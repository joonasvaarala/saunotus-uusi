// Visma Pay: vismapay-start ja vismapay-notify (reconcile). Virheet palautetaan, ei heitetä.
export function createVismapayApi({ token, linkToken = null, functionUrl, anonKey = '', fetchImpl = (typeof fetch === 'function' ? fetch.bind(globalThis) : null), timeoutMs = 20000 } = {}) {
  async function post(name, body) {
    if (!fetchImpl || !functionUrl) return { ok: false, code: 'network' };
    const ctl = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timer = ctl ? setTimeout(() => ctl.abort(), timeoutMs) : null;
    try {
      const r = await fetchImpl(functionUrl(name), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...(anonKey ? { apikey: anonKey } : {}) },
        body: JSON.stringify(body), signal: ctl?.signal, credentials: 'omit', referrerPolicy: 'no-referrer',
      });
      const text = await r.text();
      let j = null;
      try { j = text ? JSON.parse(text) : null; } catch { j = null; }
      if (j && typeof j === 'object') return j.ok === false || r.ok ? j : { ok: false, code: j.code || 'http_' + r.status };
      return { ok: false, code: r.ok ? 'bad_response' : 'http_' + r.status };
    } catch (e) {
      return { ok: false, code: e?.name === 'AbortError' ? 'timeout' : 'network' };
    } finally { if (timer) clearTimeout(timer); }
  }
  return {
    start: () => post('vismapay-start', linkToken ? { link_token: linkToken } : { order_token: token }),   // linkToken: maksulinkkisivu /maksa/?p=<link_token>
    reconcile: () => post('vismapay-notify', { action: 'reconcile', order_token: token }),
  };
}
