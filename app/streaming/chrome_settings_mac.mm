// Fork-only (eduwass/moonlight-qt): the chrome's settings window, opened by
// the gear on the bar. One pane so far, Keys: every action of the bar has its
// own complete shortcut, recorded by clicking it and pressing the new keys.
// A bound shortcut is taken by Moonlight and never reaches the remote machine.
// Design: the Paper file "Moonlight window chrome", artboard 28.

#include "chrome_keys.h"

#include "SDL_compat.h"

static const ChromeBinding k_Defaults[KEY_COUNT] = {
    {'b', MOD_CTRL | MOD_ALT | MOD_SHIFT}, {'i', MOD_CTRL | MOD_ALT | MOD_SHIFT}, {'s', MOD_CTRL | MOD_ALT | MOD_SHIFT},
    {'t', MOD_CTRL | MOD_ALT | MOD_SHIFT}, {'f', MOD_CTRL | MOD_ALT | MOD_SHIFT}, {'x', MOD_CTRL | MOD_ALT | MOD_SHIFT},
};
static NSString* const k_Names[KEY_COUNT] = {@"Show the bar", @"Connection info", @"Stats", @"True Pixels", @"Follow size", @"Fullscreen"};
static NSString* const k_Symbols[KEY_COUNT] = {@"menubar.rectangle", @"bolt.fill", @"chart.bar.fill", @"square.grid.2x2.fill",
                                               @"arrow.up.right.square", @"arrow.down.left.and.arrow.up.right"};
static NSString* const k_Saved = @"ChromeKeys";

static ChromeBinding s_Bindings[KEY_COUNT];

static void load()
{
    static bool loaded;
    if (loaded) {
        return;
    }
    loaded = true;
    memcpy(s_Bindings, k_Defaults, sizeof(s_Bindings));
    NSArray* saved = [NSUserDefaults.standardUserDefaults arrayForKey:k_Saved];
    for (NSUInteger i = 0; saved.count == KEY_COUNT * 2 && i < KEY_COUNT; i++) {
        s_Bindings[i] = {[saved[i * 2] intValue], [saved[i * 2 + 1] intValue]};
    }
}

static void save()
{
    NSMutableArray* saved = [NSMutableArray array];
    for (const ChromeBinding& binding : s_Bindings) {
        [saved addObject:@(binding.key)];
        [saved addObject:@(binding.mods)];
    }
    [NSUserDefaults.standardUserDefaults setObject:saved forKey:k_Saved];
}

ChromeBinding chromeBinding(int which)
{
    load();
    return s_Bindings[which];
}

// The keys of a binding as they are shown, one string per keycap.
static NSArray<NSString*>* caps(ChromeBinding binding)
{
    NSMutableArray* list = [NSMutableArray array];
    if (binding.mods & MOD_CTRL) [list addObject:@"⌃"];
    if (binding.mods & MOD_ALT) [list addObject:@"⌥"];
    if (binding.mods & MOD_SHIFT) [list addObject:@"⇧"];
    if (binding.mods & MOD_CMD) [list addObject:@"⌘"];
    if (binding.key >= SDLK_F1 && binding.key <= SDLK_F12) {
        [list addObject:[NSString stringWithFormat:@"F%d", binding.key - SDLK_F1 + 1]];
    }
    else {
        [list addObject:[[NSString stringWithFormat:@"%C", (unichar)binding.key] uppercaseString]];
    }
    return list;
}

NSString* chromeBindingText(int which)
{
    return [caps(chromeBinding(which)) componentsJoinedByString:@""];
}

static NSColor* rgba(uint32_t value)
{
    return [NSColor colorWithSRGBRed:((value >> 24) & 0xFF) / 255.0 green:((value >> 16) & 0xFF) / 255.0
                                blue:((value >> 8) & 0xFF) / 255.0 alpha:(value & 0xFF) / 255.0];
}

static NSDictionary* text(CGFloat size, CGFloat weight, uint32_t colour)
{
    return @{NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName: rgba(colour)};
}

static void symbol(NSString* name, NSRect box, uint32_t colour, CGFloat size)
{
    NSImage* image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
        imageWithSymbolConfiguration:[[NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium]
                                         configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[rgba(colour)]]]];
    NSSize is = image.size;
    [image drawInRect:NSMakeRect(round(NSMidX(box) - is.width / 2), round(NSMidY(box) - is.height / 2), is.width, is.height)];
}

// One shortcut: shows it as keycaps; clicked, it listens for the next one.
@interface ChromeRecorder : NSView {
@public
    int which;
    bool recording;
    NSString* complaint; // why the last keys were not taken
}
@end

@implementation ChromeRecorder
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)mouseDown:(NSEvent*)event
{
    recording = !recording;
    [complaint release];
    complaint = nil;
    [self.window makeFirstResponder:recording ? self : nil];
    self.needsDisplay = YES;
}
- (BOOL)resignFirstResponder
{
    recording = false;
    self.needsDisplay = YES;
    return YES;
}
- (void)refuse:(NSString*)why
{
    [complaint release];
    complaint = [why retain];
    self.needsDisplay = YES;
}
- (void)take:(NSEvent*)event
{
    if (event.keyCode == 53) { // Esc: leave it as it was
        [self.window makeFirstResponder:nil];
        return;
    }

    int mods = (event.modifierFlags & NSEventModifierFlagControl ? MOD_CTRL : 0) | (event.modifierFlags & NSEventModifierFlagOption ? MOD_ALT : 0) |
               (event.modifierFlags & NSEventModifierFlagShift ? MOD_SHIFT : 0) | (event.modifierFlags & NSEventModifierFlagCommand ? MOD_CMD : 0);
    // The key as it is without any modifier, which is how SDL names it.
    NSString* plain = [[event charactersByApplyingModifiers:0] lowercaseString];
    unichar c = plain.length == 1 ? [plain characterAtIndex:0] : 0;
    int key = 0;
    if (c >= NSF1FunctionKey && c <= NSF12FunctionKey) {
        key = SDLK_F1 + (c - NSF1FunctionKey);
    }
    else if (c > 32 && c < 127) {
        key = c;
    }
    // The number pad's keys have the main row's characters but other key codes in SDL.
    if (key == 0 || (event.modifierFlags & NSEventModifierFlagNumericPad)) {
        [self refuse:@"Use a letter, digit or F-key"];
        return;
    }
    // A bare key, or one with Shift alone, would take typing away from the remote machine.
    if (!(mods & (MOD_CTRL | MOD_ALT | MOD_CMD)) && key < SDLK_F1) {
        [self refuse:@"Add ⌃, ⌥ or ⌘"];
        return;
    }
    for (int other = 0; other < KEY_COUNT; other++) {
        if (other != which && s_Bindings[other].key == key && s_Bindings[other].mods == mods) {
            [self refuse:[NSString stringWithFormat:@"Used by %@", k_Names[other]]];
            return;
        }
    }
    s_Bindings[which] = {key, mods};
    save();
    [self.window makeFirstResponder:nil];
}
- (void)keyDown:(NSEvent*)event
{
    if (recording) {
        [self take:event];
    }
    else {
        [super keyDown:event];
    }
}
// Shortcuts with Command come this way first.
- (BOOL)performKeyEquivalent:(NSEvent*)event
{
    if (!recording) {
        return NO;
    }
    [self take:event];
    return YES;
}
- (void)drawRect:(NSRect)dirty
{
    if (recording) {
        NSString* words = complaint ?: @"Press a shortcut…";
        NSDictionary* look = text(12, NSFontWeightRegular, complaint ? 0xECECECFF : 0xA3A1A8FF);
        CGFloat width = ceil([words sizeWithAttributes:look].width) + 20;
        NSRect box = NSMakeRect(self.bounds.size.width - width, 0, width, 26);
        [rgba(0x2B292EFF) setFill];
        NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 1, 1) xRadius:6 yRadius:6];
        [shape fill];
        shape.lineWidth = 2;
        [rgba(0xFFFFFFD9) setStroke];
        [shape stroke];
        [words drawAtPoint:NSMakePoint(NSMinX(box) + 10, 5) withAttributes:look];
        return;
    }

    NSArray<NSString*>* keys = caps(s_Bindings[which]);
    CGFloat width = 14 + keys.count * 22 + (keys.count - 1) * 4;
    NSRect box = NSMakeRect(self.bounds.size.width - width, 0, width, 26);
    [rgba(0x2B292EFF) setFill];
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.5, 0.5) xRadius:6 yRadius:6];
    [shape fill];
    [rgba(0x5F5D64FF) setStroke];
    [shape stroke];
    CGFloat x = NSMinX(box) + 7;
    NSDictionary* look = text(12, NSFontWeightRegular, 0xECECECFF);
    for (NSString* key in keys) {
        [rgba(0x5A585FFF) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, 4, 22, 18) xRadius:4 yRadius:4] fill];
        NSSize size = [key sizeWithAttributes:look];
        [key drawAtPoint:NSMakePoint(round(x + 11 - size.width / 2), 4 + round((18 - size.height) / 2)) withAttributes:look];
        x += 26;
    }
}
@end

// doctor_mac.mm
NSView* settingsGeneralPane(NSRect frame);
NSView* settingsQualityPane(NSRect frame);
NSView* settingsDoctorPane(NSRect frame);

enum { PANE_GENERAL, PANE_QUALITY, PANE_KEYS, PANE_DOCTOR, PANE_COUNT };
static NSString* const k_PaneNames[PANE_COUNT] = {@"General", @"Quality", @"Keys", @"Doctor"};
static NSString* const k_PaneSymbols[PANE_COUNT] = {@"gearshape", @"dial.medium", @"keyboard", @"stethoscope"};

@interface ChromeSettingsView : NSView {
@public
    NSString* host;
    int pane;
    NSMutableArray<NSView*>* keyViews; // the recorders and their button
    NSView* panes[PANE_COUNT];         // the others are views of their own
}
- (void)choose:(int)which;
@end

@implementation ChromeSettingsView
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)mouseDown:(NSEvent*)event
{
    [self.window makeFirstResponder:nil]; // a click elsewhere stops a recording
    NSPoint at = [self convertPoint:event.locationInWindow fromView:nil];
    for (int i = 0; i < PANE_COUNT; i++) {
        if (NSPointInRect(at, NSMakeRect(10, 114 + i * 34, 195, 30))) {
            [self choose:i];
        }
    }
}
- (void)choose:(int)which
{
    pane = which;
    for (NSView* view in keyViews) {
        view.hidden = pane != PANE_KEYS;
    }
    for (int i = 0; i < PANE_COUNT; i++) {
        panes[i].hidden = i != pane;
    }
    self.needsDisplay = YES;
}
- (void)restore:(id)sender
{
    memcpy(s_Bindings, k_Defaults, sizeof(s_Bindings));
    save();
    [self.window makeFirstResponder:nil];
    for (NSView* view in self.subviews) {
        view.needsDisplay = YES;
    }
}
- (void)drawRect:(NSRect)dirty
{
    [rgba(0x2B292EFF) setFill];
    NSRectFill(self.bounds);
    [rgba(0x39373CFF) setFill];
    NSRectFill(NSMakeRect(0, 0, 216, self.bounds.size.height));
    [rgba(0x1F1E21FF) setFill];
    NSRectFill(NSMakeRect(215, 0, 1, self.bounds.size.height));

    // Which app this is, and what it is doing.
    [rgba(0x1F1E21FF) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(18, 56, 36, 36) xRadius:9 yRadius:9] fill];
    symbol(@"moon.fill", NSMakeRect(18, 56, 36, 36), 0xECECECFF, 18);
    [@"Moonlight" drawAtPoint:NSMakePoint(64, 58) withAttributes:text(13, NSFontWeightSemibold, 0xECECECFF)];
    [(host.length > 0 ? host : @"Settings") drawAtPoint:NSMakePoint(64, 76) withAttributes:text(11, NSFontWeightRegular, 0xA3A1A8FF)];

    for (int i = 0; i < PANE_COUNT; i++) {
        CGFloat y = 114 + i * 34;
        if (i == pane) {
            [rgba(0xFFFFFF24) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(10, y, 195, 30) xRadius:6 yRadius:6] fill];
        }
        [rgba(0x636366FF) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(18, y + 5, 20, 20) xRadius:5 yRadius:5] fill];
        symbol(k_PaneSymbols[i], NSMakeRect(18, y + 5, 20, 20), 0xFFFFFFFF, 10);
        [k_PaneNames[i] drawAtPoint:NSMakePoint(46, y + 7) withAttributes:text(13, NSFontWeightMedium, i == pane ? 0xFFFFFFFF : 0xD0D0D6FF)];
    }

    [k_PaneNames[pane] drawAtPoint:NSMakePoint(236, 16) withAttributes:text(15, NSFontWeightSemibold, 0xECECECFF)];
    if (pane != PANE_KEYS) {
        return;
    }
    NSRect card = NSMakeRect(236.5, 52.5, 481, 6 * 44 + 1);
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:card xRadius:8 yRadius:8];
    [rgba(0x343237FF) setFill];
    [shape fill];
    [rgba(0x47454BFF) setStroke];
    [shape stroke];
    for (int row = 0; row < KEY_COUNT; row++) {
        CGFloat y = 53 + row * 44;
        if (row > 0) {
            [rgba(0x47454BFF) setFill];
            NSRectFill(NSMakeRect(237, y, 480, 1));
        }
        symbol(k_Symbols[row], NSMakeRect(249, y + 14, 16, 16), 0xC4C4CAFF, 11);
        [k_Names[row] drawAtPoint:NSMakePoint(275, y + 14) withAttributes:text(13, NSFontWeightRegular, 0xECECECFF)];
    }

    [@"Click a shortcut, then press the new keys. Each action has its own full shortcut. A bound shortcut is taken by Moonlight; the remote Mac never sees it."
        drawWithRect:NSMakeRect(240, 334, 330, 60) options:NSStringDrawingUsesLineFragmentOrigin attributes:text(11, NSFontWeightRegular, 0xA3A1A8FF)];
}
@end

void chromeSettingsOpen(const char* host)
{
    static NSWindow* window;
    load();
    if (window == nil) {
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 740, 620)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                               backing:NSBackingStoreBuffered defer:NO];
        window.titlebarAppearsTransparent = YES;
        window.titleVisibility = NSWindowTitleHidden;
        window.title = @"Moonlight Settings";
        window.releasedWhenClosed = NO;
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        [window standardWindowButton:NSWindowMiniaturizeButton].enabled = NO;
        [window standardWindowButton:NSWindowZoomButton].enabled = NO;

        ChromeSettingsView* view = [[[ChromeSettingsView alloc] initWithFrame:NSMakeRect(0, 0, 740, 620)] autorelease];
        view->keyViews = [[NSMutableArray alloc] init];
        for (int row = 0; row < KEY_COUNT; row++) {
            ChromeRecorder* recorder = [[[ChromeRecorder alloc] initWithFrame:NSMakeRect(506, 53 + row * 44 + 9, 200, 26)] autorelease];
            recorder->which = row;
            [view addSubview:recorder];
            [view->keyViews addObject:recorder];
        }
        view->panes[PANE_GENERAL] = settingsGeneralPane(NSMakeRect(236, 52, 484, 540));
        [view addSubview:view->panes[PANE_GENERAL]];
        view->panes[PANE_QUALITY] = settingsQualityPane(NSMakeRect(236, 52, 484, 540));
        view->panes[PANE_DOCTOR] = settingsDoctorPane(NSMakeRect(236, 52, 484, 540));
        [view addSubview:view->panes[PANE_QUALITY]];
        [view addSubview:view->panes[PANE_DOCTOR]];
        NSButton* restore = [NSButton buttonWithTitle:@"Restore Defaults" target:view action:@selector(restore:)];
        restore.controlSize = NSControlSizeSmall;
        restore.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        [restore sizeToFit];
        [restore setFrameOrigin:NSMakePoint(718 - restore.frame.size.width, 332)];
        [view addSubview:restore];
        [view->keyViews addObject:restore];
        [view choose:PANE_GENERAL];
        window.contentView = view;
        [window center];
    }
    ChromeSettingsView* view = (ChromeSettingsView*)window.contentView;
    [view->host release];
    view->host = [@(host) retain];
    view.needsDisplay = YES;
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
}
