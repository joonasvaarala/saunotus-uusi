// Etusivun "Varaa verkosta" -osio (Joonas 24.10.2026): jokainen uudessa kaupassa varattava tuote näkyy etusivulla ja linkki vie kaupan
// tuotesivulle (FI /varaa/#/tuote/<slug>, EN /en/book/#/tuote/<slug>; yritystuotteet /yritykset/#/tuote/<slug>). Ei Johku-linkkejä.
// Tuotelista = tuotannon booking.public_catalog() 24.10.2026 (15 tuotetta; SELECT, sxbofnuisemspgquoxyv). Uusi varattava tuote lisätään tähän;
// booking/tests/linkit-kauppaan.test.mjs tarkistaa, että jokainen slug on kb-snapshotissa ja etusivulla.
// Tekstit sivuteksteistä (content/site-texts.pending-import-58.json, FI+EN); varateksti = sama kuin tuontitiedostossa.
import { tx } from './site-texts.mjs';

export const SHOP_PRODUCT_GROUPS = Object.freeze([
  { key: 'public_sauna', slugs: ['yleinensauna', 'tunnin-vuoro', 'miestensauna-2', 'naistensauna', 'hiljainen-sauna', 'turvetorstai'] },
  { key: 'private_sauna', slugs: ['oma-saunavuoro', 'jalkiloylyt'] },
  { key: 'ritual', slugs: ['saunarituaali-ja-savusaunavuoro', 'saunotusrituaali'] },
  { key: 'treatment', slugs: ['saunahoito-2', 'saunotus-2', 'syvasaunotus'] },
  { key: 'corporate', page: 'companies', slugs: ['saunavuoro-yrityksille', 'jalkiloylyt-yrityksille'] },
]);
export const SHOP_PRODUCT_SLUGS = Object.freeze(SHOP_PRODUCT_GROUPS.flatMap((g) => g.slugs));

export const SHOP_PRODUCT_TEXTS = Object.freeze({
  'ui.site.shop_products_title': { fi: 'Varaa verkosta', en: 'Book online' },
  'ui.site.shop_products_lead': { fi: 'Kaikki verkossa varattavat saunavuorot, rituaalit ja hoidot. Valitse tuote, niin pääset suoraan varaamaan.', en: 'All sauna sessions, rituals and treatments you can book online. Choose one to go straight to booking.' },
  'ui.site.shop_products_group_public_sauna': { fi: 'Yleiset saunavuorot', en: 'Public sauna sessions' },
  'ui.site.shop_products_group_private_sauna': { fi: 'Yksityisvuorot', en: 'Private sessions' },
  'ui.site.shop_products_group_ritual': { fi: 'Rituaalit', en: 'Rituals' },
  'ui.site.shop_products_group_treatment': { fi: 'Hoidot', en: 'Treatments' },
  'ui.site.shop_products_group_corporate': { fi: 'Yrityksille', en: 'For companies' },
  'ui.site.shop_products_all': { fi: 'Kaikki varattavat', en: 'Everything bookable' },
});
const quiet = { warn: () => {} };
const t = (k, lang) => tx(k, lang, { fallback: SHOP_PRODUCT_TEXTS[k][lang] ?? SHOP_PRODUCT_TEXTS[k].fi, log: quiet });

/** Osion sisältö. o = { esc, pageHref, product(slug) → kb-tuote|null, head(kicker, title, lead, opt) } */
export function shopProductsHtml(lang, o) {
  const name = (p) => (lang === 'en' && p.name_en) || p.name;
  const groups = SHOP_PRODUCT_GROUPS.map((g) => {
    const items = g.slugs.map((s) => o.product(s)).filter(Boolean)
      .map((p) => `<li><a href="${o.pageHref(g.page || 'book', lang, '/tuote/' + encodeURIComponent(p.slug))}">${o.esc(name(p))}</a></li>`).join('');
    return items ? `<div class="shopgrp"><h3>${o.esc(t('ui.site.shop_products_group_' + g.key, lang))}</h3><ul>${items}</ul></div>` : '';
  }).join('');
  return `${o.head('', t('ui.site.shop_products_title', lang), t('ui.site.shop_products_lead', lang), { orn: true })}<div class="shopgrps">${groups}</div>`
    + `<p class="center" style="margin-top:26px"><a class="btn light sm" href="${o.pageHref('book', lang)}">${o.esc(t('ui.site.shop_products_all', lang))}</a></p>`;
}
