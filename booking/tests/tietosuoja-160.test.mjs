// booking_160: tietosuojan säilytysajan korjaukset (Joonaksen säännöt 24.10.2026).
// SQL-käyttäytyminen: booking/supabase/tests/t160_retention_fixes.sql ja t160_retention_fixes_rollback.psql (paikallinen PG17).
// Tämä testi tarkistaa rakenteen staattisesti: lukuraportti = migraation ehdokaslohko, ei public-skeemaa, ei ajastusta,
// oletuksena pois päältä ja dry_run, Storage-poisto vain Storage-API:lla, rollback palauttaa tuotannon funktiot md5:llä, booking_157 ennallaan.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const md5 = (p) => createHash('md5').update(readFileSync(join(root, p))).digest('hex');
const V = '20261024330000';
const MIG = `booking/supabase/migrations/${V}_booking_160_retention_fixes.sql`;
const RB = `booking/supabase/rollbacks/${V}_booking_160_ROLLBACK.sql`;
const RO = 'booking/supabase/manual/booking_160_retention_report_readonly.sql';
const CRON = 'booking/supabase/manual/booking_160_retention_cron.sql';
const FN = 'booking/supabase/functions/privacy-storage-cleanup';
const mig = read(MIG), rb = read(RB), ro = read(RO), cron = read(CRON);
const code = (s) => s.replace(/--[^\n]*/g, '');
const block = (s) => {
  const a = s.indexOf('-- <privacy-candidates>'), b = s.indexOf('-- </privacy-candidates>');
  assert.ok(a >= 0 && b > a, 'ehdokaslohkon merkit puuttuvat');
  return s.slice(a, b);
};
const fnBody = (name) => {
  const c = code(mig), a = c.toLowerCase().indexOf(`create or replace function booking.${name.toLowerCase()}`);
  assert.ok(a >= 0, name);
  const n = c.toLowerCase().indexOf('create or replace function', a + 10);
  return c.slice(a, n < 0 ? undefined : n);
};

test('versio: booking_160 lajittuu booking_157:n jälkeen ja on uniikki', () => {
  assert.ok(V > '20261024165608');
  const all = readdirSync(join(root, 'booking/supabase/migrations'));
  assert.equal(all.filter((f) => f.startsWith(V)).length, 1);
  assert.ok(readdirSync(join(root, 'booking/supabase/rollbacks')).some((f) => f.startsWith(V)));
});

test('booking_157:n tiedostot ennallaan', () => {
  assert.equal(md5('booking/supabase/migrations/20261024165608_booking_157_privacy_retention.sql'), 'd800c31681f09c68dc1020e692d62497');
  assert.equal(md5('booking/supabase/rollbacks/20261024165608_booking_157_ROLLBACK.sql'), '34a8d6f2345dea267271ee5cac891904');
  assert.equal(md5('booking/supabase/manual/booking_157_retention_report_readonly.sql'), '36f14a1e50ec3ddee55ffec3d663c6c1');
  assert.equal(md5('booking/supabase/manual/booking_157_retention_cron.sql'), '7a02ee88ac0d178548fe4bfa1e1d0f67');
});

test('lukuraportti käyttää täsmälleen samaa ehdokaslohkoa kuin migraatio ja on pelkkä SELECT', () => {
  assert.equal(block(ro), block(mig));
  const c = code(ro).toLowerCase();
  for (const w of ['insert ', 'update ', 'delete ', 'create ', 'alter ', 'drop ', 'grant ', 'truncate ', 'cron.', 'set_config', 'net.'])
    assert.ok(!c.includes(w), `lukuraportissa ${w}`);
  assert.match(c, /^\s*with p0 as/);
  assert.match(c, /count\(\*\)/);
});

test('migraatio: ei public-skeemaa, ei ajastusta, enabled ei päälle, dry_run oletuksena true', () => {
  const c = code(mig);
  assert.ok(!/\bpublic\./.test(c), 'public-skeemaa ei saa koskea');
  assert.ok(!/cron\.(schedule|unschedule)|net\.http/.test(c));
  assert.ok(!/privacy_retention\.enabled'\s*,\s*'true'/.test(c));
  assert.ok(!/update booking\.settings set value/.test(c), 'migraatio ei muuta olemassa olevia asetusarvoja');
  assert.match(c, /\('privacy_retention\.dry_run', 'true'::jsonb,/);
  assert.match(c, /\('privacy_retention\.gift_card_pdf_years', '3'::jsonb,/);
  assert.match(c, /on conflict \(key\) do nothing/);
  assert.match(c, /set local lock_timeout/);
});

test('ajo: dry_run on oletus (vain eksplisiittinen false kirjoittaa) ja tarkistetaan ennen muutoksia', () => {
  const r = fnBody('privacy_retention_run()');
  assert.match(r, /v_dry := coalesce\(\(select s\.value is distinct from 'false'::jsonb from booking\.settings s where s\.key = 'privacy_retention\.dry_run'\), true\);/);
  const iDry = r.indexOf('if v_dry then'), iFirstUpdate = r.indexOf('update booking.customers');
  assert.ok(iDry > 0 && iFirstUpdate > iDry, 'dry_run-haara ennen ensimmäistä muutosta');
  assert.match(r.slice(iDry, iFirstUpdate), /return jsonb_build_object\('ok', true, 'enabled', true, 'dry_run', true/);
  assert.match(r, /perform booking\._privacy_require_admin\(\);/);
});

test('sääntö 1: voimassa oleva markkinointilupa = lupa ja ei myöhempää peruutusta; peruutus on aktiviteetti', () => {
  const b = block(mig);
  assert.match(b, /marketing_consent_events/);
  assert.match(b, /'marketing_consent'/);
});

test('sääntö 2: yrityksen nimi ja Y-tunnus säilyvät', () => {
  const c = code(mig);
  assert.match(fnBody('_privacy_invoice_snapshot(p jsonb)'), /business_id/);
  for (const k of ['company_name', 'business_id', 'vat_id']) assert.ok(fnBody('_privacy_invoice_snapshot(p jsonb)').includes(`'${k}'`), k);
  const r = fnBody('privacy_retention_run()');
  assert.match(r, /booking\._privacy_invoice_snapshot\(/);
  assert.match(r, /business_id_raw/);
  assert.ok(c.includes("_privacy_keep("));
});

test('sääntö 3: lähetetyt sähköpostit poistetaan jonosta (ei vain anonymisoida)', () => {
  const r = fnBody('privacy_retention_run()');
  assert.match(r, /delete from booking\.email_outbox e/);
  assert.ok(!/update booking\.email_outbox/.test(r));
  assert.match(block(mig), /'email_outbox'/);
});

test('sääntö 4: PDF:t merkitään SQL:ssä, tiedostot poistetaan vain Storage-API:lla', () => {
  const all = code(mig) + code(rb) + code(cron);
  assert.ok(!/delete\s+from\s+storage\./i.test(all), 'storage-rivejä ei saa poistaa SQL:llä');
  assert.ok(!/(update|insert into|truncate)\s+storage\./i.test(all));
  for (const k of ['receipt_pdfs_6y', 'invoice_pdfs_6y', 'gift_card_pdfs_3y']) assert.ok(block(mig).includes(`'${k}'`), k);
  for (const t of ['receipts', 'invoices', 'gift_cards']) assert.match(code(mig), new RegExp(`alter table booking\\.${t} add column if not exists pdf_deleted_at timestamptz;`));
  const due = fnBody('privacy_storage_due(');
  assert.match(due, /perform booking\._privacy_require_admin\(\);/);
  const idx = read(`${FN}/index.ts`), core = read(`${FN}/core.ts`);
  assert.match(idx, /sb\.storage\.from\(b\.bucket\)\.remove\(b\.paths\)/);
  assert.match(idx, /_cron_secret_ok/);
  assert.match(idx, /privacy_storage_due/);
  assert.match(core, /due\?\.enabled !== true \? "disabled" : \(due\?\.dry_run !== false \|\| requestDryRun\) \? "dry_run" : "remove"/);
  assert.match(read('booking/supabase/config.toml'), /\[functions\.privacy-storage-cleanup\]\nverify_jwt = false/);
  // PDF-palvelut eivät enää tarjoa poistettua PDF:ää
  for (const f of ['receipt_by_token(', 'invoice_by_token(', 'svc_get_gift_card_pdf_data(']) assert.match(fnBody(f), /pdf_deleted_at is (not )?null/, f);
});

test('sääntö 5: vain asiakkaiden auth-tilit poistetaan; henkilökunta ja viitatut tilit ohitetaan', () => {
  const p = fnBody('_privacy_auth_protected(p_uid uuid)');
  for (const k of ["'staff'", "'text_bot'", "'linked_customer'", "'app_role'", "'super_admin'", "'referenced:'"]) assert.ok(p.includes(k), k);
  const r = fnBody('privacy_retention_run()');
  const i = r.indexOf('delete from auth.users u where u.id = ad.auth_user_id');
  assert.ok(i > 0);
  assert.ok(r.lastIndexOf('booking._privacy_auth_protected(ad.auth_user_id)', i) > 0, 'suojatarkistus ennen poistoa');
  assert.equal((code(mig).match(/delete from auth\.users/g) || []).length, 1);
  assert.match(code(mig), /create table if not exists booking\.privacy_auth_deletions/);
});

test('ehto: tilauksia, maksuja, varauksia ja käyntejä ei poisteta', () => {
  const c = code(mig);
  for (const t of ['orders', 'payments', 'reservations', 'visits', 'receipts', 'invoices', 'order_lines', 'customers'])
    assert.ok(!new RegExp(`delete from booking\\.${t}\\b`).test(c), t);
});

test('rollback: palauttaa kahdeksan funktiota tuotannon md5:llä ja tarkistaa ne', () => {
  const m = {
    'booking._privacy_candidates(date)': '860ed2d3493d397c2245722851556849',
    'booking.privacy_retention_report(date)': '2af4b398e95c10d8255b2455e3859c67',
    'booking.privacy_retention_run()': 'd67501e18437fa02823abd04a3e2f757',
    'booking.receipts_guard_trg()': '928c3105ed1b69ce0a6e4eee955d2a59',
    'booking.invoices_lock_trg()': 'f0efc5f40afa919f936e55a6df482a1e',
    'booking.receipt_by_token(uuid)': '1bbc3a0f4ed08b05100b7ffe44278e27',
    'booking.invoice_by_token(uuid)': '4061b4bf7ceef0ba2464e2160e0f3d48',
    'booking.svc_get_gift_card_pdf_data(uuid)': '4a74a7a12ba5617bc7ad35815db484b6',
  };
  for (const [sig, h] of Object.entries(m)) assert.ok(rb.includes(`('${sig}', '${h}')`), sig);
  assert.match(rb, /md5\(pg_get_functiondef\(r\.sig::regprocedure\)\)/);
  assert.match(rb, /raise exception 'booking_160 rollback: md5 ei täsmää/);
  assert.match(rb, /cron\.unschedule\('booking_privacy_storage_cleanup'\)/);
  assert.ok(!/\bpublic\./.test(code(rb)));
});

test('manuaalinen cron-tiedosto: ei ajeta nyt, molemmat ajastukset ja peruminen', () => {
  assert.match(cron, /ÄLÄ AJA NYT/);
  assert.match(cron, /cron\.schedule\('booking_privacy_retention', '43 3 5 \* \*', \$cron\$select booking\.privacy_retention_run\(\)\$cron\$\)/);
  assert.match(cron, /cron\.schedule\('booking_privacy_storage_cleanup', '13 4 5 \* \*'/);
  assert.match(cron, /functions\/v1\/privacy-storage-cleanup/);
  assert.match(cron, /'x-sync-secret'/);
  assert.match(cron, /cron\.unschedule\('booking_privacy_storage_cleanup'\)/);
  // ohjeessa kuivaharjoitus ennen oikeaa ajoa
  assert.ok(cron.indexOf("privacy_retention_report()") < cron.indexOf("set value = 'false' where key = 'privacy_retention.dry_run'"));
});

test('CI ajaa booking_160:n testit', () => {
  const y = read('.github/workflows/pages.yml');
  assert.ok(y.includes('node --test booking/tests/tietosuoja-160.test.mjs'));
  assert.ok(y.includes(`${FN}/core_test.ts`));
});
