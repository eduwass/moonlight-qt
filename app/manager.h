// Fork-only (eduwass/moonlight-qt): the app's own window, see manager_mac.mm.
#pragma once

// Opens the list of devices. Returns at once; the window lives in the app's loop.
void managerStart();

// A moonlightnext:// link was opened (manager_mac.mm lists what one can say).
void managerOpenUrl(const char* url);

// The Dock icon was clicked with no window showing.
void managerShow();
