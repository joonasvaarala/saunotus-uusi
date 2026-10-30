// Talous-näkymien DATAKERROS – kaikki Talous-sivun datankäsittely kulkee tämän tiedoston kautta (näkymät eivät tunne RPC-nimiä tai p_-parametreja).
// Lopullinen sopimus: /workspace/procountor/KOODARI_talous_A_D_fi.md (v1, 17.10.2026). Nimet/parametrit/vastausmuodot: rpcBackend() ja normalisoijat alla.
//
// Mock ↔ oikea = YKSI `rpc`-funktio: createTalousApi({ rpc }) kutsuu rpcBackend(rpc):tä. Mock (talous-mock.js → createMock().rpc) vastaa samoilla RPC-nimillä,
// p_-parametreilla ja vastausrakenteilla, joten sama koodi ajaa molempia.
//   · Tila 'mock': osoitteessa ?mock=1 (kyselyosassa tai #/talous?mock=1) → kaikki data mockista.
//   · Tila 'real': kutsut menevät palvelimelle. Jos jokin RPC PUUTTUU (404 / PGRST202 / 42883; esim. vanhempi kanta ilman raportti-RPC:itä), kyseinen toiminto
//     siirtyy mockiin, sivu näyttää "ominaisuus ei vielä käytössä" -ilmoituksen (api.missing) – muut toiminnot pysyvät oikeina.
//   · Kirjoittavat toiminnot (lisäys, maksulinkki, maksun kirjaus, hyvitys, kuitin uudelleenlähetys) menevät oikeassa tilassa aina oikealle palvelimelle (ei mock-varakutsua → ei näennäisiä onnistumisia).
//   · Kuitit: getReceipt (teksti + snapshot), resendReceipt, receiptPdfUrl (receipt-pdf?t=<public_token>, URL muodostetaan hallinnan Supabase-asetuksesta, ei palvelimen pdf_url-kentästä).
import { createMock } from './talous-mock.js';

export const RPC = {
  listOrders: 'admin_list_orders', getOrder: 'admin_get_order', listPayments: 'admin_list_payments', listAddons: 'admin_list_addons',
  addToOrder: 'admin_add_to_order', createPaymentLink: 'admin_create_payment_link', refund: 'admin_refund', refundOrder: 'admin_refund_order', reservationRefundPreview: 'admin_reservation_refund_preview', cancelReservation: 'admin_cancel_reservation', recordPayment: 'admin_record_payment', listVatRates: 'admin_list_vat_rates',
  reportDaily: 'admin_report_daily', reportMonthly: 'admin_report_month', reportRange: 'admin_report_range', reportTransactions: 'admin_report_transactions', reportGiftCards: 'admin_report_gift_cards', reportCsv: 'admin_report_csv', reportAccrual: 'admin_report_accrual', reportAccrualCsv: 'admin_report_accrual_csv', salesChart: 'admin_sales_chart',
  getReceipt: 'admin_get_receipt', resendReceipt: 'admin_resend_receipt',
  annualCardForOrder: 'admin_annual_card_for_order',   // booking_146: tilauksen vuosikortti + koodin sähköpostin tila
};
export class FeatureNotReady extends Error {
  constructor(rpc) { super(`Ominaisuus ei vielä käytössä (${rpc})`); this.name = 'FeatureNotReady'; this.code = 'feature_not_ready'; this.rpc = rpc; }
}
export class RpcError extends Error {
  constructor(message, { code, status, details } = {}) { super(message); this.name = 'ApiError'; this.code = code; this.status = status; this.details = details; }
}
// PostgREST: puuttuva funktio = 404 + PGRST202 ("Could not find the function …"); 42883 = undefined_function
// HUOM: sb.js asettaa ApiError.code = details || code → PGRST202:ssa `code` on pitkä selite; BK001-virheet (esim. not_found) eivät ole puuttuvia funktioita vaikka status olisi 404.
export const isMissingRpc = (e) => !!e && e.details?.code !== 'BK001' && (e.status === 404 || e.details?.code === 'PGRST202' || e.code === 'PGRST202' || e.code === '42883' || /could not find the function/i.test(e.message || ''));
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
    amount: num(p.amount), refunded_amount: num(p.refunded_amount), rounding: num(p.rounding), created_at: p.created_at ?? null, paid_at: p.paid_at ?? null, line_count: num(p.line_count), receipt_no: p.receipt_no ?? null, receipt_token: p.receipt_token ?? null,
    source: p.source ?? (p.is_johku ? 'johku' : 'native'), is_johku: p.is_johku != null ? !!p.is_johku : p.source === 'johku' };   // booking_41: source 'johku'|'native' + is_johku (Johku-lähtöinen: ei kirjanpitoon)
}
const normLine = (l) => { const gross = num(l.amount_gross ?? l.gross), rate = num(l.vat_rate), vat = l.line_vat != null ? num(l.line_vat) : vatOf(gross, rate);   // sopimus: rivillä vain brutto + ALV-% → ALV/netto lasketaan tässä (arvio; kuitin pyöristys tehdään loppusummasta)
  return { id: l.id ?? null, order_item_id: l.order_item_id ?? null, description: l.description ?? '', quantity: num(l.quantity, 1), amount_gross: gross, vat_rate: rate, line_vat: vat, line_net: l.line_net != null ? num(l.line_net) : round2(gross - vat) }; };
// kuittiviite: admin_get_order.receipts[] (id, receipt_no, kind, issued_at, total, payment_id, refund_id, public_token, sent_at) ja payments[].receipts[] (ilman total/payment_id)
const normReceiptRef = (x) => ({ id: x.id ?? null, receipt_no: x.receipt_no, kind: x.kind ?? 'receipt', issued_at: x.issued_at ?? x.created_at ?? null, public_token: x.public_token ?? x.token ?? null, sent_at: x.sent_at ?? null,
  total: x.total != null || x.total_gross != null ? num(x.total ?? x.total_gross) : null, payment_id: x.payment_id ?? null, refund_id: x.refund_id ?? null });
// admin_get_receipt → { id, receipt_no, kind, issued_at, total_gross, snapshot, text_body, public_token, pdf_url, sent_at, order_id, payment_id, refund_id }
export const normReceipt = (x) => ({ ...normReceiptRef(x), total: num(x.total_gross ?? x.total), snapshot: x.snapshot ?? null, text_body: String(x.text_body ?? ''), pdf_url: x.pdf_url ?? null, order_id: x.order_id ?? null });
export function normOrderPayment(p) {
  const receipts = (p.receipts || []).map(normReceiptRef);
  return { payment_id: p.id ?? p.payment_id, method: p.method, method_label: p.method_label ?? null, status: p.status, amount: num(p.amount), refunded_amount: num(p.refunded_amount), rounding: num(p.rounding), paid_at: p.paid_at ?? null,
    created_at: p.created_at ?? null, provider: p.provider ?? null, link_token: p.link_token ?? null, link_path: p.link_path ?? null, link_expires_at: p.link_expires_at ?? null, link_stale: p.link_stale === true, note: p.note ?? null,
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
    invoice_locked: o.invoice_locked === true, invoice_no: o.invoice_no ?? null,
    customer_kind: o.customer?.customer_kind ?? o.customer_kind ?? null, billing_method: o.billing?.invoice_method ?? null,
    balance: { total, paid: num(b.paid), refunded: num(b.refunded), pending_link: num(b.pending_link), unpaid: num(b.unpaid), unpaid_unlinked: num(b.unpaid_unlinked, num(b.unpaid)), net_paid: num(b.net_paid) },
    total_gross: total, paid_amount: num(b.paid), unpaid_amount: num(b.unpaid),
    items: (o.items || []).map((x) => ({ id: x.id, parent_item_id: x.parent_item_id ?? null, kind: x.kind, name: x.name, quantity: num(x.quantity, 1), unit_price: num(x.unit_price), line_total: num(x.line_total), vat_rate: num(x.vat_rate), covered: num(x.covered), remaining: num(x.remaining) })),
    payments, reservations, receipts: (o.receipts || []).map(normReceiptRef), requests: o.requests || [], first_reservation_at: reservations.map((x) => x.starts_at).filter(Boolean).sort()[0] ?? null };
}
const L = (a) => (Array.isArray(a) ? a : []);
// admin_list_vat_rates → { missing:[{kind,id,name}], quote_only:[…], rates:[…] }
export function normVatRates(r) {
  return { rates: L(r?.rates).map((x) => ({ rate: num(x.rate), label: x.label ?? '', active: x.active !== false, products: num(x.products), addons: num(x.addons) })),
    missing: L(r?.missing).map((x) => ({ kind: x.kind ?? 'product', id: x.id, name: x.name ?? '' })), quote_only: L(r?.quote_only).map((x) => ({ id: x.id, name: x.name ?? '' })) };
}
// Verkkokaupan osoite (maksulinkin isäntä): admin_get_order.order_page_path on todellisuudessa täysi osoite (site_base_url + order_page_path + ?t=…); sopimus sanoo polku → hyväksytään molemmat.
export function siteOrigin(order, fallback = typeof location !== 'undefined' ? location.origin : '') {
  try { const u = new URL(order?.order_page_path || '', 'http://x.invalid'); if (u.origin !== 'http://x.invalid') return u.origin; } catch { /* ei osoite */ }
  return fallback;
}
// Sivuston juuri polkuineen (GitHub Pages -testi: https://…github.io/saunotus-uusi/, tuotanto: https://saunotus.fi/): order_page_path ilman viimeistä
// polkuosaa (/tilaus/). Pelkkä origin pudotti testisivuston polkuetuliitteen → …github.io/maksa/?p=… (404).
export function siteBase(order, fallback = typeof location !== 'undefined' ? location.origin + '/' : '') {
  try { const u = new URL(order?.order_page_path || '', 'http://x.invalid'); if (u.origin !== 'http://x.invalid') return u.origin + u.pathname.replace(/[^/]+\/?$/, ''); } catch { /* ei osoite */ }
  return fallback;
}
export const absLink = (path, order) => { if (!path) return ''; try { return new URL(String(path).replace(/^\/+/, ''), siteBase(order)).href; } catch { return String(path); } };
// booking_41: ylätason statistics.johku (EI kirjanpitoon, ei totals-lukuihin). Puuttuessa (vanha palvelin) → null = lohkoa ei näytetä.
export function normJohkuStats(j) {
  if (!j || typeof j !== 'object') return null;
  return { label: j.label ?? 'Johku (ei kirjanpitoon)', accounting: false, basis: j.basis ?? 'johku_paid_at', orders: num(j.orders), gross: num(j.gross), refunded_orders: num(j.refunded_orders), refunded_gross: num(j.refunded_gross),
    by_method: L(j.by_method).map((m) => ({ method: m.method ?? 'unknown', orders: num(m.orders), gross: num(m.gross) })) };
}
export function normReport(r) {
  const tt = r.totals || {};
  const per = r.period || {};   // sopimus (booking_35): period {from,to,tz,kind:'day'|'month'}; kind puuttuessa päätellään (sama päivä = päivä)
  const kind = per.kind === 'day' || per.kind === 'month' || per.kind === 'range' ? per.kind : (per.from && per.from === per.to ? 'day' : per.from ? 'month' : 'day');
  // gross_after_refunds = brutto hyvitysten jälkeen (booking_35). net_after_refunds on DEPRECATED (sama arvo) → ei käytetä; puuttuessa lasketaan gross + refunds_gross.
  const grossAfter = tt.gross_after_refunds ?? (num(tt.gross) + num(tt.refunds_gross));
  return { period: { ...per, from: per.from ?? null, to: per.to ?? null, kind }, generated_at: r.generated_at ?? null,
    totals: { receipts: num(tt.receipts), refund_receipts: num(tt.refund_receipts), gross: num(tt.gross), net: num(tt.net), vat: num(tt.vat), refunds_gross: num(tt.refunds_gross), gross_after_refunds: num(grossAfter), vat_after_refunds: num(tt.vat_after_refunds ?? tt.vat), net_ex_vat_after_refunds: num(tt.net_ex_vat_after_refunds ?? tt.net), rounding: num(tt.rounding) },
    by_method: L(r.by_method).map((m) => ({ method: m.method, label: m.label ?? null, payments: num(m.payments), gross: num(m.gross), refunds: num(m.refunds), rounding: num(m.rounding) })),
    by_vat: L(r.by_vat).map((v) => ({ rate: num(v.rate), net: num(v.net), vat: num(v.vat), gross: num(v.gross) })),
    by_method_vat: L(r.by_method_vat).map((v) => ({ method: v.method, rate: num(v.rate), net: num(v.net), vat: num(v.vat), gross: num(v.gross) })),
    by_category: L(r.by_category).map((c) => ({ category: c.category, label: c.label ?? null, rate: num(c.rate), quantity: num(c.quantity), gross: num(c.gross), net: num(c.net), vat: num(c.vat) })),
    by_product: Array.isArray(r.by_product) ? r.by_product.map((p) => ({ product: p.product ?? '', rate: num(p.rate), quantity: num(p.quantity), net: num(p.net), vat: num(p.vat), gross: num(p.gross) })) : null,
    refunds_by_product: Array.isArray(r.refunds_by_product) ? r.refunds_by_product.map((p) => ({ product: p.product ?? '', rate: num(p.rate), quantity: num(p.quantity), net: num(p.net), vat: num(p.vat), gross: num(p.gross) })) : null,
    reconciliation: r.reconciliation && typeof r.reconciliation === 'object' ? {
      sales_gross: num(r.reconciliation.sales_gross), refunds_gross: num(r.reconciliation.refunds_gross), product_gross: num(r.reconciliation.product_gross),
      payments_gross: num(r.reconciliation.payments_gross), difference: num(r.reconciliation.difference), line_vat: num(r.reconciliation.line_vat), receipt_vat: num(r.reconciliation.receipt_vat),
      vat_rounding: num(r.reconciliation.vat_rounding), cash_rounding: num(r.reconciliation.cash_rounding), rounding_code: r.reconciliation.rounding_code ?? null,
    } : null,
    vat_summary: Array.isArray(r.vat_summary) ? r.vat_summary.map((v) => ({ rate: num(v.rate), net: num(v.net), vat: num(v.vat), gross: num(v.gross) })) : null,
    gift_card_period: r.gift_card_period && typeof r.gift_card_period === 'object' ? {
      sold: {
        count: num(r.gift_card_period.sold?.count), net: num(r.gift_card_period.sold?.net), vat: num(r.gift_card_period.sold?.vat), gross: num(r.gift_card_period.sold?.gross),
        lines: L(r.gift_card_period.sold?.lines).map((p) => ({ product: p.product ?? '', rate: num(p.rate), quantity: num(p.quantity), net: num(p.net), vat: num(p.vat), gross: num(p.gross) })),
        by_vat: L(r.gift_card_period.sold?.by_vat).map((v) => ({ rate: num(v.rate), quantity: num(v.quantity), net: num(v.net), vat: num(v.vat), gross: num(v.gross) })),
      },
      complimentary: {
        issued_count: num(r.gift_card_period.complimentary?.issued_count), issued_gross: num(r.gift_card_period.complimentary?.issued_gross),
        redeemed_count: num(r.gift_card_period.complimentary?.redeemed_count), redeemed_gross: num(r.gift_card_period.complimentary?.redeemed_gross),
      },
    } : null,
    prepaid_redemptions: r.prepaid_redemptions && typeof r.prepaid_redemptions === 'object' ? {
      accounting: false, payments: num(r.prepaid_redemptions.payments), gross: num(r.prepaid_redemptions.gross), net: num(r.prepaid_redemptions.net), vat: num(r.prepaid_redemptions.vat),
      lines: L(r.prepaid_redemptions.lines).map((p) => ({ product: p.product ?? '', rate: num(p.rate), quantity: num(p.quantity), net: num(p.net), vat: num(p.vat), gross: num(p.gross) })),
      by_vat: L(r.prepaid_redemptions.by_vat).map((v) => ({ rate: num(v.rate), quantity: num(v.quantity), net: num(v.net), vat: num(v.vat), gross: num(v.gross) })),
    } : null,
    receipts: Array.isArray(r.receipts) ? r.receipts.map((x) => ({ receipt_no: x.receipt_no, kind: x.kind, issued_at: x.issued_at, order_no: x.order_no ?? null, method: x.method, gross: num(x.gross), net: num(x.net), vat: num(x.vat) })) : null,
    by_day: Array.isArray(r.by_day) ? r.by_day.map((d) => ({ date: d.date, receipts: num(d.receipts), gross: num(d.gross), vat: num(d.vat), refunds: num(d.refunds) })) : null,
    open: { orders: num(r.open?.orders), unpaid: num(r.open?.unpaid) },
    statistics: { johku: normJohkuStats(r.statistics?.johku) },
    lines: Array.isArray(r.lines) ? r.lines : null };   // rivitaso: vain mock (asiakaspuolen CSV); oikea palvelin ei sitä vielä palauta
}
// admin_sales_chart(p_year) → 12 kuukautta. Johku on mukana VAIN tässä (ei raportin totals/CSV). Puuttuva RPC ei vaihda sivua mock-dataan.
const monthNum = (m, i) => ({
  month: i + 1,
  native_net: num(m?.native_net), native_vat: num(m?.native_vat), native_gross: num(m?.native_gross),
  johku_net: num(m?.johku_net), johku_vat: num(m?.johku_vat), johku_gross: num(m?.johku_gross), unsplit_gross: num(m?.unsplit_gross),
  net: num(m?.net), vat: num(m?.vat), gross: num(m?.gross),
});
export function normSalesChart(r) {
  const src = L(r?.months);
  const months = Array.from({ length: 12 }, (_, i) => monthNum(src.find((x) => +x.month === i + 1) || src[i], i));
  const sum = (k) => round2(months.reduce((s, m) => s + m[k], 0));
  const t = r?.totals || {};
  return {
    year: num(r?.year), tz: r?.tz || 'Europe/Helsinki', basis: r?.basis || 'cash_receipt_issued_at', johku_basis: r?.johku_basis || 'johku_paid_at', vat_method: r?.vat_method || 'order_item_rates_proportional',
    months,
    totals: { native_net: num(t.native_net, sum('native_net')), native_vat: num(t.native_vat, sum('native_vat')), native_gross: num(t.native_gross, sum('native_gross')),
      johku_net: num(t.johku_net, sum('johku_net')), johku_vat: num(t.johku_vat, sum('johku_vat')), johku_gross: num(t.johku_gross, sum('johku_gross')), unsplit_gross: num(t.unsplit_gross, sum('unsplit_gross')),
      net: num(t.net, sum('net')), vat: num(t.vat, sum('vat')), gross: num(t.gross, sum('gross')) },
    years: L(r?.years).map((y) => +y).filter((y) => y >= 2000 && y <= 2100),
  };
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
    listOrders: async (a) => call('listOrders', compact({ p_search: a.search, p_status: a.status, p_payment_status: a.paymentStatus, p_payment_filter: a.paymentFilter, p_source: a.source, p_native: a.native === 'native' ? true : a.native === 'imported' ? false : undefined,
      p_date_field: a.dateField === 'start' ? 'start' : undefined, p_from: a.from, p_to: a.to, p_sort: orderSortParam(a.sortBy, a.sortDir), p_limit: lim(a.limit), p_offset: Math.max(0, Math.trunc(+a.offset) || 0) })),
    listPayments: async (a) => call('listPayments', compact({ p_search: a.search, p_method: a.method, p_status: a.status, p_from: a.from, p_to: a.to, p_sort: paymentSortParam(a.sortDir), p_limit: lim(a.limit), p_offset: Math.max(0, Math.trunc(+a.offset) || 0) })),
    getOrder: (id) => call('getOrder', { p_order_id: id }),
    listAddons: () => call('listAddons'),
    addToOrder: (a) => call('addToOrder', compact({ p_order_id: a.orderId, p_items: a.items, p_create_link: a.createLink ? true : undefined, p_send_email: a.sendEmail ? true : undefined, p_note: a.note })),
    createPaymentLink: (a) => call('createPaymentLink', compact({ p_order_id: a.orderId, p_send_email: a.sendEmail ? true : undefined, p_expires_days: a.expiresDays, p_note: a.note })),
    refund: (a) => call('refund', compact({ p_payment_id: a.paymentId, p_amount: a.amount, p_reason: a.reason, p_lines: a.lines })),
    // booking_136: hyvitys + valinnainen tilauksen varausten peruutus (oletus Ei); varauksen osuus maksuista; varauksen peruutus + valinnainen osuuden hyvitys (oletus Ei)
    refundOrder: (a) => call('refundOrder', compact({ p_payment_id: a.paymentId, p_amount: a.amount, p_reason: a.reason, p_lines: a.lines, p_cancel_reservations: a.cancelReservations === true ? true : undefined })),
    reservationRefundPreview: (id) => call('reservationRefundPreview', { p_reservation_id: id }),
    cancelReservation: (a) => call('cancelReservation', compact({ p_reservation_id: a.reservationId, p_reason: a.reason, p_refund: a.refund === true ? true : undefined, p_refund_reason: a.refundReason })),
    recordPayment: (a) => call('recordPayment', compact({ p_order_id: a.orderId, p_method: a.method, p_amount: a.amount, p_note: a.note, p_lines: a.lines })),
    listVatRates: () => call('listVatRates'),
    reportDaily: (date) => call('reportDaily', { p_date: date }),
    reportMonthly: (ym) => call('reportMonthly', { p_ym: ym }),
    reportRange: (a) => call('reportRange', { p_from: a.from, p_to: a.to }),
    reportTransactions: (a) => call('reportTransactions', { p_from: a.from, p_to: a.to }),
    reportGiftCards: (a) => call('reportGiftCards', { p_filter: a.filter, p_format: a.format || 'json' }),
    reportCsv: (a) => call('reportCsv', compact({ p_from: a.from, p_to: a.to, p_kind: a.kind || 'lines' })),
    reportAccrual: (a) => call('reportAccrual', { p_from: a.from, p_to: a.to }),
    reportAccrualCsv: (a) => call('reportAccrualCsv', { p_from: a.from, p_to: a.to }),
    salesChart: (year) => call('salesChart', { p_year: year }),
    getReceipt: (id) => call('getReceipt', { p_receipt_id: id }),
    resendReceipt: (id) => call('resendReceipt', { p_receipt_id: id }),
    annualCardForOrder: (id) => call('annualCardForOrder', { p_order_id: id }),
  };
}

// io = selaimen apurit (talous.js antaa sb.js:n): functionUrl(nimi, kysely) = Edge-funktion osoite, select(taulu, kysely) = PostgREST-luku, fnBlob(nimi, kysely) = JWT-suojattu GET → {blob,type}
const moneyLine = (p) => ({ product: p.product ?? '', rate: num(p.rate), quantity: num(p.quantity), net: num(p.net), vat: num(p.vat), gross: num(p.gross) });
const vatLine = (v) => ({ rate: num(v.rate), quantity: num(v.quantity), net: num(v.net), vat: num(v.vat), gross: num(v.gross) });
export function normAccrual(r) {
  const per = r.period || {};
  const t = r.totals || {};
  const adv = r.advances || {};
  const svc = adv.services || {};
  const gc = adv.gift_cards_unused || {};
  return {
    period: { from: per.from ?? null, to: per.to ?? null, tz: per.tz || 'Europe/Helsinki', kind: per.kind || (per.from && per.from === per.to ? 'day' : 'range') },
    basis: r.basis || 'service',
    as_of: r.as_of || per.to || null,
    generated_at: r.generated_at ?? null,
    sales_by_product: L(r.sales_by_product).map(moneyLine),
    sales_by_vat: L(r.sales_by_vat).map(vatLine),
    refunds_by_product: L(r.refunds_by_product).map(moneyLine),
    refunds_by_vat: L(r.refunds_by_vat).map(vatLine),
    totals: {
      sales_net: num(t.sales_net), sales_vat: num(t.sales_vat), sales_gross: num(t.sales_gross),
      refunds_net: num(t.refunds_net), refunds_vat: num(t.refunds_vat), refunds_gross: num(t.refunds_gross),
      net: num(t.net), vat: num(t.vat), gross: num(t.gross),
    },
    advances: {
      as_of: adv.as_of || r.as_of || per.to || null,
      services: { net: num(svc.net), vat: num(svc.vat), gross: num(svc.gross), lines: num(svc.lines), by_vat: L(svc.by_vat).map(vatLine) },
      gift_cards_unused: { count: num(gc.count), gross: num(gc.gross), vat: num(gc.vat), net: num(gc.net), rate: num(gc.rate || 25.5), vat_at_sale: gc.vat_at_sale !== false },
      total_gross: num(adv.total_gross),
    },
  };
}

export function createTalousApi({ rpc, io = {}, mock = wantsMock(), mockFactory = () => createMock({ delay: 120 }) } = {}) {
  const forced = !!mock, missing = new Set(), listeners = new Set();
  let mockBackend = null;
  const real = rpc && !forced ? rpcBackend(rpc) : null;
  const getMock = () => (mockBackend ||= rpcBackend(mockFactory().rpc));
  const notify = () => listeners.forEach((f) => f(api)), changeListeners = new Set();
  const run = async (key, args, post = (x) => x) => {
    if (!real || missing.has(key)) return post(await getMock()[key](args));
    try { return post(await real[key](args)); } catch (e) {
      if (!isMissingRpc(e)) throw e;
      missing.add(key); notify();   // RPC puuttuu → tämä toiminto mockiin + ilmoitus
      return post(await getMock()[key](args));
    }
  };
  // Kirjoittava toiminto: oikeassa tilassa vain oikealle palvelimelle (ei koskaan mock-varakutsua → ei näennäisiä onnistumisia); puuttuva RPC → FeatureNotReady.
  const act = async (key, args) => {
    if (!real) return getMock()[key](args);
    if (missing.has(key)) throw new FeatureNotReady(RPC[key]);
    try { return await real[key](args); } catch (e) {
      if (isMissingRpc(e)) { missing.add(key); notify(); throw new FeatureNotReady(RPC[key]); }
      throw e;
    }
  };
  const api = {
    get mode() { return !real ? 'mock' : missing.size ? 'mixed' : 'real'; }, get reason() { return forced ? 'param' : missing.size ? 'missing' : null; },
    get missing() { return [...missing].map((k) => RPC[k]); }, get missingRpc() { return [...missing].map((k) => RPC[k]).join(', '); },
    isMock: (key) => !real || missing.has(key),
    onMode(f) { listeners.add(f); return () => listeners.delete(f); },
    // oikea kirjoitus onnistui → muut välilehdet hakevat datan uudelleen kun ne avataan
    onChanged(f) { changeListeners.add(f); return () => changeListeners.delete(f); }, changed() { changeListeners.forEach((f) => f()); },
    listOrders: (a) => run('listOrders', a, (r) => ({ total: num(r.total), rows: L(r.rows).map(normOrderRow) })),
    listPayments: (a) => run('listPayments', a, (r) => ({ total: num(r.total), sum_paid: num(r.sum_paid), sum_refunded: num(r.sum_refunded),
      // booking_41: ex_johku-summat (summarivi käyttää näitä) + Johku-rivien määrä; vanha palvelin → ei Johku-rivejä, sama summa
      sum_paid_ex_johku: num(r.sum_paid_ex_johku ?? r.sum_paid), sum_refunded_ex_johku: num(r.sum_refunded_ex_johku ?? r.sum_refunded), johku_rows: num(r.johku_rows), rows: L(r.rows).map(normPaymentRow) })),
    getOrder: (id) => run('getOrder', id, normOrder),
    listAddons: () => run('listAddons', undefined, (r) => L(r).filter((x) => x.active !== false).map((x) => ({ id: x.id, code: x.code, name: x.name, name_en: x.name_en || x.name, price: num(x.price ?? x.price_gross) }))),
    reportDaily: (date) => run('reportDaily', date, normReport),
    reportMonthly: (ym) => run('reportMonthly', ym, normReport),
    reportRange: (from, to) => run('reportRange', { from, to }, normReport),
    reportAccrual: (from, to) => run('reportAccrual', { from, to }, normAccrual),
    async reportAccrualCsv(from, to) {
      const res = await run('reportAccrualCsv', { from, to });
      return { source: 'server', filename: res.filename || `suorite_${from}_${to}.csv`, content: String(res.content ?? ''), mime: res.mime || 'text/csv' };
    },
    reportTransactions: (from, to) => run('reportTransactions', { from, to }, (r) => ({ period: r.period || { from, to, kind: 'transactions' }, rows: L(r.rows).map((x) => ({
      voucher: x.voucher ?? '', date: x.date ?? '', customer: x.customer ?? '', product: x.product ?? '', quantity: num(x.quantity), net: num(x.net), vat_rate: num(x.vat_rate), vat: num(x.vat), gross: num(x.gross),
      method: x.method ?? '', method_label: x.method_label ?? '', status: x.status === 'open' ? 'open' : 'paid', kind: x.kind === 'refund' ? 'refund' : x.kind === 'redemption' ? 'redemption' : 'sale' })) })),
    // Käyrä: oikeassa tilassa puuttuva RPC ei pudota mock-myyntilukuihin (väärä raha hallinnassa). ?mock=1 käyttää mockia.
    async salesChart(year) {
      if (!real) return normSalesChart(await getMock().salesChart(year));
      try { return normSalesChart(await real.salesChart(year)); } catch (e) {
        if (isMissingRpc(e)) throw new FeatureNotReady(RPC.salesChart);
        throw e;
      }
    },
    // CSV: palvelimen admin_report_csv. lines/transactions = tapahtumaraportti (tosite;pvm;asiakas;…), summary = yhteenveto, vat = ALV-erittely.
    // Palauttaa { source:'server', filename, content }. (csv.js = asiakaspuolen varakirjoittaja samoille sarakkeille, ei käytössä kun palvelin vastaa.)
    async reportCsv(report, kind = 'lines') {
      const res = await run('reportCsv', { from: report.period.from, to: report.period.to, kind });
      const prefix = kind === 'summary' ? 'yhteenveto' : kind === 'vat' ? 'kuitit_vat' : 'tapahtumat';
      return { source: 'server', filename: res.filename || `${prefix}_${report.period.from}_${report.period.to}.csv`, content: String(res.content ?? ''), mime: res.mime || 'text/csv' };
    },
    async reportGiftCards(filter = 'open', format = 'json') {
      const res = await run('reportGiftCards', { filter, format });
      if (format === 'csv') return { source: 'server', filename: res.filename || `lahjakortit_${filter}.csv`, content: String(res.content ?? ''), mime: res.mime || 'text/csv' };
      const bucket = (b) => ({ count: num(b?.count), initial: num(b?.initial), balance: num(b?.balance), net: num(b?.net), vat: num(b?.vat), gross: num(b?.gross) });
      const row = (x) => ({ code_masked: x.code_masked ?? '', buyer: x.buyer ?? '', package: x.package ?? '', initial: num(x.initial), balance: num(x.balance), net: num(x.net), vat_rate: num(x.vat_rate), vat: num(x.vat), gross: num(x.gross), sold_on: x.sold_on ?? null, valid_to: x.valid_to ?? null, status: x.status ?? '', source: x.source ?? '', vat_treatment: x.vat_treatment ?? '', complimentary: x.complimentary === true || x.vat_treatment === 'maksuton' });
      return { filter: res.filter || filter, own: { rows: L(res.own?.rows).map(row), at_redemption: bucket(res.own?.at_redemption), at_sale: bucket(res.own?.at_sale), complimentary: bucket(res.own?.complimentary) }, johku: { rows: L(res.johku?.rows).map(row), totals: bucket(res.johku?.totals) } };
    },
    // ALV-huomautus on vain tiedote: virhe/puuttuva RPC/oikeus puuttuu → null (ei mock-varaa, ei bannerin muutosta)
    listVatRates: async () => { if (!real) return normVatRates(await getMock().listVatRates()); try { return normVatRates(await real.listVatRates()); } catch { return null; } },
    // MobilePay-hyvitys (sopimus §14.4): admin_refund luo rivin status='requested' (provider='mobilepay'); sen jälkeen POST mobilepay-refund {refund_id} käyttäjän JWT:llä (vaatii payments.refund).
    // Palauttaa { result: done | failed | retry_later | unverified | db_error | none | off | forbidden | error, detail? }. Ei koskaan heitä: tulos näytetään käyttäjälle, hyvitysrivi säilyy 'requested' kunnes käsitelty (turvallista toistaa: Idempotency-Key).
    async mobilepayRefund(refundId) {
      if (!real || !io.fn) return { result: 'done', mock: true };
      try {
        const j = await io.fn('mobilepay-refund', { refund_id: refundId });
        const x = (j?.processed || []).find((p) => +p.refund_id === +refundId);
        return x ? { result: String(x.result || 'error'), detail: x.detail ?? null } : { result: j?.mode === 'off' ? 'off' : 'none' };
      } catch (e) {
        const code = e?.code || e?.details?.code || null;
        return { result: code === 'forbidden' || e?.status === 403 ? 'forbidden' : 'error', code, status: e?.status ?? null };
      }
    },
    // Visma Pay -hyvitys: admin_refund luo rivin status='requested' (provider='visma_pay'); sen jälkeen POST vismapay-refund {refund_id} käyttäjän JWT:llä (payments.refund).
    // Palauttaa { result: done | failed | retry_later | awaiting_customer | not_settled | not_configured | db_error | none | off | forbidden | error }. Ei heitä.
    async vismapayRefund(refundId) {
      if (!real || !io.fn) return { result: 'done', mock: true };
      try {
        const j = await io.fn('vismapay-refund', { refund_id: refundId });
        const x = (j?.processed || []).find((p) => +p.refund_id === +refundId);
        if (x) return { result: String(x.result || 'error'), detail: x.detail ?? null };
        return { result: j?.mode === 'off' || j?.mode === 'dry_run' ? 'off' : 'none' };
      } catch (e) {
        const code = e?.code || e?.details?.code || null;
        return { result: code === 'forbidden' || e?.status === 403 ? 'forbidden' : 'error', code, status: e?.status ?? null };
      }
    },
    // Verkkomaksun hyvitys: admin_refund luo rivin status='requested' (provider='montonio'); sen jälkeen POST montonio-refund {refund_id}.
    // Hyvityskuitti syntyy vasta SUCCESSFUL-ilmoituksesta. Palauttaa { result: done | pending | awaiting_settlement | failed | retry_later | db_error | not_configured | none | off | forbidden | error }.
    async montonioRefund(refundId) {
      if (!real || !io.fn) return { result: 'done', mock: true };
      try {
        const j = await io.fn('montonio-refund', { refund_id: refundId });
        const x = (j?.processed || []).find((p) => +p.refund_id === +refundId);
        if (x) return { result: String(x.result || 'error'), detail: x.detail ?? null };
        return { result: j?.mode === 'off' || j?.mode === 'dry_run' ? 'off' : 'none' };
      } catch (e) {
        const code = e?.code || e?.details?.code || null;
        return { result: code === 'forbidden' || e?.status === 403 ? 'forbidden' : 'error', code, status: e?.status ?? null };
      }
    },
    addToOrder: (a) => act('addToOrder', a), createPaymentLink: (a) => act('createPaymentLink', a), refund: (a) => act('refund', a), refundOrder: (a) => act('refundOrder', a), recordPayment: (a) => act('recordPayment', a),
    reservationRefundPreview: (id) => act('reservationRefundPreview', id), cancelReservation: (a) => act('cancelReservation', a),
    // booking_146: tilauksen vuosikortti (koodi, voimassaolo, sähköpostin tila). Oikeassa tilassa EI mock-varaa: puuttuva RPC → null (näkymä ei näytä mitään keksittyä koodia).
    annualCardForOrder: async (id) => {
      if (!real) return getMock().annualCardForOrder(id);
      if (missing.has('annualCardForOrder')) return null;
      try { return await real.annualCardForOrder(id); } catch (e) { if (isMissingRpc(e)) { missing.add('annualCardForOrder'); return null; } throw e; }
    },
    // ---- kuitit ----
    getReceipt: (id) => run('getReceipt', id, normReceipt),
    // admin_resend_receipt → { ok, email_queued }: jonoon vain jos asiakkaalla on kelvollinen sähköposti; oikeus payments.manage
    resendReceipt: (id) => act('resendReceipt', id),
    // Kuitti-PDF: <SUPABASE_URL>/functions/v1/receipt-pdf?t=<public_token> (verify_jwt=false → suora linkki). URL tulee hallinnan omasta konfiguraatiosta (sama kuin sb.js:n funktiokutsut),
    // EI palvelimen pdf_url-kentästä: sen isäntä on asetus functions_base_url, joka voi osoittaa toiseen projektiin (esim. testiprojektin kopiossa tuotantoon).
    receiptPdfUrl: (token) => (token && io.functionUrl ? io.functionUrl('receipt-pdf', { t: token }) : ''),
    // Sähköpostin lähetystila (integration_config.resend.mode: off | dry_run | live) – luku sallittu henkilökunnalle (RLS). null = ei saatavilla. Mockissa dry_run (kuten tuotannossa nyt).
    async resendMode() {
      if (!real) return 'dry_run';
      try { const rows = await io.select?.('integration_config', { select: 'mode', key: 'eq.resend' }); const m = rows?.[0]?.mode; return ['off', 'dry_run', 'live'].includes(m) ? m : null; } catch { return null; }
    },
    // Raportin PDF palvelimelta (report-pdf, verify_jwt=true): kuukausi vaatii reports.view. Mockissa: ei palvelinta → null (näkymä käyttää selaimen tulostusta).
    async reportPdf(report) {
      if (!real || !io.fnBlob) return null;
      const p = report.period || {}, mode = report.pdf || 'summary';
      const q = mode === 'transactions' ? { kind: 'transactions', from: p.from, to: p.to }
        : mode === 'giftcards' ? { kind: 'giftcards', filter: report.filter || 'all' }
        : p.kind === 'day' ? { kind: 'daily', date: p.from }
        : p.kind === 'month' ? { kind: 'month', ym: String(p.from || '').slice(0, 7) }
        : { kind: 'range', from: p.from, to: p.to };
      return io.fnBlob('report-pdf', q);
    },
  };
  return api;
}
