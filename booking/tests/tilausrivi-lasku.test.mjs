// Tilauslistan laskukentät (booking_270): normalisointi, riviteksti, mock ja migraatio. Ei tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { invoiceText } from '../admin/invoices-texts.js';
import { orderInvoiceCaption } from '../admin/order-invoice-label.js';
import { normOrderRow } from '../admin/talous-api.js';
import { createMock } from '../admin/talous-mock.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const mig = 'supabase/migrations/20261110024450_booking_270_admin_list_orders_invoice_fields.sql';
const rb = 'supabase/rollbacks/20261110024450_booking_270_ROLLBACK.sql';

test('orderInvoiceCaption: numero + tila, ilman numeroa pelkkä tila, ilman kenttiä ei roskaa', () => {
  assert.equal(orderInvoiceCaption({ invoice_no: 'L000001', invoice_status: 'sent' }), 'L000001 / Lähetetty');
  assert.equal(orderInvoiceCaption({ invoice_status: 'draft' }), 'Luonnos');
  assert.equal(orderInvoiceCaption({ invoice_no: 'L000010', invoice_status: 'paid' }), 'L000010 / Maksettu');
  assert.equal(orderInvoiceCaption({ invoice_no: 'L000020', invoice_status: 'sent', invoice_kind: 'credit' }), 'L000020 / Hyvitys · Lähetetty');
  assert.equal(orderInvoiceCaption({ invoice_status: 'draft', invoice_kind: 'credit' }), 'Hyvitys · Luonnos');
  assert.equal(orderInvoiceCaption({ invoice_no: 'L000008', invoice_status: 'overdue' }), 'L000008 / Erääntynyt');
  assert.equal(orderInvoiceCaption({ invoice_no: 'L000009', invoice_status: 'credited', invoice_kind: 'credit' }), 'L000009 / Hyvitys · Hyvitetty');
  assert.equal(orderInvoiceCaption({ invoice_status: 'voided' }), 'Mitätöity');
  assert.equal(orderInvoiceCaption({}), '');
  assert.equal(orderInvoiceCaption({ invoice_id: 1 }), '');
  assert.equal(orderInvoiceCaption({ invoice_no: '  ', invoice_status: '', invoice_kind: 'debit' }), '');
  assert.equal(orderInvoiceCaption({ invoice_status: 'nope', invoice_kind: 'debit' }), '');
  assert.equal(orderInvoiceCaption(null), '');
  const en = (key) => invoiceText(key, null, 'en');
  assert.equal(orderInvoiceCaption({ invoice_no: 'L000001', invoice_status: 'sent' }, en), 'L000001 / Sent');
  assert.equal(orderInvoiceCaption({ invoice_status: 'draft' }, en), 'Draft');
});

test('normOrderRow kopioi invoice-kentät ja sietää niiden puuttumisen', () => {
  const withInv = normOrderRow({
    order_id: 15051, order_no: 15051, total: 10, paid: 0, unpaid: 10,
    invoice_id: 7, invoice_no: 'L000001', invoice_status: 'sent', invoice_kind: 'debit',
  });
  assert.deepEqual(
    [withInv.invoice_id, withInv.invoice_no, withInv.invoice_status, withInv.invoice_kind],
    [7, 'L000001', 'sent', 'debit'],
  );
  const bare = normOrderRow({ order_id: 1, order_no: 2, total: 100, paid: 40, refunded: 5, unpaid: 60 });
  assert.equal(bare.invoice_id, null);
  assert.equal(bare.invoice_no, null);
  assert.equal(bare.invoice_status, null);
  assert.equal(bare.invoice_kind, null);
  assert.equal(bare.total_gross, 100);
});

test('mock palauttaa invoiced-tilauksen invoice-kentillä, paid-suodatin ei sisällä niitä', async () => {
  const mock = createMock({ n: 400, today: '2026-10-18', delay: 0 });
  const invoiced = await mock.rpc('admin_list_orders', { p_payment_filter: 'invoiced', p_limit: 50 });
  assert.ok(invoiced.total > 0);
  assert.ok(invoiced.rows.every((row) => row.payment_status === 'invoiced'));
  const numbered = invoiced.rows.find((row) => row.invoice_no === 'L000001');
  assert.ok(numbered);
  assert.equal(numbered.invoice_status, 'sent');
  assert.equal(numbered.invoice_kind, 'debit');
  assert.ok(numbered.invoice_id);
  const draft = invoiced.rows.find((row) => row.invoice_status === 'draft' && (row.invoice_no == null || row.invoice_no === ''));
  assert.ok(draft);
  const paid = await mock.rpc('admin_list_orders', { p_payment_filter: 'paid', p_limit: 50 });
  assert.ok(paid.rows.every((row) => row.payment_status === 'paid' || row.payment_status === 'partially_refunded'));
  assert.equal(paid.rows.some((row) => row.payment_status === 'invoiced'), false);
  const unpaid = await mock.rpc('admin_list_orders', { p_payment_filter: 'unpaid', p_limit: 100 });
  assert.equal(unpaid.rows.some((row) => row.payment_status === 'invoiced'), false);
  const paidWithInvoice = mock.orders.find((o) => o.invoice_no === 'L000010' && o.payment_status === 'paid');
  assert.ok(paidWithInvoice);
  const listed = await mock.rpc('admin_list_orders', { p_payment_filter: 'paid', p_search: String(paidWithInvoice.order_no), p_limit: 10 });
  assert.equal(listed.rows[0].invoice_no, 'L000010');
  assert.equal(listed.rows[0].invoice_status, 'paid');
});

test('booking_270-migraatio on tavu-identtinen ja rollback palauttaa booking_92-funktion', () => {
  const sql = readFileSync(join(root, mig));
  assert.equal(sql.length, 7733);
  assert.equal(createHash('md5').update(sql).digest('hex'), 'c025b560376deb6db93653643c5bbae6');
  assert.match(sql.toString('utf8'), /invoice_id/);
  assert.match(sql.toString('utf8'), /invoice_no/);
  assert.match(sql.toString('utf8'), /invoice_status/);
  assert.match(sql.toString('utf8'), /invoice_kind/);
  const rollback = readFileSync(join(root, rb), 'utf8');
  assert.match(rollback, /20261019011600_booking_92_invoice_checkout/);
  assert.match(rollback, /create or replace function booking\.admin_list_orders\(/i);
  assert.match(rollback, /'receipt_count', p\.rc\) order by p\.rn\)/);
  assert.doesNotMatch(rollback.split('create or replace function')[1], /invoice_id/);
});
