// Fork-only (eduwass/moonlight-qt): what the window shows while dynres.cpp
// restarts the stream.
//
// The decoder and its renderer are gone for the length of a reconnect, so
// nothing of Moonlight's can draw. This covers the window with a picture of
// itself, dimmed, with a spinner on top. All of it is Core Animation layers,
// which the window server keeps animating while our thread blocks on the network.

#include "chrome.h"

#include "SDL_compat.h"
#include <SDL_syswm.h>

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>
#include <notify.h>

#define SPINNER_SIZE 34

static NSView* s_Cover;

// A picture of our own window's content. Reading our own window needs no
// Screen Recording permission. The call is absent from the macOS 15 SDK headers
// but still exported, hence dlsym().
static CGImageRef copyWindowContent(NSWindow* window)
{
    typedef CGImageRef (*CreateImageFn)(CGRect, uint32_t, uint32_t, uint32_t);
    CreateImageFn createImage = (CreateImageFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (createImage == nullptr) {
        return nullptr;
    }

    // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
    CGImageRef whole = createImage(CGRectNull, 1 << 3, (uint32_t)window.windowNumber, (1 << 0) | (1 << 3));
    if (whole == nullptr) {
        return nullptr;
    }

    // Cut the title bar off the top.
    CGFloat frameHeight = window.frame.size.height;
    CGFloat titleBar = frameHeight - window.contentView.frame.size.height;
    size_t skip = (size_t)(CGImageGetHeight(whole) * titleBar / frameHeight);
    CGImageRef content = CGImageCreateWithImageInRect(whole, CGRectMake(0, skip, CGImageGetWidth(whole),
                                                                        CGImageGetHeight(whole) - skip));
    CGImageRelease(whole);
    return content;
}

void dynresBusy(SDL_Window* window, bool busy)
{
    @autoreleasepool {
        if (!busy) {
            NSView* cover = s_Cover;
            s_Cover = nil;
            if (cover != nil) {
                // Fade out rather than cut, so the sharp picture underneath eases in.
                // (Through the animator: a layer-backed view ignores implicit
                // layer animations.)
                [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
                    context.duration = 0.15;
                    cover.animator.alphaValue = 0;
                } completionHandler:^{
                    [cover removeFromSuperview];
                    [cover release];
                }];
            }
            return;
        }

        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_COCOA) {
            return;
        }
        NSView* content = info.info.cocoa.window.contentView;

        if (s_Cover != nil) {
            // A new renderer puts its own view on top of ours; go back above it.
            [content addSubview:s_Cover positioned:NSWindowAbove relativeTo:nil];
            chromeRaise(); // the bar stays above the cover
            return;
        }

        NSView* cover = [[NSView alloc] initWithFrame:content.bounds];
        cover.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        cover.wantsLayer = YES;
        cover.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        cover.layer.contentsGravity = kCAGravityResize;

        CGImageRef picture = copyWindowContent(info.info.cocoa.window);
        if (picture != nullptr) {
            cover.layer.contents = (id)picture;
            CGImageRelease(picture);
        }

        NSView* dim = [[[NSView alloc] initWithFrame:cover.bounds] autorelease];
        dim.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        dim.wantsLayer = YES;
        CGColorRef shade = CGColorCreateGenericGray(0, 0.45);
        dim.layer.backgroundColor = shade;
        CGColorRelease(shade);
        [cover addSubview:dim];

        NSRect box = NSMakeRect(NSMidX(cover.bounds) - SPINNER_SIZE / 2, NSMidY(cover.bounds) - SPINNER_SIZE / 2,
                                SPINNER_SIZE, SPINNER_SIZE);
        NSView* spinner = [[[NSView alloc] initWithFrame:box] autorelease];
        spinner.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
        spinner.wantsLayer = YES;

        CAShapeLayer* arc = [CAShapeLayer layer];
        arc.frame = spinner.bounds;
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathAddArc(path, nullptr, SPINNER_SIZE / 2, SPINNER_SIZE / 2, SPINNER_SIZE / 2 - 3, 0, M_PI * 1.5, false);
        arc.path = path;
        CGPathRelease(path);
        arc.fillColor = nullptr;
        CGColorRef white = CGColorCreateGenericGray(1, 0.9);
        arc.strokeColor = white;
        CGColorRelease(white);
        arc.lineWidth = 3;
        arc.lineCap = kCALineCapRound;

        CABasicAnimation* spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0;
        spin.toValue = @(-2 * M_PI);
        spin.duration = 0.9;
        spin.repeatCount = HUGE_VALF;
        [arc addAnimation:spin forKey:@"spin"];

        [spinner.layer addSublayer:arc];
        [cover addSubview:spinner];

        [content addSubview:cover positioned:NSWindowAbove relativeTo:nil];
        chromeRaise(); // the bar stays above the cover
        // Get it on screen now: the caller is about to block for a while.
        [CATransaction flush];

        s_Cover = cover;
    }
}

// How much of what macOS draws on the window's screen the panel really has, per
// axis: 1 on a display running at its own resolution, 0.8 for "looks like
// 3200x1350" on a 5120x2160 panel (drawn at 6400x2700).
double dynresPanelScale(SDL_Window* window)
{
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_COCOA) {
        return 1;
    }

    @autoreleasepool {
        NSScreen* screen = info.info.cocoa.window.screen ?: NSScreen.mainScreen;
        CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];

        CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
        if (current == nullptr) {
            return 1;
        }
        size_t drawn = CGDisplayModeGetPixelWidth(current);
        CGDisplayModeRelease(current);

        // The panel's own width. macOS marks the panel's mode as native; where it
        // marks none, take the widest mode that is one pixel per point, which is
        // the panel on every display seen so far but is a guess.
        const uint32_t nativeFlag = 0x02000000; // kDisplayModeNativeFlag, IOGraphicsTypes.h
        size_t panel = 0, widestPlain = 0;
        NSDictionary* everyMode = @{(id)kCGDisplayShowDuplicateLowResolutionModes: @YES};
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, (CFDictionaryRef)everyMode);
        for (CFIndex i = 0; modes != nullptr && i < CFArrayGetCount(modes); i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            size_t pixels = CGDisplayModeGetPixelWidth(mode);
            if ((CGDisplayModeGetIOFlags(mode) & nativeFlag) && pixels > panel) {
                panel = pixels;
            }
            if (pixels == CGDisplayModeGetWidth(mode) && pixels > widestPlain) {
                widestPlain = pixels;
            }
        }
        if (modes != nullptr) {
            CFRelease(modes);
        }
        bool marked = panel != 0;
        if (!marked) {
            panel = widestPlain;
        }

        static size_t s_LoggedDrawn, s_LoggedPanel;
        if (drawn != s_LoggedDrawn || panel != s_LoggedPanel) {
            s_LoggedDrawn = drawn;
            s_LoggedPanel = panel;
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Panel pixels: the screen is drawn %zu wide, the panel has %zu (%s)",
                        drawn, panel, marked ? "marked native" : panel != 0 ? "widest plain mode" : "unknown");
        }
        return panel == 0 || drawn <= panel ? 1 : (double)panel / drawn;
    }
}

// Calls toggled() on the main thread whenever someone posts the notification:
//   notifyutil -p dev.eduwass.moonlight.panel-pixels
void dynresOnPanelToggle(void (*toggled)())
{
    int token;
    // The main thread sits in SDL's event loop, which runs the main queue.
    notify_register_dispatch("dev.eduwass.moonlight.panel-pixels", &token, dispatch_get_main_queue(), ^(int) {
        toggled();
    });
}


// MOONLIGHT_RAW_COLOR: the stream's colour values go to the screen as they
// are, which is what the host's own cable to this monitor would carry. macOS
// otherwise fits them to the display, and a desktop that was tuned by eye on a
// wide-gamut monitor then looks washed out next to its usual self. Done by
// telling the layer its picture is already in the colours of the screen the
// window is on; asked again on every tick, so it follows the window to another.
static void rawColorIn(NSView* view, CGColorSpaceRef display)
{
    if ([view.layer isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer* layer = (CAMetalLayer*)view.layer;
        // Not an HDR picture: its values only mean something in the colour
        // space the renderer gave the layer.
        bool sdr = layer.pixelFormat == MTLPixelFormatBGRA8Unorm || layer.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB;
        if (sdr && (layer.colorspace == nullptr || !CFEqual(layer.colorspace, display))) {
            layer.colorspace = display;
        }
    }
    for (NSView* child in view.subviews) {
        rawColorIn(child, display);
    }
}

void dynresRawColor(SDL_Window* window)
{
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_COCOA) {
        return;
    }
    NSWindow* w = info.info.cocoa.window;
    CGColorSpaceRef display = w.screen.colorSpace.CGColorSpace;
    if (display != nullptr) {
        rawColorIn(w.contentView, display);
    }
}

// Experiment (MOONLIGHT_CHROMELESS): the stream fills the whole window, title
// bar strip included, and the traffic lights are hidden. It answers one
// question before any hover bar is built: do clicks in the old title bar strip
// reach the stream, or does macOS keep them for dragging the window?
//   1  transparent title bar, content underneath, background dragging off
//   2  the same, and the window cannot be moved at all
// Nothing here survives a trip through native fullscreen: SDL rebuilds the
// style mask on the way out.
void dynresChromeless(SDL_Window* window, int mode)
{
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (mode <= 0 || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_COCOA) {
        return;
    }

    NSWindow* w = info.info.cocoa.window;
    NSRect before = w.contentView.frame;
    w.styleMask |= NSWindowStyleMaskFullSizeContentView;
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    [w standardWindowButton:NSWindowCloseButton].hidden = YES;
    [w standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [w standardWindowButton:NSWindowZoomButton].hidden = YES;
    w.movableByWindowBackground = NO;
    if (mode >= 2) {
        w.movable = NO;
    }
    NSRect after = w.contentView.frame;
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "Chromeless %d: content view was %.0fx%.0f, is %.0fx%.0f in a %.0fx%.0f window",
                mode, before.size.width, before.size.height, after.size.width, after.size.height,
                w.frame.size.width, w.frame.size.height);
}
