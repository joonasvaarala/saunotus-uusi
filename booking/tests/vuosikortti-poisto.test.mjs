// booking_152: vuosikortin poisto ja peruminen hallinnan Alennuskoodit ja vuosikortit -näkymästä, koodivihje ja Arvo koodi -nappi.
// Rakennetestit: migraatio (funktio, ehdot, oikeudet, search_path), rollback, SQL-testin kattavuus, käyttöliittymän napit ja vihje,
// tekstit (pending-import-52: FI+EN, ei '<', täsmää sanakirjaan, ei päällekkäin), mock, build-lista ja CI.
// SQL-käyttäytyminen testataan PG17:ssä: booking/supabase/tests/discounts/t152_annual_card_delete.sql (CI:ssä ei Postgresia).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { ANNUAL_MANAGE_TEXTS, amText, primeAmTexts, clearAmTextCache, fillAmText } from '../admin/annual-manage-texts.js';
import { createAdminMock } from '../admin/options-mock.js';
import { generatedAnnualCardCode, validCodeFormat } from '../shop/src/discount-code-logic.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(resolve(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024130658_booking_152_annual_card_delete.sql';
const RB = 'booking/supabase/rollbacks/20261024130658_booking_152_ROLLBACK.sql';
const SQLT = 'booking/supabase/tests/discounts/t152_annual_card_delete.sql';
const P52 = 'content/site-texts.pending-import-52.json';
const M142 = 'booking/supabase/migrations/20261024104958_booking_142_annual_cards_discount_codes.sql';
const DISC = rd('booking/admin/views/discounts.js'), CUST = rd('booking/admin/views/customers.js');
const fnBody = (sql, name) => { const m = new RegExp(`create or replace function booking\\.${name}\\([\\s\\S]*?\\nend \\$\\$;`).exec(sql); assert.ok(m, name); return m[0]; };
const norm = (s) => s.replace(/\s+/g, ' ').trim();

test('numerointi: booking_152 ja pending-import-52 olemassa, yksi migraatio', () => {
  for (const f of [MIG, RB, SQLT, P52]) assert.ok(existsSync(resolve(root, f)), f);
  assert.deepEqual(readdirSync(resolve(root, 'booking/supabase/migrations')).filter((f) => /booking_152/.test(f)), ['20261024130658_booking_152_annual_card_delete.sql']);
});

test('migraatio: admin_delete_annual_card – oikeus, ehdot (ei ostotilausta, ei varauksia), selkeät virheet, FK-kilpa, security definer', () => {
  const m = rd(MIG), f = fnBody(m, 'admin_delete_annual_card');
  assert.match(m, /set local lock_timeout = '5s';/);
  assert.match(f, /^create or replace function booking\.admin_delete_annual_card\(p_id bigint\) returns jsonb\s+language plpgsql security definer set search_path = '' as \$\$/);
  assert.match(f, /perform booking\._require_permission\('annual_cards\.manage'\);/);
  assert.ok(f.indexOf("_require_permission('annual_cards.manage')") < f.indexOf('delete from'), 'oikeus ennen poistoa');
  assert.match(f, /where id = p_id for update;/);
  assert.match(f, /booking\._err\('not_found'/);
  assert.match(f, /if c\.purchase_order_id is not null then\s+perform booking\._err\('annual_card_purchased', '[^']*Peru kortti poistamisen sijaan\.'\)/);
  assert.match(f, /if exists \(select 1 from booking\.reservations r where r\.annual_card_id = c\.id\) then\s+perform booking\._err\('annual_card_used', '[^']*Peru kortti poistamisen sijaan\.'\)/);
  assert.doesNotMatch(f, /r\.status|_res_active/, 'kaikki varaukset (myös perutut) estävät poiston');
  assert.match(f, /exception when foreign_key_violation then\s+perform booking\._err\('annual_card_used'/);
  assert.match(f, /delete from booking\.annual_cards where id = c\.id;/);
  assert.doesNotMatch(f, /update booking\.customers|audit_log/, 'asiakastyyppi ja audit tulevat olemassa olevista triggereistä');
  assert.match(m, /revoke all on function booking\.admin_delete_annual_card\(bigint\) from public, anon, service_role;/);
  assert.match(m, /grant execute on function booking\.admin_delete_annual_card\(bigint\) to authenticated;/);
  assert.doesNotMatch(m, /grant [^;]*admin_delete_annual_card[^;]*to [^;]*(anon|public|service_role)/i);
  assert.doesNotMatch(m, /\bpublic\.[a-z_]+/i, 'ei kosketa public-skeemaan');
  assert.doesNotMatch(m, /drop table|alter table|truncate/i);
});

test('migraatio: korttilista saa kentät reservations_count ja deletable, muuten sama kuin booking_142', () => {
  const l = fnBody(rd(MIG), 'admin_list_annual_cards_details');
  assert.match(l, /'reservations_count', n\.cnt/);
  assert.match(l, /'deletable', a\.purchase_order_id is null and n\.cnt = 0\)/);
  assert.match(l, /cross join lateral \(select count\(\*\)::int as cnt from booking\.reservations r where r\.annual_card_id = a\.id\) n/);
  const orig = fnBody(rd(M142), 'admin_list_annual_cards_details');
  for (const k of ['id', 'code', 'customer_id', 'customer_name', 'customer_email', 'valid_from', 'valid_to', 'active', 'revoked_at', 'notes', 'purchase_order_no', 'future_bookings']) {
    assert.ok(orig.includes(`'${k}'`) && l.includes(`'${k}'`), k);
  }
  assert.match(l, /security definer set search_path = ''/);
  assert.match(l, /_require_permission\('annual_cards\.manage'\)/);
});

test('rollback: poisto-funktio pois, korttilista palautuu sanasta sanaan booking_142:n muotoon, uudelleenajettava', () => {
  const r = rd(RB);
  assert.match(r, /drop function if exists booking\.admin_delete_annual_card\(bigint\);/);
  assert.equal(norm(fnBody(r, 'admin_list_annual_cards_details')), norm(fnBody(rd(M142), 'admin_list_annual_cards_details')));
  assert.doesNotMatch(fnBody(r, 'admin_list_annual_cards_details'), /reservations_count|deletable/);
  assert.doesNotMatch(r, /^drop function (?!if exists)/m);
  assert.doesNotMatch(r, /^\s*(grant|revoke) /m, 'create or replace säilyttää booking_142:n oikeudet');
});

test('SQL-testi t152 kattaa poiston, asiakastyypin, auditin, käytetyn, ostetun, oikeudet ja listan kentät', () => {
  const t = rd(SQLT);
  for (const re of [/admin_delete_annual_card/, /customer_type[\s\S]*'customer'/, /audit_log[\s\S]*action = 'DELETE'/, /'annual_card_used'/, /'annual_card_purchased'/,
    /'forbidden'/, /'not_found'/, /has_function_privilege\('anon'/, /has_function_privilege\('authenticated'/, /prosecdef/, /'deletable'/, /'reservations_count'/,
    /admin_create_annual_card_booking/, /admin_revoke_annual_card/, /TESTRESULT/]) assert.match(t, re);
  assert.doesNotMatch(t, /sxbofnuisemspgquoxyv/);
});

test('käyttöliittymä: korttilistassa Peru (samat vahvistukset kuin asiakaskortilla) ja Poista vain kun deletable', () => {
  assert.match(DISC, /cardActions\(a\)\)\) : empty\('Ei vuosikortteja\.'\)/);
  assert.match(DISC, /const revoke = a\.active && !a\.revoked_at \? h\('button'/);
  assert.match(DISC, /confirm\(amText\('ui\.admin\.annual_manage\.revoke_confirm'\)\)/);
  assert.match(DISC, /const cancelFuture = confirm\(amText\('ui\.admin\.annual_manage\.revoke_future_confirm'\)\);/);
  assert.match(DISC, /rpc\('admin_revoke_annual_card', \{ p_id: a\.id, p_cancel_future: cancelFuture \}\)/);
  assert.match(DISC, /const del = a\.deletable === true \? h\('button'/);
  assert.match(DISC, /rpc\('admin_delete_annual_card', \{ p_id: a\.id \}\)/);
  assert.match(DISC, /'data-testid': `annual-delete-\$\{a\.id\}`/);
  assert.match(DISC, /'data-testid': `annual-revoke-\$\{a\.id\}`/);
  // asiakaskortin vahvistukset ovat samat sanamuodot
  assert.match(CUST, /confirm\('Perutaanko vuosikortti\?'\)/);
  assert.equal(ANNUAL_MANAGE_TEXTS.fi['ui.admin.annual_manage.revoke_confirm'], 'Perutaanko vuosikortti?');
  assert.ok(CUST.includes(`confirm('${ANNUAL_MANAGE_TEXTS.fi['ui.admin.annual_manage.revoke_future_confirm']}')`));
  assert.doesNotMatch(DISC, /Peruutus tehdään asiakaskortilta/);
  assert.doesNotMatch(DISC + CUST, /#[0-9a-f]{3,6}\b|style:/i, 'ei kovakoodattuja värejä (teeman luokat btn / danger)');
  assert.doesNotMatch(DISC + CUST, /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u, 'ei emojeja');
});

test('Myönnä vuosikortti -dialogi: Arvo koodi (generatedAnnualCardCode) ja ajantasainen vihje; asiakaskortin vihje sama', () => {
  assert.match(DISC, /import \{ normalizeCode, generatedDiscountCode, generatedAnnualCardCode \} from '\.\.\/\.\.\/shop\/src\/discount-code-logic\.js';/);
  assert.match(DISC, /onclick: \(\) => \{ code\.value = generatedAnnualCardCode\(\); \} \}, amText\('ui\.admin\.annual_manage\.generate'\)\)/);
  assert.match(DISC, /field\(amText\('ui\.admin\.annual_manage\.code_label'\), h\('div', \{ class: 'row wrap' \}, code, gen\), amText\('ui\.admin\.annual_manage\.code_hint'\)\)/);
  assert.match(CUST, /amText\('ui\.admin\.annual_manage\.code_hint'\)/);
  assert.doesNotMatch(DISC + CUST, /luontosana|Tyhjä = palvelin luo koodin/);
  assert.match(ANNUAL_MANAGE_TEXTS.fi['ui.admin.annual_manage.code_hint'], /10 merkin satunnaiskoodin \(esim\. TS5DSYAH2X\)/);
  assert.match(ANNUAL_MANAGE_TEXTS.en['ui.admin.annual_manage.code_hint'], /random 10-character code \(e\.g\. TS5DSYAH2X\)/);
  assert.ok(validCodeFormat('TS5DSYAH2X'));
  for (let i = 0; i < 50; i++) assert.match(generatedAnnualCardCode(), /^[A-HJKMNP-Z2-9]{10}$/);
  assert.match(DISC, /loadAmTexts\(rpc\)/); assert.match(CUST, /loadAmTexts\(rpc\)/);
});

test('tekstit: ui.admin.annual_manage.* FI+EN, pending-import-52 täsmää sanakirjaan, ei < eikä emojeja, ei päällekkäin muiden tuontien kanssa', () => {
  const rows = JSON.parse(rd(P52));
  assert.deepEqual(Object.keys(ANNUAL_MANAGE_TEXTS.fi).sort(), Object.keys(ANNUAL_MANAGE_TEXTS.en).sort());
  assert.equal(rows.length, Object.keys(ANNUAL_MANAGE_TEXTS.fi).length * 2);
  const seen = new Set();
  for (const r of rows) {
    const w = `${r.key} [${r.lang}]`;
    assert.ok(r.key.startsWith('ui.admin.annual_manage.'), w);
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.equal(r.text, ANNUAL_MANAGE_TEXTS[r.lang][r.key], w);
    assert.equal(r.class, 'normal', w); assert.equal(r.kind, 'plain', w);
    assert.ok(r.max_len >= r.text.length && r.max_len >= 80, w);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((m) => m[0]), w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.doesNotMatch(r.text, /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u, w);
    assert.ok(r.reason, w);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), w); seen.add(`${r.key}|${r.lang}`);
  }
  const taken = new Set();
  for (const f of readdirSync(resolve(root, 'content'))) {
    if (!/^site-texts\.(pending-import-(?!52\.)|imported|fallback)/.test(f) || !f.endsWith('.json')) continue;
    const j = JSON.parse(rd(`content/${f}`));
    for (const r of Array.isArray(j) ? j : j.texts || []) taken.add(`${r.key}|${r.lang}`);
  }
  for (const k of seen) assert.equal(taken.has(k), false, `${k} on jo toisessa tuonnissa`);
});

test('tekstien haku: sanakirja varalla, tietokannan rivi voittaa, rikkinäinen paikkamerkki → sanakirja', () => {
  clearAmTextCache();
  assert.equal(amText('ui.admin.annual_manage.delete', null, 'fi'), 'Poista');
  assert.equal(amText('ui.admin.annual_manage.delete', null, 'en'), 'Delete');
  assert.equal(amText('ui.admin.annual_manage.revoked_with_bookings', { count: 2 }, 'fi'), 'Vuosikortti peruttu, 2 varausta peruttu');
  primeAmTexts([{ key: 'ui.admin.annual_manage.delete', lang: 'fi', text: 'Poista (kanta)' }, { key: 'ui.admin.annual_manage.deleted', lang: 'fi', text: 'Poistettu {{x}}' },
    { key: 'ui.admin.nav.orders', lang: 'fi', text: 'ohitetaan' }]);
  assert.equal(amText('ui.admin.annual_manage.delete', null, 'fi'), 'Poista (kanta)');
  assert.equal(amText('ui.admin.annual_manage.deleted', null, 'fi'), 'Vuosikortti poistettu');
  assert.equal(fillAmText('Kortti {{var:code}}', { code: 'ABC' }), 'Kortti ABC');
  clearAmTextCache();
});

test('mock: deletable-kortin poisto onnistuu, ostettu kortti antaa virheen, peruminen toimii', async () => {
  const m = createAdminMock();
  const call = (n, a) => m.rpc(n, a);
  const list = await call('admin_list_annual_cards_details');
  const bought = list.find((c) => c.purchase_order_no), free = list.find((c) => c.deletable);
  assert.ok(bought && bought.deletable === false && free && !free.purchase_order_no);
  await assert.rejects(() => call('admin_delete_annual_card', { p_id: bought.id }), (e) => (e.code || e.detail) === 'annual_card_purchased');
  const r = await call('admin_delete_annual_card', { p_id: free.id });
  assert.equal(r.deleted, true);
  assert.ok(!(await call('admin_list_annual_cards_details')).some((c) => c.id === free.id));
  const rv = await call('admin_revoke_annual_card', { p_id: bought.id, p_cancel_future: true });
  assert.equal(rv.ok, true);
  const after = (await call('admin_list_annual_cards_details')).find((c) => c.id === bought.id);
  assert.equal(after.active, false); assert.ok(after.revoked_at);
  const staff = createAdminMock({ role: 'staff' });
  await assert.rejects(staff.rpc('admin_delete_annual_card', { p_id: 2 }), /annual_cards\.manage/);
  await assert.rejects(staff.rpc('admin_revoke_annual_card', { p_id: 1 }), /annual_cards\.manage/);
});

test('build-lista ja CI', () => {
  assert.match(rd('scripts/build-pages.mjs'), /'annual-manage-texts\.js'/);
  assert.match(rd('.github/workflows/pages.yml'), /node --test booking\/tests\/vuosikortti-poisto\.test\.mjs/);
});
