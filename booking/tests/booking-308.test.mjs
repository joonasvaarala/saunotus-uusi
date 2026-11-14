// booking_308 (Joonas 14.11.2026 klo 9.04): (1) asiakkaan oma pienennys osin lahjakortilla/koodilla maksetussa tilauksessa – vain rahaosuus hyvitetään,
// (2) siirto vain kerran myös yksityisvuoroille + oma siirto ≥ 7 vrk ennen alkua, (3) asiakaspalvelubotin siirto = asiakkaan ainoa siirto,
// (4) admin_cancel_reservation "Hyvitä osa" rajataan rahaosuuteen. Tekstit pending-import-154.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { REDUCE_TEXTS, rt } from '../shop/src/reduce-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const migDir = 'booking/supabase/migrations';
const mig = readdirSync(join(root, migDir)).find((f) => f.includes('_booking_308_'));
const rbFile = readdirSync(join(root, 'booking/supabase/rollbacks')).find((f) => f.includes('_booking_308_ROLLBACK'));
const FUNCS = ['_customer_move_blocked', '_reduce_eval', 'public_change_preview', '_change_booking_core', 'public_change_booking',
  'svc_move_reservation', 'svc_move_reservation_to_rule', 'admin_cancel_reservation'];

test('migraatio 308: yksi tiedosto, rollback, md5-esiehdot 8 funktiolle, ei lippuja, hintoja eikä public-skeemaa', () => {
  assert.ok(mig, 'migraatio puuttuu'); assert.ok(rbFile, 'rollback puuttuu');
  assert.equal(readdirSync(join(root, migDir)).filter((f) => f.includes('_booking_308_')).length, 1);
  assert.equal(mig.slice(0, 14), rbFile.slice(0, 14), 'sama versio');
  assert.ok(mig > readdirSync(join(root, migDir)).find((f) => f.includes('_booking_307_')), 'myöhempi kuin 307');
  const s = read(`${migDir}/${mig}`);
  for (const f of FUNCS) assert.match(s, new RegExp(`booking_308: ${f} md5 % ei vastaa odotettua`), f);
  assert.match(s, /^-- booking_308/); assert.match(s, /set local lock_timeout = '5s';/); assert.match(s.trim(), /notify pgrst, 'reload schema';$/);
  assert.doesNotMatch(s, /public\.|net\.http_post|vault\.|https?:\/\//);
  assert.doesNotMatch(s, /update booking\.settings|_enabled', 'true'|update kb\.|insert into kb\.|update booking\.(products|price|vat)/i, 'ei lippu-, hinta- tai ALV-muutoksia');
  assert.equal((s.match(/insert into booking\.settings/g) || []).length, 1, 'vain uusi asetusrivi');
  assert.match(s, /'customer_move_min_days_private', '7'::jsonb/);
  assert.match(s, /on conflict \(key\) do nothing/);
  assert.match(s, /revoke all on function booking\._customer_move_blocked\(bigint\) from public, anon, authenticated/);
  const rb = read(`booking/supabase/rollbacks/${rbFile}`);
  for (const f of FUNCS) assert.match(rb, new RegExp(`booking_308 ROLLBACK: ${f} md5 % ei palautunut`), f);
  assert.match(rb, /delete from booking\.settings where key = 'customer_move_min_days_private'/);
});

test('(1) pienennys: lahjakortti/kumppanikoodi sallittu, vain rahaosuus hyvitetään, preview_stale vertaa hinnanmuutokseen', () => {
  const s = read(`${migDir}/${mig}`);
  assert.match(s, /v_refund := case when v_gp then round\(greatest\(least\(v_diff, coalesce\(\(booking\._order_refund_info\(o\.id, v_new\) ->> 'refundable_max'\)/);
  assert.match(s, /'non_refundable_amount', round\(v_diff - v_refund, 2\)/);
  assert.match(s, /or not exists \(select 1 from booking\.payments x {3}-- booking_308: vähintään yksi verkkomaksu/);
  assert.match(s, /'non_refundable', case when/);
  assert.match(s, /\+ \(v_ev ->> 'diff'\)::numeric\) > 0\.004 then {3}-- booking_308/);
});

test('(2)(3) siirto kerran: general + private_event, svc-siirrot lasketaan, 7 vrk raja, botti estetty', () => {
  const s = read(`${migDir}/${mig}`);
  assert.match(s, /pc\.cancellation_tier in \('general', 'private_event'\)/);
  assert.match(s, /a\.action in \('CUSTOMER_CHANGE', 'SVC_MOVE_RESERVATION', 'SVC_MOVE_RESERVATION_TO_RULE'\)/);
  assert.doesNotMatch(s.match(/create or replace function booking\._customer_move_blocked[\s\S]*?\$\$;/)[0], /ADMIN_CHANGE'/, 'henkilökunnan siirto ei kuluta');
  assert.equal((s.match(/perform booking\._err\('already_moved', 'Varaus on jo siirretty kerran/g) || []).length, 2, 'molemmat svc-funktiot');
  assert.match(s, /perform booking\._err\('move_too_late_private'/);
  assert.match(s, /'code', 'move_too_late_private'/);
});

test('(4) admin_cancel_reservation: rajaus vain lahjakortti-/kumppaniosuudella, muuten virhe', () => {
  const s = read(`${migDir}/${mig}`);
  assert.match(s, /if jsonb_array_length\(v_gc\) = 0 and coalesce\(v_partner, 0\) <= 0\.004 then\n\s+perform booking\._err\('amount_exceeds_refundable'/);
  assert.match(s, /'refund_capped', v_capped/);
});

test('tekstit 154: FI = EN, paikkamerkit, uudet avaimet, REDUCE_TEXTS täsmää, kauppa käyttää', () => {
  const rows = JSON.parse(read('content/site-texts.pending-import-154.json'));
  assert.equal(rows.length, 4);
  const older = ['139', '153'].flatMap((n) => JSON.parse(read(`content/site-texts.pending-import-${n}.json`))).map((r) => `${r.key}|${r.lang}`);
  for (const r of rows) {
    assert.ok(r.key.startsWith('ui.public.order_change.reduce.'), r.key);
    assert.equal(r.text, REDUCE_TEXTS[r.lang][r.key.replace('ui.public.order_change.reduce.', '')], r.key);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((x) => x[0]), r.key);
    assert.ok(r.text.length <= r.max_len, r.key);
    assert.doesNotMatch(r.text, /<|>|https?:/, r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.ok(!older.includes(`${r.key}|${r.lang}`), `uusi avain ${r.key}`);
  }
  assert.equal(rt('fi', 'move_too_late_private', { days: 7 }), 'Tämän varauksen voi siirtää verkossa viimeistään 7 vrk ennen alkua. Ota yhteyttä sähköpostilla.');
  assert.match(rt('fi', 'preview_refund_partial', { total: '58,00 €', amount: '27,00 €', kept: '2,00 €' }), /Hyvitämme rahana maksetusta osuudesta 27,00 €.*\(2,00 €\) ei hyvitetä/);
  const shop = read('booking/shop/src/shop.js');
  assert.match(shop, /rd\.kept > 0\.004 \? rt\(S\.lang, 'preview_refund_partial'/);
  assert.match(shop, /kept: \+\(ar\?\.non_refundable \|\| 0\)/);
  assert.match(shop, /r\.code === 'move_too_late_private' \? rt\(S\.lang, 'move_too_late_private', \{ days: state\.settings\?\.customer_move_min_days_private \|\| 7 \}\)/);
});
