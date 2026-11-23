// Per-touch palm rejection, the way a MacBook does it: each contact on the trackpad is judged on
// its own. One that begins while typing, or that ever grows palm-sized, is dropped until it lifts;
// every other finger passes straight through, even with a palm resting beside it.
// Pure (events in, events out), so check.ts can test it.

export const EV_KEY = 1;
export const EV_ABS = 3;
export const ABS = {
  X: 0,
  Y: 1,
  PRESSURE: 24,
  MT_SLOT: 47,
  MT_TOUCH_MAJOR: 48,
  MT_POSITION_X: 53,
  MT_POSITION_Y: 54,
  MT_TRACKING_ID: 57,
  MT_PRESSURE: 58,
} as const;
export const BTN = {
  LEFT: 272,
  TOOL_FINGER: 325,
  TOOL_QUINTTAP: 328,
  TOUCH: 330,
  TOOL_DOUBLETAP: 333,
  TOOL_TRIPLETAP: 334,
  TOOL_QUADTAP: 335,
} as const;

type Ev = { type: number; code: number; value: number };
type Contact = { id: number; accepted: boolean; shown: boolean; values: Map<number, number> };

const TOOLS = [0, BTN.TOOL_FINGER, BTN.TOOL_DOUBLETAP, BTN.TOOL_TRIPLETAP, BTN.TOOL_QUADTAP, BTN.TOOL_QUINTTAP];
const abs = (code: number, value: number): Ev => ({ type: EV_ABS, code, value });
const key = (code: number, value: number): Ev => ({ type: EV_KEY, code, value });

export class PalmFilter {
  private readonly contacts = new Map<number, Contact>(); // by slot
  private slot = 0;
  private tool = 0;
  private clicked = false;

  constructor(readonly palmMajor = 600) {}

  /** One frame from the real trackpad in; the frame for the desktop out (without its SYN_REPORT). */
  frame(events: Ev[], typing: boolean): Ev[] {
    const changed = new Set<number>();
    let click: number | null = null;
    for (const { type, code, value } of events) {
      if (type === EV_KEY && code === BTN.LEFT) click = value;
      if (type !== EV_ABS || code < ABS.MT_SLOT) continue; // single-touch axes are rebuilt below
      if (code === ABS.MT_SLOT) {
        this.slot = value;
        continue;
      }
      let c = this.contacts.get(this.slot);
      if (!c) this.contacts.set(this.slot, (c = { id: -1, accepted: false, shown: false, values: new Map() }));
      if (code === ABS.MT_TRACKING_ID) {
        if (value >= 0) Object.assign(c, { id: value, accepted: !typing, values: new Map() });
        else c.id = -1;
      } else {
        c.values.set(code, value);
        if (code === ABS.MT_TOUCH_MAJOR && value > this.palmMajor) c.accepted = false;
      }
      changed.add(this.slot);
    }

    const out: Ev[] = [];
    for (const slot of changed) {
      const c = this.contacts.get(slot)!;
      if (c.id >= 0 && c.accepted) {
        out.push(abs(ABS.MT_SLOT, slot));
        if (!c.shown) out.push(abs(ABS.MT_TRACKING_ID, c.id));
        for (const [code, value] of c.values) out.push(abs(code, value)); // the kernel drops repeats
        c.shown = true;
      } else if (c.shown) {
        out.push(abs(ABS.MT_SLOT, slot), abs(ABS.MT_TRACKING_ID, -1));
        c.shown = false;
      }
      if (c.id < 0) this.contacts.delete(slot);
    }
    return [...out, ...this.summary(click)];
  }

  /** Lift everything the desktop can see, e.g. when input moves to the Apple TV. */
  reset(): Ev[] {
    const out: Ev[] = [];
    for (const [slot, c] of this.contacts) if (c.shown) out.push(abs(ABS.MT_SLOT, slot), abs(ABS.MT_TRACKING_ID, -1));
    this.contacts.clear();
    return [...out, ...this.summary(this.clicked ? 0 : null)];
  }

  // The single-touch view a trackpad also reports: finger count, touching, the first finger's position, click.
  private summary(click: number | null): Ev[] {
    const shown = [...this.contacts.entries()].filter(([, c]) => c.shown).sort(([a], [b]) => a - b);
    const out: Ev[] = [];
    const tool = TOOLS[Math.min(shown.length, 5)]!;
    if (tool !== this.tool) {
      if (this.tool) out.push(key(this.tool, 0));
      if (tool) out.push(key(tool, 1));
      out.push(key(BTN.TOUCH, tool ? 1 : 0));
      this.tool = tool;
    }
    const first = shown[0]?.[1].values;
    if (first?.has(ABS.MT_POSITION_X)) out.push(abs(ABS.X, first.get(ABS.MT_POSITION_X)!));
    if (first?.has(ABS.MT_POSITION_Y)) out.push(abs(ABS.Y, first.get(ABS.MT_POSITION_Y)!));
    if (first?.has(ABS.MT_PRESSURE)) out.push(abs(ABS.PRESSURE, first.get(ABS.MT_PRESSURE)!));
    // A click counts only with a finger the desktop can see; its release always goes through.
    if (click === 1 && shown.length && !this.clicked) out.push(key(BTN.LEFT, 1)), (this.clicked = true);
    if (click === 0 && this.clicked) out.push(key(BTN.LEFT, 0)), (this.clicked = false);
    return out;
  }
}
