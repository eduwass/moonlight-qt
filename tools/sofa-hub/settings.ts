// The Sofa app's settings: it sends them on connect and on every change, and the hub keeps the last
// ones in ~/.config/sofa-hub/app-settings.json so they hold across restarts. parseSettings is pure.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import type { AppsShown } from "./stats.ts";

export type Settings = {
  statsEvery: number; // seconds between stats on the app's home screen; 0 = never
  previewsEvery: number; // seconds between screen previews there; 0 = never
  tvMode: string; // omarchypc's stream output when the sofa streams it, "3840x2160@60"
  tvScale: number; // and its desktop scale then
  trackpadSpeed: number; // macOS tracking speed, for the app's pointer and the Mac's
  tapToClick: boolean;
  naturalScroll: boolean;
  volumeKeysToTV: boolean; // in a stream the volume keys go to the Apple TV, not the computer
  apps: AppsShown;
  instantCursor: boolean; // the Apple TV draws the Mac's cursor; off: Sunshine draws it in the picture
};

export const DEFAULTS: Settings = {
  statsEvery: 5,
  previewsEvery: 0,
  tvMode: process.env.SOFA_TV_MODE ?? "1920x1080@60",
  tvScale: Number(process.env.SOFA_TV_SCALE ?? 1.6),
  trackpadSpeed: 0.6875,
  tapToClick: process.env.SOFA_MAC_TAP === "1",
  naturalScroll: true,
  volumeKeysToTV: true,
  apps: "titles",
  instantCursor: true,
};

const num = (v: unknown, min: number, max: number) => (typeof v === "number" && Number.isFinite(v) && v >= min && v <= max ? v : undefined);
const bool = (v: unknown) => (typeof v === "boolean" ? v : undefined);

/** `prev` with every well-formed field of `m` taken over; anything missing or out of range is ignored. */
export function parseSettings(m: Record<string, unknown>, prev: Settings = DEFAULTS): Settings {
  return {
    statsEvery: num(m.statsEvery, 0, 3600) ?? prev.statsEvery,
    previewsEvery: num(m.previewsEvery, 0, 86_400) ?? prev.previewsEvery,
    tvMode: typeof m.tvMode === "string" && parseMode(m.tvMode) ? m.tvMode : prev.tvMode,
    tvScale: num(m.tvScale, 0.5, 4) ?? prev.tvScale,
    trackpadSpeed: num(m.trackpadSpeed, 0, 3) ?? prev.trackpadSpeed,
    tapToClick: bool(m.tapToClick) ?? prev.tapToClick,
    naturalScroll: bool(m.naturalScroll) ?? prev.naturalScroll,
    volumeKeysToTV: bool(m.volumeKeysToTV) ?? prev.volumeKeysToTV,
    apps: m.apps === "titles" || m.apps === "names" || m.apps === "off" ? m.apps : prev.apps,
    instantCursor: bool(m.instantCursor) ?? prev.instantCursor,
  };
}

export type TvMode = { width: number; height: number; fps: number };

/** "3840x2160@60" as numbers, or null when it is not a mode a stream could have. */
export function parseMode(mode: string): TvMode | null {
  const m = mode.match(/^(\d+)x(\d+)@(\d+)$/);
  if (!m) return null;
  const [width, height, fps] = [Number(m[1]), Number(m[2]), Number(m[3])];
  return width >= 640 && width <= 7680 && height >= 360 && height <= 4320 && fps >= 24 && fps <= 240 ? { width, height, fps } : null;
}

const FILE = `${homedir()}/.config/sofa-hub/app-settings.json`;

export function loadSettings(): Settings {
  try {
    return parseSettings(JSON.parse(readFileSync(FILE, "utf8")));
  } catch {
    return DEFAULTS;
  }
}

export function saveSettings(s: Settings): void {
  try {
    mkdirSync(`${homedir()}/.config/sofa-hub`, { recursive: true });
    writeFileSync(FILE, `${JSON.stringify(s, null, 2)}\n`);
  } catch (error) {
    console.error(`settings: not saved: ${(error as Error).message}`);
  }
}
