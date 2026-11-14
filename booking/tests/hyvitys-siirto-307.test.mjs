// booking_307: (2) hyvitys lahjakortti-/kumppaniosuuden tilauksessa leikataan rahaosuuteen, (4) yleisen vuoron siirto vain kerran,
// sekä asiakkaan muutosnäkymän tekstit (tuonti 153: not_classified, too_late_private myös uudelle päivälle, already_moved).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { REDUCE_TEXTS, rt } from '../shop/src/reduce-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const migDir = 'booking/supabase/migrations';
const mig = readdirSync(join(root, migDir)).find((f) => f.includes('_booking_307_'));
const rbFile = readdirSync(join(root, 'booking/supabase/rollbacks')).find((f) => f.includes('_booking_307_ROLLBACK'));

test('migraatio 307: yksi tiedosto, rollback olemassa, md5-esiehdot, ei lippuja eikä public-skeemaa', () => {
  assert.ok(mig, 'migraatio puuttuu'); assert.ok(rbFile, 'rollback puuttuu');
  assert.equal(readdirSync(join(root, migDir)).filter((f) => f.includes('_booking_307_')).length, 1);
  const s = read(`${migDir}/${mig}`);
  for (const f of ['_refund_allocate', 'admin_change_booking', '_change_booking_core', 'public_change_booking']) assert.match(s, new RegExp(`booking_307: booking\\.${f} md5`), f);
  assert.doesNotMatch(s, /update booking\.settings|insert into booking\.settings/i, 'ei lippumuutoksia');
  assert.doesNotMatch(s, /\bpublic\.[a-z_]+/i, 'ei public-skeemaa');
  assert.doesNotMatch(s, /update\s+kb\.|insert into kb\.|vat_rate|update booking\.schedule_rules/i, 'ei hinta-/ALV-muutoksia');
  assert.match(s, /revoke all on function booking\._customer_move_blocked\(bigint\) from public, anon, authenticated/);
  const rb = read(`booking/supabase/rollbacks/${rbFile}`);
  assert.match(rb, /drop function booking\._customer_move_blocked\(bigint\)/);
  assert.match(rb, /d6d5da3dc9c44e195a473b01e0825b69/); assert.match(rb, /5b29ef6f52316114896763d865a37205/);
  assert.equal(rb.split('\n')[0].slice(0, 22), '-- booking_307 ROLLBAC');
});

test('korjaus 2: leikkaus vain lahjakortti-/kumppaniosuudella, ei peruutustilassa, lahjakorttia ei palauteta', () => {
  const s = read(`${migDir}/${mig}`);
  assert.match(s, /if p_cancel_mode or not v_gp_share then perform booking\._err\('amount_exceeds_refundable'/);
  assert.match(s, /p_amount := round\(greatest\(v_max, 0\), 2\);/);
  assert.match(s, /v_skip := 'no_money_share'/);
  assert.match(s, /'refund_capped'/);
  assert.doesNotMatch(s.split('create or replace function booking._change_booking_core')[0], /_gc_return_to_card/i, 'lahjakorttiosuutta ei palauteta lahjakortille');
});

test('korjaus 4: siirto vain kerran asiakaspolulla, henkilökunta ohittaa, koskee general-ryhmää', () => {
  const s = read(`${migDir}/${mig}`);
  assert.match(s, /if p_notice_hours is not null and rs\.o_starts_at is distinct from res\.starts_at and booking\._customer_move_blocked\(res\.id\)/);
  assert.match(s, /'code', 'already_moved'/);
  assert.match(s, /pc\.cancellation_tier = 'general'/);
  assert.match(s, /a\.action = 'CUSTOMER_CHANGE'/);
});

test('tekstit 153: FI = EN, paikkamerkit, REDUCE_TEXTS täsmää, kauppa käyttää uusia avaimia', () => {
  const rows = JSON.parse(read('content/site-texts.pending-import-153.json'));
  assert.equal(rows.length, 6);
  for (const r of rows) {
    assert.ok(r.key.startsWith('ui.public.order_change.reduce.'), r.key);
    assert.equal(r.text, REDUCE_TEXTS[r.lang][r.key.replace('ui.public.order_change.reduce.', '')], r.key);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((x) => x[0]), r.key);
    assert.ok(r.text.length <= r.max_len, r.key);
    assert.doesNotMatch(r.text, /<|>|https?:|\{count\}|koulutus/i, r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
  }
  const old139 = JSON.parse(read('content/site-texts.pending-import-139.json')).map((r) => `${r.key}|${r.lang}`);
  for (const r of rows) assert.ok(!old139.includes(`${r.key}|${r.lang}`), `uusi avain ${r.key} (tuonti ei päivitä olemassa olevaa)`);
  assert.equal(rt('fi', 'not_allowed_deadline_private_both', { days: 14 }).includes('sekä nykyisen että uuden ajan alkuun on vähintään 14 vrk'), true);
  const shop = read('booking/shop/src/shop.js');
  assert.match(shop, /reason === 'too_late_private'\) return rt\(S\.lang, 'not_allowed_deadline_private_both'/);
  assert.match(shop, /reason === 'not_classified'\) return rt\(S\.lang, 'not_allowed_not_classified'\)/);
  assert.match(shop, /r\.code === 'already_moved' \? rt\(S\.lang, 'already_moved'\)/);
});
