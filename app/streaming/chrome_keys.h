// Fork-only (eduwass/moonlight-qt): the chrome's shortcuts, shared by the bar
// (chrome_mac.mm) and the settings window (chrome_settings_mac.mm).
// Objective-C++ only.
#pragma once

#import <Cocoa/Cocoa.h>

enum { KEY_BAR, KEY_INFO, KEY_STATS, KEY_TRUE_PIXELS, KEY_FOLLOW, KEY_FULLSCREEN, KEY_COUNT };
enum { MOD_CTRL = 1, MOD_ALT = 2, MOD_SHIFT = 4, MOD_CMD = 8 };

// key is the SDL key code, which for anything printable is the character
// itself, lower case; mods is a set of MOD_ values.
struct ChromeBinding {
    int key;
    int mods;
};

ChromeBinding chromeBinding(int which);
NSString* chromeBindingText(int which); // "⌃⌥⇧B"
void chromeSettingsOpen(const char* host);
