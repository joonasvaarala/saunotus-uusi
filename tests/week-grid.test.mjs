// Viikko-ohjelman uusi komponentti (backlog 82, Joonas t1768u + t1769u): malli (week-grid-logic.js), näkymä (week-grid-view.js),
// rakennusvaiheen varaversio (src/week-grid.mjs) ja tuonti 171. Ei verkkoa, ei kantaa: kaikki data on tässä tiedostossa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, cpSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { buildWeek, careName, CARE_HORIZON_DAYS, weekStartOf, isoWeekNumber, weekRange, clampWeek, eventHint, careEntry, MAX_WEEKS_AHEAD, WINDOW_DAYS, dayInfo, carePrice, nextOffering } from '../booking/shop/src/week-grid-logic.js';
import { weekGridTree, toHtml, h, ownDuration, headingTitle, tabLabel } from '../booking/shop/src/week-grid-view.js';
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

test('viikon apurit: liukuva 7 päivän ikkuna (tänään … tänään+6), väli ja selausrajat', () => {
  assert.equal(WINDOW_DAYS, 7);
  assert.equal(weekStartOf('2026-11-15'), '2026-11-15', 'ikkuna alkaa tänään (su), ei maanantaista');
  assert.equal(weekStartOf('2026-11-18'), '2026-11-18');
  assert.equal(isoWeekNumber('2026-11-16'), 47);
  assert.equal(weekRange('2026-11-15'), '15.–21.11.');
  assert.equal(weekRange('2026-11-16'), '16.–22.11.');
  assert.equal(weekRange('2026-11-27'), '27.11.–3.12.');
  assert.equal(weekRange('2026-11-15', 'en'), '15–21 Nov');
  assert.equal(weekRange('2026-11-27', 'en'), '27 Nov–3 Dec');
  assert.equal(week({ lang: 'en' }).range, '16–22 Nov');
  assert.equal(clampWeek('2026-11-09', TODAY), '2026-11-16', 'ei menneisiin päiviin');
  assert.equal(clampWeek('2026-11-17', TODAY), '2026-11-17', 'ei napsauteta maanantaihin');
  const max = new Date(Date.parse('2026-11-16T12:00:00Z') + 7 * MAX_WEEKS_AHEAD * 864e5).toISOString().slice(0, 10);
  assert.equal(clampWeek('2027-06-07', TODAY), max, 'enintään MAX_WEEKS_AHEAD × 7 pv tänään-alkuisesta');
  assert.equal(clampWeek('2026-11-22', '2026-11-15'), '2026-11-22', 'su-alkuinen: 7 päivän loikka pysyy su-alkuisena');
  const m = week();
  assert.deepEqual(m.nav, { prev: false, next: true, now: false });
  assert.equal(m.todayIdx, 0);
  assert.equal(m.days.length, 7);
  assert.equal(m.end, '2026-11-22');
  assert.equal(week({ start: '2026-11-23' }).nav.now, true);
  assert.equal(week({ start: '2026-11-23' }).nav.prev, true);
  assert.equal(week({ start: '2026-11-23' }).todayIdx, -1);
  assert.equal(week({ start: max }).nav.next, false, 'eteenpäin-nuoli pois rajalla');
});

test('liukuva ikkuna: su-alkuinen ikkuna, wd ja viikonloppu tulevat päivämäärästä (ei sarakkeen indeksistä)', () => {
  const sun = week({ start: '2026-11-15', today: '2026-11-15', now: Date.parse('2026-11-15T06:00:00Z') });
  assert.deepEqual(sun.days.map((d) => d.date), ['2026-11-15', '2026-11-16', '2026-11-17', '2026-11-18', '2026-11-19', '2026-11-20', '2026-11-21']);
  assert.deepEqual(sun.days.map((d) => d.wd), [7, 1, 2, 3, 4, 5, 6], 'su ensin, la viimeisenä');
  assert.deepEqual(sun.days.map((d) => d.we), [true, false, false, false, false, false, true], 'viikonloppuväri su ja la, ei sarakkeet 6–7');
  assert.equal(sun.todayIdx, 0);
  assert.deepEqual(dayInfo('2026-11-14'), { wd: 6, we: true });
  assert.deepEqual(dayInfo('2026-11-18'), { wd: 3, we: false });
  const html = weekGridTree(sun, T, {}).map(toHtml).join('');
  assert.match(html, /class="vk-day we is-today is-on" data-vk-day="0"[^>]*><h3 class="vk-dh"[^>]*><span>Sunnuntai<\/span><b>15\.11\.<\/b>/);
  assert.match(html, /class="vk-day" data-vk-day="1"[^>]*><h3 class="vk-dh"[^>]*><span>Maanantai<\/span>/);
  assert.match(html, /class="vk-day we" data-vk-day="6"[^>]*><h3 class="vk-dh"[^>]*><span>Lauantai<\/span>/);
  assert.match(html, /aria-label="Sunnuntai 15\.11\., tänään: /, 'päivänauhan nimi: tänään');
  assert.match(html, /<span aria-hidden="true">Su<\/span><b aria-hidden="true">15<\/b>/, 'nauhan lyhenne wd:stä');
  const tue = week({ start: '2026-11-17', today: '2026-11-17', now: Date.parse('2026-11-17T06:00:00Z') });
  assert.deepEqual(tue.days.map((d) => d.wd), [2, 3, 4, 5, 6, 7, 1]);
  assert.deepEqual(tue.days.map((d) => d.we), [false, false, false, false, true, true, false]);
  // hoidot: Saunahoito ti 17.11. → 2. sarakkeessa ei ole sidottu viikon järjestykseen
  assert.deepEqual(tue.days[0].care.map((c) => c.name), ['Saunahoito']);
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
  assert.deepEqual(Object.keys(sat.care[0]), ['name', 'href', 'price', 'priceKind'], 'ei kellonaikoja, hinta mukana');
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
  assert.equal((html.match(/<button type="button" class="vk-tab[^>]*data-vk-pick="\d"/g) || []).length, 7, 'mobiilin päivänauha: 7 päivää');
  assert.match(html, /<button type="button" class="vk-tab is-on is-today"[^>]*data-vk-pick="0"/);
  assert.match(html, /data-vk-nav="prev"[^>]*disabled/, 'ei selata menneisiin viikkoihin');
  assert.equal((html.match(/16\.–22\.11\./g) || []).length, 1, 'päivämääräväli vain kerran, nuolten välissä');
  assert.match(html, /<span class="vk-wk" aria-live="polite">16\.–22\.11\.<\/span>/);
  assert.match(html, /Koulutukset<span class="vk-ext" aria-hidden="true"> ↗<\/span>/);
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
    assert.match(html, lang === 'fi' ? /Tulevat päivät saunalla/ : /Upcoming days at the sauna/);
    assert.match(html, lang === 'fi' ? /<p class="kicker">Saunavuorot<\/p>/ : /<p class="kicker">Sauna sessions<\/p>/);
    assert.doesNotMatch(html, /Tällä viikolla|This week|Viikko-ohjelma|Weekly programme|vk-dash/);
    assert.match(html, /Hoidot ja rituaalit|Treatments and rituals/);
    assert.match(html, /vk-none/);
  }
  assert.doesNotMatch(weekGrid('fi'), /saunakoulutus\.fi/, 'saunavuorot-sivulla ei koulutuslinkkiä');
  assert.match(weekGrid('fi', { heading: true, links: { all: '/x/' } }), /saunakoulutus\.fi/);
});

test('tuonnit 171 + 181: kaikki viikko-ohjelman avaimet FI + EN, 181 ohittaa 171:n, sama kuin koodin varateksti, ei HTML:ää', () => {
  const rd = (n) => JSON.parse(readFileSync(new URL(`../content/site-texts.pending-import-${n}.json`, import.meta.url), 'utf8'));
  const r171 = rd(171), r181 = rd(181);
  const keys = Object.keys(WEEK_GRID_TEXTS);
  // 181: vain muuttuneet ja uudet avaimet, kukin FI + EN; kaikki koodin avaimia
  assert.equal(r181.length, 42, '21 avainta × 2 kieltä');
  assert.ok(r181.every((r) => keys.includes(r.key)), '181 sisältää vain koodin avaimia');
  for (const k of new Set(r181.map((r) => r.key))) assert.equal(r181.filter((r) => r.key === k).length, 2, `${k} FI+EN`);
  // myöhempi tuonti voittaa: 181 > 171
  const eff = (k, lang) => (r181.find((x) => x.key === k && x.lang === lang) || r171.find((x) => x.key === k && x.lang === lang));
  for (const k of keys) for (const lang of ['fi', 'en']) {
    const r = eff(k, lang);
    assert.ok(r, `${k} ${lang} puuttuu tuonneista`);
    assert.equal(r.text, WEEK_GRID_TEXTS[k][lang], `${k} ${lang} = varateksti`);
    assert.doesNotMatch(r.text, /<[^>]+>/);
    assert.ok(r.text.length <= r.max_len);
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.deepEqual(r.placeholders, r.text.match(/\{\{var:\w+\}\}/g) || []);
  }
  assert.ok(keys.every((k) => /^ui\.site\.vk_[a-z_]+$/.test(k)));
  // muuttuneet merkkijonot (kohdat 1, 3, 15 ja tapahtumavihje) ovat 181:ssä
  const t181 = (k, lang) => r181.find((x) => x.key === k && x.lang === lang)?.text;
  assert.equal(t181('ui.site.vk_title', 'fi'), 'Tulevat päivät saunalla');
  assert.equal(t181('ui.site.vk_title', 'en'), 'Upcoming days at the sauna');
  assert.equal(t181('ui.site.vk_events_none', 'fi'), 'ei näinä päivinä.');
  assert.equal(t181('ui.site.vk_kicker', 'fi'), 'Saunavuorot');
  assert.equal(t181('ui.site.vk_kicker', 'en'), 'Sauna sessions');
  assert.equal(t181('ui.site.vk_prev', 'fi'), 'Edelliset 7 päivää');
  assert.equal(t181('ui.site.vk_next', 'en'), 'Next 7 days');
  // ei tuplariviä samalle avain+kieli-parille
  assert.equal(new Set(r181.map((r) => `${r.key}|${r.lang}`)).size, r181.length);
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
  assert.match(bothHtml, /vk-n">Saunahoito/);
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

test('jälkilöyly täynnä: sana «Täynnä» näkyy (FI) / «Full» (EN), aika yliviivataan tyylillä', () => {
  const m = week();
  const html = weekGridTree(m, T, {}).map(toHtml).join('');
  assert.match(html, /<div class="vk-card vk-line is-full">[\s\S]*?<span class="vk-s"><b class="vk-fullword">Täynnä<\/b><\/span>/);
  assert.equal((html.match(/class="vk-card vk-line is-full"/g) || []).length, 1, 'vain täysi rivi');
  assert.doesNotMatch(html.match(/class="vk-card vk-line is-quiet"[^]*?<\/a>/)[0], /vk-fullword/);
  const en = weekGridTree(week({ lang: 'en' }), gridTexts('en'), {}).map(toHtml).join('');
  assert.match(en, /<div class="vk-card vk-line is-full">[\s\S]*?<b class="vk-fullword">Full<\/b>/);
  const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  assert.match(css, /\.vk-card\.is-full \.vk-t\{text-decoration:line-through\}/);
});

test('kortit: kaikki kolme palveluriviä käyttävät samaa korttia (nimi → hinta → aika/kesto → tila), ei erillisiä rivityylejä', () => {
  const events = [ev('perinnesaunotusilta', 'Perinnesaunotusilta', [occ('2026-11-20', '17:00', '18:30'), occ('2026-11-20', '19:00', '20:30')])];
  const cr = [careEntry({ id: 10, slug: 'saunahoito-2', name: 'Saunahoito', price: 99, price_type: 'base_plus_extra_person' }, new Map([['2026-11-17', [{}]]]))];
  for (const [m, TT] of [[week({ events, care: cr }), T], [week({ events, care: cr, lang: 'en' }), gridTexts('en')]]) {
    const html = weekGridTree(m, TT, {}).map(toHtml).join('');
    const cards = [...html.matchAll(/<(a|div) class="vk-card (vk-\w+)[^"]*"[^>]*>(.*?)<\/\1>/g)];
    assert.deepEqual([...new Set(cards.map((x) => x[2]))].sort(), ['vk-cl', 'vk-evt', 'vk-line', 'vk-oma', 'vk-pub'], 'yleiset, oma sauna, jälkilöylyt, hoito ja tapahtuma');
    for (const [, , kind, body] of cards) {
      assert.match(body, /^<span class="vk-n">[^<]+<\/span>/, `${kind}: nimi ensin`);
      if (body.includes('vk-p')) assert.match(body, /^<span class="vk-n">[^<]+<\/span><span class="vk-p">/, `${kind}: hinta heti nimen perässä`);
      else assert.match(body, /<b class="vk-fullword">/, `${kind}: hinnaton kortti vain täytenä`);
    }
    assert.doesNotMatch(html, /vk-grp|vk-gn|vk-lt|vk-lp|vk-lf|class="vk-care"|vk-cn|vk-cp|vk-etimes/, 'ei vanhoja erillisiä rivirakenteita');
  }
  const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  assert.match(css, /\.vk-pubc\{--vk-c:var\(--green\)\}\n\.vk-privc\{--vk-c:var\(--gold\)\}\n\.vk-carec\{--vk-c:var\(--accent\)\}/, 'rivin väri sama kuin merkissä');
  assert.match(css, /\n\.vk-card\{[^}]*min-height:60px/, 'mobiilissa kortti vähintään 60 px (kosketusalue ≥ 44 px)');
  assert.doesNotMatch(css, /\.vk-privc:not\(\.empty\)\{|\.vk-privc\{background/, 'ei oman saunan katkoviivalaatikkoa eikä taustasävyä');
});

test('otsikko: aina «Tulevat päivät saunalla» (FI) / «Upcoming days at the sauna» (EN), ei viikkonumeroa', () => {
  const hd = { kicker: 'K', title: T.title };
  assert.equal(T.title, 'Tulevat päivät saunalla');
  assert.equal(headingTitle(week(), T, hd), 'Tulevat päivät saunalla');
  assert.equal(headingTitle(week({ start: '2026-11-30' }), T, hd), 'Tulevat päivät saunalla', 'myöhempi jakso: sama otsikko, ei «Viikko N saunassa»');
  assert.equal(gridTexts('en').title, 'Upcoming days at the sauna');
  assert.equal(headingTitle(week({ start: '2026-11-30', lang: 'en' }), gridTexts('en'), { title: gridTexts('en').title }), 'Upcoming days at the sauna');
  const html = weekGridTree(week({ start: '2026-11-30' }), T, { heading: hd }).map(toHtml).join('');
  assert.match(html, /<h2 class="sec-title">Tulevat päivät saunalla<\/h2>/);
  assert.doesNotMatch(html, /Viikko \d+|Tällä viikolla/);
  assert.equal(WEEK_GRID_TEXTS['ui.site.vk_title_week'], undefined, 'viikkonumero-otsikon avain poistettu');
  assert.equal(gridTexts('en').training, 'Sauna training');
  assert.equal(gridTexts('fi').kicker, 'Saunavuorot');
  assert.equal(gridTexts('en').kicker, 'Sauna sessions');
});

test('EN-väli näkyy navigaatiossa kerran (16–22 Nov, 30 Nov–6 Dec), nuolten nimet 7 päivää', () => {
  const en = gridTexts('en');
  const html = weekGridTree(week({ lang: 'en', start: '2026-11-30' }), en, {}).map(toHtml).join('');
  assert.match(html, /<span class="vk-wk" aria-live="polite">30 Nov–6 Dec<\/span>/);
  assert.doesNotMatch(html, /Week 49|30\.11/);
  assert.match(html, /aria-label="Previous 7 days"/);
  assert.match(html, /aria-label="Next 7 days"/);
  assert.equal(en.now, 'Today');
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
  assert.match(html, /alk\.\s*<b>250\s€<\/b><\/span><span class="vk-d"><span class="vk-dur">1–7\sh<\/span>/);
  assert.match(html, /alk\.\s*<b>250\s€<\/b><\/span><span class="vk-d"><span class="vk-dur">2\sh<\/span>/);
  const en = weekGridTree(week({ rows: rr, lang: 'en' }), gridTexts('en'), {}).map(toHtml).join('');
  assert.match(en, /from\s*<b>€250<\/b><\/span><span class="vk-d"><span class="vk-dur">1–7\sh<\/span>/);
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
  assert.match(fi, /<a class="btn light sm" href="https:\/\/saunakoulutus\.fi" target="_blank" rel="noopener">Koulutukset<span class="vk-ext" aria-hidden="true"> ↗<\/span><span class="sr"> \(avautuu uuteen välilehteen\)<\/span><\/a>/);
  assert.match(en, /<a class="btn light sm" href="https:\/\/saunahealer\.com" target="_blank" rel="noopener">Sauna training<span class="vk-ext" aria-hidden="true"> ↗<\/span><span class="sr"> \(opens in a new tab\)<\/span><\/a>/);
  assert.doesNotMatch(fi + en, /Koulutukset →|Sauna training →/, 'ei pelkkää →, ulkoisen linkin merkki ↗');
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
  for (const sel of ['.vk-n']) {
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
  assert.match(fi, /aria-label="Maanantai 28\.12\.: ei vuoroja"/);
  assert.match(en, /<b>28 Dec<\/b>/);
  assert.match(en, /<b>1 Jan<\/b>/);
  assert.match(en, /aria-label="Monday 28 Dec: nothing available"/);
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

// ---- luonnos B (t1829u): kohdat 5–14 ----
const SUN_START = '2026-11-15';
const sunWeek = (o = {}) => week({ start: SUN_START, today: SUN_START, now: Date.parse('2026-11-15T06:00:00Z'), ...o });
const treeOf = (m, o = {}, tt = T) => weekGridTree(m, tt, o).map(toHtml).join('');

test('kestoalue ja alk.-hinta tulevat datasta (booking_318–320 mock): la/su 1–9 h, arki 2–7 h, pe 2–7 h', async () => {
  globalThis.location = { search: '?priv=1' };
  const tmpMock = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'vk-mock-'));
  cpSync(new URL('../booking/shop/src', import.meta.url).pathname, tmpMock, { recursive: true });
  cpSync(new URL('../booking/shared/sb.js', import.meta.url).pathname, join(tmpMock, 'sb.js'));
  const { createShopMock } = await import(pathToFileURL(join(tmpMock, 'shop-mock.js')).href);
  const mock = createShopMock({ storage: null, now: () => Date.parse('2026-11-15T06:00:00Z') });
  const mrows = await mock.rpc('public_availability', { p_product_id: 25, p_from: '2026-11-15', p_to: '2026-11-22' });
  delete globalThis.location;
  const cat = [{ id: 25, slug: 'oma-saunavuoro', category: 'private_sauna' }];
  const m = sunWeek({ rows: mrows, catalog: cat, care: [], offers: [], hrefs });
  const own = (d) => day(m, d).own;
  // la/su aloitus vain 13 tai 14 (booking_318)
  const starts = new Set(mrows.filter((r) => ['2026-11-21', '2026-11-15'].includes(r.session_date)).map((r) => new Date(r.starts_at).toLocaleTimeString('fi-FI', { timeZone: 'Europe/Helsinki', hour: '2-digit', minute: '2-digit' })));
  assert.deepEqual([...starts].sort(), ['13.00', '14.00'], 'la/su vain 13.00 ja 14.00');
  // arkikombot (booking_319): 14.00 → 2/5/7 h, 16.00 → 3/5 h
  const wk = mrows.filter((r) => r.session_date === '2026-11-17').map((r) => [new Date(r.starts_at).toLocaleTimeString('fi-FI', { timeZone: 'Europe/Helsinki', hour: '2-digit', minute: '2-digit' }), (Date.parse(r.ends_at) - Date.parse(r.starts_at)) / 36e5]);
  assert.deepEqual(wk.sort().map((x) => x.join('/')), ['14.00/2', '14.00/5', '14.00/7', '16.00/3', '16.00/5']);
  assert.deepEqual([own('2026-11-21').durMin, own('2026-11-21').durMax], [60, 540], 'la 1–9 h');
  assert.deepEqual([own('2026-11-15').durMin, own('2026-11-15').durMax], [60, 540], 'su 1–9 h (vain vapaista: 13.00 1–3 h täynnä, 14.00 1 h vapaa)');
  assert.deepEqual([own('2026-11-17').durMin, own('2026-11-17').durMax], [120, 420], 'ti 2–7 h');
  assert.deepEqual([own('2026-11-20').durMin, own('2026-11-20').durMax], [120, 420], 'pe 2–7 h');
  assert.equal(ownDuration(own('2026-11-21'), T), '1–9 h');
  assert.equal(ownDuration(own('2026-11-17'), T), '2–7 h');
  assert.equal(own('2026-11-21').price.replace(/\s/g, ' '), '350 €', 'la alk. 350 €');
  assert.equal(own('2026-11-15').price.replace(/\s/g, ' '), '300 €', 'su alk. 300 €');
  assert.equal(own('2026-11-17').price.replace(/\s/g, ' '), '250 €', 'ma–to alk. 250 €');
  assert.equal(own('2026-11-20').price.replace(/\s/g, ' '), '300 €', 'pe alk. 300 €');
  // vain vapaat lasketaan: kun la 13.00 1 h ja 14.00 1 h täynnä ja vain 9 h vapaa, haarukka on yksi pituus
  const only9 = mrows.filter((r) => r.session_date === '2026-11-21').map((r) => ((Date.parse(r.ends_at) - Date.parse(r.starts_at)) / 36e5 === 9 ? r : { ...r, status: 'full' }));
  const m9 = sunWeek({ rows: only9, catalog: cat, care: [], offers: [], hrefs });
  assert.equal(ownDuration(day(m9, '2026-11-21').own, T), '9 h');
  assert.match(day(m9, '2026-11-21').own.price, /^2[\s ]?300\s€$/, 'hinta samasta vapaasta rivistä (9 h = 2300 €)');
});

const nbn = (o) => ({ ...o, text: o.text.replace(/\s/g, ' ') });
test('hoidon hinta katalogista: alk. jos vaihtelua, / hlö jos per_person, kiinteä sellaisenaan', () => {
  assert.deepEqual(nbn(carePrice({ price: 99, price_type: 'base_plus_extra_person', included_persons: 1, extra_person_price: 40 })), { text: '99 €', kind: 'from' });
  assert.deepEqual(nbn(carePrice({ price: 99, price_type: 'fixed' })), { text: '99 €', kind: 'fixed' });
  assert.deepEqual(nbn(carePrice({ price: 99, price_type: 'fixed', included_persons: 1, extra_person_price: 30 })), { text: '99 €', kind: 'from' }, 'lisähenkilöhinta = vaihtelua');
  assert.deepEqual(nbn(carePrice({ price: 49, price_type: 'per_person' })), { text: '49 €', kind: 'per' });
  assert.deepEqual(nbn(carePrice({ price: 59.5, price_type: 'per_person' }, 'en')), { text: '€59.50', kind: 'per' });
  assert.deepEqual(nbn(carePrice({ price: null })), { text: '', kind: '' });
  assert.deepEqual(nbn(carePrice({ price: 0 })), { text: '', kind: '' });
  // malli + näkymä
  const cr = [careEntry({ id: 10, slug: 'saunahoito-2', name: 'Saunahoito', price: 99, price_type: 'base_plus_extra_person' }, new Map([['2026-11-17', [{}]]])),
    careEntry({ id: 7, slug: 'saunarituaali-ja-savusaunavuoro', name: 'Saunarituaali ja savusaunavuoro (la & su)', price: 49, price_type: 'per_person' }, new Map([['2026-11-17', [{}]]]))];
  const m = week({ care: cr });
  assert.deepEqual(day(m, '2026-11-17').care.map((c) => [c.name, c.price.replace(/\s/g, ' '), c.priceKind]), [['Saunahoito', '99 €', 'from'], ['Saunarituaali ja savusaunavuoro', '49 €', 'per']]);
  const html = treeOf(m);
  assert.match(html, /<span class="vk-n">Saunahoito<\/span><span class="vk-p">alk\. <b>99\s€<\/b><\/span>/);
  assert.match(html, /<span class="vk-p"><b>49\s€<\/b> \/ hlö<\/span>/);
  const en = treeOf(week({ care: cr, lang: 'en' }), {}, gridTexts('en'));
  assert.match(en, /<span class="vk-p">from <b>€99<\/b><\/span>/);
  assert.match(en, /<span class="vk-p"><b>€49<\/b> \/ person<\/span>/);
});

test('nextOffering: seuraava päivä, jolla on kyseistä tarjontaa; ikkunassa ei seuraavaa → null; täydet eivät ole tarjontaa', () => {
  const m = sunWeek();
  // hoidot: ti 17.11. (Saunahoito), la 21.11. (rituaalipaketti); su 15.11. → ti
  assert.deepEqual(nextOffering(m.days, 0, 'care'), { index: 2, date: '2026-11-17', wd: 2 });
  assert.deepEqual(nextOffering(m.days, 2, 'care'), { index: 6, date: '2026-11-21', wd: 6 });
  assert.equal(nextOffering(m.days, 6, 'care'), null, 'ikkunan viimeisen päivän jälkeen ei mitään');
  // yleiset: ma 16.11. ensimmäinen; to 19. → la 21.
  assert.equal(nextOffering(m.days, 0, 'pub').date, '2026-11-16');
  assert.equal(nextOffering(m.days, 4, 'pub').date, '2026-11-21');
  // oma sauna: täynnä-päivä (22.11.) ei ole tarjontaa
  const wk = week();
  assert.equal(nextOffering(wk.days, 5, 'own'), null, 'la 21. on viimeinen oma sauna ikkunassa 16.–22.11., su on täynnä');
  assert.equal(nextOffering(wk.days, 0, 'own').date, '2026-11-21', 'ma 16. jälkeen seuraava oma sauna la 21. (väliviikolla ei ole)');
  assert.equal(nextOffering([{ date: null, public: [], own: null, after: [], care: [], events: [] }, { date: null, public: [], own: null, after: [], care: [], events: [] }], 0, 'care'), null, 'staattinen malli ilman päivämääriä');
});

test('tyhjä rivi: tekstit joka rivillä, hoitorivillä linkki seuraavaan päivään (FI + EN); ei linkkiä, jos ikkunassa ei seuraavaa; ei viivaa hoitosolussa', () => {
  const m = sunWeek({ care: care });
  const html = treeOf(m);
  const sunCare = html.match(/<li class="vk-day we is-today is-on"[\s\S]*?<\/li>/)[0];
  assert.match(sunCare, /<span class="vk-none-d">Ei tänä päivänä<\/span><span class="vk-none-m">Ei hoitoja tänä päivänä<button type="button" class="vk-jump" data-vk-pick="2">Seuraava ti 17\.11\.<span aria-hidden="true"> →<\/span><\/button><\/span>/);
  assert.match(sunCare, /Ei yleisiä vuoroja|vk-pub/, 'yleiset-rivi on aina mukana');
  assert.equal((sunCare.match(/class="vk-cell /g) || []).length, 3, 'kolme riviä: yleiset, oma sauna, hoidot');
  assert.ok(sunCare.indexOf('vk-pubc') < sunCare.indexOf('vk-privc') && sunCare.indexOf('vk-privc') < sunCare.indexOf('vk-carec'), 'järjestys yleiset → oma → hoidot');
  assert.doesNotMatch(html.slice(html.indexOf('vk-carec')), /vk-dash/, 'hoitosolussa ei viivaa');
  assert.doesNotMatch(html, /<span class="vk-dash" aria-hidden="true">–<\/span><\/div><\/li>/);
  // ikkunan viimeinen hoitopäivä: ei seuraavaa → pelkkä teksti
  const lastCare = html.match(/<li class="vk-day we" data-vk-day="6"[\s\S]*?<\/li>/)[0];
  const sat = week({ start: '2026-11-22', today: '2026-11-22', now: Date.parse('2026-11-22T06:00:00Z'), care: [] });
  const satHtml = treeOf(sat);
  assert.match(satHtml, /Ei hoitoja tänä päivänä<\/span>/);
  assert.doesNotMatch(satHtml.slice(satHtml.indexOf('vk-carec')), /vk-jump/, 'ei harhaanjohtavaa linkkiä, kun ikkunassa ei ole hoitoja');
  assert.ok(lastCare.length > 0);
  // EN
  const en = treeOf(sunWeek({ care, lang: 'en' }), {}, gridTexts('en'));
  assert.match(en, /No treatments this day<button type="button" class="vk-jump" data-vk-pick="2">Next: Tue 17 Nov<span aria-hidden="true"> →<\/span><\/button>/);
  assert.match(en, /Not this day/);
  // oma sauna -rivi tyhjänä: ma–su ilman omaa saunaa → teksti + linkki
  const noOwn = treeOf(sunWeek({ rows: rows.filter((r) => r.slug !== 'oma-saunavuoro' && r.slug !== 'jalkiloylyt') }));
  assert.match(noOwn, /Ei oman saunan vuoroja/);
  // hoitoikkunan ulkopuolella: selite, ei «ei hoitoja»
  const later = treeOf(week({ start: '2026-12-14', care: [], careHorizon: 14 }));
  assert.match(later.slice(later.indexOf('vk-carec')), /Hoitojen ajat avautuvat lähempänä ajankohtaa\./);
});

test('täysi aika: ei linkkiä, «Täynnä» näkyy tekstinä (yleiset, oma sauna, jälkilöylyt, sirut)', () => {
  const full = [
    row('yleinensauna', 'public_sauna', 1, '2026-11-16', '16:00', '19:00', { unit_price: 29, status: 'full', remaining: 0 }),
    row('yleinensauna', 'public_sauna', 1, '2026-11-17', '16:00', '18:00', { unit_price: 29, status: 'full', remaining: 0 }),
    row('yleinensauna', 'public_sauna', 1, '2026-11-17', '17:00', '19:00', { unit_price: 29, status: 'available', remaining: 8 }),
    row('yleinensauna', 'public_sauna', 1, '2026-11-17', '18:00', '20:00', { unit_price: 29, status: 'available', remaining: 2 }),
    row('oma-saunavuoro', 'private_sauna', 25, '2026-11-16', '13:00', '15:00', { base_price: 300, status: 'full' }),
    row('jalkiloylyt', 'private_sauna', 26, '2026-11-16', '19:00', '22:00', { base_price: 250, status: 'full', rule_id: 40 }),
  ];
  const m = week({ rows: full, offers: [] });
  const html = treeOf(m);
  const mon = html.match(/<li class="vk-day is-today is-on"[\s\S]*?<\/li>/)[0];
  assert.doesNotMatch(mon, /<a /, 'ma: kaikki täynnä → ei yhtään linkkiä');
  assert.doesNotMatch(mon, /href=/);
  assert.match(mon, /<div class="vk-card vk-pub is-full">[\s\S]*Täynnä/);
  assert.match(mon, /<div class="vk-card vk-oma is-full">[\s\S]*<b class="vk-fullword">Täynnä<\/b>/);
  assert.match(mon, /<div class="vk-card vk-line is-full">[\s\S]*<b class="vk-fullword">Täynnä<\/b>/);
  assert.doesNotMatch(mon, /vk-book/, 'täydessä omassa saunassa ei Varaa-painiketta');
  // ti: täysi siru ei ole linkki, vapaa on; vähän jäljellä -siru näyttää tekstin
  const tue = html.match(/<li class="vk-day" data-vk-day="1"[\s\S]*?<\/li>/)[0];
  assert.doesNotMatch(tue, /<a class="vk-chip is-full/);
  assert.match(tue, /<span class="vk-chip is-full">[^<]*<span class="sr">, Täynnä<\/span><\/span>/);
  assert.match(tue, /<a class="vk-chip is-low" href="[^"]+"[^>]* aria-label="[^"]*, 2 paikkaa jäljellä[^"]*">[^<]*<span class="vk-left">2 jäljellä<\/span><\/a>/);
  assert.match(tue, /<a class="vk-chip" href=/);
  const en = treeOf(week({ rows: full, offers: [], lang: 'en' }), {}, gridTexts('en'));
  assert.match(en, /<span class="sr">, Full<\/span>/);
  assert.match(en, /<span class="vk-left">2 left<\/span>/);
  // selite ruudukon alla (FI + EN)
  assert.match(html, /<ul class="vk-legend"><li><i class="vk-sw is-free" aria-hidden="true"><\/i>Vapaa<\/li><li><i class="vk-sw is-low" aria-hidden="true"><\/i>Vähän jäljellä<\/li><li><i class="vk-sw is-full" aria-hidden="true"><\/i>Täynnä<\/li><\/ul>/);
  assert.match(en, /Available<\/li><li><i class="vk-sw is-low" aria-hidden="true"><\/i>Few left<\/li><li><i class="vk-sw is-full" aria-hidden="true"><\/i>Full<\/li>/);
  // täysi tapahtuma pysyy linkkinä (jonotus), tämä on tietoinen poikkeus
  const evFull = treeOf(week({ events: [ev('x', 'Täysi', [occ('2026-11-20', '17:00', '18:30', 'full')])] }));
  assert.match(evFull, /<a class="vk-card vk-evt is-full"/);
});

test('mobiili: nauhan selite, tänään erillään valinnasta, ruudunlukijanimi palveluista, oma sauna ilman Varaa-painiketta, edellinen/seuraava päivä', () => {
  const m = sunWeek({ care });
  const html = treeOf(m, { selected: 2 });
  assert.match(html, /<p class="vk-key"><span><i class="pub" aria-hidden="true"><\/i>Yleiset vuorot<\/span><span><i class="priv" aria-hidden="true"><\/i>Oma sauna<\/span><span><i class="treat" aria-hidden="true"><\/i>Hoidot ja rituaalit<\/span><\/p>/);
  const en = treeOf(sunWeek({ care, lang: 'en' }), {}, gridTexts('en'));
  assert.match(en, /<p class="vk-key">[\s\S]*Public sessions[\s\S]*Private sauna[\s\S]*Treatments and rituals<\/span><\/p>/);
  // tänään (su, idx 0) ei ole valittu, mutta merkitty; valittu on ti
  assert.match(html, /<button type="button" class="vk-tab is-today"[^>]*data-vk-pick="0"[^>]*aria-current="date"/);
  assert.match(html, /<button type="button" class="vk-tab is-on"[^>]*data-vk-pick="2"/);
  assert.doesNotMatch(html, /class="vk-tab is-on is-today"/);
  const todayOn = treeOf(m, { selected: 0 });
  assert.match(todayOn, /class="vk-tab is-on is-today"/, 'tänään ja valittu: molemmat luokat');
  // ruudunlukijanimi: päivä + palvelut
  assert.match(html, /aria-label="Lauantai 21\.11\.: Yleiset vuorot, Oma sauna, Hoidot ja rituaalit"/);
  assert.match(html, /aria-label="Tiistai 17\.11\.: Hoidot ja rituaalit"/);
  assert.equal(tabLabel(m.days[0], 0, T, m), 'Sunnuntai 15.11., tänään: Oma sauna');
  assert.match(html, /aria-label="Torstai 19\.11\.: Yleiset vuorot"/);
  assert.match(html, /aria-label="Perjantai 20\.11\.: ei vuoroja"/);
  // oma sauna: kortti on linkki kuten muut rivit, ei erillistä Varaa-painiketta (Joonas t1845u)
  assert.match(html, /<a class="vk-card vk-oma" href="[^"]+"[^>]*>[\s\S]*?<span class="vk-n">Oma saunavuoro<\/span>[\s\S]*?<\/a>/);
  assert.doesNotMatch(html, /vk-book/);
  assert.doesNotMatch(en, /vk-book/);
  // edellinen/seuraava päivä: reunoilla pois käytöstä
  assert.match(treeOf(m, { selected: 0 }), /class="vk-step vk-step-prev" data-vk-step="-1" disabled>[\s\S]*Edellinen päivä<\/button><button type="button" class="vk-step vk-step-next" data-vk-step="1">Seuraava päivä/);
  assert.match(treeOf(m, { selected: 6 }), /data-vk-step="1" disabled>Seuraava päivä/);
  assert.doesNotMatch(html, /data-vk-step="-1" disabled|data-vk-step="1" disabled/, 'keskellä molemmat käytössä');
  assert.match(en, /Previous day[\s\S]*Next day/);
});

test('selaus: «Taaksepäin» disabled + selkeä aria tänään-alkuisella jaksolla; eteenpäin rajalla pois', () => {
  const m = sunWeek();
  const html = treeOf(m);
  assert.match(html, /data-vk-nav="prev" aria-label="Edellisiä päiviä ei ole: jakso alkaa tänään" disabled/);
  assert.match(html, /data-vk-nav="next" aria-label="Seuraavat 7 päivää"/);
  const later = treeOf(week({ start: '2026-11-23' }));
  assert.match(later, /data-vk-nav="prev" aria-label="Edelliset 7 päivää"(?! disabled)/);
  assert.match(later, /class="vk-now" data-vk-nav="now">Tänään<\/button>/);
  const max = new Date(Date.parse('2026-11-16T12:00:00Z') + 7 * MAX_WEEKS_AHEAD * 864e5).toISOString().slice(0, 10);
  assert.match(treeOf(week({ start: max })), /data-vk-nav="next" aria-label="Pidemmälle ei voi selata" disabled/);
});

test('tapahtumavihje: «ei näinä päivinä» FI, «none on these days» EN', () => {
  const evs = [ev('a', 'Kekri', [occ('2026-12-04', '17:00', '18:30')])];
  assert.match(treeOf(week({ events: evs })), /Tapahtumat:<\/b> ei näinä päivinä\. Seuraavaksi/);
  assert.match(treeOf(week({ events: evs, lang: 'en' }), {}, gridTexts('en')), /Events:<\/b> none on these days\. Next up:/);
});
