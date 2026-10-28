// Tuotekuvan srcset: Supabase-muunnos (600/900, avif+webp, jpeg-varakuva) tai alkuperäinen URL.
import test from 'node:test';
import assert from 'node:assert/strict';
import { canTransform, transformUrl, productImageHtml, productImageSpec, CARD_WIDTHS, SIZES } from '../booking/shop/src/product-image.js';

const OBJ = 'https://sxbofnuisemspgquoxyv.supabase.co/storage/v1/object/public/product-images/products/1-wq1bnlln.jpg';
const LOCAL = 'http://localhost:4181/storage/v1/object/public/product-images/products/1-abcdef.jpg';

test('muunnos vain julkiselle Supabase-object-URL:lle', () => {
  assert.equal(canTransform(OBJ), true);
  assert.equal(canTransform(LOCAL), false);
  assert.equal(canTransform('https://example.com/storage/v1/object/public/product-images/a.jpg'), false);
  assert.equal(canTransform('not a url'), false);
});

test('srcset 600 ja 900, avif ja webp, jpeg-varakuva, sama tiedosto', () => {
  const html = productImageHtml(OBJ, { widths: CARD_WIDTHS, sizes: SIZES.shop, alt: 'Yleinen & vuoro', width: 1600, height: 1068, lazy: true });
  assert.match(html, /<picture><source type="image\/avif" /);
  assert.match(html, /<source type="image\/webp" /);
  for (const fmt of ['avif', 'webp', 'origin']) {
    assert.match(html, new RegExp(`format=${fmt}`));
    assert.match(html, new RegExp(`width=600[^"]*format=${fmt}[^"]* 600w`));
    assert.match(html, new RegExp(`width=900[^"]*format=${fmt}[^"]* 900w`));
  }
  assert.match(html, /resize=contain/);
  assert.match(html, /<img src="https:\/\/sxbofnuisemspgquoxyv\.supabase\.co\/storage\/v1\/object\/public\/product-images\/products\/1-wq1bnlln\.jpg"/);
  for (const m of html.matchAll(/srcset="([^"]*)"/g)) assert.doesNotMatch(m[1], /\/object\/public\//);
  assert.match(html, /sizes="\(min-width: 900px\) 350px, 92vw"/);
  assert.match(html, /width="1600" height="1068" alt="Yleinen &amp; vuoro" loading="lazy"/);
  assert.doesNotMatch(html, /fetchpriority/);
  const url = transformUrl(OBJ, { width: 600, format: 'avif' });
  assert.equal(url, 'https://sxbofnuisemspgquoxyv.supabase.co/storage/v1/render/image/public/product-images/products/1-wq1bnlln.jpg?width=600&resize=contain&quality=50&format=avif');
});

test('hero ei ole lazy; paikallinen demo jää alkuperäiseen kuvaan', () => {
  const hero = productImageSpec(OBJ, { widths: [900, 1600], sizes: SIZES.hero, alt: '', lazy: false });
  assert.equal(hero.img.loading, undefined);
  assert.equal(hero.img.fetchpriority, 'high');
  assert.equal(hero.sources.length, 2);
  assert.match(hero.img.src, /\/object\/public\/product-images\/products\/1-wq1bnlln\.jpg$/);
  assert.match(hero.img.srcset, /width=1600/);
  const local = productImageHtml(LOCAL, { alt: 'A "kuva"' });
  assert.equal(local, `<img src="${LOCAL}" width="600" height="400" alt="A &quot;kuva&quot;" loading="lazy" decoding="async">`);
  assert.doesNotMatch(local, /picture|srcset|render\/image/);
});
