// Tuotekortin kuva. Lähde on sama kuin kaupalla: public_product_images (productImageFor).
// Toimituksellinen kuva (fallbackHtml) vain, kun tuotteella ei ole omaa kuvaa.
// data-product-image: selain vaihtaa kuvan elävään katalogiin (product-cards-live.js) ilman uudelleenrakennusta.
import { e } from './lib.mjs';
import { productImageFor, productImageUrl } from './product-images.mjs';
import { productImageHtml, CARD_WIDTHS, withImageVersion, imageVersionOf } from '../booking/shop/src/product-image.js';

export function productCardInner({ slug = '', alt = '', fallbackHtml = '', sizes = '', widths = CARD_WIDTHS, width = 900, height = 600, lazy = true } = {}) {
  const id = typeof slug === 'string' ? slug : '';
  const row = id ? productImageFor(id) : null;
  const raw = productImageUrl(row);
  const version = imageVersionOf(row) || row?.path || '';
  const url = raw ? withImageVersion(raw, version) : '';
  const attrs = id
    ? ` data-product-image data-slug="${e(id)}"${sizes ? ` data-sizes="${e(sizes)}"` : ''}${widths?.length ? ` data-widths="${widths.join(',')}"` : ''}${alt ? ` data-alt="${e(alt)}"` : ''}`
    : '';
  if (url) {
    const productAlt = (row.alt && String(row.alt).trim()) || alt;
    const spec = { widths, alt: productAlt, width: row.width || width, height: row.height || height, lazy };
    if (sizes) spec.sizes = sizes;
    const html = productImageHtml(url, spec);
    const fb = fallbackHtml ? `<template class="pi-fallback">${fallbackHtml}</template>` : '';
    return { attrs, html: html + fb, has: true, product: true };
  }
  return { attrs, html: fallbackHtml || '', has: !!fallbackHtml, product: false };
}
