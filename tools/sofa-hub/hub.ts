// sofa-hub: the sofa keyboard drives the Apple TV, omarchypc's desktop while it is streamed, or the
// Mac while it is streamed (through mac-receiver.swift on the Mac, see mac.ts).
// In a stream the desktop gets a copy of the trackpad with palms filtered out, touch by touch (palm.ts).
// The trackpad only works in a stream; on the Apple TV it is held so stray touches do nothing.
//
//   bun hub.ts                  run the hub (the systemd user service does this)
//   bun hub.ts mode tv|desktop|mac|toggle    tell the running hub where input goes
//   bun hub.ts pair             pair with the Apple TV once (type the PIN it shows)
import { existsSync, readFileSync, rmSync, unlinkSync } from "node:fs";
import { AppleTv } from "./appletv.ts";
import { EV_KEY, InputDevice, deviceId, findEventNode, type InputEvent } from "./evdev.ts";
import { HID, KEY, type Modifiers, isModeToggle, keyToHid, repeats } from "./keys.ts";
import { MacLink, MacTrackpad } from "./mac.ts";
import { BTN, PalmFilter } from "./palm.ts";
import { type AbsInfo, VirtualDevice } from "./uinput.ts";

type Mode = "tv" | "desktop" | "mac";
const SOCKET = `${process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`}/sofa-hub.sock`;
const KEYBOARD = "keyd virtual keyboard"; // keyd already merges every keyboard into this one
const TRACKPAD = "Apple Inc. Magic Trackpad";

if (process.argv[2] === "mode") {
  const wanted = process.argv[3];
  if (!["tv", "desktop", "mac", "toggle"].includes(wanted ?? "")) throw new Error("usage: bun hub.ts mode tv|desktop|mac|toggle");
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
const devices = new Map<string, InputDevice>();
const mods: Modifiers = { meta: false, ctrl: false, alt: false, shift: false };
const held = new Map<number, number>(); // key code -> Apple TV button it pressed

function setMode(next: Mode): void {
  if (next !== mode) {
    console.log(`mode: ${next}`);
    // Lift whatever the place input is leaving still thinks is held.
    if (mode === "desktop") virtualPad?.write(palm.reset());
    if (mode === "mac") macPad.reset(), mac.send({ t: "reset" }), palm.reset();
    if (mode === "tv") releaseAll();
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
  name === KEYBOARD && escDown ? mode !== "desktop" && mode !== "tv" : mode !== "desktop" || (name === TRACKPAD && virtualPad !== null);
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
}

// ----------------------------------------------------------------- the Mac

const tailscaleIp = Bun.spawnSync(["tailscale", "ip", "-4"]).stdout.toString().trim();
const mac = new MacLink(
  process.env.SOFA_MAC_LISTEN ?? (tailscaleIp || "127.0.0.1"),
  Number(process.env.SOFA_MAC_PORT ?? 47901),
  (process.env.SOFA_MAC_PEERS ?? "100.114.79.7").split(","), // mbp13 over Tailscale
  (on) => {
    if (!on) streamEnded();
    macStreamed = on && (macStreamed || fromSofa()); // a stream the sofa was on stays the sofa's
    if (on && !macStreamed) console.log("mac: streamed, but not from the sofa; the keyboard stays on the Apple TV");
    decide();
  },
);
const macPad = new MacTrackpad((m) => mac.send(m), Number(process.env.SOFA_MAC_TRACKING ?? 0.6875));

// ----------------------------------------------------------------- keyboard

const WAKE_AFTER_MS = 2 * 60_000;
let lastTvKeyAt = 0;
const ESC_HOLD_MS = 5000;
const ESC_TAPS = 3; // or three quick taps
const ESC_TAPS_MS = 900;
let escDown = false;
let escTimer: Timer | undefined;
let escTaps: number[] = [];
let homeFallback: Timer | undefined;
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
  press(HID.Menu);
  clearTimeout(homeFallback);
  homeFallback = setTimeout(() => (console.log("stream still up after Menu: Home"), press(HID.Home)), 2500);
}
const streamEnded = () => clearTimeout(homeFallback);

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
      escTimer = setTimeout(() => leaveStream("esc held"), ESC_HOLD_MS);
      const now = Date.now();
      escTaps = [...escTaps.filter((t) => now - t < ESC_TAPS_MS), now];
      if (escTaps.length >= ESC_TAPS) (escTaps = []), clearTimeout(escTimer), leaveStream("esc tapped three times");
    } else if (code === KEY.ESC && value === 0) {
      clearTimeout(escTimer);
      if (escDown) (escDown = false), regrab();
    }

    if (value === 1 && isModeToggle(code, mods)) {
      choose(mode === "tv" ? "desktop" : "tv");
      continue;
    }
    if (mode === "mac") {
      if (value !== 2) mac.send({ t: "key", code, down }); // the Mac repeats held keys itself, at its own speed
      continue;
    }
    if (mode !== "tv") continue;

    if (value === 0) {
      const hid = held.get(code);
      if (hid !== undefined) void tv.button(hid, false);
      held.delete(code);
    } else if (value === 1) {
      // After a quiet spell the Apple TV is likely asleep: any key wakes it (and the TV, over HDMI-CEC) first.
      if (Date.now() - lastTvKeyAt > WAKE_AFTER_MS) void tv.button(HID.Wake, true).then(() => tv.button(HID.Wake, false));
      lastTvKeyAt = Date.now();
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
  attach(TRACKPAD, onTrackpad, makeVirtualPad, () => virtualPad?.write(palm.reset()));
}

// ----------------------------------------------------------------- control socket

if (existsSync(SOCKET)) unlinkSync(SOCKET);
Bun.listen({
  unix: SOCKET,
  socket: {
    data(socket, data) {
      const wanted = data.toString().trim();
      if (wanted === "toggle") choose(mode === "tv" ? "desktop" : "tv");
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

// The Apple TV's picture: 1080p at 1.6 (a 1200x675 desktop). Sunshine sizes the display only when a
// stream launches the desktop; joining one already running (mbpmax's) keeps that client's size and
// scale, and a fresh launch keeps the last scale, so the sofa sets both. Shared streams see it too.
// The Mac launcher's sunshine-client-pointer flag (the Mac draws its own pointer, so this one is made
// clear) is taken away too: the Apple TV draws none, and the cursor would be invisible on it.
const TV_MODE = (process.env.SOFA_TV_MODE ?? "1920x1080@60").match(/^(\d+)x(\d+)@(\d+)$/);
const TV_SCALE = process.env.SOFA_TV_SCALE ?? "1.6";

function tvDisplay(): void {
  if (!TV_MODE) return;
  const run = process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`;
  rmSync(`${run}/sunshine-client-pointer`, { force: true });
  Bun.write(`${run}/sunshine-client-scale`, TV_SCALE).then(() =>
    Bun.spawn([`${process.env.HOME}/.local/bin/sunshine-virtual-display`, "resize"], {
      env: { ...process.env, SUNSHINE_CLIENT_WIDTH: TV_MODE[1], SUNSHINE_CLIENT_HEIGHT: TV_MODE[2], SUNSHINE_CLIENT_FPS: TV_MODE[3] },
      stdout: "ignore",
      stderr: "inherit",
    }),
  );
}

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
        desktopStreamed = next === "desktop" && fromSofa();
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
