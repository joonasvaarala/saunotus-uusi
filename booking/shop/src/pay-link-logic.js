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
  order_not_payable: 'not_payable', online_off: 'off', vismapay_off: 'off', vismapay_live_not_implemented: 'off', not_configured: 'off',
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

// ---- booking_177b: yhteenveto ennen maksua (RPC public_payment_link_info) ----
const STATUSES = new Set(['open', 'paid', 'expired', 'replaced', 'not_payable', 'not_found']);
const num = (v) => (v == null || v === '' || !Number.isFinite(+v) ? null : +v);
const ymd = (v) => (/^\d{4}-\d{2}-\d{2}$/.test(String(v || '')) ? String(v) : null);
const hm = (v) => (/^\d{2}:\d{2}$/.test(String(v || '')) ? String(v) : null);

/** RPC-vastaus → sivun malli. null = ei käyttökelpoista tietoa (RPC puuttuu / verkko / nopeusraja) → sivu toimii kuten ennen (yleinen kortti + painike). */
export function normLinkInfo(r) {
  if (!r || typeof r !== 'object' || r.ok !== true || !STATUSES.has(r.status)) return null;
  const items = Array.isArray(r.items) ? r.items.filter((i) => i && typeof i === 'object' && String(i.name || '').trim()).map((i) => ({
    kind: String(i.kind || ''), name: String(i.name), name_en: i.name_en ? String(i.name_en) : null, quantity: num(i.quantity) ?? 1,
    date: ymd(i.date), start: hm(i.start), end: hm(i.end), end_date: ymd(i.end_date),
  })) : [];
  return { status: r.status, reason: String(r.reason || r.status), can_pay: r.status === 'open' && r.can_pay !== false,
    amount: num(r.amount), currency: String(r.currency || 'EUR'), order_no: r.order_no ?? null,
    expires_date: ymd(r.expires_date), expires_time: hm(r.expires_time), items,
    // booking_178: peruttu / keskeytynyt yritys ei kuluta linkkiä → status open + last_attempt (cancelled | failed), muuten null
    last_attempt: r.status === 'open' && (r.last_attempt === 'cancelled' || r.last_attempt === 'failed') ? r.last_attempt : null };
}

const INFO_MSG = {
  link_paid: 'info.paid', order_paid: 'info.order_paid', link_expired: 'info.expired', payment_cancelled: 'info.cancelled', payment_not_pending: 'info.expired',
  replaced: 'info.replaced', link_stale: 'info.stale', other_provider_started: 'err.other', order_not_payable: 'err.not_payable', online_off: 'err.off', vismapay_off: 'err.off', not_found: 'err.not_found',
};
const STATUS_MSG = { paid: 'info.paid', expired: 'info.expired', replaced: 'info.replaced', not_payable: 'err.not_payable', not_found: 'err.not_found' };

/** Mallin tila → { pay: näytetäänkö painike, msgKey: tilaviesti (null kun avoin), amountKey: summan otsikko, showSummary, validKey, retryKey: uusintaviesti (booking_178) }. */
export function linkInfoView(info) {
  if (!info) return { pay: true, msgKey: null, amountKey: null, showSummary: false, validKey: null, retryKey: null };
  if (info.status === 'open') return { pay: true, msgKey: null, amountKey: 'sum.due', showSummary: true, validKey: info.expires_date ? 'sum.valid' : null,
    retryKey: info.last_attempt ? 'info.retry' : null };
  const msgKey = INFO_MSG[info.reason] || STATUS_MSG[info.status] || 'err.generic';
  return { pay: false, msgKey, amountKey: info.status === 'paid' && info.reason === 'link_paid' ? 'sum.paid' : 'sum.link', showSummary: info.status !== 'not_found' && info.amount != null,
    validKey: info.reason === 'link_expired' && info.expires_date ? 'sum.expiredAt' : null, retryKey: null };
}

/** 2026-12-04 → FI "pe 4.12.2026", EN "Fri 4 Dec 2026" (päivämäärä on jo Helsingin aikaa; ei aikavyöhykemuunnosta). */
export function fmtDate(L, d) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(d || ''));
  if (!m) return '';
  const dt = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], 12));
  try {
    const wd = new Intl.DateTimeFormat(L === 'en' ? 'en-GB' : 'fi-FI', { weekday: 'short', timeZone: 'UTC' }).format(dt).replace(/\.$/, '');
    return L === 'en' ? `${wd} ${+m[3]} ${new Intl.DateTimeFormat('en-GB', { month: 'short', timeZone: 'UTC' }).format(dt)} ${m[1]}` : `${wd} ${+m[3]}.${+m[2]}.${m[1]}`;
  } catch { return L === 'en' ? `${+m[3]}/${+m[2]}/${m[1]}` : `${+m[3]}.${+m[2]}.${m[1]}`; }
}
