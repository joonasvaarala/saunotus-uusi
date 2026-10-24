// Sähköpostipohjien "kultaiset" tapaukset (booking-osa 3 / PR 3): render(kind, data, locale) -syötteet, joilla varmistetaan että
// tekstien siirto tietokantaan (email.*-avaimet) ei muuta viestien sisältöä tavuakaan, kun DB-rivit vastaavat repon oletuksia.
// Käyttö: golden.test.mjs (sha256-tiivisteet tiedostossa golden-email.json, otettu ennen siirtoa vanhalla templates.ts:llä).
const SITE = 'https://saunotus.fi';
const ORDER_URL = `${SITE}/tilaus/?t=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c`;
const PAY_URL = `${SITE}/maksa/?p=9d8c7b6a-1111-4222-8333-444455556666`;
const GTOK = '0654361d-a2b1-43f4-a25c-8c7223907dd0';
const base = (locale) => ({
  id: 1, locale, to: 'asiakas@example.com', to_name: 'Matti Meikäläinen',
  order: {
    order_no: 15321, order_url: ORDER_URL, total: 134, status: 'confirmed',
    items: [{ name: 'Yleinen vuoro', quantity: 2, line_total: 36, vat_rate: 25.5, kind: 'product' }, { name: 'Pyyhe', quantity: 2, line_total: 6, vat_rate: 25.5, kind: 'addon' }, { name: 'Hieronta 60 min', quantity: 1, line_total: 92, vat_rate: 25.5, kind: 'product' }],
    reservations: [{ product_name: 'Yleinen vuoro', starts_at: '2026-11-07T15:00:00Z', ends_at: '2026-11-07T17:00:00Z', persons: 2, status: 'confirmed' }, { product_name: 'Peruttu', starts_at: '2026-11-08T15:00:00Z', ends_at: '2026-11-08T17:00:00Z', persons: 1, status: 'cancelled' }],
  },
  receipt: { id: 5, receipt_no: '2026-000123', kind: 'receipt', text_body: 'KUITTI 2026-000123\nYleinen vuoro 2 × 18,00 €\nYhteensä 134,00 €', public_token: 'abc', total: 134, issued_at: '2026-11-07T09:30:00Z' },
  payment: { id: 9, amount: 98.5, link_url: PAY_URL, link_expires_at: '2026-11-14T20:00:00Z' },
});
const refund = (locale) => { const d = base(locale); d.receipt = { ...d.receipt, kind: 'refund_receipt', receipt_no: '2026-000124', total: -10, text_body: 'HYVITYSKUITTI 2026-000124\nHyvitys -10,00 €' }; return d; };
const gcard = (o = {}) => ({ public_token: GTOK, package_code: 'sauna_treatment_2', package_name: 'Savusaunaelämys ja saunahoito kahdelle', package_name_en: 'Smoke sauna experience and sauna treatment for two', kind: 'product', amount: 192, valid_to: '2027-04-01', recipient_name: 'Mikko Mallikas', greeting: 'Kortin tervehdys', buyer_name: 'Olli Ostaja', persons: 2, locale: 'fi', status: 'active', delivery_to: 'buyer', deliver_on: null, deliver_time: null, deliver_at: null, recipient_email: 'mikko@example.invalid', cover_message: null, ...o });
const gbase = { functions_url: 'https://x.supabase.co/functions/v1', redeem_online: false, to_name: 'Olli Ostaja' };
const rcard = (o = {}) => gcard({ delivery_to: 'recipient', recipient_email: 'saaja@example.com', recipient_name: 'Sanna Saaja', ...o });
const sched = { delivery_to: 'recipient', deliver_on: '2026-12-24', deliver_time: '14:30', deliver_at: '2026-12-24T12:30:00Z' };
const vc = (locale, o = {}) => ({ ...base(locale), voucher_claim: { claim_id: 7, status: 'received', source: 'elamyslahjat', code_masked: '…1234', problem_code: 'invalid_code', customer_name: 'Matti Meikäläinen', ...o } });

export function emailCases() {
  const out = [];
  const add = (name, kind, data, locale) => out.push({ name, kind, data, locale });
  for (const l of ['fi', 'en']) {
    for (const k of ['order_confirmation', 'payment_link', 'receipt', 'cancel_request_ack', 'order_change']) add(`${k}.${l}`, k, base(l), l);
    add(`invoice_pdf.${l}`, 'invoice_pdf', { ...base(l), invoice: { id: 3, invoice_no: 'L000001', public_token: 'abc', total: 120, due_date: '2026-11-21', reference_no: '1234561', status: 'sent' } }, l);
    add(`refund_receipt.${l}`, 'refund_receipt', refund(l), l);
    // tyhjät/puuttuvat tiedot
    for (const k of ['order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change']) add(`${k}.${l}.tyhja`, k, { locale: l }, l);
    // ei tuotteita, vain varauksia; ei varauksia, vain rivit; ei etunimeä; ei vanhenemista; tuotevalinta
    { const d = base(l); d.order.items = []; add(`order_confirmation.${l}.vain_varaukset`, 'order_confirmation', d, l); }
    { const d = base(l); d.order.reservations = []; add(`order_confirmation.${l}.vain_rivit`, 'order_confirmation', d, l); }
    { const d = base(l); d.to_name = ''; add(`order_confirmation.${l}.ei_nimea`, 'order_confirmation', d, l); }
    { const d = base(l); d.payment.link_expires_at = null; add(`payment_link.${l}.ei_vanhene`, 'payment_link', d, l); }
    { const d = base(l); d.payment.link_url = null; add(`payment_link.${l}.ei_linkkia`, 'payment_link', d, l); }
    { const d = base(l); d.order.reservations = [{ product_name: 'Saunahoito', starts_at: '2026-11-07T15:00:00Z', ends_at: '2026-11-07T16:00:00Z', persons: 1, status: 'confirmed', option: { code: 'hunajahoito', name: 'Hunajahoito', name_en: 'Honey treatment' } }]; add(`order_confirmation.${l}.valinta`, 'order_confirmation', d, l); }
    { const d = base(l); d.receipt.total = null; d.receipt.text_body = ''; d.receipt.issued_at = null; add(`receipt.${l}.tyhja_kuitti`, 'receipt', d, l); }
    { const d = base(l); d.to_name = '<script>alert(1)</script> X'; d.order.items[0].name = 'A & B "<b>"'; d.order.order_url = 'javascript:alert(1)'; d.payment.link_url = 'https://x.example/"onmouseover="a'; for (const k of ['order_confirmation', 'payment_link', 'receipt']) add(`${k}.${l}.escape`, k, d, l); }
    // lahjakortit
    add(`gift_card_buyer.${l}.suora`, 'gift_card_buyer', { ...gbase, gift_cards: [gcard({ locale: l })] }, l);
    add(`gift_card_buyer.${l}.kaksi_korttia`, 'gift_card_buyer', { ...gbase, gift_cards: [gcard({ locale: l }), gcard({ package_code: 'open', kind: 'value', amount: 50.5, locale: l })] }, l);
    add(`gift_card_buyer.${l}.sekatilaus`, 'gift_card_buyer', { ...gbase, gift_cards: [gcard({ locale: l }), rcard({ locale: l, public_token: '11111111-2222-4333-8444-555555555555' })] }, l);
    add(`gift_card_buyer.${l}.saajalle`, 'gift_card_buyer', { ...gbase, gift_cards: [rcard({ locale: l })] }, l);
    add(`gift_card_buyer.${l}.saajalle_kaksi`, 'gift_card_buyer', { ...gbase, gift_cards: [rcard({ locale: l }), rcard({ locale: l, public_token: '11111111-2222-4333-8444-555555555555', package_code: 'open', kind: 'value', amount: 50 })] }, l);
    add(`gift_card_buyer.${l}.ajastettu`, 'gift_card_buyer', { ...gbase, gift_cards: [rcard({ locale: l, ...sched })] }, l);
    add(`gift_card_buyer.${l}.ajastettu_ei_kelloa`, 'gift_card_buyer', { ...gbase, gift_cards: [rcard({ locale: l, deliver_on: '2026-12-24', deliver_time: null, deliver_at: '2026-12-24T12:30:00Z' })] }, l);
    add(`gift_card_buyer.${l}.verkossa`, 'gift_card_buyer', { ...gbase, redeem_online: true, gift_cards: [gcard({ locale: l })] }, l);
    add(`gift_card_recipient.${l}.saate`, 'gift_card_recipient', { ...gbase, to_name: 'Sanna Saaja', redeem_online: true, gift_cards: [rcard({ locale: l, cover_message: 'Hei Sanna,\nTässä saate <b>&' })] }, l);
    add(`gift_card_recipient.${l}.ei_saatetta`, 'gift_card_recipient', { ...gbase, gift_cards: [rcard({ locale: l, cover_message: null, buyer_name: null })] }, l);
    add(`gift_card_recipient.${l}.avoin`, 'gift_card_recipient', { ...gbase, gift_cards: [rcard({ locale: l, package_code: 'open', kind: 'value', amount: 50.5 })] }, l);
    add(`gift_card_recipient.${l}.paketti`, 'gift_card_recipient', { ...gbase, gift_cards: [rcard({ locale: l })] }, l);
    add(`gift_card_recipient.${l}.kaksi`, 'gift_card_recipient', { ...gbase, gift_cards: [rcard({ locale: l }), rcard({ locale: l, package_code: 'open', kind: 'value', amount: 20 })] }, l);
    add(`gift_card_buyer.${l}.ei_pakettinimea`, 'gift_card_buyer', { ...gbase, gift_cards: [gcard({ locale: l, package_name: null, package_name_en: null, package_code: 'x' })] }, l);
    add(`gift_card_buyer.${l}.ei_nimea`, 'gift_card_buyer', { ...gbase, to_name: null, gift_cards: [gcard({ locale: l, buyer_name: null, recipient_name: null, valid_to: null, persons: null })] }, l);
    // kumppanilahjakortit
    add(`voucher_claim_received.${l}`, 'voucher_claim_received', vc(l), l);
    add(`voucher_claim_received.${l}.tuntematon`, 'voucher_claim_received', vc(l, { source: 'tuntematon', code_masked: '' }), l);
    for (const src of ['kokemuskauppa', 'kiitoskauppa', 'offerilla']) add(`voucher_claim_received.${l}.${src}`, 'voucher_claim_received', vc(l, { source: src }), l);
    for (const pc of ['invalid_code', 'expired_code', 'already_used', 'other']) add(`voucher_claim_problem.${l}.${pc}`, 'voucher_claim_problem', vc(l, { status: 'problem', problem_code: pc }), l);
    add(`voucher_claim_problem.${l}.tuntematon_kumppani`, 'voucher_claim_problem', vc(l, { status: 'problem', source: 'x', code_masked: '', problem_code: 'invalid_code' }), l);
  }
  // locale-parametri voittaa datan
  add('order_change.param_en', 'order_change', { ...base('fi'), locale: 'fi' }, 'en');
  add('order_change.ei_localea', 'order_change', { ...base('fi'), locale: undefined }, undefined);
  return out;
}
