// Kassan paikanpidon (§17) MOCK-moottori: ?mock=1&scenario=hold… (ei palvelinta, ei tallenna mitään palvelimelle). Käytetään order-mock.js:stä; tilat samat kuin palvelimen checkout_state.
// Skenaariot: hold (odottaa maksua, 15 min) | hold-partial (lahjakorttiosuus jo käytetty, loppu maksamatta) | hold-processing (maksua käsitellään, valmis ~procsec s) | hold-preliminary (ryhmävaraus, alustava)
// | hold-confirmed | hold-unpaid (vahvistettu, maksamatta) | hold-expired | hold-expired-gift (vanhentunut, lahjakorttiosuus palautettu) | hold-cancelled | hold-unavailable (verkkomaksu ei käytettävissä).
// Parametrit (vain mock): holdsec=N pidon pituus sekunteina (oletus 900), serverskew=N palvelimen kellon ero laitteeseen sekunteina (osoittaa ettei laitteen kelloa käytetä), procsec=N käsittelyn kesto.
// Pidon alku säilyy sessionStoragessa (sivun päivitys ei nollaa laskuria); luonti-RPC (kassa) käynnistää pidon alusta (restart).
export const HOLD_SCENARIO = /^hold(-partial|-processing|-preliminary|-confirmed|-unpaid|-expired|-expired-gift|-cancelled|-unavailable)?$/;
export const isHoldScenario = (s) => HOLD_SCENARIO.test(String(s || ''));

export function createHoldEngine({ scenario, holdSeconds = 900, skew = 0, procSeconds = 10, storage = globalThis.sessionStorage, ctx }) {
  const { o, sync, mp, mpMarkPaid, r2 } = ctx;
  const kind = scenario.replace(/^hold-?/, '') || 'awaiting';
  const t0 = Date.now(), p0 = typeof performance !== 'undefined' ? performance.now() : 0;
  const srvNow = () => t0 + ((typeof performance !== 'undefined' ? performance.now() : 0) - p0) + skew * 1000;   // palvelimen kello: monotoninen + ero (ei seuraa laitteen kellon muutoksia)
  const KEY = `bk-holdmock-${scenario}`;
  let start = null;
  try { const v = +storage?.getItem(KEY); if (Number.isFinite(v) && v > 0) start = v; } catch { /* ei sessionStorage */ }
  const restart = () => { start = srvNow(); try { storage?.setItem(KEY, String(start)); } catch { /* ei säilytystä */ } };
  if (start == null) restart();
  const prelim = kind === 'preliminary', holdMs = (prelim ? 7 * 86400 : holdSeconds) * 1000, expAt = () => start + holdMs;
  const gift = (p) => /lahjakort|gift/i.test(p.method_label || '');
  // alkutila
  if (kind === 'confirmed') { o.status = 'confirmed'; o.paid = o.total; o.payments = [{ status: 'paid', amount: o.total, paid_at: new Date().toISOString(), method_label: 'MobilePay', link_token: null, link_path: null }]; }
  if (kind === 'unpaid') o.status = 'confirmed';
  if (kind === 'expired' || kind === 'expired-gift') { o.status = 'expired'; if (kind === 'expired-gift') o.payments = [{ status: 'cancelled', amount: 20, paid_at: null, method_label: 'Lahjakortti', link_token: null, link_path: null }]; }
  if (kind === 'cancelled') o.status = 'cancelled';
  if (kind === 'partial') { o.paid = 20; o.payments = [{ status: 'paid', amount: 20, paid_at: new Date().toISOString(), method_label: 'Lahjakortti', link_token: null, link_path: null }]; }
  sync();
  const inflight = () => o.status === 'pending' && (kind === 'processing' ? srvNow() - start < procSeconds * 1000 : mp.started || (mp.returning && !mp.settled));
  function expire() {   // pidon vapautus: lahjakorttiosuudet palautetaan kortille (maksu 'cancelled'), tilaus vanhenee
    o.status = 'expired';
    for (const p of o.payments) if (gift(p) && p.status === 'paid') p.status = 'cancelled';
    o.paid = r2(o.payments.filter((p) => p.status === 'paid').reduce((s, p) => s + p.amount, 0)); sync();
  }
  function tick() {
    if (kind === 'processing' && o.status === 'pending' && !inflight()) mpMarkPaid();   // käsittely valmistui → vahvistettu
    if (o.status === 'pending' && !prelim && !inflight() && expAt() - srvNow() <= 0) expire();
  }
  function json() {
    const now = srvNow(), left = expAt() - now, inf = inflight();
    const st = o.status === 'cancelled' ? 'cancelled' : o.status === 'expired' ? 'expired' : o.status === 'pending' ? (prelim ? 'preliminary' : inf ? 'processing_payment' : 'awaiting_payment') : o.unpaid > 0.004 ? 'confirmed_unpaid' : 'confirmed';
    const pend = o.status === 'pending';
    return { checkout_state: st, awaiting_payment: st === 'awaiting_payment' || st === 'processing_payment', hold_kind: pend ? (prelim ? 'preliminary' : 'checkout') : null,
      hold_expires_at: pend && left > 0 ? new Date(expAt()).toISOString() : null, seconds_left: pend ? Math.max(0, Math.floor(left / 1000)) : null, server_now: new Date(now).toISOString(),
      remaining_amount: ['cancelled', 'expired'].includes(o.status) ? 0 : o.unpaid, payment_in_progress: inf };
  }
  const guard = () => (o.status === 'expired' ? 'order_expired' : o.status === 'pending' && prelim ? 'order_preliminary' : inflight() ? 'payment_in_progress' : null);
  const methods = () => (o.payments.some(gift) ? ['gift_card'] : []);
  return { kind, restart, tick, json, guard, methods, srvNow };
}

export const HOLD_ERRORS = {
  order_expired: 'Maksuaika on päättynyt', order_preliminary: 'Alustava varaus: maksu pyydetään vahvistuksen jälkeen', payment_in_progress: 'Maksua käsitellään jo', online_payment_unavailable: 'Verkkomaksu ei ole käytettävissä', too_many_pending: 'Liian monta maksamatonta varausta',
};

// Mock-parametrit osoitteesta (holdsec, serverskew, procsec); virheelliset arvot → oletus
export function holdMockParams(search = typeof location !== 'undefined' ? location.search : '') {
  const q = new URLSearchParams(search), n = (k, d, min = -86400) => { const v = q.has(k) ? +q.get(k) : NaN; return Number.isFinite(v) && v >= min ? v : d; };
  return { holdSeconds: n('holdsec', 900, 1), serverSkew: n('serverskew', 0), procSeconds: n('procsec', 10, 0) };
}
