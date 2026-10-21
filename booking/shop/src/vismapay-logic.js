// Visma Pay -painikkeen näyttö. Testitila näytetään myös ilman MobilePayn testikäyttöliittymää, jotta testikortilla voi maksaa.
export function normVisma(r) {
  if (!r || r.ok === false) return { ok: false, method: null, canPay: false };
  const method = (Array.isArray(r.methods) ? r.methods : []).find((m) => m && m.code === 'visma_pay') || null;
  return { ok: true, method, canPay: !!(method && r.order && r.order.can_pay_online === true), unpaid: r.order?.unpaid ?? null };
}

export function shouldShowVisma(opts) {
  const o = opts && typeof opts === 'object' && 'canPay' in opts ? opts : normVisma(opts);
  return !!(o.ok && o.method && o.canPay);
}

/** Vain Visma Payn oma maksusivu. Muu osoite hylätään. */
export function safeVismaRedirect(url) {
  let u;
  try { u = new URL(String(url)); } catch { return null; }
  if (u.protocol !== 'https:' || u.hostname !== 'www.vismapay.com') return null;
  if (!u.pathname.startsWith('/pbwapi/token/')) return null;
  return u.href;
}

export function classifyVisma(r) {
  if (!r || r.ok === false) return r?.code === 'rate_limited' ? 'wait' : 'net';
  const outcomes = Array.isArray(r.results) ? r.results.map((x) => x?.outcome).filter(Boolean) : [];
  if (r.payment_status === 'paid' || outcomes.includes('paid')) return 'paid';
  if (outcomes.includes('needs_review')) return 'review';
  if (outcomes.includes('failed') || outcomes.includes('cancelled')) return 'failed';
  if (outcomes.includes('pending') || outcomes.includes('authorized')) return 'wait';
  if (!outcomes.length) return 'none';
  return 'wait';
}
