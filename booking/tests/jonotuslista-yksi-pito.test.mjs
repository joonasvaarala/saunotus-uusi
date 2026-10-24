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
const T139H = 'booking/supabase/tests/waitlist/t139_waitlist_hold_off_sale.sql';
const MIG137 = 'booking/supabase/migrations/20261024080249_booking_137_waitlist_offer_window.sql';
const fnU = (sql, name) => { const i = sql.indexOf(`CREATE OR REPLACE FUNCTION booking.${name}(`); assert.ok(i >= 0, name); const j = sql.indexOf('$function$', sql.indexOf('$function$', i) + 10); return sql.slice(i, j); };
const fn = (sql, name) => { const i = sql.indexOf(`create or replace function booking.${name}(`); assert.ok(i >= 0, name); const j = sql.indexOf('end $$;', i); return sql.slice(i, j); };

test('booking_139: migraatio, rollback ja SQL-testit olemassa, aikaleima booking_137:n ja booking_138:n jälkeen, numero 139 ainoa', () => {
  for (const p of [MIG, RB, T139, T139H]) assert.ok(existsSync(resolve(repo, p)), p);
  const migs = readdirSync(resolve(repo, 'booking/supabase/migrations')).filter((f) => f.endsWith('.sql')).sort();
  const i = migs.indexOf('20261024115000_booking_139_waitlist_single_hold.sql');
  assert.ok(i > migs.findIndex((f) => /_booking_138_/.test(f)) && i > migs.indexOf('20261024080249_booking_137_waitlist_offer_window.sql'));
  assert.equal(migs.filter((f) => /_booking_139_/.test(f)).length, 1, 'vain yksi booking_139 (numero 140 on toisen työn)');
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
  assert.doesNotMatch(fns, /(?<![.'])hold_expires_at|waitlist_session_state|_waitlist_process_session|_waitlist_notify_entry/);
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

test('migraatio booking_139: pidon aikana paikka ei ole julkisessa myynnissä (_pool_peak), haltija, henkilökunta ja lukitus', () => {
  const sql = rd(MIG);
  const peak = code(fnU(sql, '_pool_peak'));
  assert.match(peak, /LANGUAGE plpgsql/, 'suunnitelma välimuistiin (booking_133-nopeutus säilyy)');
  assert.match(peak, /begin\s+return \(\s+with rs as materialized \(/);
  assert.match(peak, /from booking\.waitlist_entries w/);
  assert.match(peak, /w\.status = 'notified' and w\.hold_expires_at > now\(\)/, 'vanheneminen palauttaa myyntiin now()-ehdolla');
  assert.match(peak, /booking\._waitlist_hold_counts\(w\.id\)/);
  const hc = code(sql.slice(sql.indexOf('create or replace function booking._waitlist_hold_counts('), sql.indexOf('create index if not exists waitlist_entries_active_hold_idx')));
  assert.match(hc, /current_setting\('booking\.waitlist_hold_exempt', true\)/);
  assert.match(hc, /when 'all' then false\s+when p_id::text then false/, 'jonon sisäinen laskenta ja haltijan oma pito');
  assert.match(hc, /'service_role' or booking\.is_staff\(\)/, 'henkilökunta ja service_role ohittavat pidon');
  assert.match(sql, /revoke all on function booking\._waitlist_hold_counts\(bigint\) from public,anon,authenticated;/);
  assert.match(sql, /create index if not exists waitlist_entries_active_hold_idx on booking\.waitlist_entries \(starts_at\)\s+where status = 'notified' and hold_expires_at is not null;/);
  const pcb = code(fnU(sql, 'public_create_booking'));
  assert.match(pcb, /set_config\('booking\.waitlist_hold_exempt'/, 'haltijan oma pito ei vähennä');
  assert.match(pcb, /lower\(w\.customer_email\) = v_email/);
  const claim = code(fn(sql, 'public_waitlist_claim'));
  assert.match(claim, /set_config\('booking\.waitlist_hold_exempt', ?w\.id::text, ?true\)/);
  assert.match(claim, /'remaining',/);
  const proc = code(fn(sql, '_waitlist_process_session'));
  assert.match(proc, /pg_try_advisory_xact_lock\(hashtextextended\('booking:space:' \|\| v_space::text, 0\)\)/, 'sama tilalukko kuin varaustarkistuksella');
  assert.match(code(fnU(sql, 'admin_day_view')), /'waitlist_holds'/);
});

test('rollback booking_139: saatavuuspolut takaisin booking_138-tilaan, indeksi ja apufunktio pois', () => {
  const rb = rd(RB);
  for (const f of ['_pool_peak(', 'public_create_booking(', 'admin_day_view('])
    assert.ok(rb.includes(`CREATE OR REPLACE FUNCTION booking.${f}`), f);
  const fns = code(rb.slice(0, rb.indexOf('drop function')));
  assert.doesNotMatch(fns, /waitlist_hold_exempt|_waitlist_hold_counts|waitlist_holds/);
  assert.match(rb, /drop function if exists booking\._waitlist_hold_counts\(bigint\);/);
  assert.match(rb, /drop index if exists booking\.waitlist_entries_active_hold_idx;/);
  assert.ok(rb.indexOf('drop function if exists booking._waitlist_hold_counts(bigint);') > rb.lastIndexOf('CREATE OR REPLACE FUNCTION'));
});

test('t139 osa 2: pidon aikana ei julkisessa myynnissä — skenaariot', () => {
  const t = rd(T139H);
  for (const l of ['A3: julkinen haku', 'A6: viimeiseen pidettyyn paikkaan ei voi varata', 'A7: ajanmuutos pidettyyn paikkaan ei onnistu',
    'B1: haltijan lunastus', 'B2: haltija varaa pidetyt 2 paikkaa', 'B3: varaus vapauttaa pidon heti', 'B4: ei ylivarausta',
    'C2: pito vanheni → kaikki 4 heti myynnissä', 'C3: sweep ilmoittaa', 'D2: jonosta poistuminen vapauttaa pidetyt paikat heti',
    'E2: alle 48 h: kaikki 4 julkisesti myynnissä', 'F3: saman poolin toinen vuoro', 'G3: admin_day_view.waitlist_holds', 'G4: henkilökunta voi ohittaa pidon'])
    assert.ok(t.includes(l), l);
  assert.match(t, /raise exception 'TESTRESULT pass=% fail=%/);
});

test('kauppa ja hallinta: haltijan raja lunastuksen remaining-arvosta, hallinta näyttää pidon (FI+EN)', () => {
  const shop = rd('booking/shop/src/shop.js');
  assert.match(shop, /let max = Math\.max\(s\.min_persons, Math\.min\(s\.max_persons \|\| 50, s\.remaining\)\);/);
  assert.match(shop, /c\.enough && !c\.hold_expired && c\.remaining != null && Number\.isFinite\(\+c\.remaining\)\) max = Math\.max\(max, Math\.min\(s\.max_persons \|\| 50, \+c\.remaining\)\);/);
  assert.ok(shop.indexOf('max = Math.max(max,') < shop.indexOf('t.waitlistClaimNotEnough'));
  const nb = rd('booking/admin/views/newbooking.js');
  assert.match(nb, /v\.waitlist_holds \|\| \[\]/);
  assert.match(nb, /T\('nb\.hold', /);
  assert.match(nb, /T\('nb\.holdHint', /);
  const tx = rd('booking/admin/nb-texts.js');
  assert.equal((tx.match(/'nb\.hold':/g) || []).length, 2, 'FI + EN');
  assert.equal((tx.match(/'nb\.holdHint':/g) || []).length, 2, 'FI + EN');
  assert.doesNotMatch(tx.slice(tx.indexOf("'nb.hold'")), /'nb\.hold[^']*': '[^']*</);
});
