// Tilausnäkymä v3 (PR 1): yhteenvetopaneelin, koko tilausnäkymän, mobiilin alapalkin ja asiakasnäkymän puhdas logiikka.
// Ei DOM- eikä verkkoriippuvuuksia. Syöte = admin_get_order (raaka, booking_278:n lisäkentät valinnaisia) ja admin_get_customer.
// Palvelin päättää oikeudet ja lukot: tämä tiedosto vain piilottaa sen, mitä palvelin ei salli, ja kertoo syyn.
// Määrittely: /tilausnakyma-luonnos/v3/toteutusmaarittely.md §1–§3 (Joonas t38u–t42u, 11.11.2026).
import { orderInvoiceLocked } from './addon-lock-logic.js';
import { moveTarget, addonsEditable } from './reservation-dialog-logic.js';

const EPS = 0.005;
const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const round2 = (v) => Math.round((num(v) + Number.EPSILON) * 100) / 100;
const ACTIVE = ['pending', 'confirmed'];

/** Helsingin kalenteripäivä (YYYY-MM-DD) tai null. */
export function helDay(value) {
  if (value == null || value === '') return null;
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki', year: 'numeric', month: '2-digit', day: '2-digit' });
}

/** Varauksen ajoitus suhteessa nykyhetkeen: 'today' | 'future' | 'past'. */
export function reservationWhen(r, now = new Date()) {
  const day = helDay(r?.starts_at), today = helDay(now);
  if (!day || !today) return 'past';
  if (day === today) return 'today';
  return day > today ? 'future' : 'past';
}

/** Saapunut-toiminto vain varauspäivänä ja vain vahvistetulle varaukselle (t40u). Tuleville ei mitään saapumiseen liittyvää. */
export function canMarkArrived(r, now = new Date()) {
  return r?.status === 'confirmed' && reservationWhen(r, now) === 'today';
}

const isGiftPayment = (p) => p?.method === 'gift_card' || p?.gift_card_id != null;
const isPartnerPayment = (p) => String(p?.method || '').startsWith('partner_voucher');
const isPaidStatus = (s) => ['paid', 'partially_refunded', 'refunded'].includes(s);

/** Maksurivin laji näkymää varten. */
export function paymentKind(p) {
  if (isGiftPayment(p)) return 'gift_card';
  if (isPartnerPayment(p)) return 'partner';
  if (p?.method === 'annual_card') return 'annual_card';
  if (p?.method === 'invoice') return 'invoice';
  if (p?.status === 'pending' && p?.provider && p.provider !== 'manual') return 'link';
  if (p?.provider && p.provider !== 'manual') return 'online';
  return 'manual';
}

/**
 * Yhdistää admin_get_order-vastauksen ja booking_278:n reservation_meta-kentät yhdeksi malliksi.
 * Varaukset saavat järjestysnumeron (i/N) aikajärjestyksessä; piilotetut eivät tule palvelimelta.
 */
export function orderModel(raw) {
  if (!raw) return null;
  const meta = new Map((raw.reservation_meta || []).map((m) => [String(m.id), m]));
  const reservations = (raw.reservations || []).map((x) => ({ ...x, reservation_id: x.id ?? x.reservation_id }))
    .sort((a, b) => String(a.starts_at || '').localeCompare(String(b.starts_at || '')))
    .map((x, i, all) => ({ ...meta.get(String(x.reservation_id)) || {}, ...x, id: x.reservation_id, index: i + 1, count: all.length }));
  const b = raw.balance || {};
  const total = num(b.total ?? raw.total);
  const netPaid = b.net_paid != null ? num(b.net_paid) : round2(num(b.paid) - num(b.refunded));
  const cancelledOrder = ['cancelled', 'expired', 'draft'].includes(raw.status);
  const overpaid = raw.overpaid != null ? num(raw.overpaid) : Math.max(0, round2(netPaid - (cancelledOrder ? 0 : total)));
  const invoice = raw.invoice || (raw.invoice_no ? { invoice_no: raw.invoice_no, status: null, due_date: null, sent_at: null } : null);
  return {
    raw,
    order_id: raw.order_id, order_no: raw.order_no, status: raw.status, payment_status: raw.payment_status,
    created_at: raw.created_at, source_channel: raw.source_channel || '', locale: raw.locale || null,
    is_native: raw.is_native !== false, customer: raw.customer || {}, customer_kind: raw.customer_kind || raw.customer?.customer_kind || null,
    billing: raw.billing || null, customer_note: raw.customer_note || '', internal_note: raw.internal_note || '',
    reservations, active: reservations.filter((r) => ACTIVE.includes(r.status)),
    items: raw.items || [], payments: raw.payments || [], receipts: raw.receipts || [], refunds: raw.refunds || [],
    emails: raw.emails || [], requests: raw.requests || [], voucher_claims: raw.voucher_claims || [],
    refundable_by_payment: Array.isArray(raw.refundable_by_payment) ? raw.refundable_by_payment : null,
    locked: orderInvoiceLocked(raw), invoice,
    balance: { total, paid: num(b.paid), refunded: num(b.refunded), pending_link: num(b.pending_link), unpaid: num(b.unpaid), net_paid: netPaid },
    open: num(b.unpaid), overpaid,
    staff_can_add: !!raw.staff_can_add, public_token: raw.public_token || null, order_page_path: raw.order_page_path || null,
  };
}

/** Tilauksen ongelmat (kortin "Ongelma"-merkki): kumppanikoodi jo käytetty tai muu ongelmatila (PR #333). */
export function orderProblems(m) {
  return (m?.voucher_claims || []).filter((v) => v.status === 'problem' || v.problem_code)
    .map((v) => ({ id: v.id, code: v.problem_code || 'other', source: v.source || null, masked: v.code_masked || '', reservation_id: v.reservation_id ?? null }));
}

/** Maksun tila yhdellä sanalla merkkiä varten. */
export function paymentState(m) {
  if (!m) return 'unknown';
  if (m.overpaid > EPS) return 'overpaid';
  if (m.open > EPS) {
    if (m.locked) return 'invoiced';
    return m.balance.net_paid > EPS ? 'partial' : 'unpaid';
  }
  if (m.locked) return 'invoiced';
  if (m.balance.refunded > EPS && m.balance.paid - m.balance.refunded <= EPS) return 'refunded';
  return m.balance.total > EPS || m.balance.paid > EPS ? 'paid' : 'none';
}

/** Tilauksen varaustila otsikon merkkiin: yhden varauksen tila, monivarauksessa vallitseva voimassa oleva tila. */
export function orderReservationState(m) {
  const rs = m?.reservations || [];
  if (!rs.length) return m?.status || null;
  if (rs.some((r) => r.status === 'pending')) return 'pending';
  if (rs.some((r) => r.status === 'confirmed')) return 'confirmed';
  if (rs.every((r) => r.status === 'cancelled')) return 'cancelled';
  if (rs.some((r) => r.status === 'completed')) return 'completed';
  return rs[0].status;
}

/** Otsikon merkit: [{kind, key, vars}] – avain = ui.admin.order_view.badge.* tai varauksen tila. */
export function orderBadges(m) {
  if (!m) return [];
  const out = [];
  const rs = orderReservationState(m);
  if (rs) out.push({ kind: `st-${rs}`, key: `status.${rs}` });
  const ps = paymentState(m);
  if (ps === 'unpaid' || ps === 'partial') out.push({ kind: 'err', key: ps === 'partial' ? 'pay.partial' : 'pay.unpaid', vars: { amount: m.open } });
  else if (ps === 'invoiced') out.push({ kind: 'pay-invoiced', key: 'pay.invoiced', vars: { no: m.invoice?.invoice_no || '' } });
  else if (ps === 'overpaid') out.push({ kind: 'warn', key: 'pay.overpaid', vars: { amount: m.overpaid } });
  else if (ps === 'refunded') out.push({ kind: 'pay-refunded', key: 'pay.refunded' });
  else if (ps === 'paid') out.push({ kind: 'ok', key: 'pay.paid' });
  if (m.reservations.some((r) => r.status === 'no_show')) out.push({ kind: 'st-no_show', key: 'status.no_show' });
  for (const p of orderProblems(m)) out.push({ kind: 'err strong', key: `problem.${p.code}`, problem: true });
  return out;
}

const can0 = () => false;
const canFn = (can) => (typeof can === 'function' ? can : can0);

/**
 * Varausrivin toiminnot (§2). Palauttaa avaimet: confirm, arrive, change, option, addons, move, cancel.
 * Ei-saapunut ei ole koskaan toiminto (vain tilamerkki), eikä tulevalle varaukselle näytetä saapumiseen liittyvää.
 */
export function reservationRowActions(r, m, { can = can0, now = new Date() } = {}) {
  const c = canFn(can);
  const booking = !!c('bookings.manage');
  const when = reservationWhen(r, now);
  const live = ACTIVE.includes(r?.status) && when !== 'past';
  const out = [];
  if (booking && r?.status === 'pending' && when !== 'past') out.push('confirm');
  if (booking && canMarkArrived(r, now)) out.push('arrive');
  if (booking && live && m?.is_native !== false) out.push('change');
  if (booking && live && ((r.option_choices || []).length > 0)) out.push('option');
  if (booking && live && !m?.locked && m?.is_native !== false && ((r.addons || []).length ? addonsEditable(m?.raw, r.id) || !!m?.staff_can_add : !!m?.staff_can_add)) out.push('addons');
  if (booking && live && moveTarget({ ...r, reservation_id: r.id }, c)) out.push('move');
  if (booking && ACTIVE.includes(r?.status)) out.push('cancel');
  return out;
}

/** Rivin tilamerkki: Saapunut, Ei saapunut (vain merkki), Peruttu, Vahvistettu, Odottaa. */
export function reservationBadge(r) {
  if (!r) return null;
  if (r.status === 'completed' || (r.checkin_at && !['cancelled', 'no_show'].includes(r.status))) return { kind: 'ok', key: 'res.arrived' };
  return { kind: `st-${r.status}`, key: `status.${r.status}` };
}

/** Lisäoston rivi on lukittu, kun tilaus on laskutettu (booking_185). */
export const addonsLocked = (m) => !!m?.locked;

/** Maksu-kortti: avoin / ylisuoritus isolla, rivit ja toimintojen piilotus laskulukossa (§2 Laskulukko). */
export function paymentBox(m, { can = can0 } = {}) {
  const c = canFn(can);
  if (!m) return null;
  const payments = (m.payments || []).map((p) => ({ ...p, kind: paymentKind(p) }));
  const openLink = payments.filter((p) => p.kind === 'link' && p.link_path).sort((a, b) => num(b.id) - num(a.id))[0] || null;
  const linkEmail = (m.emails || []).filter((e) => e.kind === 'payment_link' || e.kind === 'payment_link_reminder').sort((a, b) => String(b.sent_at || b.created_at || '').localeCompare(String(a.sent_at || a.created_at || '')))[0] || null;
  const payments_manage = !!c('payments.manage'), refund = !!c('payments.refund');
  const refundable = m.refundable_by_payment != null
    ? m.refundable_by_payment.filter((x) => num(x.refundable) > EPS)
    : payments.filter((p) => ['paid', 'partially_refunded'].includes(p.status) && !['gift_card', 'partner', 'annual_card', 'invoice'].includes(p.kind) && num(p.amount) - num(p.refunded_amount) > EPS)
      .map((p) => ({ payment_id: p.id, method: p.method, provider: p.provider, refundable: round2(num(p.amount) - num(p.refunded_amount)) }));
  const locked = !!m.locked, native = m.is_native !== false;
  return {
    headline: m.overpaid > EPS ? 'overpaid' : (locked && m.open > EPS ? 'invoice_open' : (m.open > EPS ? 'open' : 'settled')),
    amount: m.overpaid > EPS ? m.overpaid : m.open,
    total: m.balance.total, paid: m.balance.paid, refunded: m.balance.refunded, pending_link: m.balance.pending_link,
    payments,
    openLink, linkSentAt: linkEmail?.sent_at || null,
    invoice: m.invoice, locked,
    voucherUnused: 0,
    actions: {
      sendLink: !locked && native && payments_manage && m.open > EPS,
      takePayment: !locked && native && payments_manage && m.open > EPS,
      copyLink: !locked && payments_manage && !!openLink,
      refund: !locked && refund && refundable.length > 0,
      openBilling: locked,
    },
    refundable,
    giftCard: payments.filter((p) => p.kind === 'gift_card' && isPaidStatus(p.status)).reduce((s, p) => s + num(p.amount) - num(p.refunded_amount), 0),
    partner: payments.filter((p) => p.kind === 'partner' && isPaidStatus(p.status)).reduce((s, p) => s + num(p.amount) - num(p.refunded_amount), 0),
  };
}

/** Ensimmäinen tuleva tai tämän päivän voimassa oleva varaus (seuraava askel, yhteenveto). */
export function nextReservation(m, now = new Date()) {
  const today = helDay(now);
  const live = (m?.reservations || []).filter((r) => ACTIVE.includes(r.status) && (helDay(r.starts_at) || '') >= today);
  return live[0] || null;
}

/**
 * "Seuraava askel" -palkki: laskulukko > ongelma > tänään saapuu > maksu puuttuu > ylisuoritus > ei mitään.
 */
export function nextStep(m, { now = new Date() } = {}) {
  if (!m) return null;
  if (m.locked) return { kind: 'invoice_locked', invoice: m.invoice };
  const problems = orderProblems(m);
  if (problems.length) return { kind: 'problem', problem: problems[0] };
  const next = nextReservation(m, now);
  const today = (m.reservations || []).find((r) => canMarkArrived(r, now));
  if (today) return { kind: 'today', reservation: today, open: m.open };
  if (m.open > EPS && m.is_native) return { kind: 'pay_missing', amount: m.open, reservation: next };
  if (m.overpaid > EPS) return { kind: 'overpaid', amount: m.overpaid };
  return null;
}

/**
 * Tilan mukaiset päätoiminnot (yhteenveto 2 kpl, mobiilin alapalkki 1–2 kpl, koko näkymän seuraava askel):
 * varauspäivänä Saapunut + Ota maksu; tulevalle Lähetä maksulinkki + Ota maksu; laskulukossa Avaa Laskutuksessa.
 */
export function primaryActions(m, { can = can0, now = new Date(), limit = 2 } = {}) {
  if (!m) return [];
  const c = canFn(can);
  const box = paymentBox(m, { can: c });
  const out = [];
  const today = (m.reservations || []).find((r) => canMarkArrived(r, now));
  if (today && c('bookings.manage')) out.push({ key: 'arrive', reservation_id: today.id });
  if (m.locked) out.push({ key: 'openBilling' });
  else if (box.actions.takePayment || box.actions.sendLink) {
    if (today) {
      if (box.actions.takePayment) out.push({ key: 'takePayment', amount: m.open });
    } else {
      if (box.actions.sendLink) out.push({ key: box.openLink || box.linkSentAt ? 'resendLink' : 'sendLink', amount: m.open });
      if (box.actions.takePayment) out.push({ key: 'takePayment', amount: m.open });
    }
  }
  return out.slice(0, Math.max(0, limit));
}

/** ⋯-valikko: kuitti (näytä / lähetä uudelleen), Kopioi maksulinkki, Hyvitys, Lisäosto, Avaa asiakas. */
export function moreMenu(m, { can = can0 } = {}) {
  if (!m) return [];
  const c = canFn(can);
  const box = paymentBox(m, { can: c });
  const out = [];
  const receipts = (m.receipts || []).filter((x) => x.kind === 'receipt' || x.kind === 'refund_receipt' || !x.kind);
  if (receipts.length) out.push({ key: 'receipt', receipt_id: receipts[receipts.length - 1].id });
  if (box.actions.copyLink) out.push({ key: 'copyLink', link_path: box.openLink.link_path });
  if (box.actions.refund) out.push({ key: 'refund' });
  if (!m.locked && m.staff_can_add && c('bookings.manage') && m.is_native) out.push({ key: 'addPurchase' });
  if (m.customer?.id) out.push({ key: 'openCustomer', customer_id: m.customer.id });
  return out;
}

/**
 * Muistiinpanot (t41u/4): varauskohtaiset (reservations.notes), mutta aina näkyvissä tilauksessa otsikolla
 * "Varaus i/N · tuote · pvm". Lisäksi asiakkaan lisätiedot (customer_note) ja järjestelmähuomautukset (internal_note, vain luku).
 */
export function collectNotes(m, { can = can0 } = {}) {
  if (!m) return { reservations: [], customer_note: '', system_note: '', first: null };
  const editable = !!canFn(can)('bookings.manage');
  const reservations = (m.reservations || []).map((r) => ({
    reservation_id: r.id, index: r.index, count: r.count, product_name: r.product_name || '', starts_at: r.starts_at || null,
    status: r.status, notes: String(r.notes || '').trim(), editable: editable && r.status !== 'expired',
  }));
  const first = reservations.find((x) => x.notes) || null;
  return { reservations, customer_note: String(m.customer_note || '').trim(), system_note: String(m.internal_note || '').trim(), first };
}

/** Lyhennys yhteenvetoon. */
export function shorten(text, max = 140) {
  const s = String(text || '').replace(/\s+/g, ' ').trim();
  return s.length > max ? `${s.slice(0, max - 1).trimEnd()}…` : s;
}

const EMAIL_KINDS = ['order_confirmation', 'order_change', 'payment_link', 'payment_link_reminder', 'receipt', 'refund_receipt',
  'unpaid_booking_cancelled', 'invoice_pdf', 'voucher_claim_received'];

/**
 * Aikajana nykydatasta (§1.3 "Viestit ja maksutapahtumat"): tilaus luotu, viestit (emails[]), maksut ja maksulinkit,
 * hyvitykset, kuitit, lasku, kumppanikoodin ongelma sekä booking_278:n muutoshistoria (jos haettu). Vanhin ensin.
 * Palauttaa [{at, key, vars, kind, source}]; teksti avaimesta ui.admin.order_view.tl.*.
 */
export function buildTimeline(m, history = null) {
  if (!m) return [];
  const ev = [];
  const add = (at, key, vars = {}, kind = 'info', source = 'order') => { if (at) ev.push({ at, key, vars, kind, source }); };
  add(m.created_at, m.source_channel === 'web' || m.source_channel === 'verkkokauppa' ? 'created_web' : 'created_staff', { n: m.reservations.length });
  for (const e of m.emails || []) {
    const kind = EMAIL_KINDS.includes(e.kind) ? e.kind : 'other';
    if (e.status === 'sent' || e.sent_at) add(e.sent_at || e.created_at, `email.${kind}`, {}, 'mail', 'emails');
    else if (e.status === 'failed' || e.status === 'dead') add(e.created_at, 'email_failed', { kind }, 'err', 'emails');
    else add(e.created_at, 'email_queued', { kind }, 'muted', 'emails');
  }
  for (const p of m.payments || []) {
    const k = paymentKind(p);
    if (k === 'link') add(p.created_at, 'link_created', { amount: p.amount }, 'info', 'payments');
    else if (isPaidStatus(p.status)) add(p.paid_at || p.created_at, `paid.${k}`, { amount: p.amount, method: p.method }, 'ok', 'payments');
    else if (p.status === 'failed') add(p.created_at, 'pay_failed', { amount: p.amount }, 'err', 'payments');
    for (const f of p.refunds || []) add(f.done_at || f.created_at, f.status === 'done' ? 'refund_done' : (f.status === 'failed' ? 'refund_failed' : 'refund_pending'), { amount: f.amount }, f.status === 'failed' ? 'err' : 'warn', 'refunds');
  }
  for (const r of m.receipts || []) add(r.issued_at, r.kind === 'refund_receipt' ? 'refund_receipt' : 'receipt', { no: r.receipt_no || '' }, 'muted', 'receipts');
  if (m.invoice?.sent_at) add(m.invoice.sent_at, 'invoice_sent', { no: m.invoice.invoice_no || '' }, 'info', 'invoice');
  for (const r of m.reservations || []) {
    if (r.checkin_at) add(r.checkin_at, 'arrived', { i: r.index, n: r.count }, 'ok', 'reservations');
    if (r.cancelled_at) add(r.cancelled_at, 'res_cancelled', { i: r.index, n: r.count }, 'warn', 'reservations');
  }
  for (const h of history?.events || []) {
    if (h.action === 'INSERT') continue;   // luonti näkyy jo omana rivinään
    const status = (h.changes || []).find((x) => x.field === 'status' && x.to != null);
    const fields = (h.changes || []).map((x) => x.field);
    if (status) add(h.at, 'h_status', { table: h.table, from: status.from, to: status.to, who: h.actor_name || '' }, 'muted', 'history');
    else if (h.action !== 'UPDATE') add(h.at, 'h_action', { action: h.action, table: h.table, who: h.actor_name || '' }, 'muted', 'history');
    else if (fields.length) add(h.at, 'h_fields', { table: h.table, fields: fields.join(', '), who: h.actor_name || '' }, 'muted', 'history');
  }
  // vakaa järjestys: aika, sitten lisäysjärjestys
  return ev.map((x, i) => ({ ...x, i })).sort((a, b) => (String(a.at).localeCompare(String(b.at))) || a.i - b.i).map(({ i, ...x }) => x);
}

/**
 * Peruutusdialogin malli (§3.1, PR 1): sama vaiherakenne 1 Mitä → 2 Hyvitys → 3 Viesti → 4 Vahvistus. Nykyiset RPC:t:
 *  - yksi varaus: admin_cancel_reservation(p_refund true = varauksen koko osuus | false). Osasumma piilossa (PR 3).
 *  - koko tilaus: ilman hyvitystä peräkkäiset admin_cancel_reservation-kutsut; hyvityksellä admin_refund_order
 *    (p_cancel_reservations) vain, kun hyvitettävä maksu on tasan yksi (atominen). Muuten "Älä hyvitä" ja ohje Hyvitys-toimintoon.
 *  - viestivaihe piilotetaan (henkilökunnan peruutusviesti tulee PR 2:ssa) ja sen numero näytetään yliviivattuna.
 */
export function cancelPlan(m, { reservationId = null, scope = null, can = can0, preview = null } = {}) {
  const c = canFn(can);
  const active = (m?.active || []);
  const target = active.find((r) => String(r.id) === String(reservationId)) || (active.length === 1 ? active[0] : null);
  const multi = active.length > 1;
  const chosen = scope || (multi ? (target ? 'one' : null) : 'one');
  const box = paymentBox(m, { can: c });
  const canRefund = !!c('payments.refund');
  let refund = { show: false, reason: null, options: [], amount: 0 };
  if (m?.locked) refund = { show: false, reason: 'invoice_locked', options: [], amount: 0 };
  else if (!canRefund) refund = { show: false, reason: 'no_permission', options: [], amount: 0 };
  else if (chosen === 'one') {
    const share = round2(num(preview?.total));
    refund = share > EPS ? { show: true, reason: null, options: ['full', 'none'], amount: share, unallocated: num(preview?.unallocated) > EPS }
      : { show: false, reason: preview ? 'nothing' : 'preview_missing', options: [], amount: 0 };
  } else if (chosen === 'all') {
    const list = box?.refundable || [];
    // admin_refund_order hyvittää maksun koko jäljellä olevan summan: ei tarjota, jos osa tilauksesta on jo käytetty
    // (saapunut, toteutunut tai ei saapunut), ettei käytetyn varauksen osuutta hyvitetä vahingossa.
    const used = (m?.reservations || []).some((r) => ['completed', 'no_show'].includes(r.status) || (r.checkin_at && r.status !== 'cancelled'));
    if (used && list.length) refund = { show: false, reason: 'partly_used', options: [], amount: 0 };
    else if (list.length === 1) refund = { show: true, reason: null, options: ['full', 'none'], amount: round2(num(list[0].refundable)), payment_id: list[0].payment_id, provider: list[0].provider };
    else if (list.length > 1) refund = { show: false, reason: 'multi_payment', options: [], amount: 0 };
    else refund = { show: false, reason: 'nothing', options: [], amount: 0 };
  }
  const partner = box?.partner > EPS, gift = box?.giftCard > EPS;
  const steps = [
    { key: 'what', shown: true },
    { key: 'refund', shown: refund.show },
    { key: 'message', shown: false },
    { key: 'confirm', shown: true },
  ];
  const totalBefore = m?.balance?.total ?? 0;
  const shareOf = (r) => num(r?.item_total) + (r?.addons || []).reduce((s, a) => s + num(a.line_total), 0);
  const totalAfter = chosen === 'all' ? 0 : round2(totalBefore - shareOf(target));
  return {
    multi, scope: chosen, target, targets: chosen === 'all' ? active : (target ? [target] : []),
    scopeOptions: multi ? ['one', 'all'] : [], steps, refund, gift, partner,
    totalBefore, totalAfter: Math.max(0, totalAfter),
    ready: !!chosen && (chosen === 'all' || !!target),
  };
}

/** Vahvistusnapin avain: täsmälleen mitä tapahtuu. */
export function cancelConfirmKey(plan, refundChoice) {
  if (!plan) return 'confirm.cancel_only';
  const refunding = plan.refund.show && refundChoice === 'full';
  if (plan.scope === 'all') return refunding ? 'confirm.cancel_all_refund' : 'confirm.cancel_all';
  return refunding ? 'confirm.cancel_refund' : 'confirm.cancel_only';
}

/** Yhteenvetopaneelin malli (§1.1). */
export function summaryModel(m, { can = can0, now = new Date() } = {}) {
  if (!m) return null;
  const first = nextReservation(m, now) || m.reservations[0] || null;
  const notes = collectNotes(m, { can });
  const addonCount = (first?.addons || []).reduce((s, a) => s + Math.max(0, num(a.quantity)), 0);
  return {
    first, more: Math.max(0, m.reservations.length - (first ? 1 : 0)), addons: first?.addons || [], addonCount,
    badges: orderBadges(m), box: paymentBox(m, { can }), note: notes.first ? { ...notes.first, short: shorten(notes.first.notes) } : null,
    actions: primaryActions(m, { can, now, limit: 2 }),
    phone: m.customer?.phone || null, email: m.customer?.email || null,
  };
}

/** Listan näppäimistö: ↑/↓ seuraava/edellinen rivi, rajoissa. */
export function stepIndex(current, delta, length) {
  if (!length) return -1;
  if (current < 0) return delta > 0 ? 0 : length - 1;
  return Math.min(length - 1, Math.max(0, current + delta));
}

/** Työpöytä vs. mobiili: yhteenveto vain leveällä näytöllä, mobiilissa koko tilaus suoraan (t41u/1). */
export const SUMMARY_MIN_WIDTH = 1200;   // = admin.css @media(min-width:75em)
export const isWide = (width) => num(width) >= SUMMARY_MIN_WIDTH;

// ---------------- Asiakasnäkymä (§1.4) ----------------

/** Tilauksen ensimmäinen varausaika (asiakkaan tilauslistan järjestys ja tulevat/menneet-jako). */
const firstStart = (o) => (o.reservations || []).map((r) => r.starts_at).filter(Boolean).sort()[0] || null;
const lastStart = (o) => (o.reservations || []).map((r) => r.starts_at).filter(Boolean).sort().pop() || null;

export function customerModel(c, { now = new Date() } = {}) {
  if (!c) return null;
  const nowIso = (now instanceof Date ? now : new Date(now)).toISOString();
  const orders = (c.orders || []).map((o) => {
    const res = (o.reservations || []).filter((r) => r);
    const upcoming = res.some((r) => ACTIVE.includes(r.status) && String(r.starts_at || '') > nowIso);
    return { ...o, first_start: firstStart(o), last_start: lastStart(o), upcoming, no_show: res.some((r) => r.status === 'no_show'),
      product: res[0]?.product_name || '', persons: res[0]?.persons ?? null, count: res.length };
  });
  const upcoming = orders.filter((o) => o.upcoming && !['cancelled', 'expired'].includes(o.status))
    .sort((a, b) => String(a.first_start || '').localeCompare(String(b.first_start || '')));
  const past = orders.filter((o) => !upcoming.includes(o))
    .sort((a, b) => String(b.last_start || b.created_at || '').localeCompare(String(a.last_start || a.created_at || '')));
  // Palvelimen tunnusluvut (booking_278 H); vanhalla palvelimella lasketaan tilausten varauksista.
  const all = orders.flatMap((o) => o.reservations || []);
  const local = {
    visits: all.filter((r) => r.status === 'completed').length,
    last_visit: all.filter((r) => r.status === 'completed').map((r) => r.starts_at).sort().pop() || null,
    upcoming: all.filter((r) => ACTIVE.includes(r.status) && String(r.starts_at || '') > nowIso).length,
    next_at: all.filter((r) => ACTIVE.includes(r.status) && String(r.starts_at || '') > nowIso).map((r) => r.starts_at).sort()[0] || null,
    no_show: all.filter((r) => r.status === 'no_show').length,
    last_no_show: all.filter((r) => r.status === 'no_show').map((r) => r.starts_at).sort().pop() || null,
    orders: orders.length,
    first_order_at: orders.map((o) => o.created_at).filter(Boolean).sort()[0] || null,
  };
  const stats = { ...local, ...(c.stats || {}) };
  const unpaidOrders = orders.filter((o) => ['unpaid', 'partially_paid'].includes(o.payment_status) && !['cancelled', 'expired', 'draft'].includes(o.status));
  return {
    id: c.id, name: c.customer_kind === 'company' && c.company ? c.company : c.name, person: c.name, kind: c.customer_kind || 'private',
    company: c.company || null, business_id: c.business_id || null,
    email: c.email || null, phone: c.phone || null, language: c.language || null, notes: String(c.notes || '').trim(),
    consent: { given: !!c.marketing_consent, at: c.marketing_consent_at || null, source: c.marketing_consent_source || null, unsubscribed_at: c.marketing_unsubscribed_at || null },
    stats, open_balance: c.open_balance != null ? num(c.open_balance) : null, open_orders: c.open_orders != null ? num(c.open_orders) : unpaidOrders.length,
    gift_cards: c.gift_cards || null, annual_cards: c.annual_cards || [], anonymized: !!c.anonymized_at,
    upcoming, past, created_at: c.created_at || null,
  };
}

/** Asiakkaan tilausrivin merkit: Maksettu / Maksamatta / Ei saapunut / Peruttu. */
export function customerOrderBadges(o) {
  const out = [];
  if (o.status === 'cancelled') out.push({ kind: 'st-cancelled', key: 'status.cancelled' });
  else if (['unpaid', 'partially_paid'].includes(o.payment_status)) out.push({ kind: 'err', key: o.payment_status === 'partially_paid' ? 'pay.partial_short' : 'pay.unpaid_short' });
  else if (o.payment_status === 'invoiced') out.push({ kind: 'pay-invoiced', key: 'pay.invoiced_short' });
  else if (['paid', 'partially_refunded'].includes(o.payment_status)) out.push({ kind: 'ok', key: 'pay.paid' });
  else if (o.payment_status === 'refunded') out.push({ kind: 'pay-refunded', key: 'pay.refunded' });
  if (o.no_show) out.unshift({ kind: 'st-no_show', key: 'status.no_show' });
  if (o.upcoming && o.status === 'confirmed') out.unshift({ kind: 'st-confirmed', key: 'status.confirmed' });
  return out;
}

/**
 * ⋯-valikon paikka ruudulla. prefer 'end' = oikeareuna nappiin (otsikon valikko),
 * 'start' = vasen reuna nappiin (varausrivin valikko). Jos suosittu reuna ei mahdu,
 * kokeillaan toista; lopuksi rajataan 8 px marginaalilla viewportin sisään.
 */
export function placeOverflowMenu(anchor, menuSize, viewport, { margin = 8, gap = 4, prefer = 'end' } = {}) {
  const vw = Number(viewport?.width) || 0;
  const vh = Number(viewport?.height) || 0;
  const maxWidth = Math.max(0, vw - margin * 2);
  const width = Math.min(Math.max(0, Number(menuSize?.width) || 0), maxWidth);
  const height = Math.max(0, Number(menuSize?.height) || 0);
  const startLeft = Number(anchor?.left) || 0;
  const endLeft = (Number(anchor?.right) || 0) - width;
  const fits = (left) => left >= margin && left + width <= vw - margin;
  let left = prefer === 'start'
    ? (fits(startLeft) ? startLeft : (fits(endLeft) ? endLeft : startLeft))
    : (fits(endLeft) ? endLeft : (fits(startLeft) ? startLeft : endLeft));
  left = Math.max(margin, Math.min(left, vw - width - margin));
  if (!Number.isFinite(left)) left = margin;
  let top = (Number(anchor?.bottom) || 0) + gap;
  if (top + height > vh - margin) {
    const up = (Number(anchor?.top) || 0) - gap - height;
    if (up >= margin) top = up;
    else top = Math.max(margin, Math.min(top, vh - height - margin));
  }
  if (!Number.isFinite(top)) top = margin;
  return { left, top, width, maxWidth };
}
