// What the Sofa app's list of computers shows about each one: load, memory, disk, uptime, what is on
// screen, and the sofa keyboard and trackpad's batteries. omarchypc's is gathered here; the Mac's
// receiver sends its own (mac-receiver.swift). The parsers are pure, so check.ts can test them.
import { readdirSync, readFileSync, statfsSync, statSync } from "node:fs";
import { hostname, networkInterfaces, type NetworkInterfaceInfo } from "node:os";

export type Host = {
  name: string;
  hostname: string;
  addresses: string[];
  cpu: number; // % busy since the last sample
  memUsed: number; // bytes
  memTotal: number;
  swapUsed: number;
  swapTotal: number;
  diskUsed: number; // root filesystem
  diskTotal: number;
  uptime: number; // seconds
  apps: string[]; // what is on screen, most recently used first
  os: "linux" | "macos";
  pressure: Pressure;
  display?: Display;
};

/** A screen as the Sofa app's display settings show it: its pixels, the scale it is drawn at, the size it
 * looks (pixels / scale), the sizes it may be set to, and whether one can be tried now (why not if not). */
export type Display = {
  pixels: [number, number];
  scale: number;
  looks: [number, number];
  modes?: [number, number][]; // the stream pixels it may be set to
  sizes?: { label: string; looks: [number, number] }[];
  tryable?: boolean;
  why?: string;
};

export type Pressure = "normal" | "warn" | "critical";
export type AppsShown = "titles" | "names" | "off";

export type Device = { kind: "keyboard" | "trackpad"; name: string; connected: boolean; battery: number | null };

/** Busy and total jiffies from /proc/stat's first line. */
export function cpuTimes(procStat: string): { busy: number; total: number } {
  const fields = (procStat.split("\n")[0] ?? "").trim().split(/\s+/).slice(1, 9).map(Number);
  const total = fields.reduce((a, b) => a + b, 0);
  return { busy: total - (fields[3] ?? 0) - (fields[4] ?? 0), total }; // idle and iowait are not busy
}

export const cpuPercent = (a: { busy: number; total: number }, b: { busy: number; total: number }) =>
  b.total > a.total ? Math.round((1000 * (b.busy - a.busy)) / (b.total - a.total)) / 10 : 0;

/** Memory and swap in bytes from /proc/meminfo. Used memory is what is not available. */
export function memory(meminfo: string): { memUsed: number; memTotal: number; swapUsed: number; swapTotal: number } {
  const kb = (key: string) => 1024 * Number(meminfo.match(new RegExp(`^${key}:\\s+(\\d+)`, "m"))?.[1] ?? 0);
  return {
    memUsed: kb("MemTotal") - kb("MemAvailable"),
    memTotal: kb("MemTotal"),
    swapUsed: kb("SwapTotal") - kb("SwapFree"),
    swapTotal: kb("SwapTotal"),
  };
}

/** Memory pressure from /proc/pressure/memory's "some avg10" (the share of the last 10 s a task waited on
 * memory) and how much is still available: warn over 10%, critical over 30% or under a tenth available. */
export function linuxPressure(psi: string, meminfo: string): Pressure {
  const some = Number(psi.match(/^some avg10=([\d.]+)/m)?.[1] ?? 0);
  const { memUsed, memTotal } = memory(meminfo);
  if (some > 30 || (memTotal > 0 && memTotal - memUsed < memTotal / 10)) return "critical";
  return some > 10 ? "warn" : "normal";
}

/** A browser title without the page's address Helium adds at its end ("Docs - https://…"). */
export const trimUrl = (title: string) => title.replace(/ - https?:\/\/\S*$/, "");

/** The apps line as the Sofa app asked: with the browser's tab ("Helium — Docs"), names only, or none. */
export function shapeApps(apps: string[], shown: AppsShown): string[] {
  if (shown === "off") return [];
  return apps.map((a) => (shown === "names" ? (a.split(" — ")[0] ?? a) : trimUrl(a)));
}

/** The LAN and Tailscale IPv4 addresses; container bridges are left out. */
export function addresses(interfaces: Record<string, NetworkInterfaceInfo[] | undefined>): string[] {
  return Object.entries(interfaces)
    .filter(([name]) => !/^(docker|br-|veth|virbr)/.test(name))
    .flatMap(([, infos]) => (infos ?? []).filter((i) => i.family === "IPv4" && !i.internal && !i.address.startsWith("169.254.")))
    .map((i) => i.address);
}

type Client = { class: string; title: string; focusHistoryID: number; mapped?: boolean; hidden?: boolean; visible?: boolean };

/** Hyprland window class to an app name: "com.mitchellh.ghostty" is "Ghostty". */
const appName = (cls: string) => {
  const last = cls.split(".").pop() || cls;
  return last.charAt(0).toUpperCase() + last.slice(1);
};

/** The apps with a window on screen (`hyprctl clients -j`), most recently focused first, each once. */
export function screenApps(clients: Client[], max = 5): string[] {
  const seen = new Set<string>();
  const apps: string[] = [];
  for (const c of [...clients].sort((a, b) => a.focusHistoryID - b.focusHistoryID)) {
    if (c.mapped === false || c.hidden || c.visible === false || !c.class) continue;
    const name = appName(c.class);
    if (seen.has(name)) continue;
    seen.add(name);
    apps.push(name === "Helium" && c.title ? `Helium — ${c.title.replace(/ - Helium( - .*)?$/, "")}` : name);
  }
  return apps.slice(0, max);
}

/** The sofa keyboard and trackpad, with batteries from /sys/class/power_supply ({model_name: capacity}). */
export function sofaDevices(batteries: Record<string, number>, present: { keyboard: boolean; trackpad: boolean }): Device[] {
  const battery = (re: RegExp) => Object.entries(batteries).find(([model]) => re.test(model))?.[1] ?? null;
  return [
    { kind: "keyboard", name: "Magic Keyboard", connected: present.keyboard, battery: battery(/keyboard/i) },
    { kind: "trackpad", name: "Magic Trackpad", connected: present.trackpad, battery: battery(/trackpad/i) },
  ];
}

// Reading capacity asks the device itself over Bluetooth, and the Magic Trackpad drops its connection
// when asked every 10 s (it reconnected every ~30 s until this cache; a single read is harmless).
// Batteries change slowly: read at most every BATTERY_EVERY_MS and answer from the cache in between.
const BATTERY_EVERY_MS = 10 * 60_000;
let batteryCache: { at: number; values: Record<string, number> } | null = null;

/** {model_name: capacity} for every Bluetooth HID battery, read at most every 10 minutes. */
export function hidBatteries(dir = "/sys/class/power_supply", now = Date.now()): Record<string, number> {
  if (batteryCache && now - batteryCache.at < BATTERY_EVERY_MS && dir === "/sys/class/power_supply") return batteryCache.values;
  const values = readBatteries(dir);
  if (dir === "/sys/class/power_supply") batteryCache = { at: now, values };
  return values;
}

function readBatteries(dir: string): Record<string, number> {
  const out: Record<string, number> = {};
  let names: string[] = [];
  try {
    names = readdirSync(dir).filter((n) => n.startsWith("hid-") && n.includes("-battery"));
  } catch {}
  for (const n of names) {
    try {
      out[readFileSync(`${dir}/${n}/model_name`, "utf8").trim()] = Number(readFileSync(`${dir}/${n}/capacity`, "utf8").trim());
    } catch {} // the device went away mid-read
  }
  return out;
}

// ----------------------------------------------------------------- this machine

// Run as a systemd user service the hub may not have Hyprland's instance in its environment: the newest
// one in $XDG_RUNTIME_DIR/hypr is the running session.
function hyprlandEnv(): Record<string, string | undefined> {
  if (process.env.HYPRLAND_INSTANCE_SIGNATURE) return process.env;
  const dir = `${process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`}/hypr`;
  try {
    const newest = readdirSync(dir).sort((a, b) => statSync(`${dir}/${b}`).mtimeMs - statSync(`${dir}/${a}`).mtimeMs)[0];
    return newest ? { ...process.env, HYPRLAND_INSTANCE_SIGNATURE: newest } : process.env;
  } catch {
    return process.env;
  }
}

async function hyprlandApps(): Promise<string[]> {
  try {
    const p = Bun.spawn(["hyprctl", "clients", "-j"], { env: hyprlandEnv(), stdout: "pipe", stderr: "ignore" });
    const timer = setTimeout(() => p.kill(), 2000);
    const text = await new Response(p.stdout).text();
    clearTimeout(timer);
    return screenApps(JSON.parse(text));
  } catch {
    return [];
  }
}

let lastCpu = cpuTimes(readFileSync("/proc/stat", "utf8"));

/** omarchypc's own line in the list. */
export async function localHost(name: string): Promise<Host> {
  const cpu = cpuTimes(readFileSync("/proc/stat", "utf8"));
  const busy = cpuPercent(lastCpu, cpu);
  lastCpu = cpu;
  const fs = statfsSync("/");
  return {
    name,
    hostname: hostname(),
    addresses: addresses(networkInterfaces()),
    cpu: busy,
    ...memory(readFileSync("/proc/meminfo", "utf8")),
    diskUsed: (fs.blocks - fs.bfree) * fs.bsize,
    diskTotal: fs.blocks * fs.bsize,
    uptime: Math.round(Number(readFileSync("/proc/uptime", "utf8").split(" ")[0])),
    apps: await hyprlandApps(),
    os: "linux",
    pressure: linuxPressure(readText("/proc/pressure/memory"), readText("/proc/meminfo")),
  };
}

const readText = (path: string) => {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
};

// ----------------------------------------------------------------- previews

type Monitor = { width: number; height: number; scale: number; x: number; disabled?: boolean };

/** grim's -s factor for an image about `width` px wide of the whole layout (monitors in logical px). */
export function grimScale(monitors: Monitor[], width = 640): number {
  const on = monitors.filter((m) => !m.disabled && m.scale > 0);
  if (!on.length) return 0.5;
  const left = Math.min(...on.map((m) => m.x));
  const right = Math.max(...on.map((m) => m.x + m.width / m.scale));
  return Math.min(1, width / Math.max(1, right - left));
}

/** Wayland's socket for a service started outside the session: the newest wayland-N in the runtime dir. */
export function waylandEnv(): Record<string, string | undefined> {
  const env = hyprlandEnv();
  if (env.WAYLAND_DISPLAY) return env;
  const dir = env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`;
  try {
    const newest = readdirSync(dir)
      .filter((n) => /^wayland-\d+$/.test(n))
      .sort((a, b) => statSync(`${dir}/${b}`).mtimeMs - statSync(`${dir}/${a}`).mtimeMs)[0];
    return { ...env, XDG_RUNTIME_DIR: dir, ...(newest ? { WAYLAND_DISPLAY: newest } : {}) };
  } catch {
    return env;
  }
}

export async function run(cmd: string[], env: Record<string, string | undefined>, ms: number): Promise<Uint8Array | null> {
  const p = Bun.spawn(cmd, { env, stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => p.kill(), ms);
  const [out, err, code] = await Promise.all([new Response(p.stdout).bytes(), new Response(p.stderr).text(), p.exited]);
  clearTimeout(timer);
  if (code !== 0) throw new Error(`${cmd[0]}: ${err.trim() || `exit ${code}`}`);
  return out;
}

/** omarchypc's whole screen as a JPEG about 640 px wide, base64, for the Sofa app's list of computers. */
export async function localPreview(): Promise<string> {
  const env = waylandEnv();
  let scale = 0.5;
  try {
    scale = grimScale(JSON.parse(new TextDecoder().decode((await run(["hyprctl", "monitors", "-j"], env, 2000))!)));
  } catch {}
  for (const quality of [70, 50, 35]) {
    const jpeg = await run(["grim", "-t", "jpeg", "-q", String(quality), "-s", scale.toFixed(4), "-"], env, 5000);
    const b64 = Buffer.from(jpeg!).toString("base64");
    if (b64.length <= PREVIEW_MAX) return b64;
  }
  throw new Error("preview too big");
}

export const PREVIEW_MAX = 150_000;
