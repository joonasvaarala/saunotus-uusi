import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (rel) => readFileSync(resolve(root, rel), 'utf8');
const mig = 'booking/supabase/migrations/20261025211000_booking_179_upsell_suggestions.sql';
const rollback = 'booking/supabase/rollbacks/20261025211000_booking_179_ROLLBACK.sql';
const texts = 'content/site-texts.pending-import-75.json';

test('migraatio ei määritä olemassa olevia funktioita uudelleen', () => {
  const sql = read(mig).toLowerCase();
  for (const name of ['public_create_booking', 'public_create_booking_code', 'public_add_to_order', '_add_to_order', '_create_legs_booking', 'payments_paid_trg', 'public_get_booking', 'public_get_site_texts', 'public_treatment_availability', '_treatment_slot_check', '_public_pay_json', '_create_link_payment']) {
    assert.doesNotMatch(sql, new RegExp(`create\\s+or\\s+replace\\s+function\\s+booking\\.${name}\\b`), name);
  }
  assert.match(sql, /create function booking\.public_upsell_checkout_attach/);
  assert.match(sql, /discount_code_id/);
  assert.match(sql, /annual_card/);
  assert.match(sql, /option_required/);
  assert.match(sql, /_treatment_availability_core/);
  assert.match(sql, /payment_status/);
  assert.match(sql, /payment_lines/);
  assert.doesNotMatch(sql, /public_treatment_availability\s*\(/);
  assert.match(sql, /enable row level security/);
  assert.match(sql, /set search_path = ''/);
  assert.doesNotMatch(read(mig), /service_role_key|eyJ/);
});

test('rollback poistaa uudet objektit', () => {
  const sql = read(rollback);
  assert.match(sql, /drop table if exists booking\.upsell_events/);
  assert.match(sql, /drop table if exists booking\.product_suggestions/);
  assert.match(sql, /upsell_cutoff_minutes/);
  assert.doesNotMatch(sql.toLowerCase(), /create or replace function booking\.public_create_booking/);
});

test('kassa liittää lisähoidon kerran eikä luo perusvarausta uudelleen', () => {
  const shop = read('booking/shop/src/shop.js');
  const at = shop.indexOf('public_upsell_checkout_attach');
  assert.ok(at > 0);
  assert.equal(shop.indexOf('public_upsell_checkout_attach', at + 1), -1);
  const fail = shop.slice(at, shop.indexOf('location.assign', at));
  assert.match(fail, /if \(!attached\?\.ok\)/);
  assert.match(fail, /return;/);
  assert.doesNotMatch(fail, /rpc\('public_create_booking/);
  assert.match(shop, /confirmationUpsellOrder/);
  assert.match(read('booking/shop/src/order.js'), /orderUpsellSection/);
  assert.match(read('booking/admin/views/products.js'), /ctx\.role === 'admin'/);
  assert.match(read('.github/workflows/pages.yml'), /upsell-179\.test\.mjs/);
  const css = read('booking/shop/src/shop.css');
  const i0 = css.indexOf('/* booking_179');
  const block = css.slice(i0, css.indexOf('/* booking_', i0 + 5));
  assert.ok(block.includes('.bk-upsell-card'));
  assert.doesNotMatch(block, /#c9c0b3|#6b5e52|#fff\b|rgba\(\s*10\s*,\s*20\s*,\s*12|rgba\(\s*0\s*,\s*0\s*,\s*0/i);
  for (const hex of block.match(/#[0-9a-f]{3,8}\b/gi) || []) assert.ok(['#2B3A30', '#F4EFE7', '#7A5530'].includes(hex.toUpperCase()), hex);
});

test('pending-import-75: FI ja EN, max_len, ei päällekkäisiä avaimia', () => {
  const rows = JSON.parse(read(texts));
  assert.equal(rows.length, 70);
  const keys = new Set(rows.map((r) => r.key));
  assert.equal(keys.size, 35);
  for (const key of keys) {
    const pair = rows.filter((r) => r.key === key);
    assert.deepEqual(pair.map((r) => r.lang).sort(), ['en', 'fi']);
    for (const r of pair) {
      assert.equal(r.class, 'normal');
      assert.equal(r.kind, 'plain');
      assert.deepEqual(r.placeholders, []);
      assert.ok(r.text.length > 0 && r.text.length <= r.max_len, `${key} ${r.lang} ${r.text.length}>${r.max_len}`);
      assert.equal(r.text.includes('<'), false, key);
      assert.match(r.reason, /booking_179/);
    }
  }
  const others = readdirSync(resolve(root, 'content')).filter((f) => /^site-texts\.pending-import-\d+\.json$/.test(f) && f !== 'site-texts.pending-import-75.json');
  for (const file of others) {
    const prev = JSON.parse(read(`content/${file}`));
    for (const row of prev) assert.equal(keys.has(row.key), false, `${row.key} in ${file}`);
  }
});
