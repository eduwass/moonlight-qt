// Lip sync: pairs each white flash of page.html (a brightness jump inside the TV in the camera picture) with its
// 1 kHz beep (mic) and reports how far the sound trails the picture. Positive = sound late.
//   bun sync.ts <recording.webm> [crop w:h:x:y of the TV's screen in the 640x360 camera frame]
// Check the crop with: ffmpeg -ss 5 -i rec.webm -frames:v 1 frame.jpg
import { RATE, brightness, samples } from "./media.ts";
const [file, crop = "300:130:250:100"] = process.argv.slice(2);
if (!file) { console.error("usage: bun sync.ts <recording.webm> [crop]"); process.exit(2); }
const frames = await brightness(file, crop), x = await samples(file);

const ys = frames.map(([, y]) => y).sort((a, b) => a - b), base = ys[Math.floor(ys.length * 0.5)]!, top = ys[Math.floor(ys.length * 0.98)]!;
const thr = base + (top - base) * 0.5, flashes: number[] = [];
for (let i = 1; i < frames.length; i++) {
  const [t0, y0] = frames[i - 1]!, [t1, y1] = frames[i]!;
  if (y1 > thr && y0 <= thr && (!flashes.length || t1 - flashes.at(-1)! > 0.5)) flashes.push(t0 + ((thr - y0) / (y1 - y0)) * (t1 - t0));
}

// 1 kHz energy per 2 ms step (Goertzel over 8 ms windows).
const w = Math.round(RATE * 0.002), k = (2 * Math.PI * 1000) / RATE, e: number[] = [];
for (let s = 0; s + w * 4 <= x.length; s += w) {
  let s1 = 0, s2 = 0;
  for (let i = s; i < s + w * 4; i++) { const s0 = x[i]! + 2 * Math.cos(k) * s1 - s2; s2 = s1; s1 = s0; }
  e.push(s1 * s1 + s2 * s2 - 2 * Math.cos(k) * s1 * s2);
}
const es = [...e].sort((a, b) => a - b), eb = es[Math.floor(es.length * 0.5)]!, et = es[Math.floor(es.length * 0.995)]!, ethr = eb + (et - eb) * 0.2;
const beeps: number[] = [];
for (let i = 1; i < e.length; i++) if (e[i]! > ethr && e[i - 1]! <= ethr && (!beeps.length || i * 0.002 - beeps.at(-1)! > 0.5)) beeps.push(i * 0.002);

const pairs = flashes.flatMap((f) => { const b = beeps.find((b) => Math.abs(b - f) < 0.45); return b === undefined ? [] : [Math.round((b - f) * 1000)]; });
const sorted = [...pairs].sort((a, b) => a - b);
console.log(JSON.stringify({ flashes: flashes.length, beeps: beeps.length, pairs: pairs.length,
  soundLateMs: { median: sorted[Math.floor(sorted.length / 2)], min: sorted[0], max: sorted.at(-1) }, each: pairs }));
