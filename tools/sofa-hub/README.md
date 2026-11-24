# sofa-hub

The sofa keyboard drives the Apple TV, until omarchypc's desktop is streamed to it. Then the keyboard
and trackpad belong to the desktop. Runs on omarchypc as a systemd user service.

- **On the Apple TV:** arrows move, Enter selects, Esc/Backspace go back, ⌘H or F3 go home,
  Space or the play key play or pause, the volume keys change the TV's volume. The trackpad is held
  and does nothing.
- **Streaming omarchypc:** the hub follows `CLIENT CONNECTED` / `CLIENT DISCONNECTED` in Sunshine's
  log and lets go of both devices for the stream.
- **In a stream:** the desktop gets a copy of the trackpad with palms filtered out touch by touch
  (`palm.ts`): a touch that lands within 0.3 s of a key, or grows palm-sized, is dropped until lifted.
- **By hand:** Caps+Esc, or `bun hub.ts mode tv|desktop|toggle`.

## Install

```sh
bash install-omarchy.sh   # on omarchypc: system files, hub, systemd user service
bash install-mac.sh       # on the Mac: builds the receiver and starts its LaunchAgent
```

dotfiles' `scripts/omarchy/replay.sh` runs `install-omarchy.sh` when this repo is checked out.
Hyprland's side (3- and 4-finger swipes into empty workspaces, the macOS pointer and scroll curves from
`T=0.875 PTS=1 bun curve.ts`, Mac key repeat, press to click) is in dotfiles' `.config/hypr/input.lua`.

By hand, once per install:

- Pair the keyboard and trackpad with the HOMMIE dongle (RTL8761B, on a USB extension outside the
  cabinet). `system/` turns the weak internal Intel 7260 off and keeps the dongle from autosuspending.
- Pair with the Apple TV: `bun hub.ts pair` in `~/.local/share/sofa-hub`, then type the PIN it shows.
  Credentials go to `~/.config/bunatv.json`.
- On the Mac, give `~/.local/bin/sofa-receiver` Accessibility (see `install-mac.sh`).

`system/` also sets `hid_apple fnmode=1` (media keys first, Fn for F1–F12) and lowers libinput's palm
size threshold to 600 for this trackpad.

## Check

```sh
bun check.ts
```
