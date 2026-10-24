// Yritysasiakashaku (booking_172): Uusi varaus ja Uusi lasku löytävät yritykset myös aiempien tilausten laskutustiedoista
// (Johku-tuonnissa yritys on vain orders.billingissä, asiakasrivi on yhteyshenkilö). Ei tietokantaa eikä selainta
// (SQL: supabase/tests/customers/t172_*.sql paikallisessa PG17:ssä; selain: scripts/e2e-yritysasiakashaku.mjs).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createAdminMock } from '../admin/options-mock.js';
import { searchCustomers, customerHitTitle, customerHitMeta, isOrderCompany } from '../admin/customer-hits.js';
import { INVOICE_TEXTS } from '../admin/invoices-texts.js';
import { NB } from '../admin/nb-texts.js';

const root = dirname(fileURLToPath(import.meta.url));
const repo = join(root, '../..');
const read = (p) => readFileSync(join(root, '..', p), 'utf8');
const MIG = 'supabase/migrations/20261025010500_booking_172_company_customer_search.sql';
const RB = 'supabase/rollbacks/20261025010500_booking_172_ROLLBACK.sql';

test('mock admin_search_customers: yritys löytyy nimellä, y-tunnuksella, yhteyshenkilöllä ja sähköpostilla', async () => {
  const mock = createAdminMock({ delay: 0 });
  for (const q of ['saunaseura', '1234560-4', '12345604', 'Eero', 'laskut@saunaseura']) {
    const rows = await mock.rpc('admin_search_customers', { p_search: q });
    const hit = rows.find((r) => r.company === 'Saunaseura Testi Oy');
    assert.ok(hit, q);
    assert.equal(hit.business_id, '1234560-4');
    assert.equal(hit.customer_kind, 'company');
  }
  const k = await mock.rpc('admin_search_customers', { p_search: 'kioski' });
  assert.ok(k.some((r) => r.source === 'orders' && r.company === 'Nimetön Kioski Ky' && !r.business_id));
  assert.deepEqual(await mock.rpc('admin_search_customers', { p_search: 'x' }), []);
});

test('mock Uusi lasku: tilauksen yritys tulee origin=orders-rivinä verkkolaskutietoineen', async () => {
  const mock = createAdminMock({ delay: 0, role: 'admin' });
  const rows = await mock.rpc('admin_search_invoice_customers', { p_search: 'saunaseura' });
  const hit = rows.find((r) => r.origin === 'orders');
  assert.ok(hit);
  assert.equal(hit.source, 'booking');
  assert.equal(hit.company_name, 'Saunaseura Testi Oy');
  assert.equal(hit.business_id, '1234560-4');
  assert.equal(hit.einvoice_address, '003712345604');
  assert.equal(hit.einvoice_operator, 'E204503');
});

test('searchCustomers: uusi RPC ensin, vanha admin_list_customers jos booking_172 puuttuu', async () => {
  const calls = [];
  const ok = await searchCustomers('oy', async (fn, a) => { calls.push([fn, a]); return [{ source: 'customer', id: 1 }]; });
  assert.deepEqual(ok, [{ source: 'customer', id: 1 }]);
  assert.deepEqual(calls, [['admin_search_customers', { p_search: 'oy', p_limit: 8 }]]);
  calls.length = 0;
  const fb = await searchCustomers('oy', async (fn, a) => { calls.push(fn); if (fn === 'admin_search_customers') throw Object.assign(new Error('nf'), { code: 'PGRST202' }); return [{ id: 2 }]; });
  assert.deepEqual(fb, [{ id: 2 }]);
  assert.deepEqual(calls, ['admin_search_customers', 'admin_list_customers']);
  assert.deepEqual(await searchCustomers('oy', async () => { throw new Error('x'); }), []);
});

test('osumarivin otsikko ja lisätieto', () => {
  const o = { source: 'orders', customer_kind: 'company', company: 'Testi Oy', name: 'Eero', business_id: '1234560-4', email: 'a@b.test' };
  assert.equal(isOrderCompany(o), true);
  assert.equal(customerHitTitle(o), 'Testi Oy (Eero)');
  assert.match(customerHitMeta(o), /^1234560-4 · a@b\.test · /);
  const p = { source: 'customer', customer_kind: 'private', name: 'Aino', email: 'x@y.test', phone: '040', business_id: '1' };
  assert.equal(isOrderCompany(p), false);
  assert.equal(customerHitTitle(p), 'Aino');
  assert.equal(customerHitMeta(p), 'x@y.test · 040');
  for (const lang of ['fi', 'en']) for (const k of ['cu.fromOrders', 'cu.fromOrdersNote']) assert.ok(NB[lang]?.[k] ?? NB[k]?.[lang], `${k} ${lang}`);
});

test('lomake käyttää uutta hakua ja vanha haku on varalla', () => {
  const cf = read('admin/views/customerform.js');
  assert.match(cf, /from '\.\.\/customer-hits\.js'/);
  assert.match(cf, /if \(isOrderCompany\(c\)\) \{ st\.customer = null; cf\.fill\(c\); cf\.existing\(false\)/);
  assert.match(read('admin/customer-hits.js'), /admin_list_customers/);
  assert.match(read('admin/views/invoices.js'), /c\.origin === 'orders'/);
});

test('booking_172 migraatio: md5-vahdit, oikeudet, ei public-skeemaa', () => {
  const s = read(MIG);
  for (const m of ['3d8de7f0154e173583efa97a04616ea7', '0b6a95a0bb492fe96632c719ff72e42c', '007c407a3fb71e6ee9098796ca34f57c', '6ab4f8a588a792ca3af0614a20ceb659']) assert.ok(s.includes(m), m);
  assert.match(s, /set local lock_timeout/i);
  assert.match(s, /revoke all on function booking\._order_company_hits\(text, integer\) from public, anon, authenticated;/);
  assert.match(s, /grant execute on function booking\.admin_search_customers\(text, integer\) to authenticated, service_role;/);
  assert.doesNotMatch(s, /public\./);
  assert.doesNotMatch(s, /admin_list_customers\s*\(/i, 'admin_list_customers ei muutu');
  assert.ok(!readdirSync(join(root, '../supabase/migrations')).some((f) => /booking_17[2-9]/.test(f) && f !== MIG.split('/').pop()));
});

test('booking_172 rollback palauttaa tuotannon admin_search_invoice_customers-määrittelyn sellaisenaan', () => {
  const body = (s) => { const i = s.indexOf('CREATE OR REPLACE FUNCTION booking.admin_search_invoice_customers'); return s.slice(i, s.indexOf('$function$', s.indexOf('$function$', i) + 10) + 10); };
  const rb = read(RB);
  const prod = body(read('supabase/tests/customers/t172_fixture_local.sql'));
  assert.ok(prod.length > 500);
  assert.equal(body(rb), prod);
  assert.match(rb, /drop function if exists booking\.admin_search_customers/i);
  assert.match(rb, /drop function if exists booking\._order_company_hits/i);
});

test('pending-import-66: src_orders FI+EN, sama kuin koodin varateksti', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-66.json'), 'utf8'));
  assert.equal(rows.length, 2);
  for (const r of rows) {
    assert.equal(r.key, 'ui.admin.invoices.src_orders');
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain'); assert.deepEqual(r.placeholders, []);
  }
  assert.deepEqual(rows.map((r) => r.lang).sort(), ['en', 'fi']);
  const src = read('admin/invoices-texts.js');
  for (const r of rows) assert.ok(src.includes(r.text), r.text);
  for (const f of readdirSync(join(repo, 'content')).filter((f) => /pending-import-\d+\.json$/.test(f) && !f.endsWith('-66.json'))) {
    assert.ok(!readFileSync(join(repo, 'content', f), 'utf8').includes('ui.admin.invoices.src_orders'), f);
  }
  assert.ok(INVOICE_TEXTS);
});
