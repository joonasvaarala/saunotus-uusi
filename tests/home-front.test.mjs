// Etusivun lyhennys: tuotekortit katalogista, viikko, JSON-LD, valikko, säilytetty perinne-osio, pending-import-85.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

delete process.env.SITE_ENV;
process.env.SITE_URL = 'https://saunotus.fi';

const { experienceHtml, HOME_TEXTS, HOME_EXPERIENCES, cardDuration } = await import('../src/home-front.mjs');
const { setLiveCatalog, clearLiveCatalog } = await import('../src/catalog-live.mjs');
const { setArticlesState } = await import('../src/articles/runtime.mjs');
const R = await import('../src/render.mjs');

const kb = JSON.parse(readFileSync(new URL('../content/kb/kb.json', import.meta.url), 'utf8'));
const cardsDoc = JSON.parse(readFileSync(new URL('../content/cards.json', import.meta.url), 'utf8'));
const home = JSON.parse(readFileSync(new URL('../content/pages/home.json', import.meta.url), 'utf8'));
const partial = JSON.parse(readFileSync(new URL('../content/partials/saunotus-perinne.json', import.meta.url), 'utf8'));
const pending = JSON.parse(readFileSync(new URL('../content/site-texts.pending-import-85.json', import.meta.url), 'utf8'));
const prod = (slug) => kb.products.find((p) => p.slug === slug);

// Sama sääntö kuin freeShopEvents (booking/shop/src/week-live.js): category event, kerta available tai full, ends_at > now.
// Mennyt kerta (Kekri päättyy 2026-10-31T17:00:00Z) ei ole etusivulla. Otsikko on cards.jsonista, kuten renderöinti.
function homeShopEvents(now = Date.now()) {
  if (!Number.isFinite(+now)) return [];
  const upcomingOf = (ev) => (Array.isArray(ev.occurrences) ? ev.occurrences : [])
    .filter((o) => o && (o.status === 'available' || o.status === 'full') && o.starts_at && Date.parse(o.ends_at || o.starts_at) > +now)
    .sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)));
  return (Array.isArray(kb.events_shop) ? kb.events_shop : [])
    .filter((ev) => ev && ev.category === 'event' && typeof ev.slug === 'string' && ev.slug && ev.name)
    .map((ev) => ({ ev, upcoming: upcomingOf(ev) }))
    .filter((x) => x.upcoming.length)
    .map(({ ev, upcoming }) => ({
      slug: ev.slug,
      title: cardsDoc.events?.[ev.slug]?.fi?.title || ev.name,
      full: upcoming.every((o) => o.status === 'full'),
      starts: upcoming[0].starts_at,
    }))
    .sort((a, b) => String(a.starts).localeCompare(String(b.starts)) || a.slug.localeCompare(b.slug));
}

// events_shop tyhjä tulevista → render.mjs upcomingEvents (kb.events + cards.json, ei Täynnä-merkkiä).
function legacyHomeEvents(today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' })) {
  const out = [];
  for (const [id, c] of Object.entries(cardsDoc.events || {})) {
    if (String(id).startsWith('_')) continue;
    const slug = c.kb || id;
    const p = kb.products.find((x) => x.slug === slug);
    if (!p) continue;
    const dates = (kb.events || []).filter((row) => row.product_id === p.id && (row.ends_on || row.starts_on) >= today)
      .sort((a, b) => String(a.starts_on).localeCompare(String(b.starts_on)));
    if (!dates.length) continue;
    out.push({ slug, title: c.fi?.title || p.name, full: false, starts: dates[0].starts_on });
  }
  return out.sort((a, b) => String(a.starts).localeCompare(String(b.starts)) || a.slug.localeCompare(b.slug));
}

function expectedHomeEvents() {
  const shop = homeShopEvents(Date.now());
  if (shop.length) return { kind: 'shop', events: shop };
  return { kind: 'legacy', events: legacyHomeEvents() };
}

test('perinne-osio säilyttää home.json about -kentän FI+EN sanasta sanaan', () => {
  assert.deepEqual(partial.fi, home.fi.about);
  assert.deepEqual(partial.en, home.en.about);
  assert.equal(partial.fi.title, 'Elämys, joka juontaa juurensa perinteeseen');
  assert.equal(partial.fi.img, 'saunotus-selka');
  assert.equal(partial.en.elements.length, 4);
});

test('pending-import-85 vastaa HOME_TEXTS-varatekstejä, FI+EN, ei HTML:ää', () => {
  const extra = JSON.parse(readFileSync(new URL('../content/site-texts.pending-import-87.json', import.meta.url), 'utf8'));
  const bookCta = JSON.parse(readFileSync(new URL('../content/site-texts.pending-import-93.json', import.meta.url), 'utf8'));
  const gift = new Set(['ui.site.home_gift_cta']);
  const book = new Set(['ui.site.home_book_cta']);
  for (const [key, v] of Object.entries(HOME_TEXTS)) for (const lang of ['fi', 'en']) {
    const pool = gift.has(key) ? extra : book.has(key) ? bookCta : pending;
    const row = pool.find((x) => x.key === key && x.lang === lang);
    assert.ok(row, `${key} ${lang}`);
    assert.equal(row.text, v[lang]);
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.ok(!row.text.includes('<'));
    assert.doesNotMatch(row.text, /johku/i);
  }
  assert.equal(pending.length, (Object.keys(HOME_TEXTS).length - gift.size - book.size) * 2);
  assert.equal(bookCta.length, book.size * 2);
});

test('elämyskortit: nimi, hinta ja kesto tuotteesta; lahjakortti #avoin; kuva vain hallinnan kuvasta', () => {
  clearLiveCatalog();
  for (const lang of ['fi', 'en']) {
    const html = experienceHtml(lang);
    const cards = html.split('<li class="card').slice(1);
    assert.equal(cards.length, HOME_EXPERIENCES.length);
    for (const spec of HOME_EXPERIENCES) {
      for (const slug of spec.pair || [spec.slug]) {
        const p = prod(slug);
        const name = (lang === 'en' && p.name_en) || p.name;
        assert.ok(html.includes(name), `${lang} ${name}`);
      }
    }
    assert.match(html, lang === 'fi' ? /alk\. 29 € \/ hlö · 2 h/ : /from €29 \/ person · 2 h/);
    assert.match(html, lang === 'fi' ? /alk\. 99 € · 1 h/ : /from €99 · 1 h/);
    assert.match(html, lang === 'fi' ? /alk\. 210 € · 2 h/ : /from €210 · 2 h/);
    assert.match(html, lang === 'fi' ? /alk\. 250 € · 1–7 h vaihtoehdot/ : /from €250 · 1–7 h options/);
    assert.match(html, lang === 'fi' ? /alk\. 180 € · 2 h/ : /from €180 · 2 h/);
    assert.match(html, lang === 'fi' ? /alk\. 29 €/ : /from €29/);
    assert.match(html, lang === 'fi' ? /<h3>Saunahoito ja saunotus<\/h3>/ : /<h3>Sauna Treatment and Saunotus<\/h3>/);
    assert.equal((html.match(/data-testid="care-pair"/g) || []).length, 1);
    const marks = ['/tuote/yleinensauna', '/tuote/saunahoito-2', '/tuote/saunotus-2', '/tuote/oma-saunavuoro', '/tuote/jalkiloylyt'];
    let at = -1;
    for (const m of marks) {
      const i = html.indexOf(m);
      assert.ok(i > at, `${lang} järjestys ${m}`);
      at = i;
    }
    assert.match(html, /j-jalkiloylyt-800\.webp/);
    assert.match(html, /data-slug="jalkiloylyt"/);
    assert.match(html, /href="\/varaa\/#\/tuote\/yleinensauna"|href="\/en\/book\/#\/tuote\/yleinensauna"/);
    assert.match(html, /products\/10-ifj3bf\.webp/);
    assert.match(html, /<picture><source type="image\/avif" srcset="[^"]*width=600[^"]*600w, [^"]*width=900[^"]*900w"/);
    assert.match(html, /type="image\/webp"/);
    assert.match(html, /format=origin/);
    assert.match(html, /resize=contain/);
    assert.match(html, /sizes="\(min-width: 1100px\) 220px, 280px"/);
    assert.match(html, /width="1600" height="1067" alt="[^"]*" loading="lazy" decoding="async"/);
    assert.equal(cards.filter((c) => c.startsWith(' noimg')).length, 2);
    assert.match(html, /j-avoin-lahjakortti-800\.webp/);
    assert.match(html, lang === 'fi' ? /Osta lahjaksi →/ : /Buy as a gift →/);
    assert.match(html, lang === 'fi' ? /href="\/lahjakortti\/#avoin"/ : /href="\/en\/gift-card\/#avoin"/);
    assert.doesNotMatch(html, /\/tuote\/lahjakortti|johku|target="_blank"/i);
  }
  assert.equal(cardDuration(prod('yleinensauna'), 'fi'), '2 h');
  assert.equal(cardDuration(prod('lahjakortti'), 'fi'), '');
});

test('public_catalog peittää kb-hinnan ja nimen; HTML escapetaan', () => {
  setLiveCatalog([{ slug: 'yleinensauna', name: '<img src=x onerror=alert(1)>', price: 31, price_type: 'per_person', price_text: '31 €', duration_text: '1,5 h', short_description: '<p>Lyhyt <b>hetki</b></p>' }]);
  const html = experienceHtml('fi');
  assert.match(html, /alk\. 31 € \/ hlö · 1,5 h/);
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.match(html, />Lyhyt hetki</);
  assert.doesNotMatch(html, /<img src=x|<b>/);
  clearLiveCatalog();
});

test('etusivu: järjestys, ei varaa-verkosta-listaa, torstai 16:00, kaksi tapahtumaa, haitari, valikon kultanappi', () => {
  clearLiveCatalog();
  setArticlesState({ count: { fi: 1, en: 1 }, source: 'test' });
  const fi = R.home('fi');
  const en = R.home('en');
  assert.doesNotMatch(fi, /id="varaa-verkosta"|class="shopgrps"|class="tiles"|Elämys, joka juontaa juurensa perinteeseen|Hyvät löylyt|Suosittelemme/);
  assert.doesNotMatch(fi, /Saunotus on ohjattu moniaistinen/);
  assert.match(fi, /Valitse elämys/);
  assert.match(en, /Choose an experience/);
  assert.ok(fi.indexOf('id="valitse-elamys"') < fi.indexOf('class="week soon"'));
  assert.ok(fi.indexOf('class="week soon"') < fi.indexOf('class="tradition"'));
  assert.ok(fi.indexOf('class="tradition"') < fi.indexOf('id="arvostelut"'));
  assert.ok(fi.indexOf('id="arvostelut"') < fi.indexOf('class="home-book"'));
  assert.ok(fi.indexOf('class="home-book"') < fi.indexOf('id="tapahtumat"'));
  const between = fi.slice(fi.indexOf('id="arvostelut"'), fi.indexOf('id="tapahtumat"'));
  assert.ok(between.indexOf('class="btn light sm"') < between.indexOf('class="home-book"'));
  assert.match(between, /<p class="home-book"><a class="btn gold" href="\/varaa\/">Varaa saunavuoro →<\/a><\/p>/);
  const betweenEn = en.slice(en.indexOf('id="reviews"'), en.indexOf('id="tapahtumat"'));
  assert.match(betweenEn, /<p class="home-book"><a class="btn gold" href="\/en\/book\/">Book a sauna →<\/a><\/p>/);
  assert.doesNotMatch(R.book('fi'), /class="home-book"/);
  assert.ok(fi.indexOf('id="tapahtumat"') < fi.indexOf('id="saunatietoa"'));
  assert.ok(fi.indexOf('id="saunatietoa"') < fi.indexOf('id="yrityksille"'));
  assert.match(fi, /Näytä koko viikko/);
  assert.match(fi, /Näytä vain tänään ja huomenna/);
  assert.match(en, /Today and tomorrow/);
  const ld = JSON.parse(fi.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
  const thu = ld.openingHoursSpecification.find((x) => x.dayOfWeek === 'Thursday');
  assert.equal(thu.opens, '16:00');
  assert.equal(thu.closes, '19:00');
  assert.ok(!ld.openingHoursSpecification.some((x) => x.dayOfWeek === 'Friday'));
  const eventsSlice = (html) => html.slice(html.indexOf('id="tapahtumat"'), html.indexOf('id="saunatietoa"'));
  // Seinäkello ei saa muuttaa tarkistusta: jäädytetty hetki (sama kuin tests/week-programme.test.mjs) on ennen Kekriä.
  const wall = Date.now;
  Date.now = () => Date.parse('2026-10-28T08:00:00Z');
  let frozenFi;
  try { frozenFi = R.home('fi'); }
  finally { Date.now = wall; }
  const evFix = eventsSlice(frozenFi);
  const nFix = (evFix.match(/<li class="card ev"/g) || []).length;
  assert.equal(nFix, 2, `vapaita tapahtumia ${nFix}`);
  assert.match(evFix, /Naisten jouluinen saunailta/);
  assert.match(evFix, /Saunottajien yhteisöpäivä/);
  // booking_210: täydet tapahtumat näkyvät himmennettyinä Täynnä-merkillä ja jonolinkillä.
  const fullFix = evFix.match(/<li class="card ev is-full"[\s\S]*?<\/li>/g) || [];
  assert.equal(fullFix.length, 2, `täysiä tapahtumia ${fullFix.length}`);
  assert.ok(fullFix.every((c) => /class="pill full">Täynnä</.test(c) && /Liity jonoon/.test(c)));
  assert.match(fullFix.join(''), /Sipoonjoen Kekri/);
  assert.match(fullFix.join(''), /Perinnesaunotusilta/);
  assert.deepEqual(homeShopEvents(Date.parse('2026-10-28T08:00:00Z')).map((x) => [x.slug, x.full]), [
    ['sipoonjoen-kekri', true],
    ['perinnesaunotusilta', true],
    ['naisten-joulusauna', false],
    ['saunottajien-yhteisopaiva-2', false],
  ]);
  assert.deepEqual(homeShopEvents(Date.parse('2026-10-31T17:00:00Z')).map((x) => x.slug), [
    'perinnesaunotusilta', 'naisten-joulusauna', 'saunottajien-yhteisopaiva-2',
  ]);
  // Nykyhetki: etusivu näyttää täsmälleen sen, mitä data ja kello sallivat. Päättynyt kerta ei jää kortiksi.
  const ev = eventsSlice(fi);
  const exp = expectedHomeEvents();
  const open = exp.events.filter((x) => !x.full);
  const fullExpected = exp.events.filter((x) => x.full);
  const n = (ev.match(/<li class="card ev"/g) || []).length;
  const full = ev.match(/<li class="card ev is-full"[\s\S]*?<\/li>/g) || [];
  assert.equal(n, open.length, `vapaita tapahtumia ${n}, odotettiin ${open.map((x) => x.slug).join(', ') || 'ei yhtään'}`);
  assert.equal(full.length, fullExpected.length, `täysiä tapahtumia ${full.length}, odotettiin ${fullExpected.map((x) => x.slug).join(', ') || 'ei yhtään'}`);
  for (const x of open) assert.ok(ev.includes(x.title), x.slug);
  assert.ok(full.every((c) => /class="pill full">Täynnä</.test(c) && /Liity jonoon/.test(c)));
  for (const x of fullExpected) assert.ok(full.join('').includes(x.title), x.slug);
  if (exp.kind === 'shop') {
    for (const raw of kb.events_shop) {
      if (exp.events.some((x) => x.slug === raw.slug)) continue;
      const title = cardsDoc.events?.[raw.slug]?.fi?.title || raw.name;
      assert.ok(!ev.includes(title), `${raw.slug} on mennyt`);
    }
  }
  if (exp.events.length) assert.match(ev, /data-live-events/);
  else assert.match(ev, /Uusia tapahtumia julkaistaan pian/);
  assert.match(ev, /Kaikki tapahtumat/);
  assert.match(ev, /href="\/varaa\/#\/\?k=tapahtuma"/);
  assert.match(fi, /<summary>Voiko vuoroon saapua myöhässä\?<\/summary>/);
  assert.match(fi, /<summary>Voinko perua tai muuttaa varausta\?<\/summary>/);
  assert.match(fi, /<summary>Mitä pitää ottaa mukaan\?<\/summary>/);
  assert.match(fi, /<summary>Mikä on jälkilöyly tai yksityisvuoro\?<\/summary>/);
  assert.doesNotMatch(fi, /Milloin sauna on rakennettu/);
  assert.match(fi, /nav-mob[\s\S]*?<a class="btn gold nav-cta" href="\/varaa\/">Varaa saunaelämys<\/a>/);
  assert.doesNotMatch(fi, /<summary>[^<]*<\/summary>\s*<a class="btn/);
  assert.match(fi, />Koulutukset</);
  assert.match(fi, /href="\/varaa\/#\/tuote\/saunarituaali-ja-savusaunavuoro"/);
  assert.match(fi, /49 €/);
  const choose = fi.slice(fi.indexOf('id="valitse-elamys"'), fi.indexOf('class="week soon"'));
  const tradition = fi.slice(fi.indexOf('class="tradition"'), fi.indexOf('id="arvostelut"'));
  assert.doesNotMatch(choose + tradition, /johku/i);
  assert.match(tradition, /Saunarituaali-ilta/);
  assert.match(tradition, /Saunarituaali on ohjattu, vuodenaikojen mukaan elävä hetki hoitosauna Raunissa/);
  assert.match(tradition, /Katso ajat ja varaa/);
  assert.match(tradition, /class="tradition-photo"/);
  assert.match(tradition, /type="image\/avif" srcset="[^"]*\/img\/rituaali-640\.avif 640w, [^"]*\/img\/rituaali-1024\.avif 1024w, [^"]*\/img\/rituaali-1536\.avif 1536w"/);
  assert.match(tradition, /type="image\/webp" srcset="[^"]*\/img\/rituaali-640\.webp 640w/);
  assert.match(tradition, /src="\/img\/rituaali-1536\.webp"/);
  assert.match(tradition, /sizes="\(min-width:900px\) 640px, 100vw"/);
  assert.match(tradition, /width="1536" height="778" alt="Saunottaja ja vieraita lauteilla saunarituaalissa" loading="lazy" decoding="async"/);
  assert.doesNotMatch(tradition, /class="facts"|class="ico"|Ohjattu rituaali|20 minuuttia/);
  const traditionEn = en.slice(en.indexOf('class="tradition"'), en.indexOf('id="arvostelut"'));
  assert.match(traditionEn, /Sauna ritual evening/);
  assert.match(traditionEn, /The sauna ritual is a guided moment in the Rauni treatment sauna/);
  assert.match(traditionEn, /alt="A sauna healer and guests on the benches during a sauna ritual"/);
  assert.match(traditionEn, /€49/);
  setArticlesState({ count: { fi: 0, en: 0 }, source: 'test' });
  assert.doesNotMatch(R.home('fi'), /saunatietoa/);
  assert.doesNotMatch(R.home('en'), /sauna-knowledge/);
});
