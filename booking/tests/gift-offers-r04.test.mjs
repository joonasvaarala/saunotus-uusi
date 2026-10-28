// R04: esirenderöity lahjakorttilista, varateksti, metakuvaus ja Product/Offer tulevat samasta julkaistusta valikoimasta.
// Hidas lataus = HTML ennen API-vastausta. API-virhe = staattisia osioita ei poisteta.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { PUBLISHED_GIFT_PACKAGES, giftMetaDescription } from '../shop/src/gift-offers.js';
import { MOCK_PACKAGES } from '../shop/src/gift-mock.js';
import { giftSaleReplacesStatic, annualCardBuyHref } from '../shop/src/gift-logic.js';
import { gift } from '../../src/render.mjs';
import { seoSchemaForPage } from '../../src/seo-enhance.mjs';
import { pageDoc } from '../../src/content-texts.mjs';
import { pageHref } from '../../src/lib.mjs';

const root = new URL('../..', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const fixed = PUBLISHED_GIFT_PACKAGES.filter((p) => !p.is_open);
const section = (html, id) => html.split(`id="${id}"`)[1]?.split('</section>')[0] || '';
const products = (html) => [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)]
  .map((m) => JSON.parse(m[1]))
  .filter((j) => j['@type'] === 'Product');

test('julkaistu valikoima on kaupan mockin valikoima', () => {
  assert.equal(MOCK_PACKAGES, PUBLISHED_GIFT_PACKAGES);
  assert.deepEqual(fixed.map((p) => [p.code, p.price]), [
    ['entry_2', 58], ['peat_mask_2', 88], ['saunarituaali_2', 98], ['sauna_treatment_2', 192], ['saunotus_2', 328],
  ]);
});

test('metakuvaus ja varateksti kuvaavat saman valikoiman eivätkä lupaa vuosikorttia', () => {
  for (const lang of ['fi', 'en']) {
    const text = giftMetaDescription(lang);
    assert.equal(pageDoc('gift')[lang].meta.description, text);
    assert.doesNotMatch(text, /vuosikortti|annual card/i);
    for (const p of fixed) assert.match(text, new RegExp(lang === 'en' ? p.name_en : p.name));
    assert.match(text, lang === 'en' ? /€29/ : /29 €/);
  }
  const fb = JSON.parse(read('content/site-texts.fallback.json')).texts.filter((r) => r.key === 'seo.gift.description');
  const pr = JSON.parse(read('content/site-texts.imported-pr64.json')).filter((r) => r.key === 'seo.gift.description');
  for (const lang of ['fi', 'en']) {
    assert.equal(fb.find((r) => r.lang === lang).text, giftMetaDescription(lang));
    const row = pr.find((r) => r.lang === lang);
    assert.equal(row.text, giftMetaDescription(lang));
    assert.equal(row.max_len, 900);
    assert.equal(row.class, 'protected');
  }
});

test('hidas lataus: esirenderöity lista ja JSON-LD ovat julkaistu valikoima', () => {
  for (const lang of ['fi', 'en']) {
    const html = gift(lang);
    const pack = section(html, 'paketit');
    const open = section(html, 'avoin');
    assert.match(html, new RegExp(`<meta name="description" content="${giftMetaDescription(lang).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}">`));
    assert.doesNotMatch(pack, /koivuvihta|birch whisk|Vuosikortti|Annual card|42 €|€42|290/);
    assert.match(open, lang === 'en' ? /€29/ : /29 €/);
    const shop = pageHref('book', lang).replace(/\/+$/, '');
    for (const p of fixed) {
      const name = lang === 'en' ? p.name_en : p.name;
      assert.match(pack, new RegExp(`data-gift-package="${p.code}"`));
      assert.match(pack, new RegExp(`<h3>${name}</h3>`));
      assert.match(pack, new RegExp(lang === 'en' ? `€${p.price}` : `${p.price} €`));
    }
    assert.match(pack, new RegExp(`${shop}/#/tuote/yleinensauna`));
    assert.match(pack, new RegExp(`${shop}/#/tuote/saunarituaali-ja-savusaunavuoro`));
    assert.match(pack, lang === 'en' ? /Peat mask and foot bath/ : /Turvenaamio ja jalkakylpy/);
    assert.doesNotMatch(pack, /tuote\/turvenaamio/);
    const offers = products(html);
    const schema = seoSchemaForPage({ lang, key: 'gift', url: 'https://x.test/lahjakortti/', body: html });
    const prices = offers.map((o) => +o.offers.price).sort((a, b) => a - b);
    assert.deepEqual(prices, [29, 58, 88, 98, 192, 328]);
    assert.deepEqual(schema.map((o) => +o.offers.price).sort((a, b) => a - b), prices);
    assert.ok(offers.every((o) => fixed.some((p) => (lang === 'en' ? p.name_en : p.name) === o.name) || o.name === (lang === 'en' ? 'Open gift card' : 'Avoin lahjakortti')));
    assert.ok(!offers.some((o) => /vuosikortti|annual card|koivuvihta|birch whisk/i.test(o.name)));
  }
});

test('API-virhe ei korvaa esirenderöityä listaa; vuosikorttilinkki vain kun myynti on auki', () => {
  const pkgs = [{ code: 'entry_2' }];
  assert.equal(giftSaleReplacesStatic(null), false);
  assert.equal(giftSaleReplacesStatic({ ok: false, code: 'PGRST202' }), false);
  assert.equal(giftSaleReplacesStatic({ ok: true, sale_enabled: false, packages: pkgs }), false);
  assert.equal(giftSaleReplacesStatic({ ok: true, sale_enabled: true, packages: [] }), false);
  assert.equal(giftSaleReplacesStatic({ ok: true, sale_enabled: true, packages: pkgs }), true);
  assert.equal(annualCardBuyHref(null, '/varaa/'), '');
  assert.equal(annualCardBuyHref({ available: false, price: 290 }, '/varaa/'), '');
  assert.equal(annualCardBuyHref({ available: true, price: 290 }, ''), '');
  assert.equal(annualCardBuyHref({ available: true, price: 290 }, '/varaa/'), '/varaa/#/vuosikortti');
  assert.equal(annualCardBuyHref({ available: true }, '/en/book/#/'), '/en/book/#/vuosikortti');
  const src = readFileSync(new URL('../shop/src/gift.js', import.meta.url), 'utf8');
  const gate = src.indexOf('if (G.giftSaleReplacesStatic(pk)');
  const remove = src.indexOf("document.getElementById('paketit')?.remove()");
  const annual = src.indexOf('placeAnnual(await annualP)');
  assert.ok(gate > 0 && remove > gate && annual > remove, 'poisto vain onnistuneen myynnin haarassa, vuosikortti sen jälkeen');
});
