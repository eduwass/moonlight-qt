// Self-check for the key mapping: bun check.ts
import { deepEqual, equal } from "node:assert/strict";
import { HID, KEY, isModeToggle, keyToHid, repeats, tvVolumeKey } from "./keys.ts";

const none = { meta: false, ctrl: false, alt: false, shift: false };
const cmd = { ...none, meta: true };
const hyper = { meta: true, ctrl: true, alt: true, shift: true };

equal(keyToHid(KEY.UP, none), HID.Up);
equal(keyToHid(KEY.ENTER, none), HID.Select);
equal(keyToHid(KEY.ESC, none), HID.Menu);
equal(keyToHid(KEY.H, cmd), HID.Home);
equal(keyToHid(KEY.H, none), null);
equal(keyToHid(KEY.SCALE, none), HID.Home, "Mission Control key goes home");
equal(keyToHid(KEY.F12, none), HID.VolumeUp, "F12 is volume up with F-keys first");
equal(keyToHid(KEY.UP, cmd), null, "a shortcut is not an arrow press");
equal(isModeToggle(KEY.ESC, hyper), true);
equal(isModeToggle(KEY.ESC, cmd), false);
equal(repeats(HID.Left), true);
equal(repeats(HID.Select), false);
equal(tvVolumeKey(KEY.VOLUMEUP, none), HID.VolumeUp, "volume up goes to the TV in a stream");
equal(tvVolumeKey(KEY.MUTE, none), HID.Mute);
equal(tvVolumeKey(KEY.F12, none), null, "F12 stays an F-key in a stream");
equal(tvVolumeKey(KEY.VOLUMEDOWN, { ...none, shift: true }), null, "with a modifier it is the computer's");

// The Sofa app link and the stats it carries.
{
  const { lineSplitter, peerAddress } = await import("./applink.ts");
  const { parseHost } = await import("./mac.ts");
  const { addresses, cpuPercent, cpuTimes, memory, screenApps, sofaDevices } = await import("./stats.ts");
  const split = lineSplitter();
  deepEqual(split('{"t":"scr'), [], "half a line waits");
  deepEqual(split('een"}\nstats {}\n\nidle'), ['{"t":"screen"}', "stats {}"], "whole lines out, blank ones dropped");
  deepEqual(split("\n"), ["idle"]);
  equal(peerAddress("::ffff:192.168.68.67"), "192.168.68.67");

  const a = cpuTimes("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3");
  deepEqual(a, { busy: 200, total: 1000 });
  equal(cpuPercent(a, cpuTimes("cpu  150 0 150 750 150 0 0 0 0 0")), 50, "idle and iowait are not busy");
  equal(cpuPercent(a, a), 0);
  deepEqual(memory("MemTotal:       1000 kB\nMemFree:  10 kB\nMemAvailable:    400 kB\nSwapTotal:  200 kB\nSwapFree: 50 kB\n"), {
    memUsed: 600 * 1024, memTotal: 1000 * 1024, swapUsed: 150 * 1024, swapTotal: 200 * 1024,
  });
  const v4 = (address: string, internal = false) => ({ address, internal, family: "IPv4" as const, netmask: "", mac: "", cidr: null });
  deepEqual(
    addresses({ lo: [v4("127.0.0.1", true)], eno1: [v4("192.168.68.63")], tailscale0: [v4("100.77.46.114")], docker0: [v4("172.17.0.1")], "br-1b30": [v4("172.18.0.1")] }),
    ["192.168.68.63", "100.77.46.114"],
    "LAN and Tailscale, no loopback or container bridges",
  );
  const w = (cls: string, title: string, focusHistoryID: number, more = {}) => ({ class: cls, title, focusHistoryID, mapped: true, hidden: false, visible: true, ...more });
  deepEqual(
    screenApps([
      w("com.mitchellh.ghostty", "~", 1),
      w("helium", "Recents · Paper - https://app.paper.design/ - Helium", 0),
      w("helium", "Other tab - Helium - edu", 2),
      w("obsidian", "notes", 3, { visible: false }),
      w("spotify", "x", 4),
    ]),
    ["Helium — Recents · Paper - https://app.paper.design/", "Ghostty", "Spotify"],
    "on screen only, most recent first, each app once, Helium with its tab",
  );
  deepEqual(sofaDevices({ "Magic Keyboard": 70, "Magic Trackpad": 98 }, { keyboard: true, trackpad: false }), [
    { kind: "keyboard", name: "Magic Keyboard", connected: true, battery: 70 },
    { kind: "trackpad", name: "Magic Trackpad", connected: false, battery: 98 },
  ]);
  equal(sofaDevices({}, { keyboard: false, trackpad: false })[0]!.battery, null, "no battery while it is off");
  deepEqual(screenApps([w("helium", "Tab - Helium - edu", 0)]), ["Helium — Tab"], "the profile name goes too");
  equal(parseHost('{"name":"MBP13","apps":[],"addresses":[]}')?.name, "MBP13");
  equal(parseHost('{"apps":[]}'), null);
  equal(parseHost("nope"), null);
}

// The app's pointer: one finger moves, a press clicks, two fingers scroll.
{
  const { MacTrackpad } = await import("./mac.ts");
  const { ABS, BTN, EV_ABS, EV_KEY } = await import("./palm.ts");
  const sent: { t: string }[] = [];
  const pad = new MacTrackpad((m) => sent.push(m));
  const a = (code: number, value: number) => ({ type: EV_ABS, code, value });
  pad.frame([a(ABS.MT_SLOT, 0), a(ABS.MT_TRACKING_ID, 1), a(ABS.MT_POSITION_X, 100), a(ABS.MT_POSITION_Y, 100)], 0);
  pad.frame([a(ABS.MT_POSITION_X, 200)], 10);
  pad.frame([{ type: EV_KEY, code: BTN.LEFT, value: 1 }], 20);
  equal(sent.map((m) => m.t).join(), "move,button");
  pad.reset();
  equal(sent.at(-1)?.t, "button", "reset lets go of the button");
}

// Palm rejection, touch by touch.
{
  const { ABS, BTN, EV_ABS, EV_KEY, PalmFilter } = await import("./palm.ts");
  const a = (code: number, value: number) => ({ type: EV_ABS, code, value });
  const k = (code: number, value: number) => ({ type: EV_KEY, code, value });
  const has = (out: { code: number; value: number }[], code: number, value: number) => out.some((e) => e.code === code && e.value === value);
  const land = (slot: number, id: number, major: number) => [a(ABS.MT_SLOT, slot), a(ABS.MT_TRACKING_ID, id), a(ABS.MT_TOUCH_MAJOR, major), a(ABS.MT_POSITION_X, 10 * slot), a(ABS.MT_POSITION_Y, 5)];

  const f = new PalmFilter(600);
  let out = f.frame([...land(0, 1, 300), k(BTN.TOUCH, 1)], false);
  equal(has(out, ABS.MT_TRACKING_ID, 1) && has(out, BTN.TOOL_FINGER, 1) && has(out, BTN.TOUCH, 1), true, "a finger passes");
  out = f.frame(land(1, 2, 300), true);
  equal(has(out, ABS.MT_TRACKING_ID, 2) || has(out, ABS.MT_SLOT, 1), false, "a touch that lands while typing is dropped");
  out = f.frame([a(ABS.MT_SLOT, 1), a(ABS.MT_POSITION_X, 99)], false);
  equal(has(out, ABS.MT_SLOT, 1) || has(out, ABS.MT_POSITION_X, 99), false, "and stays dropped after typing stops, until it lifts");
  out = f.frame([a(ABS.MT_SLOT, 0), a(ABS.MT_TOUCH_MAJOR, 800)], false);
  equal(has(out, ABS.MT_TRACKING_ID, -1) && has(out, BTN.TOUCH, 0), true, "a finger that grows palm-sized is lifted");
  out = f.frame([k(BTN.LEFT, 1)], false);
  equal(has(out, BTN.LEFT, 1), false, "a click with only palms down is dropped");
  out = f.frame([...land(2, 3, 250)], false);
  equal(has(out, ABS.MT_TRACKING_ID, 3) && has(out, BTN.TOOL_FINGER, 1), true, "a new finger works at once beside a resting palm");
  out = f.reset();
  equal(has(out, ABS.MT_TRACKING_ID, -1) && has(out, BTN.TOUCH, 0), true, "reset lifts what the desktop sees");
}
console.log("sofa-hub check passed");
