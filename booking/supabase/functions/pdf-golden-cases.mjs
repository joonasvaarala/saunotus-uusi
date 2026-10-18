// PDF-pohjien "kultaiset" tapaukset (osa 3 / PR 3): lahjakortti- ja kuitti-PDF:n syötteet, joilla varmistetaan että tekstien siirto
// tietokantaan (email.*-avaimet) ei muuta PDF:ää tavuakaan kun DB-rivit vastaavat oletuksia. Tiivisteet: pdf-golden.json (otettu ennen siirtoa).
// Ajo: deno run -A --node-modules-dir=none pdf-golden.test.ts   (Date kiinnitetään, jotta pdf-lib:n aikaleimat eivät muuta tavuja)
const seller = { name: 'Havuhattu Oy / Sipoonjoen Perinnesauna', legal_name: 'Havuhattu Oy', business_id: '3018112-1', address: 'Hindsbyntie 124', zip: '04130', city: 'Sipoo', email: 'savusauna@saunotus.fi', phone: '010 299 2866', web: 'https://saunotus.fi' };
const base = { ok: true, status: 'active', currency: 'EUR', locale: 'fi', valid_from: '2026-10-01', valid_to: '2027-04-01', issued_at: '2026-10-01T09:00:00+03:00', seller, redeemable_now: true, source: 'native' };
const pkg2 = { name: 'Savusaunaelämys ja saunahoito kahdelle', name_en: 'Smoke sauna experience and sauna treatment for two', persons: 2, is_open: false, items: [{ label: 'Yleinen vuoro', label_en: 'General session', persons: 2 }, { label: 'Saunahoito', label_en: 'Sauna treatment', persons: 2 }] };
export function giftCardCases() {
  const c = (name, data, o = {}) => ({ name, data, logo: true, lang: undefined, ...o });
  return [
    c('fi_pkg_greet', { ...base, code: 'HH3A-7CEF-HJKL', kind: 'product', package_code: 'sauna_treatment_2', package: pkg2, initial_amount: 192, balance: 192, recipient_name: 'Mikko Mallikas', buyer_name: 'Olli Ostaja', greeting: 'Hyvää syntymäpäivää, Mikko!\nNauti lämmöstä.' }),
    c('en_pkg_greet', { ...base, locale: 'en', code: 'HHCE-FHJK-LMRT', kind: 'product', package_code: 'sauna_treatment_2', package: pkg2, initial_amount: 192, balance: 192, recipient_name: 'Mikko Mallikas', buyer_name: 'Olli Ostaja', greeting: 'Happy birthday!' }),
    c('fi_open', { ...base, code: 'HH7M-RTUV-WXY3', kind: 'value', package_code: 'open', package: { is_open: true, items: [] }, initial_amount: 75, balance: 75, recipient_name: 'Mikko Mallikas', buyer_name: 'Olli Ostaja', greeting: null }),
    c('en_open', { ...base, locale: 'en', code: 'HH7M-RTUV-WXY3', kind: 'value', package_code: 'open', package: { name: 'Avoin lahjakortti', name_en: 'Open gift card', is_open: true, items: [] }, initial_amount: 75, balance: 75, recipient_name: 'Mikko Mallikas', buyer_name: 'Olli Ostaja', greeting: null }),
    c('fi_open_partial', { ...base, code: 'HH7M-RTUV-WXY3', kind: 'value', package_code: 'open', package: { is_open: true }, initial_amount: 100, balance: 62.5, recipient_name: null, buyer_name: null, greeting: 'Nauti!' }),
    c('fi_expired', { ...base, status: 'expired', code: 'HHAA-CCCC-EECE', kind: 'value', package_code: 'open', package: { is_open: true }, initial_amount: 50.5, balance: 20.25, recipient_name: 'Saaja', buyer_name: null, greeting: 'Hyvää joulua!', redeemable_now: false }),
    c('fi_used_pkg', { ...base, status: 'used', code: 'HH3A-7CEF-HJKL', kind: 'product', package_code: 'x', package: pkg2, initial_amount: 96, balance: 0, recipient_name: 'Mikko', buyer_name: 'Olli', greeting: null, redeemable_now: false }),
    c('en_expired_pkg', { ...base, locale: 'en', status: 'expired', code: 'HH3A-7CEF-HJKL', kind: 'product', package_code: 'x', package: pkg2, initial_amount: 96, balance: 96, recipient_name: 'Mikko', buyer_name: 'Olli', greeting: null, redeemable_now: false }),
    c('johku_used', { ...base, source: 'johku', status: 'used', code: 'ZZ34-79AC-EFHJ', kind: 'product', package_code: null, package: null, initial_amount: 58, balance: 0, recipient_name: null, buyer_name: 'Johku Ostaja', greeting: null, redeemable_now: false }, { logo: false }),
    c('johku_active_en', { ...base, locale: 'en', source: 'johku', code: 'ZZ34-79AC-EFHJ', kind: 'product', package_code: null, package: null, initial_amount: 58, balance: 30, recipient_name: null, buyer_name: null, greeting: null }, { logo: false }),
    c('en_open_as_fi', { ...base, locale: 'en', code: 'HH7M-RTUV-WXY3', kind: 'value', package_code: 'open', package: { is_open: true }, initial_amount: 75, balance: 75 }, { lang: 'fi' }),
    c('fi_open_as_en', { ...base, code: 'HH7M-RTUV-WXY3', kind: 'value', package_code: 'open', package: { is_open: true }, initial_amount: 75, balance: 75 }, { lang: 'en' }),
    c('no_seller', { ...base, seller: {}, code: 'HH7M-RTUV-WXY3', kind: 'value', package_code: 'open', package: { is_open: true }, initial_amount: 75, balance: 75 }, { logo: false }),
  ];
}
const sel = { name: 'Sipoonjoen Perinnesauna', legal_name: 'Havuhattu Oy', business_id: '3018112-1', vat_id: 'FI30181121', address: 'Hindsbyntie 124', zip: '04130', city: 'Sipoo', email: 'savusauna@saunotus.fi', phone: '010 299 2866', web: 'saunotus.fi', footer: 'Kiitos käynnistä! Tervetuloa uudelleen. Tämä kuitti on muuttumaton tosite.' };
const lines = [
  { description: 'Yleinen vuoro', quantity: 2, unit_gross: 18, vat_rate: 25.5, line_gross: 36, starts_at: '2026-11-07T15:00:00Z', ends_at: '2026-11-07T17:00:00Z' },
  { description: 'Pyyhe', quantity: 2, unit_gross: 3, vat_rate: 25.5, line_gross: 6 },
  { description: 'Hieronta 60 min', quantity: 1, unit_gross: 92, vat_rate: 25.5, line_gross: 92 },
];
const vat = [{ rate: 25.5, net: 106.77, vat: 27.23, gross: 134 }];
const rbase = { locale: 'fi', receipt_no: '2026-000123', document: 'receipt', invoice_required: false, seller: sel, issued_local: '2026-11-07 11:30', order_no: 15321, payment: { method_label: 'MobilePay' }, lines, vat, total_gross: 134, total_vat: 27.23, total_net: 106.77, rounding: 0, total_paid: 134 };
export function receiptCases() {
  return [
    { name: 'fi', data: rbase },
    { name: 'en', data: { ...rbase, locale: 'en', payment: { method: 'cash' } } },
    { name: 'fi_invoice_buyer', data: { ...rbase, invoice_required: true, buyer: { company: 'Yritys Oy', name: 'Matti Meikäläinen', business_id: '1234567-8', address: 'Katu 1', zip: '00100', city: 'Helsinki', reference: 'PO-77' } } },
    { name: 'en_invoice_buyer', data: { ...rbase, locale: 'en', invoice_required: true, buyer: { company: 'Yritys Oy', name: 'Matti', business_id: '1234567-8', address: 'Katu 1', zip: '00100', city: 'Helsinki', reference: 'PO-77' } } },
    { name: 'fi_refund', data: { ...rbase, document: 'refund_receipt', receipt_no: '2026-000124', reason: 'Asiakkaan peruutus', original: { receipt_no: '2026-000123', issued_local: '2026-11-07 11:30' }, total_gross: -10, total_vat: -2.03, total_net: -7.97, total_paid: -10 } },
    { name: 'en_refund', data: { ...rbase, locale: 'en', document: 'refund_receipt', receipt_no: '2026-000124', reason: 'Customer cancellation', original: { receipt_no: '2026-000123', issued_at: '2026-11-07T09:30:00Z' }, total_gross: -10, total_vat: -2.03, total_net: -7.97, total_paid: -10 } },
    { name: 'fi_rounding_nofooter', data: { ...rbase, rounding: -0.02, seller: { ...sel, footer: null } } },
    { name: 'en_rounding_plus', data: { ...rbase, locale: 'en', rounding: 0.03 } },
    { name: 'fi_monta_riviä', data: { ...rbase, lines: Array.from({ length: 40 }, (_, i) => ({ description: `Tuote ${i + 1} pitkällä kuvauksella joka voi rivittyä usealle riville ${i}`, quantity: 1, unit_gross: 10, vat_rate: 25.5, line_gross: 10 })) } },
  ];
}
