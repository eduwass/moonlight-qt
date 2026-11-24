// The Mac side of the hub. The receiver on the Mac (mac-receiver.swift) dials in over Tailscale,
// says when the Mac is being streamed, and gets keys plus trackpad input already shaped the way a
// Mac trackpad's would be: accelerated pointer moves, phased scrolls with momentum, two-finger
// clicks as right clicks, and three/four-finger swipes as Spaces and Mission Control shortcuts.
import type { Socket } from "bun";
import { pointerCurve, RES, scrollCurve } from "./curve.ts";
import { ABS, BTN, EV_ABS, EV_KEY } from "./palm.ts";

export type MacMessage =
  | { t: "key"; code: number; down: boolean }
  | { t: "move"; dx: number; dy: number }
  | { t: "button"; b: "left" | "right"; down: boolean }
  | { t: "scroll"; dx: number; dy: number; phase: number; momentum: number }
  | { t: "magnify"; m: number; phase: number }
  | { t: "smartzoom" }
  | { t: "dock"; d: number; axis: "h" | "v"; phase: number }
  | { t: "reset" };

// CGScrollPhase and CGMomentumScrollPhase values.
const PHASE = { None: 0, Began: 1, Changed: 2, Ended: 4 } as const;
const MOMENTUM = { None: 0, Begin: 1, Continue: 2, End: 3 } as const;
const DECIDE_UNITS = 2 * RES; // 2 mm of travel before a two- or three-finger gesture picks what it is
const PAD = { w: 7612, h: 5065 }; // trackpad size in device units
const SPACE_PER_PAD = 1 / 0.6; // a swipe across 60% of the trackpad moves one whole Space
const HID_PHASE = { Began: 1, Changed: 2, Ended: 4 } as const;
const DOUBLE_TAP_MS = 400;
const TAP_MS = 200; // a touch shorter than this, that barely moved, is a tap: one finger clicks, two right-click
const TAP_UNITS = 3 * RES;
const TAP_TO_CLICK = process.env.SOFA_MAC_TAP === "1"; // off by default: press to click, like the MacBooks

/** The receiver's connection. Only peers in `allowed` may connect; one at a time. */
export class MacLink {
  private socket: Socket<undefined> | null = null;

  constructor(hostname: string, port: number, allowed: string[], onStreaming: (on: boolean) => void) {
    Bun.listen({
      hostname,
      port,
      socket: {
        open: (s) => {
          if (!allowed.includes(s.remoteAddress)) return void s.end();
          this.socket?.end();
          this.socket = s;
          s.setNoDelay?.(true);
          console.log(`mac: receiver connected from ${s.remoteAddress}`);
        },
        data: (s, data) => {
          if (s !== this.socket) return;
          for (const line of data.toString().split("\n")) {
            if (line === "streaming") onStreaming(true);
            else if (line === "idle") onStreaming(false);
          }
        },
        close: (s) => {
          if (s !== this.socket) return;
          this.socket = null;
          console.log("mac: receiver gone");
          onStreaming(false);
        },
      },
    });
  }

  send(message: MacMessage): void {
    this.socket?.write(`${JSON.stringify(message)}\n`);
  }
}

type Point = { x: number; y: number };

/** Turns the palm-filtered trackpad frames into Mac input. */
export class MacTrackpad {
  private readonly contacts = new Map<number, Point>();
  private slot = 0;
  private last: { at: Point; count: number; time: number } | null = null;
  private button: "left" | "right" | null = null;
  private scrolling = false;
  private velocity: Point = { x: 0, y: 0 }; // scroll points per ms, smoothed
  private momentum: Timer | undefined;
  private swipe: { axis: "h" | "v" | null; x: number; y: number } = { axis: null, x: 0, y: 0 };
  private two: { mode: "scroll" | "pinch" | null; start: number; last: number; moved: number } | null = null;
  private lastTwoFingerTap = 0;
  private touch: { start: number; fingers: number; travel: number; clicked: boolean } | null = null;
  private readonly pointer: (s: number) => number;
  private readonly scroll: (s: number) => number;

  constructor(
    private readonly send: (m: MacMessage) => void,
    tracking = 0.6875,
    scrollBase = 4, // points per mm of finger travel at rest
  ) {
    this.pointer = pointerCurve(tracking, 1);
    this.scroll = scrollCurve(scrollBase);
  }

  frame(events: { type: number; code: number; value: number }[], now = performance.now()): void {
    let click: number | null = null;
    for (const { type, code, value } of events) {
      if (type === EV_KEY && code === BTN.LEFT) click = value;
      if (type !== EV_ABS) continue;
      if (code === ABS.MT_SLOT) this.slot = value;
      else if (code === ABS.MT_TRACKING_ID) value < 0 ? this.contacts.delete(this.slot) : this.contacts.set(this.slot, { x: 0, y: 0 });
      else if (code === ABS.MT_POSITION_X || code === ABS.MT_POSITION_Y) {
        const c = this.contacts.get(this.slot);
        if (c) c[code === ABS.MT_POSITION_X ? "x" : "y"] = value;
      }
    }
    const count = this.contacts.size;
    if (count && this.momentum) this.stopMomentum(); // a finger landing catches the page, as on a Mac
    if (count && !this.touch) this.touch = { start: now, fingers: count, travel: 0, clicked: false };
    if (this.touch) this.touch.fingers = Math.max(this.touch.fingers, count);
    if (click !== null && this.touch) this.touch.clicked = true;
    if (!count && this.touch) this.tapEnded(now);

    if (click === 1 && !this.button) this.send({ t: "button", b: (this.button = count >= 2 ? "right" : "left"), down: true });
    if (click === 0 && this.button) this.send({ t: "button", b: this.button, down: false }), (this.button = null);

    const at = centroid(this.contacts);
    const prev = this.last;
    this.last = at ? { at, count, time: now } : null;
    if (!prev || !at || prev.count !== count) return this.fingersChanged(prev?.count ?? 0, count);

    const dx = at.x - prev.at.x;
    const dy = at.y - prev.at.y;
    const dt = Math.max(1, now - prev.time);
    const speed = Math.hypot(dx, dy) / dt; // device units per ms
    if (!speed) return;
    if (this.touch) this.touch.travel += Math.hypot(dx, dy);

    if (count === 1 || this.button) {
      const gain = this.pointer(speed) / speed;
      this.send({ t: "move", dx: dx * gain, dy: dy * gain });
    } else if (count === 2) {
      this.twoFingers(dx, dy, dt, speed);
    } else {
      this.dockSwipe(dx, dy);
    }
  }

  // Two fingers either scroll or pinch; the first 2 mm decide which, and it stays that way until they lift.
  private twoFingers(dx: number, dy: number, dt: number, speed: number): void {
    const [a, b] = [...this.contacts.values()] as [Point, Point];
    const spread = Math.hypot(a.x - b.x, a.y - b.y);
    const two = (this.two ??= { mode: null, start: spread, last: spread, moved: 0 });
    two.moved += Math.hypot(dx, dy);
    if (!two.mode) {
      const pinch = Math.abs(spread - two.start);
      if (pinch > DECIDE_UNITS && pinch > two.moved) two.mode = "pinch";
      else if (two.moved > DECIDE_UNITS) two.mode = "scroll";
      else return;
      if (two.mode === "pinch") {
        this.send({ t: "magnify", m: spread / two.start - 1, phase: HID_PHASE.Began });
        two.last = spread;
        return;
      }
    }
    if (two.mode === "pinch") {
      this.send({ t: "magnify", m: spread / two.last - 1, phase: HID_PHASE.Changed });
      two.last = spread;
      return;
    }
    // Natural scrolling: the content follows the fingers.
    const gain = this.scroll(speed) / speed;
    const sx = dx * gain;
    const sy = dy * gain;
    this.velocity = { x: 0.7 * this.velocity.x + 0.3 * (sx / dt), y: 0.7 * this.velocity.y + 0.3 * (sy / dt) };
    this.send({ t: "scroll", dx: sx, dy: sy, phase: this.scrolling ? PHASE.Changed : PHASE.Began, momentum: MOMENTUM.None });
    this.scrolling = true;
  }

  // Three or four fingers drive the Dock's own swipe: Spaces slide under the fingers, up is Mission
  // Control, down App Exposé. The first 2 mm pick the direction.
  private dockSwipe(dx: number, dy: number): void {
    const sw = this.swipe;
    if (!sw.axis) {
      sw.x += dx;
      sw.y += dy;
      if (Math.hypot(sw.x, sw.y) < DECIDE_UNITS) return;
      sw.axis = Math.abs(sw.x) >= Math.abs(sw.y) ? "h" : "v";
      return this.send({ t: "dock", axis: sw.axis, d: this.dockDelta(sw.x, sw.y), phase: HID_PHASE.Began });
    }
    this.send({ t: "dock", axis: sw.axis, d: this.dockDelta(dx, dy), phase: HID_PHASE.Changed });
  }

  private dockDelta(dx: number, dy: number): number {
    return this.swipe.axis === "h" ? (-dx / PAD.w) * SPACE_PER_PAD : (dy / PAD.h) * SPACE_PER_PAD;
  }

  private tapEnded(now: number): void {
    const t = this.touch!;
    this.touch = null;
    if (t.clicked || now - t.start > TAP_MS || t.travel > TAP_UNITS || t.fingers > 2 || this.button) return;
    // Two-finger double-tap is smart zoom, as on a Mac, whether or not taps click.
    if (t.fingers === 2) {
      if (now - this.lastTwoFingerTap < DOUBLE_TAP_MS) return (this.lastTwoFingerTap = 0), this.send({ t: "smartzoom" });
      this.lastTwoFingerTap = now;
    }
    if (!TAP_TO_CLICK) return;
    const b = t.fingers === 2 ? "right" : "left";
    this.send({ t: "button", b, down: true });
    this.send({ t: "button", b, down: false });
  }

  /** Lifts everything the Mac thinks is held. */
  reset(): void {
    this.stopMomentum();
    if (this.scrolling) this.send({ t: "scroll", dx: 0, dy: 0, phase: PHASE.Ended, momentum: MOMENTUM.None });
    if (this.button) this.send({ t: "button", b: this.button, down: false });
    this.contacts.clear();
    this.touch = null;
    this.last = null;
    this.button = null;
    this.scrolling = false;
  }

  private fingersChanged(from: number, to: number): void {
    if (from === 2 && this.two?.mode === "pinch") this.send({ t: "magnify", m: 0, phase: HID_PHASE.Ended });
    if (to !== 2) this.two = null;
    if (from >= 3 && to < 3 && this.swipe.axis) this.send({ t: "dock", axis: this.swipe.axis, d: 0, phase: HID_PHASE.Ended });
    if (from === 2 && this.scrolling) {
      this.scrolling = false;
      this.send({ t: "scroll", dx: 0, dy: 0, phase: PHASE.Ended, momentum: MOMENTUM.None });
      this.startMomentum();
    }
    if (to < 3) this.swipe = { axis: null, x: 0, y: 0 };
  }

  // After the fingers lift, the scroll coasts and slows down, roughly like macOS's friction.
  private startMomentum(): void {
    let v = { ...this.velocity };
    this.velocity = { x: 0, y: 0 };
    if (Math.hypot(v.x, v.y) < 0.15) return; // a slow scroll stops where it is
    let first = true;
    this.momentum = setInterval(() => {
      v = { x: v.x * 0.95, y: v.y * 0.95 };
      const done = Math.hypot(v.x, v.y) < 0.02;
      this.send({
        t: "scroll",
        dx: v.x * 16,
        dy: v.y * 16,
        phase: PHASE.None,
        momentum: first ? MOMENTUM.Begin : done ? MOMENTUM.End : MOMENTUM.Continue,
      });
      first = false;
      if (done) this.stopMomentum(false);
    }, 16);
  }

  private stopMomentum(announce = true): void {
    if (!this.momentum) return;
    clearInterval(this.momentum);
    this.momentum = undefined;
    if (announce) this.send({ t: "scroll", dx: 0, dy: 0, phase: PHASE.None, momentum: MOMENTUM.End });
  }
}

function centroid(contacts: Map<number, Point>): Point | null {
  if (!contacts.size) return null;
  let x = 0;
  let y = 0;
  for (const c of contacts.values()) (x += c.x), (y += c.y);
  return { x: x / contacts.size, y: y / contacts.size };
}
