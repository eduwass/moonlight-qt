// sofa-hub: the sofa keyboard drives the Apple TV, or omarchypc's desktop while it is streamed.
// In a stream the desktop gets a copy of the trackpad with palms filtered out, touch by touch (palm.ts).
// The trackpad only works in a stream; on the Apple TV it is held so stray touches do nothing.
//
//   bun hub.ts                  run the hub (the systemd user service does this)
//   bun hub.ts mode tv|desktop|toggle    tell the running hub where input goes
//   bun hub.ts pair             pair with the Apple TV once (type the PIN it shows)
import { existsSync, unlinkSync } from "node:fs";
import { AppleTv } from "./appletv.ts";
import { EV_KEY, InputDevice, deviceId, findEventNode, type InputEvent } from "./evdev.ts";
import { KEY, type Modifiers, isModeToggle, keyToHid, repeats } from "./keys.ts";
import { BTN, PalmFilter } from "./palm.ts";
import { type AbsInfo, VirtualDevice } from "./uinput.ts";

type Mode = "tv" | "desktop";
const SOCKET = `${process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`}/sofa-hub.sock`;
const KEYBOARD = "keyd virtual keyboard"; // keyd already merges every keyboard into this one
const TRACKPAD = "Apple Inc. Magic Trackpad";

if (process.argv[2] === "mode") {
  const wanted = process.argv[3];
  if (!["tv", "desktop", "toggle"].includes(wanted ?? "")) throw new Error("usage: bun hub.ts mode tv|desktop|toggle");
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
  if (next !== mode) console.log(`mode: ${next}`);
  mode = next;
  for (const [name, device] of devices) device.grab(wantsGrab(name));
  if (mode === "tv") virtualPad?.write(palm.reset());
  if (mode === "desktop") releaseAll();
  else void tv.ready().catch(() => {});
}

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

const wantsGrab = (name: string) => mode === "tv" || (name === TRACKPAD && virtualPad !== null);

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
  if (mode === "desktop") virtualPad?.write(palm.frame(events, Date.now() - lastKeyAt < TYPING_MS));
}

// ----------------------------------------------------------------- keyboard

function onKeyboard(events: InputEvent[]): void {
  for (const { type, code, value } of events) {
    if (type !== EV_KEY) continue;
    const down = value !== 0;
    if (code === KEY.LEFTMETA || code === KEY.RIGHTMETA) mods.meta = down;
    else if (code === KEY.LEFTCTRL || code === KEY.RIGHTCTRL) mods.ctrl = down;
    else if (code === KEY.LEFTALT || code === KEY.RIGHTALT) mods.alt = down;
    else if (code === KEY.LEFTSHIFT || code === KEY.RIGHTSHIFT) mods.shift = down;
    else if (value === 1) lastKeyAt = Date.now();

    if (value === 1 && isModeToggle(code, mods)) {
      setMode(mode === "tv" ? "desktop" : "tv");
      continue;
    }
    if (mode !== "tv") continue;

    if (value === 0) {
      const hid = held.get(code);
      if (hid !== undefined) void tv.button(hid, false);
      held.delete(code);
    } else if (value === 1) {
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
      if (wanted === "toggle") setMode(mode === "tv" ? "desktop" : "tv");
      else if (wanted === "tv" || wanted === "desktop") setMode(wanted);
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
        if (next) setMode(next);
      }
    }
  })();
}

/** Where input belongs right now, from the last connect or disconnect Sunshine logged. */
async function currentStreamMode(): Promise<Mode> {
  const text = await Bun.file(SUNSHINE_LOG).text().catch(() => "");
  const last = text.split("\n").reverse().map(streamMode).find((m) => m !== null);
  return last ?? "tv";
}

scan();
setInterval(scan, 2000); // the trackpad gets a new event node every time it wakes from sleep
setMode((process.env.SOFA_START_MODE as Mode | undefined) ?? (await currentStreamMode()));
followSunshine();
console.log(`sofa-hub: listening on ${SOCKET}, mode ${mode}`);
