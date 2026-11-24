// Self-check for the key mapping: bun check.ts
import { equal } from "node:assert/strict";
import { HID, KEY, isModeToggle, keyToHid, repeats, tvVolumeKey } from "./keys.ts";

const none = { meta: false, ctrl: false, alt: false, shift: false };
const cmd = { ...none, meta: true };
const hyper = { meta: true, ctrl: true, alt: true, shift: true };

equal(keyToHid(KEY.UP, none), HID.Up);
equal(keyToHid(KEY.ENTER, none), HID.Select);
equal(keyToHid(KEY.ESC, none), HID.Menu);
equal(keyToHid(KEY.H, cmd), HID.Home);
equal(keyToHid(KEY.H, none), null);
equal(keyToHid(KEY.SCALE, none), HID.Home, "Mission Control key goes home");
equal(keyToHid(KEY.F12, none), HID.VolumeUp, "F12 is volume up with F-keys first");
equal(keyToHid(KEY.UP, cmd), null, "a shortcut is not an arrow press");
equal(isModeToggle(KEY.ESC, hyper), true);
equal(isModeToggle(KEY.ESC, cmd), false);
equal(repeats(HID.Left), true);
equal(repeats(HID.Select), false);
equal(tvVolumeKey(KEY.VOLUMEUP, none), HID.VolumeUp, "volume up goes to the TV in a stream");
equal(tvVolumeKey(KEY.MUTE, none), HID.Mute);
equal(tvVolumeKey(KEY.F12, none), null, "F12 stays an F-key in a stream");
equal(tvVolumeKey(KEY.VOLUMEDOWN, { ...none, shift: true }), null, "with a modifier it is the computer's");

// Palm rejection, touch by touch.
{
  const { ABS, BTN, EV_ABS, EV_KEY, PalmFilter } = await import("./palm.ts");
  const a = (code: number, value: number) => ({ type: EV_ABS, code, value });
  const k = (code: number, value: number) => ({ type: EV_KEY, code, value });
  const has = (out: { code: number; value: number }[], code: number, value: number) => out.some((e) => e.code === code && e.value === value);
  const land = (slot: number, id: number, major: number) => [a(ABS.MT_SLOT, slot), a(ABS.MT_TRACKING_ID, id), a(ABS.MT_TOUCH_MAJOR, major), a(ABS.MT_POSITION_X, 10 * slot), a(ABS.MT_POSITION_Y, 5)];

  const f = new PalmFilter(600);
  let out = f.frame([...land(0, 1, 300), k(BTN.TOUCH, 1)], false);
  equal(has(out, ABS.MT_TRACKING_ID, 1) && has(out, BTN.TOOL_FINGER, 1) && has(out, BTN.TOUCH, 1), true, "a finger passes");
  out = f.frame(land(1, 2, 300), true);
  equal(has(out, ABS.MT_TRACKING_ID, 2) || has(out, ABS.MT_SLOT, 1), false, "a touch that lands while typing is dropped");
  out = f.frame([a(ABS.MT_SLOT, 1), a(ABS.MT_POSITION_X, 99)], false);
  equal(has(out, ABS.MT_SLOT, 1) || has(out, ABS.MT_POSITION_X, 99), false, "and stays dropped after typing stops, until it lifts");
  out = f.frame([a(ABS.MT_SLOT, 0), a(ABS.MT_TOUCH_MAJOR, 800)], false);
  equal(has(out, ABS.MT_TRACKING_ID, -1) && has(out, BTN.TOUCH, 0), true, "a finger that grows palm-sized is lifted");
  out = f.frame([k(BTN.LEFT, 1)], false);
  equal(has(out, BTN.LEFT, 1), false, "a click with only palms down is dropped");
  out = f.frame([...land(2, 3, 250)], false);
  equal(has(out, ABS.MT_TRACKING_ID, 3) && has(out, BTN.TOOL_FINGER, 1), true, "a new finger works at once beside a resting palm");
  out = f.reset();
  equal(has(out, ABS.MT_TRACKING_ID, -1) && has(out, BTN.TOUCH, 0), true, "reset lifts what the desktop sees");
}
console.log("sofa-hub check passed");
