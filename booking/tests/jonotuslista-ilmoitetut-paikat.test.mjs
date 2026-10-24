// booking_135: jonotuslistan voimassa olevat ilmoitukset vähennetään vapaista paikoista myös seuraavissa ajoissa
// (sama vuoro + kapasiteettipoolin jakavat päällekkäiset vuorot), tarjouksen voimassaolo (waitlist_offer_minutes)
// ja public_waitlist_claim-rate limit vain tunnetulle tokenille. Migraation ja rollbackin rakenne.
// SQL-käytös: booking/supabase/tests/waitlist/t135_waitlist_notified_capacity.sql (ajetaan paikallisessa PG17:ssä
// migraatioiden ja fixtures/10_test_helpers.sql:n jälkeen; työnkulussa ei ole Postgresia).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

const repo = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(resolve(repo, p), 'utf8');
const code = (s) => s.replace(/--[^\n]*/g, ''); // ilman SQL-kommentteja
const MIG = 'booking/supabase/migrations/20261024073352_booking_135_waitlist_notified_capacity.sql';
const RB = 'booking/supabase/rollbacks/20261024073352_booking_135_ROLLBACK.sql';
const T135 = 'booking/supabase/tests/waitlist/t135_waitlist_notified_capacity.sql';
const MIG134 = 'booking/supabase/migrations/20261024071019_booking_134_waitlist_party_size.sql';

test('booking_135: migraatio, rollback ja SQL-testi ovat olemassa', () => {
  for (const p of [MIG, RB, T135]) assert.ok(existsSync(resolve(repo, p)), p);
  assert.ok('20261024073352' > '20261024071019', 'aikaleima booking_134:n jälkeen');
});

test('migraatio booking_135: voimassa olevat ilmoitukset vähennetään, poolit mukana, tarjous vanhenee', () => {
  const sql = rd(MIG);
  assert.match(sql, /create or replace function booking\._notify_waitlist_for_window\(p_space_id bigint,p_starts_at timestamptz,p_ends_at timestamptz\)/);
  assert.match(sql, /order by created_at,id for update skip locked/, 'jonon järjestys säilyy');
  assert.match(sql, /o\.status='notified' and o\.id<>w\.id and o\.starts_at>now\(\)/);
  assert.match(sql, /coalesce\(o\.notified_at,o\.updated_at\) \+ v_offer > now\(\)/, 'vain voimassa olevat tarjoukset');
  assert.match(sql, /booking\._setting\('waitlist_offer_minutes','60'::jsonb\)/);
  assert.match(sql, /greatest\(1, case when v_offer_raw ~ '\^\[0-9\]\{1,6\}\$' then v_offer_raw::int else 60 end\)/, 'virheellinen asetus ei kaada');
  assert.match(sql, /o\.rule_id=w\.rule_id and o\.session_date=w\.session_date/);
  assert.match(sql, /booking\.schedule_rule_pools a\s+join booking\.schedule_rule_pools b on b\.pool_id=a\.pool_id/, 'kapasiteettipooli');
  assert.match(sql, /o\.starts_at<w\.ends_at and o\.ends_at>w\.starts_at/, 'päällekkäiset vuorot');
  assert.match(sql, /v_left := v_s\.remaining - v_held;\s+if v_left < w\.persons then continue; end if;/);
  assert.doesNotMatch(code(sql), /v_used/);
  assert.match(sql, /revoke all on function booking\._notify_waitlist_for_window\(bigint,timestamptz,timestamptz\) from public,anon,authenticated;/);
});

test('migraatio booking_135: claim-rate limit vasta tunnetulle tokenille, kutsujan IP-raja', () => {
  const sql = rd(MIG);
  const claim = sql.slice(sql.indexOf('create or replace function booking.public_waitlist_claim'));
  const iFind = claim.indexOf("where public_token = p_token and status in ('waiting','notified') for update");
  const iNotFound = claim.indexOf("if not found then return jsonb_build_object('ok',false,'code','not_found')");
  const iRl = claim.indexOf("booking._rate_limit('waitlist:claim:' || p_token::text, 30, interval '10 minutes')");
  assert.ok(iFind > 0 && iNotFound > iFind && iRl > iNotFound, 'haku → not_found → rate limit');
  assert.match(claim, /v_ip is not null and not booking\._rate_limit\('waitlist:claim:ip:' \|\| v_ip, 60, interval '10 minutes'\)/);
  assert.match(claim, /v_enough := found and v_s\.starts_at = w\.starts_at and v_s\.status = 'available' and v_s\.remaining >= w\.persons;/);
  assert.match(claim, /'persons',w\.persons,'enough',v_enough/);
  assert.doesNotMatch(claim, /'customer_email'|'customer_name'/);
  assert.match(sql, /grant execute on function booking\.public_waitlist_claim\(uuid\) to anon,authenticated,service_role;/);
});

test('migraatio booking_135: ei taulumuutoksia, ei public-skeemaa, uudelleenajettava', () => {
  const sql = rd(MIG);
  assert.doesNotMatch(sql, /alter table|drop table|create table|insert into booking\.settings/i);
  assert.doesNotMatch(sql, /\bpublic\.[a-z_]+/i, 'ei public-skeemaa');
  const creates = sql.match(/create (or replace )?function/gi) || [];
  assert.equal(creates.length, 2);
  assert.ok(creates.every((c) => /or replace/i.test(c)), 'vain create or replace');
});

test('rollback booking_135: palauttaa booking_134:n funktiot', () => {
  const rb = rd(RB); const m134 = rd(MIG134);
  assert.match(rb, /CREATE OR REPLACE FUNCTION booking\._notify_waitlist_for_window\(/);
  assert.match(rb, /CREATE OR REPLACE FUNCTION booking\.public_waitlist_claim\(p_token uuid\)/);
  // booking_134:n tunnusmerkit: v_used-laskuri ja rate limit ennen hakua
  assert.match(rb, /v_left := v_s\.remaining - coalesce\(\(v_used->>v_k\)::int,0\);/);
  assert.match(m134, /v_left := v_s\.remaining - coalesce\(\(v_used->>v_k\)::int,0\);/);
  const claim = rb.slice(rb.indexOf('booking.public_waitlist_claim(p_token uuid)'));
  assert.ok(claim.indexOf("booking._rate_limit('waitlist:claim:' || p_token::text") < claim.indexOf('where public_token = p_token'));
  assert.doesNotMatch(code(rb), /v_held|v_offer|waitlist_offer_minutes|waitlist:claim:ip:/);
  assert.match(rb, /grant execute on function booking\.public_waitlist_claim\(uuid\) to anon,authenticated,service_role;/);
  assert.match(rb, /revoke all on function booking\._notify_waitlist_for_window\(bigint,timestamptz,timestamptz\) from public,anon,authenticated;/);
  assert.doesNotMatch(rb, /delete from|drop table|alter table|drop function/i, 'ei dataa poisteta, ei funktioita pudoteta');
});

test('t135: kattaa tuotannon tapauksen, vanhenemisen, poolin ja rate limitin', () => {
  const t = rd(T135);
  assert.match(t, /C2: C ei saa samoja 4 paikkaa/);
  assert.match(t, /D3: C saa vapautuneet 4 paikkaa/);
  assert.match(t, /E5: Q \(toinen sääntö, sama pooli\)/);
  assert.match(t, /F2: tuntemattomat tokenit eivät luo rate limit -rivejä/);
  assert.match(t, /raise exception 'TESTRESULT pass=% fail=%/);
});
