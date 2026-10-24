// booking_148: jonotuslistan henkilömäärän raja palvelutyypin mukaan.
// Palvelutyyppi tunnistetaan olemassa olevista sarakkeista: booking.schedule_rules.mode = 'exclusive' → yksityisvuoro (private),
// kb.products.category = 'event' → tapahtuma (event), muuten yleinen vuoro (general).
// general: 1–6 (ennallaan). private: henkilömäärää ei kysytä, palvelin tallentaa säännön minimin, vapautuva vuoro mahtuu aina.
// event: 1..tapahtuman kapasiteetti (säännön/tuotteen max_persons ja kapasiteettipooli, enintään 50). 48 h -sääntö ja 120 min pito ennallaan.
// SQL-käytös: booking/supabase/tests/waitlist/t148_waitlist_party_size_by_type.sql (paikallinen PG17, ei työnkulussa).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';

const repo = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(resolve(repo, p), 'utf8');
const code = (s) => s.replace(/--[^\n]*/g, '');
const MIG = 'booking/supabase/migrations/20261024120446_booking_148_waitlist_party_size_by_type.sql';
const RB = 'booking/supabase/rollbacks/20261024120446_booking_148_ROLLBACK.sql';
const T148 = 'booking/supabase/tests/waitlist/t148_waitlist_party_size_by_type.sql';
const PEND = 'content/site-texts.pending-import-48.json';
const FNS = ['_sessions', '_check_claim', 'public_availability', 'public_availability_all', 'public_join_waitlist', 'public_waitlist_claim', '_waitlist_notify_entry', '_waitlist_process_session'];
const fnU = (sql, name) => { const i = sql.indexOf(`CREATE OR REPLACE FUNCTION booking.${name}(`); assert.ok(i >= 0, name); const j = sql.indexOf('$function$', sql.indexOf('$function$', i) + 10); return sql.slice(i, j); };

test('booking_148: migraatio, rollback ja SQL-testi olemassa, numero 148 ainoa ja viimeisenä', () => {
  for (const p of [MIG, RB, T148, PEND]) assert.ok(existsSync(resolve(repo, p)), p);
  const migs = readdirSync(resolve(repo, 'booking/supabase/migrations')).filter((f) => f.endsWith('.sql')).sort();
  assert.equal(migs.filter((f) => /_booking_148_/.test(f)).length, 1);
  assert.ok(migs.indexOf('20261024120446_booking_148_waitlist_party_size_by_type.sql') > migs.findIndex((f) => /_booking_139_/.test(f)));
});

test('migraatio: palvelutyyppi olemassa olevista sarakkeista, apufunktiot suljettu, ei public-skeemaa', () => {
  const sql = code(rd(MIG));
  assert.match(sql, /create or replace function booking\._waitlist_party\(p_rule_id bigint\)/);
  assert.match(sql, /create or replace function booking\._waitlist_private_taken\(p_rule_id bigint, p_starts timestamptz, p_ends timestamptz\)/);
  const party = sql.slice(sql.indexOf('booking._waitlist_party(p_rule_id'), sql.indexOf('booking._waitlist_private_taken(p_rule_id'));
  assert.match(party, /mode = 'exclusive'/);
  assert.match(party, /category = 'event'/);
  assert.match(party, /least\(6, coalesce\(r\.max_persons, 6\)\)/, 'yleinen vuoro 1–6 ennallaan');
  assert.match(party, /least\(50,/, 'tapahtuman kapasiteetilla yläraja');
  for (const f of ['_waitlist_party(bigint)', '_waitlist_private_taken(bigint, timestamptz, timestamptz)'])
    assert.ok(sql.includes(`revoke all on function booking.${f} from public, anon, authenticated;`), f);
  assert.doesNotMatch(sql, /grant [a-z, ]+ on function booking\._waitlist_(party|private_taken)/);
  assert.doesNotMatch(sql, /\bpublic\.[a-z_]+\s*\(/i, 'ei public-skeeman funktioita');
  for (const f of FNS) fnU(rd(MIG), f);
  assert.doesNotMatch(sql, /annual|discount_code|gift_card_list|vuosikortti|alennuskoodi/i, 'ei vuosikortti/alennuskoodi/lahjakorttilistafunktioita');
});

test('migraatio: liittyminen, lunastus ja jako palvelutyypin mukaan; 48 h ja 120 min ennallaan', () => {
  const m = rd(MIG);
  const join = fnU(m, 'public_join_waitlist');
  assert.match(join, /booking\._waitlist_party\(/);
  assert.match(join, /'invalid_persons'/);
  assert.match(join, /'kind'/);
  assert.match(fnU(m, 'public_waitlist_claim'), /'kind'/);
  const proc = fnU(m, '_waitlist_process_session');
  assert.match(proc, /v_private/);
  // 48 h -raja ja 120 min pito tulevat ennallaan booking._waitlist_offer_expires_at-funktiosta (booking_137/139), jota ei muuteta.
  assert.match(proc, /booking\._waitlist_offer_expires_at\(now\(\), v_s\.starts_at\)/);
  assert.doesNotMatch(m, /FUNCTION booking\._waitlist_offer_expires_at\(/i);
  assert.doesNotMatch(m, /waitlist_(hold_min_hours_before|offer_minutes)'\s*,\s*'\d+'/, 'asetusten oletuksia ei muuteta');
  assert.match(fnU(m, '_waitlist_notify_entry'), /'persons'/);
  for (const f of ['public_availability', 'public_availability_all']) assert.match(fnU(m, f), /_waitlist_private_taken\(/, f);
});

test('rollback palauttaa kaikki 8 funktiota ja poistaa apufunktiot', () => {
  const rb = rd(RB);
  for (const f of FNS) { const b = fnU(rb, f); assert.doesNotMatch(b, /booking_148|_waitlist_party|_waitlist_private_taken/, `${f}: vanha määrittely`); }
  assert.match(rb, /drop function if exists booking\._waitlist_private_taken\(bigint, timestamptz, timestamptz\);/);
  assert.match(rb, /drop function if exists booking\._waitlist_party\(bigint\);/);
});

test('kauppa: waitlistParty tunnistaa tyypin samoin kuin palvelin', async () => {
  const { waitlistParty } = await import(resolve(repo, 'booking/shop/src/waitlist-logic.js'));
  assert.deepEqual(waitlistParty({ mode: 'shared', min_persons: 1, max_persons: 20 }, { category: 'sauna' }), { kind: 'general', min: 1, max: 6 });
  assert.deepEqual(waitlistParty({ mode: 'shared', min_persons: 1, max_persons: 4 }, { category: 'sauna' }), { kind: 'general', min: 1, max: 4 });
  assert.deepEqual(waitlistParty({ mode: 'exclusive', min_persons: 1, max_persons: 10 }, { category: 'private_sauna' }), { kind: 'private', min: null, max: null });
  assert.deepEqual(waitlistParty({ mode: 'shared', min_persons: 1, max_persons: 12 }, { category: 'event', max_persons: 30 }), { kind: 'event', min: 1, max: 12 });
  assert.deepEqual(waitlistParty({ mode: 'shared', min_persons: 1, max_persons: null }, { category: 'event', max_persons: null }), { kind: 'event', min: 1, max: 50 });
});

test('kauppa: yksityisvuoron lomake ei kysy henkilömäärää, tapahtumalla oma ohje ja virhe', () => {
  const ui = rd('booking/shop/src/waitlist-ui.js');
  assert.match(ui, /waitlistParty\(/);
  assert.match(ui, /wl-private-note/);
  assert.match(ui, /waitlistPrivateNote/);
  assert.match(ui, /waitlistPersonsHintEvent/);
  assert.match(ui, /waitlistInvalidPersonsEvent/);
  assert.match(ui, /p_persons: [^,]*null/);
  const shop = rd('booking/shop/src/shop.js');
  assert.match(shop, /c\.kind === 'private'/);
});

test('tekstit FI+EN: kauppa ja tuontitiedosto 48 samat, ei <-merkkiä; sähköpostin yksityisvuororivi ilman henkilömäärää', () => {
  const tx = rd('booking/shop/src/waitlist-texts.js');
  const rows = JSON.parse(rd(PEND));
  for (const k of ['waitlist_persons_hint_event', 'waitlist_invalid_persons_event', 'waitlist_private_note']) {
    for (const l of ['fi', 'en']) {
      const r = rows.find((x) => x.key === `ui.shop.${k}` && x.lang === l);
      assert.ok(r, `${k} ${l}`);
      assert.ok(tx.includes(JSON.stringify(r.text).slice(1, -1)) || tx.includes(r.text), `${k} ${l}: sama kuin koodin oletus`);
      assert.doesNotMatch(r.text, /</);
    }
  }
  const et = rd('booking/supabase/functions/send-emails/texts.ts');
  assert.match(et, /"email\.waitlist\.session_private": \{ fi: "\{\{var:what\}\}, \{\{var:when\}\}", en: "\{\{var:what\}\}, \{\{var:when\}\}" \}/);
  assert.match(rd('booking/supabase/functions/send-emails/templates.ts'), /w\.persons == null\s*\? X\("email\.waitlist\.session_private"/);
  assert.equal(rows.filter((r) => r.key === 'email.waitlist.session_private').length, 2);
});

test('hallinta: yksityisvuoron pito näytetään ilman henkilömäärää', () => {
  const nb = rd('booking/admin/views/newbooking.js');
  assert.match(nb, /T\('nb\.privFree'\) \+ holdPrivTxt\(s\)/);
  const t = rd('booking/admin/nb-texts.js');
  assert.match(t, /'nb\.holdPriv': 'jonopito klo \{time\} asti'/);
  assert.match(t, /'nb\.holdPriv': 'waiting-list hold until \{time\}'/);
});

test('SQL-testi t148 kattaa kaikki kolme tyyppiä ja tulostaa TESTRESULT', () => {
  const t = rd(T148);
  for (const s of ['general', 'private', 'event', 'TESTRESULT', 'public_join_waitlist', 'public_waitlist_claim', 'waitlist_sweep']) assert.ok(t.includes(s), s);
});
