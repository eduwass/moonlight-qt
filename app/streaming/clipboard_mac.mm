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
static NSString* s_Last;         // the text both sides had when last we looked; main thread
static NSInteger s_Count = -1;   // the pasteboard's change count then

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
    NSPasteboard* board = NSPasteboard.generalPasteboard;
    if (board.changeCount == s_Count) {
        return;
    }
    s_Count = board.changeCount;
    // Not what a password manager marked as not to be kept or passed on.
    if ([board.types containsObject:@"org.nspasteboard.ConcealedType"] || [board.types containsObject:@"org.nspasteboard.TransientType"]) {
        return;
    }
    NSString* text = [board stringForType:NSPasteboardTypeString];
    NSData* bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length == 0 || bytes.length > CLIPBOARD_MAX_BYTES || [text isEqualToString:s_Last]) {
        return;
    }
    [s_Last release];
    s_Last = [text copy];
    // wl-copy stays behind to serve the clipboard, and would hold the pipe open.
    NSString* command = s_Linux ? [k_Wayland stringByAppendingString:@"wl-copy >/dev/null 2>&1"] : @"/usr/bin/pbcopy";
    dispatch_async(s_Queue, ^{
        remote(command, bytes);
    });
}

// From the front: what was copied there comes back.
- (void)fromFront:(NSNotification*)note
{
    NSString* command = s_Linux ? [k_Wayland stringByAppendingString:@"wl-paste -n -t text 2>/dev/null"] : @"/usr/bin/pbpaste";
    dispatch_async(s_Queue, ^{
        NSData* got = remote(command, nil);
        NSString* text = got.length > 0 && got.length <= CLIPBOARD_MAX_BYTES ? [[[NSString alloc] initWithData:got encoding:NSUTF8StringEncoding] autorelease] : nil;
        if (text == nil) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard* board = NSPasteboard.generalPasteboard;
            // Unless something was copied here meanwhile: that is the newer.
            if ([text isEqualToString:s_Last] || board.changeCount != s_Count) {
                return;
            }
            [board clearContents];
            [board setString:text forType:NSPasteboardTypeString];
            s_Count = board.changeCount;
            [s_Last release];
            s_Last = [text copy];
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
