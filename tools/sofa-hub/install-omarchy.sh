#!/bin/bash
# Sets omarchypc up for the sofa keyboard and trackpad. Idempotent; run on omarchypc from anywhere:
#   bash ~/Sites/moonlight-qt/tools/sofa-hub/install-omarchy.sh
# Hyprland's side (curves, swipes, key repeat, press to click) lives in dotfiles' .config/hypr/input.lua.
# Not covered: pairing the keyboard and trackpad over Bluetooth, and the Apple TV (`bun hub.ts pair` after).
set -euo pipefail
cd "$(dirname "$0")"
dir=~/.local/share/sofa-hub

echo "== system files (sudo)"
sudo install -Dm644 system/70-sofa-hub.rules /etc/udev/rules.d/70-sofa-hub.rules
sudo install -Dm644 system/81-disable-internal-bt.rules /etc/udev/rules.d/81-disable-internal-bt.rules
sudo install -Dm644 system/btusb-no-autosuspend.conf /etc/modprobe.d/btusb-no-autosuspend.conf
sudo install -Dm644 system/hid_apple.conf /etc/modprobe.d/hid_apple.conf
sudo install -Dm644 system/local-overrides.quirks /etc/libinput/local-overrides.quirks
sudo udevadm control --reload && sudo udevadm trigger -s input
echo 1 | sudo tee /sys/module/hid_apple/parameters/fnmode >/dev/null 2>&1 || true
nmcli radio wifi off 2>/dev/null || sudo nmcli radio wifi off || true # wired; Wi-Fi only crowds the Bluetooth band

echo "== hub"
mkdir -p "$dir"
cp ./*.ts "$dir/"
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
