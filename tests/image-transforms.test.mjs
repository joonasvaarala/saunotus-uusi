// IMAGE_TRANSFORMS=off: ei muunnososoitteita artikkelien varapolussa eikä dist-tarkistuksessa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { imgHtml } from '../src/articles/pages.mjs';
import { findRenderImageUrls } from '../scripts/check-image-urls.mjs';

const root = new URL('..', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const RENDER = 'https://aoejjmfzulhkhxbehphs.supabase.co/storage/v1/render/image/public/article-images/articles/1/a.jpg?width=800&format=webp&v=1';
const OBJECT = 'https://aoejjmfzulhkhxbehphs.supabase.co/storage/v1/object/public/article-images/articles/1/a.jpg?v=1';

test('kaupan lähde ja kopioitavat moduulit eivät sisällä valmista muunnososoitetta', () => {
  for (const p of ['booking/shop/src/product-image.js', 'booking/shop/src/quiet-week.js', 'booking/shop/src/shop.js', 'booking/shop/src/product-cards-live.js', 'booking/shop/src/upsell-ui.js', 'src/lib.mjs', 'src/articles/pages.mjs']) {
    assert.doesNotMatch(read(p), /\/render\/image\//, p);
  }
});

test('artikkelin varapolku: pois päältä object-osoite, päällä alkuperäinen osoite', () => {
  const prev = process.env.IMAGE_TRANSFORMS;
  const im = { url: RENDER, width: 1600, height: 900, alt: 'Vihta' };
  try {
    process.env.IMAGE_TRANSFORMS = 'on';
    const on = imgHtml(im, new Map());
    assert.match(on, /\/render\/image\/public\/article-images\/articles\/1\/a\.jpg\?width=800&amp;format=webp&amp;v=1/);
    assert.doesNotMatch(on, /srcset/);
    process.env.IMAGE_TRANSFORMS = 'off';
    const off = imgHtml(im, new Map());
    assert.match(off, new RegExp(OBJECT.replace(/[.]/g, '\\.').replace('?', '\\?')));
    assert.doesNotMatch(off, /\/render\/image\/|srcset/);
  } finally {
    if (prev == null) delete process.env.IMAGE_TRANSFORMS;
    else process.env.IMAGE_TRANSFORMS = prev;
  }
});

test('dist-tarkistus löytää muunnososoitteen ja hyväksyy pelkän object-osoitteen', () => {
  const dir = mkdtempSync(join(tmpdir(), 'img-urls-'));
  try {
    writeFileSync(join(dir, 'index.html'), `<img src="${OBJECT}">`);
    mkdirSync(join(dir, 'booking'));
    writeFileSync(join(dir, 'booking', 'product-image.js'), "const p = '/storage/v1/' + 'render' + '/image/public/';\n");
    assert.deepEqual(findRenderImageUrls(dir), []);
    writeFileSync(join(dir, 'index.html'), `<source srcset="${RENDER} 600w">`);
    assert.deepEqual(findRenderImageUrls(dir), ['/index.html']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
