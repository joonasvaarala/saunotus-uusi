// Etusivun elämyskortit ja lyhyet nauhat. Kortin nimi, kuvaus, hinta ja kuva tulevat tuotteesta
// (liveProduct = public_catalog tai kb-snapshot; kuva = public_product_images). Ei kovakoodattuja hintoja, tekstejä tai kuvia.
// Lahjakortti ei ole public_catalogissa: teksti ja hinta kb-tuotteesta, linkki lahjakorttisivun #avoin (ei /varaa/#/tuote/lahjakortti).
import { tx } from './site-texts.mjs';
import { alts } from './content-texts.mjs';
import { site, e, pageHref, money, dur, priceOf, picture } from './lib.mjs';
import { liveProduct } from './catalog-live.mjs';
import { productCardInner } from './product-card-image.mjs';
import { SIZES } from '../booking/shop/src/product-image.js';
import { shopHash } from './event-cards.mjs';
import { shortRaw, derivedExcerpt } from '../booking/shop/src/short-desc.js';
import { visibleText } from '../booking/shop/src/rich-view.js';
import { label, listHref, t as articleT } from './articles/config.mjs';
import { carePairSpec, careText } from './treatments-page.mjs';

const carePair = carePairSpec();
export const HOME_EXPERIENCES = Object.freeze([
  { slug: 'yleinensauna' },
  { pair: carePair.slugs, imageSlug: carePair.imageSlug, fallbackImg: carePair.fallbackImg },
  { slug: 'oma-saunavuoro' },
  { slug: 'jalkiloylyt', fallbackImg: 'j-jalkiloylyt' },
  { slug: 'lahjakortti', page: 'gift', hash: 'avoin', fallbackImg: 'j-avoin-lahjakortti', cta: 'gift' },
]);

export const HOME_TEXTS = Object.freeze({
  'ui.site.home_choose_title': { fi: 'Valitse elämys', en: 'Choose an experience' },
  'ui.site.home_week_soon': { fi: 'Tänään ja huomenna', en: 'Today and tomorrow' },
  'ui.site.home_week_all': { fi: 'Näytä koko viikko', en: 'Show the full week' },
  'ui.site.home_week_less': { fi: 'Näytä vain tänään ja huomenna', en: 'Show only today and tomorrow' },
  'ui.site.home_tradition_lead': {
    fi: 'Saunarituaali on ohjattu, vuodenaikojen mukaan elävä hetki hoitosauna Raunissa, ja sen jälkeen savusaunan löylyt. Saunotus juontaa juurensa suomalaiseen saunaperinteeseen.',
    en: 'The sauna ritual is a guided moment in the Rauni treatment sauna that changes with the seasons, followed by the smoke sauna. Saunotus is rooted in Finnish sauna tradition.',
  },
  'ui.site.home_info_lead': {
    fi: 'Tarinoita vihdasta, saunottajasta ja savusaunan perinteestä.',
    en: 'Stories about the birch whisk, the sauna practitioner and smoke-sauna tradition.',
  },
  'ui.site.home_company_lead': {
    fi: 'Rauhallinen savusauna työhyvinvointiin, pienryhmille ja yhteisiin iltoihin.',
    en: 'A calm smoke sauna for workplace wellbeing, small groups and shared evenings.',
  },
  'ui.site.home_gift_cta': { fi: 'Osta lahjaksi →', en: 'Buy as a gift →' },
  'ui.site.home_book_cta': { fi: 'Varaa saunavuoro →', en: 'Book a sauna →' },
});

const quiet = { warn() {} };
export const homeText = (key, lang) => tx(key, lang, { fallback: HOME_TEXTS[key][lang] ?? HOME_TEXTS[key].fi, log: quiet });
const U = (lang) => site.ui[lang];

export function experienceHref(spec, lang) {
  if (spec.page) return pageHref(spec.page, lang, spec.hash || '');
  return pageHref('book', lang, shopHash(spec.slug));
}

/** Keston näyttö kortin rivillä: lyhyt duration_text (ei vuorolistaa, jossa "klo"), muuten duration_minutes. */
export function cardDuration(p, lang) {
  const raw = lang === 'en' ? (p.duration_text_en || p.duration_text || '') : (p.duration_text || '');
  const s = String(raw).replace(/\s+/g, ' ').trim();
  if (s && s.length <= 40 && !/\bklo\b/i.test(s)) return s;
  return p.duration_minutes ? dur(p.duration_minutes) : '';
}

function cardBlurb(p, lang) {
  const raw = shortRaw(p, lang);
  const text = raw ? visibleText(raw).replace(/\s+/g, ' ').trim() : derivedExcerpt((lang === 'en' && p.description_en) || p.description || '');
  return text.replace(/\s+/g, ' ').trim();
}

function cardImage(p, name, fallbackId) {
  const fallbackHtml = fallbackId ? picture(fallbackId, { alt: name, sizes: SIZES.home }) : '';
  return productCardInner({ slug: p.slug, alt: name, fallbackHtml, sizes: SIZES.home });
}

function experienceMeta(p, lang) {
  const u = U(lang);
  const per = p.price_type === 'per_person' ? ` ${u.perPersonShort}` : '';
  const durTxt = cardDuration(p, lang);
  return `${u.fromWord} ${money(priceOf(p), lang)}${per}${durTxt ? ` · ${durTxt}` : ''}`;
}

function productName(p, lang, slug) {
  return (lang === 'en' && p.name_en) || p.name || slug;
}

function singleExperience(spec, lang) {
  const p = liveProduct(spec.slug);
  if (!p) return '';
  const u = U(lang);
  const name = productName(p, lang, spec.slug);
  const im = cardImage(p, name, spec.fallbackImg);
  const box = im.has ? `<div class="im"${im.attrs}>${im.html}</div>` : '';
  const host = im.has ? '' : im.attrs;
  const blurb = cardBlurb(p, lang);
  const cta = spec.cta === 'gift' ? homeText('ui.site.home_gift_cta', lang) : u.reserveArrow;
  return `<li class="card${box ? '' : ' noimg'}"${host}>${box}<div class="bd"><h3><a href="${e(experienceHref(spec, lang))}"><span data-catalog-name data-catalog-slug="${e(p.slug)}">${e(name)}</span></a></h3>${blurb ? `<p class="xp-desc">${e(blurb)}</p>` : ''}<p class="xp-meta">${e(experienceMeta(p, lang))}</p></div><div class="cta" aria-hidden="true">${e(cta)}</div></li>`;
}

function pairExperience(spec, lang) {
  const products = spec.pair.map((slug) => liveProduct(slug)).filter(Boolean);
  if (!products.length) return '';
  const title = careText('ui.site.care_pair_title', lang);
  const blurb = careText('ui.site.care_pair_text', lang);
  const imageProduct = liveProduct(spec.imageSlug) || products[0];
  const im = cardImage(imageProduct, title, spec.fallbackImg);
  const box = im.has ? `<div class="im"${im.attrs}>${im.html}</div>` : '';
  const host = im.has ? '' : im.attrs;
  const u = U(lang);
  const opts = products.map((p) => {
    const name = productName(p, lang, p.slug);
    return `<li><a class="xp-opt" data-testid="care-pair-option" data-slug="${e(p.slug)}" href="${e(experienceHref({ slug: p.slug }, lang))}"><span class="xp-opt-name" data-catalog-name data-catalog-slug="${e(p.slug)}">${e(name)}</span><span class="xp-meta">${e(experienceMeta(p, lang))}</span><span class="xp-opt-cta">${e(u.reserveArrow)}</span></a></li>`;
  }).join('');
  return `<li class="card xp-pair${box ? '' : ' noimg'}" data-testid="care-pair"${host}>${box}<div class="bd"><h3>${e(title)}</h3>${blurb ? `<p class="xp-desc">${e(blurb)}</p>` : ''}<ul class="xp-opts">${opts}</ul></div></li>`;
}

export function experienceHtml(lang) {
  const items = HOME_EXPERIENCES.map((spec) => (spec.pair ? pairExperience(spec, lang) : singleExperience(spec, lang))).join('');
  return `<header class="center"><h2 class="sec-title">${e(homeText('ui.site.home_choose_title', lang))}</h2></header><ul class="xp" aria-label="${e(homeText('ui.site.home_choose_title', lang))}">${items}</ul>`;
}

const RITUAL_SLUG = 'saunarituaali-ja-savusaunavuoro';
// Sama toimituksellinen kuva kuin etusivun aiemmassa tummassa rituaalibannerissa (pic('rituaali') ennen #218).
// Lähde content/images.json → public/img/rituaali-*.avif|webp. Alt on ui.alt.rituaali (content/alts.json).
const RITUAL_PHOTO = 'rituaali';
export function traditionHtml(lang, { kicker, title, cta, perPerson }) {
  const p = liveProduct(RITUAL_SLUG);
  const href = pageHref('book', lang, shopHash(p.slug));
  const photo = picture(RITUAL_PHOTO, { alt: alts[RITUAL_PHOTO]?.[lang] || '', sizes: '(min-width:900px) 640px, 100vw' });
  return `<div class="tradition"><div class="tradition-copy"><p class="kicker">${e(kicker)}</p><h2 class="sec-title">${e(title)}</h2><p class="lead">${e(homeText('ui.site.home_tradition_lead', lang))}</p><p class="tradition-price">${e(money(p.price, lang))}<small>${e(perPerson)}</small></p><a class="btn gold" href="${e(href)}">${e(cta)}</a></div><div class="tradition-photo">${photo}</div></div>`;
}

/** Arvostelujen ja Tapahtumat-osion väliin: varaus etusivun päätoimintona. */
export function homeBookCta(lang) {
  return `<p class="home-book"><a class="btn gold" href="${e(pageHref('book', lang))}">${e(homeText('ui.site.home_book_cta', lang))}</a></p>`;
}

export function infoStrip(lang) {
  return `<div class="strip-row"><div><h2 class="sec-title">${e(label(lang))}</h2><p>${e(homeText('ui.site.home_info_lead', lang))}</p></div><a class="btn light" href="${e(listHref(lang))}">${e(articleT(lang, 'homeAll'))}</a></div>`;
}

export function companyStrip(lang, { title, cta, href }) {
  return `<div class="strip-row"><div><h2 class="sec-title">${e(title)}</h2><p>${e(homeText('ui.site.home_company_lead', lang))}</p></div><a class="btn light" href="${e(href)}">${e(cta)}</a></div>`;
}
