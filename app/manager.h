// Fork-only (eduwass/moonlight-qt): the app's own window, see manager_mac.mm.
#pragma once

// Opens the list of devices. Returns at once; the window lives in the app's loop.
void managerStart();

// A moonlightnext:// link was opened (manager_mac.mm lists what one can say).
void managerOpenUrl(const char* url);

// The Dock icon was clicked with no window showing.
void managerShow();

#ifdef __OBJC__
@class NSArray, NSString, NSDictionary;
// The devices, as saved (read from the defaults when the app's own window is not open: a stream's process).
NSArray* managerDevices();
// Gives a device its own bitrate (kbps, 0 for automatic), by name.
void managerSetDeviceBitrate(NSString* name, long kbps);
// Remembers where a device's stream window was left and how large: its left
// edge and its top in Cocoa's screen coordinates, and its size in points.
void managerSetDeviceWindow(NSString* name, long left, long top, long width, long height);
#endif
