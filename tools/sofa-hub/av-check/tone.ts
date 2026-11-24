// Crackles: takes apart a mic recording of the Sofa app's 440 Hz test tone. dips5ms counts 5 ms stretches
// where the tone's loudness falls below 60% (dropouts); notTonePct is how much of each 20 ms block is not the
// tone (clicks, distortion, noise); residualPeaksHz are the strongest frequencies in what is left.
//   bun tone.ts <recording.webm|wav>
import { RATE as rate, samples } from "./media.ts";
const file = process.argv[2];
if (!file) { console.error("usage: bun tone.ts <recording>"); process.exit(2); }
const x = await samples(file), n = x.length;
const w = Math.round(rate * 0.005), r: number[] = [];
for (let i = 0; i + w <= n; i += w) { let s = 0; for (let j = i; j < i + w; j++) s += x[j]! * x[j]!; r.push(Math.sqrt(s / w)); }
const peak = Math.max(...r);
let a = r.findIndex((v) => v > peak * 0.35), b = r.length - 1 - [...r].reverse().findIndex((v) => v > peak * 0.35);
a += 40; b -= 40; // skip 200 ms at each end
if (b <= a) { console.error("no tone found"); process.exit(1); }
const tone = r.slice(a, b), mean = tone.reduce((s, v) => s + v, 0) / tone.length;
const dips = tone.filter((v) => v < mean * 0.6).length;
const cv = Math.sqrt(tone.reduce((s, v) => s + (v - mean) ** 2, 0) / tone.length) / mean;
// Per 20 ms block: least-squares fit of sin/cos at 440 Hz; residual energy ratio.
const start = a * w, end = b * w, blk = Math.round(rate * 0.02), ratios: number[] = [], resid = new Float64Array(end - start);
for (let s = start; s + blk <= end; s += blk) {
  let ss = 0, sc = 0, cc = 0, xs = 0, xc = 0, sxx = 0;
  for (let i = s; i < s + blk; i++) { const t = (2 * Math.PI * 440 * i) / rate, si = Math.sin(t), co = Math.cos(t); ss += si * si; cc += co * co; sc += si * co; xs += x[i]! * si; xc += x[i]! * co; sxx += x[i]! * x[i]!; }
  const det = ss * cc - sc * sc, A = (xs * cc - xc * sc) / det, B = (xc * ss - xs * sc) / det;
  let e = 0; for (let i = s; i < s + blk; i++) { const t = (2 * Math.PI * 440 * i) / rate; const d = x[i]! - A * Math.sin(t) - B * Math.cos(t); e += d * d; resid[i - start] = d; }
  ratios.push(e / sxx);
}
ratios.sort((p, q) => p - q);
const N = Math.min(rate, resid.length), mags: [number, number][] = [];
for (let f = 20; f <= 12000; f += 10) { let re = 0, im = 0; for (let i = 0; i < N; i += 2) { const t = (2 * Math.PI * f * i) / rate; re += resid[i]! * Math.cos(t); im -= resid[i]! * Math.sin(t); } mags.push([f, Math.hypot(re, im)]); }
mags.sort((p, q) => q[1] - p[1]);
console.log(JSON.stringify({ toneSeconds: +((b - a) * 0.005).toFixed(2), loudnessWobble: +cv.toFixed(3), dips5ms: dips,
  notTonePct: { median: +(100 * ratios[Math.floor(ratios.length / 2)]!).toFixed(1), worst10pct: +(100 * ratios[Math.floor(ratios.length * 0.9)]!).toFixed(1) },
  residualPeaksHz: mags.slice(0, 8).map(([f]) => f) }));
