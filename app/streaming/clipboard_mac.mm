// Fork-only (eduwass/moonlight-qt): one clipboard for this Mac and the machine
// in the stream.
//
// The stream protocol carries no clipboard, so it goes on the side, over ssh
// (MOONLIGHT_CLIPBOARD=<ssh destination>, from the device's Clipboard field):
// what was copied here goes to the other machine when this stream's app comes
// to the front, and what was copied there comes back when it leaves the front.
// So a copy on either side can be pasted on the other, and nothing travels
// while you stay on one side.
//
// ponytail: text only, up to 1 MB. Pictures and files would need the types
// read and written on both ends (NSPasteboard here, wl-copy -t or an
// AppleScript there); nothing here stands in the way of adding them.

#import <Cocoa/Cocoa.h>

#define CLIPBOARD_MAX_BYTES (1024 * 1024)
#define CLIPBOARD_SECONDS 6 // an ssh that has not finished by then is ended

static NSString* s_Destination;
static bool s_Linux;
static dispatch_queue_t s_Queue; // one transfer at a time, in order
// Main thread only:
static NSString* s_Both;       // the text both sides are known to have
static NSInteger s_Seen = -1;  // this Mac's pasteboard change count when it last had nothing more to send
static NSInteger s_Turn;       // counts this app's comings to the front

// Runs ssh with a command for the other machine, gives it `input` and returns
// what it printed, or nil if it failed. Not on the main thread.
static NSData* remote(NSString* command, NSData* input)
{
    NSTask* task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ssh"];
    // One connection is kept and used again: a new one costs a third of a second.
    task.arguments = @[@"-o", @"BatchMode=yes", @"-o", @"ConnectTimeout=4", @"-o", @"ControlMaster=auto",
                       @"-o", [NSString stringWithFormat:@"ControlPath=%@/.ssh/cm-%%C", NSHomeDirectory()], @"-o", @"ControlPersist=600",
                       @"--", s_Destination, command];
    NSPipe* in = [NSPipe pipe];
    NSPipe* out = [NSPipe pipe];
    task.standardInput = in;
    task.standardOutput = out;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) {
        return nil;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, CLIPBOARD_SECONDS * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.running) {
            [task terminate];
        }
    });
    @try {
        if (input != nil) {
            [in.fileHandleForWriting writeData:input];
        }
        [in.fileHandleForWriting closeFile];
    }
    @catch (NSException*) {
        // The other end went away mid-write; the exit status says so too.
    }
    // No more than is wanted of it: the other clipboard may hold anything.
    NSMutableData* got = [NSMutableData data];
    for (;;) {
        NSData* more = [out.fileHandleForReading availableData];
        if (more.length == 0) {
            break;
        }
        if (got.length <= CLIPBOARD_MAX_BYTES) {
            [got appendData:more];
        }
    }
    [task waitUntilExit];
    return task.terminationStatus == 0 ? got : nil;
}

// A Wayland session's clipboard from an ssh login, which has neither variable.
static NSString* const k_Wayland = @"export XDG_RUNTIME_DIR=/run/user/$(id -u); "
                                    "export WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR | grep -m1 '^wayland-[0-9]*$'); ";

@interface ClipboardShare : NSObject
@end

@implementation ClipboardShare
// To the front: what was copied here since last time goes over.
- (void)toFront:(NSNotification*)note
{
    s_Turn++; // a pull still on its way is from before this, and is dropped
    NSPasteboard* board = NSPasteboard.generalPasteboard;
    NSInteger count = board.changeCount;
    if (count == s_Seen) {
        return;
    }
    NSString* text = [board stringForType:NSPasteboardTypeString];
    NSData* bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    // Nothing to send: no text, too much of it, what the other side has
    // already, or what a password manager marked as not to be passed on.
    if (bytes.length == 0 || bytes.length > CLIPBOARD_MAX_BYTES || [text isEqualToString:s_Both] ||
            [board.types containsObject:@"org.nspasteboard.ConcealedType"] || [board.types containsObject:@"org.nspasteboard.TransientType"]) {
        s_Seen = count;
        return;
    }
    // wl-copy stays behind to serve the clipboard, and would hold the pipe open.
    NSString* command = s_Linux ? [k_Wayland stringByAppendingString:@"wl-copy >/dev/null 2>&1"] : @"/usr/bin/pbcopy";
    dispatch_async(s_Queue, ^{
        bool sent = remote(command, bytes) != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Only once it is over there is it what both sides have. One that
            // did not arrive is tried again the next time this comes to the
            // front, and until then nothing from there may replace it.
            if (sent) {
                [s_Both release];
                s_Both = [text copy];
                s_Seen = count;
            }
        });
    });
}

// From the front: what was copied there comes back.
- (void)fromFront:(NSNotification*)note
{
    NSInteger count = NSPasteboard.generalPasteboard.changeCount;
    if (count != s_Seen) {
        return; // something copied here has not got there yet: it is the newer
    }
    NSInteger turn = s_Turn;
    NSString* command = s_Linux ? [k_Wayland stringByAppendingString:@"wl-paste -n -t text 2>/dev/null"] : @"/usr/bin/pbpaste";
    dispatch_async(s_Queue, ^{
        NSData* got = remote(command, nil);
        NSString* text = got.length > 0 && got.length <= CLIPBOARD_MAX_BYTES ? [[[NSString alloc] initWithData:got encoding:NSUTF8StringEncoding] autorelease] : nil;
        if (text == nil) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard* board = NSPasteboard.generalPasteboard;
            // Not if this app has been to the front again since it was asked
            // for, nor if something was copied here meanwhile.
            if (turn != s_Turn || board.changeCount != count || [text isEqualToString:s_Both]) {
                return;
            }
            [board clearContents];
            [board setString:text forType:NSPasteboardTypeString];
            s_Seen = board.changeCount;
            [s_Both release];
            s_Both = [text copy];
        });
    });
}
@end

// Called once, on the main thread, when the stream's window is there.
void clipboardShareStart()
{
    const char* destination = getenv("MOONLIGHT_CLIPBOARD");
    if (s_Destination != nil || destination == nullptr) {
        return;
    }
    // A user and a host, and nothing ssh could take for an option or a command.
    NSString* given = @(destination);
    NSCharacterSet* other = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@"] invertedSet];
    if (given.length == 0 || given.length > 128 || [given hasPrefix:@"-"] || [given rangeOfCharacterFromSet:other].location != NSNotFound) {
        NSLog(@"Clipboard: \"%@\" is not an ssh destination", given);
        return;
    }
    s_Destination = [given copy];
    s_Linux = getenv("MOONLIGHT_CHROME") != nullptr && strstr(getenv("MOONLIGHT_CHROME"), "linux") != nullptr;
    s_Queue = dispatch_queue_create("clipboard", DISPATCH_QUEUE_SERIAL);
    ClipboardShare* share = [[ClipboardShare alloc] init]; // for as long as the app runs
    [NSNotificationCenter.defaultCenter addObserver:share selector:@selector(toFront:) name:NSApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:share selector:@selector(fromFront:) name:NSApplicationDidResignActiveNotification object:nil];
    if (NSApp.active) {
        [share toFront:nil];
    }
}
