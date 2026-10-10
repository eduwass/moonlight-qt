// Fork-only (eduwass/moonlight-qt): the instant pointer's shape.
//
// With MOONLIGHT_LOCAL_CURSOR set, the pointer over the stream is this Mac's
// own, so it moves with the hand instead of one round trip later (the host
// leaves its cursor out of the picture). The stream protocol cannot say what
// the host's cursor looks like, so the host says it on the side: a helper there
// (cursor-share, in dotfiles infra/kvm/mac-host) connects to us and sends the
// cursor's picture and hot spot whenever it changes. We make it our pointer.
// A host without the helper leaves the plain arrow.
//
// One line of text, then the picture:  <width> <height> <hot x> <hot y> <bytes>\n<PNG>
// Sizes are in points; the PNG may hold more pixels than that (a 2x cursor).

#include <fcntl.h>
#include "SDL_compat.h"
#include "chrome.h"

#import <Cocoa/Cocoa.h>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

#define CURSOR_PORT 47995
#define CURSOR_MAX_POINTS 256
#define CURSOR_MAX_PIXELS (CURSOR_MAX_POINTS * 4)
#define CURSOR_MAX_BYTES (4 * 1024 * 1024)

static char s_Host[64]; // the host we stream from; only it may set our cursor
static void* s_Cursor;  // an SDL 3 cursor; main thread only
static SDL_atomic_t s_Listening;
static SDL_atomic_t s_Connected; // how many connections of the host's helper are being listened to (one, but for a moment)
static int s_Serving;            // its connection, to let go of when a newer one comes; under s_ServingLock
static pthread_mutex_t s_ServingLock = PTHREAD_MUTEX_INITIALIZER;
static bool s_Plain;             // a host with no helper: a plain arrow, and nothing to wait for

// ponytail: the SDL 2 we link is sdl2-compat, a layer over SDL 3, and the SDL 2
// calls make cursors of one pixel per point: blurry on a 2x screen. SDL 3 takes
// a cursor with a second, sharper picture, so these few calls go to SDL 3
// itself. The two share their cursor state (sdl2-compat hands cursors straight
// through), so nothing is bypassed. If SDL 3 is not there, the arrow stays.
// Upgrade path: none needed once Moonlight moves to SDL 3.
static void* sdl3(const char* name)
{
    static void* library;
    static bool looked;
    if (!looked) {
        looked = true;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char* path = _dyld_get_image_name(i);
            if (path != nullptr && strstr(path, "libSDL3") != nullptr) {
                library = dlopen(path, RTLD_NOLOAD | RTLD_LAZY);
            }
        }
    }
    return library != nullptr ? dlsym(library, name) : nullptr;
}

// The image drawn at the given size, as the BGRA bytes with straight alpha that
// SDL calls ARGB8888. malloc()ed.
static void* pixelsOf(NSImage* image, int width, int height)
{
    Uint8* pixels = (Uint8*)calloc((size_t)width * height, 4);
    CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, (size_t)width * 4, colors,
                                                 (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colors);
    if (pixels == nullptr || context == nullptr) {
        free(pixels);
        return nullptr;
    }
    NSGraphicsContext* previous = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO]];
    [image drawInRect:NSMakeRect(0, 0, width, height) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
    [NSGraphicsContext setCurrentContext:previous];
    CGContextRelease(context);

    // Core Graphics draws with colours multiplied by alpha; SDL wants them straight.
    for (Uint8* p = pixels; p < pixels + (size_t)width * height * 4; p += 4) {
        if (p[3] != 0 && p[3] != 255) {
            p[0] = (Uint8)(p[0] * 255 / p[3]);
            p[1] = (Uint8)(p[1] * 255 / p[3]);
            p[2] = (Uint8)(p[2] * 255 / p[3]);
        }
    }
    return pixels;
}

static void apply(NSData* png, int width, int height, int hotX, int hotY)
{
    auto createSurfaceFrom = (void* (*)(int, int, Uint32, void*, int))sdl3("SDL_CreateSurfaceFrom");
    auto addAlternateImage = (bool (*)(void*, void*))sdl3("SDL_AddSurfaceAlternateImage");
    auto createColorCursor = (void* (*)(void*, int, int))sdl3("SDL_CreateColorCursor");
    auto setCursor = (bool (*)(void*))sdl3("SDL_SetCursor");
    auto destroyCursor = (void (*)(void*))sdl3("SDL_DestroyCursor");
    auto destroySurface = (void (*)(void*))sdl3("SDL_DestroySurface");
    // The picture's own size is checked too: the header only says how big to show it.
    NSBitmapImageRep* picture = [[[NSBitmapImageRep alloc] initWithData:png] autorelease];
    if (picture == nil || picture.pixelsWide > CURSOR_MAX_PIXELS || picture.pixelsHigh > CURSOR_MAX_PIXELS) {
        return;
    }
    picture.size = NSMakeSize(width, height);
    NSImage* image = [[[NSImage alloc] initWithSize:picture.size] autorelease];
    [image addRepresentation:picture];
    if (!createSurfaceFrom || !addAlternateImage || !createColorCursor || !setCursor || !destroyCursor || !destroySurface) {
        return;
    }

    void* small = pixelsOf(image, width, height);
    void* sharp = pixelsOf(image, width * 2, height * 2);
    void* smallSurface = small ? createSurfaceFrom(width, height, SDL_PIXELFORMAT_ARGB8888, small, width * 4) : nullptr;
    void* sharpSurface = sharp ? createSurfaceFrom(width * 2, height * 2, SDL_PIXELFORMAT_ARGB8888, sharp, width * 8) : nullptr;
    void* cursor = nullptr;
    if (smallSurface != nullptr) {
        if (sharpSurface != nullptr) {
            addAlternateImage(smallSurface, sharpSurface);
        }
        cursor = createColorCursor(smallSurface, hotX, hotY); // copies the pictures
    }
    if (sharpSurface != nullptr) {
        destroySurface(sharpSurface);
    }
    if (smallSurface != nullptr) {
        destroySurface(smallSurface);
    }
    free(small);
    free(sharp);
    if (cursor == nullptr) {
        return;
    }

    setCursor(cursor);
    if (s_Cursor != nullptr) {
        destroyCursor(s_Cursor);
    }
    s_Cursor = cursor;
}

// `counted`, if given, is set once the first cursor has come, and the helper
// counted as connected then: over ssh there is nothing before that to say it
// is really there.
static void serve(FILE* in, bool* counted = nullptr)
{
    for (;;) {
        // A short line, read whole, so a peer cannot feed the parser without end.
        char line[64];
        int width, height, hotX, hotY, used = 0;
        unsigned long length;
        if (fgets(line, sizeof(line), in) == nullptr || strlen(line) > 40 ||
                sscanf(line, "%4d %4d %4d %4d %8lu\n%n", &width, &height, &hotX, &hotY, &length, &used) != 5 || line[used] != 0 ||
                width < 1 || height < 1 || width > CURSOR_MAX_POINTS || height > CURSOR_MAX_POINTS ||
                hotX < 0 || hotY < 0 || hotX >= width || hotY >= height || length < 1 || length > CURSOR_MAX_BYTES) {
            break;
        }
        NSMutableData* png = [[NSMutableData alloc] initWithLength:length];
        if (fread(png.mutableBytes, 1, length, in) != length) {
            [png release];
            break;
        }
        if (counted != nullptr && !*counted) {
            *counted = true;
            SDL_AtomicAdd(&s_Connected, 1);
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Cursor shapes: coming over ssh");
        }
        // The main thread is inside SDL's event loop, which runs the main queue.
        dispatch_async(dispatch_get_main_queue(), ^{
            apply(png, width, height, hotX, hotY);
            [png release];
        });
    }
}

static int listenForCursors(void*)
{
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    // Not for a process this one becomes (main.cpp tries a dropped stream once
    // more as itself): the port would be held with nobody listening.
    fcntl(listener, F_SETFD, FD_CLOEXEC);
    int yes = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in any = {};
    any.sin_family = AF_INET;
    any.sin_port = htons(CURSOR_PORT);
    if (listener < 0 || bind(listener, (struct sockaddr*)&any, sizeof(any)) != 0 || listen(listener, 2) != 0) {
        // Most likely another Moonlight has the port. The next session tries again.
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Cursor shapes: cannot listen on port %d", CURSOR_PORT);
        if (listener >= 0) {
            close(listener);
        }
        SDL_AtomicSet(&s_Listening, 0);
        return 0;
    }

    for (;;) {
        struct sockaddr_in peer;
        socklen_t peerLength = sizeof(peer);
        int fd = accept(listener, (struct sockaddr*)&peer, &peerLength);
        if (fd < 0) {
            continue;
        }
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        char from[INET_ADDRSTRLEN] = "";
        inet_ntop(AF_INET, &peer.sin_addr, from, sizeof(from));
        if (strcmp(from, s_Host) != 0) {
            close(fd);
            continue;
        }
        // A host that vanishes without a word (its cable pulled) is noticed
        // in twenty seconds; a cursor that has not changed for an hour is not
        // taken for one.
        int on = 1, idle = 10, between = 3, tries = 3;
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &between, sizeof(between));
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &tries, sizeof(tries));
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Cursor shapes: connected from %s", from);
        // From here the host leaves its cursor out of the picture, and ours
        // is the one to see; when the helper goes, the other way round.
        // (mouse.cpp shows and hides the pointer, at its next movement: it
        // knows where the pointer is and what the user has asked for.)
        // The newest connection is the helper: an older one is let go of, so
        // that one whose end was never heard of (seen: the host's side closed
        // and this side still open) cannot keep the next helper waiting.
        // (Under one lock with the closing below: a descriptor's number is
        // only this connection's until it is closed.)
        pthread_mutex_lock(&s_ServingLock);
        if (s_Serving > 0) {
            shutdown(s_Serving, SHUT_RDWR);
        }
        s_Serving = fd;
        pthread_mutex_unlock(&s_ServingLock);
        SDL_AtomicAdd(&s_Connected, 1);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            FILE* in = fdopen(fd, "r");
            if (in != nullptr) {
                @autoreleasepool {
                    serve(in);
                }
            }
            pthread_mutex_lock(&s_ServingLock);
            if (s_Serving == fd) {
                s_Serving = 0;
            }
            if (in != nullptr) {
                fclose(in);
            }
            else {
                close(fd);
            }
            pthread_mutex_unlock(&s_ServingLock);
            SDL_AtomicAdd(&s_Connected, -1);
        });
    }
}

// The other way to the same helper: started over ssh, its output read here.
// For a host where macOS does not let the helper reach this Mac (it asks
// whether "sunshine" may find devices on the local network, again after every
// re-signed build, and "Don't Allow" fails without a word); what ssh starts
// is not asked. MOONLIGHT_CLIPBOARD names the ssh destination, and with one
// this is the only way used: the two together would be two helpers on the
// host, each telling it when it comes and goes, and its cursor in or out of
// the picture by whichever spoke last. Tried again for as long as the app runs.
static int fetchOverSsh(void* destination)
{
    NSString* host = (NSString*)destination; // kept for good
    for (;; sleep(1)) { // at once the first time, then a second after each try
        @autoreleasepool {
            NSTask* task = [[[NSTask alloc] init] autorelease];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ssh"];
            task.arguments = @[@"-o", @"BatchMode=yes", @"-o", @"ConnectTimeout=4", @"-o", @"ServerAliveInterval=2", @"-o", @"ServerAliveCountMax=2",
                               @"-o", @"ControlMaster=auto", @"-o", [NSString stringWithFormat:@"ControlPath=%@/.ssh/cm-%%C", NSHomeDirectory()],
                               @"-o", @"ControlPersist=600", @"--", host,
                               // Exactly one Sunshine, or none of this: the helper would tell the wrong one.
                               @"p=$(pgrep -x sunshine); case \"$p\" in ''|*[!0-9]*) exit 1;; esac; exec ~/.local/bin/cursor-share --stdio $p"];
            NSPipe* out = [NSPipe pipe];
            task.standardOutput = out;
            // Its input is held open and never written to: that being closed
            // is how the helper knows this end has gone (sshd tells a command
            // nothing else), also when this app dies without a word.
            NSPipe* hold = [NSPipe pipe];
            task.standardInput = hold;
            task.standardError = [NSFileHandle fileHandleWithNullDevice];
            if (![task launchAndReturnError:nil]) {
                continue;
            }
            static bool asked;
            if (!asked) {
                asked = true;
                SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Cursor shapes: asking the host for them over ssh");
            }
            int copy = dup(out.fileHandleForReading.fileDescriptor);
            fcntl(copy, F_SETFD, FD_CLOEXEC);
            FILE* in = copy >= 0 ? fdopen(copy, "r") : nullptr;
            bool counted = false;
            if (in != nullptr) {
                serve(in, &counted);
                fclose(in);
            }
            else if (copy >= 0) {
                close(copy);
            }
            if (counted) {
                SDL_AtomicAdd(&s_Connected, -1);
            }
            [hold.fileHandleForWriting closeFile]; // the helper sees its input closed and goes
            [task terminate];
            [task waitUntilExit];
            // Said once per change, not once per try: a host that is off is tried every second.
            static int said = -2;
            int how = counted ? -1 : task.terminationStatus;
            if (how != said) {
                said = how;
                SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, counted ? "Cursor shapes: the helper over ssh has gone; asking again" :
                            "Cursor shapes: nothing came over ssh (it ended with %d); trying every second", task.terminationStatus);
            }
            [task waitUntilExit];
        }
    }
    return 0;
}

bool cursorShareWaiting()
{
    return getenv("MOONLIGHT_LOCAL_CURSOR") != nullptr && !s_Plain && SDL_AtomicGet(&s_Connected) == 0;
}

// Called on the main thread when a session starts.
void cursorShareStart(const char* host)
{
    // A Linux host has no helper (see the hosts page): its cursor is hidden by
    // its own prep command, and the pointer here is a plain arrow at once.
    s_Plain = getenv("MOONLIGHT_CHROME") != nullptr && strstr(getenv("MOONLIGHT_CHROME"), "linux") != nullptr;
    SDL_strlcpy(s_Host, host, sizeof(s_Host));
    // SDL destroyed the last session's cursors when it shut its video down.
    s_Cursor = nullptr;
    const char* destination = getenv("MOONLIGHT_CLIPBOARD");
    NSCharacterSet* other = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@"] invertedSet];
    bool overSsh = !s_Plain && destination != nullptr && destination[0] != 0 && destination[0] != '-' && strlen(destination) <= 128 &&
                   [@(destination) rangeOfCharacterFromSet:other].location == NSNotFound;
    // One way or the other, for the life of the app: over ssh where the device
    // has a destination for it, else the helper's own connection to us.
    if (SDL_AtomicCAS(&s_Listening, 0, 1)) {
        if (overSsh) {
            SDL_DetachThread(SDL_CreateThread(fetchOverSsh, "cursor shapes over ssh", [@(destination) retain]));
        }
        else if (!s_Plain) {
            SDL_DetachThread(SDL_CreateThread(listenForCursors, "cursor shapes", nullptr));
        }
    }
}
