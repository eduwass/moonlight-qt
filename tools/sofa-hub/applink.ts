// The link to the Sofa app on the Apple TV, newline-delimited JSON over TCP. The app says which screen
// it shows; the hub sends it the sofa devices, the computers' stats and, on its home screen, the trackpad.
import type { Socket } from "bun";

export type AppScreen = "home" | "stream" | "other";

/** Splits a byte stream into lines, keeping a partial last line for the next chunk. */
export function lineSplitter(): (chunk: string) => string[] {
  let rest = "";
  return (chunk) => {
    const lines = (rest + chunk).split("\n");
    rest = lines.pop() ?? "";
    return lines.filter((l) => l.trim());
  };
}

/** A peer's address without the IPv4-mapped IPv6 prefix. */
export const peerAddress = (address: string) => address.replace(/^::ffff:/, "");

/** The app's connection. Only peers in `allowed` may connect; the newest connection wins. */
export class AppLink {
  private socket: Socket<{ lines: (chunk: string) => string[] }> | null = null;
  screen: AppScreen = "other";

  constructor(
    port: number,
    allowed: string[],
    private readonly on: {
      connect: () => void;
      screen: (screen: AppScreen) => void;
      settings: (m: Record<string, unknown>) => void;
      restart: (host: string) => void;
      request: (m: Record<string, unknown>) => void; // trySize, keepSize, cancelSize, tone
      gone: () => void;
    },
  ) {
    Bun.listen<{ lines: (chunk: string) => string[] }>({
      hostname: "0.0.0.0",
      port,
      socket: {
        open: (s) => {
          if (!allowed.includes(peerAddress(s.remoteAddress))) return void s.end();
          s.data = { lines: lineSplitter() };
          this.socket?.end();
          this.socket = s;
          s.setNoDelay?.(true);
          console.log(`app: connected from ${s.remoteAddress}`);
          this.setScreen("other");
          this.on.connect();
        },
        data: (s, data) => {
          if (s !== this.socket) return;
          for (const line of s.data.lines(data.toString())) {
            try {
              const m = JSON.parse(line);
              if (m?.t === "screen" && ["home", "stream", "other"].includes(m.name)) this.setScreen(m.name);
              else if (m?.t === "settings") this.on.settings(m);
              else if (m?.t === "restart" && typeof m.host === "string") this.on.restart(m.host);
              else if (["trySize", "keepSize", "cancelSize", "tone", "speed"].includes(m?.t) && typeof m.host === "string") this.on.request(m);
              else if (m?.t === "offer") this.on.request(m);
              else if (m?.t === "screenshot" && typeof m.jpeg === "string") {
                // The answer to `bun hub.ts screenshot`: what the Apple TV shows, for debugging.
                const path = `${process.env.XDG_RUNTIME_DIR ?? "/tmp"}/sofa-app-screenshot.jpg`;
                void Bun.write(path, Buffer.from(m.jpeg, "base64")).then(() => console.log(`app: screenshot saved to ${path}`));
              }
            } catch {
              console.error(`app: not JSON: ${line.slice(0, 80)}`);
            }
          }
        },
        close: (s) => {
          if (s !== this.socket) return;
          this.socket = null;
          console.log("app: gone");
          this.setScreen("other");
          this.on.gone();
        },
      },
    });
  }

  /** The app's address, while it is connected. */
  get address(): string | null {
    return this.socket ? peerAddress(this.socket.remoteAddress) : null;
  }

  get connected(): boolean {
    return this.socket !== null;
  }

  send(message: object): void {
    this.socket?.write(`${JSON.stringify(message)}\n`);
  }

  private setScreen(screen: AppScreen): void {
    if (screen === this.screen) return;
    this.screen = screen;
    if (process.env.SOFA_DEBUG) console.log(`app: screen ${screen}`);
    this.on.screen(screen);
  }
}
