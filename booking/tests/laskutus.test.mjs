// Laskutus: viite, OVT, maksutila invoiced, tekstit ja migraatiot. Ei tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fiReference, validBusinessId, validOvt, validOperator } from '../shop/src/invoice-validate.js';
import { createAdminMock } from '../admin/options-mock.js';
import { matchesPaymentFilter, PAYMENT_FILTERS } from '../admin/orders-filter.js';
import { PAY } from '../admin/views/talous-ui.js';
import { TEXTS } from '../admin/talous-texts.js';
import { customerDirty, routeSearchTerm } from '../admin/invoice-customer-search.js';
import { mapYtjCompany, mapYtjResponse, titleFi, ytjSearchUrl } from '../admin/ytj.js';
import { INVOICE_TEXTS } from '../admin/invoices-texts.js';
import { ICONS } from '../admin/icons.js';
import {
  amountsForLine, catalogPriceString, convertPriceString, filterProducts, invoiceLineAmounts,
  lineToPayload, parseScaled, storedLineFromInput, suggestLines, summarize, validateLine, UNITS,
} from '../admin/invoice-lines.js';

const root = dirname(fileURLToPath(import.meta.url));
const repo = join(root, '../..');
const read = (p) => readFileSync(join(root, '..', p), 'utf8');

test('suomalainen viite ja OVT', () => {
  assert.equal(fiReference('123456'), '1234561');
  assert.equal(fiReference('1'), '0013');
  assert.equal(validBusinessId('0112038-9'), true);
  assert.equal(validBusinessId('1234567-8'), false);
  assert.equal(validOvt('003701120389', '0112038-9'), true);
  assert.equal(validOvt('003700000000', '0112038-9'), false);
  assert.equal(validOperator('003723327487'), true);
  assert.equal(validOperator('A'), false);
});

test('invoiced kulkee suodattimeen ja talouden maksutiloihin', () => {
  assert.ok(PAYMENT_FILTERS.includes('invoiced'));
  assert.equal(matchesPaymentFilter({ payment_status: 'invoiced', status: 'confirmed' }, 'invoiced'), true);
  assert.equal(matchesPaymentFilter({ payment_status: 'invoiced', status: 'confirmed' }, 'paid'), false);
  assert.equal(matchesPaymentFilter({ payment_status: 'invoiced', status: 'confirmed' }, 'unpaid'), false);
  assert.equal(matchesPaymentFilter({ payment_status: 'invoiced', status: 'cancelled' }, 'invoiced'), false);
  assert.ok(PAY.includes('invoiced'));
  assert.ok(TEXTS.fi['pay.invoiced'] && TEXTS.en['pay.invoiced']);
});

test('migraatiot 90–93 ja rollbackit ovat paikallaan', () => {
  for (const f of [
    'supabase/migrations/20261019011400_booking_90_invoices_schema.sql',
    'supabase/migrations/20261019011500_booking_91_invoices_rpc.sql',
    'supabase/migrations/20261019011600_booking_92_invoice_checkout.sql',
    'supabase/migrations/20261019011700_booking_93_invoice_email_dispatch.sql',
    'supabase/rollbacks/20261019011400_booking_90_ROLLBACK.sql',
    'supabase/rollbacks/20261019011500_booking_91_ROLLBACK.sql',
    'supabase/rollbacks/20261019011600_booking_92_ROLLBACK.sql',
    'supabase/rollbacks/20261019011700_booking_93_ROLLBACK.sql',
  ]) assert.ok(read(f).length > 200, f);
  const schema = read('supabase/migrations/20261019011400_booking_90_invoices_schema.sql');
  assert.match(schema, /invoices\.manage/);
  assert.match(schema, /'invoiced'/);
  assert.match(read('supabase/migrations/20261019011500_booking_91_invoices_rpc.sql'), /invoice_normalized/);
  assert.match(read('supabase/migrations/20261019011600_booking_92_invoice_checkout.sql'), /require_einvoice/);
  assert.match(read('supabase/migrations/20261019011700_booking_93_invoice_email_dispatch.sql'), /invoice_pdf/);
  const claim102 = read('supabase/migrations/20261019010200_booking_102_business_quote_notify_payload.sql');
  const claim93 = read('supabase/migrations/20261019011700_booking_93_invoice_email_dispatch.sql');
  const grab = (s) => s.slice(s.indexOf('CREATE OR REPLACE FUNCTION booking.email_outbox_claim'), s.indexOf('end $function$;') + 'end $function$;'.length);
  const invoiceLine = "      'invoice', case when e.kind = 'invoice_pdf' then (select jsonb_build_object('id', inv.id, 'invoice_no', inv.invoice_no, 'public_token', inv.public_token, 'total', inv.total_gross, 'due_date', inv.due_date, 'reference_no', inv.reference_no, 'status', inv.status) from booking.invoices inv where inv.id = nullif(e.payload ->> 'invoice_id', '')::bigint) end,\n";
  assert.equal(grab(claim93).replace(invoiceLine, ''), grab(claim102));
  assert.equal(grab(read('supabase/rollbacks/20261019011700_booking_93_ROLLBACK.sql')), grab(claim102));
  assert.match(claim93, /business_quote_ack', 'business_quote_notify', 'invoice_pdf'/);
  const rpc = read('supabase/migrations/20261019011500_booking_91_invoices_rpc.sql');
  assert.match(rpc, /if i\.kind = 'credit' then perform booking\._err\('invalid_status'/);
  assert.match(rpc, /perform booking\._refresh_order_payment\(i\.order_id\)/);
  assert.match(rpc, /-l\.unit_price_net, l\.vat_rate, -l\.line_net, -l\.line_vat, -l\.line_gross/);
  assert.doesNotMatch(rpc, /-abs\(l\.unit_price_net\)/);
  const checkout = read('supabase/migrations/20261019011600_booking_92_invoice_checkout.sql');
  assert.match(checkout, /raise warning/);
  assert.match(checkout, /audit_log/);
  const t90 = read('supabase/tests/invoices/t90_invoices.sql');
  for (const bit of ['reply_to', 'business_quote_requests', 'payment_status', 'receipts', "p_payment_filter => 'paid'", 'Alennus', 'invalid_status']) {
    assert.match(t90, new RegExp(bit.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});

test('kauppa vaatii verkkolaskun vain uudella avaimella', () => {
  const shop = read('shop/src/shop.js');
  assert.match(shop, /require_einvoice: true/);
  assert.match(shop, /einvoiceTitleRequired/);
  const i18n = read('shop/src/i18n.js');
  assert.match(i18n, /einvoiceTitle: 'Verkkolaskutus \(valinnainen\)'/);
  assert.match(i18n, /einvoiceTitleRequired: 'Verkkolaskutus'/);
});

test('tuontitekstit: lakitekstit protected, erä alle 500', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-13.json'), 'utf8'));
  assert.ok(rows.length > 20 && rows.length <= 500);
  const prot = new Set(rows.filter((r) => r.class === 'protected').map((r) => r.key));
  for (const k of ['ui.admin.invoices.terms', 'ui.admin.invoices.privacy', 'email.invoice.terms', 'email.invoice_pdf.iban', 'email.invoice_pdf.privacy']) {
    assert.ok(prot.has(k), k);
  }
  assert.equal(prot.has('ui.admin.invoices.title'), false);
  const taken = new Set();
  for (const f of ['content/site-texts.pending-import-14.json', 'content/site-texts.imported-pr75.json', 'content/site-texts.imported-pr71.json', 'content/site-texts.imported-pr66.json', 'content/site-texts.imported-pr64.json', 'content/site-texts.imported-pr62.json', 'content/site-texts.imported-pr61.json', 'content/site-texts.imported.json']) {
    for (const r of JSON.parse(readFileSync(join(repo, f), 'utf8'))) taken.add(`${r.key}|${r.lang}`);
  }
  const mainFallback = JSON.parse(readFileSync(join(repo, 'content/site-texts.fallback.json'), 'utf8'));
  const fbRows = Array.isArray(mainFallback) ? mainFallback : mainFallback.texts;
  for (const r of rows) {
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, r.key);
    const fb = fbRows.find((x) => x.key === r.key && x.lang === r.lang);
    if (fb) assert.equal(fb.text, r.text, r.key);
  }
});

test('provider on dry_run-rajapinta ilman Procountor-kutsua', () => {
  const src = read('supabase/functions/_shared/invoice_provider.ts');
  assert.match(src, /export const dryRunProvider/);
  assert.match(src, /mode: "dry_run"/);
  assert.doesNotMatch(src, /procountor\.com|api\.procountor|PROCOUNTOR_/i);
  const edge = read('supabase/functions/invoice-dispatch/index.ts');
  assert.match(edge, /invoice_dispatch_claim/);
  assert.match(edge, /providerFor/);
  assert.doesNotMatch(edge, /procountor\.com|PROCOUNTOR_/i);
});

test('mock: luonnos, verkkolasku dry_run, hyvitys ja virheellinen y-tunnus', async () => {
  const mock = createAdminMock({ delay: 0 });
  await assert.rejects(mock.rpc('admin_save_invoice_customer', { p: { company_name: 'Virhe Oy', business_id: '1234567-8' } }), (e) => e.code === 'invalid_business_id');
  const customer = await mock.rpc('admin_save_invoice_customer', { p: { company_name: 'Havuhattu Testi Oy', business_id: '0112038-9', einvoice_address: '003701120389', einvoice_operator: '003723327487', email: 'aino@example.com' } });
  const draft = await mock.rpc('admin_save_invoice', { p: { customer_id: customer.id, lines: [{ description: 'Saunavuoro', quantity: 2, unit: 'kpl', unit_price_net: 80, vat_rate: 25.5 }] } });
  assert.equal(draft.status, 'draft');
  assert.equal(draft.invoice_no, null);
  assert.equal(draft.total_gross, 200.8);
  const sent = await mock.rpc('admin_send_invoice', { p_id: draft.id, p_einvoice: true, p_email: false });
  assert.equal(sent.invoice_no, 'L000001');
  assert.equal(sent.reference_no, '0013');
  assert.equal(sent.status, 'sent');
  assert.equal(sent.dispatch_status, 'dry_run');
  const paid = await mock.rpc('admin_mark_invoice_paid', { p_id: sent.id });
  assert.equal(paid.status, 'paid');
  const credit = await mock.rpc('admin_credit_invoice', { p_id: paid.id });
  assert.equal(credit.kind, 'credit');
  assert.equal(credit.status, 'draft');
  assert.equal(credit.total_gross, -200.8);
  const rates = await mock.rpc('admin_list_vat_rates');
  assert.deepEqual(rates.rates.filter((r) => r.active).map((r) => r.rate), [0, 13.5, 25.5]);
});

test('hakusana siirtyy tyhjään Yritys- tai Y-tunnus-kenttään', () => {
  assert.deepEqual(routeSearchTerm('  Havu   hattu '), { field: 'company_name', value: 'Havu hattu', filled: true });
  assert.deepEqual(routeSearchTerm('0112038-9'), { field: 'business_id', value: '0112038-9', filled: true });
  assert.deepEqual(routeSearchTerm('FI01120389'), { field: 'business_id', value: '0112038-9', filled: true });
  assert.equal(routeSearchTerm('a').filled, false);
  assert.equal(routeSearchTerm('Uusi Oy', { company_name: 'Vanha Oy' }).filled, false);
  assert.equal(routeSearchTerm('0112038-9', { business_id: '1234567-1' }).filled, false);
  assert.equal(customerDirty({ company_name: 'A Oy', email: 'A@B.FI' }, { company_name: 'A Oy', email: 'a@b.fi' }), false);
  assert.equal(customerDirty({ company_name: 'A Oy', street: 'Katu 2' }, { company_name: 'A Oy', street: 'Katu 1' }), true);
});

test('YTJ-osoite ja vastaus: nimi, Y-tunnus ja postiosoite, ei verkkolaskua', () => {
  assert.match(ytjSearchUrl('Havuhattu'), /name=Havuhattu$/);
  assert.match(ytjSearchUrl('0112038-9'), /businessId=0112038-9$/);
  assert.equal(ytjSearchUrl('x'), '');
  assert.equal(titleFi('SIPOO'), 'Sipoo');
  const mapped = mapYtjCompany({
    businessId: { value: '3018112-1' },
    names: [
      { name: 'VANHA', type: '1', endDate: '2020-01-01', registrationDate: '2010-01-01' },
      { name: 'HAVUHATTU OY', type: '1', registrationDate: '2020-01-02' },
    ],
    addresses: [{
      type: '2', street: 'Hindsbyntie', buildingNumber: '124', co: 'c/o Otto kronqvist', postCode: '04130',
      postOffices: [{ languageCode: '1', city: 'SIPOO' }, { languageCode: '2', city: 'SIBBO' }],
    }],
  });
  assert.equal(mapped.company_name, 'HAVUHATTU OY');
  assert.equal(mapped.business_id, '3018112-1');
  assert.equal(mapped.street, 'c/o Otto kronqvist, Hindsbyntie 124');
  assert.equal(mapped.zip, '04130');
  assert.equal(mapped.city, 'Sipoo');
  assert.equal('einvoice_address' in mapped, false);
  assert.equal(mapYtjResponse({ companies: [mapped && { names: [], businessId: {} }, { names: [{ name: 'Oy', type: '1' }], businessId: { value: '1234567-1' } }] }).length, 1);
});

test('mock: haku, Y-tunnuksen duplikaatti, nimi+sähköposti ja laskukohtainen kuva', async () => {
  const mock = createAdminMock({ delay: 0 });
  const line = { description: 'Saunavuoro', quantity: 1, unit: 'kpl', unit_price_net: 10, vat_rate: 25.5 };
  const first = await mock.rpc('admin_save_invoice_customer', { p: { company_name: 'Havuhattu Testi Oy', business_id: '0112038-9', street: 'Vanha katu 1', email: 'aino@example.com', einvoice_address: '003701120389', einvoice_operator: '003723327487' } });
  const hits = await mock.rpc('admin_search_invoice_customers', { p_search: 'HAVU', p_limit: 8 });
  assert.equal(hits.length, 1);
  assert.equal(hits[0].company_name, 'Havuhattu Testi Oy');
  assert.equal(hits[0].source, 'invoice');
  const book = await mock.rpc('admin_search_invoice_customers', { p_search: 'koivutesti' });
  assert.equal(book.length, 1);
  assert.equal(book[0].source, 'booking');
  assert.equal(book[0].company_name, 'Koivutesti Oy');
  assert.equal(book[0].contact_name, 'Liisa Lasku');
  assert.equal(book[0].phone, '0401234567');
  assert.equal(book[0].street, 'Koivukuja 2');
  assert.equal(book[0].business_id, '1000000-4');
  assert.equal('marketing_consent' in book[0], false);
  const fromBooking = await mock.rpc('admin_save_invoice_customer', { p: { company_name: 'Koivutesti Oy', business_id: '1000000-4', email: 'liisa@t112.test', phone: '0401234567', customer_id: book[0].customer_id } });
  assert.equal(fromBooking.customer_id, 5);
  const after = await mock.rpc('admin_search_invoice_customers', { p_search: 'koivutesti' });
  assert.equal(after[0].source, 'invoice');
  assert.equal(after.some((c) => c.source === 'booking'), false);
  const byDigits = await mock.rpc('admin_search_invoice_customers', { p_search: '01120389' });
  assert.equal(byDigits[0].id, first.id);
  assert.deepEqual(await mock.rpc('admin_search_invoice_customers', { p_search: 'x' }), []);
  await assert.rejects(
    mock.rpc('admin_save_invoice_customer', { p: { company_name: 'Toinen Oy', business_id: 'FI01120389', email: 'b@example.com' } }),
    (e) => {
      assert.equal(e.code, 'customer_exists');
      assert.equal(JSON.parse(e.details.hint).id, first.id);
      return true;
    },
  );
  const person = await mock.rpc('admin_save_invoice_customer', { p: { company_name: 'Matti Meikäläinen', email: 'matti@example.test' } });
  await assert.rejects(
    mock.rpc('admin_save_invoice_customer', { p: { company_name: 'matti meikäläinen', email: 'Matti@example.test' } }),
    (e) => e.code === 'name_email_match' && JSON.parse(e.details.hint).id === person.id,
  );
  const anyway = await mock.rpc('admin_save_invoice_customer', { p: { company_name: 'matti meikäläinen', email: 'Matti@example.test', ack_name_email: true } });
  assert.notEqual(anyway.id, person.id);
  const inv = await mock.rpc('admin_save_invoice', { p: { customer_id: first.id, snapshot_mode: 'invoice', customer_override: { street: 'Vain laskulla 2' }, lines: [line] } });
  assert.equal(inv.customer_snapshot_locked, true);
  assert.equal(inv.customer.street, 'Vain laskulla 2');
  const stored = (await mock.rpc('admin_list_invoice_customers', { p_search: 'Havuhattu' })).find((c) => c.id === first.id);
  assert.equal(stored.street, 'Vanha katu 1');
  const credit = await mock.rpc('admin_credit_invoice', { p_id: (await mock.rpc('admin_mark_invoice_paid', { p_id: (await mock.rpc('admin_send_invoice', { p_id: inv.id, p_einvoice: false })).id })).id });
  assert.equal(credit.customer_snapshot_locked, true);
  assert.equal(credit.customer.street, 'Vain laskulla 2');
});

test('booking_112: haku-RPC, uniikki Y-tunnus, duplikaatti keskeyttää, rollback', () => {
  const sql = read('supabase/migrations/20261019090000_booking_112_invoice_customer_lookup.sql');
  assert.match(sql, /DUPLICATE_BUSINESS_ID/);
  assert.match(sql, /Yhtään riviä ei poistettu/);
  assert.doesNotMatch(sql, /delete from booking\.invoice_customers/i);
  assert.match(sql, /create unique index invoice_customers_business_uidx/);
  assert.match(sql, /customer_snapshot_locked boolean not null default false/);
  assert.match(sql, /create function booking\.admin_search_invoice_customers/);
  for (const name of ['admin_search_invoice_customers', 'admin_save_invoice_customer', 'admin_save_invoice', '_invoice_customer_clean', '_ensure_draft_invoice']) {
    const at = sql.indexOf(`function booking.${name}`);
    assert.ok(at > 0, name);
    const body = sql.slice(at, at + 500);
    assert.match(body, /security definer/i, name);
    assert.match(body, /set search_path = ''/, name);
  }
  assert.match(sql, /perform booking\._require_permission\('invoices\.manage'\)/);
  assert.match(sql, /grant execute on function booking\.admin_search_invoice_customers\(text, integer\) to authenticated, service_role/);
  assert.doesNotMatch(sql, /grant execute on function booking\._ensure_draft_invoice/);
  assert.match(sql, /customer_exists/);
  assert.match(sql, /name_email_match/);
  assert.match(sql, /ack_name_email/);
  const searchAt = sql.indexOf('function booking.admin_search_invoice_customers');
  const searchBody = sql.slice(searchAt, sql.indexOf('create or replace function booking.admin_save_invoice(', searchAt));
  assert.match(searchBody, /booking\.customers/);
  assert.match(searchBody, /'invoice'/);
  assert.match(searchBody, /'booking'/);
  assert.match(searchBody, /anonymized_at is null/);
  assert.doesNotMatch(searchBody, /marketing_consent/);
  assert.match(searchBody, /p_limit integer default 10/);
  const rb = read('supabase/rollbacks/20261019090000_booking_112_ROLLBACK.sql');
  assert.match(rb, /drop index if exists booking\.invoice_customers_business_uidx/);
  assert.match(rb, /drop column if exists customer_snapshot_locked/);
  assert.match(rb, /drop function if exists booking\.admin_search_invoice_customers/);
  assert.match(rb, /create or replace function booking\.admin_save_invoice_customer/);
  assert.match(rb, /create or replace function booking\._ensure_draft_invoice/);
  const t112 = read('supabase/tests/invoices/t112_invoice_customer_lookup.sql');
  for (const bit of ['customer_exists', 'name_email_match', 'ack_name_email', 'customer_snapshot_locked', '1234567-1', 'invoices.manage', 'returned_sqlstate', 'Havu Testi Zz']) {
    assert.match(t112, new RegExp(bit.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.match(t112, /t112_logout\(\);\n  perform public\.t112_ck\(\(select count\(\*\) from booking\.invoice_customers where booking\._norm_business_id/);
  assert.match(t112, /t112_logout\(\);\n  perform public\.t112_ck\(\(select street from booking\.invoice_customers/);
  assert.match(t112, /perform public\.t112_login\(u_mgr\);/);
  const t90 = read('supabase/tests/invoices/t90_invoices.sql');
  assert.match(t90, /1234567-1/);
  assert.match(t90, /2336509-6/);
});

test('pending-import-21 ja näkymä käyttävät samaa hakua kuin Uusi varaus', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-21.json'), 'utf8'));
  assert.ok(rows.length >= 28 && rows.length <= 500);
  const keys = new Set(rows.map((r) => r.key));
  for (const k of ['ui.admin.invoices.find', 'ui.admin.invoices.moved', 'ui.admin.invoices.ytj', 'ui.admin.invoices.only_invoice', 'ui.admin.invoices.need_company', 'ui.admin.invoices.src_booking', 'ui.admin.invoices.src_invoice', 'ui.admin.invoices.phone']) {
    assert.ok(keys.has(k), k);
  }
  for (const r of rows) {
    assert.equal(r.class, 'normal', r.key);
    assert.ok(r.lang === 'fi' || r.lang === 'en', r.key);
    assert.equal(INVOICE_TEXTS[r.lang][r.key], r.text, `${r.key} ${r.lang}`);
  }
  for (const lang of ['fi', 'en']) assert.equal(rows.filter((r) => r.lang === lang).length, keys.size);
  const taken = new Set();
  for (const f of readdirSync(join(repo, 'content'))) {
    if (!/^site-texts\.(pending-import(?!-21)|imported)/.test(f) || !f.endsWith('.json')) continue;
    for (const r of JSON.parse(readFileSync(join(repo, 'content', f), 'utf8'))) taken.add(`${r.key}|${r.lang}`);
  }
  const fb = JSON.parse(readFileSync(join(repo, 'content/site-texts.fallback.json'), 'utf8'));
  const fbRows = Array.isArray(fb) ? fb : fb.texts;
  for (const r of rows) {
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, r.key);
    const hit = fbRows.find((x) => x.key === r.key && x.lang === r.lang);
    assert.equal(hit?.text, r.text, r.key);
  }
  const invoices = read('admin/views/invoices.js');
  assert.match(invoices, /lookupSearch/);
  assert.match(invoices, /admin_search_invoice_customers/);
  assert.match(invoices, /p_limit: 10/);
  assert.match(invoices, /source === 'booking'/);
  assert.match(invoices, /fetchYtj/);
  assert.match(invoices, /invoice-customer-search/);
  assert.match(invoices, /routeSearchTerm/);
  assert.match(invoices, /snapshot_mode/);
  assert.match(invoices, /ack_name_email/);
  const form = read('admin/views/customerform.js');
  assert.match(form, /export function lookupSearch/);
  assert.match(form, /export function customerSearch/);
  assert.match(form, /return lookupSearch\(/);
  assert.match(form, /admin_list_customers/);
  assert.match(form, /customer-search-btn/);
});

test('laskurivin sentit vastaavat _invoice_put_lines-kaavaa', () => {
  const one = amountsForLine({ quantity: '1', priceGross: '18,00', vatRate: '25.5', basis: 'gross' });
  assert.deepEqual([Number(one.net10000), Number(one.netCents), Number(one.vatCents), Number(one.grossCents)], [143400, 1434, 366, 1800]);
  const three = amountsForLine({ quantity: '3', priceGross: '18', vatRate: 25.5, basis: 'gross' });
  assert.deepEqual([Number(three.netCents), Number(three.vatCents), Number(three.grossCents)], [4303, 1097, 5400]);
  const net = amountsForLine({ quantity: '2', priceNet: '80', vatRate: '25,5', basis: 'net' });
  assert.equal(Number(net.grossCents), 20080);
  const saved = lineToPayload({ description: ' Yleinen saunavuoro ', quantity: '1', unit: 'kpl', price_gross: '18,00', vat_rate: '25.5', basis: 'gross' });
  assert.equal(saved.price_basis, 'gross');
  assert.equal(saved.unit_price_gross, 18);
  assert.equal(saved.unit_price_net, 14.34);
  assert.equal(saved.description, 'Yleinen saunavuoro');
  const neg = invoiceLineAmounts(-1, '1.005', 25.5);
  assert.deepEqual([neg.line_net, neg.line_vat, neg.line_gross], [-1.01, -0.26, -1.27]);
  const shelf = invoiceLineAmounts(2, 80, 25.5);
  assert.equal(shelf.line_gross, 200.8);
  const gross64 = storedLineFromInput({ quantity: 1, unitPriceGross: '64,00', vatRate: 25.5, priceBasis: 'gross' });
  assert.deepEqual([gross64.line_gross, gross64.line_vat, gross64.line_net, gross64.unit_price_net], [64, 13, 51, 51]);
  const vichy = storedLineFromInput({ quantity: 3, unitPriceGross: '3,50', vatRate: 13.5, priceBasis: 'gross' });
  assert.deepEqual([vichy.line_gross, vichy.line_vat, vichy.line_net, vichy.unit_price_net], [10.5, 1.25, 9.25, 3.0833]);
  const net100 = storedLineFromInput({ quantity: 1, unitPriceNet: '100,00', vatRate: 25.5, priceBasis: 'net' });
  assert.deepEqual([net100.line_net, net100.line_vat, net100.line_gross, net100.price_basis], [100, 25.5, 125.5, 'net']);
  const zero = storedLineFromInput({ quantity: '2', unitPriceGross: '10', vatRate: 0, priceBasis: 'gross' });
  assert.deepEqual([zero.line_net, zero.line_vat, zero.line_gross, zero.unit_price_net], [20, 0, 20, 10]);
  assert.equal(catalogPriceString(18), '18,00');
  assert.equal(convertPriceString('18,00', 25.5, true, false), '14,3426');
  assert.equal(convertPriceString('14,3426', 25.5, false, true), '18,00');
  const rows = summarize([one, amountsForLine({ quantity: '1', priceGross: '3', vatRate: 13.5, basis: 'gross' })]);
  assert.equal(Number(rows.netCents), 1434 + 264);
  assert.deepEqual(rows.vatByRate.map((r) => Number(r.rateTenths)), [255, 135]);
  assert.equal(parseScaled('1,5', 3), 1500n);
  assert.equal(parseScaled('0', 4), 0n);
  assert.equal(parseScaled('-2', 3), -2000n);
  assert.equal(parseScaled('1,2345', 3), null);
  const rates = [{ rate: 25.5, active: true }, { rate: 13.5, active: true }, { rate: 0, active: true }];
  assert.deepEqual(validateLine({ description: '', quantity: '1', priceGross: '10', vatRate: 25.5, rates, basis: 'gross' }), { description: 'desc' });
  assert.deepEqual(validateLine({ description: 'X', quantity: '0', priceGross: '10', vatRate: 25.5, rates, basis: 'gross' }), { quantity: 'qty' });
  assert.deepEqual(validateLine({ description: 'X', quantity: '', priceGross: '10', vatRate: 25.5, rates, basis: 'gross' }), { quantity: 'qty' });
  assert.deepEqual(validateLine({ description: 'X', quantity: '-1', priceGross: '', priceNet: '', vatRate: 25.5, rates, basis: 'gross' }), { price_net: 'price', price_gross: 'price' });
  assert.deepEqual(validateLine({ description: 'X', quantity: '-1,5', priceGross: '0', vatRate: 25.5, rates, basis: 'gross' }), {});
  assert.equal(validateLine({ description: 'X', quantity: '1', priceGross: '-2,5', vatRate: 0, rates, basis: 'gross' }).price_gross, undefined);
  assert.deepEqual(UNITS, ['kpl', 'h', 'pv', 'hlö', 'krt', 'erä']);
  const products = [{ name: 'Yleinen saunavuoro', price: 18, vat_rate: 25.5, active: true }, { name: 'Käsipyyhe', name_en: 'Hand towel', price: 4, vat_rate: 25.5, active: true }, { name: 'Vanha', active: false }];
  assert.equal(filterProducts(products, 'yle')[0].name, 'Yleinen saunavuoro');
  assert.equal(filterProducts(products, 'towel')[0].name, 'Käsipyyhe');
  assert.equal(filterProducts(products, '').length, 0);
  assert.equal(filterProducts(products, 'vanha').length, 0);
  const none = suggestLines(products, 'oma selite');
  assert.deepEqual(none.products, []);
  assert.equal(none.freeText, 'oma selite');
  const both = suggestLines(products, ' sauna ');
  assert.ok(both.products.some((p) => p.name === 'Yleinen saunavuoro'));
  assert.equal(both.freeText, 'sauna');
  assert.equal(suggestLines(products, '  ').freeText, null);
  const manual = lineToPayload({ description: 'Kuljetus erikseen', quantity: '2', unit: 'kpl', price_gross: '10,50', vat_rate: '13.5', basis: 'gross' });
  assert.equal(manual.description, 'Kuljetus erikseen');
  assert.equal(manual.quantity, 2);
  assert.equal(manual.price_basis, 'gross');
  assert.ok(manual.unit_price_net > 0);
  assert.ok(ICONS.trash);
  const schema = read('supabase/migrations/20261019011400_booking_90_invoices_schema.sql');
  assert.match(schema, /quantity\s+numeric\(12,3\) not null check \(quantity <> 0\)/);
  assert.match(schema, /unit_price_net\s+numeric\(12,4\) not null/);
  assert.match(schema, /vat_rate\s+numeric\(5,2\) not null/);
  assert.match(schema, /line_gross\s+numeric\(12,2\) not null/);
  const pdf = read('supabase/functions/invoice-pdf/render.ts');
  assert.match(pdf, /l\.description.*l\.quantity.*l\.line_gross/s);
  assert.match(pdf, /unitPrice\(l\.unit_price_net/);
  assert.match(pdf, /toFixed\(4\)/);
});

test('pending-import-22 ja laskurivin lomake', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-22.json'), 'utf8'));
  assert.equal(rows.length, 30);
  const keys = new Set(rows.map((r) => r.key));
  for (const k of ['ui.admin.invoices.lines', 'ui.admin.invoices.line_product', 'ui.admin.invoices.free_text', 'ui.admin.invoices.price_gross', 'ui.admin.invoices.price_net', 'ui.admin.invoices.prices_include', 'ui.admin.invoices.line_sum', 'ui.admin.invoices.remove_line', 'ui.admin.invoices.err_desc', 'ui.admin.invoices.err_qty', 'ui.admin.invoices.err_price', 'ui.admin.invoices.total_net', 'ui.admin.invoices.vat_pct']) {
    assert.ok(keys.has(k), k);
  }
  for (const r of rows) {
    assert.equal(r.class, 'normal', r.key);
    assert.equal(r.kind, 'plain', r.key);
    assert.ok(r.lang === 'fi' || r.lang === 'en');
    assert.deepEqual(r.placeholders, []);
    assert.equal(INVOICE_TEXTS[r.lang][r.key], r.text, `${r.key} ${r.lang}`);
    assert.equal(r.text.includes('{{'), false, r.key);
  }
  for (const lang of ['fi', 'en']) assert.equal(rows.filter((r) => r.lang === lang).length, keys.size);
  const taken = new Set();
  for (const f of readdirSync(join(repo, 'content'))) {
    if (!/^site-texts\.(pending-import(?!-22)|imported)/.test(f) || !f.endsWith('.json')) continue;
    for (const r of JSON.parse(readFileSync(join(repo, 'content', f), 'utf8'))) taken.add(`${r.key}|${r.lang}`);
  }
  const fb = JSON.parse(readFileSync(join(repo, 'content/site-texts.fallback.json'), 'utf8'));
  const fbRows = Array.isArray(fb) ? fb : fb.texts;
  for (const r of rows) {
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, r.key);
    const hit = fbRows.find((x) => x.key === r.key && x.lang === r.lang);
    assert.equal(hit?.text, r.text, r.key);
  }
  const invoices = read('admin/views/invoices.js');
  assert.match(invoices, /mountInvoiceLines/);
  assert.match(invoices, /admin_list_products/);
  assert.match(invoices, /invoice_due_days/);
  assert.match(invoices, /todayHel\(\)/);
  assert.match(invoices, /inv-savebar/);
  assert.match(invoices, /lookupSearch/);
  assert.doesNotMatch(invoices, /unit_price_net: Number/);
  const css = read('admin/admin.css');
  const formJs = read('admin/invoice-line-form.js');
  assert.match(formJs, /suggestLines/);
  assert.match(formJs, /invoice-free-text/);
  assert.match(formJs, /acceptFree/);
  assert.doesNotMatch(formJs, /Lisää tekstirivi/);
  assert.match(css, /\.inv-line\{/);
  assert.match(css, /inv-savebar/);
  assert.doesNotMatch(css, /inv-lines \.row>\*\{flex:1 1 7\.5rem/);
});

test('pending-import-23 ja hintaperuste booking_113', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-23.json'), 'utf8'));
  assert.equal(rows.length, 6);
  const keys = new Set(rows.map((r) => r.key));
  assert.deepEqual([...keys].sort(), ['ui.admin.invoices.price_either', 'ui.admin.invoices.unit_gross', 'ui.admin.invoices.unit_net']);
  for (const r of rows) {
    assert.equal(r.class, 'normal', r.key);
    assert.equal(r.kind, 'plain', r.key);
    assert.ok(r.lang === 'fi' || r.lang === 'en');
    assert.deepEqual(r.placeholders, []);
    assert.equal(INVOICE_TEXTS[r.lang][r.key], r.text, `${r.key} ${r.lang}`);
    assert.equal(r.text.includes('{{'), false, r.key);
  }
  for (const lang of ['fi', 'en']) assert.equal(rows.filter((r) => r.lang === lang).length, keys.size);
  const taken = new Set();
  for (const f of readdirSync(join(repo, 'content'))) {
    if (!/^site-texts\.(pending-import(?!-23)|imported)/.test(f) || !f.endsWith('.json')) continue;
    for (const r of JSON.parse(readFileSync(join(repo, 'content', f), 'utf8'))) taken.add(`${r.key}|${r.lang}`);
  }
  const fb = JSON.parse(readFileSync(join(repo, 'content/site-texts.fallback.json'), 'utf8'));
  const fbRows = Array.isArray(fb) ? fb : fb.texts;
  for (const r of rows) {
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, r.key);
    const hit = fbRows.find((x) => x.key === r.key && x.lang === r.lang);
    assert.equal(hit?.text, r.text, r.key);
  }
  const formJs = read('admin/invoice-line-form.js');
  assert.match(formJs, /invoice-line-price-net/);
  assert.match(formJs, /invoice-line-price-gross/);
  assert.match(formJs, /ui\.admin\.invoices\.unit_net/);
  assert.match(formJs, /ui\.admin\.invoices\.unit_gross/);
  assert.doesNotMatch(formJs, /invoice-prices-include/);
  assert.match(formJs, /suggestLines/);
  assert.match(formJs, /acceptFree/);
  const mig = read('supabase/migrations/20261019150000_booking_113_invoice_price_basis.sql');
  assert.match(mig, /price_basis text not null default 'net'/);
  assert.match(mig, /round\(v_gross \* v_rate \/ \(100 \+ v_rate\), 2\)/);
  assert.match(mig, /v_net := v_gross - v_vat/);
  assert.match(mig, /-l\.unit_price_gross, l\.price_basis/);
  assert.match(mig, /'price_basis', l\.price_basis/);
  assert.doesNotMatch(mig, /update booking\.invoice_lines set/);
  const rb = read('supabase/rollbacks/20261019150000_booking_113_ROLLBACK.sql');
  assert.match(rb, /drop column if exists price_basis/);
  assert.match(rb, /v_net := round\(v_qty \* v_price, 2\)/);
  const sql = read('supabase/tests/invoices/t113_invoice_price_basis.sql');
  for (const bit of ['64.00', '10.50', '125.50', '200.80', 'returned_sqlstate', 't113_logout', 'Gross 64', '3.50', 'Net 100', 'Zero', '64.01']) {
    assert.match(sql, new RegExp(bit.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.doesNotMatch(sql, /_next_invoice_seq|admin_send_invoice/);
  const pro = read('supabase/functions/procountor-sync/invoice.ts');
  assert.match(pro, /unitPricesIncludeVat: pricesIncludeVat/);
  assert.match(pro, /price_basis === "gross"/);
});
