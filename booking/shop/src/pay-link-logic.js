// Maksulinkkisivun logiikka (ei DOM:ia): tokenin luku osoitteesta ja vismapay-start-vastauksen luokittelu.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** ?p=<link_token> (uuid). Muu → null. */
export function linkTokenFrom(search) {
  const p = new URLSearchParams(String(search || '')).get('p');
  const v = p ? p.trim() : '';
  return UUID.test(v) ? v.toLowerCase() : null;
}

const MAP = {
  invalid_param: 'invalid', not_found: 'not_found', link_expired: 'expired', payment_not_pending: 'expired',
  link_stale: 'stale', nothing_to_pay: 'stale', already_paid: 'paid', other_provider_started: 'other',
  order_not_payable: 'not_payable', vismapay_off: 'off', vismapay_live_not_implemented: 'off', not_configured: 'off',
  maintenance: 'off', unsupported_currency: 'not_payable', payment_in_progress: 'busy', rate_limited: 'rate',
  provider_error: 'provider', internal_error: 'provider', network: 'network', timeout: 'network',
};
// Lopulliset tilat: painike piiloon (uusi yritys ei auta).
const FINAL = new Set(['invalid', 'not_found', 'expired', 'stale', 'paid', 'other', 'not_payable']);

/** vismapay-start-virhekoodi → tekstiavaimen loppu (err.<x>) ja onko tila lopullinen. */
export function classifyLinkError(code) {
  const c = String(code || '');
  const k = MAP[c] || (/^http_5\d\d$/.test(c) ? 'provider' : 'generic');
  return { key: `err.${k}`, final: FINAL.has(k) };
}

/** Kielivalinnan linkki toiselle kielelle säilyttää ?p=. */
export function switchHref(otherPath, search) {
  const t = linkTokenFrom(search);
  return t ? `${otherPath}?p=${t}` : otherPath;
}
