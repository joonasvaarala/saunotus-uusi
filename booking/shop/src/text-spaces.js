// Sitovat välilyönnit (U+00A0 &nbsp;, U+202F, U+2007) tavallisiksi välilyönneiksi näyttöhetkellä.
// Syy (Joonas 24.10.2026): editorista/Johkusta tulleissa kuvauksissa (kb.products.description, short_description)
// jokainen sanaväli on &nbsp; → selain ei voi rivittää kappaletta, ja tuotesivu/-kortti venyy vaakasuunnassa (390 px puhelin).
// Tietokannan tekstiä ei muuteta; normalisointi tehdään vain renderöinnissä (rich-view.js).
// Tarkoituksellinen sitova väli säilyy luvun ja yksikön/luvun välissä: "5 €", "1 000", "30 %", "2 h", "60 min".
const NB = /[\u00a0\u202f\u2007]/g;
const KEEP_AFTER_DIGIT = /^(?:\d|[€$£%‰]|(?:h|min|kg|km|m|cm|l|dl|hlö|pcs|pv|vrk)(?![\p{L}\p{N}]))/u;

/** Merkkijonon sitovat välit tavallisiksi (paitsi luku + yksikkö). Muut merkit ennallaan. */
export function softenSpaces(text) {
  const s = String(text ?? '');
  if (!/[\u00a0\u202f\u2007]/.test(s)) return s;
  return s.replace(NB, (ch, i) => (/\d/.test(s[i - 1] || '') && KEEP_AFTER_DIGIT.test(s.slice(i + 1, i + 5)) ? ch : ' '));
}

/** DOM-puun tekstisolmut läpi (rikas kuvaus innerHTML:n jälkeen). Palauttaa saman elementin. */
export function softenSpacesIn(el) {
  if (!el || typeof document === 'undefined') return el;
  const w = document.createTreeWalker(el, 4 /* NodeFilter.SHOW_TEXT */);
  for (let n = w.nextNode(); n; n = w.nextNode()) { const v = softenSpaces(n.nodeValue); if (v !== n.nodeValue) n.nodeValue = v; }
  return el;
}
