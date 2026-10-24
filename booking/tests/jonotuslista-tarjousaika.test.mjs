// booking_137: jonotuslistan pito. Vuoroon ≥ waitlist_hold_min_hours_before (48) h ilmoitushetkellä → ensimmäinen mahtuva,
// pito waitlist_offer_minutes (120) min; alle 48 h → ei pitoa, ilmoitus kaikille mahtuville. Puuttuva/virheellinen asetus →
// 48 h / 120 min. Pito tarkistetaan sekä _notify_waitlist_for_window-funktiossa (voimassa olevien pitojen vähennys) että
// public_waitlist_claim-funktiossa (vanhentunut pito → offer_expired). Kaupassa offer_expired näyttää oman tekstin (ui.shop.waitlist_claim_expired, pending-import-39).
// SQL-käytös: booking/supabase/tests/waitlist/t137_waitlist_offer_window.sql (paikallinen PG17, ei työnkulussa).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { WAITLIST_TEXTS } from '../shop/src/waitlist-texts.js';

const repo = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(resolve(repo, p), 'utf8');
const code = (s) => s.replace(/--[^\n]*/g, ''); // ilman SQL-kommentteja
const MIG = 'booking/supabase/migrations/20261024080249_booking_137_waitlist_offer_window.sql';
const RB = 'booking/supabase/rollbacks/20261024080249_booking_137_ROLLBACK.sql';
const T137 = 'booking/supabase/tests/waitlist/t137_waitlist_offer_window.sql';
const MIG135 = 'booking/supabase/migrations/20261024073352_booking_135_waitlist_notified_capacity.sql';
const fn = (sql, name) => { const i = sql.indexOf(`create or replace function booking.${name}(`); assert.ok(i >= 0, name); const j = sql.indexOf('end $$;', i); return sql.slice(i, j); };

test('booking_137: migraatio, rollback ja SQL-testi ovat olemassa, aikaleima booking_135:n ja booking_136:n (20261024073642) jälkeen', () => {
  for (const p of [MIG, RB, T137]) assert.ok(existsSync(resolve(repo, p)), p);
  assert.ok('20261024080249' > '20261024073642' && '20261024080249' > '20261024073352');
});

test('migraatio booking_137: apufunktio: pito vain, kun vuoroon ≥ 48 h, kesto 120 min, virheellinen asetus → oletus', () => {
  const sql = rd(MIG);
  const h = code(fn(sql, '_waitlist_offer_expires_at'));
  assert.match(sql, /create or replace function booking\._waitlist_offer_expires_at\(p_notified_at timestamptz, p_starts_at timestamptz\)\s+returns timestamptz language plpgsql stable security definer set search_path = ''/);
  assert.match(h, /v_hours integer := 48;/);
  assert.match(h, /v_mins integer := 120;/);
  assert.match(h, /booking\._setting\('waitlist_hold_min_hours_before'\) #>> '\{\}'/);
  assert.match(h, /booking\._setting\('waitlist_offer_minutes'\) #>> '\{\}'/);
  assert.match(h, /if v_raw ~ '\^\[0-9\]\{1,5\}\$' then v_hours := v_raw::int; end if;/);
  assert.match(h, /if p_starts_at - p_notified_at < make_interval\(hours => v_hours\) then return null; end if;/, 'alle rajan → ei pitoa');
  assert.match(h, /if v_raw ~ '\^\[0-9\]\{1,6\}\$' then\s+if v_raw::int >= 1 then v_mins := v_raw::int; end if;/, 'muunnos vasta validoinnin jälkeen');
  assert.doesNotMatch(sql, /waitlist_offer_minutes_same_day|Europe\/Helsinki'\)::date >=/);
  assert.match(sql, /revoke all on function booking\._waitlist_offer_expires_at\(timestamptz,timestamptz\) from public,anon,authenticated;/);
  assert.doesNotMatch(sql, /grant execute on function booking\._waitlist_offer_expires_at/);
});

test('migraatio booking_137: asetusrivit idempotentisti, olemassa olevaa arvoa ei ylikirjoiteta', () => {
  const sql = rd(MIG);
  assert.match(sql, /insert into booking\.settings\(key, value, description\) values\s+\('waitlist_offer_minutes', '120'::jsonb, '[^']*'\),\s+\('waitlist_hold_min_hours_before', '48'::jsonb, '[^']*'\)\s+on conflict \(key\) do nothing;/);
  assert.doesNotMatch(code(sql), /do update|update booking\.settings/);
});

test('migraatio booking_137: notify ja claim käyttävät samaa voimassaoloa; claim → offer_expired', () => {
  const sql = rd(MIG);
  const notify = code(fn(sql, '_notify_waitlist_for_window'));
  assert.match(notify, /and booking\._waitlist_offer_expires_at\(coalesce\(o\.notified_at,o\.updated_at\),o\.starts_at\) > now\(\)/);
  assert.doesNotMatch(notify, /v_offer|waitlist_offer_minutes/, 'booking_135:n kiinteä 60 min poistettu');
  assert.match(notify, /order by created_at,id for update skip locked/);
  assert.match(notify, /v_left := v_s\.remaining - v_held;\s+if v_left < w\.persons then continue; end if;/);
  const claim = code(fn(sql, 'public_waitlist_claim'));
  const iRl = claim.indexOf("booking._rate_limit('waitlist:claim:' || p_token::text, 30, interval '10 minutes')");
  const iExp = claim.indexOf("if w.starts_at <= now() then return jsonb_build_object('ok',false,'code','expired'); end if;");
  assert.match(claim, /v_exp := booking\._waitlist_offer_expires_at\(coalesce\(w\.notified_at,w\.updated_at\),w\.starts_at\);/);
  const iOffer = claim.indexOf("if w.status = 'notified' and v_exp is not null and v_exp <= now() then");
  const iSess = claim.indexOf('booking._sessions(');
  assert.ok(iRl > 0 && iExp > iRl && iOffer > iExp && iSess > iOffer, 'rate limit → expired → offer_expired (vain pidossa ollut) → mahtuvuus');
  assert.match(claim, /return jsonb_build_object\('ok',false,'code','offer_expired'\);/);
  assert.match(sql, /grant execute on function booking\.public_waitlist_claim\(uuid\) to anon,authenticated,service_role;/);
  assert.match(sql, /revoke all on function booking\._notify_waitlist_for_window\(bigint,timestamptz,timestamptz\) from public,anon,authenticated;/);
});

test('migraatio booking_137: ei taulumuutoksia, ei public-skeemaa, uudelleenajettava', () => {
  const sql = code(rd(MIG));
  assert.doesNotMatch(sql, /alter table|drop table|create table|drop function/i);
  assert.doesNotMatch(sql, /\bpublic\.[a-z_]+/i, 'ei public-skeemaa');
  const creates = sql.match(/create (or replace )?function/gi) || [];
  assert.equal(creates.length, 3);
  assert.ok(creates.every((c) => /or replace/i.test(c)), 'vain create or replace');
});

test('rollback booking_137: booking_135:n funktiot, apufunktio pois, asetusrivit vain oletusarvoisina', () => {
  const rb = rd(RB); const m135 = rd(MIG135);
  assert.match(rb, /CREATE OR REPLACE FUNCTION booking\._notify_waitlist_for_window\(/);
  assert.match(rb, /CREATE OR REPLACE FUNCTION booking\.public_waitlist_claim\(p_token uuid\)/);
  for (const s of ["v_offer_raw text := booking._setting('waitlist_offer_minutes','60'::jsonb) #>> '{}';", 'coalesce(o.notified_at,o.updated_at) + v_offer > now()']) {
    assert.ok(rb.includes(s) && m135.includes(s), s);
  }
  const fns = code(rb.slice(0, rb.indexOf('drop function')));
  assert.doesNotMatch(fns, /_waitlist_offer_expires_at|offer_expired|waitlist_hold_min_hours_before/);
  assert.match(rb, /drop function if exists booking\._waitlist_offer_expires_at\(timestamptz,timestamptz\);/);
  assert.ok(rb.indexOf('drop function') > rb.lastIndexOf('CREATE OR REPLACE FUNCTION'), 'pudotus vasta, kun funktiot eivät viittaa siihen');
  assert.match(rb, /delete from booking\.settings where key = 'waitlist_hold_min_hours_before' and value = '48'::jsonb;/);
  assert.match(rb, /delete from booking\.settings where key = 'waitlist_offer_minutes' and value = '120'::jsonb;/);
  assert.equal((code(rb).match(/delete from/gi) || []).length, 2);
  assert.doesNotMatch(rb, /drop table|alter table/i);
});

test('t137: kattaa 47 h (kaikki mahtuvat, ei pitoa), 49 h (ensimmäinen, pito 119/121 min), pidon vanhenemisen alle 48 h:ssa ja ison jonovarauksen', () => {
  const t = rd(T137);
  for (const l of ['B1: vuoro 47 h päässä → ei pitoa', 'B3: 49 h, 119 min → pito voimassa', 'B4: 49 h, 121 min → pito vanhentunut',
    'D4: alle 48 h: kaikki mahtuvat', 'D5: isompi C5 ei mahdu → ei ilmoitusta', 'D8: uusi ajo → ei uusia ilmoituksia samoille (idempotenssi)',
    'E3: yli 48 h: vain ensimmäinen mahtuva P4 saa ilmoituksen', 'E4: isompi R5', 'E6: 119 min → pito voimassa', 'E8: 121 min → pito vanhentunut (hold_expired), ei offer_expired',
    'F5: X:n pito vanheni alle 48 h ennen vuoroa → Y2 ja Z3 molemmat saavat ilmoituksen']) assert.ok(t.includes(l), l);
  assert.match(t, /raise exception 'TESTRESULT pass=% fail=%/);
});

test('kauppa: offer_expired näyttää oman tekstin, muut virheet ennallaan', () => {
  const shop = rd('booking/shop/src/shop.js');
  assert.match(shop, /text: c\.code === 'offer_expired' \? t\.waitlistClaimExpired : t\.waitlistClaimInvalid/);
  for (const l of ['fi', 'en']) {
    assert.ok(WAITLIST_TEXTS[l].waitlistClaimExpired && WAITLIST_TEXTS[l].waitlistClaimExpired !== WAITLIST_TEXTS[l].waitlistClaimInvalid, l);
    assert.doesNotMatch(WAITLIST_TEXTS[l].waitlistClaimExpired, /[<>{}]/);
  }
  const rows = JSON.parse(rd('content/site-texts.pending-import-39.json'));
  assert.deepEqual(rows.map((r) => `${r.key}|${r.lang}`), ['ui.shop.waitlist_claim_expired|fi', 'ui.shop.waitlist_claim_expired|en']);
  for (const r of rows) assert.equal(r.text, WAITLIST_TEXTS[r.lang].waitlistClaimExpired);
});
