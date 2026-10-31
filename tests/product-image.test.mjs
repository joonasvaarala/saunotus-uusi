// Tuotekuvan srcset: Supabase-muunnos (600/900, avif+webp, jpeg-varakuva) tai alkuperäinen URL.
import test from 'node:test';
import assert from 'node:assert/strict';
import { canTransform, transformUrl, productImageHtml, productImageSpec, CARD_WIDTHS, SIZES, withImageVersion, liveImageUrl, imageVersionOf, catalogImageUrl, imageTransformsOn, publicImageUrl } from '../booking/shop/src/product-image.js';

process.env.IMAGE_TRANSFORMS = 'on';

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

test('kuviosoite versioidaan updated_atilla tai polulla', () => {
  assert.equal(imageVersionOf({ updated_at: '2026-10-28T18:00:00.000Z', path: 'products/1-aaaaaa.webp' }), '2026-10-28T18:00:00.000Z');
  assert.equal(imageVersionOf({ path: 'products/1-aaaaaa.webp' }), 'products/1-aaaaaa.webp');
  const url = withImageVersion(OBJ, '2026-10-28T18:00:00.000Z');
  assert.match(url, /[?&]v=2026-10-28T18%3A00%3A00\.000Z$/);
  const html = productImageHtml(url, { widths: CARD_WIDTHS, sizes: SIZES.shop, alt: 'A', width: 900, height: 600 });
  assert.match(html, /[?&]v=2026-10-28T18%3A00%3A00\.000Z/);
  assert.match(html, /width=600/);
  assert.equal(liveImageUrl('https://cdn.test/product-images', { path: '../x.png' }), '');
  assert.equal(liveImageUrl('https://cdn.test/product-images/', { path: 'products/1-aaaaaa.webp', updated_at: 't' }), 'https://cdn.test/product-images/products/1-aaaaaa.webp?v=t');
  assert.equal(catalogImageUrl('', { path: 'products/1-aaaaaa.webp' }), '');
  assert.match(catalogImageUrl(LOCAL, { path: 'products/1-abcdef.jpg' }), /[?&]v=products%2F1-abcdef\.jpg$/);
});

test('IMAGE_TRANSFORMS=off ja selainconfig: ei srcsetiä, render-osoite palautuu object-osoitteeksi', () => {
  assert.equal(imageTransformsOn({ env: {} }), true);
  assert.equal(imageTransformsOn({ env: { IMAGE_TRANSFORMS: 'off' } }), false);
  assert.equal(imageTransformsOn({ env: { IMAGE_TRANSFORMS: 'on' }, config: { imageTransforms: false } }), false);
  assert.equal(imageTransformsOn({ env: { IMAGE_TRANSFORMS: 'off' }, config: { url: 'https://x' } }), false);
  assert.equal(canTransform(OBJ, { transforms: false }), false);
  const html = productImageHtml(OBJ, { transforms: false, widths: CARD_WIDTHS, sizes: SIZES.shop, alt: 'Yleinen & vuoro', width: 1600, height: 1068, lazy: true });
  assert.equal(html, `<img src="${OBJ}" width="1600" height="1068" alt="Yleinen &amp; vuoro" loading="lazy" decoding="async">`);
  assert.doesNotMatch(html, /srcset|picture|\/render\/image\//);
  const render = `${OBJ.replace('/storage/v1/object/public/', '/storage/v1/render/image/public/')}?width=600&resize=contain&quality=50&format=avif&v=abc`;
  assert.equal(publicImageUrl(render, { transforms: false }), `${OBJ}?v=abc`);
  assert.equal(transformUrl(OBJ, { transforms: false, width: 600, format: 'avif' }), OBJ);
  const spec = productImageSpec(OBJ, { transforms: true, widths: [600], alt: 'A', lazy: true });
  assert.equal(spec.sources.length, 2);
  assert.match(spec.sources[0].srcset, /\/render\/image\//);
});
