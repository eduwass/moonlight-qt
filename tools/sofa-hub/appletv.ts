// The Apple TV over the Companion protocol (what the iPhone Remote uses), through bunatv.
// bunatv is alpha and unlicensed, so it is cloned beside the hub (setup.sh), not vendored.
import { homedir } from "node:os";

const BUNATV = process.env.BUNATV_DIR ?? `${homedir()}/.local/share/sofa-hub/bunatv`;
const { discoverDevices } = await import(`${BUNATV}/src/cli/utils/device-lookup.ts`);
const { JsonStorage } = await import(`${BUNATV}/src/core/storage/json-storage.ts`);
const { CompanionProtocol } = await import(`${BUNATV}/src/protocols/companion/CompanionProtocol.ts`);
const { createHidCommand, HidCommandModifier } = await import(`${BUNATV}/src/protocols/companion/messages/hidCommand.ts`);

export class AppleTv {
  private protocol: any = null;
  private connecting: Promise<void> | null = null;

  constructor(readonly name: string) {}

  /** Connects when needed. Only the Companion link: bunatv's DeviceApi also opens AirPlay, which hangs. */
  async ready(): Promise<void> {
    if (this.protocol?.isReady) return;
    this.connecting ??= this.connect().finally(() => (this.connecting = null));
    await this.connecting;
  }

  /** Pairs once (the Apple TV shows a PIN). Credentials are saved before verifying: verifying on the same connection times out. */
  async pair(askPin: () => Promise<string>): Promise<void> {
    const storage = new JsonStorage();
    const device = await this.find();
    const protocol: any = new CompanionProtocol(device, storage, await storage.getClientDeviceInfo());
    await protocol.transport.connect(protocol.connectionInfo.address, protocol.connectionInfo.port, { timeout: 120_000, autoReconnect: false });
    const credentials = await protocol.authService.pair({ onPinRequired: askPin }, crypto.randomUUID().toUpperCase());
    await protocol.credentialStore.save(device.identifier, credentials);
  }

  private async find() {
    const device = (await discoverDevices(2)).find((d: { name: string }) => d.name === this.name);
    if (!device) throw new Error(`${this.name} not found on the network`);
    return device;
  }

  private async connect(): Promise<void> {
    this.protocol?.disconnect?.("reconnecting").catch(() => {});
    this.protocol = null;
    const storage = new JsonStorage();
    // Look the Apple TV up afresh each time: its remote service moves to a new port when it restarts.
    const protocol = new CompanionProtocol(await this.find(), storage, await storage.getClientDeviceInfo());
    await protocol.connect({ transportOptions: { timeout: 10_000, autoReconnect: false } });
    this.protocol = protocol;
    console.log(`apple tv: connected to ${this.name}`);
  }

  // Messages go out one at a time: overlapping sends scramble the encryption counter and the
  // Apple TV hangs up.
  private queue: Promise<void> = Promise.resolve();

  button(command: number, down: boolean): Promise<void> {
    this.queue = this.queue.then(() =>
      this.send(() => this.protocol.sendCommand(createHidCommand(command, down ? HidCommandModifier.Down : HidCommandModifier.Up))),
    );
    return this.queue;
  }

  // Nothing may hold the line for long: a hung connect or send would freeze every key
  // behind it. After 6 s the connection is thrown away and the next input builds a new one.
  private async send(fn: () => Promise<unknown>): Promise<void> {
    let timer: Timer | undefined;
    try {
      await Promise.race([
        this.ready().then(fn),
        new Promise((_, reject) => (timer = setTimeout(() => reject(new Error("timed out")), 6000))),
      ]);
    } catch (error) {
      console.error(`apple tv: ${(error as Error).message}; reconnecting on next input`);
      this.protocol?.disconnect?.("reset").catch(() => {});
      this.protocol = null;
      this.connecting = null;
    } finally {
      clearTimeout(timer);
    }
  }
}
