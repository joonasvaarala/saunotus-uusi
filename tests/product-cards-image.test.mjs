// Tuotekortin kuva on tuotteen oma kuva. Toimituksellinen kuva vain, kun tuotteella ei ole kuvaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

delete process.env.SITE_ENV;
process.env.SITE_URL = 'https://saunotus.fi';
process.env.IMAGE_TRANSFORMS = 'on';

const { setProductImages } = await import('../src/product-images.mjs');
const R = await import('../src/render.mjs');
const { experienceHtml } = await import('../src/home-front.mjs');
const { mockProductImages } = await import('../booking/shop/src/mock-product-images.js');

const between = (html, start, end) => html.slice(html.indexOf(start), end ? html.indexOf(end) : undefined);

test('saunavuorot: ilman tuotekuvaa toimituksellinen kuva, tuotekuva korvaa sen', () => {
  const before = R.sauna('fi');
  assert.match(before, /data-slug="yleinensauna"/);
  assert.match(between(before, 'data-slug="yleinensauna"', 'data-slug="miestensauna-2"'), /j-yleinen-/);
  assert.doesNotMatch(between(before, 'data-slug="yleinensauna"', 'data-slug="miestensauna-2"'), /\/product-images\//);
  const en = R.sauna('en');
  assert.match(en, /data-slug="naistensauna"/);
  assert.match(en, /j-naiset-/);
  const restore = setProductImages([{ slug: 'yleinensauna', path: 'products/1-newimg2.webp', alt: 'Uusi yleinen', width: 900, height: 600, updated_at: '2026-10-28T18:00:00.000Z' }]);
  try {
    const block = between(R.sauna('fi'), 'data-slug="yleinensauna"', 'data-slug="miestensauna-2"');
    assert.match(block, /<img [^>]*src="[^"]*products\/1-newimg2\.webp[^"]*v=2026-10-28T18/);
    assert.match(block, /alt="Uusi yleinen"/);
    assert.match(block, /<template class="pi-fallback">[\s\S]*j-yleinen-/);
    assert.doesNotMatch(block.split('<template')[0], /j-yleinen-/);
  } finally { restore(); }
});

test('etusivu, hoidot ja lahjapaketti käyttävät samaa tuotekuvaa', () => {
  const home = experienceHtml('fi');
  assert.match(home, /data-slug="saunahoito-2"/);
  assert.match(home, /data-slug="yleinensauna"/);
  assert.match(home, /products\/10-ifj3bf\.webp/);
  const hoito = between(R.treatments('fi'), 'data-slug="saunahoito-2"', 'data-slug="saunotus-2"');
  assert.match(hoito, /products\/10-ifj3bf\.webp/);
  const gift = R.gift('fi');
  const pkg = between(gift, 'data-gift-package="sauna_treatment_2"', 'data-gift-package="saunotus_2"');
  assert.match(pkg, /data-slug="saunahoito-2"/);
  assert.match(pkg, /products\/10-ifj3bf\.webp/);
  const entry = between(gift, 'data-gift-package="entry_2"', 'data-gift-package="peat_mask_2"');
  assert.match(entry, /data-slug="yleinensauna"/);
  assert.match(entry, /j-yleinen-/);
  assert.match(R.gift('en'), /data-slug="saunahoito-2"/);
});

test('mockin img=2 vaihtaa tuotekuvan polun ja version', () => {
  assert.deepEqual(mockProductImages(''), []);
  assert.deepEqual(mockProductImages('?mock=1'), []);
  const a = mockProductImages('?mock=1&img=1');
  const b = mockProductImages('?img=2');
  assert.equal(a.find((x) => x.slug === 'saunahoito-2').path, 'products/10-oldimg1.webp');
  assert.equal(b.find((x) => x.slug === 'saunahoito-2').path, 'products/10-newimg2.webp');
  assert.notEqual(a[0].updated_at, b[0].updated_at);
});

test('booking_212 lisää updated_at:n eikä muuta kuvien joukkoa', () => {
  const sql = readFileSync(new URL('../booking/supabase/migrations/20261028194142_booking_212_product_image_version.sql', import.meta.url), 'utf8');
  assert.match(sql, /'updated_at', pc\.updated_at/);
  assert.match(sql, /where pc\.bookable and pc\.shop_visible and pc\.image_path is not null/);
  const back = readFileSync(new URL('../booking/supabase/rollbacks/20261028194142_booking_212_ROLLBACK.sql', import.meta.url), 'utf8');
  assert.match(back, /'path', pc\.image_path/);
  assert.doesNotMatch(back, /'updated_at'/);
});
