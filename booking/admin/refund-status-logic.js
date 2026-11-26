// Hyvitysten seuranta › "Tarkista tila Montoniosta". Puhdas logiikka (node --test ilman DOM:ia).
// VAIN LUKU: kutsuu ainoastaan montonio-refund {action:'status', refund_id}. Ei hyvitystä, claimia eikä kantamuutosta.
const P = 'ui.admin.refund_watch.status_check.';
const KNOWN = new Set(['off', 'not_configured', 'not_found', 'forbidden', 'montonio_missing', 'no_provider_refund_id', 'no_order_uuid', 'retry_later', 'provider_error']);

/** Nappi näytetään Montonio-hyvitykselle, joka on jonossa tai käsittelyssä. */
export function canCheckStatus(row) {
  return !!row && row.provider === 'montonio' && (row.status === 'requested' || row.status === 'processing') && Number.isInteger(+row.refund_id) && +row.refund_id > 0;
}

/** Ainoa Edge-kutsu: montonio-refund, runko täsmälleen { action: 'status', refund_id }. Virhe palautetaan tuloksena, ei heitetä. */
export async function checkRefundStatus(fn, refundId) {
  try {
    return await fn('montonio-refund', { action: 'status', refund_id: Number(refundId) });
  } catch (e) {
    const status = e?.status;
    const code = e?.code || (status === 401 || status === 403 ? 'forbidden' : status === 404 ? 'not_found' : 'error');
    return { ok: false, code: String(code), message: e?.message || '' };
  }
}

/** Vastaus → näytettävät osat: { local: [[avain, arvo]], montonio: [[avain, arvo]] | null, notes: [avain tai {key, vars}] }. */
export function statusCheckView(res, { money = (n) => String(n), date = (d) => String(d) } = {}) {
  const out = { local: null, montonio: null, notes: [] };
  const note = (code, message) => out.notes.push(KNOWN.has(code) ? { key: P + code } : { key: P + 'error', vars: { error: message || code || '?' } });
  if (!res || res.ok === false) { note(res?.code || 'error', res?.message); return out; }
  const l = res.local;
  if (l) out.local = [[P + 'status', l.status ?? '–'], [P + 'provider_status', l.provider_status ?? '–'], [P + 'amount', l.amount != null ? money(l.amount) : '–']];
  if (res.code) note(res.code);
  const m = res.montonio;
  if (m && m.ok === false) note(m.code);
  else if (m && m.ok) {
    if (m.refund) out.montonio = [[P + 'status', m.refund.status ?? '–'], [P + 'amount', m.refund.amount != null ? money(m.refund.amount) : '–'], [P + 'created', m.refund.createdAt ? date(m.refund.createdAt) : '–']];
    else note('montonio_missing');
    if (m.order?.paymentStatus) (out.montonio ||= []).push([P + 'order_status', m.order.paymentStatus]);
  }
  return out;
}
