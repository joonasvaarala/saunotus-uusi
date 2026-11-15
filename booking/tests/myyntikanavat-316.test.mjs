// booking_316 (Joonas t1780u 15.11.2026 klo 9.04): myyntikanavat datana (booking.sales_channels) ja tuotekohtainen monivalinta (booking.product_sales_channels).
// Ajo: node --test booking/tests/myyntikanavat-316.test.mjs
// SQL-testi booking/supabase/tests/t316_sales_channels.sql ajetaan VAIN paikalliseen kertakäyttökantaan (rollback). Työnkulussa ei ole Postgresia.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const migs = readdirSync(join(root, 'booking/supabase/migrations'));
const migName = migs.find((f) => /_booking_316_sales_channels\.sql$/.test(f));
const mig = read(`booking/supabase/migrations/${migName}`);
const rbName = readdirSync(join(root, 'booking/supabase/rollbacks')).find((f) => /_booking_316_ROLLBACK\.sql$/.test(f));
const rb = read(`booking/supabase/rollbacks/${rbName}`);
const sqlTest = read('booking/supabase/tests/t316_sales_channels.sql');
const body = (s) => s.replace(/^\s*--.*$/gm, '');
const fnDef = (src, name) => {
  const i = src.indexOf(`CREATE OR REPLACE FUNCTION booking.${name}(`);
  assert.ok(i >= 0, `${name} puuttuu`);
  const rest = src.slice(i);
  const m = /\$function\$\s*;/.exec(rest.slice(rest.indexOf('AS $function$') + 13));
  return rest.slice(0, rest.indexOf('AS $function$') + 13 + m.index);
};

const REWRITTEN = ['public_catalog', 'public_availability', 'public_availability_all', 'public_events', 'public_training_checkout', 'public_product_by_slug',
  '_upsell_options', '_public_create_booking_impl', '_public_create_booking_code_impl', '_public_create_training_signup_impl', 'public_ritual_addon',
  '_ritual_addon_fit', '_counter_lines', 'admin_pos_catalog', 'public_drinks_catalog', 'public_gift_card_packages', '_public_buy_gift_card_impl',
  'public_join_waitlist'];
const PROD_MD5 = ['a14cb1f474b5858c47bafbb8d96091aa', '5e3634cd8c5e6e2cf8576acf15b02c2e', 'e0fece192800777e3a7554edc704ed07', '32f88991275054c7aae90df0229708c5',
  '89398f45d01322cf4ffaa117bb4d9924', '630a9db6ab457b4c412bb368dcb4ae8d', '66abc9abd7ea2b4962e52db8ff14ceb9', '2fb0e0c5d84feea78e7adb904676481a',
  '786b3856991464fe118d2d6bc0b5826b', 'd5017b23bde3ff427459c77caea0b807', 'aed97660d894b70129acfac243ecabbf', '3201a2c1db7f0c8e7016c807f5f10446',
  'ac50053b47c2b14d8c20034b0d62ffb1', '3abd467f4f8aab624a90b48e60f356e0', 'e7e507a766b7287ff03e794711ac6ace', '3ac6c50c3af91a5f771db71ebd0f2d6f',
  '367323d3aab88fc78e552a7c1475fbc3', 'af0188264002fdb1b42bb22092fd94c6'];

test('booking_316: yksi migraatio, numero vapaa, nimi', () => {
  assert.equal(migs.filter((f) => /_booking_316_/.test(f)).length, 1);
  assert.ok(migName.startsWith('20261115'), migName);
});

test('booking_316: kanavat ovat dataa, liitostaulu, RLS ja grantit', () => {
  assert.match(mig, /create table booking\.sales_channels \(/);
  assert.match(mig, /create table booking\.product_sales_channels \(/);
  assert.match(mig, /primary key \(product_id, channel_code\)/);
  for (const [code, fi, en] of [['shop', 'Verkkokauppa', 'Online shop'], ['widget', 'Upotus', 'Embed'], ['link', 'Suora linkki', 'Direct link'], ['admin', 'Hallinta \\(varaus\\)', 'Admin \\(booking\\)'],
    ['pos', 'Pikakassa', 'Quick till'], ['qr', 'QR-myynti \\(kylmälaite\\)', 'QR sales \\(fridge\\)'], ['gift_shop', 'Lahjakorttikauppa', 'Gift card shop']]) {
    assert.match(mig, new RegExp(`\\('${code}',\\s+'${fi}',\\s+'${en}'`), code);
  }
  const seed = mig.slice(mig.indexOf('insert into booking.sales_channels'), mig.indexOf('-- ---------- 2) apufunktiot'));
  assert.equal((seed.match(/^\s+\('/gm) || []).length, 7, 'täsmälleen seitsemän kanavaa');
  assert.match(seed, /\('admin',\s+'Hallinta \(varaus\)',\s+'Admin \(booking\)',\s+35, true, false\)/, 'admin ei ole julkinen varauskanava');
  assert.doesNotMatch(seed, /johku|partner|kumppan/i, 'kumppanien kaupat ja Johku eivät ole kanavia');
  assert.match(mig, /alter table booking\.sales_channels enable row level security;/);
  assert.match(mig, /alter table booking\.product_sales_channels enable row level security;/);
  assert.match(mig, /create policy staff_read on booking\.product_sales_channels for select to authenticated using \(\(select booking\.is_staff\(\)\)\);/);
  assert.match(mig, /revoke all on table booking\.product_sales_channels from public, anon, authenticated;/);
  assert.doesNotMatch(mig, /grant (insert|update|delete|all)[^;]* to authenticated/i, 'kirjoitus vain RPC:n kautta');
  for (const f of ['_in_channel\\(bigint, text\\)', '_public_channel_ok\\(bigint\\)', '_gc_package_in_shop\\(text\\)', '_psc_from_config_trg\\(\\)', '_psc_to_config_trg\\(\\)']) {
    assert.match(mig, new RegExp(`revoke all on function booking\\.${f} from public, anon, authenticated;`), f);
  }
  assert.match(mig, /grant execute on function booking\.admin_set_product_sales_channels\(bigint, text\[\]\) to authenticated, service_role;/);
});

test('booking_316: backfill nykytilasta ja jälkitarkistus', () => {
  // julkiset kanavat vain bookable-tuotteille (Varattavissa verkossa -valinta poistui; Joonas 15.11. klo 10.38)
  assert.match(mig, /case when pc\.bookable and pc\.shop_visible and 'shop' = any \(booking\._channels_effective\(pc\.channels, p\.category\)\) then 'shop' end/);
  assert.match(mig, /case when pc\.bookable and 'widget' = any/);
  assert.match(mig, /case when pc\.bookable and 'link' = any/);
  assert.match(mig, /julkinen kanava tuotteella, jonka bookable = false/);
  assert.match(mig, /case when pc\.bookable and pc\.lifecycle = 'current' then 'admin' end/, 'admin = nykyinen hallintavarattavuus');
  assert.match(mig, /admin-kanava ei vastaa bookable\/lifecycle-tilaa/);
  assert.match(mig, /case when pc\.fridge_sale then 'qr' end/);
  assert.match(mig, /case when pc\.pos_enabled then 'pos' end/);
  assert.match(mig, /select distinct r\.pid, 'gift_shop'/);
  assert.match(mig, /do \$post\$/);
  assert.match(mig, /backfill ei vastaa vanhoja kenttiä/);
  // triggerit luodaan vasta backfillin jälkeen
  assert.ok(mig.indexOf('create trigger zz_sales_channels_sync') > mig.lastIndexOf("'gift_shop', null::uuid"));
});

test('booking_316: siirtymän synkka molempiin suuntiin, rekursiosuoja', () => {
  assert.match(mig, /after insert or update of shop_visible, channels, fridge_sale, pos_enabled, bookable, lifecycle on booking\.product_config/);
  assert.match(mig, /case when new\.bookable and new\.shop_visible and 'shop' = any \(v_eff\) then 'shop' end/);
  assert.match(mig, /s\.channel_code in \('shop', 'widget', 'link', 'admin'\)\);/, 'varauskanavat = julkiset + admin');
  assert.match(mig, /detail = 'has_upcoming_bookings'/, 'viimeisen varauskanavan poisto estyy tulevien varausten takia');
  assert.match(mig, /booking\._res_active\(r\.status, r\.hold_expires_at\) and r\.ends_at > now\(\)/);
  const set = mig.slice(mig.indexOf('create function booking.admin_set_product_sales_channels'));
  assert.ok(set.indexOf('insert into booking.product_sales_channels') < set.indexOf('delete from booking.product_sales_channels'), 'lisäys ennen poistoa');
  assert.match(mig, /after insert or delete or update on booking\.product_sales_channels/);
  assert.equal((mig.match(/current_setting\('booking\.channel_sync', true\)/g) || []).length, 2);
  assert.match(mig, /channel_code = any \(array\['shop', 'widget', 'link', 'qr', 'pos'\]\)/, 'vain kartoitetut koodit');
});

test('booking_316: hallinnan RPC:t ja oikeudet', () => {
  const set = mig.slice(mig.indexOf('create function booking.admin_set_product_sales_channels'));
  assert.match(set, /perform booking\._require_permission\('catalog\.edit'\);/);
  assert.match(set, /unknown_channel/);
  assert.match(set, /channel_inactive/);
  assert.match(set, /not_counter_product/);
  assert.match(set, /age_restricted/);
  const list = mig.slice(mig.indexOf('create function booking.admin_list_sales_channels'));
  assert.match(list, /perform booking\._require_staff\(\);/);
});

test('booking_316: julkiset funktiot ja kassat lukevat liitostaulua; suora API estyy', () => {
  for (const n of REWRITTEN) {
    const d = fnDef(mig, n);
    assert.match(d, /booking\._(in_channel|public_channel_ok|gc_package_in_shop)\(/, n);
    assert.doesNotMatch(d, /_channels_effective/, `${n} ei enää lue vanhaa kanavakenttää`);
  }
  for (const n of ['_public_create_booking_impl', '_public_create_booking_code_impl', '_public_create_training_signup_impl']) {
    assert.match(fnDef(mig, n), /'not_bookable', 'message', 'Tuotetta ei voi varata verkossa'/, n);
  }
  assert.match(fnDef(mig, 'public_join_waitlist'), /or not booking\._public_channel_ok\(v_rule\.product_id\)/, 'jono vaatii julkisen kanavan');
  assert.match(fnDef(mig, '_ritual_addon_fit'), /if p_public then\n    if not booking\._public_channel_ok\(v_prod\)/, 'vain julkinen polku');
  assert.match(fnDef(mig, '_counter_lines'), /booking\._in_channel\(v_id, 'pos'\)/);
  assert.match(fnDef(mig, '_counter_lines'), /booking\._in_channel\(v_id, 'qr'\)/);
  assert.doesNotMatch(body(mig), /_create_booking_core\(p_rule_id[^)]*\)\s*returns/i, 'ydintä ei muuteta (hallinnan varaukset)');
  assert.doesNotMatch(body(mig), /CREATE OR REPLACE FUNCTION booking\._create_booking_core/);
});

test('booking_316: md5-esiehdot PRODin 15.11. määrittelyistä, ei public-skeemaa, ei lippuja', () => {
  for (const m of PROD_MD5) assert.ok(mig.includes(m), m);
  assert.ok(mig.includes('e645b473fc25ebdd53cb3b0be1d43005'), '_channels_effective');
  assert.equal((body(mig).match(/CREATE OR REPLACE FUNCTION/g) || []).length, REWRITTEN.length);
  assert.match(mig, /set local lock_timeout = '5s';/);
  assert.doesNotMatch(body(mig), /\bpublic\.\w/, 'ei public-skeemaa');
  assert.doesNotMatch(body(mig), /update booking\.settings|sale_enabled'\s*,\s*'true/i, 'ei lippuja');
  assert.doesNotMatch(body(mig), /\bprice\s*=|vat_rate\s*=/i, 'ei hintoja/ALV:tä');
});

test('booking_316: rollback palauttaa PRODin määrittelyt ja poistaa uudet objektit', () => {
  for (const m of PROD_MD5) assert.ok(sqlTest.includes(m), `SQL-testi tarkistaa ${m}`);
  assert.equal((body(rb).match(/CREATE OR REPLACE FUNCTION/g) || []).length, REWRITTEN.length);
  for (const n of REWRITTEN) assert.doesNotMatch(fnDef(rb, n), /_in_channel|_public_channel_ok|_gc_package_in_shop/, n);
  assert.match(rb, /drop trigger zz_sales_channels_sync on booking\.product_config;/);
  assert.match(rb, /drop table booking\.product_sales_channels;\ndrop table booking\.sales_channels;/);
  assert.match(rb, /booking_316 ROLLBACK: määrittelyt eivät vastaa booking_316:ta/);
  assert.ok(rb.indexOf('drop function booking._in_channel') > rb.lastIndexOf('CREATE OR REPLACE FUNCTION'), 'apufunktiot poistetaan vasta palautuksen jälkeen');
});

test('booking_316: SQL-testi kattaa ekvivalenssin, rollbackin, uudelleenajon ja suoran API:n', () => {
  assert.match(sqlTest, /\\ir \.\.\/migrations\/20261115091122_booking_316_sales_channels\.sql/);
  assert.match(sqlTest, /\\ir \.\.\/rollbacks\/20261115091122_booking_316_ROLLBACK\.sql/);
  assert.match(sqlTest, /tulos sama kuin ennen/);
  assert.match(sqlTest, /not_bookable/);
  assert.match(sqlTest, /^rollback;$/m);
  assert.match(sqlTest, /TESTRESULT/);
});
