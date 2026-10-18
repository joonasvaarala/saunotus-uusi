// Laskutus: viite, OVT, maksutila invoiced, tekstit ja migraatiot. Ei tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fiReference, validBusinessId, validOvt, validOperator } from '../shop/src/invoice-validate.js';
import { createAdminMock } from '../admin/options-mock.js';
import { matchesPaymentFilter, PAYMENT_FILTERS } from '../admin/orders-filter.js';
import { PAY } from '../admin/views/talous-ui.js';
import { TEXTS } from '../admin/talous-texts.js';

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
