// booking_158: tapahtumat ja koulutukset (tietokantaosa).
// SQL-käyttäytyminen: booking/supabase/tests/t158_events.sql (paikallinen PG17: migraatio, rollback x2 + md5-tarkistus, uudelleenajo).
// Tämä testi tarkistaa rakenteen staattisesti: versiojärjestys, rollbackin md5-lista = migraation lista, ei public-skeemaa,
// myynti pois päältä oletuksena, uusien funktioiden security definer + tyhjä search_path, oikeudet ja rollbackin poistot.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const V = '20261024185009';
const MIG = `booking/supabase/migrations/${V}_booking_158_events.sql`;
const RB = `booking/supabase/rollbacks/${V}_booking_158_ROLLBACK.sql`;
const T = 'booking/supabase/tests/t158_events.sql';
const mig = read(MIG), rb = read(RB);
const code = (s) => s.replace(/--[^\n]*/g, '');
const md5s = (s) => [...s.matchAll(/^--\s+booking\.(\w+): ([0-9a-f]{32})$/gm)].map((m) => `${m[1]}=${m[2]}`);

const REPLACED = ['_sessions', '_check_claim', '_resolve_session', '_block_conflict_pairs', 'space_blocks_managed_guard',
  'closure_blocks_outbox_trg', 'closure_outbox_backfill', 'public_catalog', 'public_availability', 'public_availability_all'];
const RPCS = ['admin_event_list', 'admin_event_rule_upsert', 'admin_event_rule_delete', 'admin_event_blocks_set', 'admin_event_set_channels',
  'admin_product_copy', 'admin_event_copy', 'admin_event_rule_copy', 'public_events'];

test('versio: booking_158 lajittuu booking_157:n (20261024165608) jälkeen ja on uniikki', () => {
  assert.ok(V > '20261024165608');
  const files = readdirSync(join(root, 'booking/supabase/migrations')).filter((f) => f.startsWith(V));
  assert.equal(files.length, 1);
  assert.ok(existsSync(join(root, RB)));
  assert.ok(existsSync(join(root, T)));
});

test('rollbackin md5-lista = migraation md5-lista, kaikki korvatut funktiot mukana', () => {
  const a = md5s(mig), b = md5s(rb);
  assert.equal(a.length, REPLACED.length);
  assert.deepEqual(a, b);
  for (const f of REPLACED) {
    assert.ok(a.some((x) => x.startsWith(f + '=')), f);
    assert.match(mig, new RegExp(`create or replace function booking\\.${f}\\(`, 'i'), `migraatio korvaa ${f}`);
    assert.match(rb, new RegExp(`CREATE OR REPLACE FUNCTION booking\\.${f}\\(`), `rollback palauttaa ${f}`);
  }
  assert.match(rb, /raise exception 'booking_158 rollback: booking\.% md5/);
});

test('ei public-skeemaa, ei maksuja, ei sähköposteja, ei hintojen/slugien muutoksia', () => {
  for (const s of [code(mig), code(rb)]) {
    assert.ok(!/\bpublic\.\w/.test(s.replace(/from public,|from public;|to public\b/g, '')), 'public-skeema');
    for (const w of ['cron.', 'net.http', 'vismapay', 'mobilepay', 'procountor', 'email_outbox']) assert.ok(!s.toLowerCase().includes(w), w);
    assert.ok(!/update\s+kb\.products/i.test(s), 'kb.products-päivitys');
  }
});

test('myynti pois päältä: events.sale_enabled = false, ei ylikirjoitusta', () => {
  assert.match(mig, /\('events\.sale_enabled', 'false'::jsonb,[\s\S]*?on conflict \(key\) do nothing/);
  assert.match(mig, /r\.kind = 'event' and not booking\._events_sale_enabled\(\) and not booking\.is_staff\(\)/);
  assert.ok(!/'events\.sale_enabled',\s*'true'/.test(code(mig)));
  assert.ok(!/update booking\.settings[^;]*events\.sale_enabled/i.test(code(mig)));
});

test('uudet RPC:t: security definer, tyhjä search_path, oikeudet', () => {
  for (const f of RPCS) {
    const m = mig.match(new RegExp(`create or replace function booking\\.${f}\\([\\s\\S]*?\\$\\$;`, 'i'));
    assert.ok(m, f);
    assert.match(m[0], /security definer/i, f);
    assert.match(m[0], /set search_path (to|=) ''/i, f);
    if (f.startsWith('admin_')) assert.match(m[0], f === 'admin_event_list' ? /_require_staff\(\)|_require_permission/ : /_require_permission\('catalog\.edit'\)/, f);
  }
  assert.match(mig, /grant execute on function booking\.public_events\(date, text\) to anon, authenticated, service_role/);
});

test('rollback poistaa uudet funktiot, taulut ja sarakkeet', () => {
  for (const f of RPCS) assert.match(rb, new RegExp(`drop function if exists booking\\.${f}\\(`), f);
  assert.match(rb, /drop table if exists booking\.event_resource_blocks/);
  assert.match(rb, /drop column if exists kind/);
  assert.match(rb, /drop column if exists channels/);
  assert.match(rb, /m158_lovi_rows/);
});

test('Lovi: tuotteet 10, 11, 12, 23, 24 jäävät Loviin, muut (14–22) suljetaan; vanhan version passivoimat 23/24 takaisin', () => {
  assert.match(mig, /s\.space_id = v_lovi and s\.active and s\.product_id not in \(10, 11, 12, 23, 24\)/);
  assert.match(mig, /m\.product_id in \(10, 11, 12, 23, 24\) and not s\.active/);
  assert.match(mig, /delete from booking\.m158_lovi_rows m where m\.product_id in \(10, 11, 12, 23, 24\)/);
  assert.doesNotMatch(mig, /not in \(10, 11, 12\)/);
  const t = read(T);
  assert.match(t, /array\[14, 15, 16, 17, 18, 19, 20, 21, 22\]::bigint\[\]/);
  assert.match(t, /\) = 5, 'N2:/);
});

test('SQL-testi tarkistaa rollbackin ja uudelleenajon', () => {
  const t = read(T);
  assert.match(t, /TESTRESULT/);
  assert.match(t, /20261024185009_booking_158_ROLLBACK\.sql/);
  assert.match(t, /20261024185009_booking_158_events\.sql/);
});

test('aikavyöhyke: hallinnan ISO-aika ilman poikkeamaa = Europe/Helsinki istunnosta riippumatta; t158 ajetaan UTC-istunnossa', () => {
  const c = code(mig);
  // ei yhtään tekstin suoraa ::timestamptz-tulkintaa (riippuisi istunnon TimeZonesta) muualla kuin poikkeamallisen ajan haarassa
  assert.equal((c.match(/::timestamptz/g) || []).length, 1);
  assert.match(c, /if p_val ~\* '\^[^']*\(z\|\[\+-\]\\d\{2\}\(:\?\\d\{2\}\)\?\)\$' then\s+return \(p_val::timestamptz\) at time zone 'Europe\/Helsinki';/);
  assert.match(c, /return \(p_val::timestamp at time zone 'Europe\/Helsinki'\) at time zone 'Europe\/Helsinki';/);
  assert.equal((c.match(/v_local := booking\._event_local_ts\(v_[se]\)/g) || []).length, 2);
  assert.match(c, /'booking\._event_local_ts\(text\)'/);
  assert.match(rb, /drop function if exists booking\._event_local_ts\(text\);/);
  const t = read(T);
  assert.match(t, /\\set tz UTC/);
  assert.match(t, /set local timezone = :'tz';/);
  assert.match(t, /'L2b: /);
  assert.match(t, /'L2c: /);
  // kiinteät testipäivät, ei 14.11.2026 (törmäsi tuotannossa oikeaan Savusaunan varaukseen)
  assert.match(t, /d date := date '2027-02-22';/);
  assert.match(t, /d2 date := date '2027-03-01';/);
  assert.doesNotMatch(t, /next_dow|2026-11-14/);
});
