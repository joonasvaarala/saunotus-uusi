// booking_156: tuotteen lyhyt kuvaus (kb.products.short_description / short_description_en, rikas teksti, sama allowlist kuin kuvauksella).
// Täytetty lyhyt kuvaus korvaa kuvauksesta johdetun otteen (sivun yläbanneri + tuotekortti). EN: short_description_en || short_description.
// Tyhjä (myös pelkkä tyhjä editori "<p><br></p>") → nykyinen ote kuvauksesta. Rikas HTML näytetään vain rich-view.js:n (allowlist-puhdistus) kautta.
import { isRichHtml } from './rich-text.js';
import { visibleText, richHost } from './rich-view.js';
import { softenSpaces } from './text-spaces.js';   // &nbsp; sanaväleissä → rivittyy myös pelkässä tekstissä

const has = (v) => !!visibleText(String(v ?? '')).trim();

/** Lyhyen kuvauksen raakateksti kielellä lang; '' jos tyhjä. EN puuttuu → FI. */
export function shortRaw(p, lang) {
  if (lang === 'en' && has(p?.short_description_en)) return String(p.short_description_en).trim();
  return has(p?.short_description) ? String(p.short_description).trim() : '';
}

/** Johdettu ote yläbanneriin: ensimmäinen virke (ei katkaista kellonaikojen pisteistä "16.30"), enintään ~130 merkkiä sanarajalta. */
export function derivedShort(raw) {
  const s = String(raw ?? '');
  const d = (isRichHtml(s) ? visibleText(s) : softenSpaces(s)).replace(/\s+/g, ' ').trim(); if (!d) return '';
  const m = d.match(/^.{20,}?[.!?](?=\s+[A-ZÅÄÖ])/u); let x = m ? m[0] : d;
  if (x.length > 130) x = `${x.slice(0, 130).replace(/\s+\S*$/, '')}…`;
  return x;
}

/** Johdettu kortin ote: pelkkä teksti leikataan kuten ennen (ei välilyöntien tiivistystä), rikas HTML tiivistetään näkyväksi tekstiksi. */
export function derivedExcerpt(raw) {
  const s = String(raw ?? '');
  const plain = isRichHtml(s) ? visibleText(s).replace(/\s+/g, ' ').trim() : softenSpaces(s);
  return plain.slice(0, 170) + (plain.length > 170 ? '…' : '');
}

/** Yläbanneri: { node, text }. Rikas lyhyt kuvaus → puhdistettu solmu (node), muuten teksti (lyhyt kuvaus tai johdettu ote). */
export function heroShort(h, p, lang, desc) {
  const s = shortRaw(p, lang);
  if (s && isRichHtml(s)) return { node: richHost(h, s, 'bk-hero-short', true), text: '' };
  return { node: null, text: softenSpaces(s) || derivedShort(desc) };
}

/** Tuotesivun ingressi kalenterin vieressä (Joonas 28.10.2026): tuotteen lyhyt kuvaus; tyhjä → johdettu ote kuvauksesta. null jos ei kumpaakaan.
 *  Uima-asu- ja peruutustiedot eivät kuulu tähän: ne ovat Lue lisää -osiossa (moreInfo) pitkän kuvauksen jälkeen. */
export function leadShort(h, p, lang, desc) {
  const s = shortRaw(p, lang);
  const el = s ? richHost(h, s, 'bk-lead') : (derivedShort(desc) ? h('p', { class: 'bk-lead', text: derivedShort(desc) }) : null);
  el?.setAttribute?.('data-testid', 'lead');
  return el;
}

/** Tuotekortin kuvausosa (.bk-desc): lyhyt kuvaus (puhdistettuna; CSS tiivistää 3 riviin), muuten johdettu ote. */
export function cardShort(h, p, lang, desc) {
  const s = shortRaw(p, lang);
  return s ? richHost(h, s, 'bk-desc') : h('p', { class: 'bk-desc', text: derivedExcerpt(desc) });
}

/** Tuntemattoman tuotteen varasivu (static-products.json): kuvaus puhdistettuna; EN: description_en || description. */
export function fallbackDesc(h, st, lang) {
  const raw = (lang === 'en' && has(st?.description_en) && st.description_en) || st?.description || '';
  return richHost(h, raw, 'bk-desc');
}
