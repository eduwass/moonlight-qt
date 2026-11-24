// The Sofa app's speed check from omarchypc: the app listens, this sends it bytes for a few seconds (the
// Mac's receiver does the same from the Mac), so what the app counts is this computer's own path to the TV.

/** Writes bytes to the app's listener at addr:port for `seconds` as fast as the network takes them. */
export function sendSpeed(addr: string, port: number, seconds: number): Promise<number> {
  const chunk = new Uint8Array(256 * 1024);
  return new Promise((resolve, reject) => {
    let sent = 0;
    let end = 0;
    const timer = setTimeout(() => reject(new Error("timed out")), (seconds + 5) * 1000);
    const pump = (s: { write: (d: Uint8Array) => number; end: () => void }) => {
      while (performance.now() < end) {
        const n = s.write(chunk);
        sent += n;
        if (n < chunk.length) return; // the socket is full: drain calls back
      }
      clearTimeout(timer);
      s.end();
      resolve(sent);
    };
    Bun.connect({
      hostname: addr,
      port,
      socket: {
        open: (s) => ((end = performance.now() + seconds * 1000), pump(s)),
        drain: (s) => pump(s),
        data: () => {},
        error: (_s, e) => (clearTimeout(timer), reject(e)),
        connectError: (_s, e) => (clearTimeout(timer), reject(e)),
      },
    }).catch((e) => (clearTimeout(timer), reject(e)));
  });
}
