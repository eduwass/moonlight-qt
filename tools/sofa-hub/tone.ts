// The Sofa app's sound test: a steady 440 Hz tone on omarchypc's default output, which Sunshine carries
// into a stream. toneWav is pure; the Mac's receiver plays its own (mac-receiver.swift).
import type { Subprocess } from "bun";

/** A 16-bit stereo WAV of a sine at `dbfs` with `fadeMs` fades in and out. */
export function toneWav(seconds: number, { rate = 48_000, freq = 440, dbfs = -12, fadeMs = 10 } = {}): Uint8Array {
  const frames = Math.round(seconds * rate);
  const fade = Math.round((fadeMs / 1000) * rate);
  const amp = 32767 * 10 ** (dbfs / 20);
  const buf = new ArrayBuffer(44 + frames * 4);
  const v = new DataView(buf);
  const ascii = (at: number, s: string) => [...s].forEach((c, i) => v.setUint8(at + i, c.charCodeAt(0)));
  ascii(0, "RIFF");
  v.setUint32(4, 36 + frames * 4, true);
  ascii(8, "WAVEfmt ");
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true); // PCM
  v.setUint16(22, 2, true);
  v.setUint32(24, rate, true);
  v.setUint32(28, rate * 4, true);
  v.setUint16(32, 4, true);
  v.setUint16(34, 16, true);
  ascii(36, "data");
  v.setUint32(40, frames * 4, true);
  for (let i = 0; i < frames; i++) {
    const gain = Math.min(1, i / fade, (frames - 1 - i) / fade);
    const s = Math.round(amp * gain * Math.sin((2 * Math.PI * freq * i) / rate));
    v.setInt16(44 + i * 4, s, true);
    v.setInt16(46 + i * 4, s, true);
  }
  return new Uint8Array(buf);
}

let playing: Subprocess | null = null;

/** Plays the tone with pw-play, or paplay without it. Resolves once it is playing, or with why not. */
export async function playTone(seconds: number): Promise<{ ok: boolean; error?: string }> {
  playing?.kill();
  const path = `${process.env.XDG_RUNTIME_DIR ?? "/tmp"}/sofa-tone.wav`;
  await Bun.write(path, toneWav(seconds));
  let error = "";
  for (const player of ["pw-play", "paplay"]) {
    try {
      const p = Bun.spawn([player, path], { stdout: "ignore", stderr: "pipe" });
      playing = p;
      // Still running after a moment: playing. Gone already: it failed (no server, no output).
      const exited = await Promise.race([p.exited, Bun.sleep(300).then(() => null)]);
      if (exited === null || exited === 0) return { ok: true };
      error = `${player}: ${(await new Response(p.stderr).text()).trim() || `exit ${exited}`}`;
    } catch (e) {
      error = `${player}: ${(e as Error).message}`;
    }
  }
  return { ok: false, error };
}
