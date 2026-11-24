#!/bin/bash
# Builds and starts the Mac side (mac-receiver.swift) as a LaunchAgent. Idempotent; run on the Mac:
#   bash ~/Sites/moonlight-qt/tools/sofa-hub/install-mac.sh
# It posts input events, so it needs Accessibility: System Settings > Privacy & Security >
# Accessibility > + > ~/.local/bin/sofa-receiver. Signed with the self-made "sofa-receiver" identity
# that grant survives rebuilds; without it the build is ad-hoc signed and needs granting again each time.
set -euo pipefail
cd "$(dirname "$0")"
bin=~/.local/bin/sofa-receiver
kc=~/Library/Keychains/sofa-signing.keychain-db
plist=~/Library/LaunchAgents/dev.eduwass.sofa-receiver.plist

mkdir -p ~/.local/bin
swiftc -O mac-receiver.swift -o "$bin.new"
if [ -f "$kc" ] && [ -f ~/.config/sofa-receiver/keychain-pass ]; then
  security unlock-keychain -p "$(cat ~/.config/sofa-receiver/keychain-pass)" "$kc"
  codesign -f -s sofa-receiver --keychain "$kc" -i dev.eduwass.sofa-receiver "$bin.new"
else
  echo "!! no sofa-receiver signing identity: ad-hoc signed, Accessibility must be granted again after every build"
  codesign -f -s - -i dev.eduwass.sofa-receiver "$bin.new"
fi
mv -f "$bin.new" "$bin"

sed "s#/Users/eduwass#$HOME#g" dev.eduwass.sofa-receiver.plist > "$plist"
launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "== running; log: ~/Library/Logs/sofa-receiver.log"
