// Fork-only (eduwass/moonlight-qt): what the stream window's chrome
// (chrome_mac.mm) and the session (dynres.cpp) say to each other.
#pragma once

struct SDL_Window;

// What a click on the bar asks for. CHROME_SHOWN is not a click: the bar
// has appeared or gone, and wants its numbers kept fresh or left alone.
enum {
    CHROME_STATS,
    CHROME_TRUE_PIXELS,
    CHROME_FOLLOW,
    CHROME_FULLSCREEN,
    CHROME_SHOWN,
};

enum { CHROME_THUNDERBOLT, CHROME_ETHERNET, CHROME_WIFI, CHROME_TAILSCALE, CHROME_OTHER };
enum { CHROME_GOOD, CHROME_FAIR, CHROME_POOR };

// Where a reading stops being good, and where it becomes poor. From the day
// this was measured: on the Thunderbolt link the delay Moonlight reports is
// 1 ms with nothing lost; over Wi-Fi it was 7 to 9 ms.
#define CHROME_DELAY_FAIR_MS 5
#define CHROME_DELAY_POOR_MS 30
#define CHROME_LOSS_FAIR_PERCENT 0.1
#define CHROME_LOSS_POOR_PERCENT 1.0

struct ChromeState {
    bool stats, truePixels, followSize, fullscreen;
    bool busy;          // the stream is restarting
    int link;           // CHROME_THUNDERBOLT ...
    bool relayed;       // Tailscale is going through a relay
    int verdict;        // CHROME_GOOD ...
    int width, height, fps;
    int delayMs;        // network round trip, as Moonlight estimates it
    double lostPercent; // video packets that could not be repaired, lately
    char host[64];
};

#ifdef __APPLE__
void chromeStart(SDL_Window* window, void (*action)(int));
void chromeUpdate(const ChromeState* state);
bool chromeShown();
void chromeRaise();          // something was put on top of the window's content; go back above it
void chromeLeftFullscreen(); // the window is back from fullscreen and has its style again
#else
static inline void chromeStart(SDL_Window*, void (*)(int)) {}
static inline void chromeUpdate(const ChromeState*) {}
static inline bool chromeShown() { return false; }
static inline void chromeRaise() {}
static inline void chromeLeftFullscreen() {}
#endif

// netpath.cpp: the kind of link the stream is on, CHROME_THUNDERBOLT ..., and
// whether Tailscale is relaying it.
int netPathLink();
bool netPathRelayed();
