// booking_151 + Kääntäjän en_sources (/workspace/kaantaja/en_sources/REPORT.md): englanninkieliset lähdekentät sivustolle ja kauppaan.
// - kb-snapshot.mjs: faq question_en/answer_en, policies title_en/body_en, events time_text_en, hours/locations/business _en (vain snapshot).
// - src/kb-en.mjs: sivujen listat suomenkielisillä id:illä; EN = _en-kentät → vanha erillinen EN-rivi (FAQ 19–23, ehdot 16–24/26) → suomi.
// - render.mjs (UKK, ehdot, tapahtuman aikateksti), seo-enhance.mjs (FAQPage samalla ratkaisulla). privacy.json ennallaan.
// - booking_151: _sessions/public_availability/public_availability_all palauttavat label_en (drop + create, pohja booking_148);
//   kauppa näyttää EN-sivulla label_en || label. SQL-käytös: booking/supabase/tests/texts/t151_session_label_en.sql (paikallinen PG17).
// Ei verkkoa eikä tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync, mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

process.env.SITE_TEXTS_FIXTURE ||= '1';
process.env.ARTICLES_FIXTURE ||= '1';
const repo = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const json = (rel) => JSON.parse(read(rel));
const MIG = 'booking/supabase/migrations/20261024130120_booking_151_session_label_en.sql';
const RB = 'booking/supabase/rollbacks/20261024130120_booking_151_ROLLBACK.sql';
const M148 = 'booking/supabase/migrations/20261024120446_booking_148_waitlist_party_size_by_type.sql';
const FNS = ['_sessions', 'public_availability', 'public_availability_all'];
// funktion otsikko (RETURNS TABLE …) ja runko $function$ … $function$, välilyönnit normalisoitu
const def = (sql, fn) => {
  const i = sql.search(new RegExp(`(?:create or replace|create) function\\s+booking\\.${fn}\\(`, 'i'));
  assert.ok(i >= 0, `${fn} löytyy`);
  const rest = sql.slice(i).replace(/\s*-- booking_151:[^\n]*/g, '');
  const a = rest.indexOf('$function$'), b = rest.indexOf('$function$', a + 10);
  const n = (s) => s.replace(/\s+/g, ' ').trim();
  return { head: n(rest.slice(0, a).replace(/^create or replace function|^create function/i, '')), body: n(rest.slice(a + 10, b)) };
};

const { faqFor, policyFor, eventTimeFor, LEGACY_FAQ_EN, LEGACY_POLICY_EN } = await import('../../src/kb-en.mjs');
const { kb } = await import('../../src/lib.mjs');

test('migraatio booking_151: vain 3 funktiota, lisäys = label_en viimeisenä sarakkeena, muuten booking_148 sellaisenaan', () => {
  assert.deepEqual(readdirSync(join(repo, 'booking/supabase/migrations')).filter((n) => /booking_151_/.test(n)), ['20261024130120_booking_151_session_label_en.sql']);
  const sql = read(MIG), base = read(M148);
  const created = [...sql.matchAll(/create function\s+booking\.(\w+)\(/gi)].map((m) => m[1]).sort();
  assert.deepEqual(created, [...FNS].sort());
  assert.deepEqual([...sql.matchAll(/drop function\s+booking\.(\w+)\(/gi)].map((m) => m[1]).sort(), [...FNS].sort());
  assert.doesNotMatch(sql, /\bpublic\.\w+/i, 'ei public-skeemaa');
  assert.doesNotMatch(sql, /\b(alter table|insert into|update\s+\w+\.|delete from|truncate)\b/i, 'ei skeema- eikä datamuutoksia');
  for (const fn of FNS) {
    const a = def(sql, fn), b = def(base, fn);
    assert.equal(a.head, b.head.replace(/(\w+ (?:timestamp with time zone|numeric))\) LANGUAGE/, '$1, label_en text) LANGUAGE'), `${fn}: RETURNS TABLE + label_en`);
    const strip = (s) => s.replace(/, r\.label_en(?=, r\.mode)/, '').replace(/, c\.label_en(?= from c)/, '').replace(/, s\.label_en(?= from)/, '');
    assert.equal(strip(a.body), b.body, `${fn}: ei muita muutoksia (hinnat, tila, rajaukset, järjestys)`);
    assert.notEqual(a.body, b.body, `${fn}: label_en lisätty`);
  }
  assert.match(sql, /grant execute on function booking\._sessions\(date, date, bigint, boolean\) to service_role;/);
  for (const sig of ['public_availability\\(bigint, date, date\\)', 'public_availability_all\\(date, date, text\\)'])
    assert.match(sql, new RegExp(`grant execute on function booking\\.${sig} to anon, authenticated, service_role;`));
  assert.doesNotMatch(sql, /grant execute on function booking\._sessions[^;]*\b(anon|authenticated)\b/, '_sessions ei julkinen');
  assert.match(sql, /comment on function booking\.public_availability_all\(date, date, text\) is/);
});

test('rollback booking_151: palauttaa booking_148-määritelmät täsmälleen (md5-tarkistus), samat oikeudet', () => {
  const rb = read(RB), base = read(M148);
  for (const fn of FNS) assert.deepEqual(def(rb, fn), def(base, fn), `${fn} = booking_148`);
  assert.doesNotMatch(rb.replace(/^--.*$/gm, ''), /label_en/);
  for (const md5 of ['050f3e9eb115bac3f4d94eecaf4640d3', '5eb846faab9982b51390dc6f7d8d0418', '6a12314f51b897cac6cb0b234efa7af6']) assert.match(rb, new RegExp(md5));
  assert.doesNotMatch(rb, /\b(alter table|delete from|truncate)\b/i);
  assert.match(rb, /grant execute on function booking\.public_availability_all\(date, date, text\) to anon, authenticated, service_role;/);
});

test('SQL-testi t151 ja kb-mock: _en-sarakkeet mockissa kuten tuotannossa', () => {
  assert.ok(existsSync(join(repo, 'booking/supabase/tests/texts/t151_session_label_en.sql')));
  const mock = read('booking/supabase/tests/fixtures/kb_mock.sql');
  for (const re of [/kb\.faq add column if not exists question_en text, add column if not exists answer_en text/, /kb\.policies add column if not exists title_en text, add column if not exists body_en text/,
    /kb\.event_dates add column if not exists time_text_en text/, /kb\.opening_hours add column if not exists session_name_en text/, /kb\.locations add column if not exists name_en text/, /kb\.businesses add column if not exists description_en text/]) assert.match(mock, re);
});

test('kauppa: EN-sivu näyttää vuoron label_en, puuttuessa label; FI aina label; kaikki kolme kohtaa', () => {
  const shop = read('booking/shop/src/shop.js');
  const line = /const rlabel = \(r\) => .*;/.exec(shop)?.[0];
  assert.equal(line, "const rlabel = (r) => (S.lang === 'en' && r.label_en) || r.label;");
  const rl = (S) => new Function('S', `${line} return rlabel;`)(S);
  const r = { label: 'Iltasauna', label_en: 'Evening sauna' };
  assert.equal(rl({ lang: 'en' })(r), 'Evening sauna');
  assert.equal(rl({ lang: 'fi' })(r), 'Iltasauna');
  assert.equal(rl({ lang: 'en' })({ label: 'Iltasauna', label_en: null }), 'Iltasauna');
  assert.equal(rl({ lang: 'en' })({ label: 'Iltasauna', label_en: '' }), 'Iltasauna');
  assert.equal((shop.match(/cleanLabel\(rlabel\(r\)\)/g) || []).length, 4, 'tuotekortti, varausyhteenveto, vuorolista (2)');
  assert.doesNotMatch(shop, /cleanLabel\(r\.label\)/, 'ei suoraa label-näyttöä');
  assert.match(shop, /h\('h2', \{ text: st \? pname\(st\) : t\.unknownProduct \}\)/, 'yhteydenottotuote: EN-nimi (name_en) static-products.jsonista');
  assert.doesNotMatch(shop, /st \? st\.name :/, 'ei suomenkielistä nimeä EN-kaupassa');
  assert.match(shop, /const labelRest = /, 'pelkkä päivämäärä/kellonaika ei jätä "klo"-jäännöstä');
});

const FAKE = {
  faq: [
    { id: 1, language: 'fi', question: 'Milloin?', answer: 'Iltaisin.', question_en: 'When?', answer_en: 'Evenings.' },
    { id: 8, language: 'fi', question: 'Mitä mukaan?', answer: 'Pyyhe.' },
    { id: 9, language: 'fi', question: 'Uima-asu?', answer: 'Kyllä.', question_en: 'Swimsuit?' },
    { id: 4, language: 'fi', question: 'Varaus?', answer: 'Verkossa.' },
    { id: 19, language: 'en', question: 'When (old)?', answer: 'Old.' },
    { id: 20, language: 'en', question: 'What to bring?', answer: 'A towel.' },
    { id: 21, language: 'en', question: 'Swimsuit (old)?', answer: 'Yes.' },
  ],
  policies: [
    { id: 1, language: 'fi', title: 'Yleiset', body: 'FI', title_en: 'General', body_en: 'EN' },
    { id: 2, language: 'fi', title: 'Varaus', body: 'FI' },
    { id: 9, language: 'fi', title: 'Vuosikortti', body: 'FI' },
    { id: 4, language: 'fi', title: 'Sisäinen', body: 'x', internal: true, title_en: 'Internal', body_en: 'x' },
    { id: 17, language: 'en', title: 'Reservation terms', body: 'EN old' },
  ],
};

test('kb-en: UKK – _en-kentät → vanha EN-rivi → suomi (lang fi); FI-sivu aina suomeksi', () => {
  assert.deepEqual(faqFor(1, 'en', FAKE), { id: 1, question: 'When?', answer: 'Evenings.', lang: 'en' }, '_en ohittaa vanhan rivin 19');
  assert.deepEqual(faqFor(8, 'en', FAKE), { id: 8, question: 'What to bring?', answer: 'A towel.', lang: 'en' }, 'vanha rivi 20');
  assert.deepEqual(faqFor(9, 'en', FAKE), { id: 9, question: 'Swimsuit (old)?', answer: 'Yes.', lang: 'en' }, 'puolikas käännös ei kelpaa → vanha rivi 21');
  assert.deepEqual(faqFor(4, 'en', FAKE), { id: 4, question: 'Varaus?', answer: 'Verkossa.', lang: 'fi' }, 'ei käännöstä → suomi');
  assert.deepEqual(faqFor(1, 'fi', FAKE), { id: 1, question: 'Milloin?', answer: 'Iltaisin.', lang: 'fi' });
  assert.equal(faqFor(99, 'en', FAKE), null);
  assert.deepEqual(LEGACY_FAQ_EN, { 1: 19, 8: 20, 9: 21, 11: 22, 10: 23 });
  // nykyinen snapshot: vanhat rivit 19–23 ovat saman kysymyksen englanninkielisiä versioita (sama aihe-kategoria)
  const cat = { aukioloajat: 'opening_hours', 'käytännöt': 'practical', saapuminen: 'arrival', varaaminen: 'booking' };
  for (const [fi, en] of Object.entries(LEGACY_FAQ_EN)) {
    const a = kb.faq.find((x) => x.id === +fi), b = kb.faq.find((x) => x.id === en);
    assert.ok(a && b && a.language === 'fi' && b.language === 'en' && cat[a.category] === b.category, `${fi} ↔ ${en}`);
  }
});

test('kb-en: ehdot – _en → vanha EN-rivi → suomi; sisäiset eivät koskaan', () => {
  assert.deepEqual(policyFor(1, 'en', FAKE), { id: 1, title: 'General', body: 'EN', lang: 'en' });
  assert.deepEqual(policyFor(2, 'en', FAKE), { id: 2, title: 'Reservation terms', body: 'EN old', lang: 'en' });
  assert.deepEqual(policyFor(9, 'en', FAKE), { id: 9, title: 'Vuosikortti', body: 'FI', lang: 'fi' });
  assert.equal(policyFor(4, 'en', FAKE), null);
  assert.equal(policyFor(1, 'fi', FAKE).title, 'Yleiset');
  for (const [fi, en] of Object.entries(LEGACY_POLICY_EN)) {
    const a = kb.policies.find((x) => x.id === +fi), b = kb.policies.find((x) => x.id === en);
    assert.ok(a && b && a.language === 'fi' && b.language === 'en' && a.category === b.category, `${fi} ↔ ${en}`);
  }
});

test('kb-en: tapahtuman aikateksti – EN suosii time_text_en:ää, muuten enTime(time_text)', () => {
  const enTime = (t) => `conv:${t}`;
  assert.equal(eventTimeFor({ time_text: 'klo 18', time_text_en: '6 pm' }, 'en', enTime), '6 pm');
  assert.equal(eventTimeFor({ time_text: 'klo 18', time_text_en: '' }, 'en', enTime), 'conv:klo 18');
  assert.equal(eventTimeFor({ time_text: 'klo 18' }, 'fi', enTime), 'klo 18');
  assert.equal(eventTimeFor({}, 'en', enTime), '');
  const r = read('src/render.mjs');
  assert.match(r, /dates\.map\(\(d\) => eventTimeFor\(d, lang, enTime\)\)/);
  assert.doesNotMatch(r, /lang === 'en' \? enTime\(times\[0\]\)/, 'ei kaksinkertaista muunnosta');
});

test('sivut: listat suomenkielisillä id:illä, ei vanhoja EN-rivejä (ei tuplia); privacy.json ennallaan', () => {
  const info = json('content/pages/info.json'), terms = json('content/pages/terms.json'), priv = json('content/pages/privacy.json');
  assert.deepEqual(info.en.faq, [1, 9, 11, 10]);
  assert.deepEqual(terms.en.policies, [1, 2, 3, 5, 6, 8, 25]);
  for (const id of [...info.fi.faq, ...info.en.faq]) assert.equal(kb.faq.find((x) => x.id === id)?.language, 'fi', `faq ${id}`);
  for (const id of [...terms.fi.policies, ...terms.en.policies]) assert.equal(kb.policies.find((x) => x.id === id)?.language, 'fi', `policy ${id}`);
  for (const l of [info.en.faq, terms.en.policies]) assert.equal(new Set(l).size, l.length);
  assert.deepEqual(priv.fi.policies, [7]);
  if (priv.en) assert.deepEqual(priv.en.policies, [7]);
  assert.match(read('src/render.mjs'), /name === 'privacy'\s*\? d\.policies\.map\(\(id\) => kb\.policies\.find/);
});

test('renderöinti + FAQPage: EN-sivu nykyisellä snapshotilla = vanhat EN-tekstit, FI ennallaan, skeema = näkyvät kysymykset', async () => {
  const R = await import('../../src/render.mjs');
  const { seoSchemaForPage } = await import('../../src/seo-enhance.mjs');
  const q = (h) => [...h.slice(h.indexOf('class="narrow faq"')).matchAll(/<details[^>]*><summary>([^<]*)<\/summary>/g)].map((m) => m[1]);
  const en = R.info('en'), fi = R.info('fi');
  const exp = (lang) => json('content/pages/info.json')[lang].faq.map((id) => faqFor(id, lang)).map((f) => f.question.replace(/&/g, '&amp;').replace(/'/g, '&#39;').replace(/"/g, '&quot;'));
  assert.deepEqual(q(en), exp('en'));
  assert.deepEqual(q(fi), exp('fi'));
  assert.ok(!/<details lang="fi">/.test(en) || kb.faq.some((x) => x.language === 'fi' && !x.question_en), 'fi-varateksti merkitään lang="fi"');
  for (const lang of ['fi', 'en']) {
    const body = lang === 'en' ? en : fi;
    const s = seoSchemaForPage({ lang, key: 'info', url: 'https://example.test/', body }).find((x) => x['@type'] === 'FAQPage');
    const want = json('content/pages/info.json')[lang].faq.map((id) => faqFor(id, lang)).filter((f) => f.lang === lang).map((f) => f.question);
    assert.deepEqual(s.mainEntity.map((x) => x.name), want, `${lang}: FAQPage`);
  }
  const t = R.policyPage('terms', 'terms', 'en');
  for (const id of json('content/pages/terms.json').en.policies) assert.ok(t.includes(policyFor(id, 'en').title.replace(/&/g, '&amp;')), `terms ${id}`);
});

test('kb-snapshot: _en-kentät snapshotiin rivin id:llä, tyhjät pois, sisäiset/epäaktiiviset eivät tule mukaan', () => {
  const dir = mkdtempSync(join(tmpdir(), 'en-lahteet-'));
  mkdirSync(join(dir, 'content/kb'), { recursive: true });
  const exp = { d: {
    businesses: [{ id: 1, trade_name: 'S', description: 'Kuvaus', description_en: 'Description' }],
    locations: [{ id: 1, active: true, name: 'Paikka', name_en: 'Place', parking_en: '', directions_en: 'Turn left' }],
    products: [], variants: [],
    hours: [{ id: 1, active: true, weekday: 1, session_name: 'Iltavuoro', session_name_en: 'Evening session', swimsuit_rule_en: null }],
    events: [{ id: 1, active: true, product_id: 1, starts_on: '2026-11-01', time_text: 'klo 18', time_text_en: '6 pm' }],
    policies: [{ id: 1, status: 'active', internal: false, title: 'T', body: 'B', language: 'fi', title_en: 'Te', body_en: 'Be' }, { id: 2, status: 'draft', internal: false, title: 'X', body: 'Y', language: 'fi', title_en: 'Xe' }],
    faq: [{ id: 1, active: true, question: 'K', answer: 'V', language: 'fi', question_en: 'Q', answer_en: 'A' }, { id: 2, active: false, question: 'P', answer: 'P', language: 'fi', question_en: 'PQ' }],
  } };
  writeFileSync(join(dir, 'export.json'), JSON.stringify(exp));
  try { execFileSync(process.execPath, [join(repo, 'scripts/kb-snapshot.mjs'), 'export.json'], { cwd: dir, stdio: 'pipe' }); } catch (e) { assert.fail(String(e.stderr || e)); }
  const out = JSON.parse(readFileSync(join(dir, 'content/kb/kb.json'), 'utf8'));
  assert.deepEqual(out.faq.map((f) => [f.id, f.question_en, f.answer_en]), [[1, 'Q', 'A']]);
  assert.deepEqual(out.policies.map((p) => [p.id, p.title_en, p.body_en]), [[1, 'Te', 'Be']]);
  assert.equal(out.business.description_en, 'Description');
  const [ev] = out.events, [hr] = out.hours, [loc] = out.locations;
  assert.equal(ev.time_text_en, '6 pm');
  assert.equal(hr.session_name_en, 'Evening session'); assert.ok(!('swimsuit_rule_en' in hr), 'null pois');
  assert.equal(loc.name_en, 'Place'); assert.equal(loc.directions_en, 'Turn left'); assert.ok(!('parking_en' in loc), 'tyhjä pois');
  assert.match(read('scripts/kb-snapshot.mjs'), /faq: \['question_en', 'answer_en'\]/);
});

test('CI: en-lahteet.test.mjs ajetaan pages.yml:ssä', () => {
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/en-lahteet\.test\.mjs/);
});
