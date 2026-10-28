// Etusivun elämyskortit ja lyhyet nauhat. Kortin nimi, kuvaus, hinta ja kuva tulevat tuotteesta
// (liveProduct = public_catalog tai kb-snapshot; kuva = public_product_images). Ei kovakoodattuja hintoja, tekstejä tai kuvia.
// Lahjakortti ei ole public_catalogissa: teksti ja hinta kb-tuotteesta, linkki lahjakorttisivun #avoin (ei /varaa/#/tuote/lahjakortti).
import { tx } from './site-texts.mjs';
import { site, e, pageHref, money, dur, priceOf, picture } from './lib.mjs';
import { liveProduct } from './catalog-live.mjs';
import { productImageFor, productImageUrl } from './product-images.mjs';
import { productImageHtml, CARD_WIDTHS, SIZES } from '../booking/shop/src/product-image.js';
import { shopHash } from './event-cards.mjs';
import { shortRaw, derivedExcerpt } from '../booking/shop/src/short-desc.js';
import { visibleText } from '../booking/shop/src/rich-view.js';
import { label, listHref, t as articleT } from './articles/config.mjs';

export const HOME_EXPERIENCES = Object.freeze([
  { slug: 'yleinensauna' },
  { slug: 'saunahoito-2' },
  { slug: 'oma-saunavuoro' },
  { slug: 'saunotus-2' },
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

function cardImage(p, lang, name, fallbackId) {
  const row = productImageFor(p.slug);
  const url = productImageUrl(row);
  if (url) {
    const alt = (row.alt && String(row.alt).trim()) || name;
    const w = row.width || 900, h = row.height || 600;
    return `<div class="im">${productImageHtml(url, { widths: CARD_WIDTHS, sizes: SIZES.home, alt, width: w, height: h, lazy: true })}</div>`;
  }
  if (!fallbackId) return '';
  return `<div class="im">${picture(fallbackId, { alt: name, sizes: '(min-width:1100px) 220px, 78vw' })}</div>`;
}

export function experienceHtml(lang) {
  const u = U(lang);
  const items = HOME_EXPERIENCES.map((spec) => {
    const p = liveProduct(spec.slug);
    if (!p) return '';
    const name = (lang === 'en' && p.name_en) || p.name || spec.slug;
    const img = cardImage(p, lang, name, spec.fallbackImg);
    const blurb = cardBlurb(p, lang);
    const durTxt = cardDuration(p, lang);
    const per = p.price_type === 'per_person' ? ` ${u.perPersonShort}` : '';
    const meta = `${u.fromWord} ${money(priceOf(p), lang)}${per}${durTxt ? ` · ${durTxt}` : ''}`;
    const cta = spec.cta === 'gift' ? homeText('ui.site.home_gift_cta', lang) : u.reserveArrow;
    return `<li class="card${img ? '' : ' noimg'}">${img}<div class="bd"><h3><a href="${e(experienceHref(spec, lang))}">${e(name)}</a></h3>${blurb ? `<p class="xp-desc">${e(blurb)}</p>` : ''}<p class="xp-meta">${e(meta)}</p></div><div class="cta" aria-hidden="true">${e(cta)}</div></li>`;
  }).join('');
  return `<header class="center"><h2 class="sec-title">${e(homeText('ui.site.home_choose_title', lang))}</h2></header><ul class="xp" aria-label="${e(homeText('ui.site.home_choose_title', lang))}">${items}</ul>`;
}

const RITUAL_SLUG = 'saunarituaali-ja-savusaunavuoro';
export function traditionHtml(lang, { kicker, title, cta, perPerson }) {
  const p = liveProduct(RITUAL_SLUG);
  const href = pageHref('book', lang, shopHash(p.slug));
  return `<div class="tradition"><p class="kicker">${e(kicker)}</p><h2 class="sec-title">${e(title)}</h2><p class="lead">${e(homeText('ui.site.home_tradition_lead', lang))}</p><p class="tradition-price">${e(money(p.price, lang))}<small>${e(perPerson)}</small></p><a class="btn gold" href="${e(href)}">${e(cta)}</a></div>`;
}

export function infoStrip(lang) {
  return `<div class="strip-row"><div><h2 class="sec-title">${e(label(lang))}</h2><p>${e(homeText('ui.site.home_info_lead', lang))}</p></div><a class="btn light" href="${e(listHref(lang))}">${e(articleT(lang, 'homeAll'))}</a></div>`;
}

export function companyStrip(lang, { title, cta, href }) {
  return `<div class="strip-row"><div><h2 class="sec-title">${e(title)}</h2><p>${e(homeText('ui.site.home_company_lead', lang))}</p></div><a class="btn light" href="${e(href)}">${e(cta)}</a></div>`;
}
