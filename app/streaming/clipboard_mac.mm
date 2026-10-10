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
// Text up to 1 MB and pictures up to 20 MB (a screenshot copied on one side
// pastes on the other). On a Linux machine through wl-copy and wl-paste; on a
// Mac text through pbcopy and pbpaste, and pictures, which those two cannot
// carry, through an AppleScript one-liner and a temporary file.
// ponytail: no files.

#include "SDL_compat.h"

#import <Cocoa/Cocoa.h>

#define CLIPBOARD_MAX_BYTES (1024 * 1024)
#define CLIPBOARD_MAX_PICTURE (20 * 1024 * 1024)
#define CLIPBOARD_MAX_TIFF (96 * 1024 * 1024) // a picture not yet PNG: more than this is not even looked at
// An ssh that has not finished in time is ended: six seconds, and one more
// for every 250 kB it has to carry (a 20 MB picture over slow Wi-Fi).
#define CLIPBOARD_SECONDS(bytes) (6 + (bytes) / (250 * 1024))

static NSString* s_Destination;
static bool s_Linux;
static dispatch_queue_t s_Queue; // one transfer at a time, in order
// Main thread only:
static NSString* s_Both;       // the text both sides are known to have
static NSData* s_BothPicture;  // or the picture, as PNG
static NSInteger s_Seen = -1;  // this Mac's pasteboard change count when it last had nothing more to send
static NSInteger s_Turn;       // counts this app's comings to the front
static NSInteger s_Sending = -1; // the change count of what is on its way over, if anything is

// Runs ssh with a command for the other machine, gives it `input` and returns
// what it printed, or nil if it failed. Not on the main thread.
static NSData* remote(NSString* command, NSData* input, NSUInteger most, NSUInteger seconds)
{
    NSTask* task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ssh"];
    // One connection is kept and used again: a new one costs a third of a second.
    task.arguments = @[@"-o", @"BatchMode=yes", @"-o", @"ConnectTimeout=4", @"-o", @"ServerAliveInterval=2", @"-o", @"ServerAliveCountMax=2", @"-o", @"ControlMaster=auto",
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
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
        if (got.length <= most) {
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
    // Nothing new, or the same thing is on its way already: sent twice, the
    // second could land on top of something copied over there in between.
    if (count == s_Seen || count == s_Sending) {
        return;
    }
    NSString* text = [board stringForType:NSPasteboardTypeString];
    NSData* textBytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    // A picture and no text: a screenshot, an image copied from a page.
    NSData* png = textBytes.length == 0 ? [board dataForType:NSPasteboardTypePNG] : nil;
    NSData* tiff = textBytes.length == 0 && png == nil ? [board dataForType:NSPasteboardTypeTIFF] : nil;
    bool isPicture = png != nil || tiff != nil;
    // Nothing to send: neither of them, too much of it, what the other side
    // has already, or what a password manager marked as not to be passed on.
    if ((textBytes.length == 0 && !isPicture) || textBytes.length > CLIPBOARD_MAX_BYTES || tiff.length > CLIPBOARD_MAX_TIFF ||
            (textBytes.length != 0 && [text isEqualToString:s_Both]) ||
            [board.types containsObject:@"org.nspasteboard.ConcealedType"] || [board.types containsObject:@"org.nspasteboard.TransientType"]) {
        s_Seen = count;
        return;
    }
    // wl-copy stays behind to serve the clipboard, and would hold the pipe open.
    NSString* command = s_Linux ? [k_Wayland stringByAppendingString:isPicture ? @"wl-copy -t image/png >/dev/null 2>&1" : @"wl-copy >/dev/null 2>&1"] :
        !isPicture ? @"/usr/bin/pbcopy" :
        @"f=$(mktemp); cat > $f; osascript -e \"set the clipboard to (read (POSIX file \\\"$f\\\") as «class PNGf»)\"; r=$?; rm -f $f; exit $r";
    NSData* both = [[s_BothPicture retain] autorelease];
    s_Sending = count;
    dispatch_async(s_Queue, ^{
        @autoreleasepool {
            // Making a PNG of a large picture takes a moment: not on the main thread.
            NSData* picture = png ?: (tiff != nil ? [[NSBitmapImageRep imageRepWithData:tiff] representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil);
            NSData* bytes = isPicture ? picture : textBytes;
            // No: there is nothing more to send. Yes: only if it got there.
            bool wanted = bytes.length != 0 && bytes.length <= (isPicture ? CLIPBOARD_MAX_PICTURE : CLIPBOARD_MAX_BYTES) &&
                          !(isPicture && [picture isEqualToData:both]);
            bool sent = wanted && remote(command, bytes, 0, CLIPBOARD_SECONDS(bytes.length)) != nil;
            if (wanted) {
                SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Clipboard: %s of %lu bytes %s", isPicture ? "a picture" : "text",
                            (unsigned long)bytes.length, sent ? "sent" : "could not be sent; it is tried again the next time");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (s_Sending == count) {
                    s_Sending = -1;
                }
                // Only once it is over there is it what both sides have. One
                // that did not arrive is tried again the next time this comes
                // to the front, and until then nothing from there may replace it.
                if (sent) {
                    [s_Both release];
                    [s_BothPicture release];
                    s_Both = isPicture ? nil : [text copy];
                    s_BothPicture = [picture copy];
                }
                if (sent || !wanted) {
                    s_Seen = count;
                }
            });
        }
    });
}

- (void)settled
{
    if (NSApp.active) {
        [self toFront:nil];
    }
}

// From the front: what was copied there comes back.
- (void)fromFront:(NSNotification*)note
{
    NSInteger count = NSPasteboard.generalPasteboard.changeCount;
    if (count != s_Seen) {
        return; // something copied here has not got there yet: it is the newer
    }
    NSInteger turn = s_Turn;
    // What it holds, said on a first line: "text" or "png". Text if there is
    // any; a picture only when that is all there is.
    NSString* command = !s_Linux ?
        @"if [ \"$(/usr/bin/pbpaste | wc -c)\" -gt 0 ]; then echo text; /usr/bin/pbpaste; else f=$(mktemp); "
         "osascript -e \"set d to the clipboard as «class PNGf»\" -e \"set h to open for access POSIX file \\\"$f\\\" with write permission\" "
         "-e \"write d to h\" -e \"close access h\" >/dev/null 2>&1; if [ -s $f ]; then echo png; cat $f; fi; rm -f $f; fi" :
        [k_Wayland stringByAppendingString:
        @"t=$(wl-paste -l 2>/dev/null); "
         "if printf '%s\\n' \"$t\" | grep -q '^text/plain'; then echo text; wl-paste -n -t text 2>/dev/null; "
         "elif printf '%s\\n' \"$t\" | grep -qx 'image/png'; then echo png; wl-paste -t image/png 2>/dev/null; fi"];
    dispatch_async(s_Queue, ^{
        NSData* got = remote(command, nil, CLIPBOARD_MAX_PICTURE + 8, CLIPBOARD_SECONDS(CLIPBOARD_MAX_PICTURE));
        NSString* text = nil;
        NSData* picture = nil;
        if (got.length > 5 && memcmp(got.bytes, "text\n", 5) == 0 && got.length - 5 <= CLIPBOARD_MAX_BYTES) {
            text = [[[NSString alloc] initWithData:[got subdataWithRange:NSMakeRange(5, got.length - 5)] encoding:NSUTF8StringEncoding] autorelease];
        }
        else if (got.length > 4 && memcmp(got.bytes, "png\n", 4) == 0 && got.length - 4 <= CLIPBOARD_MAX_PICTURE) {
            picture = [got subdataWithRange:NSMakeRange(4, got.length - 4)];
            if ([NSBitmapImageRep imageRepWithData:picture] == nil) {
                picture = nil; // not a picture after all
            }
        }
        if (text == nil && picture == nil) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard* board = NSPasteboard.generalPasteboard;
            // Not if this app has been to the front again since it was asked
            // for, nor if something was copied here meanwhile.
            if (turn != s_Turn || board.changeCount != count ||
                    (picture != nil ? [picture isEqualToData:s_BothPicture] : [text isEqualToString:s_Both])) {
                return;
            }
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Clipboard: %s of %lu bytes received", picture != nil ? "a picture" : "text",
                        (unsigned long)(picture != nil ? picture.length : got.length - 5));
            [board clearContents];
            if (picture != nil) {
                [board setData:picture forType:NSPasteboardTypePNG];
            }
            else {
                [board setString:text forType:NSPasteboardTypeString];
            }
            s_Seen = board.changeCount;
            [s_Both release];
            [s_BothPicture release];
            s_Both = [text copy];
            s_BothPicture = [picture copy];
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
    // The app may have come to the front before this was listening, or may be
    // about to: look now, and once more when the window has settled.
    if (NSApp.active) {
        [share toFront:nil];
    }
    [share performSelector:@selector(settled) withObject:nil afterDelay:1.5];
}
