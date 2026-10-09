// Fork-only (eduwass/moonlight-qt): the stream window's own chrome.
//
// With MOONLIGHT_CHROME set the window has no title bar and the stream fills
// it. A small tab hangs from the top centre; resting the pointer on it shows a
// bar over the stream (nothing ever moves or resizes the picture): traffic
// lights, a handle to move the window by, the connection, and four switches.
// Each control explains itself in a tooltip. Design: the Paper file "Moonlight
// window chrome", artboard 27.
//
// The top strip of the picture is the remote machine's menu bar, so the window
// cannot be dragged there (dynresChromeless makes it immovable); the handle
// moves it instead.

#include "chrome.h"
#include "chrome_keys.h"

#include "SDL_compat.h"
#include <SDL_syswm.h>

#import <Cocoa/Cocoa.h>

#include <initializer_list>
#include <set>
#include <vector>

#define BAR_WIDTH 330
#define BAR_HEIGHT 26
#define TAB_WIDTH 56
#define TAB_HEIGHT 10
#define TIP_WIDTH 264
#define SHOW_AFTER 0.3 // the pointer rests on the tab this long before the bar shows
#define HIDE_AFTER 0.5 // the bar stays this long after the pointer has left it

static void (*s_Action)(int);
static ChromeState s_State;
static bool s_Shown;
static NSRect s_WindowedFrame; // where the window was before it went fullscreen
static NSButton* s_Lights[3];
static NSView* s_Content; // the window's content view; ours hang in it

// The bar worked from the keyboard: Ctrl+Option+Shift+B opens it with one
// control ringed, the arrows move the ring, Space acts, Esc gives the keyboard
// back to the remote machine. s_Focus is -1 when the keyboard is not in it.
static int s_Focus = -1;

static NSColor* rgba(uint32_t value)
{
    return [NSColor colorWithSRGBRed:((value >> 24) & 0xFF) / 255.0
                               green:((value >> 16) & 0xFF) / 255.0
                                blue:((value >> 8) & 0xFF) / 255.0
                               alpha:(value & 0xFF) / 255.0];
}

static NSDictionary* text(CGFloat weight, uint32_t colour)
{
    return @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:weight], NSForegroundColorAttributeName: rgba(colour)};
}

@class ChromeBar;
static NSView* s_Tab;
static ChromeBar* s_Bar;
static NSView* s_Tip;

static void showBar(bool show);

// What a tooltip says: lines of text, each with its own look. A line with a
// right-hand part is a measurement row; one with a mark is the verdict.
struct TipLine {
    NSString* left;
    NSString* right;
    NSString* hint; // the limit, shown before an out-of-range value
    CGFloat weight;
    uint32_t colour;
    int mark;       // 0 none, 1 fair, 2 poor
    bool rule;      // a hairline above
    CGFloat gap;    // space above
};

// Which system is at the other end: MOONLIGHT_CHROME=linux says Linux, anything
// else a Mac. The stream protocol does not say, so the launcher does.
static bool s_Linux;

// The remote system's mark, centred on a point: Apple's logo, or for Linux the
// outline Arch uses (the PC runs Omarchy), which reads at this size where a
// penguin would not.
static void drawSystem(NSPoint centre, CGFloat size, uint32_t colour)
{
    if (!s_Linux) {
        NSImage* image = [[NSImage imageWithSystemSymbolName:@"apple.logo" accessibilityDescription:nil]
            imageWithSymbolConfiguration:[[NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium]
                                             configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[rgba(colour)]]]];
        NSSize is = image.size;
        [image drawInRect:NSMakeRect(round(centre.x - is.width / 2), round(centre.y - is.height / 2), is.width, is.height)];
        return;
    }
    CGFloat x = centre.x - size / 2, y = centre.y - size / 2;
    NSBezierPath* arch = [NSBezierPath bezierPath];
    [arch moveToPoint:NSMakePoint(x + size * 0.5, y + size)];
    [arch curveToPoint:NSMakePoint(x, y) controlPoint1:NSMakePoint(x + size * 0.38, y + size * 0.6) controlPoint2:NSMakePoint(x + size * 0.18, y + size * 0.3)];
    [arch curveToPoint:NSMakePoint(x + size * 0.36, y + size * 0.14) controlPoint1:NSMakePoint(x + size * 0.14, y + size * 0.1) controlPoint2:NSMakePoint(x + size * 0.26, y + size * 0.14)];
    [arch curveToPoint:NSMakePoint(x + size * 0.64, y + size * 0.14) controlPoint1:NSMakePoint(x + size * 0.36, y + size * 0.52) controlPoint2:NSMakePoint(x + size * 0.64, y + size * 0.52)];
    [arch curveToPoint:NSMakePoint(x + size, y) controlPoint1:NSMakePoint(x + size * 0.74, y + size * 0.14) controlPoint2:NSMakePoint(x + size * 0.86, y + size * 0.1)];
    [arch curveToPoint:NSMakePoint(x + size * 0.5, y + size) controlPoint1:NSMakePoint(x + size * 0.82, y + size * 0.3) controlPoint2:NSMakePoint(x + size * 0.62, y + size * 0.6)];
    [arch closePath];
    [rgba(colour) setFill];
    [arch fill];
}

static void drawMark(int verdict, NSRect box)
{
    if (verdict == CHROME_FAIR) {
        [rgba(0xFFD60AFF) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:box] fill];
    }
    else if (verdict == CHROME_POOR) {
        // An exclamation mark, so that it does not rest on colour alone.
        CGFloat w = MIN(box.size.width, 2.5), x = NSMidX(box) - w / 2;
        [rgba(0xFF5F57FF) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, NSMinY(box) + w + 1, w, box.size.height - w - 1) xRadius:1 yRadius:1] fill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, NSMinY(box), w, w)] fill];
    }
}

@interface ChromeTip : NSView {
@public
    std::vector<TipLine> lines;
}
@end

@implementation ChromeTip
- (void)dealloc
{
    for (const TipLine& line : lines) {
        [line.left release];
        [line.right release];
        [line.hint release];
    }
    [super dealloc];
}
- (BOOL)isFlipped { return YES; }
- (NSView*)hitTest:(NSPoint)point { return nil; }
- (CGFloat)layout:(BOOL)draw
{
    CGFloat y = 8, inner = self.bounds.size.width - 20;
    for (const TipLine& line : lines) {
        y += line.gap;
        if (line.rule) {
            if (draw) {
                [rgba(0xFFFFFF1F) setFill];
                NSRectFillUsingOperation(NSMakeRect(10, y, inner, 1), NSCompositingOperationSourceOver);
            }
            y += 7;
        }
        CGFloat x = 10;
        if (line.mark != 0) {
            if (draw) {
                drawMark(line.mark, NSMakeRect(x, y + (line.mark == CHROME_POOR ? 4 : 5), 6, line.mark == CHROME_POOR ? 8.5 : 6));
            }
            x += 12;
        }
        NSDictionary* look = text(line.weight, line.colour);
        if (line.right != nil) {
            NSSize size = [line.right sizeWithAttributes:look];
            if (draw) {
                [line.left drawAtPoint:NSMakePoint(x, y) withAttributes:look];
                [line.right drawAtPoint:NSMakePoint(10 + inner - size.width, y) withAttributes:look];
                if (line.hint != nil) {
                    NSDictionary* quiet = text(NSFontWeightRegular, 0x8A8A92FF);
                    NSSize hint = [line.hint sizeWithAttributes:quiet];
                    [line.hint drawAtPoint:NSMakePoint(10 + inner - size.width - 8 - hint.width, y) withAttributes:quiet];
                }
            }
            y += 16;
        }
        else {
            NSRect box = [line.left boundingRectWithSize:NSMakeSize(10 + inner - x, 400)
                                                 options:NSStringDrawingUsesLineFragmentOrigin attributes:look];
            if (draw) {
                [line.left drawWithRect:NSMakeRect(x, y, 10 + inner - x, 400) options:NSStringDrawingUsesLineFragmentOrigin attributes:look];
            }
            y += MAX(16, ceil(box.size.height));
        }
    }
    return y + 8;
}
- (void)drawRect:(NSRect)dirty
{
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:8 yRadius:8];
    [rgba(0x1A1A1EFF) setFill];
    [shape fill];
    [rgba(0xFFFFFF29) setStroke];
    [shape stroke];
    [self layout:YES];
}
@end

// One 24 x 18 button of the bar: a switch, or the connection.
@interface ChromeButton : NSView {
@public
    int action; // what a click does; -1 for the connection, which only informs; -2 for the gear
    bool on, busy, hovered;
    int mark;
    NSString* symbol;
    double symbolValue; // for symbols that take one, such as the Wi-Fi arcs
    NSProgressIndicator* spinner;
}
@end

static void showTip(ChromeButton* button);

@implementation ChromeButton
- (void)updateTrackingAreas
{
    for (NSTrackingArea* area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    [self addTrackingArea:[[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                          owner:self userInfo:nil] autorelease]];
    [super updateTrackingAreas];
}
- (void)mouseEntered:(NSEvent*)event { hovered = true; self.needsDisplay = YES; showTip(self); }
- (void)mouseExited:(NSEvent*)event { hovered = false; self.needsDisplay = YES; showTip(nil); }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)mouseDown:(NSEvent*)event
{
    if (action == -2) {
        chromeSettingsOpen(s_State.host);
    }
    else if (action >= 0 && !busy && s_Action != nullptr) {
        s_Action(action);
    }
}
- (void)drawRect:(NSRect)dirty
{
    bool lit = on && action >= 0;
    [rgba(busy ? 0xFFFFFF8C : lit ? 0xFFFFFFD9 : hovered ? 0xFFFFFF29 : 0xFFFFFF14) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    if (hovered && !lit && !busy) {
        [rgba(0xFFFFFF66) setStroke];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:6 yRadius:6] stroke];
    }

    spinner.hidden = !busy;
    if (busy) {
        [spinner startAnimation:nil];
        return;
    }
    [spinner stopAnimation:nil];

    NSImage* image = nil;
    if (@available(macOS 13.0, *)) {
        if (symbolValue > 0) {
            image = [NSImage imageWithSystemSymbolName:symbol variableValue:symbolValue accessibilityDescription:nil];
        }
    }
    if (image == nil) {
        image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    }
    NSColor* ink = rgba(lit ? 0x1A1A1EFF : action < 0 ? 0xE6E6EAFF : 0xD0D0D6FF);
    image = [image imageWithSymbolConfiguration:[[NSImageSymbolConfiguration configurationWithPointSize:10.5 weight:NSFontWeightSemibold]
                                                    configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[ink, [ink colorWithAlphaComponent:0.25]]]]];
    NSSize size = image.size;
    [image drawInRect:NSMakeRect(round(NSMidX(self.bounds) - size.width / 2), round(NSMidY(self.bounds) - size.height / 2), size.width, size.height)];

    if (mark == CHROME_FAIR) {
        // Cut out of the icon by a ring in the bar's colour.
        [rgba(0x1A1A1EFF) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(17, 11, 7, 7)] fill];
        drawMark(mark, NSMakeRect(18.5, 12.5, 4, 4));
    }
    else if (mark == CHROME_POOR) {
        [rgba(0x1A1A1EFF) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(17.5, 6.5, 6.5, 11.5) xRadius:3 yRadius:3] fill];
        drawMark(mark, NSMakeRect(19.5, 8, 2.5, 8.5));
    }
}
@end

// The handle the window is moved by. performWindowDragWithEvent: is not used:
// the window is not movable, so the move is done by hand.
@interface ChromeHandle : NSView {
    NSPoint grabbedAt, windowAt;
}
@end

@implementation ChromeHandle
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor]; }
- (void)mouseDown:(NSEvent*)event
{
    grabbedAt = NSEvent.mouseLocation;
    windowAt = self.window.frame.origin;
}
- (void)mouseDragged:(NSEvent*)event
{
    NSPoint now = NSEvent.mouseLocation;
    [self.window setFrameOrigin:NSMakePoint(windowAt.x + now.x - grabbedAt.x, windowAt.y + now.y - grabbedAt.y)];
}
- (void)drawRect:(NSRect)dirty
{
    [rgba(0xFFFFFF0F) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    [rgba(0xC4C4CAFF) setFill];
    for (int column = 0; column < 4; column++) {
        for (int row = 0; row < 2; row++) {
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(round((self.bounds.size.width - 22) / 2) + 2 + column * 6 - 1.2, 5 + 1.5 + row * 5 - 1.2, 2.4, 2.4)] fill];
        }
    }
}
@end

@interface ChromeBar : NSView {
@public
    ChromeButton* link;
    ChromeButton* stats;
    ChromeButton* truePixels;
    ChromeButton* follow;
    ChromeButton* fullscreen;
    ChromeButton* gear;
    bool inside;
}
@end

@implementation ChromeBar
- (void)updateTrackingAreas
{
    for (NSTrackingArea* area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    [self addTrackingArea:[[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                          owner:self userInfo:nil] autorelease]];
    [super updateTrackingAreas];
}
- (void)mouseEntered:(NSEvent*)event
{
    inside = true;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(leave) object:nil];
    [self lights:YES];
}
- (void)mouseExited:(NSEvent*)event
{
    inside = false;
    [self lights:NO];
    [self performSelector:@selector(leave) withObject:nil afterDelay:HIDE_AFTER inModes:@[NSRunLoopCommonModes]];
}
- (void)leave
{
    if (!inside && s_Focus < 0) {
        showBar(false);
    }
}
// The traffic lights show their symbols while the pointer is over the group,
// and ask their superview whether it is (an AppKit convention, not public).
- (BOOL)_mouseInGroup:(NSButton*)button { return inside; }
- (void)lights:(BOOL)redraw
{
    for (NSView* view in self.subviews) {
        if ([view isKindOfClass:[NSButton class]]) {
            view.needsDisplay = YES;
        }
    }
}
// Anything on the bar that no control takes stays here, and never reaches the stream.
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)mouseDown:(NSEvent*)event {}
- (void)mouseUp:(NSEvent*)event {}
- (void)mouseDragged:(NSEvent*)event {}
- (void)rightMouseDown:(NSEvent*)event {}
- (void)scrollWheel:(NSEvent*)event {}
- (void)drawRect:(NSRect)dirty
{
    // Drawn by the skin.
}
@end

// The bar's colour, outline and dividers. Opaque: the remote menu bar is right
// underneath, and its icons showing through made the bar hard to read.
@interface ChromeSkin : NSView
@end

@implementation ChromeSkin
- (NSView*)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirty
{
    // Square at the top, where it meets the window's edge; round below.
    NSRect box = NSInsetRect(self.bounds, 0.5, 0);
    box.origin.y += 0.5;
    box.size.height += 10;
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:box xRadius:10 yRadius:10];
    [rgba(0x1A1A1EFF) setFill];
    [shape fill];
    [rgba(0xFFFFFF29) setStroke];
    [shape stroke];
    drawSystem(NSMakePoint(86, 13), 11, 0xC4C4CAFF);

    [rgba(0xFFFFFF24) setFill];
    NSRectFillUsingOperation(NSMakeRect(73, 6, 1, 14), NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(166, 6, 1, 14), NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(291, 6, 1, 14), NSCompositingOperationSourceOver);

    // The keyboard's ring: white, set off from the control by a gap in the bar's colour.
    if (s_Focus >= 0) {
        static const CGFloat lefts[] = {134, 175, 203, 231, 259, 300};
        NSBezierPath* ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(NSMakeRect(lefts[s_Focus], 4, 24, 18), -2.25, -2.25)
                                                             xRadius:8 yRadius:8];
        ring.lineWidth = 1.5;
        [rgba(0xFFFFFFFF) setStroke];
        [ring stroke];
    }
}
@end

// The tab at rest, and the mark beside it when the link is not good. It takes
// no clicks: they belong to the stream underneath.
@interface ChromeTab : NSView
@end

@implementation ChromeTab
- (NSView*)hitTest:(NSPoint)point { return nil; }
- (void)updateTrackingAreas
{
    for (NSTrackingArea* area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    [self addTrackingArea:[[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                          owner:self userInfo:nil] autorelease]];
    [super updateTrackingAreas];
}
- (void)mouseEntered:(NSEvent*)event
{
    // Not while a button is down: that is a drag on the remote desktop passing by.
    if (NSEvent.pressedMouseButtons == 0) {
        [self performSelector:@selector(rested) withObject:nil afterDelay:SHOW_AFTER inModes:@[NSRunLoopCommonModes]];
    }
}
- (void)mouseExited:(NSEvent*)event
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rested) object:nil];
}
- (void)rested { showBar(true); }
- (void)drawRect:(NSRect)dirty
{
    // The view is wider than the tab, to have room for the mark.
    // Dark with a light outline, so that it shows on any picture; the small
    // arrow says there is something to pull down.
    CGFloat left = round((self.bounds.size.width - TAB_WIDTH) / 2), top = self.bounds.size.height;
    NSRect tab = NSMakeRect(left + 0.5, top - TAB_HEIGHT + 0.5, TAB_WIDTH - 1, TAB_HEIGHT + 5);
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:tab xRadius:5 yRadius:5];
    [rgba(0x1A1A1EFF) setFill];
    [shape fill];
    [rgba(0xFFFFFF73) setStroke];
    [shape stroke];

    NSBezierPath* arrow = [NSBezierPath bezierPath];
    CGFloat middle = left + TAB_WIDTH / 2.0, y = top - TAB_HEIGHT / 2.0 + 0.5;
    [arrow moveToPoint:NSMakePoint(middle - 4, y + 1.5)];
    [arrow lineToPoint:NSMakePoint(middle, y - 1.5)];
    [arrow lineToPoint:NSMakePoint(middle + 4, y + 1.5)];
    arrow.lineWidth = 1.5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;
    [rgba(0xFFFFFFE6) setStroke];
    [arrow stroke];
    drawSystem(NSMakePoint(left + 12, y), 7, 0xFFFFFFB3);

    if (s_State.verdict == CHROME_FAIR) {
        drawMark(CHROME_FAIR, NSMakeRect(left + TAB_WIDTH + 4, top - 7, 4, 4));
    }
    else if (s_State.verdict == CHROME_POOR) {
        drawMark(CHROME_POOR, NSMakeRect(left + TAB_WIDTH + 4, top - 8, 2, 6));
    }
}
@end

static NSString* shortcut(int which)
{
    return [NSString stringWithFormat:@"%@ from anywhere", chromeBindingText(which)];
}

static void switchTip(std::vector<TipLine>& lines, NSString* name, NSString* state, NSString* keys)
{
    lines.push_back({name, nil, nil, NSFontWeightSemibold, 0xF2F2F4FF, 0, false, 0});
    lines.push_back({state, nil, nil, NSFontWeightRegular, 0xD6D6DCFF, 0, false, 1});
    if (keys != nil) {
        lines.push_back({keys, nil, nil, NSFontWeightRegular, 0xA0A0A8FF, 0, false, 6});
    }
}

static void fillTip(ChromeButton* button, std::vector<TipLine>& lines)
{
    const ChromeState& s = s_State;
    // From the keyboard the state line says what Space will do, as in the design.
    bool keyboard = s_Focus >= 0;
    if (button == s_Bar->stats) {
        switchTip(lines, @"Stats",
                  keyboard ? (s.stats ? @"On. Space turns it off." : @"Off. Space turns it on.")
                  : s.stats ? @"On. The stream's numbers are shown over the picture." : @"Off.", shortcut(KEY_STATS));
    }
    else if (button == s_Bar->truePixels) {
        switchTip(lines, @"True Pixels",
                  s.busy ? @"The stream restarts at the new size and the picture returns in a moment."
                  : keyboard ? (s.truePixels ? @"On. Space turns it off." : @"Off. Space turns it on.")
                  : s.truePixels ? @"On. The stream has your monitor's real resolution: faster, and all the glass can show."
                  : @"Off. Full 2x Retina: more than the monitor can show, and slower.", shortcut(KEY_TRUE_PIXELS));
    }
    else if (button == s_Bar->follow) {
        switchTip(lines, @"Follow size",
                  keyboard ? (s.followSize ? @"On. Space turns it off." : @"Off. Space turns it on.")
                  : s.followSize ? @"On. The stream restarts at the window's size when you resize it."
                  : @"Off. The stream keeps its size and is scaled to the window.", shortcut(KEY_FOLLOW));
    }
    else if (button == s_Bar->fullscreen) {
        switchTip(lines, @"Fullscreen",
                  keyboard ? (s.fullscreen ? @"On. Space turns it off." : @"Off. Space turns it on.")
                  : s.fullscreen ? @"On." : @"Off.", shortcut(KEY_FULLSCREEN));
    }
    else if (button == s_Bar->gear) {
        lines.push_back({@"Settings", nil, nil, NSFontWeightSemibold, 0xF2F2F4FF, 0, false, 0});
        lines.push_back({@"Shortcuts", nil, nil, NSFontWeightRegular, 0xA0A0A8FF, 0, false, 1});
    }
    else {
        static NSString* const kinds[] = {@"Thunderbolt", @"Ethernet", @"Wi-Fi", @"Tailscale", @"Network"};
        NSString* kind = kinds[s.link];
        if (s.link == CHROME_TAILSCALE) {
            kind = s.relayed ? @"Tailscale · relayed" : @"Tailscale · direct";
        }
        lines.push_back({[NSString stringWithFormat:@"%s · %@", s.host, s_Linux ? @"Linux" : @"macOS"], nil, nil, NSFontWeightSemibold, 0xF2F2F4FF, 0, false, 0});
        lines.push_back({kind, nil, nil, NSFontWeightRegular, 0xD6D6DCFF, 0, false, 1});
        lines.push_back({[NSString stringWithFormat:@"%d × %d · %d fps", s.width, s.height, s.fps], nil, nil, NSFontWeightRegular, 0xA0A0A8FF, 0, false, 6});

        bool slow = s.delayMs >= CHROME_DELAY_FAIR_MS, lossy = s.lostPercent >= CHROME_LOSS_FAIR_PERCENT;
        NSString* verdict = @"Good";
        if (s.verdict != CHROME_GOOD) {
            NSString* why = lossy ? @"packets are being lost" : slow ? @"the network is slow" : @"Tailscale is relaying";
            verdict = [NSString stringWithFormat:@"%@: %@", s.verdict == CHROME_POOR ? @"Poor" : @"Fair", why];
        }
        lines.push_back({verdict, nil, nil, NSFontWeightSemibold, 0xF2F2F4FF, s.verdict, true, 6});

        // A reading out of range is brighter and bolder, with its limit beside it.
        uint32_t quiet = s.verdict == CHROME_GOOD ? 0xD6D6DCFF : 0xA0A0A8FF;
        NSString* delay = [NSString stringWithFormat:@"%d ms", s.delayMs];
        NSString* lost = s.lostPercent < 0.05 ? @"0%" : [NSString stringWithFormat:@"%.1f%%", s.lostPercent];
        TipLine delayLine = {@"Network delay", delay, slow ? [NSString stringWithFormat:@"good is under %d", CHROME_DELAY_FAIR_MS] : nil,
                             slow ? NSFontWeightSemibold : NSFontWeightRegular, slow ? 0xF2F2F4FF : quiet, 0, false, 3};
        TipLine lossLine = {@"Packets lost", lost, lossy ? @"good is under 0.1%" : nil,
                            lossy ? NSFontWeightSemibold : NSFontWeightRegular, lossy ? 0xF2F2F4FF : quiet, 0, false, 3};
        if (lossy) {
            lines.push_back(lossLine);
            lines.push_back(delayLine);
        }
        else {
            lines.push_back(delayLine);
            lines.push_back(lossLine);
        }
        if (s.link == CHROME_TAILSCALE && s.relayed) {
            lines.push_back({@"Path", @"relayed", nil, NSFontWeightSemibold, 0xF2F2F4FF, 0, false, 3});
        }
    }
}

static ChromeButton* s_TipFor;

static void showTip(ChromeButton* button)
{
    s_TipFor = button;
    ChromeTip* tip = (ChromeTip*)s_Tip;
    if (button == nil || !s_Shown) {
        tip.hidden = YES;
        return;
    }
    // The lines outlive this call, so they hold on to their strings.
    for (const TipLine& line : tip->lines) {
        [line.left release];
        [line.right release];
        [line.hint release];
    }
    tip->lines.clear();
    fillTip(button, tip->lines);
    for (const TipLine& line : tip->lines) {
        [line.left retain];
        [line.right retain];
        [line.hint retain];
    }

    NSView* content = s_Bar.superview;
    NSRect anchor = [button convertRect:button.bounds toView:content];
    CGFloat height = [tip layout:NO];
    CGFloat x = round(NSMidX(anchor) - TIP_WIDTH / 2);
    x = MAX(6, MIN(x, content.bounds.size.width - TIP_WIDTH - 6));
    tip.frame = NSMakeRect(x, content.bounds.size.height - 32 - height, TIP_WIDTH, height);
    tip.hidden = NO;
    tip.needsDisplay = YES;
}

static void showBar(bool show)
{
    if (s_Bar == nil || s_Shown == show) {
        return;
    }
    s_Shown = show;
    s_Bar.hidden = !show;
    s_Tab.hidden = show;
    if (!show) {
        showTip(nil);
    }
    // The numbers are only kept fresh while someone can see them.
    if (s_Action != nullptr) {
        s_Action(CHROME_SHOWN);
    }
}

bool chromeHasPointer()
{
    return s_Bar != nil && s_Bar->inside;
}

bool chromeShown()
{
    return s_Shown;
}

static ChromeButton* focused()
{
    ChromeButton* buttons[] = {s_Bar->link, s_Bar->stats, s_Bar->truePixels, s_Bar->follow, s_Bar->fullscreen, s_Bar->gear};
    return s_Focus >= 0 ? buttons[s_Focus] : nil;
}

static void setFocus(int focus)
{
    s_Focus = focus;
    for (NSView* view in s_Bar.subviews) {
        view.needsDisplay = YES;
    }
    if (focus >= 0) {
        showBar(true);
        showTip(focused());
    }
    else if (!s_Bar->inside) {
        showBar(false);
    }
    else {
        showTip(nil);
    }
}

// Keys that are down, by who saw them go down: a release goes where its press
// went, whatever has happened to the bar in between.
static std::set<int> s_KeysOurs, s_KeysRemote;

static bool chromeTakes(int key, bool down, int sdlMods);

bool chromeKey(int key, bool down, int sdlMods)
{
    if (s_Bar == nil) {
        return false;
    }
    if (!down) {
        s_KeysRemote.erase(key);
        return s_KeysOurs.erase(key) != 0;
    }
    if (s_KeysRemote.count(key) && s_Focus >= 0) {
        return true; // held since before the bar took the keyboard, and repeating
    }
    bool ours = chromeTakes(key, down, sdlMods);
    (ours ? s_KeysOurs : s_KeysRemote).insert(key);
    return ours;
}

static bool chromeTakes(int key, bool down, int sdlMods)
{

    int mods = (sdlMods & KMOD_CTRL ? MOD_CTRL : 0) | (sdlMods & KMOD_ALT ? MOD_ALT : 0) |
               (sdlMods & KMOD_SHIFT ? MOD_SHIFT : 0) | (sdlMods & KMOD_GUI ? MOD_CMD : 0);
    for (int which = 0; down && which < KEY_COUNT; which++) {
        ChromeBinding binding = chromeBinding(which);
        if (binding.key != key || binding.mods != mods) {
            continue;
        }
        if (which == KEY_BAR) {
            setFocus(s_Focus >= 0 ? -1 : 1); // again closes it
        }
        else if (which == KEY_INFO) {
            setFocus(s_Focus == 0 ? -1 : 0);
        }
        else if (s_Action != nullptr) {
            static const int actions[] = {0, 0, CHROME_STATS, CHROME_TRUE_PIXELS, CHROME_FOLLOW, CHROME_FULLSCREEN};
            s_Action(actions[which]);
        }
        return true;
    }
    if (s_Focus < 0) {
        return false;
    }

    // The keyboard is in the bar. Modifiers still go to the remote machine: it
    // saw them go down before we took over, and must see them come up.
    switch (key) {
    case SDLK_LCTRL: case SDLK_RCTRL: case SDLK_LSHIFT: case SDLK_RSHIFT:
    case SDLK_LALT: case SDLK_RALT: case SDLK_LGUI: case SDLK_RGUI:
        return false;
    }
    if (down) {
        if (key == SDLK_LEFT || key == SDLK_RIGHT) {
            setFocus((s_Focus + (key == SDLK_LEFT ? 5 : 1)) % 6);
        }
        else if (key == SDLK_SPACE || key == SDLK_RETURN) {
            ChromeButton* button = focused();
            if (button->action == -2) {
                setFocus(-1);
                chromeSettingsOpen(s_State.host);
            }
            else if (button->action >= 0 && !button->busy && s_Action != nullptr) {
                s_Action(button->action);
            }
        }
        else if (key == SDLK_ESCAPE) {
            setFocus(-1);
        }
    }
    return true;
}

static ChromeButton* addButton(ChromeBar* bar, CGFloat x, NSString* symbol, int action)
{
    ChromeButton* button = [[[ChromeButton alloc] initWithFrame:NSMakeRect(x, 4, 24, 18)] autorelease];
    button->symbol = [symbol retain];
    button->action = action;
    button->spinner = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(6, 3, 12, 12)] autorelease];
    button->spinner.style = NSProgressIndicatorStyleSpinning;
    button->spinner.controlSize = NSControlSizeMini;
    button->spinner.displayedWhenStopped = NO;
    button->spinner.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    button->spinner.hidden = YES;
    [button addSubview:button->spinner];
    [bar addSubview:button];
    return button;
}

void chromeStart(SDL_Window* window, void (*action)(int))
{
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_COCOA) {
        return;
    }
    NSWindow* w = info.info.cocoa.window;
    NSView* content = w.contentView;

    // A new session has a new window; whatever hung in the last one went with it.
    [s_Tab release];
    [s_Bar release];
    [s_Tip release];
    s_Action = action;
    s_Linux = getenv("MOONLIGHT_CHROME") != nullptr && strstr(getenv("MOONLIGHT_CHROME"), "linux") != nullptr;
    s_Shown = false;
    s_TipFor = nil;
    s_Focus = -1;
    s_Content = content;
    s_WindowedFrame = NSZeroRect;
    s_KeysOurs.clear();
    s_KeysRemote.clear();
    // Where the window is, for the way back, as it leaves for fullscreen by any route.
    static id watcher;
    if (watcher != nil) {
        [NSNotificationCenter.defaultCenter removeObserver:watcher];
        [watcher release];
    }
    watcher = [[NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillEnterFullScreenNotification object:w queue:nil
                                                           usingBlock:^(NSNotification* note) {
        s_WindowedFrame = ((NSWindow*)note.object).frame;
    }] retain];

    CGFloat top = content.bounds.size.height, middle = round(content.bounds.size.width / 2);
    NSAutoresizingMaskOptions pinned = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;

    // Wider and taller than the tab it draws: easier to rest on, and room for the mark.
    s_Tab = [[ChromeTab alloc] initWithFrame:NSMakeRect(middle - 40, top - 14, 80, 14)];
    s_Tab.autoresizingMask = pinned;

    ChromeBar* bar = [[ChromeBar alloc] initWithFrame:NSMakeRect(middle - round(BAR_WIDTH / 2.0), top - BAR_HEIGHT, BAR_WIDTH, BAR_HEIGHT)];
    bar.autoresizingMask = pinned;
    bar.hidden = YES;

    ChromeSkin* skin = [[[ChromeSkin alloc] initWithFrame:bar.bounds] autorelease];
    [bar addSubview:skin];

    // Real traffic lights, acting on this window like the ones it no longer shows.
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindowButton kinds[] = {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton};
    for (int i = 0; i < 3; i++) {
        NSButton* light = [NSWindow standardWindowButton:kinds[i] forStyleMask:style];
        [light setFrameOrigin:NSMakePoint(12 + i * 20, round((BAR_HEIGHT - light.frame.size.height) / 2) + 1)];
        [bar addSubview:light];
        s_Lights[i] = light;
    }

    [bar addSubview:[[[ChromeHandle alloc] initWithFrame:NSMakeRect(98, 4, 28, 18)] autorelease]];
    bar->link = addButton(bar, 134, @"bolt.fill", -1);
    bar->stats = addButton(bar, 175, @"chart.bar.fill", CHROME_STATS);
    bar->truePixels = addButton(bar, 203, @"square.grid.2x2.fill", CHROME_TRUE_PIXELS);
    bar->follow = addButton(bar, 231, @"arrow.up.right.square", CHROME_FOLLOW);
    bar->fullscreen = addButton(bar, 259, @"arrow.down.left.and.arrow.up.right", CHROME_FULLSCREEN);
    bar->gear = addButton(bar, 300, @"gearshape.fill", -2);
    s_Bar = bar;

    ChromeTip* tip = [[ChromeTip alloc] initWithFrame:NSMakeRect(0, 0, TIP_WIDTH, 60)];
    tip.autoresizingMask = pinned;
    tip.hidden = YES;
    s_Tip = tip;

    chromeRaise();

    // In fullscreen the Mac's own menu bar would slide down over the tab when
    // the pointer reaches the top edge. SDL can keep it away.
    SDL_SetHint("SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY", "0");
}

void chromeRaise()
{
    if (s_Bar == nil) {
        return;
    }
    [s_Content addSubview:s_Tab positioned:NSWindowAbove relativeTo:nil];
    [s_Content addSubview:s_Bar positioned:NSWindowAbove relativeTo:nil];
    [s_Content addSubview:s_Tip positioned:NSWindowAbove relativeTo:nil];
}

// Fullscreen and back leaves the window with a title bar's worth less content
// than it had, and with the lights we put on the bar hidden. Put both right.
void chromeLeftFullscreen()
{
    if (s_Bar == nil) {
        return;
    }
    if (!NSIsEmptyRect(s_WindowedFrame)) {
        [s_Bar.window setFrame:s_WindowedFrame display:YES];
    }
    for (NSButton* light : s_Lights) {
        light.hidden = NO;
        light.needsDisplay = YES;
    }
    chromeRaise();
}

void chromeUpdate(const ChromeState* state)
{
    if (s_Bar == nil) {
        return;
    }
    s_State = *state;

    // A new renderer puts its view on top of ours; go back above it.
    if (s_Content.subviews.lastObject != s_Tip) {
        chromeRaise();
    }
    if (!state->fullscreen && !(s_Bar.window.styleMask & NSWindowStyleMaskFullScreen)) {
        s_WindowedFrame = s_Bar.window.frame;
    }
    s_Tab.hidden = s_Shown;
    s_Tab.needsDisplay = YES;

    static NSString* const symbols[] = {@"bolt.fill", @"cable.connector", @"wifi", @"globe", @"network"};
    ChromeBar* bar = s_Bar;
    [bar->link->symbol release];
    bar->link->symbol = [symbols[state->link] retain];
    // Wi-Fi drops an arc when the link is not good.
    bar->link->symbolValue = state->link == CHROME_WIFI ? (state->verdict == CHROME_GOOD ? 1.0 : state->verdict == CHROME_FAIR ? 0.66 : 0.33) : 0;
    bar->link->mark = state->verdict;
    bar->stats->on = state->stats;
    bar->truePixels->on = state->truePixels;
    bar->truePixels->busy = state->busy;
    bar->follow->on = state->followSize;
    bar->follow->busy = state->busy;
    bar->fullscreen->on = state->fullscreen;
    for (ChromeButton* button : {bar->link, bar->stats, bar->truePixels, bar->follow, bar->fullscreen, bar->gear}) {
        button.needsDisplay = YES;
    }
    if (s_TipFor != nil) {
        showTip(s_TipFor);
    }
}
