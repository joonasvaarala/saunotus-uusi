// booking_155: vuorotarjousmoottorin jatkopaketti booking_153:n päälle.
// Rakennetestit (CI:ssä ei Postgresia): migraatio ja rollback, "jo mennyt" -oletus päälle (WhatsApp + sähköposti), moottori ja
// sähköpostit pysyvät pois, ei allowlista-ajoja, public-skeema ennallaan, oma sivu ei mainitse vuorovastaavaa, tyovuoro_kysely-live-teksti,
// tick-ajastuksen käsiskripti, tekstit (pending-import-55) ja CI-rivit. SQL-käyttäytyminen: tests/vuorotarjous/t155_shift_offer_followup.sql (PG17).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(resolve(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024143157_booking_155_shift_offer_followup.sql';
const RB = 'booking/supabase/rollbacks/20261024143157_booking_155_ROLLBACK.sql';
const SQLT = 'booking/supabase/tests/vuorotarjous/t155_shift_offer_followup.sql';
const P55 = 'content/site-texts.pending-import-55.json';
const LIVE = 'Hei, työvuoroon tarvitaan tekijää. Vuoro: {{1}}, aika {{2}}. Voitko tulla töihin? Vastaathan viimeistään {{3}} mennessä alla olevasta painikkeesta.';
const mig = rd(MIG), rb = rd(RB);
const code = (sql) => sql.split('\n').filter((l) => !/^\s*--/.test(l)).join('\n');
const migs = readdirSync(resolve(root, 'booking/supabase/migrations')).sort();
const m153 = migs.find((f) => f.endsWith('_booking_153_shift_offer_rules.sql'));
const fnDef = (sql, name) => {
  const i = sql.indexOf(`create or replace function booking.${name}(`);
  if (i < 0) return null;
  return sql.slice(i, sql.indexOf('end $$;', i) + 7);
};

test('tiedostot olemassa, yksi booking_155-migraatio booking_153:n jälkeen', () => {
  for (const p of [MIG, RB, SQLT, P55, 'booking/supabase/manual/booking_153_tick_cron.sql', 'booking/supabase/manual/booking_153_otto_allowlist.md',
    'booking/supabase/functions/shift-offer-engine/booking155_test.ts']) assert.ok(existsSync(resolve(root, p)), p);
  assert.equal(migs.filter((f) => /booking_155/.test(f)).length, 1);
  assert.ok(m153, 'booking_153-migraatio löytyy');
  assert.ok(migs.indexOf(m153) < migs.indexOf('20261024143157_booking_155_shift_offer_followup.sql'));
  assert.ok(!existsSync(resolve(root, 'booking/supabase/manual/booking_153_otto_allowlist.sql')), 'allowlista-skripti poistettu');
});

test('(d) asetus shift_offer.already_taken_message → true, rollback → false', () => {
  const c = code(mig), r = code(rb);
  assert.match(c, /update booking\.settings\s+set value = 'true'::jsonb[\s\S]*?where key = 'shift_offer\.already_taken_message' and value = 'false'::jsonb/);
  assert.match(r, /update booking\.settings\s+set value = 'false'::jsonb[\s\S]*?where key = 'shift_offer\.already_taken_message'/);
});

test('(d) sähköpostikopio: trigger, sähköposti vain booking.shift_offer_email-portin kautta (email_enabled)', () => {
  const c = code(mig);
  assert.match(c, /create trigger shift_offer_already_taken_mail_trg after insert on booking\.shift_offer_notices\s+for each row when \(new\.stage = 'already_taken'\)/);
  assert.match(c, /booking\.shift_offer_email\(new\.staff_id/);
  assert.doesNotMatch(c, /insert into booking\.email_outbox/i);
  assert.match(c, /security definer set search_path = ''/);
  assert.match(c, /revoke all on function booking\._shift_offer_already_taken_mail\(\) from public, anon, authenticated/);
  assert.match(code(rb), /drop trigger if exists shift_offer_already_taken_mail_trg[\s\S]*drop function if exists booking\._shift_offer_already_taken_mail\(\)/);
});

test('(d) varapolku ei tuplaa sähköpostia, toiselle mennyt vuoro katoaa omalta sivulta', () => {
  const drain = fnDef(mig, 'shift_offer_email_drain'), page = fnDef(mig, 'shift_staff_page');
  assert.match(drain, /m\.subkind = 'already_taken'[\s\S]*'b153:at-mail:'[\s\S]*status = 'skipped', last_error = 'email_copy_sent'/);
  assert.match(page, /not \(o\.status = 'filled' and o\.accepted_staff_id is distinct from v_staff\)/);
});

test('rollback palauttaa booking_153:n funktiomääritelmät sellaisenaan', () => {
  const m = rd(`booking/supabase/migrations/${m153}`);
  for (const n of ['shift_offer_email_drain', 'shift_staff_page']) {
    assert.equal(fnDef(rb, n), fnDef(m, n), n);
    assert.notEqual(fnDef(mig, n), fnDef(m, n), n);
  }
});

test('ei kytkimiä päälle, ei allowlistaa, public-skeema ja public-funktiot ennallaan', () => {
  for (const c of [code(mig), code(rb)]) {
    assert.doesNotMatch(c, /email_enabled'?\s*(and|=)/i);
    assert.doesNotMatch(c, /whatsapp_enabled/i);
    assert.doesNotMatch(c, /test_recipients|integration_config/i);
    assert.doesNotMatch(c, /(alter|create)\s+table\s+(if\s+(not\s+)?exists\s+)?public\./i);
    assert.doesNotMatch(c, /create\s+(or\s+replace\s+)?function\s+public\./i);
    assert.doesNotMatch(c, /update\s+public\.(shift_offer_settings|shift_offer_engine_settings|staff)\b/i);
    assert.doesNotMatch(c, /cron\.schedule/i);
  }
});

test('(c) oma sivu: ei vuorovastaavaa, ohjaa Joonakselle tai Otolle (FI+EN)', () => {
  const s = rd('booking/vuoro/oma/oma.js');
  assert.doesNotMatch(s, /vuorovastaa|coordinator/i);
  assert.match(s, /Joonakselta tai Otolta/);
  assert.match(s, /Joonaksen tai Oton/);
  assert.match(s, /Joonas or Otto/);
  assert.match(s, /result_already_taken/);
});

test('(b) tyovuoro_kysely: live-teksti docsissa ja META-POHJAT.md:ssä, lyhyet parametrit moottorissa', () => {
  const docs = JSON.parse(rd('docs/whatsapp-templates.json'));
  const t = docs.booking_153_templates.find((x) => x.name === 'tyovuoro_kysely');
  assert.equal(t.components.find((c) => c.type === 'BODY').text, LIVE);
  assert.ok(rd('META-POHJAT.md').includes(LIVE));
  assert.doesNotMatch(rd('META-POHJAT.md') + JSON.stringify(docs), /mennyessä/);
  assert.equal(docs.booking_153_meta_submissions.tyovuoro_kysely.id, '1794385658497521');
  assert.equal(docs.booking_153_meta_submissions.tyovuoro_muistutus.id, '1534095558743771');
  assert.equal(docs.booking_153_meta_submissions.tyovuoro_jo_mennyt.id, '2100154127266819');
  assert.equal(docs.booking_153_meta_submissions.tyovuoro_paivan_kooste.id, '1810762233406994');
  const wa = rd('booking/supabase/functions/shift-offer-engine/whatsapp.ts');
  assert.match(wa, /OFFER_TEMPLATE_SHORT = "tyovuoro_kysely"/);
  assert.match(wa, /formatShiftWhenShort/);
  assert.doesNotMatch(rd('booking/supabase/functions/shift-offer-engine/index.ts'), /EI deployata/);
});

test('tick-ajastus: vain käsiskripti, ei migraatioissa', () => {
  const s = rd('booking/supabase/manual/booking_153_tick_cron.sql');
  assert.match(s, /ÄLÄ AJA NYT/);
  assert.match(s, /Joonas kytkee moottorin päälle/);
  assert.match(s, /cron\.schedule\(\s*'shift-offer-engine-5m',\s*'\*\/5 \* \* \* \*'/);
  assert.match(s, /functions\/v1\/shift-offer-engine/);
  assert.match(s, /calendar_sync_cron_secret/);
  assert.match(s, /cron\.unschedule\('shift-offer-engine-5m'\)/);
  for (const f of migs) assert.doesNotMatch(rd(`booking/supabase/migrations/${f}`), /shift-offer-engine-5m/, f);
});

test('tekstit pending-import-55: FI+EN, ei <, ei päällekkäin aiempien tuontien kanssa', () => {
  const rows = JSON.parse(rd(P55));
  assert.equal(rows.length, 2);
  assert.deepEqual(rows.map((r) => r.lang).sort(), ['en', 'fi']);
  for (const r of rows) {
    assert.equal(r.key, 'shift_offer.already_taken.email_subject');
    assert.ok(!r.text.includes('<') && r.text.length <= r.max_len);
  }
  assert.ok(code(mig).includes("'shift_offer.already_taken.email_subject'"));
  const others = readdirSync(resolve(root, 'content')).filter((f) => /^site-texts\.pending-import-\d+\.json$/.test(f) && f !== 'site-texts.pending-import-55.json');
  for (const f of others) {
    const keys = new Set(JSON.parse(rd(`content/${f}`)).map((r) => `${r.key}|${r.lang}`));
    for (const r of rows) assert.ok(!keys.has(`${r.key}|${r.lang}`), `${f}: ${r.key}`);
  }
});

test('CI: pages.yml ajaa booking_155:n testit', () => {
  const y = rd('.github/workflows/pages.yml');
  assert.match(y, /node --test booking\/tests\/vuorotarjous-155\.test\.mjs/);
  assert.match(y, /booking\/supabase\/functions\/shift-offer-engine\/booking155_test\.ts/);
  assert.ok(y.indexOf('vuorotarjous-155.test.mjs') < y.indexOf('upload-pages-artifact'));
});
