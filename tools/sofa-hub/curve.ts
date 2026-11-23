// Generates libinput custom acceleration points for macOS trackpad feel, printed as Hyprland settings:
//   T=<macOS tracking speed, 0.6875 default> K=<px per macOS point> PTS=1 bun curve.ts
// Port of rolotrealanis98/m5pro-linux curves.lua (Apple HIDAccelCurves + IOHIDParametricAcceleration)
// for a Magic Trackpad at RES units/mm, k = Linux logical px per macOS point.
const RES = 47;
const P = [
  [0.0, 1.0, 0.0, 0.0, 7.4, 21], [0.125, 0.99, 0.5, 0.08, 7.3, 20], [0.5, 0.98, 0.66, 0.1, 7.2, 19],
  [0.6875, 0.96, 0.83, 0.12, 7.1, 18], [0.875, 0.94, 1.0, 0.15, 7.0, 17], [1.0, 0.92, 1.15, 0.18, 7.0, 16],
  [1.5, 0.89, 1.3, 0.21, 7.0, 15],
];
const S = [[0.0, 1.0, 0.0, 0, 6.0, 12], [0.125, 0.95, 0.6, 0, 6.2, 12], [0.5, 0.9, 0.9, 0, 6.4, 12]];
const interp = (t: number[][], i: number) => {
  let c = 0;
  t.forEach((r, j) => { if (i >= r[0]!) c = j; });
  const a = t[c]!, b = t[c + 1];
  if (!b || a[0] === i) return a;
  const f = (i - a[0]!) / (b[0]! - a[0]!);
  return a.map((v, j) => v + f * (b[j]! - v));
};
const apple = (c: number[]) => {
  const [, gl, gp, gc, tl, tr] = c as [number, number, number, number, number, number];
  const f1 = (x: number) => gl * x + (gp * x) ** 2 + (gc * x) ** 3;
  const m0 = gl + 2 * tl * gp ** 2 + 3 * tl ** 2 * gc ** 3, b0 = f1(tl) - m0 * tl;
  const y1 = m0 * tr + b0, m1 = 2 * y1 * m0, b1 = y1 ** 2 - m1 * tr;
  return (x: number) => (x <= tl ? f1(x) : x <= tr ? m0 * x + b0 : Math.sqrt(m1 * x + b1));
};
const RATE = Number(process.env.RATE ?? 120); // assumed macOS report rate (Hz)
const toX = (mmPerMs: number) => (mmPerMs * 1000 / RATE / 25.4) * 67; // inches per report * 67
const fromF = (fx: number) => fx * (96 / 67) * (RATE / 1000); // points per ms
const tracking = Number(process.env.T ?? 0.6875), k = Number(process.env.K ?? 1200 / 1470);
const pf = apple(interp(P, tracking));
const motion = (s: number) => fromF(pf(toX(s / RES))) * k; // s in device units/ms -> logical px/ms
// scroll: target slow-speed axis units per mm (BASE), Apple scroll shape at 0.3125
const sc = interp(S, 0.3125), sf = apple(sc);
const BASE = Number(process.env.BASE ?? 0.55); // wl axis units per mm of finger travel at rest
const coeff = (2 / 65536) * (1000 / 120) ** 2 - (0x3bb / 65536) * (1000 / 120) + 0x18041 / 65536;
const scroll = (s: number) => {
  if (s <= 0) return 0;
  const x = toX(s / RES) * coeff;
  return s * (BASE / RES) * (sf(x) / x / sc[1]!);
};
const N = 64, step = RES / (N - 1); // 0..1000 mm/s
const pts = (fn: (s: number) => number) => Array.from({ length: N }, (_, i) => fn(i * step).toFixed(4)).join(" ");
console.log(`tracking ${tracking} k ${k.toFixed(3)} rate ${RATE}`);
console.log("mm/s  px/mm(pointer)  axis/mm(scroll)");
for (const v of [5, 10, 20, 50, 100, 200, 300, 500, 1000]) {
  const s = (v * RES) / 1000;
  console.log(v, (motion(s) / (v / 1000)).toFixed(2), (scroll(s) / (v / 1000)).toFixed(3));
}
if (process.env.PTS) {
  console.log(`accel_profile = "custom ${step.toFixed(5)} ${pts(motion)}"`);
  console.log(`scroll_points = "${step.toFixed(5)} ${pts(scroll)}"`);
}
