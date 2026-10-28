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
const home = JSON.parse(readFileSync(new URL('../content/pages/home.json', import.meta.url), 'utf8'));
const partial = JSON.parse(readFileSync(new URL('../content/partials/saunotus-perinne.json', import.meta.url), 'utf8'));
const pending = JSON.parse(readFileSync(new URL('../content/site-texts.pending-import-85.json', import.meta.url), 'utf8'));
const prod = (slug) => kb.products.find((p) => p.slug === slug);

test('perinne-osio säilyttää home.json about -kentän FI+EN sanasta sanaan', () => {
  assert.deepEqual(partial.fi, home.fi.about);
  assert.deepEqual(partial.en, home.en.about);
  assert.equal(partial.fi.title, 'Elämys, joka juontaa juurensa perinteeseen');
  assert.equal(partial.fi.img, 'saunotus-selka');
  assert.equal(partial.en.elements.length, 4);
});

test('pending-import-85 vastaa HOME_TEXTS-varatekstejä, FI+EN, ei HTML:ää', () => {
  for (const [key, v] of Object.entries(HOME_TEXTS)) for (const lang of ['fi', 'en']) {
    const row = pending.find((x) => x.key === key && x.lang === lang);
    assert.ok(row, `${key} ${lang}`);
    assert.equal(row.text, v[lang]);
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.ok(!row.text.includes('<'));
    assert.doesNotMatch(row.text, /johku/i);
  }
  assert.equal(pending.length, Object.keys(HOME_TEXTS).length * 2);
});

test('elämyskortit: nimi, hinta ja kesto tuotteesta; lahjakortti #avoin; kuva vain hallinnan kuvasta', () => {
  clearLiveCatalog();
  for (const lang of ['fi', 'en']) {
    const html = experienceHtml(lang);
    const cards = html.split('<li class="card').slice(1);
    assert.equal(cards.length, HOME_EXPERIENCES.length);
    for (const spec of HOME_EXPERIENCES) {
      const p = prod(spec.slug);
      const name = (lang === 'en' && p.name_en) || p.name;
      assert.ok(html.includes(name), `${lang} ${name}`);
    }
    assert.match(html, lang === 'fi' ? /alk\. 29 € \/ hlö · 2 h/ : /from €29 \/ person · 2 h/);
    assert.match(html, lang === 'fi' ? /alk\. 99 € · 1 h/ : /from €99 · 1 h/);
    assert.match(html, lang === 'fi' ? /alk\. 250 € · 1–7 h vaihtoehdot/ : /from €250 · 1–7 h options/);
    assert.match(html, lang === 'fi' ? /alk\. 29 €/ : /from €29/);
    assert.match(html, /href="\/varaa\/#\/tuote\/yleinensauna"|href="\/en\/book\/#\/tuote\/yleinensauna"/);
    assert.match(html, /products\/10-ifj3bf\.webp/);
    assert.match(html, /<picture><source type="image\/avif" srcset="[^"]*width=600[^"]*600w, [^"]*width=900[^"]*900w"/);
    assert.match(html, /type="image\/webp"/);
    assert.match(html, /format=origin/);
    assert.match(html, /resize=contain/);
    assert.match(html, /sizes="\(min-width: 1100px\) 220px, 280px"/);
    assert.match(html, /width="1600" height="1067" alt="[^"]*" loading="lazy" decoding="async"/);
    assert.equal(cards.filter((c) => c.startsWith(' noimg')).length, 4);
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
  assert.ok(fi.indexOf('id="arvostelut"') < fi.indexOf('id="tapahtumat"'));
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
  const ev = fi.slice(fi.indexOf('id="tapahtumat"'), fi.indexOf('id="saunatietoa"'));
  const n = (ev.match(/<li class="card ev"/g) || []).length;
  assert.ok(n >= 1 && n <= 2, `tapahtumia ${n}`);
  assert.match(ev, /Kaikki tapahtumat/);
  assert.match(fi, /<details><summary>Milloin sauna on rakennettu\?<\/summary>/);
  assert.match(fi, /nav-mob[\s\S]*?<a class="btn gold nav-cta" href="\/varaa\/">Varaa saunaelämys<\/a>/);
  assert.doesNotMatch(fi, /<summary>[^<]*<\/summary>\s*<a class="btn/);
  assert.match(fi, />Koulutukset</);
  assert.match(fi, /href="\/varaa\/#\/tuote\/saunarituaali-ja-savusaunavuoro"/);
  assert.match(fi, /49 €/);
  const choose = fi.slice(fi.indexOf('id="valitse-elamys"'), fi.indexOf('class="week soon"'));
  const tradition = fi.slice(fi.indexOf('class="tradition"'), fi.indexOf('id="arvostelut"'));
  assert.doesNotMatch(choose + tradition, /johku/i);
  setArticlesState({ count: { fi: 0, en: 0 }, source: 'test' });
  assert.doesNotMatch(R.home('fi'), /saunatietoa/);
  assert.doesNotMatch(R.home('en'), /sauna-knowledge/);
});
