import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (rel) => readFileSync(resolve(root, rel), 'utf8');
const texts = 'content/site-texts.pending-import-81.json';

function fnBody(src, name) {
  const i = src.indexOf(`function ${name}`);
  assert.ok(i > 0, name);
  const rest = src.slice(i + 1);
  const next = rest.search(/\nfunction |\nexport function |\nconst |\nlet /);
  return src.slice(i, i + 1 + (next > 0 ? next : rest.length));
}

test('pending-import-81: kesto ja henkilömäärä, FI ja EN, ei päällekkäisiä avaimia', () => {
  const rows = JSON.parse(read(texts));
  assert.equal(rows.length, 4);
  const keys = new Set(rows.map((r) => r.key));
  assert.deepEqual([...keys].sort(), ['ui.upsell.duration', 'ui.upsell.persons']);
  for (const key of keys) {
    const pair = rows.filter((r) => r.key === key);
    assert.deepEqual(pair.map((r) => r.lang).sort(), ['en', 'fi']);
    for (const r of pair) {
      assert.equal(r.class, 'normal');
      assert.equal(r.kind, 'plain');
      assert.deepEqual(r.placeholders, []);
      assert.ok(r.text.length > 0 && r.text.length <= r.max_len);
      assert.equal(r.text.includes('<'), false);
    }
  }
  const others = readdirSync(resolve(root, 'content')).filter((f) => /^site-texts\.pending-import-\d+\.json$/.test(f) && f !== 'site-texts.pending-import-81.json');
  for (const file of others) {
    const prev = JSON.parse(read(`content/${file}`));
    for (const row of prev) assert.equal(keys.has(row.key), false, `${row.key} in ${file}`);
  }
});

test('tietoikkuna on dialogi ilman ajanvarauksen nappeja, linkki käyttää ui.upsell.read_more', () => {
  const ui = read('booking/shop/src/upsell-ui.js');
  const info = fnBody(ui, 'productInfo');
  assert.match(info, /aria-modal/);
  assert.match(info, /role:'dialog'/);
  assert.match(info, /upsell-info-close/);
  assert.doesNotMatch(info, /bk-upsell-chip|choose_time|public_upsell_add/);
  assert.match(ui, /upsell-intro-more-/);
  assert.match(ui, /t\('read_more'\)/);
  assert.match(ui, /excerpt\(p,L,180,false\)|excerpt\(p, L, 180, false\)/);
  assert.match(read('booking/shop/src/shop.js'), /checkoutUpsellSection\(\{[\s\S]*details:/);
  assert.match(read('.github/workflows/pages.yml'), /upsell-readmore\.test\.mjs/);
});

test('pending-import-82: hoito ja valinta, FI ja EN, ei päällekkäisiä avaimia', () => {
  const file = 'content/site-texts.pending-import-82.json';
  const rows = JSON.parse(read(file));
  assert.equal(rows.length, 4);
  const keys = new Set(rows.map((r) => r.key));
  assert.deepEqual([...keys].sort(), ['ui.upsell.choose_option', 'ui.upsell.option']);
  for (const key of keys) {
    const pair = rows.filter((r) => r.key === key);
    assert.deepEqual(pair.map((r) => r.lang).sort(), ['en', 'fi']);
    for (const r of pair) {
      assert.equal(r.class, 'normal');
      assert.equal(r.kind, 'plain');
      assert.deepEqual(r.placeholders, []);
      assert.ok(r.text.length > 0 && r.text.length <= r.max_len);
      assert.equal(r.text.includes('<'), false);
    }
  }
  const others = readdirSync(resolve(root, 'content')).filter((f) => /^site-texts\.pending-import-\d+\.json$/.test(f) && f !== 'site-texts.pending-import-82.json');
  for (const name of others) {
    const prev = JSON.parse(read(`content/${name}`));
    for (const row of prev) assert.equal(keys.has(row.key), false, `${row.key} in ${name}`);
  }
});

test('pakollinen tuotevalinta näkyy ennen aikoja ja lähtee mukaan', () => {
  const ui = read('booking/shop/src/upsell-ui.js');
  assert.match(ui, /upsell-opt-/);
  assert.match(ui, /option_id/);
  assert.match(ui, /option_code/);
  assert.match(ui, /needsOption/);
  const info = fnBody(ui, 'productInfo');
  assert.match(info, /t\('option'\)/);
  assert.doesNotMatch(info, /bk-upsell-chip|public_upsell_add/);
  const sql = read('booking/supabase/migrations/20261026191928_booking_186_upsell_options.sql');
  assert.doesNotMatch(sql, /not coalesce\(pc\.option_required/);
  assert.match(sql, /price_delta/);
  assert.match(sql, /p_option_id bigint default null/);
  assert.match(sql, /order_invoiced/);
  assert.match(read('booking/supabase/rollbacks/20261026191928_booking_186_ROLLBACK.sql'), /not coalesce\(pc\.option_required, false\)/);
  const t186 = read('booking/supabase/tests/checkout/t186_upsell_options.sql');
  assert.match(t186, /TESTRESULT pass=% fail=%/);
  assert.match(t186, /fixtures\/10_test_helpers\.sql/);
  assert.match(t186, /option_required/);
  assert.match(t186, /order_invoiced/);
  assert.match(t186, /hunajahoito/);
});
