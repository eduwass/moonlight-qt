// Fork-only (eduwass/moonlight-qt): keep the Mac's own menu shortcuts out of a
// stream.
//
// SDL's keyboard grab stops the system shortcuts (Cmd+Tab, Cmd+Space, Mission
// Control), but the application menu's key equivalents are handled by AppKit
// before SDL sees the key: Cmd+H went to the host and also hid Moonlight here.
// While streaming there is nothing in that menu worth a shortcut, so they go.
// (Cmd+Q, Cmd+W and Cmd+M were measured and already only reach the host.)

#import <Cocoa/Cocoa.h>

void sysKeysSessionStarted()
{
    @autoreleasepool {
        NSMenu* appMenu = [[NSApp mainMenu] itemAtIndex:0].submenu;
        for (NSMenuItem* item in appMenu.itemArray) {
            if (item.action == @selector(hide:) || item.action == @selector(hideOtherApplications:)) {
                item.keyEquivalent = @"";
            }
        }
    }
}
