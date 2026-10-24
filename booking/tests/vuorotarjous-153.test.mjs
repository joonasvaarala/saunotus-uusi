// booking_153: vuorotarjousmoottorin sääntömuutokset, henkilökunnan oma sivu, WhatsApp-pohjat ja tervetuloviesti.
// Rakennetestit (CI:ssä ei Postgresia): migraatio ja rollback, asetusten oletukset, moottori pysyy pois päältä, Otto ei allowlistilla,
// public-skeeman rakenne ennallaan, booking_154:n funktioita ei määritellä uudelleen, tekstit (pending-import-53), oma sivu,
// hallinnan osio, META-pohjat ja CI-rivit. SQL-käyttäytyminen: booking/supabase/tests/vuorotarjous/t153_shift_offer_rules.sql (PG17).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { SHIFT_STAFF_TEXTS, ssText, primeSsTexts, clearSsTextCache } from '../admin/shift-staff-texts.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(resolve(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024141356_booking_153_shift_offer_rules.sql';
const RB = 'booking/supabase/rollbacks/20261024141356_booking_153_ROLLBACK.sql';
const SQLT = 'booking/supabase/tests/vuorotarjous/t153_shift_offer_rules.sql';
const P53 = 'content/site-texts.pending-import-53.json';
const OTTO = '2975633f-c53f-48d6-8a38-41cae0be5a83';
const mig = rd(MIG), rb = rd(RB);
const code = (sql) => sql.split('\n').filter((l) => !/^\s*--/.test(l)).join('\n');

test('tiedostot olemassa, yksi booking_153-migraatio ja rollback', () => {
  for (const p of [MIG, RB, SQLT, P53, 'META-POHJAT.md', 'booking/vuoro/oma/index.html', 'booking/vuoro/oma/oma.js', 'booking/vuoro/oma/oma.css',
    'booking/vuoro/oma/oma_test.ts', 'booking/admin/views/shift-staff-panel.js', 'booking/supabase/manual/booking_153_otto_allowlist.md']) assert.ok(existsSync(resolve(root, p)), p);
  assert.equal(readdirSync(resolve(root, 'booking/supabase/migrations')).filter((f) => /booking_153/.test(f)).length, 1);
});

test('migraatio: moottori pysyy pois päältä, ei whatsapp_enabled-muutosta, ei Ottoa allowlistille', () => {
  const c = code(mig);
  assert.doesNotMatch(c, /update\s+public\.shift_offer_(settings|engine_settings)[\s\S]{0,200}?set[\s\S]{0,80}?(enabled|sender_enabled)\s*=\s*true/i);
  assert.doesNotMatch(c, /update\s+public\.staff\b/i);
  assert.doesNotMatch(c, /whatsapp_enabled\s*=\s*true/i);
  assert.doesNotMatch(c, /test_recipients/);
  assert.doesNotMatch(c, /(update|insert into|delete from)\s+booking\.integration_config/i);
  assert.match(c, /'shift_offer\.email_enabled', 'false'/);
  assert.match(c, /'shift_offer\.welcome_enabled', 'false'/);
  // booking_155: Otto on jo tuotannon allowlistalla; käsin ajettava skripti korvattiin muistiinpanolla
  const manual = rd('booking/supabase/manual/booking_153_otto_allowlist.md');
  assert.ok(manual.includes(OTTO));
  assert.match(manual, /shift_offer\.email_enabled = false/);
  assert.ok(!existsSync(resolve(root, 'booking/supabase/manual/booking_153_otto_allowlist.sql')));
});

test('migraatio: public-skeeman taulujen rakenne ennallaan, booking_154:n funktioita ei määritellä uudelleen', () => {
  const c = code(mig);
  assert.doesNotMatch(c, /alter\s+table\s+(if\s+exists\s+)?public\./i);
  assert.doesNotMatch(c, /create\s+table\s+(if\s+not\s+exists\s+)?public\./i);
  assert.doesNotMatch(c, /drop\s+table\s+(if\s+exists\s+)?public\./i);
  for (const f of ['email_outbox_claim', '_annual_card_email_trg', '_annual_card_mail', 'admin_create_annual_card']) {
    assert.doesNotMatch(c, new RegExp(`function\\s+booking\\.${f}\\(`), f);
    assert.doesNotMatch(code(rb), new RegExp(`function\\s+booking\\.${f}\\(`), f);
  }
  assert.ok(readdirSync(resolve(root, 'booking/supabase/migrations')).sort().indexOf('20261024134645_booking_154_annual_card_admin_email.sql') <
    readdirSync(resolve(root, 'booking/supabase/migrations')).sort().indexOf('20261024141356_booking_153_shift_offer_rules.sql'));
});

test('asetukset ja oletukset', () => {
  const want = {
    'shift_offer.last_round_before': /"heater":"14 days","therapist":"21 days","reception":"14 days"/,
    'shift_offer.last_round_min_lead': /"21 days"/,
    'shift_offer.round_reminder_before': /"12 hours"/,
    'shift_offer.vacant_notice': /"first_reminder_after":"3 days","daily_from":"7 days"/,
    'shift_offer.therapist_notice': /"three_weeks":"21 days","warn_after":"3 days","close_after":"6 hours","weekly":"7 days"/,
    'shift_offer.offer_uncertain_shifts': /'false'/,
    'shift_offer.unavailability_frees_shift': /'true'/,
    'shift_offer.whatsapp_hours': /"start":"08:00","end":"21:00"/,
    'shift_offer.already_taken_message': /'false'/,
    'shift_offer.wa_templates': /"offer":\{"name":"tyovuoro_kysely","approved":false,"fallback":"vuorotarjous"\}.*"tyovuoro_muistutus".*"tyovuoro_jo_mennyt".*"tyovuoro_paivan_kooste"/,
    'shift_offer.staff_page_url': /vuoro\/oma\//,
  };
  for (const [k, re] of Object.entries(want)) {
    const line = mig.split('\n').find((l) => l.includes(`('${k}'`));
    assert.ok(line, k);
    assert.match(line, re, k);
  }
  assert.match(mig, /on conflict \(key\) do nothing/);
});

test('rollback: uudelleenajettava, palauttaa kind-rajoitteen ja poistaa booking_153:n osat', () => {
  assert.match(rb, /drop constraint if exists email_outbox_kind_check/);
  assert.doesNotMatch(rb.match(/add constraint email_outbox_kind_check[\s\S]*?;/)[0], /staff_shift_notice/);
  assert.match(rb, /'annual_card_code'/);
  for (const t of ['shift_offer_notices', 'shift_staff_page_tokens', 'shift_staff_whatsapp_consent']) assert.match(rb, new RegExp(`drop table if exists booking\\.${t}`), t);
  assert.match(rb, /delete from booking\.settings where key (like 'shift_offer\.%'|in)/);
  for (const m of code(rb).matchAll(/drop (function|table|trigger|index)\s+(?!if exists)/gi)) assert.fail(`ei if exists: ${m[0]}`);
});

test('SQL-testi: kattaa säännöt 1–8 ja oman sivun', () => {
  const s = rd(SQLT);
  assert.match(s, /TESTRESULT pass=% fail=%/);
  for (const tag of ['1a', '2a', '3a', '4a', '5a', '6a', '7a', '8a', 'P0', 'W1', 'd1', 'e1', 'f1', 'h1']) assert.ok(s.includes(`'${tag}`), tag);
});

test('tekstit pending-import-53: FI + EN, ei <, täsmää sanakirjaan, tervetuloviesti', () => {
  const rows = JSON.parse(rd(P53));
  assert.ok(!rd(P53).includes('<'));
  const keys = new Set(rows.map((r) => r.key));
  for (const k of keys) {
    const fi = rows.filter((r) => r.key === k && r.lang === 'fi'), en = rows.filter((r) => r.key === k && r.lang === 'en');
    assert.equal(fi.length, 1, k); assert.equal(en.length, 1, k);
    for (const r of [fi[0], en[0]]) {
      assert.match(r.key, /^[a-z0-9_]+(\.[a-z0-9_-]+)+$/);
      assert.ok(r.text.length <= r.max_len, k);
      assert.deepEqual(r.placeholders, [...new Set(r.text.match(/\{\{var:[a-z_]+\}\}/g) ?? [])], k);
      if (k.startsWith('ui.admin.shift_staff.')) assert.equal(r.text, SHIFT_STAFF_TEXTS[r.lang][k], k);
    }
  }
  assert.deepEqual([...keys].filter((k) => k.startsWith('ui.admin.shift_staff.')).sort(), Object.keys(SHIFT_STAFF_TEXTS.fi).sort());
  assert.deepEqual(Object.keys(SHIFT_STAFF_TEXTS.fi).sort(), Object.keys(SHIFT_STAFF_TEXTS.en).sort());
  const w = rows.find((r) => r.key === 'shift_offer.whatsapp.welcome' && r.lang === 'fi');
  assert.deepEqual(w.placeholders, ['{{var:name}}', '{{var:link}}']);
  assert.match(w.text, /–Tapio$/);
  assert.ok(mig.includes(w.text.replace(/\n/g, '\\n')), 'SQL-varateksti = tuotava teksti');
  for (const p of readdirSync(resolve(root, 'content')).filter((f) => /^site-texts\.pending-import-\d+\.json$/.test(f) && f !== 'site-texts.pending-import-53.json')) {
    for (const r of JSON.parse(rd('content/' + p))) assert.ok(!keys.has(r.key), `${r.key} myös tiedostossa ${p}`);
  }
});

test('hallinnan tekstit: live-teksti voittaa, puuttuva muuttuja → sanakirja', () => {
  clearSsTextCache();
  primeSsTexts([{ key: 'ui.admin.shift_staff.renew', lang: 'fi', text: 'Vaihda linkki' }, { key: 'ui.admin.shift_staff.revoke_confirm', lang: 'fi', text: 'Peru {{var:muu}}' }]);
  assert.equal(ssText('ui.admin.shift_staff.renew', null, 'fi'), 'Vaihda linkki');
  assert.equal(ssText('ui.admin.shift_staff.revoke_confirm', { name: 'Aino' }, 'fi'), SHIFT_STAFF_TEXTS.fi['ui.admin.shift_staff.revoke_confirm'].replace('{{var:name}}', 'Aino'));
  clearSsTextCache();
});

test('hallinta: Käyttäjät-näkymässä omien sivujen osio, whatsapp_enabled ei muutu', () => {
  const users = rd('booking/admin/views/users.js'), panel = rd('booking/admin/views/shift-staff-panel.js');
  assert.match(users, /renderShiftStaffPanel\(\{ reload \}\)/);
  assert.match(panel, /admin_shift_staff_overview/);
  for (const a of ['issue', 'renew', 'revoke', 'dismiss_suggestion']) assert.ok(panel.includes(`'${a}'`), a);
  assert.match(panel, /suggest_whatsapp/);
  assert.doesNotMatch(code(panel), /whatsapp_enabled\s*[:=]/);
  assert.doesNotMatch(panel, /innerHTML/);
});

test('oma sivu: noindex, ei referreriä, vain textContent, värit ilman sinistä, build kopioi', () => {
  const html = rd('booking/vuoro/oma/index.html'), js = rd('booking/vuoro/oma/oma.js'), css = rd('booking/vuoro/oma/oma.css');
  assert.match(html, /<meta name="robots" content="noindex, nofollow">/);
  assert.match(html, /<meta name="referrer" content="no-referrer">/);
  assert.match(html, /href="\.\.\/vuoro\.css"/);
  assert.doesNotMatch(js, /innerHTML|outerHTML|insertAdjacentHTML|document\.write/);
  assert.match(js, /\/api\/my\/respond/);
  assert.match(js, /Europe\/Helsinki/);
  assert.doesNotMatch(css + html, /#(?:00f|0000ff|1e90ff|2563eb|3b82f6|007bff)\b|\bblue\b/i);
  for (const c of css.match(/#[0-9a-f]{3,6}\b/gi) ?? []) assert.ok(['#2b3a30', '#f4efe7', '#7a5530', '#fff', '#ffffff'].includes(c.toLowerCase()), c);
  assert.doesNotMatch(js + html, /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u);
  const build = rd('scripts/build-pages.mjs');
  assert.match(build, /for \(const f of \['index\.html', 'oma\.css', 'oma\.js'\]\) cpSync\(join\('booking\/vuoro\/oma', f\), join\(V, 'oma', f\)\);/);
  assert.match(mig, /https:\/\/joonasvaarala\.github\.io\/saunotus-uusi\/vuoro\/oma\//);
});

test('META-pohjat: neljä pohjaa, samat rungot kuin docs/whatsapp-templates.json', () => {
  const md = rd('META-POHJAT.md');
  const docs = JSON.parse(rd('docs/whatsapp-templates.json')).booking_153_templates;
  assert.deepEqual(docs.map((t) => t.name), ['tyovuoro_kysely', 'tyovuoro_muistutus', 'tyovuoro_jo_mennyt', 'tyovuoro_paivan_kooste']);
  for (const t of docs) {
    assert.equal(t.category, 'UTILITY'); assert.equal(t.language, 'fi');
    const body = t.components.find((c) => c.type === 'BODY').text;
    assert.ok(md.includes(`## `) && md.includes(t.name) && md.includes(body), t.name);
    assert.doesNotMatch(body, /^\{\{|\}\}[.!]?$/, `${t.name}: muuttuja ei saa olla alussa tai lopussa`);
    assert.equal(t.components.find((c) => c.type === 'FOOTER').text, 'Tapio');
  }
});

test('CI: pages.yml ajaa testin ja booking_153:n deno-testit', () => {
  const y = rd('.github/workflows/pages.yml');
  assert.match(y, /- run: node --test booking\/tests\/vuorotarjous-153\.test\.mjs/);
  for (const f of ['booking/supabase/functions/shift-offer-engine/booking153_test.ts', 'booking/supabase/functions/send-emails/staff_notice_test.ts', 'booking/vuoro/oma/oma_test.ts']) assert.ok(y.includes(f), f);
  assert.ok(y.indexOf('vuorotarjous-153.test.mjs') < y.indexOf('upload-pages-artifact'));
});
