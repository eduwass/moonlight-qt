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

#include <Limelight.h>
#include "SDL_compat.h"

#include <QWriteLocker>

// How long the window size must hold still before we reconnect.
#define DYNRES_SETTLE_MS 700

// Smaller than this is a window on its way somewhere else, not a target.
#define DYNRES_MIN_WIDTH 640
#define DYNRES_MIN_HEIGHT 360

// Only one session streams at a time, so plain statics are enough.
static int s_SeenWidth, s_SeenHeight;
static Uint32 s_SeenAt;
static bool s_Changed;

// Called from every turn of Session::exec()'s event loop.
// Returns false if the stream could not be restarted and the session must end.
bool Session::dynresTick()
{
    // No decoder means we are not streaming yet, or are mid-restart. Starting
    // over here makes the first size we see the baseline rather than a change,
    // so the window Moonlight opens on its own never triggers a reconnect.
    if (m_VideoDecoder == nullptr) {
        s_SeenWidth = s_SeenHeight = 0;
        return true;
    }

    if (SDL_GetWindowFlags(m_Window) & (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_MINIMIZED)) {
        return true;
    }

    // Pixels, not points: on a Retina display this is what makes one stream
    // pixel land on one screen pixel. Encoders want even dimensions.
    int width, height;
    SDL_GetWindowSizeInPixels(m_Window, &width, &height);
    width &= ~1;
    height &= ~1;

    Uint32 now = SDL_GetTicks();
    if (width != s_SeenWidth || height != s_SeenHeight) {
        s_Changed = s_SeenWidth != 0;
        s_SeenWidth = width;
        s_SeenHeight = height;
        s_SeenAt = now;
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

    if ((width == m_StreamConfig.width && height == m_StreamConfig.height) ||
            width < DYNRES_MIN_WIDTH || height < DYNRES_MIN_HEIGHT) {
        return true;
    }

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "Window is now %dx%d; restarting the %dx%d stream to match",
                width, height, m_StreamConfig.width, m_StreamConfig.height);

    m_InputHandler->raiseAllKeys();

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
    m_InputHandler->setStreamSize(width, height);

    // LiStartConnection() fills unset callbacks with stubs in our struct. A
    // second call then rejects a pull renderer that "has" a submit callback.
    if (m_VideoCallbacks.capabilities & CAPABILITY_PULL_RENDERER) {
        m_VideoCallbacks.submitDecodeUnit = nullptr;
    }

    if (!startConnectionAsync()) {
        return false;
    }

    // LiStartConnection() only recorded the new format (see drSetup()). The
    // decoder itself is built by the event loop's renderer reset path.
    SDL_Event event = {};
    event.type = SDL_RENDER_DEVICE_RESET;
    SDL_PushEvent(&event);

    return true;
}
