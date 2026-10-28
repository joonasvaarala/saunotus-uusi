// Hoidot ja rituaalit: tuotekortit katalogista, FI+EN, pending-import-95, JSON-LD.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

delete process.env.SITE_ENV;
process.env.SITE_URL = 'https://saunotus.fi';

const { TREATMENTS_TEXTS, TREATMENT_GROUPS, treatmentCardPrice, treatmentCardWhen, treatmentOffers, treatmentFaq } = await import('../src/treatments-page.mjs');
const { setLiveCatalog, clearLiveCatalog } = await import('../src/catalog-live.mjs');
const R = await import('../src/render.mjs');
const S = await import('../src/seo-enhance.mjs');
const { classFor } = await import('../booking/shop/src/text-registry.js');

const kb = JSON.parse(readFileSync(new URL('../content/kb/kb.json', import.meta.url), 'utf8'));
const pending = JSON.parse(readFileSync(new URL('../content/site-texts.pending-import-95.json', import.meta.url), 'utf8'));
const prod = (slug) => kb.products.find((p) => p.slug === slug);
const cardOf = (html, slug) => html.split('<li class="bk-card">').slice(1).find((c) => c.includes(`/tuote/${slug}`));

test('pending-import-95 vastaa varatekstejä, FI+EN, ei HTML:ää, ei päällekkäisiä avaimia', () => {
  const keys = Object.keys(TREATMENTS_TEXTS);
  assert.equal(pending.length, keys.length * 2);
  for (const key of keys) for (const lang of ['fi', 'en']) {
    const row = pending.find((x) => x.key === key && x.lang === lang);
    assert.ok(row, `${key} ${lang}`);
    assert.equal(row.text, TREATMENTS_TEXTS[key][lang]);
    assert.equal(row.class, classFor(key, TREATMENTS_TEXTS[key].fi));
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.ok(row.text.length <= row.max_len);
    assert.ok(!row.text.includes('<'));
    assert.equal(row.text, row.text.trim());
  }
  assert.equal(classFor('ui.site.treatments_fit_new', TREATMENTS_TEXTS['ui.site.treatments_fit_new'].fi), 'protected');
  const mine = new Set(pending.map((r) => `${r.key}|${r.lang}`));
  for (const f of readdirSync(new URL('../content/', import.meta.url)).filter((n) => /^site-texts\.(pending-import|imported).*\.json$/.test(n) && n !== 'site-texts.pending-import-95.json')) {
    const rows = JSON.parse(readFileSync(new URL(`../content/${f}`, import.meta.url), 'utf8'));
    if (!Array.isArray(rows)) continue;
    for (const r of rows) assert.ok(!mine.has(`${r.key}|${r.lang}`), `${f} ${r.key}`);
  }
});

test('kortit: hinta, kesto ja slug tuotteesta; savusaunamerkki vain lipulla; Morsiussauna kysyy ajan', () => {
  clearLiveCatalog();
  const expectPrice = {
    'saunahoito-2': ['99 € (sis. 1 hlö, lisähenkilö +35 €)', '€99 (incl. 1 guest, extra guest +€35)'],
    'saunotus-2': ['210 € (sis. 1 hlö, lisähenkilö +60 €)', '€210 (incl. 1 guest, extra guest +€60)'],
    'syvasaunotus': ['290 € (sis. 1 hlö, lisähenkilö +70 €)', '€290 (incl. 1 guest, extra guest +€70)'],
    'perinnesaunotus-ryhmalle': ['499 €', '€499'],
    'saunarituaali-ja-savusaunavuoro': ['49 € / hlö', '€49 / person'],
    'turvetorstai': ['35 € / hlö', '€35 / person'],
    'perinnesaunotusilta': ['59 € / hlö', '€59 / person'],
    'morsiussauna': ['alk. 390 €', 'from €390'],
    'turvesauna': ['alk. 330 €', 'from €330'],
    'synttarisauna': ['alk. 350 €', 'from €350'],
  };
  for (const lang of ['fi', 'en']) {
    const html = R.treatments(lang);
    const i = lang === 'fi' ? 0 : 1;
    for (const g of TREATMENT_GROUPS) for (const slug of g.slugs) {
      const p = prod(slug);
      const card = cardOf(html, slug);
      assert.ok(card, `${lang} ${slug}`);
      const name = (lang === 'en' && p.name_en) || p.name;
      assert.ok(card.includes(`<h3>${name.replace(/&/g, '&amp;')}</h3>`), name);
      assert.ok(card.includes(`<strong>${expectPrice[slug][i]}</strong>`), `${lang} ${slug} hinta`);
      assert.equal(treatmentCardPrice(p, lang), expectPrice[slug][i]);
      assert.ok(card.includes(treatmentCardWhen(p, lang)), `${lang} ${slug} kesto`);
      assert.match(card, new RegExp(`href="/(?:en/book|varaa)/#/tuote/${slug}"`));
      if (p.includes_smoke_sauna === true) assert.match(card, lang === 'fi' ? /Sisältää savusaunan/ : /Includes the smoke sauna/);
      else assert.doesNotMatch(card, /Sisältää savusaunan|Includes the smoke sauna/);
    }
    assert.equal(html.split(lang === 'fi' ? 'Sisältää savusaunan' : 'Includes the smoke sauna').length - 1, 6);
    const mors = cardOf(html, 'morsiussauna');
    assert.match(mors, lang === 'fi' ? />Kysy ajankohtaa</ : />Ask for a time</);
    assert.doesNotMatch(mors, lang === 'fi' ? />Varaa</ : />Book</);
    assert.match(html, lang === 'fi' ? /href="\/varaa\/#\/\?k=hoito"/ : /href="\/en\/book\/#\/\?k=hoito"/);
    assert.match(html, lang === 'fi' ? /href="\/lahjakortti\/"/ : /href="\/en\/gift-card\/"/);
    assert.match(html, lang === 'fi' ? />Varaa saunotus</ : />Book a saunotus</);
    assert.match(html, lang === 'fi' ? />Anna lahjaksi</ : />Give as a gift</);
    assert.doesNotMatch(html, /Lisätiedot|hunaja-, vihta-|Saunahoito opiskelijatyönä|Haluatko oppia saunottajaksi|Want to become a sauna healer/);
    assert.doesNotMatch(html, /johku\.com/);
    assert.match(html, /id="arvostelut"|id="reviews"/);
    assert.match(html, /class="rv-grid"/);
    assert.match(html, lang === 'fi' ? /Mistä aloittaa\?/ : /Where to start\?/);
    const first = html.match(/<li class="tr-path"><h3>[^<]*<\/h3>.*?<\/ul><\/li>/)[0];
    assert.match(first, lang === 'fi' ? /href="\/varaa\/#\/tuote\/saunahoito-2">Saunahoito</ : /href="\/en\/book\/#\/tuote\/saunahoito-2">Sauna Treatment</, 'ensimmäinen kerta: Saunahoito');
    assert.match(first, /tuote\/saunarituaali-ja-savusaunavuoro"/);
    assert.doesNotMatch(first, /turvetorstai/, 'Turvetorstai ei enää ensimmäisen kerran polussa');
    assert.match(html, lang === 'fi' ? /Näin saunotus etenee/ : /How a saunotus goes/);
    assert.match(html, lang === 'fi' ? /Sopiiko tämä minulle\?/ : /Is this for me\?/);
    assert.match(html, /rituaali-1536\.avif|rituaali-1024\.avif/);
    assert.match(html, /saunotus-1920\.avif|saunotus-1200\.avif/);
    assert.match(html, /hunaja-(?:480|800|1200)\.(?:avif|webp)/, 'Saunahoidon kortti: hunajahoidon kuva');
    assert.doesNotMatch(html, /products\/10-ifj3bf\.webp/, 'ei samaa kuvaa kuin Saunotuksella');
    assert.doesNotMatch(html, /<p class="note-box">/, 'introsta poistettu huomiolaatikko');
    assert.doesNotMatch(html, /<p class="lead">[^<]*<\/p><p class="note-box">/);
    assert.match(html, lang === 'fi' ? /Hoitojen hintaan ei sisälly pääsyä savusaunaan tai paljuihin/ : /does not include access to the smoke sauna or the hot tubs/);
    assert.match(html, lang === 'fi' ? /href="\/saunavuorot\/"/ : /href="\/en\/sauna\/"/);
  }
});

test('public_catalog peittää hinnan ja nimen; alk.-hintaa ei merkitä kiinteäksi', () => {
  setLiveCatalog([{ slug: 'saunahoito-2', name: 'Saunahoito <x>', price: 123, price_type: 'base_plus_extra_person', duration_text: '45 min' }]);
  const html = R.treatments('fi');
  const card = cardOf(html, 'saunahoito-2');
  assert.match(card, /Saunahoito &lt;x&gt;/);
  assert.match(card, /123 € \(sis\. 1 hlö, lisähenkilö \+35 €\)/);
  assert.match(card, /45 min/);
  assert.doesNotMatch(card, />99 €</);
  clearLiveCatalog();
  const offers = treatmentOffers('fi');
  assert.equal(offers.find((p) => p.slug === 'morsiussauna').exact, false);
  assert.equal(offers.find((p) => p.slug === 'saunahoito-2').price, 99);
});

test('JSON-LD: näkyvät tuotteet ja UKK, ei alk.-hintoja eikä vanhaa korttikuvausta', () => {
  clearLiveCatalog();
  const html = R.treatments('fi');
  const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => JSON.parse(m[1]));
  const products = blocks.filter((b) => b['@type'] === 'Product');
  const names = products.map((p) => p.name);
  assert.ok(names.includes('Saunahoito'));
  assert.ok(names.includes('Turvetorstai (to)'));
  assert.ok(!names.includes('Morsiussauna'));
  assert.ok(!names.includes('Turvesauna'));
  const hoito = products.find((p) => p.name === 'Saunahoito');
  assert.equal(hoito.offers.price, '99');
  assert.match(hoito.description, /Kiireetön hetki saunan lämmössä/);
  assert.doesNotMatch(hoito.description, /hunaja-, vihta-/);
  const faq = blocks.find((b) => b['@type'] === 'FAQPage');
  assert.equal(faq.mainEntity.length, treatmentFaq('fi').length);
  for (const q of faq.mainEntity) {
    assert.ok(html.includes(`<summary>${q.name}</summary>`));
    assert.equal(q.acceptedAnswer.text, treatmentFaq('fi').find((f) => f.question === q.name).answer);
  }
  assert.deepEqual(S.seoSchemaForPage({ lang: 'fi', key: 'treatments', url: 'https://x.test/hoidot-rituaalit/', body: '' }).filter((x) => x['@type'] === 'Product' || x['@type'] === 'FAQPage'), []);
  const meta = html.match(/<meta name="description" content="([^"]*)"/)[1];
  assert.match(meta, /Saunahoito 1 h, saunotus 2 h ja syväsaunotus 3 h/);
});
