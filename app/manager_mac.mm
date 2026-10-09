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
//   truePixels, rawColor, localCursor
//   fpsRule                "pixels:above:below", see dynres.cpp (MOONLIGHT_FPS_ABOVE)
//   bitrate                kbps, 0 for Moonlight's own choice
//   screenshot             a shell command that writes a picture of the device's screen to stdout
//   before                 a shell command run before connecting (wake, unlock); if its last line of
//                          output is an address, the stream goes there instead

#include "manager.h"

#import <Cocoa/Cocoa.h>

void chromeSettingsOpen(const char* host);

static NSString* const k_Devices = @"Devices";
static NSString* const k_MoonlightSuite = @"com.moonlight-stream.Moonlight";

static NSMutableArray<NSMutableDictionary*>* s_Devices;

static void saveDevices()
{
    [NSUserDefaults.standardUserDefaults setObject:s_Devices forKey:k_Devices];
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
                                 @"windowWidth": @1920, @"windowHeight": @1080, @"localCursor": @NO} mutableCopy] autorelease]];
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
    NSTextField* bitrate;
    NSTextField* screenshot;
    NSTextField* before;
    NSMutableDictionary<NSString*, DeviceStatus*>* statuses; // by address
    NSMutableDictionary<NSString*, NSImage*>* pictures;       // by device name
    NSMutableDictionary<NSString*, NSDate*>* pictureTimes;
    NSMutableSet<NSString*>* running; // the devices with a stream open or warm, as of the last look
    NSButton* endStream;
    int shooting; // screenshots on their way
}
@end

@interface ManagerController ()
- (void)show;
@end

static ManagerController* s_Manager;

static NSTextField* label(NSString* text, CGFloat size, NSFontWeight weight, NSColor* colour)
{
    NSTextField* field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = colour;
    return field;
}

// Runs a shell command off the main thread; hands back what it printed.
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
        NSData* output = nil;
        if ([task launchAndReturnError:nil]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (task.running) {
                    [task terminate];
                }
            });
            output = [out.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            done(output);
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
    bitrate.stringValue = [device[@"bitrate"] integerValue] > 0 ? [device[@"bitrate"] stringValue] : @"";
    screenshot.stringValue = device[@"screenshot"] ?: @"";
    before.stringValue = device[@"before"] ?: @"";

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
        [table reloadData];
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
    [self ask];
    [self shoot:NO];
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
    if (fixed == wasFixed && width.integerValue >= 320 && height.integerValue >= 200) {
        device[fixed ? @"width" : @"windowWidth"] = @(width.integerValue);
        device[fixed ? @"height" : @"windowHeight"] = @(height.integerValue);
    }
    device[@"truePixels"] = @(truePixels.state == NSControlStateValueOn);
    device[@"rawColor"] = @(rawColor.state == NSControlStateValueOn);
    device[@"localCursor"] = @(localCursor.state == NSControlStateValueOn);
    device[@"bitrate"] = @(MAX(0, bitrate.integerValue));
    device[@"screenshot"] = screenshot.stringValue;
    device[@"before"] = before.stringValue;
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
    [s_Devices addObject:[[@{@"name": @"New device", @"address": @"", @"system": @"mac", @"windowWidth": @1920, @"windowHeight": @1080} mutableCopy] autorelease]];
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

- (void)launch:(NSArray<NSString*>*)arguments environment:(NSDictionary<NSString*, NSString*>*)environment for:(NSString*)deviceName
{
    NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    configuration.arguments = arguments;
    NSMutableDictionary* all = [[NSProcessInfo.processInfo.environment mutableCopy] autorelease];
    [all addEntriesFromDictionary:environment];
    configuration.environment = all;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration
                                    completionHandler:^(NSRunningApplication* app, NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (app != nil && deviceName != nil) {
                [running addObject:deviceName];
            }
            connect.enabled = YES;
            [table reloadData];
            [self show];
        });
    }];
}

- (void)connect:(id)sender
{
    [self start:[self device]];
}

// Starts the stream of a device, or brings its window forward if it is open.
- (void)start:(NSDictionary*)asGiven
{
    NSDictionary* device = [[asGiven copy] autorelease];
    NSString* deviceName = device[@"name"];
    if (device == nil || [device[@"address"] length] == 0) {
        return;
    }
    if (streamRuns(deviceName)) {
        tellStream(deviceName, @"show");
        return;
    }
    connect.enabled = NO;
    statusLine.stringValue = [device[@"before"] length] > 0 ? @"Waking it…" : @"Connecting…";

    void (^go)(NSString*) = ^(NSString* at) {
        // Moonlight tries the address it last saw the host at before the one it
        // is given; make them the same (see remote-mbp.sh for how that went wrong).
        NSString* prefix = device[@"host"] != nil ? moonlightHostPrefix(device[@"host"]) : nil;
        if (prefix != nil) {
            NSUserDefaults* moonlight = [[[NSUserDefaults alloc] initWithSuiteName:k_MoonlightSuite] autorelease];
            [moonlight setObject:at forKey:[prefix stringByAppendingString:@"localaddress"]];
            [moonlight setObject:at forKey:[prefix stringByAppendingString:@"manualaddress"]];
        }

        bool fixed = [device[@"fixed"] boolValue], linux = [device[@"system"] isEqualToString:@"linux"];
        CGFloat scale = window.screen.backingScaleFactor ?: 2;
        NSInteger w = [device[@"windowWidth"] integerValue] ?: 1920, h = [device[@"windowHeight"] integerValue] ?: 1080;
        NSInteger pw = fixed ? [device[@"width"] integerValue] ?: 3840 : (NSInteger)(w * scale);
        NSInteger ph = fixed ? [device[@"height"] integerValue] ?: 2160 : (NSInteger)(h * scale);
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
        if (fixed) environment[@"MOONLIGHT_FOLLOW"] = @"0";
        if (!fixed && [device[@"truePixels"] boolValue]) environment[@"MOONLIGHT_PANEL_PIXELS"] = @"1";
        if ([device[@"rawColor"] boolValue]) environment[@"MOONLIGHT_RAW_COLOR"] = @"1";
        if ([device[@"localCursor"] boolValue]) environment[@"MOONLIGHT_LOCAL_CURSOR"] = @"1";
        [self launch:arguments environment:environment for:deviceName];
    };

    if ([device[@"before"] length] == 0) {
        go(device[@"address"]);
        return;
    }
    runShell(device[@"before"], 8, ^(NSData* output) {
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

- (void)settings:(id)sender
{
    chromeSettingsOpen([[self device][@"name"] UTF8String] ?: "");
}

// ---- links: moonlightnext://connect/<device>?size=1920x1080&fixed=3840x2160&truepixels=1&raw=1&pointer=0&bitrate=20000&fps=60
//      moonlightnext://show (this window) and moonlightnext://settings. What a link says holds for that one stream; the device's own settings stay.

- (BOOL)open:(NSURL*)url
{
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
    for (NSDictionary* each in s_Devices) {
        if ([each[@"name"] caseInsensitiveCompare:wanted] == NSOrderedSame || [each[@"address"] caseInsensitiveCompare:wanted] == NSOrderedSame ||
                [each[@"host"] caseInsensitiveCompare:wanted] == NSOrderedSame) {
            device = [[each mutableCopy] autorelease];
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
    for (NSURLQueryItem* item in parts.queryItems) {
        NSArray<NSString*>* size = [item.value.lowercaseString componentsSeparatedByString:@"x"];
        bool isSize = size.count == 2 && size[0].integerValue >= 320 && size[1].integerValue >= 200;
        bool on = item.value.boolValue || [item.value isEqualToString:@"on"];
        if ([item.name isEqualToString:@"size"] && isSize) {
            device[@"windowWidth"] = @(size[0].integerValue);
            device[@"windowHeight"] = @(size[1].integerValue);
        }
        else if ([item.name isEqualToString:@"fixed"]) {
            device[@"fixed"] = @(isSize || on);
            if (isSize) {
                device[@"width"] = @(size[0].integerValue);
                device[@"height"] = @(size[1].integerValue);
            }
        }
        else if ([item.name isEqualToString:@"truepixels"]) device[@"truePixels"] = @(on);
        else if ([item.name isEqualToString:@"raw"]) device[@"rawColor"] = @(on);
        else if ([item.name isEqualToString:@"pointer"]) device[@"localCursor"] = @(on);
        else if ([item.name isEqualToString:@"bitrate"]) device[@"bitrate"] = @(MAX(0, item.value.integerValue));
        else if ([item.name isEqualToString:@"fps"]) device[@"fps"] = @(MAX(0, item.value.integerValue));
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

    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 940, 700)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                                                   NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                                           backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Moonlight";
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
    NSStackView* head = [NSStackView stackViewWithViews:@[names, endStream, connect]];
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
    localCursor = [self check:@"Instant pointer" tip:@"This Mac draws the pointer itself, so it moves with the hand. Needs the cursor helper on the device (macOS hosts)."];
    NSStackView* checks = [NSStackView stackViewWithViews:@[truePixels, rawColor, localCursor]];
    checks.spacing = 16;
    bitrate = [self field:@"automatic"];
    [bitrate.widthAnchor constraintEqualToConstant:90].active = YES;
    NSStackView* bitrateRow = [NSStackView stackViewWithViews:@[bitrate, label(@"kbps. Leave empty to let Moonlight choose; lower it on a weak connection.", 11, NSFontWeightRegular, NSColor.secondaryLabelColor)]];
    screenshot = [self field:@"A shell command that writes a picture of its screen to stdout"];
    before = [self field:@"A shell command to run first: wake it, unlock it (optional)"];

    NSGridView* form = [NSGridView gridViewWithViews:@[
        @[label(@"Name", 13, NSFontWeightRegular, NSColor.labelColor), name],
        @[label(@"Address", 13, NSFontWeightRegular, NSColor.labelColor), address],
        @[label(@"System", 13, NSFontWeightRegular, NSColor.labelColor), system],
        @[label(@"Stream size", 13, NSFontWeightRegular, NSColor.labelColor), sizeRow],
        @[label(@"", 13, NSFontWeightRegular, NSColor.labelColor), checks],
        @[label(@"Bitrate", 13, NSFontWeightRegular, NSColor.labelColor), bitrateRow],
        @[label(@"Screenshot", 13, NSFontWeightRegular, NSColor.labelColor), screenshot],
        @[label(@"Before connecting", 13, NSFontWeightRegular, NSColor.labelColor), before],
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

void managerSetDeviceBitrate(NSString* name, long kbps)
{
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

void managerStart()
{
    s_StartedAt = [[NSDate date] retain];
    loadDevices();
    s_Manager = [[ManagerController alloc] init];
    [s_Manager build];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
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
