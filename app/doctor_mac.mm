// Fork-only (eduwass/moonlight-qt): two panes of the settings window
// (streaming/chrome_settings_mac.mm), made of stock controls.
//
// Quality: what streams started from now on ask for. The codec, 4:4:4 and HDR
// are Moonlight's own settings; the bitrate and frame rate are this app's
// ("Bitrate" in kbps and "FrameRate", 0 for automatic) and are given to each
// stream as it starts, unless the device has its own.
//
// Doctor: looks at the way to one device (which kind of link, how fast and how
// steady it answers, what a Wi-Fi link can carry) and says what to ask of it.
// It measures the link, not a stream: the numbers of a running stream are on
// its bar.

#include "manager.h"

#import <Cocoa/Cocoa.h>
#import <CoreWLAN/CoreWLAN.h>

#include <arpa/inet.h>
#include <netdb.h>
#include <signal.h>

static NSString* const k_MoonlightSuite = @"com.moonlight-stream.Moonlight";

static NSTextField* note(NSString* text)
{
    NSTextField* field = [NSTextField wrappingLabelWithString:text];
    field.font = [NSFont systemFontOfSize:11];
    field.textColor = NSColor.secondaryLabelColor;
    return field;
}

static NSTextField* caption(NSString* text)
{
    NSTextField* field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:13];
    return field;
}

// ---- Quality

@interface QualityPane : NSView {
    NSSegmentedControl* preset;
    NSPopUpButton* bitrateKind;
    NSTextField* bitrate;
    NSPopUpButton* frameRate;
    NSPopUpButton* codec;
    NSButton* yuv444;
    NSButton* hdr;
}
@end

@implementation QualityPane

- (BOOL)isFlipped { return YES; }

- (void)show
{
    NSUserDefaults* ours = NSUserDefaults.standardUserDefaults;
    NSUserDefaults* moonlight = [[[NSUserDefaults alloc] initWithSuiteName:k_MoonlightSuite] autorelease];
    NSInteger kbps = [ours integerForKey:@"Bitrate"], fps = [ours integerForKey:@"FrameRate"];
    [bitrateKind selectItemAtIndex:kbps > 0 ? 1 : 0];
    bitrate.enabled = kbps > 0;
    bitrate.stringValue = kbps > 0 ? [NSString stringWithFormat:@"%g", kbps / 1000.0] : @"";
    [frameRate selectItemAtIndex:fps == 30 ? 2 : fps == 60 ? 1 : 0];
    NSInteger video = [moonlight integerForKey:@"videocfg"];
    [codec selectItemAtIndex:video == 1 ? 1 : video == 2 ? 2 : video == 4 ? 3 : 0];
    yuv444.state = [moonlight boolForKey:@"yuv444"];
    hdr.state = [moonlight boolForKey:@"hdr"];
    preset.selectedSegment = kbps == 0 && fps == 0 ? 0 : kbps == 40000 && fps == 0 ? 1 : kbps == 15000 && fps == 30 ? 2 : -1;
}

// The settings as they are saved now: another of the app's processes (the
// device window, another stream) may have changed them since this was shown,
// and the next change made here writes every control's value.
- (void)refresh
{
    [self show];
}

- (void)changed:(id)sender
{
    NSUserDefaults* ours = NSUserDefaults.standardUserDefaults;
    NSUserDefaults* moonlight = [[[NSUserDefaults alloc] initWithSuiteName:k_MoonlightSuite] autorelease];
    if (sender == preset) {
        static const NSInteger kbps[] = {0, 40000, 15000}, fps[] = {0, 0, 30};
        [ours setInteger:kbps[preset.selectedSegment] forKey:@"Bitrate"];
        [ours setInteger:fps[preset.selectedSegment] forKey:@"FrameRate"];
    }
    else {
        double mbps = bitrate.doubleValue;
        if (bitrateKind.indexOfSelectedItem == 1 && mbps < 0.5) {
            mbps = 20; // "Custom" just chosen: a start to change from
        }
        [ours setInteger:bitrateKind.indexOfSelectedItem == 1 ? (NSInteger)(MIN(mbps, 500) * 1000) : 0 forKey:@"Bitrate"];
        static const NSInteger rates[] = {0, 60, 30};
        [ours setInteger:rates[frameRate.indexOfSelectedItem] forKey:@"FrameRate"];
        static const NSInteger codecs[] = {0, 1, 2, 4}; // Moonlight's VideoCodecConfig
        [moonlight setInteger:codecs[codec.indexOfSelectedItem] forKey:@"videocfg"];
        [moonlight setBool:yuv444.state == NSControlStateValueOn forKey:@"yuv444"];
        [moonlight setBool:hdr.state == NSControlStateValueOn forKey:@"hdr"];
    }
    [self show];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    preset = [NSSegmentedControl segmentedControlWithLabels:@[@"Cable", @"Wi-Fi", @"Away"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changed:)];
    preset.toolTip = @"Cable: no limits. Wi-Fi: at most 40 Mbps. Away: at most 15 Mbps and 30 frames a second.";
    bitrateKind = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
    [bitrateKind addItemsWithTitles:@[@"Automatic, by the stream's size", @"At most"]];
    bitrate = [NSTextField textFieldWithString:@""];
    [bitrate.widthAnchor constraintEqualToConstant:60].active = YES;
    frameRate = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
    [frameRate addItemsWithTitles:@[@"Automatic, by the stream's size", @"60 a second", @"30 a second"]];
    codec = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
    [codec addItemsWithTitles:@[@"Automatic", @"H.264", @"HEVC", @"AV1"]];
    yuv444 = [NSButton checkboxWithTitle:@"4:4:4 colour" target:self action:@selector(changed:)];
    hdr = [NSButton checkboxWithTitle:@"HDR" target:self action:@selector(changed:)];
    for (NSControl* control in @[bitrateKind, bitrate, frameRate, codec]) {
        control.target = self;
        control.action = @selector(changed:);
    }
    NSStackView* bitrateRow = [NSStackView stackViewWithViews:@[bitrateKind, bitrate, caption(@"Mbps")]];
    NSGridView* grid = [NSGridView gridViewWithViews:@[
        @[caption(@"Connection"), preset],
        @[caption(@"Bitrate"), bitrateRow],
        @[caption(@"Frame rate"), frameRate],
        @[caption(@"Video codec"), codec],
        @[caption(@""), yuv444],
        @[caption(@""), note(@"Sharper coloured text, about half as much data again. The device must be able to send it.")],
        @[caption(@""), hdr],
        @[caption(@""), note(@"These hold for streams started from now on. A device's own bitrate, if it has one, comes first. "
                              "The doctor measures the way to a device and says what it can carry.")],
    ]];
    grid.rowSpacing = 10;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [grid.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-4],
        [grid.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
    ]];
    [self show];
    return self;
}

@end

// ---- Doctor

// What a tool printed by the time limit. The limit holds whatever the tool
// does: a child of it that keeps the pipe open is not waited for.
static NSString* runTool(NSString* path, NSArray<NSString*>* arguments, NSTimeInterval limit)
{
    NSTask* task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSPipe* out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) {
        return @"";
    }
    NSMutableData* output = [NSMutableData data];
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
    NSString* text;
    @synchronized (output) {
        text = [[[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] autorelease];
    }
    return text ?: @"";
}

static NSString* firstMatch(NSString* text, NSString* pattern)
{
    NSRegularExpression* expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult* match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match != nil && match.numberOfRanges > 1 ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}

// What the doctor found. kbps is what it would ask of the link, 0 for no limit.
struct Diagnosis {
    NSMutableArray<NSArray*>* lines; // (mark 0 good / 1 mind / 2 bad, text)
    NSInteger kbps;
    NSString* advice;
};

static Diagnosis examine(NSDictionary* device)
{
    Diagnosis d = {[NSMutableArray array], -1, @""}; // -1: nothing found out that a bitrate could be advised from
    NSString* host = device[@"address"];

    // Where it is.
    struct addrinfo hints = {}, *found = nullptr;
    hints.ai_family = AF_INET;
    char ip[INET_ADDRSTRLEN] = "";
    if (host.length == 0 || getaddrinfo(host.UTF8String, nullptr, &hints, &found) != 0 || found == nullptr) {
        [d.lines addObject:@[@2, [NSString stringWithFormat:@"“%@” does not resolve to an address.", host]]];
        d.advice = @"Check the device's address, and that this Mac is on its network or on Tailscale.";
        return d;
    }
    inet_ntop(AF_INET, &((struct sockaddr_in*)found->ai_addr)->sin_addr, ip, sizeof(ip));
    freeaddrinfo(found);
    NSString* address = @(ip);

    // By which way.
    NSString* interface = firstMatch(runTool(@"/sbin/route", @[@"-n", @"get", address], 3), @"interface: (\\S+)") ?: @"?";
    CWInterface* wifi = CWWiFiClient.sharedWiFiClient.interface;
    bool onWifi = [interface isEqualToString:wifi.interfaceName];
    bool tailscale = [interface hasPrefix:@"utun"];
    bool bridge = [interface hasPrefix:@"bridge"];
    double carries = 0; // Mbps the link can be trusted with, 0 for plenty
    if (bridge) {
        [d.lines addObject:@[@0, [NSString stringWithFormat:@"The way to %@ is over %@, a direct cable (Thunderbolt bridge).", address, interface]]];
    }
    else if (onWifi) {
        double rate = wifi.transmitRate;
        NSInteger signal = wifi.rssiValue, noise = wifi.noiseMeasurement;
        NSString* band = wifi.wlanChannel.channelBand == kCWChannelBand5GHz ? @"5 GHz" : wifi.wlanChannel.channelBand == kCWChannelBand6GHz ? @"6 GHz" : @"2.4 GHz";
        [d.lines addObject:@[@(signal < -72 || rate < 100 ? 1 : 0),
                             [NSString stringWithFormat:@"The way to %@ is over Wi-Fi (%@): %@, link rate %.0f Mbps, signal %ld dBm, noise %ld dBm.",
                              address, interface, band, rate, (long)signal, (long)noise]]];
        // Half the link rate is what gets through on a good day; a stream should take well under that.
        carries = rate * 0.5;
        if (signal < -72) {
            [d.lines addObject:@[@1, @"The signal is weak; move closer to the access point or use a cable."]];
        }
    }
    else if (tailscale) {
        NSString* status = runTool(@"/Applications/Tailscale.app/Contents/MacOS/Tailscale", @[@"status", @"--json"], 4);
        NSDictionary* json = status.length > 0 ? [NSJSONSerialization JSONObjectWithData:[status dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        bool relayed = false, known = false;
        for (NSDictionary* peer in [json[@"Peer"] allValues]) {
            if ([peer[@"TailscaleIPs"] containsObject:address]) {
                known = true;
                relayed = [peer[@"CurAddr"] length] == 0;
            }
        }
        [d.lines addObject:@[@(relayed ? 2 : 1), [NSString stringWithFormat:@"The way to %@ is through Tailscale (%@)%@.", address, interface,
                              !known ? @"" : relayed ? @", relayed through a Tailscale server" : @", directly"]]];
        if (relayed) {
            carries = 10;
        }
        else if (wifi.transmitRate > 0 && wifi.interfaceName != nil) {
            carries = wifi.transmitRate * 0.4; // this Mac's own radio is very likely part of the way
        }
    }
    else {
        [d.lines addObject:@[@0, [NSString stringWithFormat:@"The way to %@ is over %@ (wired).", address, interface]]];
    }

    // How fast and how steadily it answers.
    NSString* ping = runTool(@"/sbin/ping", @[@"-c", @"25", @"-i", @"0.2", @"-q", address], 12);
    NSString* lossText = firstMatch(ping, @"([0-9.]+)% packet loss");
    NSString* times = firstMatch(ping, @"= ([0-9./]+) ms");
    NSArray<NSString*>* t = [times componentsSeparatedByString:@"/"];
    double loss = lossText != nil ? lossText.doubleValue : 100, average = t.count == 4 ? t[1].doubleValue : 0, worst = t.count == 4 ? t[2].doubleValue : 0,
           spread = t.count == 4 ? t[3].doubleValue : 0;
    if (t.count != 4) {
        [d.lines addObject:@[@2, @"It does not answer a ping. Asleep, off, or a firewall in the way."]];
    }
    else {
        [d.lines addObject:@[@(loss >= 1 || average >= 30 || spread >= 10 ? 2 : loss > 0 || average >= 5 || spread >= 4 ? 1 : 0),
                             [NSString stringWithFormat:@"25 pings: %.1f ms on average, %.1f at worst, spread %.1f ms, %.0f%% lost.", average, worst, spread, loss]]];
    }

    // Whether the streaming host is there.
    NSDate* sent = [NSDate date];
    NSData* info = [NSData dataWithContentsOfURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://%@:47989/serverinfo", address]] options:0 error:nil];
    NSString* body = info != nil ? [[[NSString alloc] initWithData:info encoding:NSUTF8StringEncoding] autorelease] : @"";
    if (![body containsString:@"<hostname>"]) {
        [d.lines addObject:@[@2, @"Sunshine does not answer on port 47989. Is it running on the device?"]];
        d.advice = @"Start Sunshine on the device, then run the doctor again.";
        return d;
    }
    [d.lines addObject:@[@0, [NSString stringWithFormat:@"Sunshine answers in %.0f ms%@.", -sent.timeIntervalSinceNow * 1000,
                              [body containsString:@"SERVER_FREE"] ? @"" : @"; a stream is open on it now"]]];

    // What to ask of it.
    bool shaky = loss >= 1 || spread >= 10 || average >= 30;
    if (carries == 0 && !shaky) {
        d.kbps = 0;
        d.advice = @"A good link. Leave the bitrate automatic; any size at 60 frames a second.";
    }
    else {
        double mbps = carries == 0 ? 20 : MAX(5, MIN(80, carries * 0.6));
        if (shaky) {
            mbps = MIN(mbps, 15);
        }
        d.kbps = (NSInteger)(round(mbps / 5) * 5 * 1000);
        d.advice = [NSString stringWithFormat:@"Ask for at most %ld Mbps%@.", (long)(d.kbps / 1000),
                    mbps <= 15 ? @", a fixed size of 2560 × 1440 or less, and 30 frames a second if it still stutters"
                    : mbps < 40 ? @"; up to 3840 × 2160 should hold at 60 frames a second" : @"; any size up to 5120 × 2160 should hold at 60 frames a second"];
    }
    return d;
}

@interface DoctorPane : NSView {
    NSPopUpButton* which;
    NSButton* run;
    NSButton* apply;
    NSProgressIndicator* spinner;
    NSTextView* report;
    NSInteger suggested;
    bool checking;
    NSString* examined;
}
- (void)examine:(NSString*)device;
@end

@implementation DoctorPane

- (BOOL)isFlipped { return YES; }

- (void)fill
{
    NSString* selected = [[which.titleOfSelectedItem retain] autorelease];
    [which removeAllItems];
    for (NSDictionary* device in managerDevices()) {
        [which addItemWithTitle:device[@"name"] ?: @"?"];
    }
    if (selected != nil) {
        [which selectItemWithTitle:selected];
    }
    run.enabled = which.numberOfItems > 0 && !checking;
}

- (void)viewDidMoveToWindow
{
    [self fill];
}

- (void)layout
{
    [super layout];
    // As wide as what shows of it, so that lines wrap short of the scroller.
    NSScrollView* scroll = report.enclosingScrollView;
    [report setFrameSize:NSMakeSize(scroll.contentSize.width, report.frame.size.height)];
}

- (NSDictionary*)device
{
    for (NSDictionary* device in managerDevices()) {
        if ([device[@"name"] isEqualToString:which.titleOfSelectedItem]) {
            return device;
        }
    }
    return nil;
}

- (void)run:(id)sender
{
    NSDictionary* device = [[[self device] copy] autorelease];
    if (device == nil) {
        return;
    }
    if (checking) {
        return; // one at a time: two would finish in any order, and the report be either's
    }
    checking = true;
    run.enabled = NO;
    apply.hidden = YES;
    [spinner startAnimation:nil];
    report.string = @"Measuring the way there. About eight seconds…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The way a stream would take: a device's "before connecting" command
        // may say where to go (see manager_mac.mm), and wakes the device.
        NSMutableDictionary* asStreamed = [[device mutableCopy] autorelease];
        if ([device[@"before"] length] > 0) {
            NSString* said = [runTool(@"/bin/sh", @[@"-c", device[@"before"]], 8) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString* last = [said componentsSeparatedByString:@"\n"].lastObject;
            NSCharacterSet* notAddress = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:"] invertedSet];
            if (last.length > 2 && last.length < 64 && ![last hasPrefix:@"-"] && [last rangeOfCharacterFromSet:notAddress].location == NSNotFound) {
                asStreamed[@"address"] = last;
            }
        }
        Diagnosis d = examine(asStreamed);
        NSMutableAttributedString* text = [[[NSMutableAttributedString alloc] init] autorelease];
        NSDictionary* plain = @{NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: NSColor.labelColor};
        for (NSArray* line in d.lines) {
            NSInteger mark = [line[0] integerValue];
            NSColor* colour = mark == 0 ? NSColor.systemGreenColor : mark == 1 ? NSColor.systemYellowColor : NSColor.systemRedColor;
            [text appendAttributedString:[[[NSAttributedString alloc] initWithString:mark == 0 ? @"✓  " : mark == 1 ? @"!  " : @"✕  "
                                                                          attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightBold],
                                                                                       NSForegroundColorAttributeName: colour}] autorelease]];
            [text appendAttributedString:[[[NSAttributedString alloc] initWithString:[line[1] stringByAppendingString:@"\n\n"] attributes:plain] autorelease]];
        }
        [text appendAttributedString:[[[NSAttributedString alloc] initWithString:d.advice
                                                                      attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                                                                                   NSForegroundColorAttributeName: NSColor.labelColor}] autorelease]];
        NSInteger kbps = d.kbps;
        dispatch_async(dispatch_get_main_queue(), ^{
            [report.textStorage setAttributedString:text];
            [spinner stopAnimation:nil];
            checking = false;
            run.enabled = YES;
            suggested = kbps;
            [examined release];
            examined = [device[@"name"] retain];
            NSInteger has = [device[@"bitrate"] integerValue];
            apply.hidden = kbps < 0 || has == kbps;
            apply.title = kbps > 0 ? [NSString stringWithFormat:@"Set %@ to at most %ld Mbps", examined, (long)(kbps / 1000)]
                                   : [NSString stringWithFormat:@"Set %@ back to automatic", examined];
        });
    });
}

- (void)refresh
{
    [self fill]; // devices added, renamed or removed since
}

- (void)examine:(NSString*)device
{
    [self fill];
    if ([which itemWithTitle:device] != nil && run.enabled) {
        [which selectItemWithTitle:device];
        [self run:nil];
    }
}

- (void)apply:(id)sender
{
    managerSetDeviceBitrate(examined, suggested);
    apply.hidden = YES;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    which = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
    run = [NSButton buttonWithTitle:@"Examine" target:self action:@selector(run:)];
    spinner = [[[NSProgressIndicator alloc] init] autorelease];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    NSStackView* top = [NSStackView stackViewWithViews:@[caption(@"Device"), which, run, spinner]];

    NSScrollView* scroll = [[[NSScrollView alloc] init] autorelease];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    report = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 470, 300)] autorelease];
    report.editable = NO;
    report.drawsBackground = NO;
    report.textContainerInset = NSMakeSize(0, 4);
    report.autoresizingMask = NSViewWidthSizable;
    report.string = @"Pick a device and press Examine. The doctor looks at the way from this Mac to it: which kind of link, "
                    "how fast and how steadily it answers, and what a Wi-Fi link can carry. Then it says what to ask of it.";
    report.font = [NSFont systemFontOfSize:12];
    report.textColor = NSColor.secondaryLabelColor;
    scroll.documentView = report;

    apply = [NSButton buttonWithTitle:@"Apply" target:self action:@selector(apply:)];
    apply.hidden = YES;

    NSStackView* all = [NSStackView stackViewWithViews:@[top, scroll, apply]];
    all.orientation = NSUserInterfaceLayoutOrientationVertical;
    all.alignment = NSLayoutAttributeLeading;
    all.spacing = 14;
    all.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:all];
    [NSLayoutConstraint activateConstraints:@[
        [all.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [all.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [all.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [scroll.widthAnchor constraintEqualToAnchor:all.widthAnchor],
        [scroll.heightAnchor constraintEqualToConstant:330],
    ]];
    [self fill];
    return self;
}

@end

// ---- General

@interface GeneralPane : NSView {
    NSPopUpButton* warm;
}
@end

@implementation GeneralPane
- (BOOL)isFlipped { return YES; }
- (void)changed:(id)sender
{
    [NSUserDefaults.standardUserDefaults setInteger:warm.selectedItem.tag forKey:@"WarmSeconds"];
}
- (void)refresh
{
    [warm selectItemWithTag:[NSUserDefaults.standardUserDefaults integerForKey:@"WarmSeconds"]];
}
- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    warm = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
    NSArray* choices = @[@[@"End the stream", @0], @[@"Keep it warm for 15 minutes", @900], @[@"Keep it warm for an hour", @3600],
                         @[@"Keep it warm for 2 hours", @7200], @[@"Keep it warm for 8 hours", @28800], @[@"Keep it warm until I end it", @-1]];
    for (NSArray* choice in choices) {
        [warm addItemWithTitle:choice[0]];
        warm.lastItem.tag = [choice[1] integerValue];
    }
    [warm selectItemWithTag:[NSUserDefaults.standardUserDefaults integerForKey:@"WarmSeconds"]];
    warm.target = self;
    warm.action = @selector(changed:);
    NSGridView* grid = [NSGridView gridViewWithViews:@[
        @[caption(@"Closing a stream's window"), warm],
        @[caption(@""), note(@"A warm stream goes on out of sight, so its window is back at once: Connect in the device window, a link, or the Dock. "
                              "The device keeps sending picture all that time. End Stream in the device window, or ⌃⌥⇧Q in the stream, ends it for good.")],
        // Which build this is: the fork's commit, as the build script wrote it into the bundle.
        @[caption(@"Build"), note([NSBundle.mainBundle objectForInfoDictionaryKey:@"MoonlightNextBuild"] ?: @"not recorded")],
    ]];
    grid.rowSpacing = 10;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [grid.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-4],
        [grid.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
    ]];
    return self;
}
@end

NSView* settingsGeneralPane(NSRect frame)
{
    return [[[GeneralPane alloc] initWithFrame:frame] autorelease];
}

NSView* settingsQualityPane(NSRect frame)
{
    return [[[QualityPane alloc] initWithFrame:frame] autorelease];
}

NSView* settingsDoctorPane(NSRect frame)
{
    return [[[DoctorPane alloc] initWithFrame:frame] autorelease];
}

// Examines a device at once: for the device window's Check Link.
void settingsDoctorExamine(NSView* pane, NSString* device)
{
    if ([pane isKindOfClass:[DoctorPane class]]) {
        [(DoctorPane*)pane examine:device];
    }
}

// Check Link's examination by itself, from a terminal: what it finds for an
// address and what bitrate it would advise (scripts/check-link.sh <address>).
// Not in the app.
#ifdef DOCTOR_SELFTEST
NSArray* managerDevices() { return @[]; }
void managerSetDeviceBitrate(NSString*, long) {}
int main(int argc, char** argv)
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: check-link <address>\n");
            return 2;
        }
        Diagnosis d = examine(@{@"name": @"selftest", @"address": @(argv[1])});
        for (NSArray* line in d.lines) {
            printf("%s  %s\n", [line[0] integerValue] == 0 ? "ok  " : [line[0] integerValue] == 1 ? "mind" : "bad ", [line[1] UTF8String]);
        }
        printf("advice: %s\nbitrate: %s\n", d.advice.UTF8String, d.kbps < 0 ? "none advised" : d.kbps == 0 ? "automatic" : [NSString stringWithFormat:@"%ld kbps", (long)d.kbps].UTF8String);
        return 0;
    }
}
#endif
