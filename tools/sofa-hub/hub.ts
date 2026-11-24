// sofa-hub: the sofa keyboard drives the Apple TV, omarchypc's desktop while it is streamed, or the
// Mac while it is streamed (through mac-receiver.swift on the Mac, see mac.ts).
// In a stream the desktop gets a copy of the trackpad with palms filtered out, touch by touch (palm.ts).
// The trackpad only works in a stream, or as the pointer on the Sofa app's home screen (applink.ts);
// elsewhere on the Apple TV it is held so stray touches do nothing.
// The volume keys go to the Apple TV, which sets the TV's volume over HDMI-CEC; in a stream of omarchypc
// the desktop gets the keyboard through the hub's own copy of it, without them. The Sofa app can turn
// that off, and sets the trackpad, the stats and previews it gets, and restarts computers (settings.ts).
// It also tries sizes for omarchypc's desktop on the TV (display.ts) and plays a test tone (tone.ts).
//
//   bun hub.ts                  run the hub (the systemd user service does this)
//   bun hub.ts mode tv|desktop|mac|toggle    tell the running hub where input goes
//   bun hub.ts pair             pair with the Apple TV once (type the PIN it shows)
import { existsSync, readFileSync, rmSync, unlinkSync } from "node:fs";
import { AppLink } from "./applink.ts";
import { AppleTv } from "./appletv.ts";
import { SizeTrial, macDisplayFacts, pathMs, sizeTarget, sunshineStreaming, tvDisplayFacts, virtualOutput } from "./display.ts";
import { EV_KEY, InputDevice, deviceId, findEventNode, type InputEvent } from "./evdev.ts";
import { HID, KEY, type Modifiers, isModeToggle, keyToHid, repeats, tvVolumeKey } from "./keys.ts";
import { MacLink, MacTrackpad } from "./mac.ts";
import { BTN, PalmFilter } from "./palm.ts";
import { loadSettings, parseMode, parseSettings, saveSettings } from "./settings.ts";
import { type Host, PREVIEW_MAX, hidBatteries, localHost, localPreview, shapeApps, sofaDevices } from "./stats.ts";
import { sendSpeed } from "./speed.ts";
import { playTone } from "./tone.ts";
import { type AbsInfo, VirtualDevice } from "./uinput.ts";

type Mode = "tv" | "desktop" | "mac";
const SOCKET = `${process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`}/sofa-hub.sock`;
const KEYBOARD = "keyd virtual keyboard"; // keyd already merges every keyboard into this one
const TRACKPAD = "Apple Inc. Magic Trackpad";

if (process.argv[2] === "mode") {
  const wanted = process.argv[3];
  if (!["tv", "desktop", "mac", "toggle", "screenshot"].includes(wanted ?? "")) throw new Error("usage: bun hub.ts mode tv|desktop|mac|toggle|screenshot");
  const reply = await new Promise<string>((resolve, reject) => {
    Bun.connect({
      unix: SOCKET,
      socket: {
        open: (s) => void s.write(`${wanted}\n`),
        data: (s, d) => (resolve(d.toString().trim()), s.end()),
        error: (_, e) => reject(e),
        connectError: (_, e) => reject(e),
      },
    }).catch(reject);
  });
  console.log(reply);
  process.exit(0);
}

const tv = new AppleTv(process.env.SOFA_APPLE_TV ?? "Living Room");

if (process.argv[2] === "pair") {
  await tv.pair(async () => (prompt("PIN shown on the Apple TV:") ?? "").trim());
  console.log("paired");
  process.exit(0);
}
let mode: Mode = "desktop"; // until the start-up decides
let settings = loadSettings();
const devices = new Map<string, InputDevice>();
const mods: Modifiers = { meta: false, ctrl: false, alt: false, shift: false };
const held = new Map<number, number>(); // key code -> Apple TV button it pressed

function setMode(next: Mode): void {
  if (next !== mode) {
    console.log(`mode: ${next}`);
    // Lift whatever the place input is leaving still thinks is held.
    if (mode === "desktop") virtualPad?.write(palm.reset()), liftKeys();
    if (mode === "mac") macPad.reset(), mac.send({ t: "reset" }), palm.reset();
    if (mode === "tv") releaseAll(), appPad.reset(), palm.reset();
  }
  mode = next;
  for (const [name, device] of devices) device.grab(wantsGrab(name));
  if (mode === "tv") void tv.ready().catch(() => {});
}

// Whoever is being streamed gets the input: omarchypc first, then the Mac, else the Apple TV.
// A stream only counts when it is watched from the sofa: one that starts with no sofa input in the
// last SOFA_CLAIM_MS is another client (mbpmax streaming omarchypc or mbp13), and the keyboard stays
// on the Apple TV. Caps+Esc still switches by hand.
const SOFA_CLAIM_MS = 90_000;
let lastSofaInputAt = 0;
const fromSofa = () => Date.now() - lastSofaInputAt < SOFA_CLAIM_MS;
let desktopStreamed = false;
let macStreamed = false;
let macLive = false; // the Mac is being streamed, by anyone
const KEY_B = 48; // linux/input-event-codes.h
// The streams being watched outlive a restart of the hub (a deploy), so input stays where it was.
// ponytail: a stream that ends while the hub is down is missed; holding Esc 5 s gets back to the Apple TV.
const STATE = `${process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`}/sofa-hub-streams.json`;
const decide = () => {
  void Bun.write(STATE, JSON.stringify({ desktopStreamed, macStreamed }));
  setMode(desktopStreamed ? "desktop" : macStreamed ? "mac" : "tv");
};
// A choice by hand (Caps+Esc, `bun hub.ts mode`) stands until the next stream starts or ends.
const choose = (next: Mode) => {
  desktopStreamed = next === "desktop";
  macStreamed = next === "mac";
  decide();
};

function releaseAll(): void {
  for (const hid of held.values()) void tv.button(hid, false);
  held.clear();
}

// ----------------------------------------------------------------- palm rejection
// The hub holds the real trackpad and gives the desktop a virtual copy carrying only the touches
// PalmFilter lets through: none that began within TYPING_MS of a key, none that grew palm-sized.
// If the copy cannot be made, the real trackpad is left to the desktop as it was.

const TYPING_MS = Number(process.env.SOFA_TYPING_MS ?? 300);
const palm = new PalmFilter(Number(process.env.SOFA_PALM_MAJOR ?? 600));
const TRACKPAD_AXES = [0, 1, 24, 47, 48, 49, 52, 53, 54, 57, 58]; // X Y PRESSURE, MT slot/size/angle/position/id/pressure
let virtualPad: VirtualDevice | null = null;
let lastKeyAt = 0;

const wantsGrab = (name: string) =>
  name === KEYBOARD && keyCopy()
    ? true // the desktop gets the keyboard through virtualKeys
    : name === KEYBOARD && escDown
      ? mode !== "desktop" && mode !== "tv"
      : mode !== "desktop" || (name === TRACKPAD && virtualPad !== null);
const regrab = () => { for (const [name, device] of devices) device.grab(wantsGrab(name)); };

function makeVirtualPad(real: InputDevice): void {
  const id = deviceId(TRACKPAD);
  if (virtualPad || !id) return;
  const abs = new Map<number, AbsInfo>();
  for (const code of TRACKPAD_AXES) {
    const info = real.absInfo(code);
    if (info) abs.set(code, info);
  }
  const keys = [BTN.LEFT, BTN.TOOL_FINGER, BTN.TOOL_DOUBLETAP, BTN.TOOL_TRIPLETAP, BTN.TOOL_QUADTAP, BTN.TOOL_QUINTTAP, BTN.TOUCH];
  try {
    // Same ids as the real one, so libinput applies its Apple quirks to the copy.
    virtualPad = new VirtualDevice({ name: `${TRACKPAD} (sofa)`, id, props: [0, 2], keys, abs }); // POINTER, BUTTONPAD
    console.log("palm rejection: virtual trackpad ready");
  } catch (error) {
    console.error(`palm rejection off, no virtual trackpad: ${(error as Error).message}`);
  }
}

function onTrackpad(events: InputEvent[]): void {
  lastSofaInputAt = Date.now();
  const typing = Date.now() - lastKeyAt < TYPING_MS;
  if (mode === "desktop") virtualPad?.write(palm.frame(events, typing));
  else if (mode === "mac") macPad.frame(palm.frame(events, typing));
  else if (app.screen === "home") appPad.frame(palm.frame(events, typing));
}

// ----------------------------------------------------------------- the Mac

const tailscaleIp = Bun.spawnSync(["tailscale", "ip", "-4"]).stdout.toString().trim();
const mac = new MacLink(
  process.env.SOFA_MAC_LISTEN ?? (tailscaleIp || "127.0.0.1"),
  Number(process.env.SOFA_MAC_PORT ?? 47901),
  (process.env.SOFA_MAC_PEERS ?? "100.114.79.7").split(","), // mbp13 over Tailscale
  {
    streaming: (on) => {
      macLive = on;
      if (!on) streamEnded();
      macStreamed = on && (macStreamed || fromSofa()); // a stream the sofa was on stays the sofa's
      if (on && !macStreamed) console.log("mac: streamed, but not from the sofa; the keyboard stays on the Apple TV");
      decide();
    },
    stats: (host) => (macHost = { host, at: Date.now() }),
    presence: () => (sendHello(), syncInstantCursor()),
    line: (line) => onMacLine(line),
  },
);
const padOptions = () => ({ tracking: settings.trackpadSpeed, tapToClick: settings.tapToClick, naturalScroll: settings.naturalScroll });
// Each move to the Mac is numbered and, with the instant cursor on, also sent to the app, which draws the
// cursor at once and corrects it from the receiver's `cursor <seq> <x> <y> <w> <h>` (onMacLine).
let cursorSeq = 0;
const macPad = new MacTrackpad((m) => {
  if (m.t !== "move") return mac.send(m);
  const seq = ++cursorSeq;
  mac.send({ ...m, seq });
  if (settings.instantCursor && app.screen === "stream") app.send({ t: "cursor", dx: m.dx, dy: m.dy, seq });
}, padOptions());

/** Tells the receiver whether the Apple TV draws the cursor itself (from the next stream). */
function syncInstantCursor(): void {
  const client = app.address ?? (process.env.SOFA_APP_PEERS ?? "192.168.68.67").split(",")[0]!;
  if (mac.connected) mac.send({ t: "instantCursor", on: settings.instantCursor, client });
}

// ----------------------------------------------------------------- the Sofa app on the Apple TV
// The app's list of computers shows the sofa devices' batteries and each computer's stats. On that
// screen, with input on the Apple TV, the trackpad is the app's pointer, shaped as for the Mac; the
// Mac-only gestures (Spaces, zoom, the menu bar) are left out.

let macHost: { host: Host; at: number } | null = null;
const MAC_STATS_STALE_MS = 20_000;
let lastDevices = "";

function sendDevices(always = false): void {
  if (!app.connected) return;
  const trackpad = devices.get(TRACKPAD);
  const message = {
    t: "devices",
    bridge: true,
    devices: sofaDevices(hidBatteries(), { keyboard: findEventNode("Magic Keyboard") !== null, trackpad: !!trackpad && !trackpad.closed }),
  };
  const json = JSON.stringify(message);
  if (!always && json === lastDevices) return;
  lastDevices = json;
  app.send(message);
}

async function sendStats(): Promise<void> {
  if (!app.connected) return;
  try {
    const mode = parseMode(settings.tvMode);
    const hosts = [{ ...(await localHost(HOST_NAME)), ...(mode ? { display: tvDisplayFacts(mode, settings.tvScale, await sizeWhyNot()) } : {}) }];
    if (macHost && Date.now() - macHost.at < MAC_STATS_STALE_MS) {
      const { display, ...host } = macHost.host;
      hosts.push(Array.isArray(display?.pixels) ? { ...host, display: macDisplayFacts(display!, macSizeWhyNot()) } : host);
    }
    app.send({ t: "stats", hosts: hosts.map((h) => ({ ...h, apps: shapeApps(h.apps, settings.apps) })) });
  } catch (error) {
    console.error(`stats: ${(error as Error).message}`);
  }
}

const app = new AppLink(Number(process.env.SOFA_APP_PORT ?? 47902), (process.env.SOFA_APP_PEERS ?? "192.168.68.67").split(","), {
  connect: () => ((lastPreviewAt = 0), sendHello(), sendDevices(true)),
  screen: (screen) => {
    if (screen !== "home") appPad.reset(), palm.reset();
    homeTimers(true);
  },
  settings: (m) => applySettings(m),
  restart: (host) => restart(host),
  request: (m) => onRequest(m),
  gone: () => (void sizes.cancel("the app went"), mac.send({ t: "sizeCancel" })),
});
const appPad = new MacTrackpad((m) => (m.t === "move" || m.t === "button" || m.t === "scroll") && app.send(m), padOptions());
setInterval(sendDevices, 10_000);

const HOST_NAME = process.env.SOFA_HOST_NAME ?? "omarchypc";
const macName = () => macHost?.host.name ?? "MBP13";
const VERSION = (() => {
  try {
    return readFileSync(`${import.meta.dir}/VERSION`, "utf8").trim() || "dev"; // install-omarchy.sh writes it
  } catch {
    return "dev";
  }
})();
const sendHello = () => app.send({ t: "hello", version: VERSION, receiver: mac.connected, hubUptime: Math.round(process.uptime()) });

const logged = new Set<string>();
const logOnce = (text: string) => void (logged.has(text) || (logged.add(text), console.error(text)));

// Stats and previews go only to the app's home screen, the list of computers: once on arriving there
// (a preview only if the last is older than its interval), then every statsEvery / previewsEvery s.
let statsTimer: Timer | undefined;
let previewTimer: Timer | undefined;
let lastPreviewAt = 0;

function homeTimers(arriving = false): void {
  clearInterval(statsTimer);
  clearInterval(previewTimer);
  statsTimer = previewTimer = undefined;
  if (!app.connected || app.screen !== "home") return;
  const { statsEvery, previewsEvery } = settings;
  if (statsEvery > 0) statsTimer = setInterval(sendStats, statsEvery * 1000);
  if (previewsEvery > 0) previewTimer = setInterval(sendPreviews, previewsEvery * 1000);
  if (arriving && statsEvery > 0) void sendStats();
  if (arriving && previewsEvery > 0 && Date.now() - lastPreviewAt > previewsEvery * 1000) void sendPreviews();
}

async function sendPreviews(): Promise<void> {
  lastPreviewAt = Date.now();
  if (mac.connected) mac.send({ t: "preview" }); // the receiver answers `preview <base64>`, onMacLine
  try {
    app.send({ t: "preview", host: HOST_NAME, jpeg: await localPreview(), at: Math.round(Date.now() / 1000) });
  } catch (error) {
    logOnce(`preview: ${(error as Error).message}`);
  }
}

function applySettings(m: Record<string, unknown>): void {
  const prev = settings;
  settings = parseSettings(m, prev);
  if (JSON.stringify(prev) === JSON.stringify(settings)) return;
  console.log(`settings: ${JSON.stringify(settings)}`);
  saveSettings(settings);
  macPad.configure(padOptions());
  appPad.configure(padOptions());
  if (prev.volumeKeysToTV !== settings.volumeKeysToTV) {
    if (!keyCopy()) liftKeys(); // the desktop reads keyd's keyboard itself again
    regrab();
  }
  if (prev.statsEvery !== settings.statsEvery || prev.previewsEvery !== settings.previewsEvery) homeTimers();
  if (prev.instantCursor !== settings.instantCursor) syncInstantCursor();
}

// Restarting from the app: omarchypc reboots itself (logind lets the session's user; its disk unlocks
// and it logs in on its own), the Mac through its receiver (fdesetup authrestart, setup-mac-restart.sh).
let pendingRestart: { host: string; timer: Timer } | null = null;

function restart(host: string): void {
  const reply = (ok: boolean, error?: string) => app.send({ t: "restart", host, ok, ...(error ? { error } : {}) });
  if (host.toLowerCase() === HOST_NAME.toLowerCase()) {
    const login1 = ["org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager"];
    const can = Bun.spawnSync(["busctl", "call", ...login1, "CanReboot"]).stdout.toString().trim();
    if (can !== 's "yes"') return reply(false, `reboot needs a password here (CanReboot: ${can || "no answer"})`);
    console.log(`restart: rebooting ${HOST_NAME}, asked by the Sofa app`);
    reply(true);
    setTimeout(() => Bun.spawn(["systemctl", "reboot"], { stdout: "ignore", stderr: "inherit" }), 500);
    return;
  }
  if (host.toLowerCase() !== macName().toLowerCase()) return reply(false, `no computer called ${host}`);
  if (!mac.connected) return reply(false, "the Mac's receiver is not connected");
  clearTimeout(pendingRestart?.timer);
  pendingRestart = { host, timer: setTimeout(() => ((pendingRestart = null), reply(false, "no answer from the Mac")), 15_000) };
  console.log(`restart: asking ${host} to restart`);
  mac.send({ t: "restart" });
}

// ----------------------------------------------------------------- sizes and the test tone
// The app tries omarchypc's size on the TV (only while nobody but the sofa streams it), keeps or cancels
// it (display.ts), and plays a test tone on either computer.

let macTryPixels: [number, number] | null = null; // as the app asked, so it knows the answer for its own

function macSizeWhyNot(): string {
  if (!mac.connected) return "the Mac's receiver is not connected";
  if (macStreamed || macLive) return "streamed right now";
  return "";
}

async function sizeWhyNot(): Promise<string> {
  if (sunshineLive && !desktopStreamed) return "streamed from another device";
  if (!(await virtualOutput())) return "no virtual output (a monitor is plugged in)";
  return "";
}

let offerOn = false;
let offerTimer: Timer | undefined;

let pendingTone: { host: string; timer: Timer; path: Promise<number | null> } | null = null;

// The input path's one-way time for the app's responsiveness estimate: omarchypc's input is injected here
// (uinput), the Mac's crosses Tailscale to the receiver: half the median of 5 round trips there.
const pongs = new Map<number, () => void>();
let pingId = 0;
async function macPathMs(): Promise<number | null> {
  const trips: number[] = [];
  for (let i = 0; i < 5; i++) {
    const id = ++pingId;
    const start = performance.now();
    const answered = await new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => (pongs.delete(id), resolve(false)), 1000);
      pongs.set(id, () => (clearTimeout(timer), resolve(true)));
      mac.send({ t: "ping", id });
    });
    if (answered) trips.push(performance.now() - start);
  }
  return pathMs(trips);
}

function onRequest(m: Record<string, unknown>): void {
  const host = String(m.host);
  const here = host.toLowerCase() === HOST_NAME.toLowerCase();
  const pair = (v: unknown) => (Array.isArray(v) && v.length === 2 && v.every((n) => Number.isInteger(n) && n > 0) ? (v as [number, number]) : null);
  const pixels = pair(m.pixels);
  const looks = pair(m.looks);
  if (m.t === "offer") {
    // The app's mid-stream offer of a lower bitrate is showing: ⌥⌘B takes it (onKeyboard).
    clearTimeout(offerTimer);
    offerOn = m.on === true;
    if (offerOn) offerTimer = setTimeout(() => (offerOn = false), 15_000);
    return;
  }
  if (m.t === "speed") {
    // The app listens on `port`; the computer sends it bytes for `seconds`, so the measure is its own path.
    const port = Number(m.port), seconds = Math.min(Math.max(Number(m.seconds) || 4, 1), 10);
    const addr = app.address;
    const reply = (ok: boolean, more: object) => (console.log(`speed: ${host}: ${JSON.stringify(more)}`), app.send({ t: "speed", host, ok, ...more }));
    console.log(`speed: ${host} to ${addr}:${port} for ${seconds} s`);
    if (!addr || !Number.isInteger(port) || port < 1 || port > 65535) return reply(false, { error: "bad request" });
    if (here) return void sendSpeed(addr, port, seconds).then((bytes) => reply(true, { bytes }), (e) => reply(false, { error: (e as Error).message }));
    if (host.toLowerCase() !== macName().toLowerCase()) return reply(false, { error: `no computer called ${host}` });
    if (!mac.connected) return reply(false, { error: "the Mac's receiver is not connected" });
    return mac.send({ t: "speed", addr, port, seconds });
  }
  if (m.t === "tone") {
    const seconds = Math.min(Math.max(Number(m.seconds) || 6, 1), 30);
    const reply = (ok: boolean, error?: string, path: number | null = null) =>
      app.send({ t: "tone", host, ok, ...(path !== null ? { pathMs: path } : {}), ...(error ? { error } : {}) });
    if (here) return void playTone(seconds).then((r) => (console.log(`tone: ${seconds} s ${r.ok ? "playing" : r.error}`), reply(r.ok, r.error, 1)));
    if (host.toLowerCase() !== macName().toLowerCase()) return reply(false, `no computer called ${host}`);
    if (!mac.connected) return reply(false, "the Mac's receiver is not connected");
    clearTimeout(pendingTone?.timer);
    pendingTone = { host, timer: setTimeout(() => ((pendingTone = null), reply(false, "no answer from the Mac")), 5000), path: macPathMs() };
    return mac.send({ t: "tone", seconds });
  }
  if (!here) {
    // The Mac: its receiver resizes its stream display (see mac-receiver.swift, sizes); it answers `size`.
    if (host.toLowerCase() !== macName().toLowerCase()) return;
    if (m.t === "cancelSize") return mac.send({ t: "sizeCancel" });
    const why = macSizeWhyNot();
    if (!looks) return void (m.t === "trySize" && app.send({ t: "sizePreview", host, pixels: m.pixels, looks: m.looks, error: "no such size" }));
    if (m.t === "keepSize") return mac.send({ t: "sizeKeep", w: looks[0], h: looks[1] });
    if (why) return app.send({ t: "sizePreview", host, pixels: m.pixels, looks, error: why });
    macTryPixels = pixels;
    return mac.send({ t: "sizeTry", w: looks[0], h: looks[1] });
  }
  if (m.t === "cancelSize") return void sizes.cancel("the app cancelled");
  // A size is the stream's pixels and the size the desktop looks, no bigger than them, at a scale up to 4.
  const target = pixels && looks && parseMode(`${pixels[0]}x${pixels[1]}@60`) && looks[0] <= pixels[0] && pixels[0] / looks[0] <= 4 ? sizeTarget(pixels, looks) : null;
  if (!target) return void (m.t === "trySize" && app.send({ t: "sizePreview", host, pixels: m.pixels, looks: m.looks, error: "no such size" }));
  if (m.t === "trySize") return sizes.try(pixels!, looks!, sizeWhyNot);
  // keepSize: the sofa's stream from now on, saved as the app's tvMode and tvScale, and the output's now.
  applySettings({ tvMode: `${target.width}x${target.height}@${target.fps}`, tvScale: target.scale });
  void (async () => {
    if (await sizeWhyNot()) return void sizes.cancel("kept while another device streams");
    await sizes.keep(target);
  })().catch((error) => console.error(`size: ${(error as Error).message}`));
}

/** The receiver's answers: `preview <base64>`, `preview-failed <why>`, `restarting`, `restart-failed <why>`,
 * `tone-ok`, `tone-failed <why>`, `pong <id>`. */
function onMacLine(line: string): void {
  const space = line.indexOf(" ");
  const [word, rest] = space < 0 ? [line, ""] : [line.slice(0, space), line.slice(space + 1)];
  if (word === "preview") {
    if (rest.length > PREVIEW_MAX) return logOnce(`mac preview too big: ${rest.length} bytes`);
    app.send({ t: "preview", host: macName(), jpeg: rest, at: Math.round(Date.now() / 1000) });
  } else if (word === "preview-failed") {
    logOnce(`mac preview: ${rest}${rest === "no-permission" ? " (give ~/.local/bin/sofa-receiver Screen Recording)" : ""}`);
  } else if (word === "restarting" || word === "restart-failed") {
    const host = pendingRestart?.host ?? macName();
    clearTimeout(pendingRestart?.timer);
    pendingRestart = null;
    console.log(`restart: ${host}: ${line}`);
    app.send({ t: "restart", host, ok: word === "restarting", ...(word === "restart-failed" ? { error: rest || "failed" } : {}) });
  } else if (word === "size") {
    // "size <w> <h> ok <base64>" or "size <w> <h> failed <why>": the answer to a try.
    const [w, h, result, ...more] = rest.split(" ");
    const looks = [Number(w), Number(h)];
    const answer = { t: "sizePreview", host: macName(), pixels: macTryPixels ?? [looks[0]! * 2, looks[1]! * 2], looks };
    if (result === "ok" && more[0] && more[0].length <= PREVIEW_MAX * 4) app.send({ ...answer, scale: 2, jpeg: more[0] });
    else app.send({ ...answer, error: result === "ok" ? "picture too big" : more.join(" ") || "failed" });
  } else if (word === "cursor") {
    const [seq, x, y, w, h] = rest.split(" ").map(Number);
    if (settings.instantCursor && app.screen === "stream" && [seq, x, y, w, h].every(Number.isFinite)) app.send({ t: "cursorAt", seq, x, y, w, h });
  } else if (word === "speed-done" || word === "speed-failed") {
    console.log(`speed: ${macName()}: ${line}`);
    app.send({ t: "speed", host: macName(), ok: word === "speed-done", ...(word === "speed-done" ? { bytes: Number(rest) || 0 } : { error: rest || "failed" }) });
  } else if (word === "pong") {
    pongs.get(Number(rest))?.();
    pongs.delete(Number(rest));
  } else if (word === "tone-ok" || word === "tone-failed") {
    const host = pendingTone?.host ?? macName();
    const path = pendingTone?.path ?? Promise.resolve(null);
    clearTimeout(pendingTone?.timer);
    pendingTone = null;
    void path.then((ms) =>
      app.send({ t: "tone", host, ok: word === "tone-ok", ...(ms !== null ? { pathMs: ms } : {}), ...(word === "tone-failed" ? { error: rest || "failed" } : {}) }),
    );
  }
}

// ----------------------------------------------------------------- keyboard
// In a stream of omarchypc the hub holds the keyboard too and passes every key on to the desktop through
// a copy of it, except the volume keys, which go to the Apple TV: the desktop would otherwise turn down its
// own (Sunshine's) sound as well. The copy has keyd's vendor id, 0fac, which keyd leaves alone; any other
// id and keyd would take it into the keyboard the hub reads, in a loop. Without the copy the desktop reads
// keyd's keyboard itself, and the volume keys change both.

const virtualKeys = (() => {
  const keys = Array.from({ length: 0x2ff }, (_, i) => i + 1).filter((k) => k < 0x100 || k >= 0x160); // no mouse buttons
  try {
    return new VirtualDevice({ name: "sofa keyboard", id: { bus: 6, vendor: 0x0fac, product: 0x50fa, version: 1 }, props: [], keys, abs: new Map() });
  } catch (error) {
    console.error(`no keyboard copy, the desktop reads keyd's itself: ${(error as Error).message}`);
    return null;
  }
})();
const keysDown = new Set<number>(); // what the desktop has seen pressed through the copy
// Only while the volume keys go to the Apple TV; otherwise the desktop reads keyd's keyboard itself.
const keyCopy = () => virtualKeys !== null && settings.volumeKeysToTV;

function passKey(code: number, value: number): void {
  if (!virtualKeys || (value !== 1 && !keysDown.has(code))) return; // never an up or repeat for a key it did not see go down
  if (value === 1) keysDown.add(code);
  if (value === 0) keysDown.delete(code);
  virtualKeys.write([{ type: EV_KEY, code, value }]);
}

/** Lifts every key the desktop still thinks is held. */
function liftKeys(): void {
  for (const code of keysDown) virtualKeys?.write([{ type: EV_KEY, code, value: 0 }]);
  keysDown.clear();
}

const WAKE_AFTER_MS = 2 * 60_000;
let lastTvKeyAt = 0;
const ESC_HOLD_MS = 5000;
const ESC_TAPS = 3; // or three quick taps
const ESC_TAPS_MS = 900;
let escDown = false;
let escTimer: Timer | undefined;
let escTaps: number[] = [];
let homeFallback: Timer | undefined;
let leaving = false; // between a leave and the stream's end
const press = (hid: number) => void tv.button(hid, true).then(() => tv.button(hid, false));

// Back to the Apple TV: Menu, which the Sofa app takes as "leave the stream" and so lands on its list of
// computers. Should the stream still be up a moment later (the app took Menu for the stream's own Esc),
// Home leaves the app instead.
function leaveStream(why: string): void {
  console.log(`${why}: back to the Apple TV`);
  if (mode === "mac") mac.send({ t: "key", code: KEY.ESC, down: false });
  desktopStreamed = false;
  macStreamed = false;
  decide();
  clearTimeout(homeFallback);
  leaving = true;
  // The wait starts once Menu has reached the Apple TV, which may first need to reconnect.
  void tv.button(HID.Menu, true).then(() => tv.button(HID.Menu, false)).then(() => {
    console.log("apple tv: Menu sent");
    if (!leaving) return; // the stream ended already
    homeFallback = setTimeout(() => (console.log("stream still up after Menu: Home"), press(HID.Home)), 2500);
  });
}
const streamEnded = () => {
  leaving = false;
  clearTimeout(homeFallback);
};

function onKeyboard(events: InputEvent[]): void {
  for (const { type, code, value } of events) {
    if (type !== EV_KEY) continue;
    if (process.env.SOFA_DEBUG) console.log(`key ${code} ${value} ${performance.now().toFixed(0)}`);
    const down = value !== 0;
    if (code === KEY.LEFTMETA || code === KEY.RIGHTMETA) mods.meta = down;
    else if (code === KEY.LEFTCTRL || code === KEY.RIGHTCTRL) mods.ctrl = down;
    else if (code === KEY.LEFTALT || code === KEY.RIGHTALT) mods.alt = down;
    else if (code === KEY.LEFTSHIFT || code === KEY.RIGHTSHIFT) mods.shift = down;
    else if (value === 1) lastKeyAt = Date.now();
    if (value === 1) lastSofaInputAt = Date.now();

    // Esc tapped three times quickly, or held ESC_HOLD_MS, in a stream: back to the Apple TV. The keyboard
    // is grabbed only once Esc is up, so the desktop never keeps it held.
    if (code === KEY.ESC && value === 1 && mode !== "tv") {
      escDown = true;
      void tv.ready().catch(() => {}); // the Apple TV link idles out after ~30 s: have it back before the third tap
      escTimer = setTimeout(() => leaveStream("esc held"), ESC_HOLD_MS);
      const now = Date.now();
      escTaps = [...escTaps.filter((t) => now - t < ESC_TAPS_MS), now];
      if (escTaps.length >= ESC_TAPS) (escTaps = []), clearTimeout(escTimer), leaveStream("esc tapped three times");
    } else if (code === KEY.ESC && value === 0) {
      clearTimeout(escTimer);
      if (escDown) (escDown = false), regrab();
    }

    // ⌥⌘B while the app offers a lower bitrate mid-stream: taken, and kept from the computer.
    if (offerOn && code === KEY_B && mods.alt && mods.meta && value !== 0) {
      if (value === 1) (offerOn = false), clearTimeout(offerTimer), app.send({ t: "offerTaken" }), console.log("offer: taken");
      continue;
    }
    if (value === 1 && isModeToggle(code, mods)) {
      choose(mode === "tv" ? "desktop" : "tv");
      continue;
    }
    // In a stream the volume keys still go to the Apple TV, below (unless the app says not to);
    // everything else to the computer.
    const volume = mode === "tv" || !settings.volumeKeysToTV ? null : tvVolumeKey(code, mods);
    if (mode === "mac" && volume === null) {
      if (value !== 2) mac.send({ t: "key", code, down }); // the Mac repeats held keys itself, at its own speed
      continue;
    }
    if (mode === "desktop" && volume === null) {
      if (keyCopy()) passKey(code, value);
      continue;
    }

    if (value === 0) {
      const hid = held.get(code);
      if (hid !== undefined) void tv.button(hid, false);
      held.delete(code);
    } else if (value === 1) {
      // After a quiet spell the Apple TV is likely asleep: any key wakes it (and the TV, over HDMI-CEC) first.
      if (mode === "tv" && Date.now() - lastTvKeyAt > WAKE_AFTER_MS) void tv.button(HID.Wake, true).then(() => tv.button(HID.Wake, false));
      if (mode === "tv") lastTvKeyAt = Date.now();
      const hid = keyToHid(code, mods);
      if (hid === null) continue;
      held.set(code, hid);
      void tv.button(hid, true);
    } else if (value === 2) {
      const hid = held.get(code);
      if (hid !== undefined && repeats(hid)) void tv.button(hid, false).then(() => tv.button(hid, true));
    }
  }
}

// ----------------------------------------------------------------- devices come and go

function attach(name: string, onFrame: (events: InputEvent[]) => void, setup?: (d: InputDevice) => void, onGone?: () => void): void {
  const path = findEventNode(name);
  const current = devices.get(name);
  if (current && !current.closed && current.path === path) return;
  current?.close();
  devices.delete(name);
  if (!path) return;
  try {
    const device = new InputDevice(path, onFrame, () => (console.log(`gone: ${name}`), onGone?.()));
    setup?.(device);
    device.grab(wantsGrab(name));
    devices.set(name, device);
    console.log(`attached: ${name} (${path})`);
  } catch (error) {
    console.error(`cannot open ${name} at ${path}: ${(error as Error).message}`);
  }
}

function scan(): void {
  attach(KEYBOARD, onKeyboard);
  attach(TRACKPAD, onTrackpad, makeVirtualPad, () => (virtualPad?.write(palm.reset()), appPad.reset()));
}

// ----------------------------------------------------------------- control socket

if (existsSync(SOCKET)) unlinkSync(SOCKET);
Bun.listen({
  unix: SOCKET,
  socket: {
    data(socket, data) {
      const wanted = data.toString().trim();
      if (wanted === "screenshot") app.send({ t: "screenshot" }); // answered on the app link, saved by applink.ts
      else if (wanted === "toggle") choose(mode === "tv" ? "desktop" : "tv");
      else if (wanted === "tv" || wanted === "desktop" || wanted === "mac") choose(wanted);
      socket.write(`mode: ${mode}\n`);
      socket.end();
    },
  },
});

// ----------------------------------------------------------------- follow Sunshine
// A client streaming this desktop gets the devices; when it leaves (quit or just backed out),
// they go back to the Apple TV. Sunshine says both in its log.

const SUNSHINE_LOG = process.env.SOFA_SUNSHINE_LOG ?? `${process.env.HOME}/.config/sunshine/sunshine.log`;
const streamMode = (line: string): Mode | null =>
  line.includes("CLIENT CONNECTED") ? "desktop" : line.includes("CLIENT DISCONNECTED") ? "tv" : null;

// The Apple TV's picture: the app's tvMode and tvScale, 1080p at 1.6 by default (a 1200x675 desktop). Sunshine sizes the display only when a
// stream launches the desktop; joining one already running (mbpmax's) keeps that client's size and
// scale, and a fresh launch keeps the last scale, so the sofa sets both. Shared streams see it too.
// The Mac launcher's sunshine-client-pointer flag (the Mac draws its own pointer, so this one is made
// clear) is taken away too: the Apple TV draws none, and the cursor would be invisible on it.
function tvDisplay(): void {
  const mode = parseMode(settings.tvMode);
  if (!mode) return;
  const run = process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`;
  rmSync(`${run}/sunshine-client-pointer`, { force: true });
  Bun.write(`${run}/sunshine-client-scale`, String(settings.tvScale)).then(() =>
    Bun.spawn([`${process.env.HOME}/.local/bin/sunshine-virtual-display`, "resize"], {
      env: { ...process.env, SUNSHINE_CLIENT_WIDTH: String(mode.width), SUNSHINE_CLIENT_HEIGHT: String(mode.height), SUNSHINE_CLIENT_FPS: String(mode.fps) },
      stdout: "ignore",
      stderr: "inherit",
    }),
  );
}

// The size trials, and whether any client streams this desktop (sofa or not), from the log's last word.
const sizes = new SizeTrial(HOST_NAME, (m) => app.send(m));
let sunshineLive = (() => {
  try {
    return sunshineStreaming(readFileSync(SUNSHINE_LOG, "utf8").slice(-200_000)) ?? false;
  } catch {
    return false;
  }
})();

function followSunshine(): void {
  const tail = Bun.spawn(["tail", "-F", "-n", "0", SUNSHINE_LOG], { stdout: "pipe", stderr: "ignore" });
  void (async () => {
    let buffered = "";
    for await (const chunk of tail.stdout) {
      buffered += new TextDecoder().decode(chunk);
      const lines = buffered.split("\n");
      buffered = lines.pop() ?? "";
      for (const line of lines) {
        const next = streamMode(line);
        if (!next) continue;
        if (next !== "desktop") streamEnded();
        sunshineLive = next === "desktop";
        desktopStreamed = next === "desktop" && fromSofa();
        if (next === "desktop") void sizes.streamStarted(desktopStreamed).catch((e) => console.error(`size: ${(e as Error).message}`));
        if (next === "desktop" && !desktopStreamed) console.log("desktop: streamed, but not from the sofa; the keyboard stays on the Apple TV");
        if (desktopStreamed) tvDisplay();
        decide();
      }
    }
  })();
}

scan();
setInterval(scan, 2000); // the trackpad gets a new event node every time it wakes from sleep
// Restarted mid-stream it picks up the streams it was following; started afresh (after a boot), the
// Apple TV.
try {
  ({ desktopStreamed, macStreamed } = JSON.parse(readFileSync(STATE, "utf8")));
  if (desktopStreamed || macStreamed) lastSofaInputAt = Date.now(); // so the Mac's "streaming" on reconnect counts
} catch {}
if (process.env.SOFA_START_MODE) setMode(process.env.SOFA_START_MODE as Mode);
else decide();
followSunshine();
console.log(`sofa-hub: listening on ${SOCKET}, mode ${mode}`);

// ----------------------------------------------------------------- connection check
// The Sofa app's "Check connection" times a download from here: the Apple TV's Wi-Fi is what limits a
// stream from either computer, and omarchypc is wired. GET /speed?bytes=N sends N zero bytes (at most 100 MB).
const SPEED_CHUNK = new Uint8Array(1 << 20);
const appPeers = (process.env.SOFA_APP_PEERS ?? "192.168.68.67").split(",");
Bun.serve({
  port: Number(process.env.SOFA_SPEED_PORT ?? 47903),
  fetch(request, server) {
    const url = new URL(request.url);
    // A dual-stack listener reports IPv4 peers as ::ffff:a.b.c.d.
    const peer = (server.requestIP(request)?.address ?? "").replace(/^::ffff:/, "");
    if (!appPeers.includes(peer) || url.pathname !== "/speed") return new Response("no", { status: 404 });
    let left = Math.min(Math.max(Number(url.searchParams.get("bytes")) || 0, 0), 100_000_000);
    const length = left;
    const body = new ReadableStream({
      pull(controller) {
        if (left <= 0) return controller.close();
        const n = Math.min(left, SPEED_CHUNK.length);
        controller.enqueue(SPEED_CHUNK.subarray(0, n));
        left -= n;
      },
    });
    return new Response(body, { headers: { "content-length": String(length), "cache-control": "no-store" } });
  },
});
