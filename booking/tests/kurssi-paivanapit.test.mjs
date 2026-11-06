// Kurssin ilmoittautuminen tuotesivulla (Joonas 6.11.2026, t1366u): vain "Valitse päivä", ei "Valitse aika".
// Ehto on kb.products.category = 'training'. Tapahtumat (kind=event, category event) ja muut tuotteet pitävät päivä + kellonaika -valinnan,
// myös silloin kun päivällä on vain yksi vuoro. Lue lisää: vuorosääntöjen nimet + alku- ja loppuajat + peruutusehto.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { T } from '../shop/src/i18n.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const NOW = Date.parse('2026-11-06T08:00:00Z');
const M = await import(pathToFileURL(join(root, 'shop/src/training-dates.js')).href);
const { groupEventDays } = await import(pathToFileURL(join(root, 'shop/src/event-pick.js')).href);

// Intro Course (kb 114) tuotannon vuorosäännöt 105 ja 106: ma 12:30, 3090 min → ke 16:00 (Helsinki).
const INTRO = {
  '2026-11-23': [{ rule_id: 105, label: '23.–25.11.2026', label_en: '23–25 Nov 2026', session_date: '2026-11-23', starts_at: '2026-11-23T10:30:00Z', ends_at: '2026-11-25T14:00:00Z', status: 'full', remaining: 0 }],
  '2027-04-19': [{ rule_id: 106, label: '19.–21.4.2027', label_en: '19–21 Apr 2027', session_date: '2027-04-19', starts_at: '2027-04-19T09:30:00Z', ends_at: '2027-04-21T13:00:00Z', status: 'available', remaining: 6 }],
};
const CLOCK = /(?<![\d.])\d{1,2}[:.]\d{2}(?![\d.])|klo/;
const days = groupEventDays(INTRO, { now: NOW, today: '2026-11-06' });
const sessions = M.trainingSessions(days, new Map());

test('ehto: vain category = training (ei kind/event, ei deposit-lippu, ei vuorojen määrä)', () => {
  assert.equal(M.isTrainingCategory({ category: 'training' }), true);
  for (const c of ['event', 'public_sauna', 'private_sauna', 'ceremony', 'corporate', 'treatment', 'ritual', 'gift_card', undefined]) {
    assert.equal(M.isTrainingCategory({ category: c, kind: 'event' }), false, String(c));
  }
  assert.equal(M.isTrainingCategory({ category: 'event', deposit: true }), false);
  assert.equal(M.isTrainingCategory(null), false);
});

test('päivänapin teksti FI+EN: vain päiväväli, ei kellonaikoja (Intro Course)', () => {
  const fi = sessions.map((s) => M.sessionDateText(s.r, s.segs, 'fi'));
  const en = sessions.map((s) => M.sessionDateText(s.r, s.segs, 'en'));
  assert.deepEqual(fi, ['23.–25.11.2026', '19.–21.4.2027']);
  assert.deepEqual(en, ['Mon 23 Nov – Wed 25 Nov 2026', 'Mon 19 Apr – Wed 21 Apr 2027']);
  for (const x of [...fi, ...en]) assert.doesNotMatch(x, CLOCK, x);
});

test('formatDateSpan: kuukauden ja vuoden vaihde, yksi päivä', () => {
  assert.equal(M.formatDateSpan('2026-11-30T10:30:00Z', '2026-12-04T14:00:00Z', 'fi'), '30.11.–4.12.2026');
  assert.equal(M.formatDateSpan('2026-11-30T10:30:00Z', '2026-12-04T14:00:00Z', 'en'), 'Mon 30 Nov – Fri 4 Dec 2026');
  assert.equal(M.formatDateSpan('2026-12-28T10:30:00Z', '2027-01-02T14:00:00Z', 'fi'), '28.12.2026–2.1.2027');
  assert.equal(M.formatDateSpan('2026-12-28T10:30:00Z', '2027-01-02T14:00:00Z', 'en'), 'Mon 28 Dec 2026 – Sat 2 Jan 2027');
  assert.equal(M.formatDateSpan('2027-04-19T09:30:00Z', '2027-04-19T13:00:00Z', 'fi'), '19.4.2027');
  assert.equal(M.formatDateSpan('2027-04-19T09:30:00Z', '2027-04-19T13:00:00Z', 'en'), 'Mon 19 Apr 2027');
  assert.equal(M.formatDateSpan('x', null, 'fi'), '');
});

test('monijaksoinen kurssi: jaksojen päivävälit ilman kellonaikoja', () => {
  const segs = [
    { label: 'Sauna healing 30.11.2026', label_en: 'Sauna healing 30 Nov 2026', starts_at: '2026-11-30T10:30:00Z', ends_at: '2026-12-04T14:00:00Z' },
    { label: 'Jatkoviikko 7.12.2026', label_en: 'Second week 7 Dec 2026', starts_at: '2026-12-07T10:30:00Z', ends_at: '2026-12-13T14:00:00Z' },
  ];
  const r = { rule_id: 111, starts_at: segs[0].starts_at, ends_at: segs[1].ends_at, status: 'available', remaining: 6 };
  assert.equal(M.sessionDateText(r, segs, 'fi'), '30.11.–4.12.2026 · 7.–13.12.2026');
  assert.doesNotMatch(M.sessionDateText(r, segs, 'en'), CLOCK);
  const rows = M.scheduleRows(M.trainingSessions([{ date: '2026-11-30', slots: [r] }], new Map([[111, segs]])), 'fi', NOW);
  assert.deepEqual(rows[0].parts.map((p) => p.title), ['Sauna healing 30.11.2026', 'Jatkoviikko 7.12.2026']);
  assert.match(rows[0].parts[0].when, /klo 12\.30/);
});

test('kerrat: yksi nappi per kerta, täysi kerta merkitty, paikat jäljellä', () => {
  assert.equal(sessions.length, 2);
  assert.equal(sessions[0].full, true);
  assert.equal(sessions[0].remaining, null);
  assert.equal(sessions[1].full, false);
  assert.equal(sessions[1].remaining, 6);
  assert.equal(T.fi.freeSpots(6), '6 vapaana');
  assert.equal(T.en.freeSpots(6), '6 left');
  const two = M.trainingSessions([{ date: '2027-01-01', slots: [{ rule_id: 1, status: 'available', remaining: 2 }, { rule_id: 2, status: 'full' }] }]);
  assert.deepEqual(two.map((s) => s.r.rule_id), [1, 2], 'kaksi kertaa samana päivänä → kaksi nappia');
});

test('Lue lisää -aikataulu FI+EN: vuorosäännön nimi + alku- ja loppuaika kellonaikoineen', () => {
  const fi = M.scheduleRows(sessions, 'fi', NOW);
  const en = M.scheduleRows(sessions, 'en', NOW);
  assert.deepEqual(fi.map((x) => x.title), ['23.–25.11.2026', '19.–21.4.2027']);
  assert.deepEqual(en.map((x) => x.title), ['23–25 Nov 2026', '19–21 Apr 2027']);
  assert.equal(fi[1].when, 'ma 19.4.2027 klo 12.30 – ke 21.4.2027 klo 16.00');
  assert.equal(en[1].when, 'Mon 19 Apr 2027 12:30 – Wed 21 Apr 2027 16:00');
  assert.equal(fi[0].full, true);
  assert.equal(M.trainingDateText('schedule', 'fi'), 'Ajankohdat ja aikataulu');
  assert.equal(M.trainingDateText('schedule', 'en'), 'Dates and schedule');
  assert.equal(M.trainingDateText('schedule', 'fi', (k) => (k === 'ui.shop.training.schedule' ? 'X' : null)), 'X');
});

const src = read('booking/shop/src/shop.js');
const body = src.slice(src.indexOf('async function viewProduct'), src.indexOf('\nfunction slotItem'));

test('kauppa: kurssilla ei "Valitse aika" -osiota; päivänappi vie suoraan kerran ilmoittautumiseen', () => {
  assert.match(body, /const course = isTrainingCategory\(p\);/);
  assert.match(body, /if \(course\) \{ drawCourse\(calBox, slotBox, days, segByRule\); return; \}/, 'kurssi palaa ennen drawTimes-kutsua');
  const course = body.slice(body.indexOf('function drawCourse'), body.indexOf('const draw = async'));
  assert.doesNotMatch(course, /eventPickTime|pickTime|drawTimes|bk-ev-time/, 'kurssinäkymässä ei kellonaikavalintaa');
  assert.match(course, /slotBox\.replaceChildren\(\)/);
  assert.match(course, /bk\(`\/varaa\/\$\{s\.r\.rule_id\}\/\$\{s\.date\}\/\$\{p\.id\}`\)/, 'sama reitti kuin ennen kellonajan napista');
  assert.match(course, /sessionDateText\(s\.r, s\.segs, S\.lang\)/);
  assert.doesNotMatch(course, /\bhm\(|occurrenceText|formatWhenList/, 'napissa ei kellonaikoja');
  assert.match(course, /is-full/);
  assert.match(course, /'aria-disabled': s\.full \? 'true' : null/);
  assert.match(course, /t\.freeSpots\(s\.remaining\)/);
  assert.match(course, /t\.full/);
  assert.match(body, /moreInfo\(desc, schedBox\)/);
});

test('kauppa: tapahtumat ja muut tuotteet ennallaan (päivä + kellonaika, myös yhden vuoron päivä)', () => {
  assert.match(body, /const eventProduct = p\.category === 'event' \|\| training;/);
  const ev = body.slice(body.indexOf('async function fillEventDates'));
  assert.match(ev, /const drawTimes = \(\) => \{/);
  assert.match(ev, /h\('h3', \{ id: 'bk-ev-time-h', text: t\.eventPickTime \}\)/);
  assert.match(ev, /day\.slots\.map\(\(r\) => eventTimeLink/);
  assert.doesNotMatch(body, /slots\.length === 1[\s\S]{0,160}(?:drawTimes|slotBox\.hidden|eventPickTime)/, 'yksi vuoro ei piilota kellonaikaa');
  assert.doesNotMatch(body, /kind === 'event'[\s\S]{0,80}course|course = [^;]*kind/, 'ehto ei ole kind=event');
  assert.match(body, /h\('h3', \{ text: `\$\{t\.pickSlot\} – /, 'kuukausikalenterin tuotteet: vuorolista ennallaan');
  assert.equal(T.fi.eventPickTime, 'Valitse kellonaika');
  assert.equal(T.en.eventPickTime, 'Choose a time');
});

test('Lue lisää: aikataulu ennen peruutusehtoa, ei pelkkä peruutusehto', () => {
  const mi = src.slice(src.indexOf('function moreInfo'), src.indexOf('// ---- näkymä 1'));
  assert.match(mi, /function moreInfo\(desc, extra = null\)/);
  assert.ok(mi.indexOf('extra,') < mi.indexOf('S.cancelRule'), 'aikataulu ennen peruutusehtoa');
  assert.match(body, /data-testid': 'training-schedule'/);
  assert.match(body, /scheduleRows\(sessions, S\.lang\)/);
  assert.match(body, /trainingDateText\('schedule', S\.lang/);
  const css = read('booking/shop/src/shop.css');
  assert.match(css, /\.bk-ev-date\[aria-current="true"\],\.bk-ev-date\[aria-pressed="true"\]/);
  assert.match(css, /\.bk-course-list>li\{[^}]*overflow-wrap:anywhere/);
});

test('pending-import-126: FI+EN, sama kuin koodin oletus, ei <, ei päällekkäin', () => {
  const rows = JSON.parse(read('content/site-texts.pending-import-126.json')).filter((r) => r.key === 'ui.shop.training.schedule');
  assert.equal(rows.length, 2);
  for (const r of rows) {
    assert.equal(r.key, 'ui.shop.training.schedule');
    assert.equal(r.text, M.TRAINING_DATE_TEXTS[r.lang].schedule);
    assert.equal(r.kind, 'plain');
    assert.doesNotMatch(r.text, /[<>]/);
    assert.ok(r.max_len >= r.text.length);
  }
  for (const f of readdirSync(join(repo, 'content')).filter((n) => /^site-texts\.(pending-import|imported).*\.json$/.test(n) && n !== 'site-texts.pending-import-126.json')) {
    const other = JSON.parse(readFileSync(join(repo, 'content', f), 'utf8'));
    if (!Array.isArray(other)) continue;
    for (const r of other) assert.notEqual(r.key, 'ui.shop.training.schedule', f);
  }
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/kurssi-paivanapit\.test\.mjs/);
});
