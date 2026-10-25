// soefix: vuorotarjousmoottorin korjaukset (B2, B3-vahti, B4, B7/B8, B9, C1/C2, T1) + hyväksytty tervetuloteksti.
// Rakennetestit (CI:ssä ei Postgresia): migraatio ja rollback (md5-vahdit, jälkitarkistus), moottorin kytkimet/allowlista koskematta,
// tervetuloteksti sanatarkasti, ei '<'-merkkiä, bot-gateway ei kuulu tähän PR:ään, CI-rivit.
// SQL-käyttäytyminen: tests/vuorotarjous/tsoefix_engine_fixes.sql (paikallinen PG + tuotannon määrittelyt).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(resolve(root, p), 'utf8');
const migDir = 'booking/supabase/migrations';
const MIGF = readdirSync(resolve(root, migDir)).filter((f) => f.endsWith('_soefix_engine_fixes.sql'));
const MIG = `${migDir}/${MIGF[0]}`;
const RB = `booking/supabase/rollbacks/${MIGF[0]?.replace('.sql', '_ROLLBACK.sql')}`;
const SQLT = 'booking/supabase/tests/vuorotarjous/tsoefix_engine_fixes.sql';
const ENG = 'booking/supabase/functions/shift-offer-engine';
const code = (sql) => sql.split('\n').filter((l) => !/^\s*--/.test(l)).join('\n');
const WELCOME = 'Hei {nimi}! Tervetuloa Sipoonjoen perinnesaunan vuoroviesteihin. Saat tästä numerosta tarjouksia avoimista vuoroista, jotka sopivat sinulle. Vastaa tarjoukseen painamalla viestin "Avaa vastaus" -painiketta, ja valitse sivulla hyväksy tai kieltäydy. Kirjautumista ei tarvita. Jos useampi ehtii hyväksyä saman vuoron, se menee ensimmäiselle. Omalla sivullasi näet avoimet ja jo vastatut päiväsi, ja voit muuttaa vastaustasi siellä: {linkki} Viestejä lähetetään vain klo 8–21. Tapio';

test('yksi soefix-migraatio, rollback ja SQL-testi olemassa', () => {
  assert.equal(MIGF.length, 1);
  for (const p of [MIG, RB, SQLT, `${ENG}/soefix_test.ts`]) assert.ok(existsSync(resolve(root, p)), p);
});

test('bot-gateway ei kuulu tähän PR:ään', () => {
  const all = readdirSync(resolve(root, migDir));
  assert.ok(!all.some((f) => f.includes('botgw_otto_disabled')));
  assert.ok(!/create\s+(schema|table)\s+(if not exists\s+)?botgw/i.test(code(rd(MIG))));
});

test('migraatio: md5-vahti, lukitusraja, jälkitarkistus, ei muutoksia vahdin pettäessä', () => {
  const m = rd(MIG), c = code(m);
  assert.match(c, /set local lock_timeout\s*=\s*'5s'/);
  assert.ok(c.includes('pg_get_functiondef'));
  assert.ok(c.includes("tuotannon määrittelyt eivät vastaa odotettua"));
  for (const h of ['ddec4116', 'ce342485', '2aeb4adb', '04e72c0c', '8705686f', 'c11363b4', 'e615d22a', 'c74e01c1']) assert.ok(c.includes(h), h);
  for (const h of ['d6a47aa43feb0445f0bf00d549b60905', 'c20b901d3e21cb27814a7c2b160af97e', 'edc1f3bda7fcd6c40e7ed9767a0c895a']) assert.ok(c.includes(h), h);
  assert.ok(c.includes('has_function_privilege'));
});

test('moottorin kytkimet ja allowlista koskematta (migraatio ja rollback)', () => {
  for (const sql of [code(rd(MIG)), code(rd(RB))]) {
    assert.ok(!/update\s+public\.shift_offer_engine_settings/i.test(sql));
    assert.ok(!/update\s+public\.shift_offer_settings/i.test(sql));
    assert.ok(!/allow_staff_ids\s*=/i.test(sql));
    assert.ok(!/welcome_enabled[^\n]*(jsonb_set|'true')/i.test(sql));
    const settingsWrites = sql.match(/update\s+booking\.settings[^;]*;/gi) ?? [];
    for (const w of settingsWrites) assert.match(w, /shift_offer\.wa_templates/);
  }
  assert.match(code(rd(MIG)), /value #- '\{offer,fallback\}' where key = 'shift_offer\.wa_templates'/);
});

test('tervetuloteksti sanatarkasti, ei <-merkkiä, julkaistaan versiona 2', () => {
  const m = rd(MIG);
  assert.ok(m.includes(WELCOME.replace('{nimi}', '{{var:name}}').replace('{linkki}', '{{var:link}}')) || m.includes(WELCOME));
  assert.ok(!WELCOME.includes('<'));
  assert.ok(m.includes("'shift_offer.whatsapp.welcome'"));
  assert.ok(m.includes('Joonas hyväksyi 25.10.2026'));
  assert.ok(code(rd(MIG)).includes('_text_validate'));
});

test('rollback: md5-vahti ja palautus tuotannon määrittelyihin', () => {
  const r = code(rd(RB));
  assert.ok(r.includes('pg_get_functiondef'));
  assert.match(r, /drop trigger shift_offer_email_sent on booking.email_outbox/i);
  assert.match(r, /drop table booking\.shift_offer_skips/i);
  assert.ok(r.includes("'{offer,fallback}'"));
  for (const h of ['ddec4116', 'e615d22a']) assert.ok(r.includes(h), h);
});

test('SQL-testi: kirjautumismalli, SQLSTATE-tarkistukset, purkaa itsensä', () => {
  const t = rd(SQLT);
  assert.ok(t.includes('test.login'));
  assert.ok(t.includes("'42501'"));
  assert.match(t, /errcode\s*=\s*'TRBK0'/);
});

test('edge: ei vuorotarjous-varapohjaa, sähköpostivara, B9-kirjaus', () => {
  const w = rd(`${ENG}/whatsapp.ts`), s = rd(`${ENG}/sender.ts`), i = rd(`${ENG}/inbound.ts`);
  assert.ok(!/fallback\??:/.test(w));
  assert.ok(w.includes('"unapproved"') && w.includes('no_working_channel'));
  assert.ok(s.includes('shift_staff_welcome_mark_sent') && s.includes('shift_staff_welcome_release'));
  assert.ok(i.includes('welcomeSent') && i.includes('welcomeRelease'));
});

test('CI ajaa soefix-testit', () => {
  const y = rd('.github/workflows/pages.yml');
  assert.ok(y.includes(`${ENG}/soefix_test.ts`));
  assert.ok(y.includes('booking/tests/vuorotarjous-soefix.test.mjs'));
});
