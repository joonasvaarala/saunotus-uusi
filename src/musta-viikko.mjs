// Savusaunan musta viikko: suljettava yläbanneri (koko julkinen sivusto) ja etusivun kuvallinen mainos.
// Tuotantobuild (SITE_ENV=prod): banneria ja mainosta ei kirjoiteta sivuun. Testibuild (SITE_ENV=test,
// GitHub Pages / DEV-kanta): päällä kampanja-ajan. Muussa ympäristössä näkyviin ?preview=musta-viikko.
// Ostolinkit: suorat ?paketti=-osoitteet. Kampanjasivu: /musta-viikko/ ja /en/black-week/.
import { tx } from './site-texts.mjs';
import { e, pageHref, money, href } from './lib.mjs';
import { regularListPrice } from '../booking/shop/src/gift-logic.js';

/** Lahjakorttipaketin koodi yläbannerin vanhassa vakiossa ja jälkilöylytarjouksessa (?paketti=). */
export const MUSTA_VIIKKO_PACKAGE = 'bf_jalkiloylyt_mato';
export const MUSTA_VIIKKO_PACKAGE_YLEISET = 'mv_yleiset_mato';

/** @deprecated käytä mustaViikkoEnvOn(); säilytetään testeille: ilman SITE_ENV=test arvo on false. */
export const MUSTA_VIIKKO_ENABLED = false;

export const MUSTA_VIIKKO_PREVIEW = 'musta-viikko';
export const MUSTA_VIIKKO_STORAGE_KEY = 'saunotus:musta-viikko:dismissed';
export const MUSTA_VIIKKO_PRICE = 130;
export const MUSTA_VIIKKO_PRICE_YLEISET = 50;

/** Kampanja päättyy ma 30.11.2026 klo 10 (Eurooppa/Helsinki, UTC+2). */
export const MUSTA_VIIKKO_ENDS = '2026-11-30T10:00:00+02:00';
export function mustaViikkoActive(now = Date.now()) {
  const t = typeof now === 'number' ? now : Date.parse(now);
  return Number.isFinite(t) && t < Date.parse(MUSTA_VIIKKO_ENDS);
}

/** Testibuildissa banneri ja mainos ovat päällä. Tuotannossa eivät. */
export function mustaViikkoEnvOn(env = process.env.SITE_ENV) {
  return String(env ?? '').trim() === 'test';
}
/** Tuotantobuild ei sisällä bannerin tai mainoksen HTML:ää eikä boot-skriptiä. */
export function mustaViikkoBuildIncludes(env = process.env.SITE_ENV) {
  return String(env ?? '').trim() !== 'prod';
}

/** Etusivun mainoksen ja kampanjasivun heron kuva (kuvankäsittelijän tumma toimitus). */
export const MUSTA_VIIKKO_IMAGE = 'mv-mainos';
export const MUSTA_VIIKKO_IMAGE_BP = 700;
export const MUSTA_VIIKKO_IMAGE_SIZE = { w: 1600, h: 700 };
export const MUSTA_VIIKKO_IMAGE_MOBILE_SIZE = { w: 900, h: 1100 };
export const MUSTA_VIIKKO_IMAGE_ALT = Object.freeze({
  fi: 'Ihmisiä istuu noen mustaamilla lauteilla Sipoonjoen perinnesaunan savusaunassa; holvikatto, savuluukku ja palavat kynttilät.',
  en: 'People sitting on the soot-blackened benches of the Sipoonjoki traditional smoke sauna, with its barrel vault, smoke hatch and burning candles.',
});

export const MUSTA_VIIKKO_OFFERS = Object.freeze([
  { code: MUSTA_VIIKKO_PACKAGE, price: MUSTA_VIIKKO_PRICE, nameKey: 'ui.site.mv_product', textKey: 'ui.site.mv_card_text' },
  { code: MUSTA_VIIKKO_PACKAGE_YLEISET, price: MUSTA_VIIKKO_PRICE_YLEISET, nameKey: 'ui.site.mv_product_b', textKey: 'ui.site.mv_card_text' },
]);

export const MUSTA_VIIKKO_TEXTS = Object.freeze({
  'ui.site.mv_title': { fi: 'Savusaunan musta viikko', en: 'Smoke Sauna Black Week' },
  'ui.site.mv_product': { fi: 'Jälkilöylylahjakortti', en: 'After Session Sauna gift card' },
  'ui.site.mv_product_b': { fi: 'Yleisten vuorojen lahjakortti 2 hengelle', en: 'Public session gift card for 2 people' },
  'ui.site.mv_banner_offers': {
    fi: 'jälkilöylyt ja yleiset vuorot lahjakorttina ma–to',
    en: 'After Session and public session gift cards, Mon–Thu',
  },
  'ui.site.mv_close': { fi: 'Sulje ilmoitus', en: 'Dismiss notice' },
  'ui.site.mv_card_text': { fi: 'Voimassa 6 kk, ma–to', en: 'Valid 6 months, Mon–Thu' },
  'ui.site.mv_card_terms': { fi: 'Ei voimassa 24.–30.12.', en: 'Not valid 24–30 Dec.' },
  'ui.site.mv_cta': { fi: 'Osta lahjakortti →', en: 'Buy a gift card →' },
  'ui.site.mv_more': { fi: 'Tutustu kampanjaan', en: 'See the campaign' },
  'ui.site.mv_see': { fi: 'Katso tarjoukset →', en: 'See the offers →' },
  'ui.site.mv_regular': { fi: 'Normaalihinta {{var:price}}', en: 'Regular price {{var:price}}' },
});

const quiet = { warn() {} };
const fillVars = (s, vars) => String(s ?? '').replace(/\{\{var:(\w+)\}\}/g, (_, k) => (vars && vars[k] != null ? vars[k] : `{{var:${k}}}`));
export const mvText = (key, lang, vars = null) => fillVars(
  tx(key, lang, { fallback: MUSTA_VIIKKO_TEXTS[key][lang] ?? MUSTA_VIIKKO_TEXTS[key].fi, log: quiet, vars }),
  vars,
);

export function mustaViikkoHref(lang) {
  return pageHref('mustaViikko', lang);
}

export function mustaViikkoPrice(lang, amount = MUSTA_VIIKKO_PRICE) {
  return money(amount, lang);
}

/** Kampanjahinta + yliviivattu normaalihinta (saavutettava del). */
export function mustaViikkoPriceCompareHtml(lang, campaign, code) {
  const now = mustaViikkoPrice(lang, campaign);
  const was = regularListPrice(code);
  if (was == null || was <= campaign) return `<span class="mv-price-now">${e(now)}</span>`;
  const wasTxt = mustaViikkoPrice(lang, was);
  const label = mvText('ui.site.mv_regular', lang, { price: wasTxt });
  return `<span class="mv-price-now">${e(now)}</span> <del class="mv-price-was"><span class="sr">${e(label)}</span><span aria-hidden="true">${e(wasTxt)}</span></del>`;
}

export function mustaViikkoOfferHref(code, lang) {
  const base = pageHref('gift', lang);
  const q = `paketti=${encodeURIComponent(code)}`;
  return base.includes('?') ? `${base}&${q}` : `${base}?${q}`;
}

export function mustaViikkoPicture({ alt = '', sizes = '100vw', cls = 'mv-ad-img', loading = 'lazy', fetchpriority } = {}) {
  const id = MUSTA_VIIKKO_IMAGE;
  const bp = `(max-width:${MUSTA_VIIKKO_IMAGE_BP}px)`;
  const set = (kind, ext, w1, w2) => `${href(`/img/${id}-${kind}.${ext}`)} ${w1}w, ${href(`/img/${id}-${kind}@2x.${ext}`)} ${w2}w`;
  const { w, h } = MUSTA_VIIKKO_IMAGE_SIZE;
  const prio = fetchpriority ? ` fetchpriority="${e(fetchpriority)}"` : '';
  return `<picture><source type="image/webp" media="${bp}" srcset="${set('mobiili', 'webp', 900, 1800)}" sizes="${sizes}"><source type="image/jpeg" media="${bp}" srcset="${set('mobiili', 'jpg', 900, 1800)}" sizes="${sizes}"><source type="image/webp" srcset="${set('desktop', 'webp', 1600, 3200)}" sizes="${sizes}"><img src="${href(`/img/${id}-desktop.jpg`)}" srcset="${set('desktop', 'jpg', 1600, 3200)}" sizes="${sizes}" width="${w}" height="${h}" alt="${e(alt)}" class="${e(cls)}" loading="${e(loading)}" decoding="async"${prio}></picture>`;
}

export function mustaViikkoBannerHtml(lang, now = Date.now(), env = process.env.SITE_ENV) {
  if (!mustaViikkoBuildIncludes(env) || !mustaViikkoActive(now)) return '';
  const title = mvText('ui.site.mv_title', lang);
  const text = mvText('ui.site.mv_banner_offers', lang);
  const see = mvText('ui.site.mv_see', lang);
  const close = mvText('ui.site.mv_close', lang);
  const hrefPage = mustaViikkoHref(lang);
  return `<div class="mv-banner" data-mv-banner hidden role="region" aria-label="${e(title)}"><div class="wrap mv-banner-in"><a class="mv-banner-link" href="${e(hrefPage)}"><strong>${e(title)}</strong><span class="mv-banner-sep" aria-hidden="true">–</span><span class="mv-banner-text">${e(text)}</span><span class="mv-banner-cta">${e(see)}</span></a><button type="button" class="mv-banner-close" data-mv-close aria-label="${e(close)}"><span aria-hidden="true">×</span></button></div></div>`;
}

export function mustaViikkoCardHtml(lang, now = Date.now(), env = process.env.SITE_ENV) {
  if (!mustaViikkoBuildIncludes(env) || !mustaViikkoActive(now)) return '';
  const title = mvText('ui.site.mv_title', lang);
  const see = mvText('ui.site.mv_see', lang);
  const page = mustaViikkoHref(lang);
  const alt = MUSTA_VIIKKO_IMAGE_ALT[lang] || MUSTA_VIIKKO_IMAGE_ALT.fi;
  const pic = mustaViikkoPicture({ alt, sizes: '(min-width:701px) 1100px, 100vw' });
  const offers = MUSTA_VIIKKO_OFFERS.map((o) => {
    const name = mvText(o.nameKey, lang);
    const text = mvText(o.textKey, lang);
    return `<article class="mv-ad-offer"><h3>${e(name)}</h3><p class="mv-note">${e(text)}</p><p class="mv-price">${mustaViikkoPriceCompareHtml(lang, o.price, o.code)}</p></article>`;
  }).join('');
  return `<section class="section strip mv-sec" data-mv-promo hidden><div class="wrap"><div class="mv-ad"><div class="mv-ad-visual"><div class="mv-ad-media">${pic}</div></div><div class="mv-ad-body"><h2 class="mv-ad-title"><a href="${e(page)}">${e(title)}</a></h2><div class="mv-ad-offers">${offers}</div><p class="mv-ad-cta"><a class="btn gold" href="${e(page)}">${e(see)}</a></p></div></div></div></section>`;
}

export function mustaViikkoBootScript(env = process.env.SITE_ENV) {
  if (!mustaViikkoBuildIncludes(env)) return '';
  const enabled = mustaViikkoEnvOn(env) ? 'true' : 'false';
  const preview = JSON.stringify(MUSTA_VIIKKO_PREVIEW);
  const key = JSON.stringify(MUSTA_VIIKKO_STORAGE_KEY);
  const ends = JSON.stringify(MUSTA_VIIKKO_ENDS);
  return `<script>(function(){if(Date.now()>=Date.parse(${ends}))return;var on=${enabled};try{on=on||new URLSearchParams(location.search).get('preview')===${preview}}catch(e){}if(!on)return;document.documentElement.classList.add('mv-on');document.querySelectorAll('[data-mv-promo]').forEach(function(el){el.hidden=false});var b=document.querySelector('[data-mv-banner]');if(!b)return;try{if(localStorage.getItem(${key}))return}catch(e){}b.hidden=false;var c=b.querySelector('[data-mv-close]');if(c)c.addEventListener('click',function(ev){ev.preventDefault();ev.stopPropagation();try{localStorage.setItem(${key},'1')}catch(e){}b.hidden=true})})();</script>`;
}
