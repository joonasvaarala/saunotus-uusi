// Paketti 11: Schema.org-lisäykset sivupohjiin + vanhojen WordPress-osoitteiden ohjaussivut.
// Ei riippuvuuksia eikä selaimen ajonaikaista JS:ää. Sauna- ja hoitosivujen hinnat samasta kb:stä ja samalla laskulla kuin näkyvät korttihinnat
// (priceOf), ja tuote merkitään vain, jos sen kortti (otsikko) näkyy samalla sivulla. Hintoja ei muuteta.
// Lahjakorttisivu: Product/Offer tulee julkaistusta valikoimasta (gift-offers.js), ei cards.jsonin vanhoista Johku-korteista.
// Ei aggregateRating-merkintää: arviot ovat Googlen (kolmannen osapuolen) arvioita, eikä niitä saa merkitä omaksi rakenteiseksi dataksi.
import { kb, abs, e, priceOf, fromMode, site } from './lib.mjs';
import { liveCatalogName } from './catalog-live.mjs';
import { cards, pageDoc } from './content-texts.mjs';
import { faqFor } from './kb-en.mjs';
import { tx } from './site-texts.mjs';
import { PUBLISHED_GIFT_PACKAGES } from '../booking/shop/src/gift-offers.js';
import { treatmentFaq, treatmentOffers } from './treatments-page.mjs';

// Saunavuorot: Product/Offer näkyvistä cards.json-korteista. Hoidot ja rituaalit merkitään erikseen tuotteen korteista.
const PRODUCT_PAGES = new Set(['sauna']);
const CARD_GROUPS = ['sauna', 'treatments', 'gift'];
const bySlug = (slug) => kb.products.find((p) => p.slug === slug);
const exactPrice = (c, p) => Number.isFinite(+priceOf(p)) && +priceOf(p) > 0 && (c.exact || !fromMode(p));

function giftOfferSchema(lang, url, body) {
  const out = [];
  for (const p of PUBLISHED_GIFT_PACKAGES) {
    const title = lang === 'en' ? p.name_en : p.name;
    const description = (lang === 'en' ? p.description_en : p.description) || title;
    const price = p.is_open ? p.min_amount : p.price;
    if (!title || !(+price > 0) || !body.includes(`>${e(title)}`)) continue;
    out.push({
      '@context': 'https://schema.org', '@type': 'Product', '@id': `${url}#tuote-${p.code}`,
      name: title, description, image: abs('/img/og-hero-ovi-uusi.jpg'),
      brand: { '@id': abs('/#business') },
      offers: { '@type': 'Offer', priceCurrency: 'EUR', price: String(+price), availability: 'https://schema.org/InStock', url },
    });
  }
  return out;
}

/** Sivukohtaiset lisä-JSON-LD:t: Product+Offer näkyville hintakorteille, FAQPage infosivun näkyville kysymyksille. */
export function seoSchemaForPage({ lang, key, url, body = '' }) {
  const out = [];
  if (key === 'gift') out.push(...giftOfferSchema(lang, url, body));
  else if (key === 'treatments') {
    for (const p of treatmentOffers(lang)) {
      if (!p.exact || !p.name || !body.includes(`>${e(p.name)}`)) continue;
      out.push({
        '@context': 'https://schema.org', '@type': 'Product', '@id': `${url}#tuote-${p.id}`,
        name: p.name, description: p.description, image: abs('/img/og-hero-ovi-uusi.jpg'),
        brand: { '@id': abs('/#business') },
        offers: { '@type': 'Offer', priceCurrency: 'EUR', price: String(p.price), availability: 'https://schema.org/InStock', url },
      });
    }
  } else if (PRODUCT_PAGES.has(key)) {
    const seen = new Set();
    for (const g of CARD_GROUPS) for (const c of Object.values(cards[g] || {})) {
      if (!c?.kb || !(c.show || []).includes('price') || seen.has(c.kb)) continue;
      const p = bySlug(c.kb), title = liveCatalogName(c.kb, lang) || c[lang]?.title;
      if (!p || !title || !exactPrice(c, p) || !body.includes(`>${e(title)}`)) continue;
      seen.add(c.kb);
      out.push({
        '@context': 'https://schema.org', '@type': 'Product', '@id': `${url}#tuote-${p.id}`,
        name: title, description: c[lang]?.text || title, image: abs('/img/og-hero-ovi-uusi.jpg'),
        brand: { '@id': abs('/#business') },
        offers: { '@type': 'Offer', priceCurrency: 'EUR', price: String(+priceOf(p)), availability: 'https://schema.org/InStock', url },
      });
    }
  }
  if (key === 'treatments') {
    const all = treatmentFaq(lang).filter((x) => x.question && x.answer && body.includes(`<summary>${e(x.question)}</summary>`));
    if (all.length) out.push({ '@context': 'https://schema.org', '@type': 'FAQPage', '@id': `${url}#ukk`,
      mainEntity: all.map((x) => ({ '@type': 'Question', name: x.question, acceptedAnswer: { '@type': 'Answer', text: x.answer } })) });
  }
  if (key === 'info') {
    // UKK näkyy infosivulla <details><summary>…; sivun omat (suomenkieliset) id:t ratkaistaan kielelle kuten sivulla (kb-en.mjs),
    // ja mukaan vain samankieliset (ei suomenkielistä varatekstiä EN-sivun skeemaan), sivulla näkyvät kysymykset.
    const ids = pageDoc('info')?.[lang]?.faq || [];
    const all = ids.map((id) => faqFor(id, lang)).filter((x) => x && x.lang === lang && x.question && x.answer && body.includes(`<summary>${e(x.question)}</summary>`)).slice(0, 30);
    if (all.length) out.push({ '@context': 'https://schema.org', '@type': 'FAQPage', '@id': `${url}#ukk`,
      mainEntity: all.map((x) => ({ '@type': 'Question', name: x.question, acceptedAnswer: { '@type': 'Answer', text: x.answer } })) });
  }
  return out;
}
export const jsonLdScript = (schema) => `<script type="application/ld+json">${JSON.stringify(schema).replace(/</g, '\\u003c')}</script>`;

// Vanhat WordPress-polut → nykyiset polut. GitHub Pages ei anna HTTP 301:tä: HTML-sivu (meta refresh 0 + location.replace + linkki).
// Ohjaussivut ovat AINA noindex eivätkä ole sitemap.xml:ssä. Nykyisiä osoitteita ei muuteta; nykyinen polku ei koskaan jää ohjauksen alle.
export const legacyRedirects = Object.freeze({
  '/varaa-sauna/': '/varaa/',
  '/varaus/': '/varaa/',
  '/lahjakortit/': '/lahjakortti/',
  '/hinnasto/': '/saunavuorot/',
  '/yhteystiedot/': '/info/',
  '/saunahoidot/': '/hoidot-rituaalit/',
  '/yrityksille/': '/yritykset/',
  '/savusauna/': '/saunavuorot/',
});
/** Tarkistaa, ettei vanha polku ole nykyinen sivu ja että kohde on nykyinen sivu. Palauttaa [vanha, kohde]-parit. */
export function validLegacyRedirects(pages = site.pages) {
  const current = new Set(Object.values(pages).flatMap((x) => [x.fi, x.en]).filter(Boolean));
  return Object.entries(legacyRedirects).filter(([from, to]) => !current.has(from) && current.has(to));
}
// Ohjaussivun tekstit sivuteksteistä (content/site-texts.pending-import-44.json), varateksti = sama kuin tuontitiedostossa.
export const REDIRECT_TEXTS = Object.freeze({
  'ui.site.redirect_title': { fi: 'Sivu on siirtynyt', en: 'This page has moved' },
  'ui.site.redirect_text': { fi: 'Tämä vanha osoite ohjaa sivuston uuteen osoitteeseen.', en: 'This old address redirects to the new address of the website.' },
  'ui.site.redirect_link': { fi: 'Siirry uuteen osoitteeseen', en: 'Go to the new address' },
});
const quiet = { warn: () => {} };
const rt = (k, lang) => tx(k, lang, { fallback: REDIRECT_TEXTS[k][lang], log: quiet });
export function redirectHtml(target) {
  const full = abs(target);
  const fi = (k) => e(rt(k, 'fi')), en = (k) => e(rt(k, 'en'));
  return `<!doctype html><html lang="fi" data-redirect="legacy"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,follow"><link rel="canonical" href="${e(full)}"><meta name="description" content="${fi('ui.site.redirect_text')}"><meta http-equiv="refresh" content="0;url=${e(full)}"><title>${fi('ui.site.redirect_title')}</title><style>body{margin:0;padding:48px 20px;font-family:Georgia,serif;background:#F4EFE7;color:#2B3A30;text-align:center}a{color:#7A5530}</style><script>location.replace(${JSON.stringify(full).replace(/</g, '\\u003c')});</script></head><body><main><h1>${fi('ui.site.redirect_title')}</h1><p>${fi('ui.site.redirect_text')} <a href="${e(full)}">${fi('ui.site.redirect_link')}</a></p><p lang="en">${en('ui.site.redirect_text')} <a href="${e(full)}">${en('ui.site.redirect_link')}</a></p></main></body></html>`;
}
