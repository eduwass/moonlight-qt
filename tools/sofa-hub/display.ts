// The size of omarchypc's desktop on the TV, as the Sofa app's display settings show and try it: the stream's
// pixels (the Apple TV outputs 4K) and how big things look, as the size the desktop looks (its logical
// pixels); the scale is pixels / looks. The sofa streams it at the app's tvMode and tvScale. Trying a size
// sets it on the stream output ("virtual") at once, sends back a picture of it, and puts the output back as
// it was on cancel, after two quiet minutes, when the app goes, or when a stream starts. The helpers at the
// top are pure.
//
// The output is set straight through Hyprland (under the lock sunshine-virtual-display holds), not with
// `sunshine-virtual-display resize`: that one also unmutes this machine's speakers and sets up the cursor
// for a stream, which a preview with nobody streaming must not do.
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import type { TvMode } from "./settings.ts";
import { type Display, run, waylandEnv } from "./stats.ts";

export const OUTPUT = "virtual";
export const MODES: [number, number][] = [[1920, 1080], [2560, 1440], [3840, 2160]]; // the GTX 1080 encodes 4K60 HEVC
export const SIZES: { label: string; looks: [number, number] }[] = [
  { label: "Largest", looks: [960, 540] },
  { label: "Larger", looks: [1200, 675] },
  { label: "Balanced", looks: [1536, 864] },
  { label: "More space", looks: [1920, 1080] },
];
export const PREVIEW_WIDTH = 1920; // the picture of a 4K try is scaled down to this
export const PREVIEW_JPEG_MAX = 450_000; // bytes, before base64
const QUIET_MS = 120_000;

/** The scale Hyprland takes nearest to `scale` for a mode: one that gives whole logical pixels, a step of
 * 1/120 that divides both sides (as sunshine-virtual-display's apply() reckons; it rounds up, this to the
 * nearest, the larger on a tie). */
export function hyprScale(scale: number, width: number, height: number): number {
  const gcd = (a: number, b: number): number => (b ? gcd(b, a % b) : a);
  const g = gcd(width * 120, height * 120);
  const want = Math.min(Math.max(Math.round(scale * 120), 1), g);
  let up = want;
  while (g % up !== 0) up++;
  let down = want;
  while (down > 1 && g % down !== 0) down--;
  return (up - want <= want - down ? up : down) / 120;
}

/** What a size asked for becomes: the stream's mode, and the scale Hyprland takes with the size it looks. */
export function sizeTarget(pixels: [number, number], looks: [number, number], fps = 60): TvMode & { scale: number; looks: [number, number] } {
  const [width, height] = pixels;
  const scale = hyprScale(width / looks[0], width, height);
  return { width, height, fps, scale, looks: [Math.round(width / scale), Math.round(height / scale)] };
}

/** omarchypc's line in the app's display settings: the sofa's stream as it is set now. */
export function tvDisplayFacts(mode: TvMode, scale: number, why: string): Display {
  const s = hyprScale(scale, mode.width, mode.height);
  return {
    pixels: [mode.width, mode.height],
    scale: s,
    looks: [Math.round(mode.width / s), Math.round(mode.height / s)],
    modes: MODES,
    sizes: SIZES,
    tryable: !why,
    why,
  };
}

/** The Mac's text sizes: its stream display always draws at 2x, so a size is just how big it looks (points);
 * the receiver resizes it to try one, and keeping one makes it the sofa's from the next stream. */
export const MAC_SIZES: { label: string; looks: [number, number] }[] = [
  { label: "Largest", looks: [960, 540] },
  { label: "Larger", looks: [1280, 720] },
  { label: "Balanced", looks: [1536, 864] },
  { label: "More space", looks: [1920, 1080] },
];

/** The Mac's line in the app's display settings: its main display as the receiver sees it, its own sizes. */
export const macDisplayFacts = (d: Display, why: string): Display => ({
  pixels: d.pixels,
  scale: d.scale,
  looks: d.looks,
  modes: [d.pixels],
  sizes: MAC_SIZES,
  tryable: !why,
  why,
  perComputer: true,
});

/** The input path's one-way time from round trips: half their median, rounded (null with none). */
export function pathMs(roundTrips: number[]): number | null {
  if (!roundTrips.length) return null;
  const sorted = [...roundTrips].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  const median = sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
  return Math.round(median / 2);
}

/** Whether the last client line in Sunshine's log says a stream is up (null: none in the text). */
export function sunshineStreaming(log: string): boolean | null {
  const connected = log.lastIndexOf("CLIENT CONNECTED");
  const disconnected = log.lastIndexOf("CLIENT DISCONNECTED");
  return connected < 0 && disconnected < 0 ? null : connected > disconnected;
}

type Monitor = { name: string; width: number; height: number; refreshRate: number; scale: number; dpmsStatus?: boolean };
export type OutputState = { mode: string; scale: number };

/** "1920x1080@60" and the scale the output has now. */
export const outputState = (m: Monitor): OutputState => ({ mode: `${m.width}x${m.height}@${Math.round(m.refreshRate)}`, scale: m.scale });

/** Lua for Hyprland that sets the output, as sunshine-virtual-display's mode() writes it. */
export const monitorLua = (s: OutputState) => `hl.monitor({ output = "${OUTPUT}", mode = "${s.mode}", position = "auto", scale = ${s.scale} })`;

// ----------------------------------------------------------------- Hyprland

const RUNTIME = process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`;
const MODE_STATE = `${RUNTIME}/sunshine-virtual-mode`; // what sunshine-virtual-display's `watch` puts back
const TRIAL_FILE = `${RUNTIME}/sofa-hub-size-trial.json`; // the state to put back, should the hub restart mid-trial

export async function virtualOutput(): Promise<Monitor | null> {
  try {
    const monitors: Monitor[] = JSON.parse(new TextDecoder().decode((await run(["hyprctl", "monitors", "-j"], waylandEnv(), 2000))!));
    return monitors.find((m) => m.name === OUTPUT) ?? null;
  } catch {
    return null;
  }
}

/** Sets the output under sunshine-virtual-display's lock; with `stateLine`, also what its `watch` keeps. */
async function setOutput(s: OutputState, stateLine = ""): Promise<void> {
  const script = 'hyprctl eval "$1" > /dev/null && { [ -z "$2" ] || { printf "%s\\n" "$2" > "$3.new" && mv "$3.new" "$3"; }; }';
  await run(["flock", "-w", "3", `${MODE_STATE}.lock`, "sh", "-c", script, "sh", monitorLua(s), stateLine, MODE_STATE], waylandEnv(), 5000);
}

/** Waits until Hyprland shows the output at `s` (up to 1.5 s), switched on, then `drawMs` more: apps take a
 * few hundred ms to draw their windows at a new size (150 ms showed them half drawn). */
async function settle(s: OutputState, drawMs = 150): Promise<boolean> {
  for (let i = 0; i < 30; i++) {
    const m = await virtualOutput();
    if (m?.dpmsStatus === false) await run(["hyprctl", "eval", 'hl.dispatch(hl.dsp.dpms("on"))'], waylandEnv(), 2000).catch(() => null);
    if (m && outputState(m).mode === s.mode && Math.abs(m.scale - s.scale) < 0.005 && m.dpmsStatus !== false) {
      await Bun.sleep(drawMs);
      return true;
    }
    await Bun.sleep(50);
  }
  return false;
}

/** grim's -s for a picture of the whole output PREVIEW_WIDTH px wide at most (it scales logical pixels). */
export const captureFactor = (width: number, scale: number) => Math.min(scale, (PREVIEW_WIDTH * scale) / width);

/** The whole output, at most PREVIEW_WIDTH wide, as a JPEG under PREVIEW_JPEG_MAX, base64. */
async function capture(width: number, scale: number): Promise<string> {
  const factor = captureFactor(width, scale).toFixed(4);
  for (const quality of [80, 65, 50, 35]) {
    const jpeg = (await run(["grim", "-o", OUTPUT, "-s", factor, "-t", "jpeg", "-q", String(quality), "-"], waylandEnv(), 5000))!;
    if (jpeg.length <= PREVIEW_JPEG_MAX) return Buffer.from(jpeg).toString("base64");
  }
  throw new Error("picture too big");
}

const ruleScale = () => {
  try {
    return readFileSync(`${homedir()}/.config/hypr/monitors.lua`, "utf8").match(/^local omarchy_monitor_scale = (\S+)/m)?.[1] ?? "";
  } catch {
    return "";
  }
};

// ----------------------------------------------------------------- the trial

type Send = (m: object) => void;

/** Sizes tried from the app. One display change at a time; of trials asked for while one runs, only the
 * latest is answered. */
export class SizeTrial {
  private before: OutputState | null = null; // the output before the first try
  private tried: OutputState | null = null;
  private chain: Promise<unknown> = Promise.resolve();
  private latest = 0;
  private quiet: Timer | undefined;

  constructor(
    private readonly host: string,
    private readonly send: Send,
  ) {
    // A hub restarted mid-trial puts back what it had remembered.
    try {
      const before: OutputState = JSON.parse(readFileSync(TRIAL_FILE, "utf8"));
      this.before = before;
      void this.cancel("the hub restarted");
    } catch {}
  }


  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const p = this.chain.then(fn);
    this.chain = p.catch(() => {});
    return p;
  }

  private remember(before: OutputState | null): void {
    this.before = before;
    if (before) writeFileSync(TRIAL_FILE, JSON.stringify(before));
    else rmSync(TRIAL_FILE, { force: true });
    clearTimeout(this.quiet);
    if (before) this.quiet = setTimeout(() => void this.cancel("two quiet minutes"), QUIET_MS);
  }

  /** Shows the desktop at `pixels`, looking `looks`, on the stream output and answers with a picture of it,
   * and the scale and size it really took. */
  try(pixels: [number, number], looks: [number, number], whyNot: () => Promise<string>): void {
    const ticket = ++this.latest;
    const want = sizeTarget(pixels, looks);
    const target = { mode: `${want.width}x${want.height}@${want.fps}`, scale: want.scale };
    const answer = (more: object) => ticket === this.latest && this.send({ t: "sizePreview", host: this.host, pixels, looks, ...more });
    void this.serial(async () => {
      if (ticket !== this.latest) return; // a newer one is waiting
      const why = await whyNot();
      if (why) return answer({ error: why });
      if (!this.before) {
        const now = await virtualOutput();
        if (!now) return answer({ error: "no virtual output" });
        this.remember(outputState(now));
      } else this.remember(this.before); // restarts the two quiet minutes
      // Apps redraw at a new scale in ~450 ms; a new mode as well takes them longer.
      const modeChanges = (this.tried ?? this.before)?.mode !== target.mode;
      console.log(`size: trying ${target.mode} at ${target.scale}`);
      await setOutput(target);
      this.tried = target;
      if (!(await settle(target, modeChanges ? 700 : 450))) return answer({ error: "Hyprland did not take the size" });
      if (ticket !== this.latest) return;
      answer({ looks: want.looks, scale: want.scale, jpeg: await capture(want.width, want.scale) });
    }).catch((error) => answer({ error: (error as Error).message }));
  }

  /** Makes a size (from sizeTarget) the output's from now on, also what `watch` keeps; the caller saves it
   * as tvMode and tvScale. */
  keep(size: TvMode & { scale: number }): Promise<void> {
    this.latest++;
    const target = { mode: `${size.width}x${size.height}@${size.fps}`, scale: size.scale };
    return this.serial(async () => {
      console.log(`size: keeping ${target.scale}`);
      this.remember(null);
      this.tried = null;
      await setOutput(target, `${target.mode} ${target.scale} ${ruleScale()}`);
      await settle(target);
    });
  }

  /** Puts the output back exactly as it was before the first try. */
  cancel(why: string): Promise<void> {
    this.latest++;
    return this.serial(async () => {
      const before = this.before;
      if (!before) return;
      console.log(`size: back to ${before.mode} at ${before.scale} (${why})`);
      this.remember(null);
      this.tried = null;
      await setOutput(before);
      await settle(before);
    });
  }

  /** A stream has started: Sunshine's own `resize` has set the output for it already. A sofa stream gets
   * the tvScale from the hub next, so the trial is just forgotten. Another client's keeps the mode it set,
   * and the scale before the trial if it brought none of its own (the output still has the tried one).
   * ponytail: assumes Sunshine runs its prep-cmd before it logs CLIENT CONNECTED, as its log shows. */
  streamStarted(fromSofa: boolean): Promise<void> {
    this.latest++;
    return this.serial(async () => {
      const before = this.before;
      const tried = this.tried;
      if (!before) return;
      this.remember(null);
      this.tried = null;
      if (fromSofa) return void console.log("size: a sofa stream started; the trial is over");
      const now = await virtualOutput();
      if (!now || !tried || Math.abs(now.scale - tried.scale) >= 0.005) return;
      const back = { mode: outputState(now).mode, scale: before.scale };
      console.log(`size: a stream started; back to ${back.scale} at its ${back.mode}`);
      let state: string[] = [];
      try {
        state = readFileSync(MODE_STATE, "utf8").trim().split(" ");
      } catch {}
      await setOutput(back, `${back.mode} ${back.scale} ${state[2] ?? ruleScale()}`);
      await settle(back);
    });
  }
}
