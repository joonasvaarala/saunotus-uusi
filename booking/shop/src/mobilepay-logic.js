// MobilePay-maksun logiikka (ei DOMia): painikkeen näyttöpäätös, paluutilan luokittelu ja tilan kysely (polling). Sopimus: KOODARI_talous_A_D_fi.md §14.
export const POLL_INTERVAL_MS = 2500;   // §14.3: 2-3 s välein
export const POLL_MAX_MS = 60000;       // §14.3: enintään ~60 s
export const RECONCILE_EVERY = 4;       // reconcile kysyy Vippsiltä: ensin heti, sitten joka 4. kierros (~10 s); välissä pelkkä public_get_order (kevyt, webhook voi ehtiä ensin)

// public_payment_options -vastaus → { ok, method, pending, canPay }
export function normOptions(r) {
  if (!r || r.ok === false) return { ok: false, method: null, pending: false, canPay: false };
  const method = (Array.isArray(r.methods) ? r.methods : []).find((m) => m && m.code === 'mobilepay') || null;
  return { ok: true, method, canPay: !!(method && r.order && r.order.can_pay_online === true), pending: !!r.order?.mobilepay_pending, unpaid: r.order?.unpaid ?? null };
}
// Näytetäänkö painike: methods sisältää mobilepayn JA order.can_pay_online. Testitilan tapa (methods[].test=true) vain testiympäristössä (env.testUi) – tuotantosivustolla piilotetaan.
export function shouldShowButton(opts, env = {}) {
  const o = opts && typeof opts === 'object' && 'canPay' in opts ? opts : normOptions(opts);
  if (!o.ok || !o.method || !o.canPay) return false;
  if (o.method.test === true && !env.testUi) return false;
  return true;
}
// Testiympäristö: config.js testUi (rakennus: BOOKING_MOBILEPAY_TEST_UI tai SITE_ENV=test) tai ?mock=1
export function testUiEnabled(cfg = {}, search = '') {
  if (new URLSearchParams(search || '').get('mock') === '1') return true;
  const v = cfg.mobilepayTestUi;
  return v === true || v === 'true' || v === '1' || v === 1;
}
// Vain https (Vipps/MobilePay-sivu); paikallinen http sallitaan vain localhostille (mock/kehitys)
export function safeRedirect(url, { allowHttpLocal = false } = {}) {
  let u; try { u = new URL(String(url)); } catch { return null; }
  if (u.protocol === 'https:') return u.href;
  if (allowHttpLocal && u.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(u.hostname)) return u.href;
  return null;
}
// mobilepay-notify reconcile -vastaus → paluutila. results[].outcome: paid, paid_needs_review, pending, not_authorized, cancelled_slot_lost, capture_failed, amount_mismatch (+ error)
// Tilat: 'paid' | 'review' (maksettu, henkilökunta tarkistaa) | 'failed' | 'slot_lost' | 'contact' | 'pending' | 'none' (ei yhtään yritystä)
export function classifyResults(results) {
  const rs = Array.isArray(results) ? results.map((x) => x?.outcome).filter(Boolean) : [];
  if (!rs.length) return 'none';
  if (rs.includes('paid')) return 'paid';
  if (rs.includes('paid_needs_review')) return 'review';
  if (rs.includes('cancelled_slot_lost')) return 'slot_lost';
  if (rs.includes('pending') || rs.includes('error')) return 'pending';   // jokin yritys vielä kesken (asiakas ei ole vielä hyväksynyt) → odotetaan
  if (rs.every((x) => x === 'not_authorized')) return 'failed';
  if (rs.some((x) => x === 'capture_failed' || x === 'amount_mismatch')) return 'contact';
  return 'pending';
}


// Paluutilan kysely. deps: { reconcile(): Promise<{ok,payment_status,results,code}>, getOrder(): Promise<{ok,payment_status}|{ok:false}>, sleep(ms), now(): number, onTick?(info) }
// Palauttaa { state, order }: state = paid | review | failed | slot_lost | contact | none | wait (aikakatkaisu, vielä kesken) | net (yhtään kyselyä ei onnistunut)
export async function pollPayment(deps, { intervalMs = POLL_INTERVAL_MS, maxMs = POLL_MAX_MS, reconcileEvery = RECONCILE_EVERY } = {}) {
  const t0 = deps.now();
  let answered = 0, i = 0, lastOrder = null;
  for (;;) {
    let state = null;
    // reconcile heti ensimmäisellä kierroksella ja sen jälkeen joka N. kierros (Vippsin kysely; rate_limited/mobilepay_off = palvelin vastasi, ohitetaan)
    if (i % reconcileEvery === 0) {
      try {
        const r = await deps.reconcile();
        if (r && r.ok !== false) { answered++; state = classifyResults(r.results); if (r.payment_status === 'paid' && state !== 'review') state = 'paid'; }
        else if (r?.code && !/^(network|timeout|bad_response|http_)/.test(r.code)) answered++;   // palvelin vastasi (esim. rate_limited): ei laske verkkovirheeksi
      } catch { /* verkkovirhe: jatketaan get_order-kyselyyn */ }
    }
    // public_get_order: totuus maksutilasta (webhook voi olla ehtinyt ennen reconcilea); ei tarvita jos reconcile jo kertoi lopputuloksen
    if (state == null || state === 'pending' || state === 'none' || state === 'failed') {
      try {
        const o = await deps.getOrder();
        if (o && o.ok !== false) { answered++; lastOrder = o; if (o.payment_status === 'paid') state = 'paid'; }
      } catch { /* verkkovirhe */ }
    }
    if (state && state !== 'pending') return { state, order: lastOrder };
    i++;
    deps.onTick?.({ i, elapsed: deps.now() - t0 });
    if (deps.now() - t0 + intervalMs > maxMs) return { state: answered ? 'wait' : 'net', order: lastOrder };
    await deps.sleep(intervalMs);
  }
}
