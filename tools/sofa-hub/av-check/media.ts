// ffmpeg helpers: a recording's sound as mono 48 kHz samples, and the mean brightness of a crop of each video frame.
export const RATE = 48_000;

async function run(args: string[]): Promise<Buffer> {
  const p = Bun.spawn(["ffmpeg", "-loglevel", "error", ...args], { stdout: "pipe", stderr: "pipe" });
  const out = Buffer.from(await new Response(p.stdout).arrayBuffer());
  if ((await p.exited) !== 0) throw new Error(`ffmpeg failed: ${await new Response(p.stderr).text()}`);
  return out;
}

export async function samples(file: string): Promise<Float64Array> {
  const b = await run(["-i", file, "-ac", "1", "-ar", String(RATE), "-f", "s16le", "-"]);
  const x = new Float64Array(b.length / 2);
  for (let i = 0; i < x.length; i++) x[i] = b.readInt16LE(i * 2) / 32768;
  return x;
}

/** [seconds, mean luma] per frame of the crop `w:h:x:y`. */
export async function brightness(file: string, crop: string): Promise<[number, number][]> {
  const text = (await run(["-i", file, "-an", "-vf", `crop=${crop},signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-`, "-f", "null", "-"])).toString();
  const frames: [number, number][] = []; let t = NaN;
  for (const l of text.split("\n")) { const m = l.match(/pts_time:([\d.]+)/); if (m) t = +m[1]!; const y = l.match(/YAVG=([\d.]+)/); if (y && !isNaN(t)) frames.push([t, +y[1]!]); }
  return frames;
}
