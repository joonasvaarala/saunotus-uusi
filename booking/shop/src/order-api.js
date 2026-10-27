// Asiakkaan tilaussivun DATAKERROS: public_get_order, public_add_to_order, public_request_cancel, public_get_receipt (sopimus: KOODARI_talous_A_D_fi.md, vaihe C).
// Mock ↔ oikea = yksi `rpc`-funktio (order-mock.js:n rpc vastaa samoilla nimillä, parametreilla ja vastausmuodoilla). Mock vain kun osoitteessa on ?mock=1.
// Asiakkaalle EI näytetä esimerkkidataa, vaikka RPC puuttuisi: puuttuva RPC (404/PGRST202) → { ok:false, notReady:true } → "ominaisuus ei vielä käytössä".
// Palvelimen virheet tulevat HTTP 200 + { ok:false, code, message } → palautetaan sellaisenaan (ei heitetä).
import { createOrderMock } from './order-mock.js';
import { normOptions, reservationItem } from './options-logic.js';
import { normCheckout } from './hold-logic.js';
import { holdMockParams } from './hold-mock.js';
export const RPC = { get: 'public_get_order', addToOrder: 'public_add_to_order', requestCancel: 'public_request_cancel', getReceipt: 'public_get_receipt', changeOrderTime: 'public_change_order_time' };
export const isMissingRpc = (e) => !!e && (e.status === 404 || e.code === 'PGRST202' || e.code === '42883' || /could not find the function/i.test(e.message || ''));
export const wantsMock = (loc = typeof location !== 'undefined' ? location : null) => !!loc && new URLSearchParams(loc.search || '').get('mock') === '1';
export const validToken = (t) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(t || ''));
const num = (v, d = 0) => (v == null || v === '' || !Number.isFinite(+v) ? d : +v);
// public_get_order → sivun malli
export function normOrder(r) {
  return { ok: true, order_no: r.order_no, status: r.status, payment_status: r.payment_status || 'unpaid', created_at: r.created_at ?? null, first_name: r.first_name ?? '', locale: r.locale ?? null,
    total: num(r.total), paid: num(r.paid), unpaid: num(r.unpaid),
    checkout: normCheckout(r),   // booking_53 (§17): kassan pitotila; null = vanha backend (tilaussivu toimii ennallaan)
    items: (r.items || []).map((i) => ({ name: i.name, name_en: i.name_en ?? null, quantity: num(i.quantity, 1), line_total: num(i.line_total), vat_rate: num(i.vat_rate) })),
    // reservations: booking_50 lisää product_id, option (valittu hoito) ja option_choices (vaihtoehdot, muutosvalitsin); booking_52 option_label(_fi/_en) (valitsimen otsikko)
    reservations: (r.reservations || []).map((x) => ({ reservation_id: x.reservation_id, product_id: x.product_id ?? null, product_name: x.product_name,
      option: x.option ? { id: x.option.id ?? null, code: x.option.code, name: x.option.name, name_en: x.option.name_en ?? null } : null, option_choices: normOptions({ options: x.option_choices }).options, option_label: x.option_label ?? null, option_label_fi: x.option_label_fi ?? null, option_label_en: x.option_label_en ?? null, starts_at: x.starts_at, ends_at: x.ends_at, persons: num(x.persons, 1), status: x.status,
      addons: (x.addons || []).map((a) => ({ addon_id: a.addon_id ?? null, name: a.name ?? '', name_en: a.name_en ?? null, quantity: num(a.quantity, 1) })) })),
    payments: (r.payments || []).map((p) => ({ status: p.status, amount: num(p.amount), paid_at: p.paid_at ?? null, method_label: p.method_label ?? null, link_token: p.link_token ?? null, link_path: p.link_path ?? null, refund_pending: p.refund_pending === true })),
    receipts: (r.receipts || []).map((x) => ({ receipt_no: x.receipt_no, kind: x.kind || 'receipt', issued_at: x.issued_at ?? null, token: x.token ?? null, total: num(x.total) })),
    can_add: !!r.can_add, add_until: r.add_until ?? null, can_change: !!r.can_change, change_deadline: r.change_deadline ?? null, change_hours_before: r.change_hours_before ?? null,
    invoice_locked: r.invoice_locked === true,
    customer_kind: r.customer_kind ?? null, invoice_method: r.invoice_method ?? null,   // booking_187: tilaussivu erottaa verkkomaksun laskusta
    // booking_149: asiakkaan peruutuspyynnön takaraja (vuoron alku − customer_change_hours_before). can_request_cancel null = vanha backend (ei kenttää) → lomake kuten ennen.
    can_request_cancel: r.can_request_cancel == null ? null : !!r.can_request_cancel, cancel_deadline: r.cancel_deadline ?? null, cancel_hours_before: r.cancel_hours_before ?? null, cancel_closed: !!r.cancel_closed,
    cancel_request: r.cancel_request ? { status: r.cancel_request.status, created_at: r.cancel_request.created_at } : null, online_payment_enabled: !!r.online_payment_enabled,
    instructions: (r.instructions || []).filter((g) => g && String(g.body || '').trim()).map((g) => ({ id: g.id ?? null, title: g.title || '', body: String(g.body), link_url: g.link_url || null, rich: g.rich === true ? true : g.rich === false ? false : undefined,
      // booking_141: lyhyt ohje aina näkyvissä (short_rich vain tosi/epätosi; puuttuva = pelkkä teksti).
      short_text: String(g.short_text ?? ''), short_rich: g.short_rich === true, delivery_mode: g.delivery_mode === 'order_only' ? 'order_only' : 'scheduled' })),
    upsell_addons: (r.upsell?.addons || []).map((a) => ({ id: a.id, code: a.code, name: a.name, name_en: a.name_en ?? null, price: num(a.price), max: num(a.max, 20) })),
    upsell_treatments: (r.upsell?.treatments || []).map((x) => ({ product_id: x.product_id ?? null, name: x.name || '', name_en: x.name_en ?? null })) };
}
export function rpcBackend(rpc, token) {
  return {
    get: async () => { const r = await rpc(RPC.get, { p_token: token }); return r?.ok === false ? r : normOrder(r); },
    addToOrder: ({ items }) => rpc(RPC.addToOrder, { p_token: token, p_items: items }),
    // booking_50: hoidon vaihto (pelkkä p_option_code; muut null = ennallaan) ja varausrivin lisäys tilaukseen (option_code pakollinen jos tuote vaatii)
    changeOrderTime: ({ reservationId, optionCode, start, ruleId, date, persons }) => rpc(RPC.changeOrderTime, { p_token: token, p_reservation_id: reservationId, p_start: start ?? null, p_rule_id: ruleId ?? null, p_date: date ?? null, p_persons: persons ?? null, p_option_code: optionCode ?? null }),
    addReservation: (r) => rpc(RPC.addToOrder, { p_token: token, p_items: [reservationItem(r)] }),
    requestCancel: ({ reason }) => rpc(RPC.requestCancel, reason ? { p_token: token, p_reason: reason } : { p_token: token }),
    getReceipt: ({ receiptNo }) => rpc(RPC.getReceipt, { p_order_token: token, p_receipt_no: receiptNo }),   // HUOM: parametri on p_order_token (ei p_token)
  };
}
export function createOrderApi({ rpc, token, mock = wantsMock(), mockFactory = () => createOrderMock({ delay: 120, scenario: typeof location !== 'undefined' ? new URLSearchParams(location.search).get('scenario') || '' : '', mpResult: typeof location !== 'undefined' ? new URLSearchParams(location.search).get('mpresult') || '' : '', ...holdMockParams() }) } = {}) {
  const inst = mock ? mockFactory() : null;
  const backendRpc = mock ? inst.rpc : rpc;
  const be = rpcBackend(backendRpc, token);
  const wrap = (key) => async (a) => { try { return await be[key](a); } catch (e) { if (!mock && isMissingRpc(e)) return { ok: false, notReady: true, rpc: RPC[key] }; throw e; } };
  return { mock, rpc: backendRpc, mpFetch: inst?.mpFetch ?? null, get: wrap('get'), addToOrder: wrap('addToOrder'), requestCancel: wrap('requestCancel'), getReceipt: wrap('getReceipt'), changeOrderTime: wrap('changeOrderTime'), addReservation: wrap('addReservation') };
}
