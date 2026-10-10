#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
// Fork-only (eduwass/moonlight-qt): the window the app opens when it is started
// by itself. The machines to connect to on the left; on the right the one
// selected: a picture of what is on its screen, whether it answers, and how it
// is streamed. Connect starts a stream in a process of its own (this same app
// with "stream ..."), so several can be open at once, each in its window.
//
// Moonlight's own screens (pairing, its settings) are still there: "Classic
// Moonlight" in the "..." menu, or MOONLIGHT_CLASSIC=1.
//
// A device is a dictionary in this app's defaults ("Devices"):
//   name, address          what it is called here, and where it is
//   host                   the name Moonlight knows it by (its saved host), to pin the address
//   system                 "mac" or "linux" (the mark on the stream's bar)
//   fixed, width, height   a fixed stream size in pixels, scaled to fit the window; otherwise the window's pixels
//   windowWidth/Height     the window to open, in points
//   truePixels, rawColor, localCursor, noSound
//   fpsRule                "pixels:above:below", see dynres.cpp (MOONLIGHT_FPS_ABOVE)
//   bitrate                kbps, 0 for Moonlight's own choice
//   screenshot             a shell command that writes a picture of the device's screen to stdout
//   clipboard              an ssh destination: the clipboard is shared with it (clipboard_mac.mm)
//   before                 a shell command run before connecting (wake, unlock); if its last line of
//                          output is an address, the stream goes there instead

#include "manager.h"

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

void chromeSettingsOpen(const char* host);
void chromeSettingsDoctor(const char* device);

static NSMutableDictionary* plainEnvironment();
double dynresScreenPanelScale(NSScreen* screen); // dynres_mac.mm
static NSString* const k_Devices = @"Devices";
static NSString* const k_MoonlightSuite = @"com.moonlight-stream.Moonlight";

static NSMutableArray<NSMutableDictionary*>* s_Devices;

static void dockMenuChanged();

static void saveDevices()
{
    [NSUserDefaults.standardUserDefaults setObject:s_Devices forKey:k_Devices];
    dockMenuChanged();
}

// A device with its window's place and size as they are saved now: its stream,
// a process of its own, writes them as the window is moved, after this one
// read the list.
static NSMutableDictionary* withPlacement(NSDictionary* device)
{
    NSMutableDictionary* placed = [[device mutableCopy] autorelease];
    for (NSDictionary* saved in [NSUserDefaults.standardUserDefaults arrayForKey:k_Devices]) {
        if ([saved[@"name"] isEqual:device[@"name"]]) {
            for (NSString* key in @[@"windowLeft", @"windowTop", @"windowWidth", @"windowHeight"]) {
                if (saved[key] != nil) {
                    placed[key] = saved[key];
                }
            }
        }
    }
    return placed;
}

// Moonlight's saved hosts, as it numbers them: index -> its settings prefix.
static NSString* moonlightHostPrefix(NSString* host)
{
    NSUserDefaults* moonlight = [[[NSUserDefaults alloc] initWithSuiteName:k_MoonlightSuite] autorelease];
    NSInteger count = [moonlight integerForKey:@"hosts.size"];
    for (NSInteger i = 1; i <= count; i++) {
        NSString* prefix = [NSString stringWithFormat:@"hosts.%ld.", (long)i];
        if ([[moonlight stringForKey:[prefix stringByAppendingString:@"hostname"]] isEqualToString:host]) {
            return prefix;
        }
    }
    return nil;
}

static void loadDevices()
{
    s_Devices = [[NSMutableArray alloc] init];
    for (NSDictionary* saved in [NSUserDefaults.standardUserDefaults arrayForKey:k_Devices]) {
        [s_Devices addObject:[[saved mutableCopy] autorelease]];
    }
    if (s_Devices.count != 0 || [NSUserDefaults.standardUserDefaults objectForKey:k_Devices] != nil) {
        return;
    }
    // First run: the hosts Moonlight is already paired with.
    NSUserDefaults* moonlight = [[[NSUserDefaults alloc] initWithSuiteName:k_MoonlightSuite] autorelease];
    NSInteger count = [moonlight integerForKey:@"hosts.size"];
    for (NSInteger i = 1; i <= count; i++) {
        NSString* prefix = [NSString stringWithFormat:@"hosts.%ld.", (long)i];
        NSString* host = [moonlight stringForKey:[prefix stringByAppendingString:@"hostname"]];
        NSString* address = [moonlight stringForKey:[prefix stringByAppendingString:@"manualaddress"]];
        if (host.length == 0 || address.length == 0) {
            continue;
        }
        [s_Devices addObject:[[@{@"name": host, @"host": host, @"address": address, @"system": @"mac",
                                 @"windowWidth": @1920, @"windowHeight": @1080, @"localCursor": @NO, @"truePixels": @YES} mutableCopy] autorelease]];
    }
    saveDevices();
}

// How a stream's process is told which device it is (MOONLIGHT_DEVICE), and
// how it is found again: a warm stream may have been started by an earlier run
// of this window, or by a link.
static NSString* deviceId(NSString* name)
{
    return [name stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: @"";
}

static bool streamRuns(NSString* name)
{
    NSTask* task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/ps"];
    task.arguments = @[@"eww", @"-Ao", @"command"];
    NSPipe* out = [NSPipe pipe];
    task.standardOutput = out;
    if (![task launchAndReturnError:nil]) {
        return false;
    }
    NSData* data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString* all = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] ?: @"";
    NSString* mark = [NSString stringWithFormat:@"MOONLIGHT_DEVICE=%@", deviceId(name)];
    for (NSString* line in [all componentsSeparatedByString:@"\n"]) {
        if ([line containsString:@"Moonlight stream "] && ([line containsString:[mark stringByAppendingString:@" "]] || [line hasSuffix:mark])) {
            return true;
        }
    }
    return false;
}

// Where a device's last screenshot is kept between runs of the app.
static NSURL* pictureFile(NSString* name)
{
    NSURL* folder = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
                     URLByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier ?: @"dev.eduwass.moonlight-next"];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* safe = [deviceId(name) stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [folder URLByAppendingPathComponent:[safe stringByAppendingString:@".shot"]];
}

static void tellStream(NSString* name, NSString* what)
{
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"dev.eduwass.moonlight-next.stream" object:deviceId(name)
                                                                userInfo:@{@"do": what} deliverImmediately:YES];
}

// What a device answered when last asked.
@interface DeviceStatus : NSObject {
@public
    bool asked, online, busy;
    int ms;
}
@end
@implementation DeviceStatus
@end

@interface ManagerController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate> {
@public
    NSWindow* window;
    NSTableView* table;
    NSView* detail;
    NSImageView* picture;
    NSProgressIndicator* spinner;
    NSTextField* pictureNote;
    NSTextField* title;
    NSTextField* statusLine;
    NSButton* connect;
    NSTextField* name;
    NSTextField* address;
    NSPopUpButton* system;
    NSPopUpButton* size;
    NSTextField* width;
    NSTextField* height;
    NSButton* truePixels;
    NSButton* rawColor;
    NSButton* localCursor;
    NSButton* noSound;
    NSTextField* bitrate;
    NSTextField* screenshot;
    NSTextField* before;
    NSTextField* clipboard;
    NSMutableDictionary<NSString*, DeviceStatus*>* statuses; // by address
    NSMutableDictionary<NSString*, NSImage*>* pictures;       // by device name
    NSMutableDictionary<NSString*, NSDate*>* pictureTimes;
    NSMutableSet<NSString*>* running; // the devices with a stream open or warm, as of the last look
    NSMutableSet<NSString*>* starting; // the devices whose stream is on its way: one start at a time each
    NSButton* endStream;
    int shooting; // screenshots on their way
    NSMutableDictionary<NSString*, NSWindow*>* waiting; // by device id: what is shown where a stream is about to be
    NSMutableDictionary<NSString*, NSNumber*>* asking;   // by device id: a "show" not yet answered by its stream
    NSMutableDictionary<NSString*, NSNumber*>* launched; // by device id: the process of the stream last started for it
}
@end

@interface ManagerController ()
- (void)reloadList;
- (void)show;
- (void)reread;
- (void)fillDockMenu:(NSMenu*)menu;
@end

static ManagerController* s_Manager;

static NSTextField* label(NSString* text, CGFloat size, NSFontWeight weight, NSColor* colour)
{
    NSTextField* field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = colour;
    return field;
}

// Runs a shell command off the main thread; hands back what it printed by the
// time limit. The limit holds whatever the command does: a child of it that
// lives on and keeps the pipe open is not waited for.
static void runShell(NSString* command, NSTimeInterval limit, void (^done)(NSData* output))
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask* task = [[[NSTask alloc] init] autorelease];
        task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
        task.arguments = @[@"-c", command];
        NSPipe* out = [NSPipe pipe];
        task.standardOutput = out;
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        NSMutableData* output = [NSMutableData data];
        if ([task launchAndReturnError:nil]) {
            dispatch_semaphore_t finished = dispatch_semaphore_create(0);
            NSFileHandle* reading = out.fileHandleForReading;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSData* all = [reading readDataToEndOfFile];
                @synchronized (output) {
                    [output appendData:all];
                }
                dispatch_semaphore_signal(finished);
            });
            if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC))) != 0) {
                [task terminate];
                if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2)) != 0 && task.running) {
                    kill(task.processIdentifier, SIGKILL);
                }
            }
            dispatch_release(finished);
        }
        NSData* got;
        @synchronized (output) {
            got = [[output copy] autorelease];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            done(got);
        });
    });
}

@implementation ManagerController

- (NSMutableDictionary*)device
{
    NSInteger row = table.selectedRow;
    return row >= 0 && row < (NSInteger)s_Devices.count ? s_Devices[row] : nil;
}

// ---- the list

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
    return s_Devices.count;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row
{
    NSDictionary* device = s_Devices[row];
    DeviceStatus* status = statuses[device[@"address"] ?: @""];
    CGFloat wide = MAX(150, column.width);
    NSTableCellView* cell = [[[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, wide, 40)] autorelease];

    NSImageView* dot = [[[NSImageView alloc] initWithFrame:NSMakeRect(4, 14, 10, 10)] autorelease];
    NSString* symbol = status != nil && status->online ? @"circle.fill" : @"circle";
    dot.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:status != nil && status->online ? @"Online" : @"Not answering"];
    dot.contentTintColor = status == nil || !status->asked ? NSColor.tertiaryLabelColor : status->online ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    dot.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:8 weight:NSFontWeightRegular];
    [cell addSubview:dot];

    NSTextField* nameField = label(device[@"name"] ?: @"", 13, NSFontWeightMedium, NSColor.labelColor);
    nameField.frame = NSMakeRect(20, 20, wide - 24, 17);
    nameField.lineBreakMode = NSLineBreakByTruncatingTail;
    nameField.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:nameField];

    NSString* sub = [device[@"system"] isEqualToString:@"linux"] ? @"Linux" : @"macOS";
    if ([running containsObject:device[@"name"] ?: @""]) {
        sub = [sub stringByAppendingString:@" · streaming"];
    }
    NSTextField* subField = label(sub, 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    subField.frame = NSMakeRect(20, 4, wide - 24, 14);
    subField.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:subField];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification
{
    [self show];
    [self shoot:NO];
}

// ---- the selected device

- (void)show
{
    if (window == nil) {
        return;
    }
    NSDictionary* device = [self device];
    detail.hidden = device == nil;
    if (device == nil) {
        return;
    }
    NSString* deviceName = device[@"name"] ?: @"";
    title.stringValue = deviceName;
    // The form as saved, unless a field of it is being typed in: what is in
    // that field is not saved yet (it is when the field is left), and this is
    // also called for news that has nothing to do with the form: a stream
    // that has started or gone, a device that answers again.
    if (![window.firstResponder isKindOfClass:[NSText class]]) {
        name.stringValue = deviceName;
        address.stringValue = device[@"address"] ?: @"";
        [system selectItemAtIndex:[device[@"system"] isEqualToString:@"linux"] ? 1 : 0];
        bool fixed = [device[@"fixed"] boolValue];
        [size selectItemAtIndex:fixed ? 1 : 0];
        width.stringValue = [NSString stringWithFormat:@"%ld", (long)([device[fixed ? @"width" : @"windowWidth"] integerValue] ?: (fixed ? 3840 : 1920))];
        height.stringValue = [NSString stringWithFormat:@"%ld", (long)([device[fixed ? @"height" : @"windowHeight"] integerValue] ?: (fixed ? 2160 : 1080))];
        width.toolTip = height.toolTip = fixed ? @"The stream's size, in pixels" : @"The window to open, in points";
        truePixels.state = [device[@"truePixels"] boolValue];
        truePixels.enabled = !fixed;
        rawColor.state = [device[@"rawColor"] boolValue];
        localCursor.state = [device[@"localCursor"] boolValue];
        noSound.state = [device[@"noSound"] boolValue];
        // What it is on that kind of machine, so that a pointer that never changes shape is no surprise.
        localCursor.title = [device[@"system"] isEqualToString:@"linux"] ? @"Instant pointer (plain arrow)" : @"Instant pointer";
        bitrate.stringValue = [device[@"bitrate"] integerValue] > 0 ? [device[@"bitrate"] stringValue] : @"";
        screenshot.stringValue = device[@"screenshot"] ?: @"";
        before.stringValue = device[@"before"] ?: @"";
        clipboard.stringValue = device[@"clipboard"] ?: @"";
    }

    DeviceStatus* status = statuses[device[@"address"] ?: @""];
    bool streaming = [running containsObject:deviceName];
    endStream.hidden = !streaming;
    if (status == nil || !status->asked) {
        statusLine.stringValue = @"Checking…";
    }
    else if (!status->online) {
        statusLine.stringValue = @"Not answering. Asleep, off, or not reachable from this network.";
    }
    else {
        statusLine.stringValue = [NSString stringWithFormat:@"Online · answers in %d ms · %@", status->ms,
                                  streaming ? @"streaming to this Mac" : status->busy ? @"a stream is open on it" : @"ready"];
    }
    connect.title = streaming ? @"Show Window" : @"Connect";

    picture.image = pictures[deviceName];
    NSDate* at = pictureTimes[deviceName];
    if ([device[@"screenshot"] length] == 0) {
        pictureNote.stringValue = @"No picture: give this device a screenshot command below.";
    }
    else if (at == nil) {
        pictureNote.stringValue = shooting > 0 ? @"Getting a picture of its screen…" : @"No picture yet.";
    }
    else {
        NSDateFormatter* format = [[[NSDateFormatter alloc] init] autorelease];
        format.timeStyle = NSDateFormatterMediumStyle;
        pictureNote.stringValue = [NSString stringWithFormat:@"Its screen at %@", [format stringFromDate:at]];
    }
}

// A picture of the device's screen. Not more often than every 20 s unless asked.
- (void)shoot:(BOOL)asked
{
    NSDictionary* device = [self device];
    NSString* command = device[@"screenshot"];
    NSString* deviceName = device[@"name"];
    if (command.length == 0 || deviceName == nil) {
        return;
    }
    NSDate* at = pictureTimes[deviceName];
    if (!asked && at != nil && -at.timeIntervalSinceNow < 20) {
        return;
    }
    shooting++;
    [spinner startAnimation:nil];
    [self show];
    runShell(command, 10, ^(NSData* output) {
        NSImage* image = output.length > 0 ? [[[NSImage alloc] initWithData:output] autorelease] : nil;
        if (image != nil) {
            pictures[deviceName] = image;
            pictureTimes[deviceName] = [NSDate date];
            [output writeToURL:pictureFile(deviceName) atomically:YES]; // for the next start of its stream, in any run of the app
        }
        if (--shooting == 0) {
            [spinner stopAnimation:nil];
        }
        [self show];
        if (image == nil && [[self device][@"name"] isEqualToString:deviceName]) {
            pictureNote.stringValue = @"The screenshot command gave no picture.";
        }
    });
}

// The list drawn again, with the device that was selected still selected: a
// table that is reloaded forgets, and with no device selected the rest of the
// window is empty.
- (void)reloadList
{
    NSInteger selected = table.selectedRow;
    [table reloadData];
    if (selected >= 0 && selected < (NSInteger)s_Devices.count) {
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
    }
}

- (void)refresh:(id)sender
{
    [self shoot:YES];
}

// ---- whether each device answers

- (void)end:(id)sender
{
    NSString* deviceName = [self device][@"name"];
    if (deviceName != nil) {
        tellStream(deviceName, @"end");
        [running removeObject:deviceName];
        dockMenuChanged();
        [self reloadList];
        [self show];
    }
}

- (void)ask
{
    // Which devices have a stream, seen or warm. (One ps for all of them.)
    NSMutableSet* now = [NSMutableSet set];
    for (NSDictionary* device in s_Devices) {
        if (device[@"name"] != nil && streamRuns(device[@"name"])) {
            [now addObject:device[@"name"]];
        }
    }
    if (![now isEqualToSet:running]) {
        [running setSet:now];
        dockMenuChanged();
        NSInteger selected = table.selectedRow;
        [table reloadData];
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
    }
    for (NSDictionary* device in s_Devices) {
        NSString* at = device[@"address"];
        if (at.length == 0) {
            continue;
        }
        NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:47989/serverinfo", at]];
        if (url == nil) {
            continue;
        }
        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2.5];
        NSDate* sent = [NSDate date];
        [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            NSString* body = data != nil ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
            bool online = [body containsString:@"<hostname>"];
            bool busy = online && ![body containsString:@"SERVER_FREE"];
            int ms = (int)round(-sent.timeIntervalSinceNow * 1000);
            dispatch_async(dispatch_get_main_queue(), ^{
                DeviceStatus* status = statuses[at];
                if (status == nil) {
                    status = [[[DeviceStatus alloc] init] autorelease];
                    statuses[at] = status;
                }
                bool changed = !status->asked || status->online != online || status->busy != busy;
                status->asked = true;
                status->online = online;
                status->busy = busy;
                status->ms = ms;
                if (changed) {
                    NSInteger selected = table.selectedRow;
                    [table reloadData];
                    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
                }
                [self show];
            });
        }] resume];
    }
}

- (void)tick:(NSTimer*)timer
{
    if (window.visible) {
        [self ask];
    }
}

- (void)windowDidBecomeKey:(NSNotification*)notification
{
    [self reread];
    [self ask];
    [self shoot:NO];
}

// The devices may have been changed from elsewhere since they were read: a
// stream is another process (it writes where its window is left, its doctor
// can set a bitrate). Before anything is done with them.
- (void)reread
{
    NSArray* saved = [NSUserDefaults.standardUserDefaults arrayForKey:k_Devices];
    // Not while a field is being typed in: what is in it has not been saved yet.
    if (saved != nil && ![saved isEqualToArray:s_Devices] && ![window.firstResponder isKindOfClass:[NSText class]]) {
        NSInteger selected = table.selectedRow;
        [s_Devices removeAllObjects];
        for (NSDictionary* each in saved) {
            [s_Devices addObject:[[each mutableCopy] autorelease]];
        }
        [table reloadData];
        if (selected >= 0 && selected < (NSInteger)s_Devices.count) {
            [table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
        }
        [self show];
        dockMenuChanged();
    }
}

- (void)windowWillClose:(NSNotification*)notification
{
    // The streams are processes of their own and go on.
    [NSApp terminate:nil];
}

// ---- changes to the selected device

- (void)changed:(id)sender
{
    NSMutableDictionary* device = [self device];
    if (device == nil) {
        return;
    }
    NSString* oldName = [[device[@"name"] retain] autorelease];
    bool fixed = size.indexOfSelectedItem == 1;
    bool wasFixed = [device[@"fixed"] boolValue];
    if (name.stringValue.length > 0) {
        device[@"name"] = name.stringValue;
    }
    device[@"address"] = [address.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    device[@"system"] = system.indexOfSelectedItem == 1 ? @"linux" : @"mac";
    device[@"fixed"] = @(fixed);
    if (fixed == wasFixed && width.integerValue >= 320 && height.integerValue >= 200 && width.integerValue <= 8192 && height.integerValue <= 8192) {
        device[fixed ? @"width" : @"windowWidth"] = @(width.integerValue);
        device[fixed ? @"height" : @"windowHeight"] = @(height.integerValue);
    }
    device[@"truePixels"] = @(truePixels.state == NSControlStateValueOn);
    device[@"rawColor"] = @(rawColor.state == NSControlStateValueOn);
    device[@"noSound"] = @(noSound.state == NSControlStateValueOn);
    device[@"localCursor"] = @(localCursor.state == NSControlStateValueOn);
    device[@"bitrate"] = @(MIN(500000, MAX(0, bitrate.integerValue)));
    device[@"screenshot"] = screenshot.stringValue;
    device[@"before"] = before.stringValue;
    device[@"clipboard"] = [clipboard.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    saveDevices();
    if (![oldName isEqualToString:device[@"name"]]) {
        NSInteger selected = table.selectedRow;
        [table reloadData];
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
    }
    [self show];
}

- (void)controlTextDidEndEditing:(NSNotification*)notification
{
    [self changed:notification.object];
}

- (void)add:(id)sender
{
    [s_Devices addObject:[[@{@"name": @"New device", @"address": @"", @"system": @"mac", @"windowWidth": @1920, @"windowHeight": @1080, @"truePixels": @YES} mutableCopy] autorelease]];
    saveDevices();
    [table reloadData];
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:s_Devices.count - 1] byExtendingSelection:NO];
    [window makeFirstResponder:name];
}

- (void)remove:(id)sender
{
    NSDictionary* device = [self device];
    if (device == nil) {
        return;
    }
    NSAlert* alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = [NSString stringWithFormat:@"Remove “%@” from the list?", device[@"name"]];
    alert.informativeText = @"Its pairing stays, so adding it again needs no new PIN.";
    [alert addButtonWithTitle:@"Remove"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            [s_Devices removeObject:device];
            saveDevices();
            [table reloadData];
            [self show];
        }
    }];
}

// ---- starting things

// A window where the stream's is about to be, at once: the device's last
// screenshot, dimmed, and a spinner. A stream takes a second or three to have
// a picture, and until then there would be nothing to see for the click.
// Taken away when the stream says it has one (dynresUp), or after 20 s.
- (void)wait:(NSDictionary*)device
{
    NSString* key = deviceId(device[@"name"]);
    if (waiting[key] != nil) {
        return;
    }
    // Where and how large the stream's own window will be (chromeStart has the
    // same test): where it was left if enough of that is on a screen, else
    // the middle of the main one, no larger than fits there.
    CGFloat w = [device[@"windowWidth"] integerValue] ?: 1920, h = [device[@"windowHeight"] integerValue] ?: 1080;
    NSRect frame = NSZeroRect;
    if (device[@"windowLeft"] != nil && device[@"windowTop"] != nil) {
        NSRect left = NSMakeRect([device[@"windowLeft"] integerValue], [device[@"windowTop"] integerValue] - h, w, h);
        for (NSScreen* screen in NSScreen.screens) {
            NSRect showing = NSIntersectionRect(screen.visibleFrame, left);
            if (showing.size.width >= 200 && showing.size.height >= 100) {
                frame = left;
            }
        }
    }
    if (NSIsEmptyRect(frame)) {
        NSRect visible = NSScreen.mainScreen.visibleFrame;
        w = MIN(w, visible.size.width);
        h = MIN(h, visible.size.height);
        frame = NSMakeRect(NSMidX(visible) - w / 2, NSMidY(visible) - h / 2, w, h);
    }
    NSWindow* shown = [[[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                                                     backing:NSBackingStoreBuffered defer:NO] autorelease];
    shown.releasedWhenClosed = NO;
    shown.titlebarAppearsTransparent = YES;
    shown.titleVisibility = NSWindowTitleHidden;
    NSWindowButton kinds[] = {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton};
    for (NSWindowButton kind : kinds) {
        [shown standardWindowButton:kind].hidden = YES;
    }
    shown.backgroundColor = NSColor.blackColor;
    shown.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    shown.level = NSFloatingWindowLevel; // above the stream's window, which comes up black under it
    shown.ignoresMouseEvents = YES;
    [shown setFrame:frame display:NO];

    NSView* content = shown.contentView;
    NSString* deviceName = device[@"name"];
    NSImageView* view = [[[NSImageView alloc] initWithFrame:content.bounds] autorelease];
    view.image = pictures[deviceName] ?: [[[NSImage alloc] initWithContentsOfURL:pictureFile(deviceName)] autorelease];
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    view.alphaValue = 0.45;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:view];
    // And a new one meanwhile: it is often there before the stream is, and is
    // what the screen looks like now rather than when it was last looked at.
    if ([device[@"screenshot"] length] > 0) {
        runShell(device[@"screenshot"], 6, ^(NSData* output) {
            NSImage* image = output.length > 0 ? [[[NSImage alloc] initWithData:output] autorelease] : nil;
            if (image != nil) {
                pictures[deviceName] = image;
                pictureTimes[deviceName] = [NSDate date];
                [output writeToURL:pictureFile(deviceName) atomically:YES];
                if (waiting[key] == shown) {
                    view.image = image;
                }
            }
        });
    }
    NSProgressIndicator* turning = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(NSMidX(content.bounds) - 16, NSMidY(content.bounds) - 4, 32, 32)] autorelease];
    turning.style = NSProgressIndicatorStyleSpinning;
    turning.indeterminate = YES;
    [turning startAnimation:nil];
    [content addSubview:turning];
    NSTextField* says = label([NSString stringWithFormat:@"Connecting to %@…", device[@"name"]], 13, NSFontWeightMedium, NSColor.whiteColor);
    [says sizeToFit];
    [says setFrameOrigin:NSMakePoint(round(NSMidX(content.bounds) - says.frame.size.width / 2), NSMidY(content.bounds) - 34)];
    [content addSubview:says];

    waiting[key] = shown;
    [shown orderFrontRegardless];
    [self performSelector:@selector(waited:) withObject:key afterDelay:20];
}

- (void)waited:(NSString*)key
{
    NSWindow* shown = [[waiting[key] retain] autorelease];
    if (shown == nil) {
        return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(waited:) object:key];
    [waiting removeObjectForKey:key];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
        context.duration = 0.15;
        shown.animator.alphaValue = 0;
    } completionHandler:^{
        [shown orderOut:nil];
    }];
}

- (void)passedOn:(NSNotification*)note
{
    if (![note.object isKindOfClass:[NSString class]]) {
        return;
    }
    // Got it, the sender may stop saying it. It may have said it twice before
    // this reached it: the same link again within three seconds is that.
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"dev.eduwass.moonlight-next.opened" object:note.object
                                                                userInfo:nil deliverImmediately:YES];
    static NSString* last;
    static NSTimeInterval lastAt;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([note.object isEqualToString:last] && now - lastAt < 3) {
        return;
    }
    [last release];
    last = [note.object copy];
    lastAt = now;
    managerOpenUrl([note.object UTF8String]);
}

// ---- the Dock icon's menu: the devices, to connect to (or bring forward) from there

- (void)fillDockMenu:(NSMenu*)menu
{
    [menu removeAllItems];
    for (NSDictionary* device in s_Devices) {
        NSString* deviceName = device[@"name"];
        if (deviceName.length == 0 || [device[@"address"] length] == 0) {
            continue;
        }
        // Said in words that it has a stream: the Dock draws no tick for an app's own items (tried).
        NSString* title = [running containsObject:deviceName] ? [deviceName stringByAppendingString:@" (streaming)"] : deviceName;
        NSMenuItem* item = [[[NSMenuItem alloc] initWithTitle:title action:@selector(dockConnect:) keyEquivalent:@""] autorelease];
        item.target = self;
        item.representedObject = deviceName;
        [menu addItem:item];
    }
}

- (void)dockConnect:(NSMenuItem*)item
{
    for (NSDictionary* device in s_Devices) {
        if ([device[@"name"] isEqual:item.representedObject]) {
            [self start:withPlacement(device)];
            return;
        }
    }
}

- (void)streamShown:(NSNotification*)note
{
    if ([note.object isKindOfClass:[NSString class]]) {
        [asking removeObjectForKey:note.object]; // it is well: nothing is to be started in its place
    }
}

- (void)streamUp:(NSNotification*)note
{
    if ([note.object isKindOfClass:[NSString class]]) {
        [self waited:note.object];
        [self stream:note.object runs:true];
    }
}

- (void)streamGone:(NSNotification*)note
{
    if (![note.object isKindOfClass:[NSString class]]) {
        return;
    }
    // Not the going of an older stream of this device, when a newer one has
    // been started since: each says which process it is.
    NSNumber* gone = note.userInfo[@"pid"], *current = launched[note.object];
    if (gone != nil && current != nil && ![gone isEqual:current]) {
        return;
    }
    [launched removeObjectForKey:note.object];
    [self stream:note.object runs:false];
}

// A stream has said it has a picture, or that it is on its way out: the list,
// the buttons and the Dock menu say so at once, and not only the next time the
// window is looked at.
- (void)stream:(NSString*)key runs:(bool)runs
{
    for (NSDictionary* device in s_Devices) {
        NSString* deviceName = device[@"name"];
        if (deviceName != nil && [deviceId(deviceName) isEqual:key] && [running containsObject:deviceName] != runs) {
            if (runs) {
                [running addObject:deviceName];
            }
            else {
                [running removeObject:deviceName];
            }
            NSInteger selected = table.selectedRow;
            [table reloadData];
            if (selected >= 0) {
                [table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
            }
            [self show];
            dockMenuChanged();
        }
    }
}

- (void)launch:(NSArray<NSString*>*)arguments environment:(NSDictionary<NSString*, NSString*>*)environment for:(NSString*)deviceName
{
    NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    configuration.arguments = arguments;
    NSMutableDictionary* all = plainEnvironment();
    [all addEntriesFromDictionary:environment];
    configuration.environment = all;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration
                                    completionHandler:^(NSRunningApplication* app, NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (app != nil && deviceName != nil) {
                [running addObject:deviceName];
                launched[deviceId(deviceName)] = @(app.processIdentifier);
                dockMenuChanged();
            }
            else if (deviceName != nil) {
                [self waited:deviceId(deviceName)]; // it did not start
            }
            if (deviceName != nil) {
                [starting removeObject:deviceName];
            }
            connect.enabled = YES;
            [self reloadList];
            [self show];
        });
    }];
}

- (void)connect:(id)sender
{
    [self start:[self device] != nil ? withPlacement([self device]) : nil];
}

- (void)startIfGone:(NSDictionary*)device asked:(NSNumber*)mine tries:(int)tries
{
    NSString* key = deviceId(device[@"name"]);
    if (![asking[key] isEqual:mine]) {
        return; // answered, or asked again since
    }
    if (!streamRuns(device[@"name"])) {
        [asking removeObjectForKey:key];
        [self start:device again:YES];
    }
    else if (tries > 1) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
            [self startIfGone:device asked:mine tries:tries - 1];
        });
    }
    else {
        [asking removeObjectForKey:key];
    }
}

- (void)start:(NSDictionary*)asGiven
{
    [self start:asGiven again:NO];
}

// Starts the stream of a device, or brings its window forward if it is open.
- (void)start:(NSDictionary*)asGiven again:(BOOL)again
{
    NSDictionary* device = [[asGiven copy] autorelease];
    NSString* deviceName = device[@"name"];
    if (device == nil || [device[@"address"] length] == 0) {
        return;
    }
    if ([starting containsObject:deviceName]) {
        return; // a second press, or a second link, while the first is at work
    }
    if (streamRuns(deviceName)) {
        tellStream(deviceName, @"show");
        // It may be one that is on its way out (its window just closed, the
        // host still being told): that one shows nothing, and the click or the
        // link would be for nothing. If it is gone within a few seconds, this
        // is started again, once.
        // (A stream that is well says so at once: "shown".)
        // One such wait per device: a newer request takes its place, and the
        // stream's answer ends it, whenever it comes (streamShown:).
        if (!again) {
            static NSInteger count;
            NSNumber* mine = @(++count);
            asking[deviceId(deviceName)] = mine;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self startIfGone:device asked:mine tries:16];
            });
        }
        return;
    }
    [starting addObject:deviceName];
    [self wait:device];
    connect.enabled = NO;
    statusLine.stringValue = [device[@"before"] length] > 0 ? @"Waking it…" : @"Connecting…";

    void (^go)(NSString*) = ^(NSString* at) {
        // Removed from the list while its "before connecting" command ran: then not.
        bool stillThere = false;
        for (NSDictionary* each in s_Devices) {
            stillThere |= [each[@"name"] isEqual:deviceName];
        }
        if (!stillThere) {
            [self waited:deviceId(deviceName)];
            [starting removeObject:deviceName];
            connect.enabled = YES;
            [self show];
            return;
        }
        // Moonlight tries the address it last saw the host at before the one it
        // is given; make them the same (see remote-mbp.sh for how that went wrong).
        NSString* prefix = device[@"host"] != nil ? moonlightHostPrefix(device[@"host"]) : nil;
        if (prefix != nil) {
            NSUserDefaults* moonlight = [[[NSUserDefaults alloc] initWithSuiteName:k_MoonlightSuite] autorelease];
            [moonlight setObject:at forKey:[prefix stringByAppendingString:@"localaddress"]];
            [moonlight setObject:at forKey:[prefix stringByAppendingString:@"manualaddress"]];
        }

        bool fixed = [device[@"fixed"] boolValue], linux = [device[@"system"] isEqualToString:@"linux"];
        NSInteger w = [device[@"windowWidth"] integerValue] ?: 1920, h = [device[@"windowHeight"] integerValue] ?: 1080;
        // The screen the stream's window will be on: where it was left, else the main one.
        NSScreen* target = NSScreen.mainScreen;
        if (device[@"windowLeft"] != nil && device[@"windowTop"] != nil) {
            NSRect left = NSMakeRect([device[@"windowLeft"] integerValue], [device[@"windowTop"] integerValue] - h, w, h);
            for (NSScreen* screen in NSScreen.screens) {
                NSRect showing = NSIntersectionRect(screen.visibleFrame, left);
                if (showing.size.width >= 200 && showing.size.height >= 100) {
                    target = screen;
                }
            }
        }
        // Pixels for points; with True Pixels only as many as the panel has
        // of them (dynres.cpp does the same sum for the window once it is
        // there, and a different answer here made every such stream start
        // twice and its window grow by a quarter each time).
        CGFloat scale = target.backingScaleFactor ?: 2;
        if (!fixed && [device[@"truePixels"] boolValue]) {
            scale *= dynresScreenPanelScale(target);
        }
        NSInteger pw = fixed ? [device[@"width"] integerValue] ?: 3840 : ((NSInteger)(w * scale + 0.5) & ~1);
        NSInteger ph = fixed ? [device[@"height"] integerValue] ?: 2160 : ((NSInteger)(h * scale + 0.5) & ~1);
        NSString* rule = [device[@"fpsRule"] length] > 0 ? device[@"fpsRule"] : linux ? @"11059200:50:60" : @"8294400:40:60";
        NSArray<NSString*>* parts = [rule componentsSeparatedByString:@":"];
        NSInteger fps = parts.count == 3 ? (pw * ph > [parts[0] integerValue] ? [parts[1] integerValue] : [parts[2] integerValue]) : 60;
        NSInteger askedFps = [device[@"fps"] integerValue] ?: [NSUserDefaults.standardUserDefaults integerForKey:@"FrameRate"];
        if (askedFps > 0) {
            fps = askedFps; // asked for by a link, or in Settings > Quality
            rule = [NSString stringWithFormat:@"0:%ld:%ld", (long)fps, (long)fps];
        }

        NSMutableArray* arguments = [NSMutableArray arrayWithArray:@[@"stream", at, @"Desktop", @"--resolution", [NSString stringWithFormat:@"%ldx%ld", (long)pw, (long)ph],
                                                                     @"--fps", [NSString stringWithFormat:@"%ld", (long)fps],
                                                                     @"--absolute-mouse", @"--capture-system-keys", @"always", @"--quit-after", @"--no-vsync"]];
        // The device's own bitrate, else the one in Settings > Quality, else Moonlight's by size.
        NSInteger kbps = [device[@"bitrate"] integerValue] ?: [NSUserDefaults.standardUserDefaults integerForKey:@"Bitrate"];
        if (kbps > 0) {
            [arguments addObjectsFromArray:@[@"--bitrate", [NSString stringWithFormat:@"%ld", (long)kbps]]];
        }
        NSMutableDictionary* environment = [NSMutableDictionary dictionary];
        environment[@"MOONLIGHT_CHROME"] = linux ? @"linux" : @"1";
        environment[@"MOONLIGHT_DEVICE"] = deviceId(deviceName);
        environment[@"MOONLIGHT_FPS_ABOVE"] = rule;
        environment[@"MOONLIGHT_WINDOW"] = [NSString stringWithFormat:@"%ldx%ld", (long)w, (long)h];
        if (device[@"windowLeft"] != nil && device[@"windowTop"] != nil) {
            // where its window was left the last time: its left edge and its top
            environment[@"MOONLIGHT_WINDOW_AT"] = [NSString stringWithFormat:@"%ld,%ld", (long)[device[@"windowLeft"] integerValue], (long)[device[@"windowTop"] integerValue]];
        }
        if ([device[@"sizeOnce"] boolValue]) environment[@"MOONLIGHT_WINDOW_ONCE"] = @"1";
        if (fixed) environment[@"MOONLIGHT_FOLLOW"] = @"0";
        if (!fixed && [device[@"truePixels"] boolValue]) environment[@"MOONLIGHT_PANEL_PIXELS"] = @"1";
        if ([device[@"rawColor"] boolValue]) environment[@"MOONLIGHT_RAW_COLOR"] = @"1";
        if ([device[@"noSound"] boolValue]) environment[@"MOONLIGHT_NO_SOUND"] = @"1";
        if ([device[@"clipboard"] length] > 0) environment[@"MOONLIGHT_CLIPBOARD"] = device[@"clipboard"];
        if ([device[@"localCursor"] boolValue]) environment[@"MOONLIGHT_LOCAL_CURSOR"] = @"1";
        [self launch:arguments environment:environment for:deviceName];
    };

    if ([device[@"before"] length] == 0) {
        go(device[@"address"]);
        return;
    }
    // MOONLIGHT_POINTER tells the command whether this Mac will draw the
    // pointer (Instant pointer): a host that cannot say so by itself must then
    // keep its cursor out of the picture (see pc-wake in dotfiles).
    NSString* command = [NSString stringWithFormat:@"export MOONLIGHT_POINTER=%d; %@", [device[@"localCursor"] boolValue] ? 1 : 0, device[@"before"]];
    runShell(command, 8, ^(NSData* output) {
        // An address on the last line it printed is where to go instead.
        NSString* text = [[[NSString alloc] initWithData:output ?: [NSData data] encoding:NSUTF8StringEncoding] autorelease];
        NSString* last = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"].lastObject;
        NSCharacterSet* notAddress = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:"] invertedSet];
        bool isAddress = last.length > 2 && last.length < 64 && [last rangeOfCharacterFromSet:notAddress].location == NSNotFound;
        go(isAddress ? last : device[@"address"]);
    });
}

- (void)pair:(id)sender
{
    NSDictionary* device = [self device];
    if ([device[@"address"] length] > 0) {
        // Moonlight's own pairing: it shows the PIN to type in on the host.
        [self launch:@[@"pair", device[@"address"]] environment:@{} for:nil];
    }
}

- (void)classic:(id)sender
{
    [self launch:@[] environment:@{@"MOONLIGHT_CLASSIC": @"1"} for:nil];
}

- (void)check:(id)sender
{
    NSString* deviceName = [self device][@"name"];
    if (deviceName != nil) {
        chromeSettingsDoctor(deviceName.UTF8String);
    }
}

- (void)settings:(id)sender
{
    chromeSettingsOpen([[self device][@"name"] UTF8String] ?: "");
}

// ---- links: moonlightnext://connect/<device>?size=1920x1080&fixed=3840x2160&truepixels=1&raw=1&pointer=0&bitrate=20000&fps=60
//      moonlightnext://show (this window) and moonlightnext://settings. What a link says holds for that one stream; the device's own settings stay.

- (BOOL)open:(NSURL*)url
{
    [self reread];
    NSURLComponents* parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if ([parts.host isEqualToString:@"settings"]) {
        [self settings:nil];
        return NO;
    }
    if (![parts.host isEqualToString:@"connect"]) {
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return NO;
    }
    NSString* wanted = parts.path.length > 1 ? [parts.path substringFromIndex:1] : @"";
    NSMutableDictionary* device = nil;
    // By name first, then by address or the name Moonlight has for it. (A
    // device added by hand has no such name, and comparing against nothing
    // would call it a match.)
    for (NSString* key in @[@"name", @"address", @"host"]) {
        for (NSDictionary* each in s_Devices) {
            NSString* value = each[key];
            if (device == nil && wanted.length > 0 && value.length > 0 && [value caseInsensitiveCompare:wanted] == NSOrderedSame) {
                device = withPlacement(each);
            }
        }
    }
    if (device == nil) {
        NSAlert* alert = [[[NSAlert alloc] init] autorelease];
        alert.messageText = [NSString stringWithFormat:@"No device called “%@”", wanted];
        alert.informativeText = @"A link names a device as it is called in the list, or by its address.";
        [window makeKeyAndOrderFront:nil];
        [alert beginSheetModalForWindow:window completionHandler:nil];
        return NO;
    }
    // A link comes from anywhere: whole numbers only, and within what a stream can be.
    NSInteger (^number)(NSString*, NSInteger, NSInteger) = ^NSInteger(NSString* text, NSInteger least, NSInteger most) {
        if (text.length == 0 || text.length > 6 || [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) {
            return -1;
        }
        NSInteger value = text.integerValue;
        return value >= least && value <= most ? value : -1;
    };
    for (NSURLQueryItem* item in parts.queryItems) {
        NSArray<NSString*>* size = [item.value.lowercaseString componentsSeparatedByString:@"x"];
        NSInteger w = size.count == 2 ? number(size[0], 320, 8192) : -1, h = size.count == 2 ? number(size[1], 200, 8192) : -1;
        bool isSize = w > 0 && h > 0;
        bool on = [item.value isEqualToString:@"1"] || [item.value isEqualToString:@"on"] || [item.value isEqualToString:@"true"];
        if ([item.name isEqualToString:@"size"] && isSize) {
            device[@"windowWidth"] = @(w);
            device[@"windowHeight"] = @(h);
            device[@"sizeOnce"] = @YES; // for this stream only: not to be remembered as the device's
        }
        else if ([item.name isEqualToString:@"fixed"]) {
            device[@"fixed"] = @(isSize || on);
            if (isSize) {
                device[@"width"] = @(w);
                device[@"height"] = @(h);
            }
        }
        else if ([item.name isEqualToString:@"truepixels"]) device[@"truePixels"] = @(on);
        else if ([item.name isEqualToString:@"raw"]) device[@"rawColor"] = @(on);
        else if ([item.name isEqualToString:@"pointer"]) device[@"localCursor"] = @(on);
        else if ([item.name isEqualToString:@"bitrate"]) {
            NSInteger kbps = [item.value isEqualToString:@"0"] ? 0 : number(item.value, 500, 500000);
            if (kbps >= 0) device[@"bitrate"] = @(kbps);
        }
        else if ([item.name isEqualToString:@"fps"]) {
            NSInteger rate = number(item.value, 10, 240);
            if (rate > 0) device[@"fps"] = @(rate);
        }
    }
    [self start:device];
    return YES;
}

// ---- building the window

- (NSTextField*)field:(NSString*)placeholder
{
    NSTextField* field = [NSTextField textFieldWithString:@""];
    field.placeholderString = placeholder;
    field.delegate = self;
    field.target = self;
    field.action = @selector(changed:);
    field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return field;
}

- (NSButton*)check:(NSString*)text tip:(NSString*)tip
{
    NSButton* button = [NSButton checkboxWithTitle:text target:self action:@selector(changed:)];
    button.toolTip = tip;
    return button;
}

- (void)build
{
    statuses = [[NSMutableDictionary alloc] init];
    pictures = [[NSMutableDictionary alloc] init];
    pictureTimes = [[NSMutableDictionary alloc] init];
    running = [[NSMutableSet alloc] init];
    starting = [[NSMutableSet alloc] init];
    waiting = [[NSMutableDictionary alloc] init];
    asking = [[NSMutableDictionary alloc] init];
    launched = [[NSMutableDictionary alloc] init];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(streamShown:) name:@"dev.eduwass.moonlight-next.shown" object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(streamUp:) name:@"dev.eduwass.moonlight-next.up" object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(streamGone:) name:@"dev.eduwass.moonlight-next.gone" object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 940, 700)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                                                   NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                                           backing:NSBackingStoreBuffered defer:NO];
    window.title = NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"Moonlight";
    window.titlebarAppearsTransparent = YES;
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.minSize = NSMakeSize(820, 640);
    [window setFrameAutosaveName:@"Manager"];

    NSSplitViewController* split = [[[NSSplitViewController alloc] init] autorelease];

    // The list, as a sidebar.
    NSViewController* side = [[[NSViewController alloc] init] autorelease];
    NSView* sideView = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 230, 700)] autorelease];
    side.view = sideView;
    NSScrollView* scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 36, 230, 664 - 44)] autorelease];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    table.style = NSTableViewStyleSourceList;
    table.headerView = nil;
    table.rowHeight = 40;
    table.backgroundColor = NSColor.clearColor;
    NSTableColumn* column = [[[NSTableColumn alloc] initWithIdentifier:@"device"] autorelease];
    column.resizingMask = NSTableColumnAutoresizingMask;
    column.width = 190;
    [table addTableColumn:column];
    table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.doubleAction = @selector(connect:); // as in any list of things to open
    scroll.documentView = table;
    [sideView addSubview:scroll];

    NSButton* plus = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"Add a device"] target:self action:@selector(add:)];
    NSButton* minus = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"minus" accessibilityDescription:@"Remove the device"] target:self action:@selector(remove:)];
    NSPopUpButton* more = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES] autorelease];
    [more addItemWithTitle:@""];
    more.itemArray.firstObject.image = [NSImage imageWithSystemSymbolName:@"ellipsis.circle" accessibilityDescription:@"More"];
    [more addItemWithTitle:@"Settings…"];
    more.lastItem.target = self;
    more.lastItem.action = @selector(settings:);
    [more addItemWithTitle:@"Pair This Device…"];
    more.lastItem.target = self;
    more.lastItem.action = @selector(pair:);
    [more addItemWithTitle:@"Classic Moonlight…"];
    more.lastItem.target = self;
    more.lastItem.action = @selector(classic:);
    CGFloat x = 8;
    for (NSButton* button in @[plus, minus, more]) {
        button.bordered = NO;
        button.frame = NSMakeRect(x, 6, button == more ? 44 : 26, 24);
        [sideView addSubview:button];
        x += button == more ? 44 : 28;
    }
    NSSplitViewItem* sideItem = [NSSplitViewItem sidebarWithViewController:side];
    sideItem.minimumThickness = 200;
    sideItem.maximumThickness = 300;
    sideItem.canCollapse = NO;
    [split addSplitViewItem:sideItem];

    // The selected device.
    NSViewController* main = [[[NSViewController alloc] init] autorelease];
    detail = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 710, 700)];
    NSView* holder = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 710, 700)] autorelease];
    detail.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [holder addSubview:detail];
    main.view = holder;
    [split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:main]];

    picture = [[[NSImageView alloc] init] autorelease];
    picture.imageScaling = NSImageScaleProportionallyUpOrDown;
    picture.wantsLayer = YES;
    picture.layer.backgroundColor = [NSColor.blackColor colorWithAlphaComponent:0.25].CGColor;
    picture.layer.cornerRadius = 8;
    picture.layer.masksToBounds = YES;
    spinner = [[[NSProgressIndicator alloc] init] autorelease];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    pictureNote = label(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSButton* again = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Get a new picture"] target:self action:@selector(refresh:)];
    again.bordered = NO;
    again.toolTip = @"Get a new picture of its screen";
    NSStackView* noteRow = [NSStackView stackViewWithViews:@[spinner, pictureNote, again]];
    noteRow.spacing = 6;

    title = label(@"", 20, NSFontWeightSemibold, NSColor.labelColor);
    statusLine = label(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    statusLine.lineBreakMode = NSLineBreakByTruncatingTail;
    [statusLine setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    connect = [NSButton buttonWithTitle:@"Connect" target:self action:@selector(connect:)];
    connect.keyEquivalent = @"\r";
    connect.controlSize = NSControlSizeLarge;
    NSStackView* names = [NSStackView stackViewWithViews:@[title, statusLine]];
    names.orientation = NSUserInterfaceLayoutOrientationVertical;
    names.alignment = NSLayoutAttributeLeading;
    names.spacing = 2;
    endStream = [NSButton buttonWithTitle:@"End Stream" target:self action:@selector(end:)];
    endStream.controlSize = NSControlSizeLarge;
    endStream.hidden = YES;
    NSButton* check = [NSButton buttonWithTitle:@"Check Link" target:self action:@selector(check:)];
    check.controlSize = NSControlSizeLarge;
    check.toolTip = @"Have the doctor look at the way to this device and say what it can carry";
    NSStackView* head = [NSStackView stackViewWithViews:@[names, check, endStream, connect]];
    head.distribution = NSStackViewDistributionFill;
    [names setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    name = [self field:@"What to call it"];
    address = [self field:@"Address or name on the network"];
    system = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
    [system addItemsWithTitles:@[@"macOS", @"Linux"]];
    system.target = self;
    system.action = @selector(changed:);
    size = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
    [size addItemsWithTitles:@[@"Follows the window", @"Fixed, scaled to fit"]];
    size.target = self;
    size.action = @selector(changed:);
    size.toolTip = @"Follows the window: the stream always has the window's pixels, and restarts when you resize it.\nFixed: the stream keeps this size in pixels and is scaled to fit the window, with black bands where the shapes differ.";
    width = [self field:@"width"];
    height = [self field:@"height"];
    [width.widthAnchor constraintEqualToConstant:64].active = YES;
    [height.widthAnchor constraintEqualToConstant:64].active = YES;
    NSStackView* sizeRow = [NSStackView stackViewWithViews:@[size, width, label(@"×", 13, NSFontWeightRegular, NSColor.secondaryLabelColor), height]];
    truePixels = [self check:@"True Pixels" tip:@"The stream has as many pixels as the monitor's panel, not as many as macOS draws. Faster on a scaled display."];
    rawColor = [self check:@"Raw colours" tip:@"Show the device's colour values as they are, as its own cable to this monitor would. For a desktop tuned by eye on this monitor."];
    localCursor = [self check:@"Instant pointer" tip:@"This Mac draws the pointer itself, so it moves with the hand. A Mac with the cursor helper shows its own cursor shapes; a Hyprland PC set up for it shows a plain arrow."];
    noSound = [self check:@"No sound" tip:@"Do not play the device's sound here, and do not open this Mac's sound output for the stream. For a device that sends none, or whose sound reaches you another way."];
    NSStackView* checks = [NSStackView stackViewWithViews:@[truePixels, rawColor, localCursor, noSound]];
    checks.spacing = 16;
    bitrate = [self field:@"automatic"];
    [bitrate.widthAnchor constraintEqualToConstant:90].active = YES;
    NSStackView* bitrateRow = [NSStackView stackViewWithViews:@[bitrate, label(@"kbps. Leave empty to let Moonlight choose; lower it on a weak connection.", 11, NSFontWeightRegular, NSColor.secondaryLabelColor)]];
    screenshot = [self field:@"A shell command that writes a picture of its screen to stdout"];
    before = [self field:@"A shell command to run first: wake it, unlock it (optional)"];
    clipboard = [self field:@"me@its-name: share the clipboard with it over ssh (optional)"];

    NSGridView* form = [NSGridView gridViewWithViews:@[
        @[label(@"Name", 13, NSFontWeightRegular, NSColor.labelColor), name],
        @[label(@"Address", 13, NSFontWeightRegular, NSColor.labelColor), address],
        @[label(@"System", 13, NSFontWeightRegular, NSColor.labelColor), system],
        @[label(@"Stream size", 13, NSFontWeightRegular, NSColor.labelColor), sizeRow],
        @[label(@"", 13, NSFontWeightRegular, NSColor.labelColor), checks],
        @[label(@"Bitrate", 13, NSFontWeightRegular, NSColor.labelColor), bitrateRow],
        @[label(@"Screenshot", 13, NSFontWeightRegular, NSColor.labelColor), screenshot],
        @[label(@"Before connecting", 13, NSFontWeightRegular, NSColor.labelColor), before],
        @[label(@"Clipboard", 13, NSFontWeightRegular, NSColor.labelColor), clipboard],
    ]];
    form.rowSpacing = 8;
    form.columnSpacing = 10;
    [form columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    form.rowAlignment = NSGridRowAlignmentFirstBaseline;

    NSStackView* column0 = [NSStackView stackViewWithViews:@[picture, noteRow, head, form]];
    column0.orientation = NSUserInterfaceLayoutOrientationVertical;
    column0.alignment = NSLayoutAttributeLeading;
    column0.spacing = 12;
    [column0 setCustomSpacing:6 afterView:picture];
    [column0 setCustomSpacing:18 afterView:noteRow];
    [column0 setCustomSpacing:18 afterView:head];
    column0.translatesAutoresizingMaskIntoConstraints = NO;
    [detail addSubview:column0];
    [NSLayoutConstraint activateConstraints:@[
        [column0.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor constant:24],
        [column0.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor constant:-24],
        [column0.topAnchor constraintEqualToAnchor:detail.topAnchor constant:44],
        [column0.bottomAnchor constraintLessThanOrEqualToAnchor:detail.bottomAnchor constant:-20],
        [picture.widthAnchor constraintEqualToAnchor:column0.widthAnchor],
        [picture.heightAnchor constraintEqualToAnchor:picture.widthAnchor multiplier:9.0 / 21.0],
        [head.widthAnchor constraintEqualToAnchor:column0.widthAnchor],
        [form.widthAnchor constraintEqualToAnchor:column0.widthAnchor],
    ]];
    [picture setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [picture setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    window.contentViewController = split;
    [window setContentSize:NSMakeSize(940, 700)];
    [window layoutIfNeeded];
    if (![window setFrameUsingName:@"Manager"]) {
        [window center];
    }

    [table reloadData];
    if (s_Devices.count > 0) {
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
    [self show];
    [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

@end

NSArray* managerDevices()
{
    if (s_Devices == nil) {
        loadDevices();
    }
    return s_Devices;
}

// The devices as they are saved now: another process may have changed them
// since this one read them (the app's window and each stream are processes of
// their own), and saving an old copy back would undo that.
static void rereadDevices()
{
    NSArray* saved = [NSUserDefaults.standardUserDefaults arrayForKey:k_Devices];
    if (saved == nil) {
        return;
    }
    if (s_Devices == nil) {
        s_Devices = [[NSMutableArray alloc] init];
    }
    [s_Devices removeAllObjects];
    for (NSDictionary* each in saved) {
        [s_Devices addObject:[[each mutableCopy] autorelease]];
    }
}

void managerSetDeviceWindow(NSString* name, long left, long top, long width, long height)
{
    if (s_Manager == nil) {
        rereadDevices(); // a stream's process: the device window's is the one that edits
    }
    for (NSMutableDictionary* device in managerDevices()) {
        if ([device[@"name"] isEqualToString:name]) {
            device[@"windowLeft"] = @(left);
            device[@"windowTop"] = @(top);
            if (width > 0 && height > 0) {
                device[@"windowWidth"] = @(width);
                device[@"windowHeight"] = @(height);
            }
        }
    }
    saveDevices();
}

void managerSetDeviceBitrate(NSString* name, long kbps)
{
    if (s_Manager == nil) {
        rereadDevices();
    }
    for (NSMutableDictionary* device in managerDevices()) {
        if ([device[@"name"] isEqualToString:name]) {
            device[@"bitrate"] = @(kbps);
        }
    }
    saveDevices();
    [s_Manager show];
}

static bool s_OpenedByLink;
static NSDate* s_StartedAt;
static NSDate* s_LinkAt; // when the last link to a device came

// This process's environment without what was set for one stream: a process
// started from here must not take another device's switches for its own.
static NSMutableDictionary* plainEnvironment()
{
    NSMutableDictionary* all = [[NSProcessInfo.processInfo.environment mutableCopy] autorelease];
    for (NSString* key in @[@"DEVICE", @"CHROME", @"FPS_ABOVE", @"WINDOW", @"WINDOW_AT", @"WINDOW_ONCE", @"FOLLOW", @"PANEL_PIXELS",
                            @"RAW_COLOR", @"LOCAL_CURSOR", @"CLIPBOARD", @"OPEN_URL", @"CLASSIC", @"NO_SOUND"]) {
        [all removeObjectForKey:[@"MOONLIGHT_" stringByAppendingString:key]];
    }
    [all removeObjectForKey:@"SDL_AUDIODRIVER"]; // set in a stream's process for MOONLIGHT_NO_SOUND, see main.cpp
    return all;
}

// The process with the app's own window holds this lock for as long as it
// runs. That is how another process knows there is one (and that it need not
// start one), also while that one is still starting and not yet listening.
static int managerLock()
{
    NSString* path = [[pictureFile(@"x") URLByDeletingLastPathComponent].path stringByAppendingPathComponent:@"manager.lock"];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        fd = -1;
    }
    return fd;
}

// Passes a link to the process that holds the lock: said again every half
// second until it answers that it has it (it may still be starting), for
// five seconds at most.
@interface LinkPasser : NSObject {
@public
    NSString* link;
    int tries;
    bool thenQuit;
}
@end

@implementation LinkPasser
- (void)say
{
    if (tries++ >= 10) {
        NSLog(@"MoonlightNext: nobody took the link %@", link);
        [self done:nil];
        return;
    }
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"dev.eduwass.moonlight-next.open" object:link
                                                                userInfo:nil deliverImmediately:YES];
    [self performSelector:@selector(say) withObject:nil afterDelay:0.5];
}
- (void)done:(NSNotification*)note
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(say) object:nil];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
    if (thenQuit) {
        exit(0);
    }
    [link release];
    [self autorelease];
}
@end

static void passLink(NSString* link, bool thenQuit)
{
    LinkPasser* passer = [[LinkPasser alloc] init]; // lets go of itself in done:
    passer->link = [link copy];
    passer->thenQuit = thenQuit;
    [NSDistributedNotificationCenter.defaultCenter addObserver:passer selector:@selector(done:) name:@"dev.eduwass.moonlight-next.opened" object:link
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [passer say];
}

// As it finishes launching, AppKit goes through the main menu to add its text
// input items, and on macOS 15 it first loads the Writing Tools library to see
// whether those belong there: 0.48 to 0.56 s on the main thread of every
// process of the app, measured, before it does anything of its own (a stream's
// process cannot ask its host for anything meanwhile). The app has no use for
// Writing Tools, so the question is answered here.
// ponytail: the method asked is AppKit's own (+[NSTextView _supportsWritingTools]);
// if a later macOS has no such method this does nothing and the half second is
// back, nothing else. The public defaults that take Dictation and Emoji out of
// the menu do not stop the library being loaded (tried).
void managerBeforeLaunch()
{
    Method asked = class_getClassMethod(NSTextView.class, NSSelectorFromString(@"_supportsWritingTools"));
    if (asked != nullptr && strcmp(method_getTypeEncoding(asked) ?: "", "B16@0:8") == 0) {
        method_setImplementation(asked, imp_implementationWithBlock(^BOOL(id) { return NO; }));
    }
}

// The menu is made again whenever the list of devices is saved or read again,
// and not when the Dock asks for it: as the menu's delegate, filling it at
// that moment, the app was "not responding" to the Dock (tried).
static NSMenu* s_DockMenu;

static void dockMenuChanged()
{
    if (s_Manager != nil && s_DockMenu != nil) {
        [s_Manager fillDockMenu:s_DockMenu];
    }
}

void managerAlert(const char* text)
{
    NSAlert* alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"The stream could not be started";
    alert.informativeText = @(text) ?: @"";
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

void managerForwardUrl(const char* url)
{
    NSString* link = @(url);
    int fd = managerLock();
    if (fd < 0) {
        passLink(link, false); // there is one
        return;
    }
    // There is none: start one, with the link. (Two streams doing this at
    // once start two; the second finds the lock taken, passes its link on to
    // the first and goes: see managerStart.)
    close(fd);
    NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    NSMutableDictionary* environment = plainEnvironment();
    environment[@"MOONLIGHT_OPEN_URL"] = link; // read in managerStart
    configuration.environment = environment;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration completionHandler:nil];
}

void managerStart()
{
    // Started for a link while another process already has the app's window:
    // the link is that one's, and this process is not needed.
    static int lock = -1;
    lock = managerLock();
    if (lock < 0 && getenv("MOONLIGHT_OPEN_URL") != nullptr) {
        passLink(@(getenv("MOONLIGHT_OPEN_URL")), true);
        return;
    }
    s_StartedAt = [[NSDate date] retain];
    loadDevices();
    s_Manager = [[ManagerController alloc] init];
    [s_Manager build];
    // A link that came to a stream's process is passed on: by a notification
    // if this process was there, in the environment if it was started for it.
    [NSDistributedNotificationCenter.defaultCenter addObserver:s_Manager selector:@selector(passedOn:) name:@"dev.eduwass.moonlight-next.open" object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    if (getenv("MOONLIGHT_OPEN_URL") != nullptr) {
        NSString* link = @(getenv("MOONLIGHT_OPEN_URL"));
        unsetenv("MOONLIGHT_OPEN_URL");
        dispatch_async(dispatch_get_main_queue(), ^{
            managerOpenUrl(link.UTF8String);
        });
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    // Settings… with ⌘, in the app's menu, where a Mac app has it. (Qt makes
    // that menu when its loop starts, so this waits a turn.)
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMenu* appMenu = NSApp.mainMenu.itemArray.firstObject.submenu;
        // Qt keeps a hidden Preferences item there that already owns ⌘, : make
        // that one ours rather than add a second the key never reaches.
        NSMenuItem* item = nil;
        for (NSMenuItem* each in appMenu.itemArray) {
            if ([each.keyEquivalent isEqualToString:@","]) {
                item = each;
            }
        }
        if (item == nil && appMenu != nil) {
            item = [[[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@","] autorelease];
            [appMenu insertItem:item atIndex:MIN(1, appMenu.numberOfItems)];
        }
        item.title = @"Settings…";
        item.target = s_Manager;
        item.action = @selector(settings:);
        item.hidden = NO;
        item.enabled = YES;
        // The devices in the Dock icon's menu. Qt's application delegate hands
        // the Dock the menu it is given with setDockMenu:.
        // ponytail: that is Qt's own class (QCocoaApplicationDelegate); if a
        // later Qt has no such method, there is no such menu and nothing else changes.
        id delegate = NSApp.delegate;
        if ([delegate respondsToSelector:NSSelectorFromString(@"setDockMenu:")]) {
            s_DockMenu = [[NSMenu alloc] init];
            [s_Manager fillDockMenu:s_DockMenu];
            [delegate performSelector:NSSelectorFromString(@"setDockMenu:") withObject:s_DockMenu];
        }
    });
    // Started by a link to a device, the app shows that device's stream and
    // not this window (the Dock icon brings it up). macOS says which kind of
    // start this is when the app has finished launching.
    static bool shown;
    void (^showWindow)(void) = ^{
        if (!shown && !s_OpenedByLink) {
            shown = true;
            [s_Manager->window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
        }
    };
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* note) {
        // The event that started the app: "open this link", or plain "open".
        NSAppleEventDescriptor* event = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
        if (!(event.eventClass == kInternetEventClass && event.eventID == kAEGetURL)) {
            showWindow();
        }
    }];
    // If that never comes, or the link was not one to a device.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), showWindow);
}

void managerOpenUrl(const char* url)
{
    NSURL* parsed = [NSURL URLWithString:@(url)];
    if (s_Manager != nil && parsed != nil && [s_Manager open:parsed]) {
        // The app was started for this link if it has only just started:
        // then its own window is not what was asked for.
        if (!s_OpenedByLink && -s_StartedAt.timeIntervalSinceNow < 4) {
            [s_Manager->window orderOut:nil];
        }
        s_OpenedByLink = true;
        [s_LinkAt release];
        s_LinkAt = [[NSDate date] retain];
    }
}

void managerShow()
{
    // Not for the activation that comes with a link to a device: that asks
    // for the device's stream, not for this window. The link may arrive just
    // after the activation, so wait a moment before deciding.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (s_LinkAt == nil || -s_LinkAt.timeIntervalSinceNow > 2) {
            [s_Manager->window makeKeyAndOrderFront:nil];
        }
    });
    return;
    [s_Manager->window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
