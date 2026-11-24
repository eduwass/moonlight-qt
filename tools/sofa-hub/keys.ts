// What the keyboard means to the Apple TV. Pure, so check.ts can test it.

/** Linux key codes (linux/input-event-codes.h) the hub cares about. */
export const KEY = {
  ESC: 1,
  BACKSPACE: 14,
  ENTER: 28,
  LEFTCTRL: 29,
  LEFTSHIFT: 42,
  H: 35,
  F3: 61,
  F8: 66, // play/pause on an Apple keyboard with F-keys first (hid-apple fnmode=2)
  F11: 87, // volume down, same
  F12: 88, // volume up, same
  SCALE: 120, // the Mission Control key (F3) on an Apple keyboard
  SPACE: 57,
  LEFTALT: 56,
  KPENTER: 96,
  RIGHTCTRL: 97,
  RIGHTALT: 100,
  UP: 103,
  LEFT: 105,
  RIGHT: 106,
  DOWN: 108,
  MUTE: 113,
  VOLUMEDOWN: 114,
  VOLUMEUP: 115,
  LEFTMETA: 125,
  RIGHTMETA: 126,
  NEXTSONG: 163,
  PLAYPAUSE: 164,
  PREVIOUSSONG: 165,
  RIGHTSHIFT: 54,
} as const;

/** Companion HID commands (bunatv's HidCommandType). */
export const HID = {
  Up: 1,
  Down: 2,
  Left: 3,
  Right: 4,
  Menu: 5,
  Select: 6,
  Home: 7,
  VolumeUp: 8,
  VolumeDown: 9,
  Wake: 13,
  PlayPause: 14,
  Mute: 18, // bunatv's PageUp, which its toggleMute sends
} as const;

export type Modifiers = { meta: boolean; ctrl: boolean; alt: boolean; shift: boolean };

const plain: Record<number, number> = {
  [KEY.UP]: HID.Up,
  [KEY.DOWN]: HID.Down,
  [KEY.LEFT]: HID.Left,
  [KEY.RIGHT]: HID.Right,
  [KEY.ENTER]: HID.Select,
  [KEY.KPENTER]: HID.Select,
  [KEY.ESC]: HID.Menu,
  [KEY.F3]: HID.Home,
  [KEY.SCALE]: HID.Home,
  [KEY.F8]: HID.PlayPause,
  [KEY.F11]: HID.VolumeDown,
  [KEY.F12]: HID.VolumeUp,
  [KEY.BACKSPACE]: HID.Menu,
  [KEY.SPACE]: HID.PlayPause,
  [KEY.PLAYPAUSE]: HID.PlayPause,
  [KEY.VOLUMEUP]: HID.VolumeUp,
  [KEY.VOLUMEDOWN]: HID.VolumeDown,
  [KEY.MUTE]: HID.Mute,
};

/** The Apple TV button a key press means, or null when it means nothing there. */
export function keyToHid(code: number, mods: Modifiers): number | null {
  if (mods.meta && code === KEY.H) return HID.Home;
  if (mods.meta || mods.ctrl || mods.alt) return null;
  return plain[code] ?? null;
}

/** The TV's volume keys, which go to the Apple TV (and over HDMI-CEC to the TV) even in a stream. F11 and
 * F12 stay F-keys there; with a modifier held, the key is the streamed computer's. */
export function tvVolumeKey(code: number, mods: Modifiers): number | null {
  if (code !== KEY.VOLUMEUP && code !== KEY.VOLUMEDOWN && code !== KEY.MUTE) return null;
  return mods.meta || mods.ctrl || mods.alt || mods.shift ? null : keyToHid(code, mods);
}

/** Keys that repeat when held, like the remote's arrows. */
export const repeats = (hid: number) => hid <= HID.Right || hid === HID.VolumeUp || hid === HID.VolumeDown;

/** Caps+Esc (keyd turns Caps into Ctrl+Alt+Shift+Cmd) switches between Apple TV and desktop. */
export const isModeToggle = (code: number, mods: Modifiers) =>
  code === KEY.ESC && mods.meta && mods.ctrl && mods.alt && mods.shift;

