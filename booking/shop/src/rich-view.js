// Tuotekuvauksen ja ohjeen näyttö. Pelkkä teksti pysyy textContent-solmuna (rivinvaihdot ennallaan).
// Rikas HTML näytetään vasta allowlist-puhdistuksen jälkeen.
import { isRichHtml, sanitizeRich, toPlainText } from './rich-text.js';
import { rewriteAnchors } from './johku-links.js';
import { softenSpaces, softenSpacesIn } from './text-spaces.js';
// Johku-linkit tietokannan kuvauksissa → oma kauppa (window.BOOKING_SHOP.links, build.mjs). Ilman linkkitietoja ennallaan.
const linkCtx = () => (typeof window !== 'undefined' ? window.BOOKING_SHOP?.links : null);

export function visibleText(raw) {
  const s = String(raw ?? '');
  return softenSpaces(isRichHtml(s) ? toPlainText(s) : s);
}

export function richHost(h, raw, className, rich) {
  const s = softenSpaces(raw);   // &nbsp; joka sanavälissä → rivittyy (text-spaces.js)
  // rich === false tulee täyttämättömästä pohjasta. Täytetty arvo ei saa muuttaa pelkkää tekstiä HTML:ksi.
  if (rich === false || (rich !== true && !isRichHtml(s))) return h('p', { class: className || null, text: s });
  const el = h('div', { class: className ? `${className} bk-rich` : 'bk-rich' });
  el.innerHTML = sanitizeRich(s);
  rewriteAnchors(el, linkCtx());
  softenSpacesIn(el);   // &nbsp;-entiteetit puretaan vasta sanitizeRichissä → tekstisolmut normalisoidaan tässä
  return el;
}
