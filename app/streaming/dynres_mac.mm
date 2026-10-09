// Fork-only (eduwass/moonlight-qt): what the window shows while dynres.cpp
// restarts the stream.
//
// The decoder and its renderer are gone for the length of a reconnect, so
// nothing of Moonlight's can draw. This covers the window with a picture of
// itself, dimmed, with a spinner on top. All of it is Core Animation layers,
// which the window server keeps animating while our thread blocks on the network.

#include "SDL_compat.h"
#include <SDL_syswm.h>

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>

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
        // Get it on screen now: the caller is about to block for a while.
        [CATransaction flush];

        s_Cover = cover;
    }
}
