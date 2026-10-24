// booking_137: jonotuslistan tarjousaika. Sama Helsingin päivä → 30 min (waitlist_offer_minutes_same_day), seuraava päivä
// tai myöhemmin → 120 min (waitlist_offer_minutes); puuttuva/virheellinen asetus → 30 / 120. Voimassaolo tarkistetaan sekä
// _notify_waitlist_for_window-funktiossa (voimassa olevien tarjousten vähennys) että public_waitlist_claim-funktiossa
// (vanhentunut → offer_expired). Kaupassa offer_expired näyttää oman tekstin (ui.shop.waitlist_claim_expired, pending-import-39).
// SQL-käytös: booking/supabase/tests/waitlist/t137_waitlist_offer_window.sql (paikallinen PG17, ei työnkulussa).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { WAITLIST_TEXTS } from '../shop/src/waitlist-texts.js';

const repo = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(resolve(repo, p), 'utf8');
const code = (s) => s.replace(/--[^\n]*/g, ''); // ilman SQL-kommentteja
const MIG = 'booking/supabase/migrations/20261024095000_booking_137_waitlist_offer_window.sql';
const RB = 'booking/supabase/rollbacks/20261024095000_booking_137_ROLLBACK.sql';
const T137 = 'booking/supabase/tests/waitlist/t137_waitlist_offer_window.sql';
const MIG135 = 'booking/supabase/migrations/20261024073352_booking_135_waitlist_notified_capacity.sql';
const fn = (sql, name) => { const i = sql.indexOf(`create or replace function booking.${name}(`); assert.ok(i >= 0, name); const j = sql.indexOf('end $$;', i); return sql.slice(i, j); };

test('booking_137: migraatio, rollback ja SQL-testi ovat olemassa, aikaleima booking_135:n ja booking_136:n (20261024073642) jälkeen', () => {
  for (const p of [MIG, RB, T137]) assert.ok(existsSync(resolve(repo, p)), p);
  assert.ok('20261024095000' > '20261024073642' && '20261024095000' > '20261024073352');
});

test('migraatio booking_137: apufunktio 30 / 120 min Helsingin päivän mukaan, virheellinen asetus → oletus', () => {
  const sql = rd(MIG);
  const h = code(fn(sql, '_waitlist_offer_expires_at'));
  assert.match(sql, /create or replace function booking\._waitlist_offer_expires_at\(p_notified_at timestamptz, p_starts_at timestamptz\)\s+returns timestamptz language plpgsql stable security definer set search_path = ''/);
  assert.match(h, /\(p_notified_at at time zone 'Europe\/Helsinki'\)::date >= \(p_starts_at at time zone 'Europe\/Helsinki'\)::date/);
  assert.match(h, /case when v_same then 30 else 120 end/);
  assert.match(h, /case when v_same then 'waitlist_offer_minutes_same_day' else 'waitlist_offer_minutes' end/);
  assert.match(h, /v_raw ~ '\^\[0-9\]\{1,6\}\$' then\s+case when v_raw::int >= 1 then v_raw::int else v_def end else v_def end/, 'muunnos vasta validoinnin jälkeen');
  assert.match(sql, /revoke all on function booking\._waitlist_offer_expires_at\(timestamptz,timestamptz\) from public,anon,authenticated;/);
  assert.doesNotMatch(sql, /grant execute on function booking\._waitlist_offer_expires_at/);
});

test('migraatio booking_137: asetusrivit idempotentisti, olemassa olevaa arvoa ei ylikirjoiteta', () => {
  const sql = rd(MIG);
  assert.match(sql, /insert into booking\.settings\(key, value, description\) values\s+\('waitlist_offer_minutes_same_day', '30'::jsonb, '[^']*'\),\s+\('waitlist_offer_minutes', '120'::jsonb, '[^']*'\)\s+on conflict \(key\) do nothing;/);
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
  const iOffer = claim.indexOf("if w.status = 'notified' and booking._waitlist_offer_expires_at(coalesce(w.notified_at,w.updated_at),w.starts_at) <= now() then");
  const iSess = claim.indexOf('booking._sessions(');
  assert.ok(iRl > 0 && iExp > iRl && iOffer > iExp && iSess > iOffer, 'rate limit → expired → offer_expired → mahtuvuus');
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
  assert.doesNotMatch(fns, /_waitlist_offer_expires_at|offer_expired|waitlist_offer_minutes_same_day/);
  assert.match(rb, /drop function if exists booking\._waitlist_offer_expires_at\(timestamptz,timestamptz\);/);
  assert.ok(rb.indexOf('drop function') > rb.lastIndexOf('CREATE OR REPLACE FUNCTION'), 'pudotus vasta, kun funktiot eivät viittaa siihen');
  assert.match(rb, /delete from booking\.settings where key = 'waitlist_offer_minutes_same_day' and value = '30'::jsonb;/);
  assert.match(rb, /delete from booking\.settings where key = 'waitlist_offer_minutes' and value = '120'::jsonb;/);
  assert.equal((code(rb).match(/delete from/gi) || []).length, 2);
  assert.doesNotMatch(rb, /drop table|alter table/i);
});

test('t137: kattaa 29/31 min, 119/121 min, päivänrajan ja offer_expired', () => {
  const t = rd(T137);
  for (const l of ['B2: sama päivä, 29 min → voimassa', 'B3: sama päivä, 31 min → vanhentunut', 'C2: seuraava päivä, 119 min → voimassa',
    'C3: seuraava päivä, 121 min → vanhentunut', 'D1: ilmoitus 23:50, vuoro 00:30 seuraavana päivänä → 120 min',
    'F7: A:n tarjous 121 min → vanhentunut, B saa ilmoituksen', 'F8: A:n lunastus 121 min jälkeen → offer_expired']) assert.ok(t.includes(l), l);
  assert.match(t, /'2026-11-10 23:50 Europe\/Helsinki', '2026-11-11 00:30 Europe\/Helsinki'/);
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
