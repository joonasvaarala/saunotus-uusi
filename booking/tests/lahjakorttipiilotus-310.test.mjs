// booking_310 (Joonas 14.11.2026 klo 12.34): peruttu nollaledgerin lahjakorttimaksu ei estä maksamatta vanhentuneen verkkotilauksen piilotusta.
// Ajo: node --test booking/tests/lahjakorttipiilotus-310.test.mjs
// SQL-testi booking/supabase/tests/checkout/t310_gift_card_cancelled_zero_ledger.sql ajetaan VAIN paikalliseen kertakäyttökantaan (rollback).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const migName = readdirSync(join(root, 'booking/supabase/migrations')).find((f) => /_booking_310_gift_card_cancelled_zero_ledger_archivable\.sql$/.test(f));
const mig = read(`booking/supabase/migrations/${migName}`);
const rbName = readdirSync(join(root, 'booking/supabase/rollbacks')).find((f) => /_booking_310_ROLLBACK\.sql$/.test(f));
const rb = read(`booking/supabase/rollbacks/${rbName}`);
const body = (s) => s.replace(/^\s*--.*$/gm, '');

test('booking_310: vain peruttu lahjakorttimaksu, jonka kirjaukset omalle kortille ovat nettona 0, ilman kuitteja/hyvityksiä', () => {
  assert.match(mig, /p\.method = 'gift_card' and p\.status = 'cancelled' and p\.gift_card_id is not null/);
  assert.match(mig, /exists \(select 1 from booking\.gift_card_ledger l where l\.payment_id = p\.id\)/, 'vähintään yksi kirjaus');
  assert.match(mig, /l\.gift_card_id is distinct from p\.gift_card_id/, 'kirjaukset vain maksun omalle kortille');
  assert.match(mig, /\(select sum\(l\.delta\) from booking\.gift_card_ledger l where l\.payment_id = p\.id\) = 0/);
  assert.match(mig, /booking\.receipts rc where rc\.payment_id = p\.id/);
  assert.match(mig, /booking\.refunds rf where rf\.payment_id = p\.id/);
  // muut rahalliset tapaukset estävät edelleen
  assert.match(mig, /p\.status not in \('cancelled', 'failed'\) or coalesce\(p\.refunded_amount, 0\) <> 0/);
  assert.match(mig, /or p\.external_source is not null or p\.method = 'invoice'/);
  assert.match(mig, /coalesce\(\(select sum\(l\.delta\) from booking\.gift_card_ledger l where l\.order_id = o\.id\), 0\) = 0/, 'tilaustason netto 0 ennallaan');
  assert.doesNotMatch(mig, /or p\.paid_at is not null\)\)/, 'vanha ehdoton paid_at-este korvattu');
});

test('booking_310: md5-esiehdot, ei muita muutoksia, rollback 309-tilaan', () => {
  for (const m of ['38d0f4093802da2d8caa5d01561cdde6', 'afe9100c20f3d5083e8494d77a100085', '172f72b8587d232e20914c6214b2b4bf']) assert.ok(mig.includes(m), m);
  assert.equal((body(mig).match(/create or replace function/gi) || []).length, 1, 'vain _expired_web_order_archivable');
  assert.match(mig, /CREATE OR REPLACE FUNCTION booking\._expired_web_order_archivable\(p_order_id bigint\)/);
  assert.doesNotMatch(body(mig), /_customer_archivable\(p_customer_id|marketing_consent|delete\s+from|update\s+booking\.|insert\s+into|public\./i);
  assert.match(mig, /revoke all on function booking\._expired_web_order_archivable\(bigint\) from public, anon, authenticated;/);
  assert.match(mig, /set local lock_timeout/);
  assert.match(rb, /or p\.paid_at is not null\)\)/, 'rollback palauttaa booking_309-ehdon');
  assert.match(rb, /38d0f4093802da2d8caa5d01561cdde6/);
  assert.match(rb, /revoke all on function booking\._expired_web_order_archivable\(bigint\) from public, anon, authenticated;/);
});
