#!/bin/bash
# Sets omarchypc up for the sofa keyboard and trackpad. Idempotent; run on omarchypc from anywhere:
#   bash ~/Sites/moonlight-qt/tools/sofa-hub/install-omarchy.sh
# Hyprland's side (curves, swipes, key repeat, press to click) lives in dotfiles' .config/hypr/input.lua.
# Not covered: pairing the keyboard and trackpad over Bluetooth, and the Apple TV (`bun hub.ts pair` after).
set -euo pipefail
cd "$(dirname "$0")"
dir=~/.local/share/sofa-hub

# Restarting the hub mid-stream takes the keyboard and trackpad away from whoever is on the sofa.
if [ -z "${FORCE:-}" ] && grep -q true "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sofa-hub-streams.json" 2>/dev/null; then
  echo "!! a stream is being watched from the sofa; not restarting the hub (FORCE=1 to anyway)"; exit 1
fi

echo "== system files (sudo)"
sudo install -Dm644 system/70-sofa-hub.rules /etc/udev/rules.d/70-sofa-hub.rules
sudo install -Dm644 system/81-disable-internal-bt.rules /etc/udev/rules.d/81-disable-internal-bt.rules
sudo install -Dm644 system/btusb-no-autosuspend.conf /etc/modprobe.d/btusb-no-autosuspend.conf
sudo install -Dm644 system/hid_apple.conf /etc/modprobe.d/hid_apple.conf
sudo install -Dm644 system/local-overrides.quirks /etc/libinput/local-overrides.quirks
sudo udevadm control --reload && sudo udevadm trigger -s input
echo 1 | sudo tee /sys/module/hid_apple/parameters/fnmode >/dev/null 2>&1 || true
sudo ufw allow proto tcp from 192.168.68.67 to any port 47902 comment sofa-app >/dev/null # the Apple TV's Sofa app (hub.ts)
sudo ufw allow proto tcp from 192.168.68.67 to any port 47903 comment sofa-speed >/dev/null # its connection check (hub.ts)
nmcli radio wifi off 2>/dev/null || sudo nmcli radio wifi off || true # wired; Wi-Fi only crowds the Bluetooth band

echo "== hub"
mkdir -p "$dir"
cp ./*.ts "$dir/"
# The commit the Sofa app sees in the hub's hello ("+" when this folder has changes not committed).
version=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
[ "$version" = dev ] || git diff --quiet HEAD -- . || version="$version+"
echo "$version" > "$dir/VERSION"
if [ ! -d "$dir/bunatv" ]; then
  git clone -q https://github.com/JarekToro/bunatv.git "$dir/bunatv" # Apple TV Companion protocol; alpha, unlicensed
fi
git -C "$dir/bunatv" checkout -q b3842e3
(cd "$dir/bunatv" && bun install --ignore-scripts >/dev/null)
(cd "$dir" && bun check.ts)

mkdir -p ~/.config/systemd/user
cp sofa-hub.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable sofa-hub >/dev/null
systemctl --user restart sofa-hub

[ -f ~/.config/bunatv.json ] || echo "!! not paired with the Apple TV yet: (cd $dir && bun hub.ts pair)"
echo "== done"
