// booking_309 (Joonas t1738u 14.11.2026): verkkokaupan maksamatta vanhentuneet tilaukset poistuvat näkyvistä + #15210-merkkikorjaus.
// Ajo: node --test booking/tests/vanhentuneet-poisto-309.test.mjs
// SQL-testi booking/supabase/tests/checkout/t309_expired_web_orders_auto_archive.sql ajetaan VAIN paikalliseen kertakäyttökantaan (rollback).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as L from '../admin/order-view-logic.js';
import { cardPaymentStatus } from '../admin/order-card-logic.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');

// #15210 PROD 14.11.2026: lahjakorttiosto 192 €, status expired, payment_status pending (vanhentunut kenttä), maksu visma_pay cancelled,
// _order_balance = { total 192, paid 0, unpaid 0 }
const raw15210 = {
  order_id: 14156, order_no: 15210, status: 'expired', payment_status: 'pending', created_at: '2026-11-14T03:21:56Z', source_channel: 'web', is_native: true,
  customer: { id: 10462, name: 'X' }, overpaid: 0,
  balance: { total: 192, paid: 0, refunded: 0, pending_link: 0, unpaid: 0, net_paid: 0 },
  reservations: [], items: [{ id: 16686, kind: 'gift_card', product_name: 'Lahjakortti', line_total_gross: 192 }], receipts: [], emails: [], requests: [], refunds: [],
  payments: [{ id: 1144, method: 'visma_pay', provider: 'visma_pay', status: 'cancelled', amount: 192, refunded_amount: 0, paid_at: null }],
};

test('#15210: vanhentunut maksamaton tilaus ei saa "Maksettu"-merkkiä', () => {
  const m = L.orderModel(raw15210);
  assert.equal(L.paymentState(m), 'none');
  const keys = L.orderBadges(m).map((b) => b.key);
  assert.ok(keys.includes('status.expired'), keys.join());
  assert.ok(!keys.includes('pay.paid'), 'ei Maksettu: ' + keys.join());
  assert.equal(L.amountSummary(m).state, 'none', 'summalaatikko Ei maksettavaa');
});

test('#15210: kortin maksutila = Ei maksettavaa (ei Maksettu, ei vanhentunut Maksu kesken)', () => {
  const order = { status: 'expired', payment_status: 'pending', total: 192, balance: { total: 192, paid: 0, unpaid: 0, refunded: 0, pending_link: 0 } };
  const p = cardPaymentStatus(order, null);
  assert.equal(p.kind, 'free'); assert.equal(p.label, 'free'); assert.equal(p.badgeClass, 'muted');
  const p2 = cardPaymentStatus({ status: 'expired', payment_status: 'pending', total: 192 }, null);
  assert.equal(p2.kind, 'free', 'ilman saldoa: payment_status pending ei näy Maksu kesken');
  const p3 = cardPaymentStatus({ status: 'cancelled', payment_status: 'unpaid', total: 58, balance: { total: 58, paid: 0, unpaid: 0 } }, null);
  assert.equal(p3.kind, 'free');
});

test('ennallaan: maksettu, peruttu-mutta-maksettu, hyvitetty ja voimassa oleva tilaus', () => {
  const paid = L.orderModel({ ...raw15210, status: 'confirmed', payment_status: 'paid', balance: { total: 192, paid: 192, refunded: 0, unpaid: 0, net_paid: 192 } });
  assert.equal(L.paymentState(paid), 'paid');
  const cancelledPaid = L.orderModel({ ...raw15210, status: 'cancelled', overpaid: 0, balance: { total: 192, paid: 192, refunded: 0, unpaid: 0, net_paid: 192 } });
  assert.equal(L.paymentState(cancelledPaid), 'paid', 'peruttu mutta maksettu (rahat tilillä) näyttää yhä Maksettu');
  const refunded = L.orderModel({ ...raw15210, status: 'cancelled', balance: { total: 192, paid: 192, refunded: 192, unpaid: 0, net_paid: 0 } });
  assert.equal(L.paymentState(refunded), 'refunded');
  const open = L.orderModel({ ...raw15210, status: 'pending', balance: { total: 192, paid: 0, refunded: 0, unpaid: 192, net_paid: 0 } });
  assert.equal(L.paymentState(open), 'unpaid');
  assert.equal(cardPaymentStatus({ status: 'confirmed', total: 50, balance: { total: 50, paid: 50, unpaid: 0 } }).kind, 'paid');
  assert.equal(cardPaymentStatus({ status: 'cancelled', total: 50, balance: { total: 50, paid: 50, unpaid: 0 } }).kind, 'paid');
  assert.equal(cardPaymentStatus({ status: 'confirmed', payment_status: 'pending', total: 50 }).kind, 'pending');
});

const migDir = 'booking/supabase/migrations';
const migName = readdirSync(join(root, migDir)).find((f) => /_booking_309_expired_web_orders_auto_archive\.sql$/.test(f));
const mig = read(`${migDir}/${migName}`);
const rbName = readdirSync(join(root, 'booking/supabase/rollbacks')).find((f) => /_booking_309_ROLLBACK\.sql$/.test(f));
const rb = read(`booking/supabase/rollbacks/${rbName}`);

test('booking_309: rajaus vain verkkokaupan asiakkaan omiin, maksuttomiin, vanhentuneisiin', () => {
  assert.match(mig, /o\.source_channel = 'web' and o\.created_by is null/);
  assert.match(mig, /r\.cancel_reason is distinct from 'hold_expired'/);
  assert.match(mig, /o\.status = 'expired' and not exists \(select 1 from booking\.reservations/);
  assert.match(mig, /p\.status not in \('cancelled', 'failed'\)/);
  for (const t of ['receipts', 'refunds', 'accounting_outbox', 'invoices', 'annual_cards', 'training_participants', 'voucher_claims', 'vc_difference_payments', 'gift_card_ledger', 'email_outbox']) {
    assert.ok(mig.includes(`booking.${t}`), t);
  }
  assert.match(mig, /e\.status in \('pending', 'failed', 'sending'\)/, 'vanhentumisviesti ehtii lähteä ennen arkistointia');
});

test('booking_309: ei fyysistä poistoa, ei rahaa, ei viestejä, ei public-skeemaa; md5-esiehdot ja rollback', () => {
  assert.doesNotMatch(mig.replace(/^--.*$/gm, ''), /delete\s+from\s+booking\.(orders|payments|reservations)/i);
  assert.doesNotMatch(mig, /public\./);
  assert.doesNotMatch(mig.replace(/^--.*$/gm, ''), /_enqueue_email|_enqueue_unpaid_booking_email/);
  assert.match(mig, /archive_reason = 'auto:expired_unpaid'/);
  assert.match(mig, /'ORDER_AUTO_ARCHIVED_EXPIRED'/);
  assert.match(mig, /'late_paid_archived'/);
  assert.match(mig, /expired_unpaid_auto_archive_paused', 'false'::jsonb/);
  for (const m of ['e8a677d847de8669ef8a4070c95abfdd', '3753915f420e2819699a1d08a64e4857', 'b35618b8cd17fa9e7c5902719d0804a2', '716a9f0236789788b7a6c517d7b5a521', '485836577d7cfc06f9de3660d7150844']) {
    assert.ok(mig.includes(m), 'esiehto ' + m);
  }
  assert.match(mig, /exception when others then\s+raise warning 'booking_309/, 'sweep-virhe ei kaada expire_holdsia');
  assert.match(rb, /drop function if exists booking\.expired_web_orders_archive_sweep\(integer\)/);
  assert.match(rb, /archived_at = null/);
});
