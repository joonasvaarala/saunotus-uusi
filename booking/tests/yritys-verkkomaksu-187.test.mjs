// booking_187: yrityksen kolmas laskutustapa "Maksa verkossa" (ei laskua, sama verkkomaksu kuin yksityisellä).
// Ei verkkoa eikä tietokantaa. SQL: supabase/tests/checkout/t187_company_online_payment.sql (ajetaan devissä migraation jälkeen).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { paysByInvoice, formPaysOnline } from '../shop/src/company-pay.js';
import { BILLING_METHOD_TEXTS, billingMethodText } from '../admin/billing-method-texts.js';
import { normOrder } from '../admin/talous-api.js';
import { setLang } from '../admin/talous-i18n.js';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');
const rd = (p) => readFileSync(join(root, p), 'utf8');
const md5 = (s) => createHash('md5').update(s).digest('hex');
const MIG = 'booking/supabase/migrations/20261027090000_booking_187_company_online_payment.sql';
const RB = 'booking/supabase/rollbacks/20261027090000_booking_187_ROLLBACK.sql';
const REPLACED = {
  'booking._clean_company': ['53fa5a8a98e98aeb4a97000d2f6b37ec', '019579f7b2a615f691c206aeb214195d'],
  'booking._stamp_order_billing': ['693f24abfe0dddfbf4a2e345e1596e73', 'ded4c037a352e2b65b6f5e3100643334'],
  'booking.public_create_booking': ['befba768679c4e414c4f3966ac4aa136', '6bf51ffd45c259ef5546aa19f63f5066'],
  'booking.public_create_treatment_booking': ['d47cd6e939943cb2cfa385c0767bc2cb', 'ece168b714a2478bd8a1e5d31f6e6fb7'],
  'booking.vismapay_payment_prepare': ['cca997c4e900e78b8bb9e2e0c7da25d4', 'd1f8df803a45c2b77aa9f8554fc41890'],
  'booking.public_payment_options': ['07937cf049df18f7951e7c827f495f8e', '46834d95db5127935ad94e8759758ceb'],
  'booking.public_payment_link_info': ['647c556562046c75b7e7e33703c050a0', '1b729ef4d72dc925001169c38bad3315'],
  'booking.public_get_booking': ['3b9187db7f41c94f5d582fcebb132f23', '31b07afa6d8e5b61ed9c044d39e76275'],
  'booking.public_get_order': ['c993d12037a9a9269265ba1cb809291e', '5d0a5c1623ed4495be2d3ad0173284f1'],
  'booking.orders_invoice_status_trg': ['9ec5c212604145e284fa07d2fd2686f6', '7f7eced664b101cb2672a78059c90682'],
};
const HELPER = '40b7b4498592ad7ae0b2883941364573';
const DEPS = {
  public_create_booking_code: '0741abee882e4a30cf46f5c8160de7a3',
  mobilepay_payment_prepare: 'e6888446c4b44e554d31c0920609ddb6',
  orders_invoice_draft_trg: 'a48fe50340cff5f6e9709ad46055ecb9',
  _ensure_draft_invoice: 'eefa8e82c7aab1a148bdb3e319ae65ae',
  _order_invoice_locked: '96713008e2d1fce8c81aeda3a2b6b025',
  _buyer_json: '12b345a433ece461a946b7385f849f77',
  _issue_receipt: 'ae8b663945b78d1849b0028987689c8e',
  _receipt_text: '87a25fcd8cc1f8890386c344a82deb3e',
  public_checkout_payment_options: 'e6f019284f2b222013133af83d8fface',
  _public_pay_json: 'cc3e61dbdfbd9a816cd9c982c73820c5',
};
// pg_get_functiondef = CREATE..$function$ + yksi rivinvaihto, ilman puolipistettä.
// plpgsql sulkee `end $function$;`, SQL-apufunktio omalla rivillään `$function$;`.
const bodies = (sql) => {
  const out = {};
  const re = /CREATE OR REPLACE FUNCTION (booking\.[a-z_]+)\(/g;
  let m;
  while ((m = re.exec(sql))) {
    const start = m.index;
    const open = sql.indexOf('AS $function$', start);
    assert.ok(open > start, m[1]);
    const close = sql.indexOf('$function$', open + 'AS $function$'.length);
    assert.ok(close > open, m[1]);
    out[m[1]] = sql.slice(start, close + '$function$'.length) + '\n';
  }
  return out;
};
const code = (sql) => sql.replace(/CREATE OR REPLACE FUNCTION[\s\S]*?\$function\$;/g, '').replace(/--.*$/gm, '');

test('migraatio: F1–F10 ja apufunktio = odotettu md5, vartija hyväksyy tuotannon tai booking_187:n, riippuvuudet tarkasti', () => {
  const sql = rd(MIG);
  const b = bodies(sql);
  assert.equal(md5(b['booking._order_pays_by_invoice']), HELPER);
  assert.match(sql, /revoke all on function booking\._order_pays_by_invoice\(text, jsonb\) from public, anon, authenticated/);
  for (const [fn, [prod, after]] of Object.entries(REPLACED)) {
    assert.equal(md5(b[fn]), after, fn);
    assert.ok(sql.includes(`'${prod}'`) && sql.includes(`'${after}'`), `${fn} vartija`);
  }
  for (const [fn, hash] of Object.entries(DEPS)) assert.ok(sql.includes(`'${hash}'`), fn);
  const bare = code(sql);
  assert.doesNotMatch(bare, /integration_config|update booking\.settings|price|vat_rate|procountor|site_base_url/i);
  assert.match(sql, /coalesce\(new\.billing ->> 'invoice_method', ''\) <> 'online'/);
  assert.match(b['booking._clean_company'], /'einvoice', 'pdf', 'online'/);
  assert.match(b['booking.public_create_booking'], /v_online := v_is_company and lower\(btrim\(coalesce\(p_company ->> 'invoice_method', ''\)\)\) = 'online'/);
  assert.match(b['booking.public_create_treatment_booking'], /v_pay_method := case when v_invoice then 'invoice' else 'pay_later' end/);
  assert.match(b['booking.vismapay_payment_prepare'], /booking\._order_pays_by_invoice\(o\.customer_kind, o\.billing\)/);
  assert.doesNotMatch(sql, /CREATE OR REPLACE FUNCTION booking\.mobilepay_payment_prepare/);
  assert.doesNotMatch(sql, /CREATE OR REPLACE FUNCTION booking\.public_create_booking_code/);
  assert.doesNotMatch(sql, /CREATE OR REPLACE FUNCTION booking\._order_invoice_locked/);
});

test('rollback: palauttaa tuotannon rungot ja pudottaa apufunktion vasta F5–F7:n jälkeen', () => {
  const sql = rd(RB);
  const b = bodies(sql);
  for (const [fn, [prod, after]] of Object.entries(REPLACED)) {
    assert.equal(md5(b[fn]), prod, fn);
    assert.ok(sql.includes(prod) && sql.includes(after), fn);
  }
  const dropAt = sql.indexOf('drop function if exists booking._order_pays_by_invoice');
  const visma = sql.indexOf('CREATE OR REPLACE FUNCTION booking.vismapay_payment_prepare');
  const opts = sql.indexOf('CREATE OR REPLACE FUNCTION booking.public_payment_options');
  const link = sql.indexOf('CREATE OR REPLACE FUNCTION booking.public_payment_link_info');
  assert.ok(visma > 0 && opts > visma && link > opts && dropAt > link);
  assert.match(sql, /invoice_method='online'/);
});

test('kauppa: kolme radiota, online piilottaa OVT:n, huomautus ja nappi vaihtuvat', () => {
  const shop = rd('booking/shop/src/shop.js');
  const i18n = rd('booking/shop/src/i18n.js');
  const tr = rd('booking/shop/src/treatment-ui.js');
  assert.match(shop, /\['online', t\.invoiceMethodOnline\]/);
  assert.match(shop, /data-testid': `invoice-method-\$\{m\}`/);
  assert.match(shop, /einvoiceBox\.hidden = invoiceMethod !== 'einvoice'/);
  assert.match(shop, /el\.required = kind === 'company' && invoiceMethod === 'einvoice'/);
  assert.match(shop, /invoice_method: invoiceMethod, einvoice_address: ei \? normOvt/);
  assert.match(shop, /invoiceMethod === 'online' \? t\.companyOnlineNote : t\.companyInvoiceMethodNote/);
  assert.match(shop, /invoiceMethod: \(\) => invoiceMethod/);
  assert.match(shop, /paysOnline\(\) && hmode\.on \? ht\(S\.lang, 'checkout\.button'\) : t\.book/);
  assert.match(shop, /paysByInvoice\(b\)/);
  assert.match(i18n, /invoiceMethodOnline: 'Maksa verkossa'/);
  assert.match(i18n, /companyOnlineNote: 'Siirryt maksamaan verkossa tilauksen jälkeen\.'/);
  assert.match(i18n, /invoiceMethodOnline: 'Pay online'/);
  assert.match(i18n, /invalid_invoice_method: 'Valitse laskutustapa\.'/);
  assert.match(tr, /formPaysOnline/);
  assert.match(tr, /data-testid': 'review-online-note'/);
  assert.match(tr, /onlinePay && hi\.on \? ht\(S\.lang, 'checkout\.button'\) : t\.book/);
  assert.match(rd('booking/shop/src/pay-choices.js'), /!paysByInvoice\(booking\)/);
  assert.match(rd('booking/shop/src/treatment-mock.js'), /paysInvoice \? 'invoice' : 'pay_later'/);
  assert.match(rd('booking/shop/src/order-mock.js'), /invoice_method = 'einvoice'/);
  assert.match(rd('booking/shop/src/order-api.js'), /invoice_method: r\.invoice_method/);
});

test('paysByInvoice ja formPaysOnline: verkkomaksava yritys kuten yksityinen, laskuyritys ei', () => {
  assert.equal(paysByInvoice({ customer_kind: 'private' }), false);
  assert.equal(paysByInvoice({ customer_kind: 'company', invoice_method: 'einvoice' }), true);
  assert.equal(paysByInvoice({ customer_kind: 'company', invoice_method: 'pdf' }), true);
  assert.equal(paysByInvoice({ customer_kind: 'company', invoice_method: null }), true);
  assert.equal(paysByInvoice({ customer_kind: 'company', invoice_method: 'online' }), false);
  assert.equal(paysByInvoice(null), false);
  const online = { kind: 'company', invoiceMethod: () => 'online' };
  const pdf = { kind: 'company', invoiceMethod: () => 'pdf' };
  assert.equal(formPaysOnline({ kind: 'private', invoiceMethod: () => 'einvoice' }), true);
  assert.equal(formPaysOnline(online), true);
  assert.equal(formPaysOnline(pdf), false);
  assert.equal(formPaysOnline({ kind: 'company', invoiceMethod: () => 'einvoice' }), false);
});

test('hallinta: normOrder.billing_method ja tekstit kolmelle arvolle, null ei näytä riviä', () => {
  const o = normOrder({ order_id: 1, order_no: 2, customer: { customer_kind: 'company' }, billing: { invoice_method: 'online' }, balance: {} });
  assert.equal(o.customer_kind, 'company');
  assert.equal(o.billing_method, 'online');
  assert.equal(normOrder({ order_id: 1, customer: { customer_kind: 'company' }, balance: {} }).billing_method, null);
  assert.equal(normOrder({ order_id: 1, customer_kind: 'private', billing: { invoice_method: 'pdf' }, balance: {} }).billing_method, 'pdf');
  setLang('fi');
  assert.equal(billingMethodText('online'), 'Verkkomaksu (ei laskua)');
  assert.equal(billingMethodText('einvoice'), 'Verkkolasku');
  assert.equal(billingMethodText('pdf'), 'PDF-lasku sähköpostiin');
  assert.equal(billingMethodText('company_details'), 'Yritysasiakas – yritystiedot');
  setLang('en');
  assert.equal(billingMethodText('online'), 'Online payment (no invoice)');
  setLang('fi');
  const orders = rd('booking/admin/views/talous-orders.js');
  const shared = rd('booking/admin/views/shared.js');
  assert.match(orders, /data-testid': 'order-billing-method'/);
  assert.match(orders, /o\.customer_kind === 'company' \? o\.billing_method : null/);
  assert.match(shared, /data-testid': 'res-billing-method'/);
  assert.match(shared, /online \? billingMethodText\('company_details'\) : 'Yritysasiakas – laskutustiedot'/);
  assert.match(shared, /online \? \[\] : dd\('Verkkolasku'/);
  assert.equal(BILLING_METHOD_TEXTS.fi.online, 'Verkkomaksu (ei laskua)');
  assert.equal(BILLING_METHOD_TEXTS.en.label, 'Billing method');
});

test('tekstit: pending-import-83 FI+EN, max_len, ei päällekkäin, sama kuin koodin oletus', async () => {
  const rows = JSON.parse(rd('content/site-texts.pending-import-83.json'));
  assert.equal(rows.length, 14);
  const keys = [...new Set(rows.map((r) => r.key))];
  assert.deepEqual(keys.sort(), [
    'ui.admin.billing_method.company_details', 'ui.admin.billing_method.einvoice', 'ui.admin.billing_method.label',
    'ui.admin.billing_method.online', 'ui.admin.billing_method.pdf', 'ui.shop.company_online_note', 'ui.shop.invoice_method_online',
  ].sort());
  const { collectDefaults } = await import('../shop/src/text-registry.js');
  const def = new Map(collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  for (const r of rows) {
    assert.ok(['fi', 'en'].includes(r.lang));
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.ok(r.max_len >= r.text.length, r.key);
    assert.equal(r.reason, 'booking_187: yrityksen verkkomaksu');
    if (r.key.startsWith('ui.shop.')) assert.equal(r.text, def.get(`${r.key}|${r.lang}`), `${r.key} ${r.lang}`);
    if (r.key.startsWith('ui.admin.')) {
      const k = r.key.split('.').pop();
      assert.equal(r.text, BILLING_METHOD_TEXTS[r.lang][k], r.key);
    }
  }
  for (const k of keys) assert.equal(rows.filter((r) => r.key === k).length, 2, k);
  const others = readdirSync(join(root, 'content')).filter((f) => /^site-texts\.(pending-import|imported|fallback).*\.json$/.test(f) && f !== 'site-texts.pending-import-83.json');
  for (const f of others) {
    const raw = JSON.parse(rd(`content/${f}`));
    const list = Array.isArray(raw) ? raw : raw.texts || [];
    for (const r of list) assert.ok(!keys.includes(r?.key), `${r?.key} on jo ${f}`);
  }
});

test('order_confirmation-pohja ei sano lasku eikä invoice', () => {
  const src = rd('booking/supabase/functions/send-emails/templates.ts');
  const start = src.indexOf('case "order_confirmation"');
  const end = src.indexOf('case "product_message"', start);
  const slice = src.slice(start, end);
  assert.ok(start > 0 && end > start);
  assert.doesNotMatch(slice, /lasku|invoice/i);
});
