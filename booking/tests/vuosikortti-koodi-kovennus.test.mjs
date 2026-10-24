// Paketti 10 jatko / booking_143: vuosikorttikoodien kovennus, vuosikorttivarauksen alennus ja peruutuksen käyttökerran palautus.
// Migraation ja rollbackin rakenne sekä rajaukset (mitä EI muuteta). SQL-käyttäytyminen testataan PG17:ssä:
// booking/supabase/tests/discounts/t143_annual_code_hardening.sql (CI:ssä ei Postgresia).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { generatedAnnualCardCode, ANNUAL_ALPHABET, ANNUAL_CODE_LENGTH, validCodeFormat } from '../shop/src/discount-code-logic.js';
import { DISCOUNT_TEXTS } from '../shop/src/discount-texts.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(resolve(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024160000_booking_143_annual_code_hardening.sql';
const SQL = rd(MIG);
const RB = rd('booking/supabase/rollbacks/20261024160000_booking_143_ROLLBACK.sql');
const SQL142 = rd('booking/supabase/migrations/20261024104958_booking_142_annual_cards_discount_codes.sql');
const T143 = rd('booking/supabase/tests/discounts/t143_annual_code_hardening.sql');
const fn = (src, name) => {
  const m = src.match(new RegExp(`create or replace function booking\\.${name}\\([\\s\\S]*?\\$(function)?\\$;`, 'i'));
  assert.ok(m, `${name} puuttuu`); return m[0];
};

test('migraatio tulee booking_142:n jälkeen ja kirjoittaa vain booking-skeemaan', () => {
  const files = readdirSync(resolve(root, 'booking/supabase/migrations')).filter((f) => f.endsWith('.sql')).sort();
  const i143 = files.indexOf(MIG.split('/').at(-1)), i142 = files.indexOf('20261024104958_booking_142_annual_cards_discount_codes.sql');
  assert.ok(i142 >= 0 && i143 > i142);
  assert.doesNotMatch(SQL, /\bpublic\.\w+/i, 'ei public-skeemaa');
  assert.doesNotMatch(SQL, /\b(alter|create)\s+table\b/i, 'ei taulumuutoksia');
  assert.doesNotMatch(SQL, /update\s+kb\.products|price_gross\s*=|vat_rate\s*=/i, 'ei hinta- tai ALV-muutoksia');
  assert.doesNotMatch(SQL, /https?:\/\//, 'ei URL-osoitteita');
  assert.match(SQL, /^set local lock_timeout/m);
});

test('vuosikorttikoodi: 10 merkkiä, ei 0/O/1/I/L, kryptografinen satunnaisuus, yksilöllinen', () => {
  const g = fn(SQL, '_generate_annual_card_code');
  assert.match(g, /'ABCDEFGHJKMNPQRSTUVWXYZ23456789'/);
  assert.match(g, /len constant int := 10/);
  assert.match(g, /gen_random_uuid\(\)/);
  assert.doesNotMatch(g, /\brandom\(\)/, 'ei random()-funktiota');
  assert.match(g, /v >= 248/, 'hylkäysotanta tasajakaumaan');
  assert.match(g, /pg_advisory_xact_lock/);
  assert.match(g, /annual_cards where code = c\) and not exists \(select 1 from booking\.discount_codes where code = c\)/);
  assert.equal(ANNUAL_ALPHABET, 'ABCDEFGHJKMNPQRSTUVWXYZ23456789');
  assert.equal(ANNUAL_ALPHABET.length, 31);
  for (const ch of '0O1IL') assert.ok(!ANNUAL_ALPHABET.includes(ch), ch);
  const seen = new Set();
  for (let i = 0; i < 500; i++) {
    const c = generatedAnnualCardCode();
    assert.equal(c.length, ANNUAL_CODE_LENGTH); assert.ok(validCodeFormat(c)); assert.ok([...c].every((x) => ANNUAL_ALPHABET.includes(x)));
    seen.add(c);
  }
  assert.equal(seen.size, 500);
  assert.doesNotMatch(SQL, /update\s+booking\.annual_cards\s+set\s+code/i, 'olemassa olevia koodeja ei muuteta');
});

test('rate limit toimii ilman IP:tä: IP / IP-ton yhteinen raja, sähköposti, puhelin, henkilökohtainen kortti', () => {
  const r = fn(SQL, '_code_rate_ok');
  assert.match(r, /'code:ip:' \|\| p_ip, 20, interval '10 minutes'/);
  assert.match(r, /'code:noip', 200, interval '10 minutes'/);
  assert.match(r, /'code:email:' \|\| v_email, 20/);
  assert.match(r, /'code:phone:' \|\| v_phone, 20/);
  assert.match(r, /'code:card:' \|\| md5\(p_code\), 20/);
  assert.match(r, /booking\.annual_cards where code = p_code/, 'koodikohtainen raja vain henkilökohtaisille korteille');
  for (const f of ['public_check_code', 'public_create_booking_code']) assert.match(fn(SQL, f), /booking\._code_rate_ok\(/, f);
  assert.match(SQL, /revoke all on function %s from public, anon, authenticated/);
  assert.match(SQL, /'booking\._code_rate_ok\(text,text,text,text\)'/);
});

test('väärä omistaja → sama geneerinen virhe kuin tuntematon koodi (invalid_code)', () => {
  for (const f of ['public_preview_code', 'public_create_booking_code']) {
    const b = fn(SQL, f);
    assert.doesNotMatch(b, /'annual_card_customer_mismatch'/, f);
    const owner = b.search(/_annual_card_owner_ok\(v_card/), annual = b.search(/if v_card\.id is not null or d\.is_annual_card_code then/);
    assert.ok(owner > 0 && annual > owner, `${f}: omistajatarkistus ennen muita vuosikorttitarkistuksia`);
    assert.match(b.slice(owner, owner + 300), /'invalid_code'/);
  }
  assert.ok(DISCOUNT_TEXTS.fi.codeErrors?.invalid_code ?? true);
});

test('vuosikorttivarauksen alennus = alkuperäinen hinta (trigger), rivin summa pysyy 0 €', () => {
  const t = fn(SQL, '_annual_res_discount_trg');
  assert.match(t, /_rule_price\(new\.rule_id, new\.persons\)/);
  assert.match(t, /set discount_amount = coalesce\(v_full, 0\)/);
  assert.match(t, /kind = 'reservation' and discount_code_id is null and line_total_gross = 0/);
  assert.match(SQL, /create trigger reservations_annual_discount after insert or update of rule_id, persons, annual_card_id, order_item_id on booking\.reservations\s+for each row when \(new\.annual_card_id is not null\)/);
});

test('peruutus palauttaa käyttökerran kaikista aktiivisista tiloista, palautus ottaa takaisin', () => {
  const rel = fn(SQL, '_discount_release_trg');
  assert.doesNotMatch(rel, /is_annual_card_code/);
  assert.match(SQL, /create trigger orders_discount_release after update of status on booking\.orders\s+for each row when \(new\.status in \('cancelled', 'expired'\) and old\.status not in \('cancelled', 'expired'\) and new\.discount_code_id is not null\)/);
  assert.match(SQL, /create trigger orders_discount_reclaim after update of status on booking\.orders\s+for each row when \(old\.status in \('cancelled', 'expired'\) and new\.status not in \('cancelled', 'expired'\) and new\.discount_code_id is not null\)/);
  assert.match(fn(SQL, '_discount_reclaim_trg'), /used_count = used_count \+ 1/);
});

test('EI muuteta: tuotteen 43 maksu luo kortin asetuksesta riippumatta (odottaa päätöstä)', () => {
  assert.doesNotMatch(SQL, /_annual_card_from_order|_on_payment_paid|annual_card_sale_enabled'\s*,/);
  assert.doesNotMatch(SQL, /create or replace function booking\.public_buy_annual_card/);
});

test('rollback palauttaa booking_142:n määritelmät ja poistaa booking_143:n lisäykset', () => {
  for (const f of ['_generate_annual_card_code', 'public_preview_code', 'public_check_code', 'public_create_booking_code', '_discount_release_trg'])
    assert.match(RB, new RegExp(`CREATE OR REPLACE FUNCTION booking\\.${f}\\(`), f);
  assert.match(RB, /drop trigger if exists reservations_annual_discount on booking\.reservations/);
  assert.match(RB, /drop trigger if exists orders_discount_reclaim on booking\.orders/);
  for (const f of ['_annual_res_discount_trg()', '_discount_reclaim_trg()', '_code_rate_ok(text, text, text, text)'])
    assert.ok(RB.includes(`drop function if exists booking.${f}`), f);
  assert.match(RB, /old\.status = 'pending' and new\.discount_code_id is not null\s+and new\.payment_status not in \('paid', 'partially_paid'\)/);
  assert.match(RB, /'annual_card_customer_mismatch'/);
  assert.match(RB, /where id = new\.discount_code_id and not is_annual_card_code/);
  for (const w of ['HIRVI', 'NORPPA', 'KOSKI']) assert.ok(RB.includes(`'${w}'`) && SQL142.includes(`'${w}'`), w);
  assert.ok(RB.indexOf('drop function if exists booking._code_rate_ok') > RB.indexOf('CREATE OR REPLACE FUNCTION booking.public_create_booking_code'),
    '_code_rate_ok poistetaan vasta kun sitä käyttävät funktiot on palautettu');
});

test('SQL-testi t143 kattaa kohdat', () => {
  for (const k of ['G1:', 'G3:', 'L1:', 'L6:', 'L7:', 'R1:', 'R4:', 'R7:', 'R9:', 'D2:', 'D3:', 'D4:', 'C3:', 'C4:', 'C7:', 'C10:', 'C13:', 'S2:'])
    assert.ok(T143.includes(k), k);
  assert.match(T143, /raise exception 'TESTRESULT pass=% fail=% :: %'/);
});
