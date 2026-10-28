// booking_158: etusivun tapahtumakortit (src/event-cards.mjs + render.mjs eventsHtml). Uusi data (kb.json events_shop = public_events)
// vs. vanha (kb.event_dates + cards.json), menneet ja täydet/suljetut pois, linkki aina kaupan tuotesivulle FI/EN, XSS.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

const repo = join(dirname(fileURLToPath(import.meta.url)), '../..');
delete process.env.SITE_URL; delete process.env.SITE_ENV;
const C = await import(pathToFileURL(join(repo, 'src/event-cards.mjs')).href);
const lib = await import(pathToFileURL(join(repo, 'src/lib.mjs')).href);
const R = await import(pathToFileURL(join(repo, 'src/render.mjs')).href);
const XSS = '<img src=x onerror="alert(1)">';
const NOW = Date.parse('2026-10-24T12:00:00Z');
const ev = (over = {}, occ = []) => ({ product_id: 31, slug: 'perinnesaunotusilta', name: 'Perinnesaunotusilta', name_en: 'Traditional sauna evening', category: 'event', price: 69, sale_open: true, occurrences: occ, ...over });
const o = (starts_at, ends_at, status = 'available') => ({ rule_id: 1, starts_at, ends_at, status });

test('selectShopEvents: vain vapaat tulevat kerrat; full, closed ja menneet pois; tyhjä/virheellinen → []', () => {
  const list = [
    ev({}, [o('2026-11-14T14:00:00Z', '2026-11-14T17:00:00Z'), o('2026-10-01T14:00:00Z', '2026-10-01T17:00:00Z'), o('2026-11-21T14:00:00Z', '2026-11-21T17:00:00Z', 'closed')]),
    ev({ product_id: 32, slug: 'naisten-joulusauna', name: 'Naisten joulusauna' }, [o('2026-11-07T14:00:00Z', '2026-11-07T17:00:00Z', 'full')]),
    ev({ product_id: 33, slug: 'saunottajakoulutus', name: 'Koulutus', category: 'training' }, [o('2026-11-28T07:00:00Z', '2026-11-29T14:00:00Z')]),
    ev({ product_id: 34, slug: 'vanha', name: 'Mennyt' }, [o('2026-09-01T14:00:00Z', '2026-09-01T17:00:00Z')]),
    ev({ product_id: 35, slug: 'kiinni', name: 'Kiinni', sale_open: false }, [o('2026-12-01T14:00:00Z', '2026-12-01T17:00:00Z', 'closed')]),
  ];
  const sel = C.selectShopEvents(list, NOW);
  assert.deepEqual(sel.map((x) => x.slug), ['perinnesaunotusilta']);
  assert.equal(sel[0].occurrences.length, 1, 'vain available-kerta');
  assert.equal(C.linkTarget, undefined, 'Johku-linkkivaihtoehto poistettu');
  for (const bad of [undefined, null, {}, 'x', []]) assert.deepEqual(C.selectShopEvents(bad, NOW), []);
  assert.equal(C.selectShopEvents([ev({ sale_open: false }, [o('2026-11-14T14:00:00Z', '2026-11-14T17:00:00Z', 'closed')])], NOW).length, 0);
  assert.equal(C.selectShopEvents([ev({ sale_open: true }, [o('2026-11-14T14:00:00Z', '2026-11-14T17:00:00Z', 'full')])], NOW).length, 0);
});

test('päivät ja kellonajat: yksipäiväinen ja monipäiväinen FI/EN', () => {
  const one = o('2026-11-14T14:00:00Z', '2026-11-14T17:00:00Z'), two = o('2026-11-28T07:00:00Z', '2026-11-29T14:00:00Z');
  assert.equal(C.occDates(one, 'fi'), '14.11.');
  assert.equal(C.occDates(two, 'fi'), '28.11.–29.11.');
  assert.equal(C.occDates(two, 'en'), '28 Nov–29 Nov');
  assert.equal(C.occTime(one, 'fi'), 'klo 16.00–19.00');
  assert.equal(C.occTime(one, 'en'), '16:00–19:00');
  assert.equal(C.occTime(two, 'fi'), '');
});

const soon = (d, h = 3, status = 'available') => o(new Date(Date.now() + d * 864e5).toISOString(), new Date(Date.now() + d * 864e5 + h * 36e5).toISOString(), status);

test('linkki: aina kaupan tuotesivu FI /varaa/#/tuote/<slug>, EN /en/book/#/tuote/<slug>, samaan välilehteen; myös myynnin ollessa pois', () => {
  assert.equal(lib.pageHref('book', 'fi', C.shopHash('perinnesaunotusilta')), '/varaa/#/tuote/perinnesaunotusilta');
  assert.equal(lib.pageHref('book', 'en', C.shopHash('perinnesaunotusilta')), '/en/book/#/tuote/perinnesaunotusilta');
  assert.equal(C.shopHash('a b/"x'), '/tuote/a%20b%2F%22x');
  const saved = lib.kb.events_shop;
  try {
    process.env.EVENT_LINK_TARGET = 'johku';   // vanha lippu ei enää vaikuta
    lib.kb.events_shop = [ev({ sale_open: true }, [soon(5, 3, 'available')])];
    const fi = R.eventsHtml('fi', 'tyhjä'), en = R.eventsHtml('en', 'empty');
    assert.match(fi, /href="\/varaa\/#\/tuote\/perinnesaunotusilta"/);
    assert.match(en, /href="\/en\/book\/#\/tuote\/perinnesaunotusilta"/);
    assert.doesNotMatch(fi + en, /johku\.com|target="_blank"/, 'ei Johkua, oma kauppa samaan välilehteen');
    assert.match(fi, /Perinnesaunotusilta/);
    assert.match(en, /Traditional sauna evening|Perinnesaunotusilta/);
  } finally { lib.kb.events_shop = saved; delete process.env.EVENT_LINK_TARGET; }
});

test('vanha data (events_shop puuttuu tai tyhjä): kortit kb.event_dates + cards.json, linkki silti kaupan tuotesivulle', () => {
  const saved = lib.kb.events_shop;
  try {
    delete lib.kb.events_shop;
    const legacy = R.eventsHtml('fi', 'tyhjä'), legacyEn = R.eventsHtml('en', 'empty');
    lib.kb.events_shop = [];
    assert.equal(R.eventsHtml('fi', 'tyhjä'), legacy);
    assert.doesNotMatch(legacy + legacyEn, /johku\.com|target="_blank"/, 'vanha data ei linkitä Johkuun');
    const ups = R.upcomingEvents('fi');
    for (const { p } of ups) {
      assert.ok(legacy.includes(`href="${lib.e(lib.pageHref('book', 'fi', C.shopHash(p.slug)))}"`), `FI ${p.slug}`);
      assert.ok(legacyEn.includes(`href="${lib.e(lib.pageHref('book', 'en', C.shopHash(p.slug)))}"`), `EN ${p.slug}`);
    }
  } finally { if (saved === undefined) delete lib.kb.events_shop; else lib.kb.events_shop = saved; }
});

test('XSS: tietokannan nimet, kuvaukset ja slug escapattuina; kuvaus pelkkänä tekstinä', () => {
  const html = C.shopEventsHtml([{ ...ev({ slug: 'x"><script>', name: XSS, description_short: `<p>Hei ${XSS}</p>` }), occurrences: [o('2026-11-14T14:00:00Z', '2026-11-14T17:00:00Z')] }], 'fi', {
    e: lib.e, money: lib.money, link: (x) => lib.pageHref('book', 'fi', C.shopHash(x.slug)), img: () => '',
  });
  assert.doesNotMatch(html, /<img|<script|onerror="/);
  assert.match(html, /&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/);
  assert.match(html, /href="\/varaa\/#\/tuote\/x%22%3E%3Cscript%3E"/);
  assert.equal(C.plainText('<p>A&nbsp;<b>B</b></p>'), 'A B');
});

test('kb-vienti ja snapshot: events_shop public_eventsistä, vain julkiset kentät, puuttuessa pois', () => {
  const sql = readFileSync(join(repo, 'docs/kb-export.sql'), 'utf8');
  assert.match(sql, /'events_shop', booking\.public_events\(current_date, 'shop'\)/);
  const snap = readFileSync(join(repo, 'scripts/kb-snapshot.mjs'), 'utf8');
  assert.match(snap, /if \(Array\.isArray\(raw\.events_shop\)\)/);
  assert.doesNotMatch(snap.slice(snap.indexOf('events_shop')), /'remaining'|'email'|'phone'/);
});
