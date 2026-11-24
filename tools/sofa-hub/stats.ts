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
};

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
    apps.push(name === "Helium" && c.title ? `Helium — ${c.title.replace(/ - Helium$/, "")}` : name);
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

/** {model_name: capacity} for every Bluetooth HID battery. */
export function hidBatteries(dir = "/sys/class/power_supply"): Record<string, number> {
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
  };
}
