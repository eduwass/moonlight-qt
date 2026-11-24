// Records camera + mic on the measuring laptop (pointed at the TV) through its browser over CDP, as WebM.
// Picks the built-in FaceTime camera (not an iPhone's Continuity Camera) and the built-in mic, with all voice
// processing off.   bun record.ts <seconds> <out.webm> [cdp-url]
import { cdp } from "./cdp.ts";
const [secs = "15", out = "av.webm", base = "http://localhost:9223"] = process.argv.slice(2);
const tab = await (await fetch(`${base}/json/new?https://example.com`, { method: "PUT" })).json();
const version = await (await fetch(`${base}/json/version`)).json();
const browser = cdp(version.webSocketDebuggerUrl); await browser.ready;
await browser.send("Browser.grantPermissions", { origin: "https://example.com", permissions: ["audioCapture", "videoCapture"] });
const page = cdp(tab.webSocketDebuggerUrl); await page.ready; await Bun.sleep(1500);
const expr = `(async () => {
  (await navigator.mediaDevices.getUserMedia({ audio: true })).getTracks().forEach(t => t.stop());
  const devs = await navigator.mediaDevices.enumerateDevices();
  const cam = devs.find(d => d.kind === "videoinput" && /FaceTime|Built-in/i.test(d.label)), mic = devs.find(d => d.kind === "audioinput" && /MacBook Pro Microphone/i.test(d.label) && d.deviceId !== "default");
  const stream = await navigator.mediaDevices.getUserMedia({ audio: { deviceId: mic ? { exact: mic.deviceId } : undefined, echoCancellation: false, noiseSuppression: false, autoGainControl: false }, video: { deviceId: cam ? { exact: cam.deviceId } : undefined, width: 640, height: 360, frameRate: 60 } });
  const rec = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp8,opus', audioBitsPerSecond: 256000 });
  const parts = []; rec.ondataavailable = (e) => parts.push(e.data); rec.start(250);
  await new Promise((r) => setTimeout(r, ${Number(secs)} * 1000)); rec.stop(); await new Promise((r) => (rec.onstop = r));
  stream.getTracks().forEach((t) => t.stop());
  const buf = new Uint8Array(await new Blob(parts).arrayBuffer()); let s = '';
  for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
  return btoa(s);
})()`;
const r = await page.send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
await fetch(`${base}/json/close/${tab.id}`);
if (!r.result?.result?.value) { console.error("record failed", JSON.stringify(r).slice(0, 400)); process.exit(1); }
await Bun.write(out, Buffer.from(r.result.result.value, "base64"));
console.log(`saved ${out}`); process.exit(0);
