// Opens page.html (a white flash and a 1 kHz beep together, every second) in a new tab of the streamed computer's
// browser over CDP, or closes it again.   bun open-page.ts <cdp-url> open|close
import { cdp } from "./cdp.ts";
const [base = "http://localhost:9222", mode = "open"] = process.argv.slice(2);
const idFile = `${import.meta.dir}/.tab-id`;
if (mode === "close") { await fetch(`${base}/json/close/${(await Bun.file(idFile).text()).trim()}`); console.log("closed"); process.exit(0); }
const html = await Bun.file(`${import.meta.dir}/page.html`).text();
const tab = await (await fetch(`${base}/json/new?about:blank`, { method: "PUT" })).json();
await Bun.write(idFile, tab.id);
const page = cdp(tab.webSocketDebuggerUrl); await page.ready;
await page.send("Page.enable");
await page.send("Page.navigate", { url: "data:text/html;base64," + Buffer.from(html).toString("base64") });
await Bun.sleep(1500);
await page.send("Page.bringToFront");
const r = await page.send("Runtime.evaluate", { expression: "ctx.resume().then(() => ctx.state)", awaitPromise: true, userGesture: true, returnByValue: true });
console.log("opened, audio:", r.result?.result?.value);
process.exit(0);
