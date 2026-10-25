// booking_157: tietosuojan säilytysajat (anonymisointi 3 v / kirjanpito 6 v) ja kävijämittauksen kuukausikooste.
// SQL-käyttäytyminen: booking/supabase/tests/t157_privacy_retention.sql ja t157_privacy_retention_rollback.psql (paikallinen PG17).
// Tämä testi tarkistaa rakenteen staattisesti: tuotannon lukuraportti = migraation ehdokaslohko, henkilökenttälistat täsmäävät,
// ei public-skeemaa, ei ajastusta migraatiossa, rollback palauttaa tuotannon funktiot ja tarkistaa md5:n.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const V = '20261024165608';
const MIG = `booking/supabase/migrations/${V}_booking_157_privacy_retention.sql`;
const RB = `booking/supabase/rollbacks/${V}_booking_157_ROLLBACK.sql`;
const RO = 'booking/supabase/manual/booking_157_retention_report_readonly.sql';
const CRON = 'booking/supabase/manual/booking_157_retention_cron.sql';
const mig = read(MIG), rb = read(RB), ro = read(RO), cron = read(CRON);
const code = (s) => s.replace(/--[^\n]*/g, '');
const block = (s) => {
  const a = s.indexOf('-- <privacy-candidates>'), b = s.indexOf('-- </privacy-candidates>');
  assert.ok(a >= 0 && b > a, 'ehdokaslohkon merkit puuttuvat');
  return s.slice(a, b);
};

test('versio: booking_157 lajittuu booking_156:n (20261024163053) jälkeen ja on uniikki', () => {
  assert.ok(V > '20261024163053');
  const all = readdirSync(join(root, 'booking/supabase/migrations')).filter((f) => f.endsWith('.sql')).sort();
  // booking_157:n jälkeen saa tulla vain myöhempiä booking-migraatioita (esim. booking_159); ei aiempia numeroita sen perään
  // ei-booking-migraatiot (esim. history-sync 20261025113918_ops_health_light) eivät kuulu numerojärjestykseen
  const after = all.filter((f) => f.slice(0, 14) > V && /_booking_\d+_/.test(f));
  assert.ok(after.every((f) => +f.match(/_booking_(\d+)_/)[1] > 157), `booking_157:n jälkeen vain myöhempiä migraatioita: ${after}`);
  const files = readdirSync(join(root, 'booking/supabase/migrations')).filter((f) => f.startsWith(V));
  assert.equal(files.length, 1);
  assert.ok(readdirSync(join(root, 'booking/supabase/rollbacks')).some((f) => f.startsWith(V)));
});

test('tuotannon lukuraportti käyttää täsmälleen samaa ehdokaslohkoa kuin migraatio ja on pelkkä SELECT', () => {
  assert.equal(block(ro), block(mig));
  const c = code(ro).toLowerCase();
  for (const w of ['insert ', 'update ', 'delete ', 'create ', 'alter ', 'drop ', 'grant ', 'truncate ', 'cron.', 'set_config']) assert.ok(!c.includes(w), `lukuraportissa ${w}`);
  assert.match(c, /^\s*with p0 as/);
  assert.ok(!/sample|\bid\b\s*,\s*email/.test(c));
  assert.match(c, /count\(\*\)/);
});

test('henkilökenttälistat: _privacy_pii_keys = ehdokaslohkon pii-lista', () => {
  const keys = {};
  const fn = mig.slice(mig.indexOf('function booking._privacy_pii_keys()'));
  for (const m of fn.slice(0, fn.indexOf('$$;')).matchAll(/\('([a-z_]+)', array\[[^\]]*\], array\[([^\]]*)\], (true|false)\)/g)) keys[m[1]] = m[2] + '|' + m[3];
  const pii = {};
  const b = block(mig);
  for (const m of b.slice(b.indexOf('pii(tbl, keys, acct)')).matchAll(/\('([a-z_]+)', array\[([^\]]*)\], (true|false)\)/g)) pii[m[1]] = m[2] + '|' + m[3];
  assert.ok(Object.keys(pii).length >= 15);
  assert.deepEqual(keys, pii);
});

test('migraatio: ei public-skeemaa, ei kb.products-muutoksia, ei ajastusta, oletuksena pois päältä', () => {
  const c = code(mig);
  assert.ok(!/\bpublic\./.test(c.replace(/from public|to public|revoke all on [^;]+ from public[^;]*;/g, '')), 'public-skeemaa ei saa koskea');
  assert.ok(!/cron\.schedule/.test(c));
  assert.ok(!/(update|insert into|delete from|alter table)\s+kb\.products/.test(c));
  assert.ok(!/public_catalog/.test(c));
  assert.match(c, /'privacy_retention\.enabled', 'false'::jsonb/);
  assert.match(c, /on conflict \(key\) do nothing/);
  assert.match(c, /set local lock_timeout/);
  assert.match(c, /create or replace function booking\.privacy_retention_run\(\)\s*returns jsonb language plpgsql volatile security definer set search_path = ''/);
  assert.match(c, /perform booking\._privacy_require_admin\(\);\s*v_enabled :=/);
  assert.match(c, /create or replace function booking\.privacy_retention_report\(p_as_of date default/);
  // raportti on stable (ei kirjoita)
  assert.match(c, /privacy_retention_report\(p_as_of date default \(now\(\) at time zone 'Europe\/Helsinki'\)::date\)\s*returns jsonb language plpgsql stable/);
  // kooste ei tallenna istunto-, tilaus- tai UTM-tietoja
  const t = c.slice(c.indexOf('create table if not exists booking.analytics_monthly'), c.indexOf(');', c.indexOf('create table if not exists booking.analytics_monthly')));
  for (const k of ['session_key', 'order_id', 'utm_', 'referrer']) assert.ok(!t.includes(k), `analytics_monthly: ${k}`);
});

test('turvapoikkeukset ovat ehdokaslohkossa', () => {
  const b = block(mig);
  for (const k of ['future_reservation', 'active_gift_card', 'active_annual_card', 'open_payment', 'open_refund', 'open_invoice', 'marketing_consent', 'open_email'])
    assert.ok(b.includes(`'${k}'`), k);
  assert.match(b, /g\.status = 'active' and g\.balance > 0 and \(g\.valid_to is null or g\.valid_to >= p\.as_of\)/);
});

test('manuaalinen cron-tiedosto: kuukausittain, ei ajeta migraatiossa', () => {
  assert.match(cron, /ÄLÄ AJA NYT/);
  assert.match(cron, /cron\.schedule\('booking_privacy_retention', '43 3 5 \* \*', \$cron\$select booking\.privacy_retention_run\(\)\$cron\$\)/);
  assert.match(cron, /cron\.unschedule\('booking_privacy_retention'\)/);
});

test('rollback: palauttaa neljä funktiota tuotannon md5:llä ja tarkistaa ne', () => {
  const md5 = {
    'booking.admin_analytics_summary(date,date)': 'f21c0cbdde8587fbdf709ab7c724a08e',
    'booking.analytics_cleanup()': 'e7a029b50af8a35743babb726aa7a38f',
    'booking.invoices_lock_trg()': '4195a369d8bf7dc8cd15e24663f41b0a',
    'booking.receipts_guard_trg()': 'ea08f705bc87c141b6c3aa21b30e5d12',
  };
  for (const [sig, m] of Object.entries(md5)) assert.ok(rb.includes(`('${sig}', '${m}')`), sig);
  for (const n of ['admin_analytics_summary(p_from date, p_to date)', 'analytics_cleanup()', 'invoices_lock_trg()', 'receipts_guard_trg()'])
    assert.ok(rb.includes(`CREATE OR REPLACE FUNCTION booking.${n}`), n);
  assert.match(rb, /raise exception 'booking_157 rollback: md5 ei täsmää/);
  assert.match(rb, /drop function if exists booking\.privacy_retention_run\(\);/);
  assert.match(rb, /cron\.unschedule\('booking_privacy_retention'\)/);
  assert.ok(!/\bpublic\./.test(code(rb)));
});

test('kirjanpitolukkojen poikkeus vaatii ajon lipun ja 6 v säilytyksen päättymisen', () => {
  const c = code(mig);
  const r = c.slice(c.indexOf('create or replace function booking.receipts_guard_trg()'));
  assert.match(r, /current_setting\('booking\.privacy_retention', true\)/);
  assert.match(r, /booking\._privacy_acct_due\(\(old\.issued_at at time zone 'Europe\/Helsinki'\)::date\)/);
  assert.match(r, /new\.text_body is distinct from booking\._receipt_text\(new\.snapshot\)/);
  const i = c.slice(c.indexOf('create or replace function booking.invoices_lock_trg()'));
  assert.match(i, /old\.status in \('paid', 'credited', 'voided'\)/);
  assert.match(i, /new\.total_gross is distinct from old\.total_gross/);
});

test('raportti: ilman koostekuukausia sama kysely kuin booking_150', () => {
  const m150 = read('booking/supabase/migrations/20261024120719_booking_150_analytics_hardening.sql');
  const f150 = m150.slice(m150.indexOf('create or replace function booking.admin_analytics_summary'));
  const raw150 = f150.slice(f150.indexOf('  with e as materialized ('), f150.indexOf('  ) into result;'));
  const f157 = mig.slice(mig.indexOf('create or replace function booking.admin_analytics_summary'));
  const indented = raw150.split('\n').map((l) => (l ? '  ' + l : l)).join('\n');
  assert.ok(f157.includes(indented), 'booking_150:n kysely puuttuu sellaisenaan');
});

test('hallinnan kävijätilastot: pitkä menneisyysväli ja koosteteksti fi/en', () => {
  const v = read('booking/admin/views/talous-analytics.js');
  assert.match(v, /\(to<=helDay\(\) \? 3660 : 366\)\*864e5/);
  assert.match(v, /t\('a\.aggregated'\)/);
  const tx = read('booking/admin/talous-texts.js');
  assert.equal((tx.match(/'a\.aggregated':/g) || []).length, 2);
});
