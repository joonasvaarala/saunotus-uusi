// Tuotekuvauksen ja ohjeen näyttö. Pelkkä teksti pysyy textContent-solmuna (rivinvaihdot ennallaan).
// Rikas HTML näytetään vasta allowlist-puhdistuksen jälkeen.
import { isRichHtml, sanitizeRich, toPlainText } from './rich-text.js';

export function visibleText(raw) {
  const s = String(raw ?? '');
  return isRichHtml(s) ? toPlainText(s) : s;
}

export function richHost(h, raw, className, rich) {
  const s = String(raw ?? '');
  // rich === false tulee täyttämättömästä pohjasta. Täytetty arvo ei saa muuttaa pelkkää tekstiä HTML:ksi.
  if (rich === false || (rich !== true && !isRichHtml(s))) return h('p', { class: className || null, text: s });
  const el = h('div', { class: className ? `${className} bk-rich` : 'bk-rich' });
  el.innerHTML = sanitizeRich(s);
  return el;
}
