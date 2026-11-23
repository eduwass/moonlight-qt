// Linux input devices read straight from /dev/input, with exclusive grab via ioctl.
import { dlopen, FFIType, ptr } from "bun:ffi";
import { closeSync, createReadStream, openSync, readFileSync } from "node:fs";

const { symbols: libc } = dlopen("libc.so.6", {
  ioctl: { args: [FFIType.i32, FFIType.u64, FFIType.u64], returns: FFIType.i32 },
});

const EVIOCGRAB = 0x40044590;
const EVIOCGABS = (axis: number) => 0x80184540 + axis;
const EVENT_SIZE = 24; // struct input_event on 64-bit: timeval(16) + type(2) + code(2) + value(4)

export const EV_SYN = 0;
export const EV_KEY = 1;

export type InputEvent = { type: number; code: number; value: number };

/** Path of the event node for the input device with this exact name, or null. */
export function findEventNode(name: string): string | null {
  for (const block of readFileSync("/proc/bus/input/devices", "utf8").split("\n\n")) {
    if (!block.includes(`N: Name="${name}"`)) continue;
    const node = block.match(/H: Handlers=.*?\b(event\d+)/)?.[1];
    if (node) return `/dev/input/${node}`;
  }
  return null;
}

/** Bus, vendor, product and version of the named device, from /proc. */
export function deviceId(name: string): { bus: number; vendor: number; product: number; version: number } | null {
  for (const block of readFileSync("/proc/bus/input/devices", "utf8").split("\n\n")) {
    if (!block.includes(`N: Name="${name}"`)) continue;
    const m = block.match(/I: Bus=(\w+) Vendor=(\w+) Product=(\w+) Version=(\w+)/);
    if (m) return { bus: parseInt(m[1]!, 16), vendor: parseInt(m[2]!, 16), product: parseInt(m[3]!, 16), version: parseInt(m[4]!, 16) };
  }
  return null;
}

/** One open input device. Delivers events a frame at a time (up to each SYN_REPORT). */
export class InputDevice {
  private readonly fd: number;
  private grabbed = false;
  closed = false;

  constructor(
    readonly path: string,
    onFrame: (events: InputEvent[]) => void,
    onGone: () => void,
  ) {
    this.fd = openSync(path, "r");
    const stream = createReadStream(path, { fd: this.fd, highWaterMark: EVENT_SIZE * 64, autoClose: false });
    let pending = Buffer.alloc(0);
    let frame: InputEvent[] = [];
    stream.on("data", (chunk: Buffer) => {
      const data = pending.length ? Buffer.concat([pending, chunk]) : chunk;
      let offset = 0;
      for (; offset + EVENT_SIZE <= data.length; offset += EVENT_SIZE) {
        const type = data.readUInt16LE(offset + 16);
        const code = data.readUInt16LE(offset + 18);
        const value = data.readInt32LE(offset + 20);
        if (type === EV_SYN) {
          if (code === 0 && frame.length) onFrame(frame);
          frame = [];
        } else frame.push({ type, code, value });
      }
      pending = data.subarray(offset);
    });
    const gone = () => {
      if (this.closed) return;
      this.close();
      onGone();
    };
    stream.on("error", gone);
    stream.on("end", gone);
  }

  /** Take (or give back) the device exclusively: while grabbed, the desktop sees none of its input. */
  grab(on: boolean): void {
    if (this.closed || this.grabbed === on) return;
    if (libc.ioctl(this.fd, EVIOCGRAB, on ? 1 : 0) === 0) this.grabbed = on;
  }

  /** An absolute axis's current value, range and resolution, or null when the device has no such axis. */
  absInfo(axis: number): { value: number; min: number; max: number; fuzz: number; flat: number; resolution: number } | null {
    const i = new Int32Array(6);
    if (libc.ioctl(this.fd, EVIOCGABS(axis), ptr(i)) < 0) return null;
    return { value: i[0]!, min: i[1]!, max: i[2]!, fuzz: i[3]!, flat: i[4]!, resolution: i[5]! };
  }

  close(): void {
    if (this.closed) return;
    try {
      this.grab(false);
      this.closed = true;
      closeSync(this.fd);
    } catch {
      // The device is already gone.
    }
  }
}
