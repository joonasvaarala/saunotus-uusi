// HALL-LASKUT-01 (UX-analyysi #345): "Lasku tilauksesta" kysyy tilausnumeroa (order_no), mutta
// admin_create_invoice_from_order(p_order_id) hakee sisäisellä tunnisteella (orders.id). PRODissa id:t ja tilausnumerot
// menevät päällekkäin, joten suora numero saattoi luoda laskun VÄÄRÄLLE tilaukselle. Tilausnumero muunnetaan nyt
// tunnisteeksi (admin_order_lookup, booking_278), tilaus haetaan (admin_get_order) ja asiakas + summa näytetään
// vahvistettavaksi ennen luontia. Tietokantafunktio pysyy ennallaan: muut kutsujat (Uusi varaus, Koulutukset) antavat jo order_id:n.

export function parseOrderNo(raw) {
  const s = String(raw ?? '').trim().replace(/^#/, '');
  if (!/^\d{1,12}$/.test(s)) return null;
  const n = Number(s);
  return Number.isSafeInteger(n) && n > 0 ? n : null;
}

function codeOf(e) {
  return e?.code || e?.details?.code || (/not_found/.test(e?.message || '') ? 'not_found' : null);
}

/** Tilausnumero → { orderId, orderNo, customer, company, total, status, invoice }. Virhe: Error.code invalid_order_no | not_found | mismatch. */
export async function resolveOrderForInvoice(rpc, raw) {
  const orderNo = parseOrderNo(raw);
  if (!orderNo) { const e = new Error('invalid_order_no'); e.code = 'invalid_order_no'; throw e; }
  let hit;
  try { hit = await rpc('admin_order_lookup', { p_order_no: orderNo }); }
  catch (e) { if (codeOf(e) === 'not_found') { const nf = new Error('not_found'); nf.code = 'not_found'; throw nf; } throw e; }
  const orderId = Number(hit?.order_id);
  if (!orderId || Number(hit?.order_no) !== orderNo) { const nf = new Error('not_found'); nf.code = 'not_found'; throw nf; }
  const o = await rpc('admin_get_order', { p_order_id: orderId });
  // Varmistus: haettu tilaus on juuri se, jonka numero kirjoitettiin.
  if (Number(o?.order_id) !== orderId || Number(o?.order_no) !== orderNo) { const e = new Error('mismatch'); e.code = 'mismatch'; throw e; }
  const c = o.customer || {};
  return {
    orderId, orderNo,
    customer: c.name || '', company: c.company || o.billing?.company || '', email: c.email || '',
    total: Number(o.total) || 0, status: o.status || '', invoice: o.invoice || null,
  };
}

/** Vahvistusrivi: "Tilaus 15123 · Yritys Oy · Matti Meikäläinen · 256,00 €". */
export function orderSummaryLine(o, money) {
  const who = [o.company, o.customer].filter(Boolean).filter((x, i, a) => a.indexOf(x) === i);
  return [`#${o.orderNo}`, ...who, money(o.total)].join(' · ');
}
