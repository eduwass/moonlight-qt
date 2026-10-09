// Fork-only (eduwass/moonlight-qt): follow the window size, like the Dynamic
// Resolution mode of macOS Screen Sharing.
//
// A stream's resolution is fixed when the connection starts, so following the
// window means reconnecting. This does it inside the running session: the SDL
// window stays, only the connection and the decoder are replaced. The host app
// is quit and launched again (not resumed) so that Sunshine reruns its prep
// commands, which is where the host display gets resized.

#include "session.h"
#include "backend/nvhttp.h"
#include "streaming/input/input.h"
#include "streaming/video/decoder.h"
#include "streaming/chrome.h"

#include <Limelight.h>
#include "SDL_compat.h"

#include <QWriteLocker>

// How long the window size must hold still before we reconnect.
#define DYNRES_SETTLE_MS 700

// Smaller than this is a window on its way somewhere else, not a target.
#define DYNRES_MIN_WIDTH 640
#define DYNRES_MIN_HEIGHT 360

// The cover comes off this long after the new stream's first packets, which is
// enough for the first frame to be decoded and drawn underneath it.
#define DYNRES_FIRST_FRAME_MS 150

// If the new stream never shows up, uncover the window anyway.
#define DYNRES_COVER_MAX_MS 6000

// A connection that brings no video within this long is made again, up to this
// many times. Sunshine on macOS now and then starts a session sending video to
// the client's audio port (seen in about one connect in fifteen); left alone,
// the session dies ten seconds later with "no video traffic".
#define DYNRES_NO_VIDEO_MS 3000
#define DYNRES_MAX_RETRIES 2

// The event loop sleeps until an event arrives; these keep it turning while we
// are waiting on a clock instead.
#define DYNRES_WAKE_MS 30

// While the stream restarts, the window is covered with a dimmed picture of
// itself and a spinner (dynres_mac.mm). Other platforms show a blank window.
#ifdef Q_OS_DARWIN
void dynresBusy(SDL_Window* window, bool busy);
void sysKeysSessionStarted(); // syskeys_mac.mm; called from here because this is the fork's one hook into a session
void cursorShareStart(const char* host); // cursorshare_mac.mm
double dynresPanelScale(SDL_Window* window);
void dynresOnPanelToggle(void (*toggled)());
void dynresChromeless(SDL_Window* window, int mode);
#else
static void dynresBusy(SDL_Window*, bool) {}
static void sysKeysSessionStarted() {}
static void cursorShareStart(const char*) {}
static double dynresPanelScale(SDL_Window*) { return 1; }
static void dynresOnPanelToggle(void (*)()) {}
static void dynresChromeless(SDL_Window*, int) {}
#endif

void netPathUpdate(const QString& host); // netpath.cpp

// Only one session streams at a time, so plain statics are enough. A new
// session is recognised by its window id (ids are never reused, unlike the
// addresses of Session objects) and starts from a clean slate.
static Uint32 s_WindowId;
static int s_SeenWidth, s_SeenHeight;
static Uint32 s_SeenAt;
static bool s_Changed;
static bool s_Sized;

// Stream only the pixels the panel has. macOS draws a scaled display mode
// ("looks like 3200x1350" on a 5120x2160 panel) at twice the points and
// shrinks the result to the panel, so a stream at the window's full pixel size
// carries 5 pixels for every 4 that reach the glass: a third more to encode
// for nothing. With this on, the stream is the window's size in panel pixels.
// The picture is then scaled twice on its way to the glass and may come out a
// little softer, which is why it is a switch: MOONLIGHT_PANEL_PIXELS starts
// with it on, and `notifyutil -p dev.eduwass.moonlight.panel-pixels` flips it
// in a running session.
static bool s_PanelPixels;

// The window's own chrome (chrome_mac.mm), with MOONLIGHT_CHROME. Its clicks
// arrive while AppKit handles an event, and are acted on at the next tick.
static bool s_Chrome;
static int s_ChromeAsked;      // one bit per CHROME_ action
static bool s_Follow = true;   // restart the stream when the window's size changes
static bool s_ResizeOnce;      // a restart the user asked for, whatever s_Follow says
static char s_Host[64];
static ChromeState s_ChromeState; // what the bar was last told

enum {
    COVER_OFF,
    COVER_UNTIL_DECODER, // until the event loop has built the new decoder
    COVER_UNTIL_PACKETS, // until the new stream delivers video
    COVER_UNTIL_DRAWN,   // until that video has had time to reach the screen
};
static int s_Cover;
static Uint32 s_CoverAt, s_PacketsAt;

// Waiting for a new connection's first video packets.
static bool s_Await, s_Retry;
static Uint32 s_AwaitAt;
static int s_Retries;

static SDL_atomic_t s_WantWake, s_WakeUntil;
static Uint32 s_WakeEvent;
static SDL_TimerID s_WakeTimer;

// Nobody tells this file that a session has ended, so the timer gives up by
// itself if dynresTick() has stopped renewing it.
#define DYNRES_WAKE_LEASE_MS 2000

static Uint32 wakeTimer(Uint32 interval, void*)
{
    if (!SDL_AtomicGet(&s_WantWake) ||
            (Sint32)(SDL_GetTicks() - (Uint32)SDL_AtomicGet(&s_WakeUntil)) > 0) {
        SDL_AtomicSet(&s_WantWake, 0);
        return 0;
    }

    SDL_Event event = {};
    event.type = s_WakeEvent;
    SDL_PushEvent(&event);
    return interval;
}

static void setWake(bool want)
{
    SDL_AtomicSet(&s_WakeUntil, (int)(SDL_GetTicks() + DYNRES_WAKE_LEASE_MS));
    if (!!SDL_AtomicGet(&s_WantWake) == want) {
        return;
    }

    if (s_WakeEvent == 0) {
        // The first id SDL hands out is SDL_USEREVENT itself, which the event
        // loop reads as "a frame is ready"; take the next one.
        s_WakeEvent = SDL_RegisterEvents(1);
        if (s_WakeEvent == SDL_USEREVENT) {
            s_WakeEvent = SDL_RegisterEvents(1);
        }
    }

    // A timer that saw the flag clear has already ended itself; removing it
    // again is harmless.
    SDL_RemoveTimer(s_WakeTimer);
    SDL_AtomicSet(&s_WantWake, want);
    s_WakeTimer = want ? SDL_AddTimer(DYNRES_WAKE_MS, wakeTimer, nullptr) : 0;
}

// MOONLIGHT_FPS_ABOVE=<pixels>:<fps>:<full fps> picks the frame rate by size on
// every restart: <fps> for streams larger than <pixels>, <full fps> otherwise.
// For hosts whose encoder cannot keep up with big frames at the full rate: an
// M1 at 60 fps and 3200x1800 sometimes let frames back up for a whole session
// (87 ms of host latency instead of 21); at 40 fps it never did. Whoever
// launches Moonlight applies the same rule to the --fps it starts with.
static int fpsFor(int width, int height, int fps)
{
    static int abovePixels = -1, aboveFps, fullFps;
    if (abovePixels < 0) {
        abovePixels = 0;
        QList<QByteArray> rule = qgetenv("MOONLIGHT_FPS_ABOVE").split(':');
        if (rule.size() == 3 && rule[0].toInt() > 0 && rule[1].toInt() > 0 && rule[2].toInt() > 0) {
            abovePixels = rule[0].toInt();
            aboveFps = rule[1].toInt();
            fullFps = rule[2].toInt();
        }
    }
    if (abovePixels == 0) {
        return fps;
    }
    return width * height > abovePixels ? aboveFps : fullFps;
}

// Runs on the main thread when the switch is flipped from outside.
static void panelToggled()
{
    s_PanelPixels = !s_PanelPixels;
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Panel pixels: %s", s_PanelPixels ? "on" : "off");
    // Have the size looked at again, and the event loop turn while it settles.
    s_SeenWidth = s_SeenHeight = 0;
    s_ResizeOnce = true;
    setWake(true);
}

static void chromeAsked(int action)
{
    if (action != CHROME_SHOWN) {
        s_ChromeAsked |= 1 << action;
    }
    setWake(true);
}

// Good, fair or poor, from what the link is doing: the worst reading decides,
// and a relayed Tailscale path is a reason by itself. A worse verdict has to
// hold for three seconds before it shows, a better one shows at once.
static void judgeLink(ChromeState& state, Uint32 now)
{
    static Uint32 sampledAt, worseSince;
    static uint32_t lastVideo, lastFailed;
    static double lost;
    static int shown;

    uint32_t rtt = 0, variance = 0;
    LiGetEstimatedRttInfo(&rtt, &variance);
    state.delayMs = (int)rtt;

    // Counted over two seconds at a time; the counters start again with every connection.
    const RTP_VIDEO_STATS* rtp = LiGetRTPVideoStats();
    if (rtp->packetCountVideo < lastVideo || now - sampledAt >= 2000) {
        if (rtp->packetCountVideo > lastVideo && rtp->packetCountFecFailed >= lastFailed) {
            lost = 100.0 * (rtp->packetCountFecFailed - lastFailed) / (rtp->packetCountVideo - lastVideo);
        }
        lastVideo = rtp->packetCountVideo;
        lastFailed = rtp->packetCountFecFailed;
        sampledAt = now;
    }
    state.lostPercent = lost;

    int verdict = CHROME_GOOD;
    if (state.delayMs >= CHROME_DELAY_POOR_MS || lost >= CHROME_LOSS_POOR_PERCENT || state.relayed) {
        verdict = CHROME_POOR;
    }
    else if (state.delayMs >= CHROME_DELAY_FAIR_MS || lost >= CHROME_LOSS_FAIR_PERCENT) {
        verdict = CHROME_FAIR;
    }
    if (verdict <= shown) {
        shown = verdict;
        worseSince = 0;
    }
    else if (worseSince == 0) {
        worseSince = now ? now : 1;
    }
    else if (now - worseSince >= 3000) {
        shown = verdict;
    }
    state.verdict = shown;
}

// Called from every turn of Session::exec()'s event loop.
// Returns false if the stream could not be restarted and the session must end.
bool Session::dynresTick()
{
    Uint32 now = SDL_GetTicks();

    if (SDL_GetWindowID(m_Window) != s_WindowId) {
        // Whatever the last session left behind (it may have ended mid-restart).
        s_WindowId = SDL_GetWindowID(m_Window);
        dynresBusy(m_Window, false);
        s_Cover = COVER_OFF;
        s_SeenWidth = s_SeenHeight = 0;
        s_Changed = s_Sized = s_Retry = false;
        s_Await = true;
        s_AwaitAt = 0;
        s_Retries = 0;
        setWake(false);
        sysKeysSessionStarted();
        netPathUpdate(m_Computer->activeAddress.address());
        if (qEnvironmentVariableIsSet("MOONLIGHT_LOCAL_CURSOR")) {
            cursorShareStart(m_Computer->activeAddress.address().toUtf8().constData());
        }
        dynresChromeless(m_Window, qEnvironmentVariableIntValue("MOONLIGHT_CHROMELESS"));
        s_Chrome = qEnvironmentVariableIsSet("MOONLIGHT_CHROME");
        s_ChromeAsked = 0;
        s_Follow = true;
        if (s_Chrome) {
            SDL_strlcpy(s_Host, m_Computer->name.toUtf8().constData(), sizeof(s_Host));
            dynresChromeless(m_Window, 2);
            chromeStart(m_Window, chromeAsked);
        }
        static bool watching;
        if (!watching) {
            watching = true;
            s_PanelPixels = qEnvironmentVariableIsSet("MOONLIGHT_PANEL_PIXELS");
            dynresOnPanelToggle(panelToggled);
        }
    }

    if (s_Chrome) {
        int asked = s_ChromeAsked;
        s_ChromeAsked = 0;
        if (asked & (1 << CHROME_STATS)) {
            m_OverlayManager.setOverlayState(Overlay::OverlayDebug, !m_OverlayManager.isOverlayEnabled(Overlay::OverlayDebug));
        }
        if (asked & (1 << CHROME_TRUE_PIXELS)) {
            panelToggled();
        }
        if (asked & (1 << CHROME_FOLLOW)) {
            s_Follow = !s_Follow;
            s_SeenWidth = s_SeenHeight = 0;
        }
        if (asked & (1 << CHROME_FULLSCREEN)) {
            toggleFullscreen();
        }

        // Twice a second is plenty for what the bar shows, and at once after a click.
        static Uint32 toldAt;
        static bool wasFullscreen;
        bool fullscreen = (SDL_GetWindowFlags(m_Window) & SDL_WINDOW_FULLSCREEN) != 0;
        if (asked != 0 || now - toldAt >= 500) {
            toldAt = now;
            if (wasFullscreen && !fullscreen) {
                // SDL rebuilt the window's style on the way out of fullscreen.
                dynresChromeless(m_Window, 2);
                chromeLeftFullscreen();
            }
            wasFullscreen = fullscreen;

            ChromeState& state = s_ChromeState;
            state.stats = m_OverlayManager.isOverlayEnabled(Overlay::OverlayDebug);
            state.truePixels = s_PanelPixels;
            state.followSize = s_Follow;
            state.fullscreen = fullscreen;
            state.busy = s_Cover != COVER_OFF;
            state.link = netPathLink();
            state.relayed = netPathRelayed();
            state.width = m_StreamConfig.width;
            state.height = m_StreamConfig.height;
            state.fps = m_StreamConfig.fps;
            SDL_strlcpy(state.host, s_Host, sizeof(state.host));
            judgeLink(state, now);
            chromeUpdate(&state);
        }
        if (chromeShown()) {
            setWake(true); // keep the numbers moving while they are on screen
        }
    }

    if (s_Changed || s_Await || s_Cover != COVER_OFF) {
        setWake(true); // renew the lease
    }

    if (s_Cover != COVER_OFF) {
        if (s_Cover == COVER_UNTIL_DECODER && m_VideoDecoder != nullptr &&
                !SDL_HasEvent(SDL_RENDER_DEVICE_RESET)) {
            // The new renderer has put its view over our cover.
            dynresBusy(m_Window, true);
            s_Cover = COVER_UNTIL_PACKETS;
        }
        // The count starts at zero with every connection, so anything above
        // it is video from the new one, even if the host then goes quiet.
        else if (s_Cover == COVER_UNTIL_PACKETS &&
                 LiGetRTPVideoStats()->packetCountVideo != 0) {
            s_PacketsAt = now;
            s_Cover = COVER_UNTIL_DRAWN;
        }

        if ((s_Cover == COVER_UNTIL_DRAWN && now - s_PacketsAt >= DYNRES_FIRST_FRAME_MS) ||
                now - s_CoverAt >= DYNRES_COVER_MAX_MS) {
            dynresBusy(m_Window, false);
            s_Cover = COVER_OFF;
            setWake(s_Changed);
        }
    }

    // No decoder means we are not streaming yet, or are mid-restart. Start
    // over, so that the first size seen afterwards is judged against the
    // stream rather than against a size from before.
    if (m_VideoDecoder == nullptr) {
        s_SeenWidth = s_SeenHeight = 0;
        return true;
    }

    if (s_Await) {
        if (LiGetRTPVideoStats()->packetCountVideo != 0) {
            s_Await = false;
            s_Retries = 0;
        }
        else if (s_AwaitAt == 0) {
            s_AwaitAt = now;
        }
        else if (now - s_AwaitAt >= DYNRES_NO_VIDEO_MS) {
            // Out of retries: leave it to the ten second limit to end the session.
            s_Await = false;
            s_Retry = s_Retries++ < DYNRES_MAX_RETRIES;
        }
    }

    Uint32 flags = SDL_GetWindowFlags(m_Window);
    bool windowed = !(flags & (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_MINIMIZED));

    // Pixels, not points: on a Retina display this is what makes one stream
    // pixel land on one screen pixel. Encoders want even dimensions.
    int width, height;
    SDL_GetWindowSizeInPixels(m_Window, &width, &height);
    if (s_PanelPixels) {
        // Asking the display for its modes is not free and this runs on every
        // event; the answer only changes when the window changes screens.
        static double share = 1;
        static Uint32 askedAt;
        // Shorter than the settle time, so a window that has moved to another
        // screen is never restarted with the old screen's answer.
        if (askedAt == 0 || now - askedAt >= 250) {
            askedAt = now ? now : 1;
            share = dynresPanelScale(m_Window);
        }
        width = (int)(width * share + 0.5);
        height = (int)(height * share + 0.5);
    }

    // Moonlight sizes its window as if stream pixels were points and then
    // shrinks it to fit the screen, so a 3840x2160 stream on a Retina display
    // opens slightly scaled. Once, when a session starts in a window, give the
    // stream its exact size. If that does not fit the screen the window comes
    // out smaller, and the usual resize path below then matches the stream to
    // it instead.
    if (!s_Sized) {
        s_Sized = true;
        int pointWidth, pointHeight;
        SDL_GetWindowSize(m_Window, &pointWidth, &pointHeight);
        if (windowed && pointWidth > 0 && (width != m_StreamConfig.width || height != m_StreamConfig.height)) {
            double scale = (double)width / pointWidth;
            SDL_SetWindowSize(m_Window, (int)(m_StreamConfig.width / scale + 0.5),
                              (int)(m_StreamConfig.height / scale + 0.5));
            s_SeenWidth = s_SeenHeight = 0;
            return true;
        }
    }

    if (s_Retry) {
        s_Retry = false;
        width = m_StreamConfig.width;
        height = m_StreamConfig.height;
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "No video %d ms after connecting; connecting again (attempt %d of %d)",
                    DYNRES_NO_VIDEO_MS, s_Retries, DYNRES_MAX_RETRIES);
    }
    else {
        if ((flags & SDL_WINDOW_MINIMIZED) || (!s_Follow && !s_ResizeOnce)) {
            // Whatever was settling is moot: the window is away, or the stream
            // has been told to keep its size.
            s_Changed = false;
            setWake(s_Cover != COVER_OFF);
            return true;
        }

        width &= ~1;
        height &= ~1;

        if (width != s_SeenWidth || height != s_SeenHeight) {
            // The first size seen after a (re)start counts as a change only if the
            // stream does not already match it: the window may have been resized
            // while we were busy restarting, or clamped to the screen when sized.
            s_Changed = s_SeenWidth != 0 || width != m_StreamConfig.width || height != m_StreamConfig.height;
            s_SeenWidth = width;
            s_SeenHeight = height;
            s_SeenAt = now;
            // Nothing may happen in the window while we wait for it to settle.
            setWake(s_Changed || s_Cover != COVER_OFF);
            return true;
        }

        if (!s_Changed || now - s_SeenAt < DYNRES_SETTLE_MS) {
            return true;
        }

        // Still dragging the window edge: wait for the button to come up.
        if (SDL_GetGlobalMouseState(nullptr, nullptr) & SDL_BUTTON_LMASK) {
            s_SeenAt = now;
            return true;
        }

        s_Changed = false;
        setWake(s_Cover != COVER_OFF);

        if ((width == m_StreamConfig.width && height == m_StreamConfig.height) ||
                width < DYNRES_MIN_WIDTH || height < DYNRES_MIN_HEIGHT) {
            return true;
        }

        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "Window is now %dx%d; restarting the %dx%d stream to match",
                    width, height, m_StreamConfig.width, m_StreamConfig.height);
    }

    m_InputHandler->raiseAllKeys();
    s_ResizeOnce = false;

    // Everything from here to the first new frame happens behind the cover.
    if (s_Chrome) {
        // The bar hears of it now: this thread is about to be busy for a while.
        s_ChromeState.busy = true;
        chromeUpdate(&s_ChromeState);
    }
    dynresBusy(m_Window, true);
    s_Cover = COVER_UNTIL_DECODER;
    s_CoverAt = now;
    setWake(true);

    // Same order as the normal exit path: the decoder has to be gone before
    // LiStopConnection().
    SDL_LockMutex(m_DecoderLock);
    delete m_VideoDecoder;
    m_VideoDecoder = nullptr;
    SDL_UnlockMutex(m_DecoderLock);

    LiStopConnection();

    try {
        NvHTTP http(m_Computer);
        http.quitApp();
    } catch (const GfeHttpResponseException&) {
    } catch (const QtNetworkReplyException&) {
    }

    {
        // startConnectionAsync() resumes instead of launching if it thinks the
        // app is still running.
        QWriteLocker lock(&m_Computer->lock);
        m_Computer->currentGameId = 0;
    }

    m_StreamConfig.width = width;
    m_StreamConfig.height = height;
    m_StreamConfig.fps = fpsFor(width, height, m_Preferences->fps);
    m_InputHandler->setStreamSize(width, height);

    // LiStartConnection() fills unset callbacks with stubs in our struct. A
    // second call then rejects a pull renderer that "has" a submit callback.
    if (m_VideoCallbacks.capabilities & CAPABILITY_PULL_RENDERER) {
        m_VideoCallbacks.submitDecodeUnit = nullptr;
    }

    if (!startConnectionAsync()) {
        dynresBusy(m_Window, false);
        s_Cover = COVER_OFF;
        setWake(false);
        return false;
    }

    // The calls above block for seconds; the cover's time limit is for what
    // comes after them.
    s_CoverAt = SDL_GetTicks();
    s_Await = true;
    s_AwaitAt = 0;

    // LiStartConnection() only recorded the new format (see drSetup()). The
    // decoder itself is built by the event loop's renderer reset path.
    SDL_Event event = {};
    event.type = SDL_RENDER_DEVICE_RESET;
    SDL_PushEvent(&event);

    return true;
}
