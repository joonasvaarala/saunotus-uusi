// booking_139: jonotuslistan pito korjattu omistajan säännön mukaiseksi. Vuoroon ≥ 48 h → vain YKSI pito per vuoro kerrallaan
// (ensimmäinen mahtuva jonojärjestyksessä, 120 min). Pidon vanhetessa ei uutta pitoa samasta vapautumisesta: paikka on vapaasti
// myynnissä ja seuraava ajo (pg_cron booking_waitlist_sweep minuutin välein) ilmoittaa kaikille mahtuville ilman pitoa.
// Vanhentuneen pidon haltija voi varata tavallisena asiakkaana (claim → ok + hold_expired, ei offer_expired).
// Uusi vapautuminen = vuoron vapaa kapasiteetti > booking.waitlist_session_state.offered_free → yksi uusi pito ensimmäiselle
// mahtuvalle, jolla ei ole ollut pitoa (waitlist_entries.hold_expires_at is null). Alle 48 h ennallaan.
// SQL-käytös: booking/supabase/tests/waitlist/t139_waitlist_single_hold.sql (paikallinen PG17, ei työnkulussa).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';

const repo = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(resolve(repo, p), 'utf8');
const code = (s) => s.replace(/--[^\n]*/g, '');
const MIG = 'booking/supabase/migrations/20261024115000_booking_139_waitlist_single_hold.sql';
const RB = 'booking/supabase/rollbacks/20261024115000_booking_139_ROLLBACK.sql';
const T139 = 'booking/supabase/tests/waitlist/t139_waitlist_single_hold.sql';
const MIG137 = 'booking/supabase/migrations/20261024080249_booking_137_waitlist_offer_window.sql';
const fn = (sql, name) => { const i = sql.indexOf(`create or replace function booking.${name}(`); assert.ok(i >= 0, name); const j = sql.indexOf('end $$;', i); return sql.slice(i, j); };

test('booking_139: migraatio, rollback ja SQL-testi olemassa, aikaleima booking_137:n ja booking_138:n jälkeen, ei numeroa 140', () => {
  for (const p of [MIG, RB, T139]) assert.ok(existsSync(resolve(repo, p)), p);
  const migs = readdirSync(resolve(repo, 'booking/supabase/migrations')).filter((f) => f.endsWith('.sql')).sort();
  const i = migs.indexOf('20261024115000_booking_139_waitlist_single_hold.sql');
  assert.ok(i > migs.findIndex((f) => /_booking_138_/.test(f)) && i > migs.indexOf('20261024080249_booking_137_waitlist_offer_window.sql'));
  assert.ok(!migs.some((f) => /_booking_140_/.test(f)), 'booking_140 on varattu toiselle työlle');
});

test('migraatio booking_139: pidon historia ja vuorokohtainen tarjottu kapasiteetti, taulu suljettu', () => {
  const sql = code(rd(MIG));
  assert.match(sql, /alter table booking\.waitlist_entries add column if not exists hold_expires_at timestamptz;/);
  assert.match(sql, /create table if not exists booking\.waitlist_session_state \(/);
  assert.match(sql, /references booking\.schedule_rules\(id\) on delete cascade/);
  assert.match(sql, /alter table booking\.waitlist_session_state enable row level security;/);
  assert.match(sql, /revoke all on booking\.waitlist_session_state from public, anon, authenticated;/);
  assert.doesNotMatch(sql, /grant [a-z, ]+ on booking\.waitlist_session_state to (anon|authenticated)/);
  assert.doesNotMatch(sql, /\bpublic\.[a-z_]+/i, 'ei public-skeemaa');
  assert.doesNotMatch(sql, /drop table|drop column/i);
});

test('migraatio booking_139: yksi pito per vuoro, ei kasautumista, vanhentunut pito → kaikille ilman pitoa', () => {
  const p = code(fn(rd(MIG), '_waitlist_process_session'));
  assert.match(p, /pg_try_advisory_xact_lock\(hashtextextended\('booking:waitlist:'\|\|p_rule_id\|\|':'\|\|p_date, 0\)\)/);
  assert.match(p, /booking\._waitlist_offer_expires_at\(/, '48 h / 120 min -asetukset booking_137:stä');
  assert.match(p, /least\(booking\.waitlist_session_state\.offered_free, excluded\.offered_free\)/, 'pidon aikana vain lasku kirjataan');
  assert.match(p, /v_mode := case when v_hold_until is not null and v_cur > v_offered then 'hold' else 'all' end;/);
  assert.match(p, /and \(v_mode = 'all' or hold_expires_at is null\)/, 'pito vain sille, jolla ei ole ollut pitoa');
  assert.match(p, /if v_mode = 'hold' and v_n = 0 then/, 'ei pitokelpoista → ilmoitus kaikille ilman pitoa');
  const claim = code(fn(rd(MIG), 'public_waitlist_claim'));
  assert.doesNotMatch(claim, /offer_expired/);
  assert.match(claim, /'hold_expired',v_hold_expired/);
});

test('migraatio booking_139: sweep vain service_rolelle, pg_cron minuutin välein suojattuna', () => {
  const sql = rd(MIG);
  assert.match(sql, /revoke all on function booking\.waitlist_sweep\(\) from public,anon,authenticated;/);
  assert.match(sql, /grant execute on function booking\.waitlist_sweep\(\) to service_role;/);
  for (const f of ['_waitlist_notify_entry(bigint,timestamptz)', '_waitlist_process_session(bigint,date)', '_notify_waitlist_for_window(bigint,timestamptz,timestamptz)'])
    assert.ok(sql.includes(`revoke all on function booking.${f} from public,anon,authenticated;`), f);
  assert.match(sql, /to_regprocedure\('cron\.schedule\(text,text,text\)'\) is not null/);
  assert.match(sql, /cron\.schedule\('booking_waitlist_sweep', '\* \* \* \* \*', 'select booking\.waitlist_sweep\(\)'\)/);
  for (const name of ['_waitlist_notify_entry', '_waitlist_process_session', '_notify_waitlist_for_window', 'waitlist_sweep', 'public_waitlist_claim'])
    assert.match(fn(sql, name), /security definer set search_path = ''/, name);
});

test('rollback booking_139: booking_137:n funktiot takaisin, uudet oliot pois oikeassa järjestyksessä', () => {
  const rb = rd(RB); const m137 = rd(MIG137);
  assert.match(rb, /cron\.unschedule\('booking_waitlist_sweep'\)/);
  assert.match(rb, /CREATE OR REPLACE FUNCTION booking\._notify_waitlist_for_window\(/);
  assert.match(rb, /CREATE OR REPLACE FUNCTION booking\.public_waitlist_claim\(p_token uuid\)/);
  for (const s of ["return jsonb_build_object('ok',false,'code','offer_expired');", 'and booking._waitlist_offer_expires_at(coalesce(o.notified_at,o.updated_at),o.starts_at) > now()'])
    assert.ok(rb.includes(s) && m137.includes(s), s);
  const fns = code(rb.slice(0, rb.indexOf('drop function')));
  assert.doesNotMatch(fns, /hold_expires_at|waitlist_session_state|_waitlist_process_session|_waitlist_notify_entry/);
  const iDrop = rb.indexOf('drop function if exists booking.waitlist_sweep();');
  assert.ok(iDrop > rb.lastIndexOf('CREATE OR REPLACE FUNCTION'));
  assert.ok(rb.indexOf('drop table if exists booking.waitlist_session_state;') > iDrop);
  assert.ok(rb.indexOf('alter table booking.waitlist_entries drop column if exists hold_expires_at;') > iDrop);
});

test('t139: kattaa skenaariot a–e ja tekniset tarkistukset', () => {
  const t = rd(T139);
  for (const l of ['A4: ensimmäinen mahtuva B1 saa pidon ja yhden viestin', 'A6: A, C ja D odottavat (D ei saa toista pitoa)', 'A10: uudet ajot ja sweep pidon aikana → ei mitään',
    'B1: sweep: C4 ja D3 saavat ilmoituksen', 'B2: ei uutta pitoa', 'B6: vanhentunut pito → lunastus ok (hold_expired), ei offer_expired', 'B7: vanhentuneen pidon haltija varaa normaalisti',
    'B10: paikka on vapaasti myynnissä', 'C3: kaikki mahtuvat Q1, R4, S3 saavat ilmoituksen', 'C5: ei pitoa',
    'D4: vapautuminen pidon aikana → ei toista pitoa', 'D6: uusi vapautuminen → yksi pito W2:lle', 'D14: uusi vapautuminen → pito W3:lle',
    'D18: uusi vapautuminen, kaikilla jo ollut pito → ilmoitus kaikille mahtuville ilman pitoa', 'E5: toistuvat sweepit ja ajot eivät lähetä lisää',
    'T3: tilataulu: RLS, ei oikeuksia', 'T5: pg_cron-ajo minuutin välein']) assert.ok(t.includes(l), l);
  assert.match(t, /raise exception 'TESTRESULT pass=% fail=%/);
});

test('kauppa: hold_expired → oma teksti, tavallinen varaus (ei lukitusta, ei estoa); offer_expired-haara säilyy rollbackia varten', () => {
  const shop = rd('booking/shop/src/shop.js');
  assert.match(shop, /else if \(c\?\.ok && c\.hold_expired\) wlNote = h\('p', \{ class: 'bk-note', role: 'status', text: t\.waitlistClaimExpired \}\);/);
  assert.ok(shop.indexOf('c?.ok && c.hold_expired') < shop.indexOf('t.waitlistClaimNotEnough'), 'ennen ei mahdu -estoa');
  assert.match(shop, /c\.code === 'offer_expired' \? t\.waitlistClaimExpired/);
  assert.ok(!existsSync(resolve(repo, 'content/site-texts.pending-import-40.json')), 'ei uusia tekstejä (teksti ui.shop.waitlist_claim_expired on pending-import-39:ssä)');
});
