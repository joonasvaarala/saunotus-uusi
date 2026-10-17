// MobilePay-maksun datakerros (kauppa): public_payment_options (RPC) + edge-funktiot mobilepay-start / mobilepay-notify (reconcile). Sopimus: KOODARI_talous_A_D_fi.md §14.
// Palvelimen virheet: HTTP 4xx/5xx + JSON {ok:false, code, message} → palautetaan sellaisenaan. Verkkovirhe / ei vastausta → {ok:false, code:'network'|'timeout'} (ei heitetä).
// Mock (osoitteessa ?mock=1): order-mock.js:n mpFetch vastaa samoilla muodoilla; mitään ei lähetetä palvelimelle.
export const MP_RPC = 'public_payment_options';
export const START_FN = 'mobilepay-start', NOTIFY_FN = 'mobilepay-notify';
const isMissingRpc = (e) => !!e && (e.status === 404 || e.code === 'PGRST202' || e.code === '42883' || /could not find the function/i.test(e.message || ''));

export function createMobilepayApi({ rpc, token, functionUrl, anonKey = '', fetchImpl = (typeof fetch === 'function' ? fetch.bind(globalThis) : null), timeoutMs = 20000 } = {}) {
  async function post(name, body) {
    if (!fetchImpl) return { ok: false, code: 'network' };
    const ctl = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timer = ctl ? setTimeout(() => ctl.abort(), timeoutMs) : null;
    try {
      const r = await fetchImpl(functionUrl(name), { method: 'POST', headers: { 'Content-Type': 'application/json', ...(anonKey ? { apikey: anonKey } : {}) }, body: JSON.stringify(body), signal: ctl?.signal, credentials: 'omit', referrerPolicy: 'no-referrer' });
      const text = await r.text();
      let j = null; try { j = text ? JSON.parse(text) : null; } catch { j = null; }
      if (j && typeof j === 'object') return r.ok || j.ok === false ? j : { ok: false, code: 'http_' + r.status };
      return { ok: false, code: r.ok ? 'bad_response' : 'http_' + r.status };
    } catch (e) {
      return { ok: false, code: e?.name === 'AbortError' ? 'timeout' : 'network' };
    } finally { if (timer) clearTimeout(timer); }
  }
  return {
    // → public_payment_options-vastaus tai null (RPC puuttuu / virhe: painiketta ei näytetä, ei virheilmoitusta asiakkaalle)
    async options() {
      try { const r = await rpc(MP_RPC, { p_token: token }); return r && typeof r === 'object' ? r : null; }
      catch (e) { if (!isMissingRpc(e)) { /* verkkovirhe tms.: ei painiketta */ } return null; }
    },
    start: () => post(START_FN, { order_token: token }),
    reconcile: () => post(NOTIFY_FN, { action: 'reconcile', order_token: token }),
  };
}
