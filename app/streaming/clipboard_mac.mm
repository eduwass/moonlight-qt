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
// Files copied in the Finder (or a file manager over there) go too, up to
// 200 MB together: packed with tar, unpacked into a cache folder at the other
// end, and put on that clipboard as files.
// ponytail: a transfer is held in memory whole (a 200 MB copy is 200 MB of
// this app for a moment); folders are not taken. Upgrade path: stream the tar
// straight between the two processes.

#include <CommonCrypto/CommonDigest.h>
#include "SDL_compat.h"

#import <Cocoa/Cocoa.h>

#include <fcntl.h>
#include <sys/time.h>
#include <unistd.h>

#define CLIPBOARD_MAX_BYTES (1024 * 1024)
#define CLIPBOARD_MAX_PICTURE (20 * 1024 * 1024)
#define CLIPBOARD_MAX_FILES (200 * 1024 * 1024)
#define CLIPBOARD_MAX_FILE_COUNT 64
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
static NSString* s_BothFiles;  // or the files: see filesKey
static NSInteger s_Seen = -1;  // this Mac's pasteboard change count when it last had nothing more to send
static NSInteger s_Turn;       // counts this app's comings to the front
static NSInteger s_Sending = -1; // the change count of what is on its way over, if anything is

// Runs ssh with a command for the other machine, gives it `input` and returns
// what it printed, or nil if it failed. Not on the main thread.
static NSData* remote(NSString* command, NSData* input, NSUInteger most, NSUInteger seconds)
{
    NSTask* task = [[[NSTask alloc] init] autorelease];
    // One connection is kept and used again: a new one costs a third of a second.
    NSArray<NSString*>* ssh = @[@"/usr/bin/ssh", @"-o", @"BatchMode=yes", @"-o", @"ConnectTimeout=4", @"-o", @"ServerAliveInterval=2", @"-o", @"ServerAliveCountMax=2", @"-o", @"ControlMaster=auto",
                       @"-o", [NSString stringWithFormat:@"ControlPath=%@/.ssh/cm-%%C", NSHomeDirectory()], @"-o", @"ControlPersist=600",
                       @"--", s_Destination, command];
    // Its time is up whether or not this process is still there to say so
    // (below): a stream that ends, or is replaced by its second try, with a
    // command hung at the other end would leave ssh waiting for good. The
    // alarm is set before ssh takes the process's place, and stays set.
    if ([NSFileManager.defaultManager isExecutableFileAtPath:@"/usr/bin/perl"]) {
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/perl"];
        task.arguments = [@[@"-e", @"alarm shift; exec @ARGV", [NSString stringWithFormat:@"%lu", (unsigned long)seconds + 5]] arrayByAddingObjectsFromArray:ssh];
    }
    else {
        task.executableURL = [NSURL fileURLWithPath:ssh[0]];
        task.arguments = [ssh subarrayWithRange:NSMakeRange(1, ssh.count - 1)];
    }
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
    // No more than is wanted of it: the other clipboard may hold anything, and
    // the other machine may send anything. More than `most` ends it, and is
    // nothing received.
    NSMutableData* got = [NSMutableData data];
    bool over = false;
    for (;;) {
        @autoreleasepool {
            NSData* more = [out.fileHandleForReading availableData];
            if (more.length == 0) {
                break;
            }
            if (most == 0) {
                continue; // nothing is expected back; what comes is let go of
            }
            if (more.length > most - got.length) {
                over = true;
                [task terminate];
                break;
            }
            [got appendData:more];
        }
    }
    [task waitUntilExit];
    return !over && task.terminationStatus == 0 ? got : nil;
}

// A Wayland session's clipboard from an ssh login, which has neither variable.
static NSString* const k_Wayland = @"export XDG_RUNTIME_DIR=/run/user/$(id -u); "
                                    "export WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR | grep -m1 '^wayland-[0-9]*$'); ";

// What a set of files is known by: each one's name, size and time of last
// change. tar carries all three across, so the copy at the other end has the
// same.
static NSString* filesKey(NSArray<NSURL*>* files)
{
    NSMutableArray* parts = [NSMutableArray array];
    for (NSURL* file in files) {
        NSDictionary* about = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
        [parts addObject:[NSString stringWithFormat:@"%@|%llu|%.0f", file.lastPathComponent, about.fileSize, about.fileModificationDate.timeIntervalSince1970]];
    }
    return [[parts sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"];
}

// The plain files among them, or nil if they cannot be sent as they are: a
// folder among them, too many, too much.
static NSArray<NSURL*>* sendable(NSArray<NSURL*>* files)
{
    unsigned long long total = 0;
    NSMutableSet* names = [NSMutableSet set];
    for (NSURL* file in files) {
        NSDictionary* about = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
        // Two of one name (from two folders) would be one file at the other end.
        NSString* name = file.lastPathComponent.lowercaseString;
        if (![about.fileType isEqualToString:NSFileTypeRegular] || name == nil || [names containsObject:name]) {
            return nil;
        }
        [names addObject:name];
        total += about.fileSize;
    }
    return files.count > 0 && files.count <= CLIPBOARD_MAX_FILE_COUNT && total <= CLIPBOARD_MAX_FILES ? files : nil;
}

// Packs `files` with tar; nil if it failed or came to more than is sent (a
// file can have grown since it was looked at).
static NSData* pack(NSArray<NSURL*>* files)
{
    NSTask* task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
    // -n: what was a file and is a folder by now is not gone into.
    NSMutableArray* arguments = [NSMutableArray arrayWithArray:@[@"-cnf", @"-"]];
    for (NSURL* file in files) {
        // "./": a name is a name, whatever it begins with (tar reads -x as an
        // option and @x as an archive to take entries from).
        [arguments addObjectsFromArray:@[@"-C", file.path.stringByDeletingLastPathComponent, [@"./" stringByAppendingString:file.lastPathComponent]]];
    }
    task.arguments = arguments;
    // Without what a Mac keeps beside a file (its "._name" twin in the
    // archive): at the other end that is one more file, of no use there.
    NSMutableDictionary* environment = [[NSProcessInfo.processInfo.environment mutableCopy] autorelease];
    environment[@"COPYFILE_DISABLE"] = @"1";
    task.environment = environment;
    NSPipe* out = [NSPipe pipe];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = out;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) {
        return nil;
    }
    NSMutableData* got = [NSMutableData data];
    bool over = false;
    for (;;) {
        @autoreleasepool {
            NSData* more = [out.fileHandleForReading availableData];
            if (more.length == 0) {
                break;
            }
            if (got.length + more.length > CLIPBOARD_MAX_FILES + (1 << 20)) {
                over = true;
                [task terminate];
                break;
            }
            [got appendData:more];
        }
    }
    [task waitUntilExit];
    return !over && task.terminationStatus == 0 ? got : nil;
}

static NSString* const k_Nul = [NSString stringWithCharacters:(const unichar[]){0} length:1];

static unsigned long long octal(const unsigned char* field, size_t length, bool* bad)
{
    unsigned long long value = 0;
    size_t i = 0;
    if (length > 0 && (field[0] & 0x80)) {
        *bad = true; // the binary form, for sizes of 8 GB and more
        return 0;
    }
    while (i < length && field[i] == ' ') {
        i++;
    }
    for (; i < length && field[i] >= '0' && field[i] <= '7'; i++) {
        value = value * 8 + (field[i] - '0');
    }
    return value;
}

// Unpacks an archive that came from the other machine into `folder`, and
// gives back the names of the files made; nil (and nothing kept) if it is not
// exactly what is taken: plain files, at the top, each name once, no more of
// them and no larger than is sent. Read here and not by tar, which would
// unpack whatever it is given: links, a path of folders, an archive that is
// small and compressed and enormous once out.
static NSArray<NSString*>* unpack(NSData* archive, NSString* folder)
{
    const unsigned char* bytes = (const unsigned char*)archive.bytes;
    size_t length = archive.length, at = 0;
    NSMutableArray<NSString*>* made = [NSMutableArray array];
    NSString* longName = nil; // from a header that names the next file in full
    unsigned long long total = 0;
    bool bad = false;
    while (!bad && at + 512 <= length) {
        const unsigned char* header = bytes + at;
        bool empty = true;
        for (int i = 0; i < 512 && empty; i++) {
            empty = header[i] == 0;
        }
        if (empty) {
            break; // the end of the archive
        }
        unsigned long long size = octal(header + 124, 12, &bad), stamp = octal(header + 136, 12, &bad);
        size_t data = at + 512;
        if (bad || size > length - data) {
            bad = true;
            break;
        }
        char kind = (char)header[156];
        if (kind == 'x' || kind == 'L') {
            // The next file's name in full: "<length> path=<name>\n" among
            // other such lines, or the name itself.
            NSString* text = [[[NSString alloc] initWithBytes:bytes + data length:(NSUInteger)size encoding:NSUTF8StringEncoding] autorelease];
            if (kind == 'L') {
                longName = [text componentsSeparatedByString:k_Nul].firstObject; // it ends with one
            }
            else {
                for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
                    NSRange path = [line rangeOfString:@" path="];
                    if (path.location != NSNotFound) {
                        longName = [line substringFromIndex:NSMaxRange(path)];
                    }
                    // A size given here is one this does not go by: the header's has been checked against what is there.
                    bad |= [line rangeOfString:@" size="].location != NSNotFound;
                }
            }
            bad |= text == nil;
        }
        else if (kind == 'g') {
            // settings for the whole archive: nothing here needs them
        }
        else if (kind == '0' || kind == 0) {
            NSString* name = longName;
            if (name == nil) {
                NSString* last = [[[NSString alloc] initWithBytes:header length:strnlen((const char*)header, 100) encoding:NSUTF8StringEncoding] autorelease];
                NSString* first = [[[NSString alloc] initWithBytes:header + 345 length:strnlen((const char*)header + 345, 155) encoding:NSUTF8StringEncoding] autorelease];
                name = first.length > 0 ? [NSString stringWithFormat:@"%@/%@", first, last] : last;
            }
            longName = nil;
            if ([name hasPrefix:@"./"]) {
                name = [name substringFromIndex:2];
            }
            total += size;
            if (name.length == 0 || name.length > 255 || [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
                    [name rangeOfString:@"/"].location != NSNotFound || [name rangeOfString:k_Nul].location != NSNotFound ||
                    made.count >= CLIPBOARD_MAX_FILE_COUNT || total > CLIPBOARD_MAX_FILES) {
                bad = true;
                break;
            }
            NSString* path = [folder stringByAppendingPathComponent:name];
            // New, and not through a link: a name that is there already is the second of its kind.
            int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (fd < 0) {
                bad = true;
                break;
            }
            size_t written = 0;
            while (written < size) {
                ssize_t n = write(fd, bytes + data + written, (size_t)size - written);
                if (n <= 0) {
                    bad = true;
                    break;
                }
                written += (size_t)n;
            }
            struct timeval times[2] = {{(time_t)stamp, 0}, {(time_t)stamp, 0}};
            futimes(fd, times); // as at the other end: it is part of what the files are known by
            close(fd);
            [made addObject:name];
        }
        else {
            bad = true; // a folder, a link, a device: not taken
        }
        at = data + (size_t)((size + 511) / 512 * 512);
    }
    return bad || made.count == 0 ? nil : made;
}

// (The Mac one writes, waits a moment and counts, until the clipboard has
// them all: a script that writes several files and leaves at once left only
// the first there nine times in ten, and one that counted at once still one
// time in ten; with the wait, none in thirty.)
// For the other machine. Putting files on its clipboard: the archive comes on
// standard input. Taking them off: "files" on a first line, then the archive;
// nothing if its clipboard holds no files (or a folder, or too much).
static NSString* const k_MacSetFiles = @(R"SH(d="$HOME/Library/Caches/moonlightnext-clipboard"; rm -rf "$d"; mkdir -p "$d" && /usr/bin/tar -xf - -C "$d" && D="$d" osascript -l JavaScript -e 'ObjC.import("AppKit"); ObjC.import("stdlib"); var d = $.getenv("D"); var names = $.NSFileManager.defaultManager.contentsOfDirectoryAtPathError(d, null); var a = $.NSMutableArray.alloc.init; for (var i = 0; i < names.count; i++) a.addObject($.NSURL.fileURLWithPath(d + "/" + names.objectAtIndex(i).js)); var pb = $.NSPasteboard.generalPasteboard; for (var k = 0; k < 8; k++) { pb.clearContents; pb.writeObjects(a); delay(0.3); if (pb.pasteboardItems.count == a.count) break; }' >/dev/null)SH");
static NSString* const k_LinuxSetFiles = @(R"SH(d="$HOME/.cache/moonlightnext-clipboard"; rm -rf "$d"; mkdir -p "$d" && tar -xf - -C "$d" && python3 -c 'import os,sys,urllib.parse; d=sys.argv[1]; sys.stdout.write("".join("file://"+urllib.parse.quote(os.path.join(d,n))+"\r\n" for n in sorted(os.listdir(d))))' "$d" | wl-copy -t text/uri-list >/dev/null 2>&1)SH");
static NSString* const k_MacListFiles = @(R"SH(l=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var u = $.NSPasteboard.generalPasteboard.readObjectsForClassesOptions($.NSArray.arrayWithObject($.NSURL), $({NSPasteboardURLReadingFileURLsOnly: true})); var o = []; for (var i = 0; u && i < u.count; i++) o.push(u.objectAtIndex(i).path.js); o.join("\n")' 2>/dev/null); )SH");
static NSString* const k_LinuxListFiles = @(R"SH(l=$(wl-paste -l 2>/dev/null | grep -qx text/uri-list && wl-paste -t text/uri-list 2>/dev/null | python3 -c 'import sys,urllib.parse; [print(urllib.parse.unquote(u.strip()[7:])) for u in sys.stdin if u.startswith("file://")]'); )SH");
// After either of the two above: the files of $l as an archive, or else what follows this.
static NSString* const k_SendFilesOr = @(R"SH(set --; n=0; bad=0; while IFS= read -r f; do [ -n "$f" ] || continue; [ -f "$f" ] || { bad=1; continue; }; n=$((n + $(wc -c < "$f"))); set -- "$@" -C "$(dirname "$f")" "./$(basename "$f")"; done <<LIST
$l
LIST
if [ $# -gt 0 ] && [ $bad = 0 ] && [ $# -le 192 ] && [ $n -le 209715200 ]; then echo files; COPYFILE_DISABLE=1 tar -cf - "$@"; exit; fi; [ -z "$l" ] || exit 0; )SH");

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
    // Only what kinds of thing it holds are asked here. What it holds is read
    // on the queue below: for something copied on another Apple device, macOS
    // fetches it over the network at that moment, and this is the thread the
    // stream's window and keys live on.
    NSArray<NSPasteboardType>* types = board.types;
    // What macOS itself brought here from another Mac (Universal Clipboard
    // marks it so) is not sent on to a Mac: it most likely came from that one,
    // and macOS does the same errand between the two anyway. Nor what a
    // password manager marked as not to be passed on, to anyone.
    if ((!s_Linux && [types containsObject:@"com.apple.is-remote-clipboard"]) ||
            [types containsObject:@"org.nspasteboard.ConcealedType"] || [types containsObject:@"org.nspasteboard.TransientType"]) {
        s_Seen = count;
        return;
    }
    NSString* bothText = [[s_Both copy] autorelease];
    NSData* bothPicture = [[s_BothPicture retain] autorelease];
    NSString* bothFiles = [[s_BothFiles copy] autorelease];
    s_Sending = count;
    dispatch_async(s_Queue, ^{
        @autoreleasepool {
            NSPasteboard* from = NSPasteboard.generalPasteboard;
            // What there is to send, in this order: files (the Finder puts
            // their names there as text too, and a name is not what was
            // copied), text, a picture (a screenshot, an image from a page).
            NSArray<NSURL*>* copied = [from readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
            NSArray<NSURL*>* files = copied.count > 0 ? sendable(copied) : nil;
            NSString* key = files != nil ? filesKey(files) : nil;
            NSString* text = copied.count > 0 ? nil : [from stringForType:NSPasteboardTypeString];
            NSData* textBytes = [text dataUsingEncoding:NSUTF8StringEncoding];
            NSData* picture = nil;
            if (copied.count == 0 && textBytes.length == 0) {
                picture = [from dataForType:NSPasteboardTypePNG];
                NSData* tiff = picture == nil ? [from dataForType:NSPasteboardTypeTIFF] : nil;
                if (tiff != nil && tiff.length <= CLIPBOARD_MAX_TIFF) {
                    picture = [[NSBitmapImageRep imageRepWithData:tiff] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                }
            }
            NSData* bytes = nil;
            NSString* command = nil;
            const char* what = "";
            // (Nothing: a folder among the files, too many, too much; text or a
            // picture too large; or what the other side has already.)
            if (files != nil && ![key isEqualToString:bothFiles]) {
                bytes = pack(files);
                command = s_Linux ? [k_Wayland stringByAppendingString:k_LinuxSetFiles] : k_MacSetFiles;
                what = "files";
            }
            else if (copied.count == 0 && textBytes.length != 0 && textBytes.length <= CLIPBOARD_MAX_BYTES && ![text isEqualToString:bothText]) {
                bytes = textBytes;
                // wl-copy stays behind to serve the clipboard, and would hold the pipe open.
                command = s_Linux ? [k_Wayland stringByAppendingString:@"wl-copy >/dev/null 2>&1"] : @"/usr/bin/pbcopy";
                what = "text";
            }
            else if (picture.length != 0 && picture.length <= CLIPBOARD_MAX_PICTURE && ![picture isEqualToData:bothPicture]) {
                bytes = picture;
                command = s_Linux ? [k_Wayland stringByAppendingString:@"wl-copy -t image/png >/dev/null 2>&1"] :
                    @"f=$(mktemp); cat > $f; osascript -e \"set the clipboard to (read (POSIX file \\\"$f\\\") as «class PNGf»)\"; r=$?; rm -f $f; exit $r";
                what = "a picture";
            }
            // Copied over while it was being read: the next coming to the front has the new one.
            bool stale = from.changeCount != count;
            bool wanted = !stale && bytes.length != 0;
            bool sent = wanted && remote(command, bytes, 0, CLIPBOARD_SECONDS(bytes.length)) != nil;
            if (wanted) {
                SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Clipboard: %s, %lu bytes, %s", what, (unsigned long)bytes.length,
                            sent ? "sent" : "could not be sent; tried again the next time");
            }
            bool isFiles = files != nil && bytes != nil && command != nil && strcmp(what, "files") == 0;
            bool isPicture = strcmp(what, "a picture") == 0;
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
                    [s_BothFiles release];
                    s_Both = isFiles || isPicture ? nil : [text copy];
                    s_BothPicture = isPicture ? [picture copy] : nil;
                    s_BothFiles = isFiles ? [key copy] : nil;
                }
                if (sent || (!wanted && !stale)) {
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
        // Something copied here has not got there yet (it is the newer), or
        // this Mac's clipboard has changed by itself since this app last
        // looked: Universal Clipboard bringing what was copied on another Mac.
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Clipboard: not fetched, this Mac's has changed since it was last looked at%s",
                    [NSPasteboard.generalPasteboard.types containsObject:@"com.apple.is-remote-clipboard"] ? " (macOS brought it from another device)" : "");
        return;
    }
    NSInteger turn = s_Turn;
    // What it holds, said on a first line: "files", "text" or "png". Files if
    // there are any (their names are there as text too); else text if there is
    // any; a picture only when that is all there is.
    NSString* rest = !s_Linux ?
        @"if [ \"$(/usr/bin/pbpaste | wc -c)\" -gt 0 ]; then echo text; /usr/bin/pbpaste; else f=$(mktemp); "
         "osascript -e \"set d to the clipboard as «class PNGf»\" -e \"set h to open for access POSIX file \\\"$f\\\" with write permission\" "
         "-e \"write d to h\" -e \"close access h\" >/dev/null 2>&1; if [ -s $f ]; then echo png; cat $f; fi; rm -f $f; fi" :
        [k_Wayland stringByAppendingString:
        @"t=$(wl-paste -l 2>/dev/null); "
         "if printf '%s\\n' \"$t\" | grep -q '^text/plain'; then echo text; wl-paste -n -t text 2>/dev/null; "
         "elif printf '%s\\n' \"$t\" | grep -qx 'image/png'; then echo png; wl-paste -t image/png 2>/dev/null; fi"];
    NSString* command = [NSString stringWithFormat:@"%@%@%@", s_Linux ? [k_Wayland stringByAppendingString:k_LinuxListFiles] : k_MacListFiles, k_SendFilesOr, rest];
    dispatch_async(s_Queue, ^{
        NSData* got = remote(command, nil, CLIPBOARD_MAX_FILES + (1 << 20), CLIPBOARD_SECONDS(CLIPBOARD_MAX_FILES));
        NSString* text = nil;
        NSData* picture = nil;
        if (got.length > 6 && memcmp(got.bytes, "files\n", 6) == 0) {
            [self received:[got subdataWithRange:NSMakeRange(6, got.length - 6)] turn:turn count:count];
            return;
        }
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
            [s_BothFiles release];
            s_Both = [text copy];
            s_BothPicture = [picture copy];
            s_BothFiles = nil;
        });
    });
}

// Files have come (not on the main thread): unpacked into a folder of their
// own in the app's caches, and put on the clipboard from there. The folder
// holds one clipboard's worth; the one before goes.
- (void)received:(NSData*)archive turn:(NSInteger)turn count:(NSInteger)count
{
    NSFileManager* manager = NSFileManager.defaultManager;
    NSURL* caches = [[manager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
                     URLByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier ?: @"dev.eduwass.moonlight-next"];
    // One folder per device: two streams must not empty each other's.
    // (Its name with nothing in it that could lead out of the caches: this
    // folder is emptied, and the name comes from the environment.)
    NSString* given = getenv("MOONLIGHT_DEVICE") != nullptr ? @(getenv("MOONLIGHT_DEVICE")) : nil;
    NSCharacterSet* plain = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%_"];
    NSString* device = [[given componentsSeparatedByCharactersInSet:plain.invertedSet] componentsJoinedByString:@"_"];
    if (device.length == 0 || device.length > 100) {
        // (Still its own: two devices with long names are two folders.)
        // (All of the name goes into it: NSString's own hash looks at 96 characters.)
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        const char* whole = given.UTF8String ?: "";
        CC_SHA256(whole, (CC_LONG)strlen(whole), digest);
        device = [NSString stringWithFormat:@"stream%02x%02x%02x%02x%02x%02x%02x%02x", digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7]];
    }
    static long arrivals; // only ever here, on the one queue
    // (The folder they are unpacked into is this arrival's own: what is done
    // with it on the main thread, later, must not be done to the next one's.)
    NSURL* fresh = [caches URLByAppendingPathComponent:[NSString stringWithFormat:@"clipboard-%@.new%ld", device, ++arrivals]];
    NSURL* folder = [caches URLByAppendingPathComponent:[NSString stringWithFormat:@"clipboard-%@", device]];
    [manager removeItemAtURL:fresh error:nil];
    NSArray<NSString*>* names = [manager createDirectoryAtURL:fresh withIntermediateDirectories:YES attributes:nil error:nil] ? unpack(archive, fresh.path) : nil;
    if (names == nil) {
        [manager removeItemAtURL:fresh error:nil];
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Clipboard: files came that are not taken (a folder or a link among them, too many, too much)");
        return;
    }
    NSMutableArray<NSURL*>* arrived = [NSMutableArray array];
    for (NSString* name in names) {
        [arrived addObject:[fresh URLByAppendingPathComponent:name]];
    }
    NSString* key = filesKey(arrived);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPasteboard* board = NSPasteboard.generalPasteboard;
        if (names.count == 0 || turn != s_Turn || board.changeCount != count || [key isEqualToString:s_BothFiles]) {
            [manager removeItemAtURL:fresh error:nil];
            return;
        }
        [manager removeItemAtURL:folder error:nil];
        if (![manager moveItemAtURL:fresh toURL:folder error:nil]) {
            [manager removeItemAtURL:fresh error:nil];
            return;
        }
        NSMutableArray<NSURL*>* files = [NSMutableArray array];
        for (NSString* name in names) {
            [files addObject:[folder URLByAppendingPathComponent:name]];
        }
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Clipboard: %lu files, %lu bytes received", (unsigned long)files.count, (unsigned long)archive.length);
        [board clearContents];
        [board writeObjects:files];
        s_Seen = board.changeCount;
        [s_Both release];
        [s_BothPicture release];
        [s_BothFiles release];
        s_Both = nil;
        s_BothPicture = nil;
        s_BothFiles = [key copy];
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
