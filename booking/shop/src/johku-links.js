// Johku-linkit → oma kauppa. Projektin oletus (Joonas 24.10.2026): kaikki asiakkaille näkyvät linkit osoittavat kaupan sisälle,
// kun tuote on varattavissa uudessa järjestelmässä: FI /varaa/#/tuote/<slug>, EN /en/book/#/tuote/<slug>.
// Käyttö: booking/shop/build.mjs (perussivuston HTML ja static-products.json build-aikana) ja rich-view.js (tietokannan rikkaat
// kuvaukset ajonaikana, window.BOOKING_SHOP.links). Puhdas moduuli, ei DOM-riippuvuutta. Testit: booking/tests/linkit-kauppaan.test.mjs.
export const JOHKU_URL = /^https:\/\/sipoonjoenperinnesauna\.johku\.com\/[^/?#]+\/?([^?#]*)/;
// Jää Johkuun (ei vielä kohdetta uudessa kaupassa):
//  - yleinen-lahjakorttivaraus: Johku-lahjakortilla tehtävä vuorovaraus (uudessa kaupassa lahjakortti lunastetaan kassalla, kytkin gift_cards.redeem_enabled)
//  - sarja-ja-lahjakortit (paitsi vuosikortti): lahjakorttien myynti on /lahjakortti/-sivulla kytkimen gift_cards.sale_enabled takana
//  - info/: Johkun omat info-sivut
export const KEEP = /^(yleinen-lahjakorttivaraus|sarja-ja-lahjakortit(?!\/vuosikortti\/?$)|info(\/|$))/;

/**
 * Johku-osoite → kaupan osoite tai null (ei Johku-linkki tai jää Johkuun).
 * ctx: { shop: kaupan polku ('/varaa/' tai '/en/book/', BASE mukana), companies: yrityssivun polku, slugs: Set|Array uuden kaupan slugeista }
 */
export function shopTarget(url, ctx = {}) {
  const m = JOHKU_URL.exec(String(url || '').trim());
  if (!m || !ctx.shop) return null;
  const path = m[1].replace(/\/+$/, '');
  if (KEEP.test(path)) return null;
  const slugs = ctx.slugs instanceof Set ? ctx.slugs : new Set(ctx.slugs || []);
  const parts = path.split('/').filter(Boolean);
  const slug = parts[parts.length - 1] || '';
  const prod = parts.length > 1 && slugs.has(slug) ? `#/tuote/${encodeURIComponent(slug)}` : '';
  if (parts[0] === 'yrityksille' && ctx.companies) return ctx.companies + prod;
  if (parts[0] === 'sarja-ja-lahjakortit' && slug === 'vuosikortti') return `${ctx.shop}#/vuosikortti`;
  if (prod) return ctx.shop + prod;
  if (parts[0] === 'yleinen-sauna') return `${ctx.shop}#/?k=yleinen`;
  if (parts[0] === 'yksityisvuorot') return `${ctx.shop}#/?k=yksityinen`;
  return `${ctx.shop}#/`;
}

/** HTML-merkkijonon <a href="johku…"> → kauppa (build-aika). Uuteen välilehteen -merkinnät ja target poistetaan kaupan linkeistä. */
const ANCHOR = /<a\b([^>]*?)href="(https:\/\/sipoonjoenperinnesauna\.johku\.com\/[^"]*)"([^>]*)>([\s\S]*?)<\/a>/g;
const NOTE = /<span class="sr"> \((?:avautuu uuteen välilehteen|opens in a new tab)\)<\/span>/g;
export function rewriteHtml(html, ctx) {
  return String(html ?? '').replace(ANCHOR, (m, a, url, b, inner) => {
    const target = shopTarget(url.replace(/&amp;/g, '&'), ctx);
    if (!target) return m;
    const attrs = (a + b).replace(/\s*target="_blank"/g, '').replace(/\s*rel="noopener"/g, '');
    return `<a${attrs.trim() ? ' ' + attrs.trim() : ''} href="${target}">${inner.replace(NOTE, '')}</a>`;
  });
}

/** DOM-solmun linkit (rich-view.js, puhdistuksen jälkeen). */
export function rewriteAnchors(root, ctx) {
  if (!root?.querySelectorAll || !ctx?.shop) return 0;
  let n = 0;
  for (const a of root.querySelectorAll('a[href]')) {
    const t = shopTarget(a.getAttribute('href'), ctx);
    if (t) { a.setAttribute('href', t); a.removeAttribute('target'); n++; }
  }
  return n;
}
