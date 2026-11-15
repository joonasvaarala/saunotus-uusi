// Viikko-ohjelman uusi komponentti (backlog 82, Joonas t1768u + t1769u): malli (week-grid-logic.js), näkymä (week-grid-view.js),
// rakennusvaiheen varaversio (src/week-grid.mjs) ja tuonti 171. Ei verkkoa, ei kantaa: kaikki data on tässä tiedostossa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, cpSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { buildWeek, careName, CARE_HORIZON_DAYS, weekStartOf, isoWeekNumber, weekRange, clampWeek, eventHint, careEntry, MAX_WEEKS_AHEAD } from '../booking/shop/src/week-grid-logic.js';
import { weekGridTree, toHtml, h, ownDuration, headingTitle } from '../booking/shop/src/week-grid-view.js';
import { WEEK_GRID_TEXTS } from '../booking/shop/src/week-grid-texts.js';
import { shopHrefs, loadWeek } from '../booking/shop/src/week-grid.js';
import { weekGrid, gridTexts, trainingUrl } from '../src/week-grid.mjs';

const START = '2026-11-16';                     // maanantai, viikko 47
const TODAY = '2026-11-16';
const NOW = Date.parse('2026-11-16T06:00:00Z'); // 8.00 Helsingissä
const ut = (d, hhmm) => { const [hh, mm] = hhmm.split(':').map(Number); return new Date(Date.parse(`${d}T00:00:00Z`) + ((hh - 2) * 60 + mm) * 6e4).toISOString(); };   // marraskuu = UTC+2
let rule = 1;
const row = (slug, category, product_id, date, s, e, extra = {}) => ({ slug, category, product_id, rule_id: rule++, session_date: date, starts_at: ut(date, s), ends_at: ut(date, e), status: 'available', remaining: 10, unit_price: null, base_price: null, ...extra });
const catalog = [
  { id: 1, slug: 'yleinensauna', name: 'Yleinen vuoro', name_en: 'Public Sauna Session', category: 'public_sauna' },
  { id: 5, slug: 'turvetorstai', name: 'Turvetorstai', category: 'public_sauna' },
  { id: 6, slug: 'tunnin-vuoro', name: 'Tunnin vuoro', category: 'public_sauna' },
  { id: 25, slug: 'oma-saunavuoro', name: 'Oma savusaunavuoro', category: 'private_sauna' },
  { id: 26, slug: 'jalkiloylyt', name: 'Savusaunan jälkilöylyt', category: 'private_sauna' },
];
const rows = [
  row('miestensauna-2', 'public_sauna', 2, '2026-11-16', '16:00', '19:00', { unit_price: 29 }),
  row('turvetorstai', 'public_sauna', 5, '2026-11-19', '16:00', '19:00', { unit_price: 35 }),
  row('tunnin-vuoro', 'public_sauna', 6, '2026-11-21', '14:00', '15:00', { unit_price: 18 }),
  row('tunnin-vuoro', 'public_sauna', 6, '2026-11-21', '15:00', '16:00', { unit_price: 18 }),
  row('yleinensauna', 'public_sauna', 1, '2026-11-21', '14:00', '16:00', { unit_price: 29, remaining: 12 }),
  row('yleinensauna', 'public_sauna', 1, '2026-11-21', '15:00', '17:00', { unit_price: 29, remaining: 2 }),
  row('yleinensauna', 'public_sauna', 1, '2026-11-21', '16:00', '18:00', { unit_price: 29, status: 'full', remaining: 0 }),
  row('oma-saunavuoro', 'private_sauna', 25, '2026-11-21', '13:00', '15:00', { base_price: 300 }),
  row('oma-saunavuoro', 'private_sauna', 25, '2026-11-21', '14:00', '15:00', { base_price: 250 }),
  row('oma-saunavuoro', 'private_sauna', 25, '2026-11-22', '13:00', '15:00', { base_price: 300, status: 'full' }),
  row('turvesauna', 'private_sauna', 31, '2026-11-21', '13:00', '15:00', { base_price: 400 }),
  row('saunavuoro-yrityksille', 'corporate', 48, '2026-11-21', '13:00', '15:00', { base_price: 350 }),
  row('jalkiloylyt', 'private_sauna', 26, '2026-11-16', '19:00', '21:00', { base_price: 180, rule_id: 22 }),
  row('jalkiloylyt', 'private_sauna', 26, '2026-11-21', '19:00', '22:00', { base_price: 300, status: 'full', rule_id: 23 }),
  row('jalkiloylyt', 'private_sauna', 26, '2026-11-15', '19:00', '22:00', { base_price: 250 }),   // viikon ulkopuolella
];
const offers = [{ product_id: 26, rule_id: 22, session_date: '2026-11-16', starts_at: ut('2026-11-16', '19:00'), ends_at: ut('2026-11-16', '21:00'), percent: 20, base_price: 180, discounted_price: 144 }];
const care = [
  careEntry({ id: 10, slug: 'saunahoito-2', name: 'Saunahoito' }, new Map([['2026-11-17', [{}]], ['2026-11-22', [{}]]])),
  careEntry({ id: 8, slug: 'saunotusrituaali', name: 'Saunotusrituaali' }, new Map([['2026-11-21', [{}]]])),
  careEntry({ id: 7, slug: 'saunarituaali-ja-savusaunavuoro', name: 'Saunarituaali ja savusaunavuoro (la & su)' }, new Map([['2026-11-21', [{}]]])),
];
const ev = (slug, name, occ, extra = {}) => ({ category: 'event', slug, name, product_id: 9, price: 59, occurrences: occ, ...extra });
const occ = (date, s, e, status = 'available') => ({ rule_id: 69, status, starts_at: ut(date, s), ends_at: ut(date, e) });
const hrefs = shopHrefs('/varaa/');
const base = { start: START, today: TODAY, now: NOW, rows, catalog, care, events: [], offers, lang: 'fi', hrefs };
const week = (o = {}) => buildWeek({ ...base, ...o });
const day = (m, date) => m.days.find((d) => d.date === date);

test('viikon apurit: maanantai, ISO-viikko, väli ja selausrajat', () => {
  assert.equal(weekStartOf('2026-11-22'), '2026-11-16');
  assert.equal(weekStartOf('2026-11-16'), '2026-11-16');
  assert.equal(isoWeekNumber('2026-11-16'), 47);
  assert.equal(weekRange('2026-11-16'), '16.–22.11.');
  assert.equal(weekRange('2026-11-30'), '30.11.–6.12.');
  assert.equal(weekRange('2026-11-16', 'en'), '16–22 Nov');
  assert.equal(weekRange('2026-11-30', 'en'), '30 Nov–6 Dec');
  assert.equal(week({ lang: 'en' }).range, '16–22 Nov');
  assert.equal(clampWeek('2026-11-09', TODAY), '2026-11-16');
  assert.equal(clampWeek('2027-06-07', TODAY), `2027-01-11`.replace('2027-01-11', new Date(Date.parse('2026-11-16T12:00:00Z') + 7 * MAX_WEEKS_AHEAD * 864e5).toISOString().slice(0, 10)));
  const m = week();
  assert.deepEqual(m.nav, { prev: false, next: true, now: false });
  assert.equal(m.todayIdx, 0);
  assert.equal(week({ start: '2026-11-23' }).nav.now, true);
  assert.equal(week({ start: '2026-11-23' }).nav.prev, true);
  assert.equal(week({ start: '2026-11-23' }).todayIdx, -1);
});

test('yleiset vuorot: tunnin vuoroa ei näytetä, Turvetorstai näkyy, useampi alkuaika → chips, täynnä-tila', () => {
  const m = week();
  const all = m.days.flatMap((d) => d.public);
  assert.ok(!all.some((g) => g.slug === 'tunnin-vuoro'), 'tunnin vuoro pois');
  assert.ok(!JSON.stringify(m).includes('Tunnin'), 'ei tunnin vuoroa missään');
  assert.deepEqual(day(m, '2026-11-19').public.map((g) => g.name), ['Turvetorstai']);
  assert.equal(day(m, '2026-11-16').public[0].price.replace(/\s/g, ' '), '29 €');
  const sat = day(m, '2026-11-21').public;
  assert.equal(sat.length, 1);
  assert.equal(sat[0].name, 'Yleinen vuoro');
  assert.equal(sat[0].time, '14.00–18.00');
  assert.equal(sat[0].dur, '2 h');
  assert.deepEqual(sat[0].chips.map((c) => [c.label, c.full, c.low]), [['14.00', false, null], ['15.00', false, 2], ['16.00', true, null]]);
  assert.equal(sat[0].full, false);
  assert.equal(sat[0].href, '/varaa/#/tuote/yleinensauna/2026-11-21');
  assert.equal(day(m, '2026-11-20').publicNone, true, 'perjantaina ei yleistä vuoroa');
  assert.equal(day(m, '2026-11-20').public.length, 0);
  // koko vuoro täynnä
  const fullRows = rows.map((r) => (r.slug === 'yleinensauna' ? { ...r, status: 'full' } : r));
  assert.equal(day(week({ rows: fullRows }), '2026-11-21').public[0].full, true);
});

test('oma saunavuoro: vain "alk." halvin vapaa hinta, ei turvesaunaa eikä yrityksiä; jälkilöylyt ale ja täynnä', () => {
  const m = week();
  const sat = day(m, '2026-11-21');
  assert.equal(sat.own.price.replace(/\s/g, ' '), '250 €', 'päivän halvin vapaa');
  assert.equal(sat.own.href, '/varaa/#/tuote/oma-saunavuoro/2026-11-21');
  assert.equal(day(m, '2026-11-22').own.full, true, 'kaikki varattu');
  assert.equal(day(m, '2026-11-17').own, null);
  assert.ok(!JSON.stringify(m).match(/turvesauna|yritykset|saunavuoro-yrityksille/i), 'ei turvesaunaa eikä Yrityksille-riviä');
  const mon = day(m, '2026-11-16').after;
  assert.equal(mon.length, 1);
  assert.equal(mon[0].price.replace(/\s/g, ' '), '144 €');
  assert.equal(mon[0].was.replace(/\s/g, ' '), '180 €');
  assert.equal(mon[0].pct, '20');
  assert.equal(mon[0].time, '19.00–21.00');
  assert.equal(mon[0].href, '/varaa/#/varaa/22/2026-11-16/26');
  const full = day(m, '2026-11-21').after;
  assert.equal(full.length, 1);
  assert.equal(full[0].full, true);
  assert.equal(full[0].pct, '');
  assert.ok(!m.days.some((d) => d.after.some((a) => a.time === '19.00–22.00' && !a.full)), 'viikon ulkopuolinen jälkilöyly ei näy');
  // ilman tarjousta täysi hinta
  assert.equal(day(week({ offers: [] }), '2026-11-16').after[0].price.replace(/\s/g, ' '), '180 €');
  assert.equal(day(week({ offers: [] }), '2026-11-16').after[0].pct, '');
  // ale oman vuoron halvimmassa hinnassa
  const o2 = [{ product_id: 25, rule_id: rows[8].rule_id, session_date: '2026-11-21', starts_at: rows[8].starts_at, ends_at: rows[8].ends_at, percent: 10, base_price: 250, discounted_price: 225 }];
  const own = day(week({ offers: o2 }), '2026-11-21').own;
  assert.equal(own.price.replace(/\s/g, ' '), '225 €');
  assert.equal(own.pct, '10');
});

test('hoidot ja rituaalit: vain nimet, ei Saunotusrituaalia, paketti mukana; tapahtumat samassa solussa', () => {
  const events = [ev('perinnesaunotusilta', 'Perinnesaunotusilta', [occ('2026-11-20', '17:00', '18:30'), occ('2026-11-20', '19:00', '20:30')])];
  const m = week({ events });
  const sat = day(m, '2026-11-21');
  assert.deepEqual(sat.care.map((c) => c.name), ['Saunarituaali ja savusaunavuoro'], 'saunotusrituaali pois, sulkuselite pois');
  assert.equal(sat.care[0].href, '/varaa/#/tuote/saunarituaali-ja-savusaunavuoro?n=1&d=2026-11-21');
  assert.deepEqual(Object.keys(sat.care[0]), ['name', 'href'], 'ei kellonaikoja');
  assert.deepEqual(day(m, '2026-11-17').care.map((c) => c.name), ['Saunahoito']);
  assert.ok(!m.days.some((d) => d.care.some((c) => /saunotusrituaali/i.test(c.href) && !/ritual-ja/.test(c.href))));
  const fri = day(m, '2026-11-20');
  assert.equal(fri.events.length, 1, 'tapahtuma perjantain Hoidot ja rituaalit -soluun');
  assert.equal(fri.events[0].name, 'Perinnesaunotusilta');
  assert.equal(fri.events[0].price.replace(/\s/g, ' '), '59 €');
  assert.deepEqual(fri.events[0].times, ['17.00–18.30', '19.00–20.30']);
  assert.equal(fri.events[0].href, '/varaa/#/tuote/perinnesaunotusilta/2026-11-20');
  assert.equal(m.hasEvents, true);
  assert.equal(careName('Saunarituaali ja savusaunavuoro (la & su)'), 'Saunarituaali ja savusaunavuoro');
  assert.equal(careName('Saunahoito'), 'Saunahoito');
  // ei tapahtumia → ei ylimääräistä
  assert.equal(week().hasEvents, false);
  assert.ok(week().days.every((d) => d.events.length === 0));
  // täysi tapahtuma merkitään, menneet ja closed pois
  const evs = week({ events: [ev('a', 'Täysi', [occ('2026-11-20', '17:00', '18:30', 'full')]), ev('b', 'Mennyt', [occ('2026-11-15', '17:00', '18:30')]), ev('c', 'Suljettu', [occ('2026-11-20', '17:00', '18:30', 'closed')])] });
  assert.deepEqual(day(evs, '2026-11-20').events.map((x) => [x.name, x.full]), [['Täysi', true]]);
  assert.equal(evs.days.flatMap((d) => d.events).length, 1);
});

test('hoitojen aikaikkuna: myöhäiset viikot eivät hae hoitoja, vihje seuraavista tapahtumista', () => {
  assert.equal(week({ start: '2026-11-30', care: [] }).careLater, true);
  assert.equal(week().careLater, false);
  assert.equal(week({ start: '2026-11-23', care: [] }).careLater, false, 'ikkunan sisällä');
  const events = [ev('perinnesaunotusilta', 'Perinnesaunotusilta', [occ('2026-12-04', '17:00', '18:30', 'full')]), ev('sipoonjoen-joulusauna', 'Sipoonjoen joulusauna', [occ('2026-12-19', '14:00', '16:00')]), ev('naisten-joulusauna', 'Naisten', [occ('2026-12-18', '16:00', '19:00')])];
  const m = week({ events });
  assert.equal(m.hasEvents, false);
  assert.deepEqual(m.hint.map((x) => [x.name, x.when, x.full]), [['Perinnesaunotusilta', '4.12.', true], ['Sipoonjoen joulusauna', '19.12.', false]], 'Naisten joulusauna ei nouse etusivulle');
  assert.equal(m.hint[0].href, '/varaa/#/tuote/perinnesaunotusilta');
  assert.deepEqual(eventHint(null, { after: START, now: NOW, hrefs }), []);
  // viikon jälkeen -vihje ei toista saman viikon tapahtumaa
  assert.equal(eventHint([ev('x', 'X', [occ('2026-11-20', '17:00', '18:00')])], { after: '2026-11-22', now: NOW, hrefs }).length, 0);
});

test('menneet päivät ja puuttuva haku: publicNone vain ladatulle tulevalle päivälle', () => {
  const m = week({ start: START, today: '2026-11-18', now: Date.parse('2026-11-18T06:00:00Z') });
  assert.equal(day(m, '2026-11-16').past, true);
  assert.equal(day(m, '2026-11-16').publicNone, false);
  assert.equal(day(m, '2026-11-20').publicNone, true);
  const none = week({ rows: null });
  assert.ok(none.days.every((d) => !d.publicNone && d.public.length === 0));
  // alkanut / päättynyt vuoro ei näy
  const late = week({ now: Date.parse('2026-11-16T17:30:00Z') });
  assert.equal(day(late, '2026-11-16').public.length, 0);
});

const T = gridTexts('fi');
const tree = (m, o = {}) => weekGridTree(m, T, { heading: { kicker: 'Viikko-ohjelma', title: T.title }, links: { training: 'https://saunakoulutus.fi', all: '/saunavuorot/#yleiset' }, ...o }).map(toHtml).join('');

test('näkymä: päivät sarakkeina, kolme palvelurivit, ei tapahtumakaistaa, ei tiivis/laaja-nappia', () => {
  const html = tree(week({ events: [ev('perinnesaunotusilta', 'Perinnesaunotusilta', [occ('2026-11-20', '17:00', '18:30')])] }));
  assert.equal((html.match(/class="vk-day[ "]/g) || []).length, 7);
  assert.equal((html.match(/class="vk-lane /g) || []).length, 3, 'kolme palvelurivi: yleiset, oma sauna, hoidot ja rituaalit');
  assert.match(html, /Yleiset vuorot/);
  assert.match(html, /Hoidot ja rituaalit/);
  assert.doesNotMatch(html, /vk-evth|Tapahtumat<\/b>|Yrityksille|Tunnin vuoro|Saunotusrituaali<|Turvesauna|Näytä kaikki tiedot|Näytä vähemmän|aria-expanded/);
  assert.match(html, /vk-evt/, 'tapahtumakortti hoitosolussa');
  const care = html.slice(html.indexOf('vk-carec'));
  assert.match(care, /Perinnesaunotusilta/);
  assert.equal((html.match(/data-vk-pick="\d"/g) || []).length, 7, 'mobiilin päivänauha: 7 päivää');
  assert.match(html, /<button type="button" class="vk-tab is-on is-today"[^>]*data-vk-pick="0"/);
  assert.match(html, /data-vk-nav="prev"[^>]*disabled/, 'ei selata menneisiin viikkoihin');
  assert.match(html, /Viikko 47<\/b> 16\.–22\.11\./);
  assert.match(html, /Koulutukset →/);
  assert.match(html, /href="https:\/\/saunakoulutus\.fi"/);
  assert.match(html, /Kaikki vuorot →/);
  assert.match(html, /Ei yleisiä vuoroja/);
  assert.match(html, /alk\.\s*<b>250 €<\/b>/);
  assert.match(html, /vk-sale">−20 %/);
});

test('näkymä: nimet ja tekstit escapataan, linkit avaavat kaupan oikealle päivälle', () => {
  const evil = [{ ...catalog[0], name: '<img src=x onerror=alert(1)>' }, ...catalog.slice(1)];
  const html = tree(week({ catalog: evil, rows: rows.map((r) => (r.slug === 'yleinensauna' ? { ...r, name: '<b>x</b>' } : r)) }));
  assert.ok(!html.includes('<img src=x'), 'ei raakaa HTML:ää');
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.match(html, /href="\/varaa\/#\/tuote\/oma-saunavuoro\/2026-11-21"/);
  assert.match(html, /href="\/varaa\/#\/varaa\/22\/2026-11-16\/26"/);
  assert.match(html, /href="\/varaa\/#\/tuote\/saunahoito-2\?n=1&amp;d=2026-11-17"/);
  assert.equal(toHtml(h('p', { title: 'a"b' }, '<')), '<p title="a&quot;b">&lt;</p>');
});

test('näkymä: päivänauhan menneet päivät ovat pois käytöstä, valittu päivä merkitään', () => {
  const m = week({ start: START, today: '2026-11-18', now: Date.parse('2026-11-18T06:00:00Z') });
  const html = tree(m, { selected: 4 });
  assert.match(html, /class="vk-tab"[^>]*data-vk-pick="0"[^>]*disabled/);
  assert.match(html, /class="vk-tab is-on"[^>]*data-vk-pick="4"/);
  assert.match(html, /class="vk-day is-on"[^>]*data-vk-day="4"|class="vk-day is-on"[^>]*data-vk-day="4"/);
  assert.match(html, /vk-day is-past/);
});

test('rakennusvaiheen varaversio: 7 päivää, ei hintoja eikä päivämääriä, sama näkymä FI/EN; ei tunnin vuoroa eikä saunotusrituaalia', () => {
  for (const lang of ['fi', 'en']) {
    const html = weekGrid(lang, { heading: true, links: { all: '/x/' } });
    assert.equal((html.match(/class="vk-day[ "]/g) || []).length, 7);
    assert.match(html, /<div class="vk" data-vk data-quiet-week /);
    assert.doesNotMatch(html, /Tunnin|Hour|Saunotusrituaali<|Yrityksille|For companies|Näytä kaikki tiedot|aria-expanded/);
    assert.match(html, lang === 'fi' ? /Tällä viikolla saunassa/ : /This week at the sauna/);
    assert.match(html, /Hoidot ja rituaalit|Treatments and rituals/);
    assert.match(html, /vk-none/);
  }
  assert.doesNotMatch(weekGrid('fi'), /saunakoulutus\.fi/, 'saunavuorot-sivulla ei koulutuslinkkiä');
  assert.match(weekGrid('fi', { heading: true, links: { all: '/x/' } }), /saunakoulutus\.fi/);
});

test('tuonti 171: kaikki viikko-ohjelman avaimet FI + EN, sama kuin koodin varateksti, ei HTML:ää', () => {
  const rowsIn = JSON.parse(readFileSync(new URL('../content/site-texts.pending-import-171.json', import.meta.url), 'utf8'));
  const keys = Object.keys(WEEK_GRID_TEXTS);
  assert.equal(rowsIn.length, keys.length * 2);
  for (const k of keys) for (const lang of ['fi', 'en']) {
    const r = rowsIn.filter((x) => x.key === k && x.lang === lang);
    assert.equal(r.length, 1, `${k} ${lang}`);
    assert.equal(r[0].text, WEEK_GRID_TEXTS[k][lang], `${k} ${lang} = varateksti`);
    assert.doesNotMatch(r[0].text, /<[^>]+>/);
    assert.ok(r[0].text.length <= r[0].max_len);
    assert.equal(r[0].class, 'normal');
    assert.equal(r[0].kind, 'plain');
    assert.deepEqual(r[0].placeholders, r[0].text.match(/\{\{var:\w+\}\}/g) || []);
  }
  assert.ok(keys.every((k) => /^ui\.site\.vk_[a-z_]+$/.test(k)));
});

test('tyylit: ei vanhoja .week/.sess-sääntöjä, ei tiivis/laaja-valitsinta; vk-rakenne mobiili + desktop', () => {
  const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  assert.doesNotMatch(css, /\.week-more|\.week-soon|\.week\.soon|\.week>li|\.sess\b/);
  assert.match(css, /@media \(min-width:900px\)\{[\s\S]*?\.vk-days\{display:grid;grid-template-columns:150px repeat\(7,minmax\(0,1fr\)\)/);
  assert.match(css, /\.vk\.is-js \.vk-day:not\(\.is-on\)\{display:none\}/);
});

// ---- PR #386: korjaukset ----
const evDec = [ev('perinnesaunotusilta', 'Perinnesaunotusilta (la & su)', [occ('2026-12-04', '17:00', '18:30')]), ev('sipoonjoen-joulusauna', 'Sipoonjoen joulusauna', [occ('2026-12-19', '14:00', '16:00')])];

test('hoitoikkuna tulee asetuksesta: 90 pv → viikko 30.11. näyttää hoidot, oletus 14 pv piilottaa vain varalla', () => {
  assert.equal(CARE_HORIZON_DAYS, 14, 'vara-arvo');
  const careDec = [careEntry({ id: 10, slug: 'saunahoito-2', name: 'Saunahoito' }, new Map([['2026-12-01', [{}]], ['2026-12-05', [{}]]]))];
  const wk = { start: '2026-11-30', care: careDec, rows: [] };
  const m90 = week({ ...wk, careHorizon: 90 });
  assert.equal(m90.careLater, false);
  assert.deepEqual(day(m90, '2026-12-01').care.map((c) => c.name), ['Saunahoito']);
  assert.deepEqual(day(m90, '2026-12-05').care.map((c) => c.name), ['Saunahoito']);
  assert.equal(week({ ...wk, careHorizon: 14, care: [] }).careLater, true, 'ikkuna 14 pv: viikko 30.11. ulkopuolella');
  assert.equal(week({ start: '2027-02-15', care: [], careHorizon: 90 }).careLater, true, 'ikkunan ulkopuolella myös 90 pv:llä');
  assert.equal(week({ start: '2026-11-30', care: null, careHorizon: 90 }).careLater, false, 'haku epäonnistui → ei "avautuu lähempänä" -tekstiä');
});

test('tapahtumat näkyvät aina Hoidot ja rituaalit -solussa, myös kun careLater on tosi tai hoitoja ei ole', () => {
  const later = week({ start: '2026-11-30', care: [], careHorizon: 14, events: evDec });
  assert.equal(later.careLater, true);
  assert.deepEqual(day(later, '2026-12-04').events.map((x) => x.name), ['Perinnesaunotusilta'], 'kortin nimestä sulkuosa pois');
  assert.equal(later.hasEvents, true);
  const html = weekGridTree(later, T, {}).map(toHtml).join('');
  const care = html.slice(html.indexOf('vk-carec'));
  assert.match(html, /Hoitojen ajat avautuvat lähempänä/, 'selite palvelurivin otsikossa');
  assert.match(care, /vk-evt/);
  assert.match(care, /Perinnesaunotusilta/);
  assert.equal((html.match(/vk-evt/g) || []).length > 0, true);
  // sama viikko, ikkuna 90: hoito + tapahtuma samassa solussa
  const careFri = [careEntry({ id: 10, slug: 'saunahoito-2', name: 'Saunahoito' }, new Map([['2026-12-04', [{}]]]))];
  const both = week({ start: '2026-11-30', care: careFri, careHorizon: 90, events: evDec });
  const bothHtml = weekGridTree(both, T, {}).map(toHtml).join('');
  assert.match(bothHtml, /vk-cl[^>]*>Saunahoito/);
  assert.match(bothHtml, /vk-evt/);
  assert.doesNotMatch(bothHtml, /Hoitojen ajat avautuvat/);
  // joulusauna 19.12.: viikko 14.–20.12. ikkunan ulkopuolella (14 pv), tapahtuma silti näkyvissä
  const xmas = week({ start: '2026-12-14', care: [], careHorizon: 14, events: evDec });
  assert.deepEqual(day(xmas, '2026-12-19').events.map((x) => x.name), ['Sipoonjoen joulusauna']);
});

test('loadWeek: hoitohaku rajataan näkyvään viikkoon, tähän päivään ja asetusten ikkunaan', async () => {
  const careCalls = [];
  const loadCareFn = async (cat, from, to) => { careCalls.push([from, to]); return []; };
  const rpc = async () => [];
  const cat = [{ id: 10 }];
  // ikkuna 90: viikko 30.11.–6.12. haetaan kokonaan
  await loadWeek('2026-11-30', { rpc, today: TODAY, catalog: cat, horizon: 90, loadCareFn });
  assert.deepEqual(careCalls.pop(), ['2026-11-30', '2026-12-06']);
  // kuluva viikko alkaa tänään (ei menneitä päiviä)
  await loadWeek('2026-11-16', { rpc, today: '2026-11-18', catalog: cat, horizon: 90, loadCareFn });
  assert.deepEqual(careCalls.pop(), ['2026-11-18', '2026-11-22']);
  // ikkuna loppuu kesken viikon: 14 pv tästä päivästä = 16.11.–29.11.; viikko 23.–29.11. kokonaan, 30.11. ei haeta
  await loadWeek('2026-11-23', { rpc, today: TODAY, catalog: cat, horizon: 14, loadCareFn });
  assert.deepEqual(careCalls.pop(), ['2026-11-23', '2026-11-29']);
  const r = await loadWeek('2026-11-30', { rpc, today: TODAY, catalog: cat, horizon: 14, loadCareFn });
  assert.equal(careCalls.length, 0, 'ikkunan ulkopuolella ei hoitohakua');
  assert.deepEqual(r.care, [], 'ei hakua = tyhjä, ei virhe');
  // ikkuna leikkaa viikon: 20 pv → 16.11.–5.12.; viikko 30.11. haetaan 30.11.–5.12.
  await loadWeek('2026-11-30', { rpc, today: TODAY, catalog: cat, horizon: 20, loadCareFn });
  assert.deepEqual(careCalls.pop(), ['2026-11-30', '2026-12-05']);
});

test('careHorizon: public_settings.public_treatment_horizon_days (90), varalla 14', async () => {
  // week-grid.js tuo treatments.js:n dynaamisesti, ja se tuo ./sb.js:n (kopioidaan buildissa) → väliaikainen kopio, sb.js tilalla tynkä
  const dir = join(mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'vk-horizon-')), 'shop');
  cpSync(new URL('../booking/shop/src', import.meta.url).pathname, dir, { recursive: true });
  writeFileSync(join(dir, 'sb.js'), 'export class ApiError extends Error {}\nexport async function rpc() { return null; }\n');
  const W = await import(pathToFileURL(join(dir, 'week-grid.js')));
  assert.equal(await W.careHorizon({ public_treatment_horizon_days: 90 }), 90);
  assert.equal(await W.careHorizon(null), 14);
  assert.equal(await W.careHorizon({}), 14);
});

test('jälkilöyly täynnä: sana «Täynnä» näkyy (FI) / «Full» (EN), aika ja hinta yliviivataan tyylillä', () => {
  const m = week();
  const html = weekGridTree(m, T, {}).map(toHtml).join('');
  assert.match(html, /vk-line is-full[^>]*>[\s\S]*?<span class="vk-lf">Täynnä<\/span>/);
  assert.equal((html.match(/class="vk-lf"/g) || []).length, 1, 'vain täydelle riville');
  assert.doesNotMatch(html.match(/class="vk-line is-quiet"[^]*?<\/a>/)[0], /vk-lf/);
  const en = weekGridTree(week({ lang: 'en' }), gridTexts('en'), {}).map(toHtml).join('');
  assert.match(en, /<span class="vk-lf">Full<\/span>/);
  const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  assert.match(css, /\.vk-lf\{/);
});

test('otsikko: kuluvalla viikolla perusotsikko, muilla viikoilla viikkonumero (FI + EN)', () => {
  const hd = { kicker: 'K', title: T.title };
  assert.equal(headingTitle(week(), T, hd), 'Tällä viikolla saunassa');
  const next = week({ start: '2026-11-30' });
  assert.equal(headingTitle(next, T, hd), 'Viikko 49 saunassa');
  assert.equal(headingTitle(week({ start: '2026-11-30', lang: 'en' }), gridTexts('en'), { title: gridTexts('en').title }), 'Week 49 at the sauna');
  assert.equal(headingTitle({ week: null, nav: { now: false } }, T, hd), T.title, 'staattinen varaversio');
  const html = weekGridTree(next, T, { heading: hd }).map(toHtml).join('');
  assert.match(html, /<h2 class="sec-title">Viikko 49 saunassa<\/h2>/);
  assert.match(weekGridTree(week(), T, { heading: hd }).map(toHtml).join(''), /<h2 class="sec-title">Tällä viikolla saunassa<\/h2>/);
  assert.equal(gridTexts('en').training, 'Sauna training');
  assert.equal(gridTexts('en').titleWeek, 'Week {n} at the sauna');
});

test('EN-viikkoväli näkyy navigaatiossa (16–22 Nov, 30 Nov–6 Dec)', () => {
  const en = gridTexts('en');
  const html = weekGridTree(week({ lang: 'en', start: '2026-11-30' }), en, {}).map(toHtml).join('');
  assert.match(html, /Week 49<\/b> 30 Nov–6 Dec/);
  assert.doesNotMatch(html, /Week 49<\/b> 30\.11/);
});

test('oman vuoron kesto: haarukka (1–7 h), yksi pituus (2 h), tunnin vuoro mukaan haarukkaan mutta ei yleisiin', () => {
  const d = (n) => `2026-11-${n}`;
  const own = (date, s, e) => row('oma-saunavuoro', 'private_sauna', 25, date, s, e, { base_price: 250 });
  const hour = row('tunnin-vuoro', 'public_sauna', 6, d(17), '10:00', '11:00', { unit_price: 18 });
  const rr = [own(d(17), '12:00', '19:00'), hour, own(d(18), '13:00', '15:00'), own(d(19), '10:00', '11:30'), own(d(19), '12:00', '14:00')];
  const m = week({ rows: rr });
  const a = day(m, d(17)).own, b = day(m, d(18)).own, c = day(m, d(19)).own;
  assert.deepEqual([a.durMin, a.durMax], [60, 420], 'tunnin vuoro (1 h) + 7 h');
  assert.deepEqual([b.durMin, b.durMax], [120, 120]);
  assert.equal(ownDuration(a, T), '1–7 h');
  assert.equal(ownDuration(b, T), '2 h');
  assert.equal(ownDuration(c, T), '1,5–2 h', 'FI desimaalipilkku');
  assert.equal(ownDuration(c, gridTexts('en')), '1.5–2 h');
  assert.ok(!day(m, d(17)).public.some((g) => g.slug === 'tunnin-vuoro'), 'tunnin vuoroa ei yleisten vuorojen rivillä');
  const html = weekGridTree(m, T, {}).map(toHtml).join('');
  assert.match(html, /alk\.\s*<b>250\s€<\/b>\s·\s1–7\sh/);
  assert.match(html, /alk\.\s*<b>250\s€<\/b>\s·\s2\sh/);
  const en = weekGridTree(week({ rows: rr, lang: 'en' }), gridTexts('en'), {}).map(toHtml).join('');
  assert.match(en, /from\s*<b>€250<\/b> · 1–7\sh/);
  // täynnä oleva oma vuoro: ei kestoa; ei kestoa jos kaikki pituudet puuttuvat
  assert.equal(ownDuration({ durMin: null, durMax: null }, T), '');
  assert.equal(day(week(), '2026-11-22').own.durMin, null, 'täynnä: ei kestoa');
  assert.doesNotMatch(weekGridTree(week(), T, {}).map(toHtml).join('').match(/vk-oma is-full[^]*?<\/a>/)[0], / h</);
});

test('Koulutukset-linkki: FI saunakoulutus.fi, EN saunahealer.com', () => {
  assert.equal(trainingUrl('fi'), 'https://saunakoulutus.fi');
  assert.equal(trainingUrl('en'), 'https://saunahealer.com');
  const fi = weekGrid('fi', { heading: true, links: { all: '/x/' } });
  const en = weekGrid('en', { heading: true, links: { all: '/x/' } });
  assert.match(fi, /<a class="btn light sm" href="https:\/\/saunakoulutus\.fi" rel="noopener">Koulutukset →<\/a>/);
  assert.match(en, /<a class="btn light sm" href="https:\/\/saunahealer\.com" rel="noopener">Sauna training →<\/a>/);
  assert.doesNotMatch(en, /saunakoulutus\.fi/);
  assert.doesNotMatch(fi, /saunahealer\.com/);
});

test('tapahtumavihje: nimen sulkuosa pois', () => {
  const hint = week({ start: '2026-11-30', care: [], careHorizon: 14, events: [ev('perinnesaunotusilta', 'Perinnesaunotusilta (la & su, rajoitettu)', [occ('2026-12-12', '17:00', '18:30')])] }).hint;
  assert.equal(hint[0].name, 'Perinnesaunotusilta');
});

test('tyylit: viikko-ohjelman virhe- ja vähissä-värit käyttävät --danger-tokenia, ei kovakoodattua heksaa', () => {
  const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  const vk = css.split('\n').filter((l) => /^\.vk-(low|chip\.is-low|error)\b/.test(l)).join('\n');
  assert.match(vk, /\.vk-low\{color:var\(--danger\)/);
  assert.match(vk, /\.vk-error\{[^}]*color:var\(--danger\)/);
  assert.doesNotMatch(vk, /#9a4b1f|#c98a5a/i);
});

test('tapahtumakortin nimi: sulkuosa pois sekä FI:ssä että EN:ssä', () => {
  const events = [ev('perinnesaunotusilta', 'Perinnesaunotusilta (la & su)', [occ('2026-12-04', '17:00', '18:30')], { name_en: 'Traditional Sauna Ritual Evening (Perinnesaunotusilta)' })];
  const fiM = week({ start: '2026-11-30', care: [], careHorizon: 14, events });
  assert.equal(day(fiM, '2026-12-04').events[0].name, 'Perinnesaunotusilta');
  const enM = week({ start: '2026-11-30', care: [], careHorizon: 14, events, lang: 'en' });
  assert.equal(day(enM, '2026-12-04').events[0].name, 'Traditional Sauna Ritual Evening');
  assert.equal(week({ events: [ev('x', 'Joulusauna', [occ('2026-11-20', '17:00', '18:30')])] }).days.find((d) => d.events.length).events[0].name, 'Joulusauna', 'ilman sulkuja ennallaan');
});

test('tyylit: viikko-ohjelman nimet tavuttuvat sanarajoilla (hyphens:auto), ei anywhere/break-all; juuressa lang', () => {
  const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  for (const sel of ['.vk-n', '.vk-cl']) {
    const line = css.split('\n').find((l) => l.startsWith(`${sel}{`));
    assert.ok(line, `${sel} löytyy`);
    assert.match(line, /hyphens:auto/, `${sel} hyphens:auto`);
    assert.doesNotMatch(line, /overflow-wrap:anywhere|word-break:break-all/, `${sel} ei anywhere/break-all`);
  }
  const vkLines = css.split('\n').filter((l) => /^(\.vk\b|\s+\.vk\b)/.test(l)).join('\n');
  assert.doesNotMatch(vkLines, /overflow-wrap:anywhere|word-break:break-all/);
  assert.match(weekGrid('fi'), /<div class="vk" data-vk data-quiet-week lang="fi" /);
  assert.match(weekGrid('en'), /<div class="vk" data-vk data-quiet-week lang="en" /);
});

// ---- PR #386 jatkohuomiot ----
// Kevyt DOM-tynkä mountWeekGrid-testeihin (ei jsdomia): kerää elementit ja tekstit.
function fakeRoot(texts) {
  const mk = (t) => ({ t, className: '', attrs: {}, children: [], append(c) { this.children.push(c); }, setAttribute(k, v) { this.attrs[k] = v; }, focus() {}, nodeType: 1 });
  const doc = { createElement: mk, createTextNode: (s) => ({ text: s }) };
  const listeners = {};
  const root = {
    ownerDocument: doc, dataset: { vkTexts: JSON.stringify(texts), vkOpts: '{}' }, attrs: { lang: 'fi' }, nodes: [],
    getAttribute(k) { return this.attrs[k] ?? null; }, setAttribute(k, v) { this.attrs[k] = v; }, removeAttribute(k) { delete this.attrs[k]; },
    classList: { add() {}, remove() {}, toggle() {} }, addEventListener(ev, fn) { listeners[ev] = fn; }, contains: () => true,
    replaceChildren(...n) { this.nodes = n; }, querySelector: () => null, querySelectorAll: () => [],
    click(kind) { listeners.click({ target: { closest: () => ({ dataset: { vkNav: kind } }) } }); },
    text() { const w = (n) => (n.text != null ? n.text : (n.children || []).map(w).join(' ')); return this.nodes.map(w).join(' '); },
  };
  return root;
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const mountRpc = (calls) => async (name, args) => { calls.push([name, args?.p_from]); return name === 'public_availability_all' ? [] : name === 'public_settings' ? null : []; };

test('viikkoselaus: debounce, nopea selaus hakee vain viimeisen viikon', async () => {
  const { mountWeekGrid } = await import('../booking/shop/src/week-grid.js');
  const calls = [];
  const root = fakeRoot(gridTexts('fi'));
  const vk = mountWeekGrid(root, { rpc: mountRpc(calls), now: () => NOW, debounceMs: 30, loadCareFn: async () => [], shared: async () => ({ events: [], catalog: [{ id: 10 }] }) });
  await wait(60);
  const weekCalls = () => calls.filter((c) => c[0] === 'public_availability_all').length;
  assert.equal(weekCalls(), 1);
  root.click('next'); root.click('next'); root.click('prev'); root.click('next');
  await wait(10);
  assert.equal(weekCalls(), 1, 'ei hakua ennen viivettä');
  await wait(80);
  assert.equal(weekCalls(), 2, 'yksi haku neljästä klikkauksesta');
  assert.equal(vk.start, '2026-11-30', 'next+next+prev+next = +2 viikkoa');
});

test('viikkoselaus: hoitohaun virhe → virheteksti hoitorivillä, tapahtumat jäävät, tulosta ei jäädä välimuistiin', async () => {
  const { mountWeekGrid } = await import('../booking/shop/src/week-grid.js');
  const calls = [];
  let careOk = false;
  const loadCareFn = async () => (careOk ? [careEntry({ id: 10, slug: 'saunahoito-2', name: 'Saunahoito' }, new Map([['2026-11-24', [{}]]]))] : null);
  const evt = [{ category: 'event', slug: 'ilta', name: 'Ilta', price: 20, occurrences: [{ status: 'available', starts_at: ut('2026-11-24', '18:00'), ends_at: ut('2026-11-24', '21:00') }] }];
  const root = fakeRoot(gridTexts('fi'));
  mountWeekGrid(root, { rpc: mountRpc(calls), now: () => NOW, debounceMs: 0, loadCareFn, shared: async () => ({ events: evt, catalog: [{ id: 10 }] }) });
  await wait(30);
  assert.match(root.text(), /Hoitojen aikoja ei saatu haettua/);
  root.click('next'); await wait(30);
  assert.match(root.text(), /Hoitojen aikoja ei saatu haettua/);
  assert.match(root.text(), /Ilta/, 'tapahtuma näkyy samassa solussa');
  careOk = true;
  root.click('prev'); await wait(30);
  root.click('next'); await wait(30);
  assert.doesNotMatch(root.text(), /Hoitojen aikoja ei saatu haettua/, 'epäonnistunutta viikkoa haettiin uudelleen');
  assert.match(root.text(), /Saunahoito/);
});

test('buildWeek: careErr vain kun hoitohaku puuttuu ja päivä on ikkunassa; vk_care_error FI+EN koodissa ja tuonnissa 171', () => {
  const failed = week({ care: null });
  assert.equal(day(failed, '2026-11-17').careErr, true);
  const html = weekGridTree(failed, T, {}).map(toHtml).join('');
  assert.match(html, /class="vk-care-err"[^>]*>Hoitojen aikoja ei saatu haettua\. Yritä hetken päästä uudelleen\./);
  assert.equal(day(week({ care: [] }), '2026-11-17').careErr, false);
  assert.equal(day(week({ start: '2026-11-30', care: null }), '2026-12-01').careErr, false, 'ikkunan ulkopuolella ei virhettä');
  const imp = JSON.parse(readFileSync(new URL('../content/site-texts.pending-import-171.json', import.meta.url), 'utf8')).filter((x) => x.key === 'ui.site.vk_care_error');
  assert.deepEqual(imp.map((x) => x.lang).sort(), ['en', 'fi']);
  const d = WEEK_GRID_TEXTS['ui.site.vk_care_error'];
  assert.equal(imp.find((x) => x.lang === 'fi').text, d.fi);
  assert.equal(imp.find((x) => x.lang === 'en').text, d.en);
});

test('loadCare: rate_limited / busy yritetään uudelleen, muu virhe ei', async () => {
  const dir = join(mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'vk-retry-')), 'shop');
  cpSync(new URL('../booking/shop/src', import.meta.url).pathname, dir, { recursive: true });
  writeFileSync(join(dir, 'sb.js'), 'export class ApiError extends Error {}\nexport async function rpc(n) { return globalThis.__vkRpc(n); }\n');
  const W = await import(pathToFileURL(join(dir, 'week-grid.js')));
  const cat = [{ id: 10, slug: 'saunahoito-2', name: 'Saunahoito', booking_kind: 'slots' }];
  const waits = [];
  const wait_ = async (ms) => { waits.push(ms); };
  for (const code of ['rate_limited', 'busy']) {
    let n = 0;
    globalThis.__vkRpc = async () => { if (n++ < 2) throw Object.assign(new Error(code), { code }); return [{ session_date: '2026-11-17', starts_at: ut('2026-11-17', '12:00'), ends_at: ut('2026-11-17', '13:00'), status: 'available', total: 50 }]; };
    waits.length = 0;
    const r = await W.loadCare(cat, `2026-11-1${code === 'busy' ? 7 : 6}`, '2026-11-22', { retryMs: 5, wait: wait_ });
    assert.equal(r?.length, 1, `${code}: onnistui uudelleenyrityksen jälkeen`);
    assert.ok(r[0].days.has('2026-11-17'));
    if (code === 'rate_limited') assert.equal(waits.length, 2, 'rate_limited: ulompi uudelleenyritys odottaa');   // busy: treatments.js yrittää itse
  }
  const cat2 = [{ ...cat[0], id: 11 }], cat3 = [{ ...cat[0], id: 12 }];   // treatments.js:n välimuisti on tuotekohtainen
  let m = 0;
  globalThis.__vkRpc = async () => { m++; throw Object.assign(new Error('x'), { code: 'bad_range' }); };
  assert.equal(await W.loadCare(cat2, '2026-11-20', '2026-11-22', { retryMs: 5, wait: wait_ }), null);
  assert.equal(m, 1, 'ei uudelleenyritystä muulle virheelle');
  m = 0;
  globalThis.__vkRpc = async () => { m++; throw Object.assign(new Error('x'), { code: 'rate_limited' }); };
  assert.equal(await W.loadCare(cat3, '2026-11-21', '2026-11-22', { retryMs: 5, wait: wait_ }), null);
  assert.equal(m, 3, 'enintään 2 uudelleenyritystä');
});

test('päiväsolun päivämäärä: FI 16.11., EN 16 Nov, vuodenvaihde, aria-label', () => {
  const fi = weekGridTree(week({ start: '2026-12-28' }), T, {}).map(toHtml).join('');
  const en = weekGridTree(week({ start: '2026-12-28', lang: 'en' }), gridTexts('en'), {}).map(toHtml).join('');
  assert.match(fi, /<b>28\.12\.<\/b>/);
  assert.match(fi, /<b>1\.1\.<\/b>/);
  assert.match(fi, /aria-label="Maanantai 28\.12\."/);
  assert.match(en, /<b>28 Dec<\/b>/);
  assert.match(en, /<b>1 Jan<\/b>/);
  assert.match(en, /aria-label="Monday 28 Dec"/);
  assert.doesNotMatch(en, /<b>28\.12\.<\/b>/);
  const en16 = weekGridTree(week({ lang: 'en' }), gridTexts('en'), {}).map(toHtml).join('');
  assert.match(en16, /<b>16 Nov<\/b>/);
});

test('yleisen vuoron nimestä sulkuosa pois (FI ja EN), nimi ilman sulkuja ennallaan', () => {
  const cat2 = [{ id: 5, slug: 'turvetorstai', name: 'Turvetorstai (to)', name_en: 'Peat Thursday (Turvetorstai)', category: 'public_sauna' }, ...catalog.filter((c) => c.id !== 5)];
  const r = [row('turvetorstai', 'public_sauna', 5, '2026-11-19', '16:00', '19:00', { unit_price: 35, name: 'Turvetorstai (to)', name_en: 'Peat Thursday (Turvetorstai)' }), row('yleinensauna', 'public_sauna', 1, '2026-11-20', '16:00', '19:00', { unit_price: 29 })];
  const en = buildWeek({ start: START, today: TODAY, now: NOW, rows: r, catalog: null, care: [], events: [], offers: [], lang: 'en', hrefs: shopHrefs('/'), careHorizon: 90 });
  assert.deepEqual(day(en, '2026-11-19').public.map((x) => x.name), ['Peat Thursday']);
  const fi = buildWeek({ start: START, today: TODAY, now: NOW, rows: r, catalog: null, care: [], events: [], offers: [], lang: 'fi', hrefs: shopHrefs('/'), careHorizon: 90 });
  assert.deepEqual(day(fi, '2026-11-19').public.map((x) => x.name), ['Turvetorstai']);
  assert.ok(cat2.length);
  assert.equal(careName('Peat Thursday (Turvetorstai)'), 'Peat Thursday');
  assert.equal(careName('Public Sauna Session'), 'Public Sauna Session');
});

test('päävalikko ja alatunniste: Training-linkki kielen mukaan (FI saunakoulutus.fi, EN saunahealer.com), ei ristiin', async () => {
  const { layout } = await import('../src/render.mjs');
  const page = (lang) => layout({ lang, key: 'home', meta: { title: 't', description: 'd' }, body: '<main></main>' });
  const links = (html) => [...html.matchAll(/href="(https:\/\/saunakoulutus\.fi|https:\/\/saunahealer\.com)[^"]*"/g)].map((m) => m[1]);
  const fi = page('fi'), en = page('en');
  assert.ok(links(fi).length >= 2 && links(fi).every((u) => u === 'https://saunakoulutus.fi'), 'FI nav + footer');
  assert.ok(links(en).length >= 2 && links(en).every((u) => u === 'https://saunahealer.com'), 'EN nav + footer');
});
