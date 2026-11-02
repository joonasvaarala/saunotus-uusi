// booking_235: botin SQL-rajapinta ei koske hintoihin, ALV:hen, URL:eihin eikä suomeen.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const mig = readFileSync(join(root, 'booking/supabase/migrations/20261102113506_booking_235_svc_move_paid_texts.sql'), 'utf8');
const rb = readFileSync(join(root, 'booking/supabase/rollbacks/20261102113506_booking_235_ROLLBACK.sql'), 'utf8');

const sigs = [
  'booking.svc_move_reservation(bigint, timestamptz, text, text)',
  'booking.svc_mark_order_paid_external(bigint, text, text)',
  'booking.svc_texts_stale_en(integer)',
  'booking.svc_set_product_text_en(bigint, text, text, text)',
];
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

test('booking_235: neljä service_role-funktiota, definer ja tyhjä search_path', () => {
  for (const sig of sigs) {
    assert.match(mig, new RegExp(`function ${esc(sig.split('(')[0])}\\(`));
    assert.match(mig, new RegExp(`revoke all on function ${esc(sig)} from public, anon, authenticated`, 'i'));
    assert.match(mig, new RegExp(`grant execute on function ${esc(sig)} to service_role`, 'i'));
  }
  const bodies = mig.split(/create or replace function /i).slice(1);
  assert.equal(bodies.length, 4);
  for (const body of bodies) {
    assert.match(body, /security definer/i);
    assert.match(body, /search_path to ''/i);
  }
  assert.match(mig, /SVC_MOVE_RESERVATION/);
  assert.match(mig, /SVC_MARK_ORDER_PAID_EXTERNAL/);
  assert.match(mig, /SVC_SET_PRODUCT_TEXT_EN/);
  assert.match(mig, /_resolve_session/);
  assert.match(mig, /_treatment_slot_check/);
  assert.match(mig, /_plan_legs/);
  assert.match(mig, /_text_validate/);
  assert.match(mig, /_text_publish/);
  const code = mig.replace(/^--.*$/gm, '');
  assert.doesNotMatch(code, /_change_booking_core/);
  assert.doesNotMatch(code, /admin_change_booking/);
  assert.doesNotMatch(code, /insert into booking\.payments/i);
  assert.doesNotMatch(mig, /insert into booking\.email_outbox/i);
});

test('booking_235: englannin kirjoitus ei koske hintaa, ALV:tä, URLia, slugia eikä suomea', () => {
  const fn = mig.slice(mig.indexOf('function booking.svc_set_product_text_en'));
  assert.match(fn, /name', 'description', 'short_description', 'duration_text'/);
  assert.match(fn, /invalid_field/);
  assert.match(fn, /facts_changed/);
  assert.match(fn, /p\.price is distinct from v_price/);
  assert.match(fn, /p\.vat_rate is distinct from v_vat/);
  assert.match(fn, /p\.booking_url is distinct from v_url/);
  assert.match(fn, /p\.name is distinct from v_name/);
  assert.doesNotMatch(fn, /set price\s*=/i);
  assert.doesNotMatch(fn, /set vat_rate\s*=/i);
  assert.doesNotMatch(fn, /set slug\s*=/i);
  assert.doesNotMatch(fn, /set active\s*=/i);
});

test('booking_235: rollback pudottaa vain nämä funktiot', () => {
  for (const sig of sigs) {
    assert.match(rb, new RegExp(`drop function if exists ${esc(sig)}`, 'i'));
  }
  assert.doesNotMatch(rb, /\b(delete from|update\s+\w+\.|truncate|alter table)\b/i);
});
