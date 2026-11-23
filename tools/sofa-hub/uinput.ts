// A virtual input device through /dev/uinput, built as a copy of a real one's capabilities.
import { dlopen, FFIType, ptr } from "bun:ffi";
import { closeSync, constants, openSync, writeSync } from "node:fs";

const { symbols: libc } = dlopen("libc.so.6", {
  ioctl: { args: [FFIType.i32, FFIType.u64, FFIType.u64], returns: FFIType.i32 },
});

const UI_SET_EVBIT = 0x40045564;
const UI_SET_KEYBIT = 0x40045565;
const UI_SET_ABSBIT = 0x40045567;
const UI_SET_PROPBIT = 0x4004556e;
const UI_DEV_SETUP = 0x405c5503; // struct uinput_setup: input_id(8) + name[80] + ff_effects_max(4)
const UI_ABS_SETUP = 0x401c5504; // struct uinput_abs_setup: code(2) + pad(2) + input_absinfo(24)
const UI_DEV_CREATE = 0x5501;
const UI_DEV_DESTROY = 0x5502;
const EV_SYN = 0;

export type AbsInfo = { value: number; min: number; max: number; fuzz: number; flat: number; resolution: number };
export type Spec = {
  name: string;
  id: { bus: number; vendor: number; product: number; version: number };
  props: number[];
  keys: number[];
  abs: Map<number, AbsInfo>;
};

export class VirtualDevice {
  private readonly fd: number;

  constructor(spec: Spec) {
    this.fd = openSync("/dev/uinput", constants.O_WRONLY | constants.O_NONBLOCK);
    const io = (request: number, arg: number) => {
      if (libc.ioctl(this.fd, request, arg) < 0) throw new Error(`uinput ioctl 0x${request.toString(16)} failed`);
    };
    io(UI_SET_EVBIT, 1); // EV_KEY
    io(UI_SET_EVBIT, 3); // EV_ABS
    for (const prop of spec.props) io(UI_SET_PROPBIT, prop);
    for (const k of spec.keys) io(UI_SET_KEYBIT, k);
    for (const [code, a] of spec.abs) {
      io(UI_SET_ABSBIT, code);
      const setup = new DataView(new ArrayBuffer(28));
      setup.setUint16(0, code, true);
      [a.value, a.min, a.max, a.fuzz, a.flat, a.resolution].forEach((v, i) => setup.setInt32(4 + i * 4, v, true));
      io(UI_ABS_SETUP, ptr(setup.buffer));
    }
    const dev = new DataView(new ArrayBuffer(92));
    [spec.id.bus, spec.id.vendor, spec.id.product, spec.id.version].forEach((v, i) => dev.setUint16(i * 2, v, true));
    new Uint8Array(dev.buffer, 8, 79).set(new TextEncoder().encode(spec.name).subarray(0, 79));
    io(UI_DEV_SETUP, ptr(dev.buffer));
    io(UI_DEV_CREATE, 0);
  }

  /** Writes one frame and its SYN_REPORT. */
  write(events: { type: number; code: number; value: number }[]): void {
    if (!events.length) return;
    const buf = Buffer.alloc((events.length + 1) * 24); // struct input_event; the kernel stamps the time
    events.forEach((e, i) => {
      buf.writeUInt16LE(e.type, i * 24 + 16);
      buf.writeUInt16LE(e.code, i * 24 + 18);
      buf.writeInt32LE(e.value, i * 24 + 20);
    });
    buf.writeUInt16LE(EV_SYN, events.length * 24 + 16);
    writeSync(this.fd, buf);
  }

  close(): void {
    libc.ioctl(this.fd, UI_DEV_DESTROY, 0);
    closeSync(this.fd);
  }
}
