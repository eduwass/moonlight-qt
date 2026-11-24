# sofa-hub

The sofa keyboard drives the Apple TV, until omarchypc's desktop is streamed to it. Then the keyboard
and trackpad belong to the desktop. Runs on omarchypc as a systemd user service.

- **On the Apple TV:** arrows move, Enter selects, Esc/Backspace go back, ⌘H or F3 go home,
  Space or the play key play or pause, the volume keys change the TV's volume. The trackpad is held
  and does nothing, except as the pointer on the Sofa app's list of computers (below). The first key
  after two quiet minutes wakes the Apple TV first, which turns the TV on over HDMI-CEC.
- **Streaming omarchypc or the Mac:** the hub follows `CLIENT CONNECTED` / `CLIENT DISCONNECTED` in
  Sunshine's log (on the Mac, the receiver does) and lets go of both devices for the stream, but only
  when the sofa keyboard or trackpad was used in the 90 s before it started. A stream nobody on the
  sofa started (mbpmax watching omarchypc) leaves them on the Apple TV. A hub restarted mid-stream
  starts on the Apple TV too.
- **In a stream:** the volume keys (and mute) still go to the Apple TV (unless the Sofa app's
  `volumeKeysToTV` is off: then they are the computer's, and the hub leaves omarchypc's keyboard alone), which sets the TV's volume over
  HDMI-CEC; with a modifier held they are the computer's. For omarchypc the hub holds keyd's keyboard
  and gives the desktop a copy without them (`sofa keyboard`, keyd's vendor id 0fac so keyd leaves it
  alone), or Sunshine's sound would go down too.
- **In a stream:** the desktop gets a copy of the trackpad with palms filtered out touch by touch
  (`palm.ts`): a touch that lands within 0.3 s of a key, or grows palm-sized, is dropped until lifted.
- **Leaving a stream:** tap Esc three times quickly (or hold it 5 s): the keyboard goes back to the
  Apple TV, and Menu there ends the stream on the Sofa app's list of computers. If the stream is still
  up 2.5 s later, Home leaves the app instead.
- **By hand:** Caps+Esc, or `bun hub.ts mode tv|desktop|toggle`.

## The Sofa app link

The Sofa app on the Apple TV connects to TCP 47902 (`SOFA_APP_PORT`; only `SOFA_APP_PEERS`, default
the Apple TV at 192.168.68.67; the newest connection wins). One JSON object per line.

```jsonc
// app -> hub, whenever its screen changes
{"t":"screen","name":"home"}            // or "stream", "other"

// app -> hub, on connect and on every change; kept in ~/.config/sofa-hub/app-settings.json across restarts
{"t":"settings","statsEvery":5,"previewsEvery":300,"tvScale":1.6,"trackpadSpeed":0.6875,"tapToClick":false,
 "naturalScroll":true,"volumeKeysToTV":true,"apps":"titles"}   // apps: "titles" | "names" | "off"

// app -> hub: restart a computer; the hub answers {"t":"restart","host":"MBP13","ok":false,"error":"..."}
{"t":"restart","host":"omarchypc"}      // or "MBP13"

// hub -> app: on connect, and when the Mac's receiver comes or goes. version is the installed commit
{"t":"hello","version":"053b2f44","receiver":true,"hubUptime":3600}

// hub -> app: on connect, then when it changes (checked every 10 s); battery is null while a device is off
{"t":"devices","bridge":true,"devices":[{"kind":"keyboard","name":"Magic Keyboard","connected":true,"battery":70},
                                        {"kind":"trackpad","name":"Magic Trackpad","connected":true,"battery":98}]}

// hub -> app: on the home screen only, on arriving and then every statsEvery s. omarchypc's own, and the
// Mac's while its receiver reported in the last 20 s
{"t":"stats","hosts":[{"name":"omarchypc","hostname":"eduwass-omarchy-1","addresses":["192.168.68.63","100.77.46.114"],
  "cpu":9.9,"memUsed":4751499264,"memTotal":16589463552,"swapUsed":41746432,"swapTotal":33183481856,
  "diskUsed":319164489728,"diskTotal":477936746496,"uptime":77130,"apps":["Helium — Google"],
  "os":"linux","pressure":"normal"}]}    // pressure: "normal" | "warn" | "critical"

// hub -> app: on the home screen only, every previewsEvery s, and on arriving if the last is older than that
{"t":"preview","host":"omarchypc","jpeg":"<base64, ~640 px wide, under 150 KB>","at":1795454006}

// hub -> app: the trackpad, only on the home screen with input on the Apple TV (Mac-shaped, see mac.ts)
{"t":"move","dx":3.2,"dy":-1.5}
{"t":"button","b":"left","down":true}  // b: "left" | "right" (two fingers)
{"t":"scroll","dx":0,"dy":12.5,"phase":2,"momentum":0}  // CGScrollPhase / CGMomentumScrollPhase values
```

cpu is % busy since the last sample; sizes are bytes; uptime is seconds; apps are what is on screen,
most recent first, at most 5, browsers with their tab (no address) unless `apps` says otherwise.
omarchypc's come from `/proc`, `statfs /` and `hyprctl clients -j`, pressure from `/proc/pressure/memory`
(some avg10 over 10 warn, over 30 critical, or under a tenth of memory available), its preview from
`grim`; batteries from `/sys/class/power_supply/hid-*-battery*`. The Mac's receiver sends `stats <json>`
lines every 5 s (pressure from `kern.memorystatus_vm_pressure_level`), and answers the hub's `preview`
with `preview <base64>` or `preview-failed no-permission`, and `restart` with `restarting` or
`restart-failed <why>`. `tvScale` is omarchypc's scale on the TV from the next stream; `trackpadSpeed`,
`tapToClick` and `naturalScroll` are the app's pointer and the Mac's.

Restarting omarchypc is `systemctl reboot` (logind allows the session's user; the disk unlocks and it
logs in by itself). Restarting the Mac is `fdesetup authrestart`, so it comes back logged in too.
To watch it from another machine, add its address to `SOFA_APP_PEERS` and `nc omarchypc 47902`.

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
- On the Mac, give `~/.local/bin/sofa-receiver` Accessibility (see `install-mac.sh`), and Screen Recording
  for the app's previews: System Settings > Privacy & Security > Screen & System Audio Recording > + >
  `~/.local/bin/sofa-receiver` (it adds itself, off, on its first preview), then reinstall or restart it.
- On the Mac, `bash setup-mac-restart.sh` in a terminal, once, so the app can restart it: a sudo rule for
  `fdesetup authrestart -inputplist` and the login password in the keychain as `sofa-receiver-login`.

`system/` also sets `hid_apple fnmode=1` (media keys first, Fn for F1–F12) and lowers libinput's palm
size threshold to 600 for this trackpad.

## Check

```sh
bun check.ts
```
