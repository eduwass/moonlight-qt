// Self-check for the key mapping: bun check.ts
import { deepEqual, equal, ok } from "node:assert/strict";
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

// The app's settings, what its list of computers shows, and the pointer it configures.
{
  const { DEFAULTS, parseSettings } = await import("./settings.ts");
  const { grimScale, linuxPressure, shapeApps, trimUrl } = await import("./stats.ts");
  const { MacTrackpad } = await import("./mac.ts");
  const { ABS, EV_ABS } = await import("./palm.ts");

  const s = parseSettings({ t: "settings", statsEvery: 30, previewsEvery: 300, tvMode: "3840x2160@60", tvScale: 2, trackpadSpeed: 1, tapToClick: true, naturalScroll: false, volumeKeysToTV: false, apps: "names", instantCursor: false });
  deepEqual(s, { statsEvery: 30, previewsEvery: 300, tvMode: "3840x2160@60", tvScale: 2, trackpadSpeed: 1, tapToClick: true, naturalScroll: false, volumeKeysToTV: false, apps: "names", instantCursor: false });
  deepEqual(parseSettings({ statsEvery: -1, tvMode: "4k", tvScale: "big", apps: "all", naturalScroll: 1 }, s), s, "bad fields keep what was there");
  deepEqual(parseSettings({}), DEFAULTS);

  equal(trimUrl("Recents · Paper - https://app.paper.design/"), "Recents · Paper");
  equal(trimUrl("Docs - http://localhost:3000/a?b=c"), "Docs");
  equal(trimUrl("A - B"), "A - B", "only an address at the end goes");
  const apps = ["Helium — Docs - https://x.dev/", "Ghostty"];
  deepEqual(shapeApps(apps, "titles"), ["Helium — Docs", "Ghostty"]);
  deepEqual(shapeApps(apps, "names"), ["Helium", "Ghostty"]);
  deepEqual(shapeApps(apps, "off"), []);

  const mem = (availKb: number) => `MemTotal: 1000 kB\nMemAvailable: ${availKb} kB\n`;
  equal(linuxPressure("some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00", mem(500)), "normal");
  equal(linuxPressure("some avg10=12.50 avg60=1.00 avg300=0.00 total=1", mem(500)), "warn");
  equal(linuxPressure("some avg10=31.00 avg60=1.00 avg300=0.00 total=1", mem(500)), "critical");
  equal(linuxPressure("some avg10=0.00", mem(90)), "critical", "under a tenth available");
  equal(linuxPressure("", ""), "normal", "no PSI, no meminfo");

  equal(grimScale([{ width: 1920, height: 1080, scale: 1.6, x: 0 }]), 640 / 1200, "a 1200 px wide layout to 640");
  equal(grimScale([{ width: 1920, height: 1080, scale: 1, x: 0 }, { width: 1920, height: 1080, scale: 1, x: 1920 }]), 640 / 3840);
  equal(grimScale([{ width: 320, height: 200, scale: 1, x: 0 }]), 1, "never larger than the screen");

  const a = (code: number, value: number) => ({ type: EV_ABS, code, value });
  const twoFingerScroll = (pad: InstanceType<typeof MacTrackpad>) => {
    pad.frame([a(ABS.MT_SLOT, 0), a(ABS.MT_TRACKING_ID, 1), a(ABS.MT_POSITION_X, 100), a(ABS.MT_POSITION_Y, 100), a(ABS.MT_SLOT, 1), a(ABS.MT_TRACKING_ID, 2), a(ABS.MT_POSITION_X, 600), a(ABS.MT_POSITION_Y, 100)], 0);
    for (let i = 1; i <= 5; i++) pad.frame([a(ABS.MT_SLOT, 0), a(ABS.MT_POSITION_Y, 100 + 60 * i), a(ABS.MT_SLOT, 1), a(ABS.MT_POSITION_Y, 100 + 60 * i)], 10 * i);
  };
  const scrolls = (naturalScroll: boolean) => {
    const sent: { t: string; dy?: number }[] = [];
    twoFingerScroll(new MacTrackpad((m) => sent.push(m), { naturalScroll }));
    return sent.filter((m) => m.t === "scroll").map((m) => Math.sign(m.dy ?? 0));
  };
  equal(scrolls(true).at(-1), 1, "natural: the content follows the fingers down");
  equal(scrolls(false).at(-1), -1, "not natural: the other way");

  const taps = (tapToClick: boolean) => {
    const sent: { t: string }[] = [];
    const pad = new MacTrackpad((m) => sent.push(m), { tapToClick });
    pad.frame([a(ABS.MT_SLOT, 0), a(ABS.MT_TRACKING_ID, 1), a(ABS.MT_POSITION_X, 100), a(ABS.MT_POSITION_Y, 100)], 0);
    pad.frame([a(ABS.MT_TRACKING_ID, -1)], 50);
    return sent.filter((m) => m.t === "button").length;
  };
  equal(taps(false), 0, "press to click: a tap does nothing");
  equal(taps(true), 2, "tap to click: a tap is a click, down and up");
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
// Sizes on the TV, and the test tone.
{
  const { captureFactor, hyprScale, macDisplayFacts, monitorLua, outputState, pathMs, sizeTarget, sunshineStreaming, tvDisplayFacts } = await import("./display.ts");
  const { parseMode } = await import("./settings.ts");
  const { toneWav } = await import("./tone.ts");
  equal(hyprScale(1.25, 1920, 1080), 1.25);
  equal(hyprScale(1.6, 1920, 1080), 1.6);
  equal(hyprScale(1.3, 1920, 1080), 1.3333333333333333, "to the nearest scale with whole logical pixels");
  equal(hyprScale(1.26, 1920, 1080), 1.25, "down when that is nearer");
  equal(hyprScale(9, 1920, 1080), 10, "the larger on a tie");
  const fhd = { width: 1920, height: 1080, fps: 60 };
  const tv = tvDisplayFacts(fhd, 1.25, "");
  deepEqual([tv.pixels, tv.scale, tv.looks, tv.tryable, tv.why], [[1920, 1080], 1.25, [1536, 864], true, ""]);
  deepEqual(tv.modes, [[1920, 1080], [2560, 1440], [3840, 2160]]);
  deepEqual(tv.sizes?.map((x) => x.looks), [[960, 540], [1200, 675], [1536, 864], [1920, 1080]]);
  deepEqual(tvDisplayFacts({ width: 3840, height: 2160, fps: 60 }, 3.2, "").looks, [1200, 675], "4K, Larger");
  equal(tvDisplayFacts(fhd, 1, "streamed from another device").tryable, false);
  deepEqual(sizeTarget([3840, 2160], [1200, 675]), { width: 3840, height: 2160, fps: 60, scale: 3.2, looks: [1200, 675] });
  deepEqual(sizeTarget([2560, 1440], [1200, 675]), { width: 2560, height: 1440, fps: 60, scale: 256 / 120, looks: [1200, 675] });
  deepEqual(sizeTarget([2560, 1440], [1000, 700]).looks, [1024, 576], "an odd size: the nearest scale, and the size it really looks");
  for (const [w, h] of tv.modes!) for (const { looks } of tv.sizes!) deepEqual(sizeTarget([w, h], looks).looks, looks, `${w}x${h} looking ${looks}`);
  equal(captureFactor(1920, 1.25), 1.25, "1080p: the picture at full pixels");
  equal(captureFactor(3840, 3.2) * (3840 / 3.2), 1920, "4K: scaled down to 1920 wide");
  deepEqual(parseMode("3840x2160@60"), { width: 3840, height: 2160, fps: 60 });
  equal(parseMode("4k"), null);
  equal(parseMode("100x100@60"), null);
  equal(pathMs([40, 10, 12, 11, 500]), 6, "half the median round trip");
  equal(pathMs([]), null);
  const mac = macDisplayFacts({ pixels: [1920, 1080], scale: 2, looks: [960, 540] }, "");
  deepEqual([mac.modes, mac.tryable, mac.perComputer, mac.sizes?.length], [[[1920, 1080]], true, true, 4]);
  equal(macDisplayFacts({ pixels: [1920, 1080], scale: 2, looks: [960, 540] }, "streamed right now").tryable, false);
  equal(sunshineStreaming("[a]: Info: CLIENT CONNECTED\n[b]: Info: CLIENT DISCONNECTED\n"), false);
  equal(sunshineStreaming("[b]: Info: CLIENT DISCONNECTED\n[c]: Info: CLIENT CONNECTED\n[d]: Info: x"), true);
  equal(sunshineStreaming("nothing"), null);
  const out = outputState({ name: "virtual", width: 3440, height: 1440, refreshRate: 59.94, scale: 1.333333 });
  deepEqual(out, { mode: "3440x1440@60", scale: 1.333333 });
  equal(monitorLua(out), 'hl.monitor({ output = "virtual", mode = "3440x1440@60", position = "auto", scale = 1.333333 })');

  const wav = toneWav(1);
  const v = new DataView(wav.buffer);
  equal(new TextDecoder().decode(wav.subarray(0, 4)) + new TextDecoder().decode(wav.subarray(8, 12)), "RIFFWAVE");
  equal(wav.length, 44 + 48_000 * 4, "1 s of 48 kHz 16-bit stereo");
  equal(v.getUint32(40, true), 48_000 * 4);
  let peak = 0;
  for (let i = 44; i < wav.length; i += 2) peak = Math.max(peak, Math.abs(v.getInt16(i, true)));
  equal(Math.abs(peak - Math.round(32767 * 10 ** (-12 / 20))) <= 2, true, "-12 dBFS peak");
  equal(Math.abs(v.getInt16(44 + 4 * 5, true)) < 0.1 * peak, true, "fades in");
  equal(v.getInt16(wav.length - 4, true), 0, "and out to silence");
}
{
  // speed.ts: everything written for the time asked arrives at a listener.
  const { sendSpeed } = await import("./speed.ts");
  let got = 0;
  const server = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data: (_s, d) => void (got += d.length) } });
  const sent = await sendSpeed("127.0.0.1", server.port, 1);
  await Bun.sleep(200);
  server.stop(true);
  ok(sent > 0 && got === sent, `speed: sent ${sent}, got ${got}`);
}
console.log("sofa-hub check passed");
