// A minimal Chrome DevTools Protocol client: one websocket, request/response by id.
export function cdp(url: string) {
  const ws = new WebSocket(url); let id = 0; const pending = new Map<number, (v: any) => void>();
  ws.onmessage = (e) => { const m = JSON.parse(String(e.data)); if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id); } };
  return {
    ready: new Promise((r) => (ws.onopen = r)),
    send: (method: string, params: any = {}) => new Promise<any>((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); }),
  };
}
