// Johku-linkit → oma sivusto. Projektin oletus (Joonas 24.10.2026): sivustolla EI ole yhtään Johku-linkkiä; kaikki asiakkaille näkyvät linkit
// osoittavat uuden kaupan sisälle: FI /varaa/#/tuote/<slug>, EN /en/book/#/tuote/<slug> (yritystuotteet /yritykset/, lahjakortit /lahjakortti/).
// Lisäksi tietokannan kuvauksiin tallennetut kanoniset osoitteet (https://uusi.saunotus.com/…, booking_161) ohjataan sivuston omaan BASE-polkuun.
// Käyttö: booking/shop/build.mjs (perussivuston HTML ja static-products.json build-aikana + vartija: dististä ei saa löytyä Johku-hrefiä) ja
// rich-view.js (tietokannan rikkaat kuvaukset ajonaikana, window.BOOKING_SHOP.links). Puhdas moduuli, ei DOM-riippuvuutta.
// Testit: booking/tests/linkit-kauppaan.test.mjs.
export const JOHKU_URL = /^https:\/\/sipoonjoenperinnesauna\.johku\.com(?:\/([^/?#]+))?\/?([^?#]*)/;
export const CANONICAL = 'https://uusi.saunotus.com';
// Johkun lahjakorttipaketit: avoin lahjakortti → lahjakorttisivun #avoin, muut paketit → #paketit (gift.js säilyttää id:t myynnin ollessa auki).
const GIFT_OPEN = new Set(['lahjakortti']);

const join = (a, b) => (a || '') + (b || '');
/**
 * Johku- tai kanoninen osoite → sivuston oma osoite, tai null (muu linkki: ei muutosta).
 * ctx: { shop: kaupan polku ('/varaa/' tai '/en/book/', BASE mukana), companies, gift, info, terms, privacy: sivujen polut (BASE mukana),
 *        base: sivuston BASE ('' tai '/saunotus-uusi'; kanonisten osoitteiden ohjaus), slugs: Set|Array uuden kaupan slugeista }
 */
export function shopTarget(url, ctx = {}) {
  const u = String(url || '').trim();
  if (!ctx.shop) return null;
  if (ctx.base != null && (u === CANONICAL || u.startsWith(CANONICAL + '/') || u.startsWith(CANONICAL + '#'))) return join(ctx.base, u.slice(CANONICAL.length) || '/');
  const m = JOHKU_URL.exec(u);
  if (!m) return null;
  const parts = (m[2] || '').replace(/\/+$/, '').split('/').filter(Boolean);
  const head = parts[0] || '', slug = parts[parts.length - 1] || '';
  const slugs = ctx.slugs instanceof Set ? ctx.slugs : new Set(ctx.slugs || []);
  const prod = parts.length > 1 && slugs.has(slug) ? `#/tuote/${encodeURIComponent(slug)}` : '';
  if (head === 'yrityksille' && ctx.companies) return ctx.companies + prod;
  if (head === 'sarja-ja-lahjakortit') {
    if (slug === 'vuosikortti') return `${ctx.shop}#/vuosikortti`;
    if (ctx.gift) return ctx.gift + (parts.length < 2 ? '' : GIFT_OPEN.has(slug) ? '#avoin' : '#paketit');
    return `${ctx.shop}#/`;
  }
  // Johku-lahjakortilla tehtävä varaus: uudessa kaupassa lahjakortti (myös Johkun) lunastetaan kassalla → kaupan etusivu
  if (head === 'yleinen-lahjakorttivaraus') return `${ctx.shop}#/`;
  if (head === 'info') {
    if (/^deliveryterms$/i.test(parts[1] || '') && ctx.terms) return ctx.terms;
    if (/^privacypolicy$/i.test(parts[1] || '') && ctx.privacy) return ctx.privacy;
    return ctx.info || `${ctx.shop}#/`;
  }
  if (prod) return ctx.shop + prod;
  if (head === 'yleinen-sauna') return `${ctx.shop}#/?k=yleinen`;
  if (head === 'yksityisvuorot') return `${ctx.shop}#/?k=yksityinen`;
  return `${ctx.shop}#/`;
}

/** HTML-merkkijonon <a href="johku…|kanoninen…"> → sivuston osoite (build-aika). Uuteen välilehteen -merkinnät ja target poistetaan. */
const ANCHOR = /<a\b([^>]*?)href="((?:https:\/\/sipoonjoenperinnesauna\.johku\.com|https:\/\/uusi\.saunotus\.com)(?:[/#][^"]*)?)"([^>]*)>([\s\S]*?)<\/a>/g;
const NOTE = /<span class="sr"> \((?:avautuu uuteen välilehteen|opens in a new tab)\)<\/span>/g;
const attr = (s) => String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;');
export function rewriteHtml(html, ctx) {
  return String(html ?? '').replace(ANCHOR, (m, a, url, b, inner) => {
    const target = shopTarget(url.replace(/&amp;/g, '&'), ctx);
    if (!target) return m;
    const attrs = (a + b).replace(/\s*target="_blank"/g, '').replace(/\s*rel="noopener(?: noreferrer)?"/g, '');
    return `<a${attrs.trim() ? ' ' + attrs.trim() : ''} href="${attr(target)}">${inner.replace(NOTE, '')}</a>`;
  });
}

/** Johku-hrefit merkkijonossa (build-vartija): palauttaa löydetyt osoitteet. */
export function johkuHrefs(text) {
  return [...String(text ?? '').matchAll(/href=\\?["']?(https?:\/\/[a-z0-9.-]*johku\.com[^"'\s>\\]*)/gi)].map((x) => x[1]);
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
