#!/bin/bash
# check-clipboard: the shared clipboard's archive reader against archives it
# must take and must refuse (the self-check at the end of clipboard_mac.mm).
# Needs a Mac with the SDL headers the app is built with.
#   scripts/check-clipboard.sh
cd "$(dirname "$0")/.." || exit 1
out=$(mktemp -d)
clang++ -x objective-c++ -std=c++17 -fno-objc-arc -w -DCLIPBOARD_SELFTEST -I app $(sdl2-config --cflags) \
  app/streaming/clipboard_mac.mm -framework Cocoa $(sdl2-config --libs) -o "$out/selftest" || { rm -rf "$out"; exit 1; }
"$out/selftest"; status=$?
rm -rf "$out"
exit $status
