// Talous-näkymien DATAKERROS – kaikki Talous-sivun datankäsittely kulkee tämän tiedoston kautta (näkymät eivät tunne RPC-nimiä tai p_-parametreja).
// Lopullinen sopimus: /workspace/procountor/KOODARI_talous_A_D_fi.md (v1, 17.10.2026). Nimet/parametrit/vastausmuodot: rpcBackend() ja normalisoijat alla.
//
// Mock ↔ oikea = YKSI `rpc`-funktio: createTalousApi({ rpc }) kutsuu rpcBackend(rpc):tä. Mock (talous-mock.js → createMock().rpc) vastaa samoilla RPC-nimillä,
// p_-parametreilla ja vastausrakenteilla, joten sama koodi ajaa molempia.
//   · Tila 'mock': osoitteessa ?mock=1 (kyselyosassa tai #/talous?mock=1) → kaikki data mockista.
//   · Tila 'real': kutsut menevät palvelimelle. Jos jokin RPC PUUTTUU (404 / PGRST202 / 42883; esim. raporttien vaihe D ei vielä tuotannossa), kyseinen toiminto
//     siirtyy mockiin, sivu näyttää "ominaisuus ei vielä käytössä" -ilmoituksen (api.missing) – muut toiminnot pysyvät oikeina.
//   · Kirjoittavat toiminnot (LIVE_ACTIONS): oikeassa tilassa pois päältä, kunnes tiimi kytkee ne (yksi lippu per toiminto). Mock-tilassa ne toimivat mockina.
import { createMock } from './talous-mock.js';

export const RPC = {
  listOrders: 'admin_list_orders', getOrder: 'admin_get_order', listPayments: 'admin_list_payments', listAddons: 'admin_list_addons',
  addToOrder: 'admin_add_to_order', createPaymentLink: 'admin_create_payment_link', refund: 'admin_refund',
  reportDaily: 'admin_report_daily', reportMonthly: 'admin_report_month', reportCsv: 'admin_report_csv',
};
// Kirjoittavat toiminnot oikeassa tilassa. HUOM: sopimuksen mukaan vaihe A (booking_29/30) on tuotannossa ja nämä RPC:t ovat olemassa, mutta rahaa liikuttavat
// toiminnot kytketään päälle vasta kun ne on kokeiltu hallinnan käyttöliittymästä testikannalla (ei tässä UI-kehyksessä) → false.
export const LIVE_ACTIONS = { addToOrder: false, createPaymentLink: false, refund: false };

export class FeatureNotReady extends Error {
  constructor(rpc) { super(`Ominaisuus ei vielä käytössä (${rpc})`); this.name = 'FeatureNotReady'; this.code = 'feature_not_ready'; this.rpc = rpc; }
}
export class RpcError extends Error {
  constructor(message, { code, status, details } = {}) { super(message); this.name = 'ApiError'; this.code = code; this.status = status; this.details = details; }
}
// PostgREST: puuttuva funktio = 404 + PGRST202 ("Could not find the function …"); 42883 = undefined_function
export const isMissingRpc = (e) => !!e && (e.status === 404 || e.code === 'PGRST202' || e.code === '42883' || /could not find the function/i.test(e.message || ''));
export function wantsMock(loc = typeof location !== 'undefined' ? location : null) {
  if (!loc) return false;
  const q = new URLSearchParams(loc.search || ''), hq = new URLSearchParams((loc.hash || '').split('?')[1] || '');
  return q.get('mock') === '1' || hq.get('mock') === '1';
}

const num = (v, d = 0) => (v == null || v === '' || !Number.isFinite(+v) ? d : +v);
const round2 = (n) => Math.round((+n + Number.EPSILON) * 100) / 100;
const vatOf = (gross, rate) => round2(gross - gross / (1 + rate / 100));

// ---- vastausten normalisointi: sopimuksen rakenne → näkymien malli ----
// admin_list_orders.rows[] → {total→total_gross, paid→paid_amount, unpaid→unpaid_amount, first_start→first_reservation_at, …}
export function normOrderRow(r) {
  const total = num(r.total ?? r.total_gross), paid = num(r.paid ?? r.paid_amount);
  return { order_id: r.order_id ?? r.id, order_no: r.order_no, johku_order_no: r.johku_order_no ?? null, created_at: r.created_at, status: r.status ?? null, payment_status: r.payment_status ?? 'unpaid',
    source_channel: r.source_channel ?? '', is_native: r.is_native !== false, total_gross: total, paid_amount: paid, refunded_amount: num(r.refunded ?? r.refunded_amount),
    unpaid_amount: r.unpaid != null || r.unpaid_amount != null ? num(r.unpaid ?? r.unpaid_amount) : round2(Math.max(0, total - paid)),
    customer_name: r.customer_name ?? '', customer_company: r.customer_company ?? null, customer_kind: r.customer_kind ?? null,
    first_reservation_at: r.first_start ?? r.first_reservation_at ?? null, last_end: r.last_end ?? null, reservation_count: num(r.reservation_count), payment_count: num(r.payment_count), receipt_count: num(r.receipt_count), last_paid_at: r.last_paid_at ?? null };
}
// admin_list_payments.rows[] (EI laskurivejä: line_count; rivit haetaan admin_get_order:sta)
export function normPaymentRow(p) {
  return { payment_id: p.payment_id ?? p.id, order_id: p.order_id, order_no: p.order_no, customer_name: p.customer_name ?? '', method: p.method, method_label: p.method_label ?? null, provider: p.provider ?? null, status: p.status,
    amount: num(p.amount), refunded_amount: num(p.refunded_amount), rounding: num(p.rounding), created_at: p.created_at ?? null, paid_at: p.paid_at ?? null, line_count: num(p.line_count), receipt_no: p.receipt_no ?? null, receipt_token: p.receipt_token ?? null };
}
const normLine = (l) => { const gross = num(l.amount_gross ?? l.gross), rate = num(l.vat_rate), vat = l.line_vat != null ? num(l.line_vat) : vatOf(gross, rate);   // sopimus: rivillä vain brutto + ALV-% → ALV/netto lasketaan tässä (arvio; kuitin pyöristys tehdään loppusummasta)
  return { id: l.id ?? null, order_item_id: l.order_item_id ?? null, description: l.description ?? '', quantity: num(l.quantity, 1), amount_gross: gross, vat_rate: rate, line_vat: vat, line_net: l.line_net != null ? num(l.line_net) : round2(gross - vat) }; };
const normReceiptRef = (x) => ({ id: x.id ?? null, receipt_no: x.receipt_no, kind: x.kind ?? 'receipt', issued_at: x.issued_at ?? x.created_at ?? null, public_token: x.public_token ?? x.token ?? null, sent_at: x.sent_at ?? null });
export function normOrderPayment(p) {
  const receipts = (p.receipts || []).map(normReceiptRef);
  return { payment_id: p.id ?? p.payment_id, method: p.method, method_label: p.method_label ?? null, status: p.status, amount: num(p.amount), refunded_amount: num(p.refunded_amount), rounding: num(p.rounding), paid_at: p.paid_at ?? null,
    created_at: p.created_at ?? null, provider: p.provider ?? null, link_token: p.link_token ?? null, link_path: p.link_path ?? null, link_expires_at: p.link_expires_at ?? null, note: p.note ?? null,
    lines: (p.lines || []).map(normLine), receipts, refunds: (p.refunds || []).map((x) => ({ id: x.id, amount: num(x.amount), status: x.status, reason: x.reason ?? null, created_at: x.created_at ?? null, done_at: x.done_at ?? null })),
    receipt_no: receipts.find((x) => x.kind === 'receipt')?.receipt_no ?? null };
}
export function normOrder(o) {
  const b = o.balance || {}, payments = (o.payments || []).map(normOrderPayment);
  const reservations = (o.reservations || []).map((x) => ({ reservation_id: x.id ?? x.reservation_id, item_id: x.item_id ?? null, product_name: x.product_name, mode: x.mode ?? null, starts_at: x.starts_at, ends_at: x.ends_at, persons: x.persons, status: x.status, item_total: num(x.item_total),
    addons: (x.addons || []).map((a) => ({ addon_id: a.addon_id ?? null, name: a.name, quantity: num(a.quantity, 1), unit_price: num(a.unit_price), line_total: num(a.line_total), vat_rate: num(a.vat_rate) })) }));
  const total = num(o.total ?? b.total);
  return { order_id: o.order_id, order_no: o.order_no, johku_order_no: o.johku_order_no ?? null, status: o.status ?? null, payment_status: o.payment_status ?? 'unpaid', source_channel: o.source_channel ?? '', is_native: o.is_native !== false,
    created_at: o.created_at, customer: o.customer || {}, customer_name: o.customer?.name ?? '', internal_note: o.internal_note ?? null, customer_note: o.customer_note ?? null,
    public_token: o.public_token ?? null, order_page_path: o.order_page_path ?? null, can_add: !!o.can_add, staff_can_add: !!o.staff_can_add, add_until: o.add_until ?? null,
    balance: { total, paid: num(b.paid), refunded: num(b.refunded), pending_link: num(b.pending_link), unpaid: num(b.unpaid), unpaid_unlinked: num(b.unpaid_unlinked, num(b.unpaid)), net_paid: num(b.net_paid) },
    total_gross: total, paid_amount: num(b.paid), unpaid_amount: num(b.unpaid),
    items: (o.items || []).map((x) => ({ id: x.id, parent_item_id: x.parent_item_id ?? null, kind: x.kind, name: x.name, quantity: num(x.quantity, 1), unit_price: num(x.unit_price), line_total: num(x.line_total), vat_rate: num(x.vat_rate), covered: num(x.covered), remaining: num(x.remaining) })),
    payments, reservations, receipts: (o.receipts || []).map(normReceiptRef), requests: o.requests || [], first_reservation_at: reservations.map((x) => x.starts_at).filter(Boolean).sort()[0] ?? null };
}
const L = (a) => (Array.isArray(a) ? a : []);
export function normReport(r) {
  const tt = r.totals || {};
  return { period: r.period || { from: null, to: null, kind: 'day' }, generated_at: r.generated_at ?? null,
    totals: { receipts: num(tt.receipts), refund_receipts: num(tt.refund_receipts), gross: num(tt.gross), net: num(tt.net), vat: num(tt.vat), refunds_gross: num(tt.refunds_gross), net_after_refunds: num(tt.net_after_refunds ?? tt.net), rounding: num(tt.rounding) },
    by_method: L(r.by_method).map((m) => ({ method: m.method, label: m.label ?? null, payments: num(m.payments), gross: num(m.gross), refunds: num(m.refunds), rounding: num(m.rounding) })),
    by_vat: L(r.by_vat).map((v) => ({ rate: num(v.rate), net: num(v.net), vat: num(v.vat), gross: num(v.gross) })),
    by_method_vat: L(r.by_method_vat).map((v) => ({ method: v.method, rate: num(v.rate), net: num(v.net), vat: num(v.vat), gross: num(v.gross) })),
    by_category: L(r.by_category).map((c) => ({ category: c.category, label: c.label ?? null, rate: num(c.rate), quantity: num(c.quantity), gross: num(c.gross), net: num(c.net), vat: num(c.vat) })),
    receipts: Array.isArray(r.receipts) ? r.receipts.map((x) => ({ receipt_no: x.receipt_no, kind: x.kind, issued_at: x.issued_at, order_no: x.order_no ?? null, method: x.method, gross: num(x.gross), net: num(x.net), vat: num(x.vat) })) : null,
    by_day: Array.isArray(r.by_day) ? r.by_day.map((d) => ({ date: d.date, receipts: num(d.receipts), gross: num(d.gross), vat: num(d.vat), refunds: num(d.refunds) })) : null,
    open: { orders: num(r.open?.orders), unpaid: num(r.open?.unpaid) },
    lines: Array.isArray(r.lines) ? r.lines : null };   // rivitaso: vain mock (asiakaspuolen CSV); oikea palvelin ei sitä vielä palauta
}

// ---- parametrien muodostus ----
const compact = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== null && v !== ''));
// Näkymän lajitteluavain → sopimuksen p_sort (`created_desc|order_no_asc|total_*|start_*|paid_*|unpaid_desc`). "Maksutila"-lajittelua ei ole sopimuksessa → unpaid_desc (maksamattomat ensin).
export function orderSortParam(sortBy = 'created', sortDir = 'desc') {
  const dir = sortDir === 'asc' ? 'asc' : 'desc';
  switch (sortBy) {
    case 'order_no': return `order_no_${dir}`; case 'total': return `total_${dir}`; case 'first_reservation': return `start_${dir}`;
    case 'payment_status': return 'unpaid_desc'; default: return `created_${dir}`;
  }
}
export const paymentSortParam = (sortDir = 'desc') => `paid_${sortDir === 'asc' ? 'asc' : 'desc'}`;
const lim = (n) => Math.min(200, Math.max(1, Math.trunc(+n) || 50));   // sopimus: max 200

// ---- oikea toteutus: nimet ja p_-parametrit sopimuksen mukaan. `rpc(nimi, parametrit)` = sb.js:n rpc tai mockin rpc ----
export function rpcBackend(rpc) {
  const call = async (key, params = {}) => {
    const res = await rpc(RPC[key], params);
    if (res && res.ok === false) throw new RpcError(res.message || res.code || 'Pyyntö epäonnistui', { code: res.code, status: 400, details: res });
    return res;
  };
  return {
    listOrders: async (a) => call('listOrders', compact({ p_search: a.search, p_status: a.status, p_payment_status: a.paymentStatus, p_source: a.source, p_native: a.native === 'native' ? true : a.native === 'imported' ? false : undefined,
      p_date_field: a.dateField === 'start' ? 'start' : undefined, p_from: a.from, p_to: a.to, p_sort: orderSortParam(a.sortBy, a.sortDir), p_limit: lim(a.limit), p_offset: Math.max(0, Math.trunc(+a.offset) || 0) })),
    listPayments: async (a) => call('listPayments', compact({ p_search: a.search, p_method: a.method, p_status: a.status, p_from: a.from, p_to: a.to, p_sort: paymentSortParam(a.sortDir), p_limit: lim(a.limit), p_offset: Math.max(0, Math.trunc(+a.offset) || 0) })),
    getOrder: (id) => call('getOrder', { p_order_id: id }),
    listAddons: () => call('listAddons'),
    addToOrder: (a) => call('addToOrder', compact({ p_order_id: a.orderId, p_items: a.items, p_create_link: a.createLink ? true : undefined, p_send_email: a.sendEmail ? true : undefined, p_note: a.note })),
    createPaymentLink: (a) => call('createPaymentLink', compact({ p_order_id: a.orderId, p_send_email: a.sendEmail ? true : undefined, p_expires_days: a.expiresDays, p_note: a.note })),
    refund: (a) => call('refund', compact({ p_payment_id: a.paymentId, p_amount: a.amount, p_reason: a.reason, p_lines: a.lines })),
    reportDaily: (date) => call('reportDaily', { p_date: date }),
    reportMonthly: (ym) => call('reportMonthly', { p_ym: ym }),
    reportCsv: (a) => call('reportCsv', compact({ p_from: a.from, p_to: a.to, p_kind: a.kind || 'lines' })),
  };
}

export function createTalousApi({ rpc, mock = wantsMock(), mockFactory = () => createMock({ delay: 120 }) } = {}) {
  const forced = !!mock, missing = new Set(), listeners = new Set();
  let mockBackend = null;
  const real = rpc && !forced ? rpcBackend(rpc) : null;
  const getMock = () => (mockBackend ||= rpcBackend(mockFactory().rpc));
  const notify = () => listeners.forEach((f) => f(api));
  const run = async (key, args, post = (x) => x) => {
    if (!real || missing.has(key)) return post(await getMock()[key](args));
    try { return post(await real[key](args)); } catch (e) {
      if (!isMissingRpc(e)) throw e;
      missing.add(key); notify();   // RPC puuttuu → tämä toiminto mockiin + ilmoitus
      return post(await getMock()[key](args));
    }
  };
  const act = async (key, args) => {
    if (real && !LIVE_ACTIONS[key]) throw new FeatureNotReady(RPC[key]);
    return run(key, args);
  };
  const api = {
    get mode() { return !real ? 'mock' : missing.size ? 'mixed' : 'real'; }, get reason() { return forced ? 'param' : missing.size ? 'missing' : null; },
    get missing() { return [...missing].map((k) => RPC[k]); }, get missingRpc() { return [...missing].map((k) => RPC[k]).join(', '); },
    isMock: (key) => !real || missing.has(key),
    onMode(f) { listeners.add(f); return () => listeners.delete(f); },
    // nappi on käytössä mockissa tai kun LIVE_ACTIONS[key] on päällä
    actionLive: (key) => !real || (!!LIVE_ACTIONS[key] && !missing.has(key)),
    listOrders: (a) => run('listOrders', a, (r) => ({ total: num(r.total), rows: L(r.rows).map(normOrderRow) })),
    listPayments: (a) => run('listPayments', a, (r) => ({ total: num(r.total), sum_paid: num(r.sum_paid), sum_refunded: num(r.sum_refunded), rows: L(r.rows).map(normPaymentRow) })),
    getOrder: (id) => run('getOrder', id, normOrder),
    listAddons: () => run('listAddons', undefined, (r) => L(r).filter((x) => x.active !== false).map((x) => ({ id: x.id, code: x.code, name: x.name, name_en: x.name_en || x.name, price: num(x.price ?? x.price_gross) }))),
    reportDaily: (date) => run('reportDaily', date, normReport),
    reportMonthly: (ym) => run('reportMonthly', ym, normReport),
    // CSV: jos raportti sisältää rivitason (`lines`, vain mock) → asiakaspuolen CSV (csv.js, pyydetyt 12 saraketta); muuten palvelimen admin_report_csv (sen omat sarakkeet).
    // Palauttaa { source:'client', lines } tai { source:'server', filename, content }.
    async reportCsv(report) {
      if (report.lines) return { source: 'client', lines: report.lines };
      const res = await run('reportCsv', { from: report.period.from, to: report.period.to, kind: 'lines' });
      return { source: 'server', filename: res.filename || `kuitit_${report.period.from}_${report.period.to}.csv`, content: String(res.content ?? ''), mime: res.mime || 'text/csv' };
    },
    addToOrder: (a) => act('addToOrder', a), createPaymentLink: (a) => act('createPaymentLink', a), refund: (a) => act('refund', a),
  };
  return api;
}
