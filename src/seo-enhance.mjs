// Paketti 11: Schema.org-lisäykset sivupohjiin + vanhojen WordPress-osoitteiden ohjaussivut.
// Ei riippuvuuksia eikä selaimen ajonaikaista JS:ää. Hinnat samasta kb:stä ja samalla laskulla kuin näkyvät korttihinnat
// (priceOf), ja tuote merkitään vain, jos sen kortti (otsikko) näkyy samalla sivulla. Hintoja ei muuteta.
// Ei aggregateRating-merkintää: arviot ovat Googlen (kolmannen osapuolen) arvioita, eikä niitä saa merkitä omaksi rakenteiseksi dataksi.
import { kb, abs, e, priceOf, fromMode, site } from './lib.mjs';
import { cards, pageDoc } from './content-texts.mjs';
import { faqFor } from './kb-en.mjs';
import { tx } from './site-texts.mjs';

// Sivut, joiden kortit saavat Product/Offer-merkinnän (sivuavain → korttiryhmät, joista kortteja voi näkyä)
const PRODUCT_PAGES = new Set(['sauna', 'treatments', 'gift']);
const CARD_GROUPS = ['sauna', 'treatments', 'gift'];
const bySlug = (slug) => kb.products.find((p) => p.slug === slug);
const exactPrice = (c, p) => Number.isFinite(+priceOf(p)) && +priceOf(p) > 0 && (c.exact || !fromMode(p));

/** Sivukohtaiset lisä-JSON-LD:t: Product+Offer näkyville hintakorteille, FAQPage infosivun näkyville kysymyksille. */
export function seoSchemaForPage({ lang, key, url, body = '' }) {
  const out = [];
  if (PRODUCT_PAGES.has(key)) {
    const seen = new Set();
    for (const g of CARD_GROUPS) for (const c of Object.values(cards[g] || {})) {
      if (!c?.kb || !(c.show || []).includes('price') || seen.has(c.kb)) continue;
      const p = bySlug(c.kb), title = c[lang]?.title;
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
