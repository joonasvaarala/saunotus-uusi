// Savusaunan musta viikko: suljettava yläbanneri (koko julkinen sivusto) ja etusivun mainoskortti.
// Oletuksena pois päältä. Näkyviin: MUSTA_VIIKKO_ENABLED = true TAI osoiteparametri ?preview=musta-viikko.
// Tuote ostettavissa vain suoralla lahjakorttilinkillä. Vaihda paketin koodi yhdestä paikasta: MUSTA_VIIKKO_PACKAGE.
import { tx } from './site-texts.mjs';
import { e, pageHref, money } from './lib.mjs';

/** Lahjakorttipaketin koodi (?paketti=). listed=false, näkyy vain suoralla linkillä. */
export const MUSTA_VIIKKO_PACKAGE = 'bf_jalkiloylyt_mato';

/** Kampanja valmiina kaikille kävijöille. Pidä false kunnes tuote on julkaistu linkillä. */
export const MUSTA_VIIKKO_ENABLED = false;

export const MUSTA_VIIKKO_PREVIEW = 'musta-viikko';
export const MUSTA_VIIKKO_STORAGE_KEY = 'saunotus:musta-viikko:dismissed';
export const MUSTA_VIIKKO_PRICE = 130;

/** Kampanja päättyy ma 30.11.2026 klo 10 (Eurooppa/Helsinki, UTC+2). Banneri, etusivun kortti ja myöhemmin kampanjasivu käyttävät tätä. */
export const MUSTA_VIIKKO_ENDS = '2026-11-30T10:00:00+02:00';
export function mustaViikkoActive(now = Date.now()) {
  const t = typeof now === 'number' ? now : Date.parse(now);
  return Number.isFinite(t) && t < Date.parse(MUSTA_VIIKKO_ENDS);
}

export const MUSTA_VIIKKO_TEXTS = Object.freeze({
  'ui.site.mv_title': { fi: 'Savusaunan musta viikko', en: 'Smoke Sauna Black Week' },
  'ui.site.mv_product': { fi: 'Jälkilöylylahjakortti', en: 'After Session Sauna gift card' },
  'ui.site.mv_banner_text': {
    fi: 'Jälkilöylylahjakortti {{var:price}}, voimassa 6 kk ma–to',
    en: 'After Session Sauna gift card {{var:price}}, valid 6 months Mon–Thu',
  },
  'ui.site.mv_close': { fi: 'Sulje ilmoitus', en: 'Dismiss notice' },
  'ui.site.mv_card_text': { fi: 'Voimassa 6 kk, ma–to', en: 'Valid 6 months, Mon–Thu' },
  'ui.site.mv_card_terms': { fi: 'Ei voimassa 24.–30.12.', en: 'Not valid 24–30 Dec.' },
  'ui.site.mv_cta': { fi: 'Osta lahjakortti →', en: 'Buy a gift card →' },
});

const quiet = { warn() {} };
const fillVars = (s, vars) => String(s ?? '').replace(/\{\{var:(\w+)\}\}/g, (_, k) => (vars && vars[k] != null ? vars[k] : `{{var:${k}}}`));
export const mvText = (key, lang, vars = null) => fillVars(
  tx(key, lang, { fallback: MUSTA_VIIKKO_TEXTS[key][lang] ?? MUSTA_VIIKKO_TEXTS[key].fi, log: quiet, vars }),
  vars,
);

export function mustaViikkoHref(lang) {
  return lang === 'en' ? '/en/black-week/' : '/musta-viikko/';
}

export function mustaViikkoPrice(lang) {
  return money(MUSTA_VIIKKO_PRICE, lang);
}

export function mustaViikkoBannerHtml(lang, now = Date.now()) {
  if (!mustaViikkoActive(now)) return '';
  const title = mvText('ui.site.mv_title', lang);
  const price = mustaViikkoPrice(lang);
  const text = mvText('ui.site.mv_banner_text', lang, { price });
  const close = mvText('ui.site.mv_close', lang);
  const href = mustaViikkoHref(lang);
  return `<div class="mv-banner" data-mv-banner hidden role="region" aria-label="${e(title)}"><div class="wrap mv-banner-in"><a class="mv-banner-link" href="${e(href)}"><strong>${e(title)}</strong><span class="mv-banner-sep" aria-hidden="true">–</span><span class="mv-banner-text">${e(text)}</span></a><button type="button" class="mv-banner-close" data-mv-close aria-label="${e(close)}"><span aria-hidden="true">×</span></button></div></div>`;
}

export function mustaViikkoCardHtml(lang, now = Date.now()) {
  if (!mustaViikkoActive(now)) return '';
  const title = mvText('ui.site.mv_title', lang);
  const product = mvText('ui.site.mv_product', lang);
  const text = mvText('ui.site.mv_card_text', lang);
  const terms = mvText('ui.site.mv_card_terms', lang);
  const cta = mvText('ui.site.mv_cta', lang);
  const price = mustaViikkoPrice(lang);
  const href = mustaViikkoHref(lang);
  return `<section class="section strip mv-sec" data-mv-promo hidden><div class="wrap"><a class="card mv-card" href="${e(href)}"><div class="mv-copy"><p class="kicker">${e(title)}</p><h2>${e(product)}</h2><p class="mv-note">${e(text)}</p><p class="mv-terms">${e(terms)}</p></div><div class="mv-actions"><p class="mv-price">${e(price)}</p><span class="btn gold sm">${e(cta)}</span></div></a></div></section>`;
}

export function mustaViikkoBootScript() {
  const enabled = MUSTA_VIIKKO_ENABLED ? 'true' : 'false';
  const preview = JSON.stringify(MUSTA_VIIKKO_PREVIEW);
  const key = JSON.stringify(MUSTA_VIIKKO_STORAGE_KEY);
  const ends = JSON.stringify(MUSTA_VIIKKO_ENDS);
  return `<script>(function(){if(Date.now()>=Date.parse(${ends}))return;var on=${enabled};try{on=on||new URLSearchParams(location.search).get('preview')===${preview}}catch(e){}if(!on)return;document.documentElement.classList.add('mv-on');document.querySelectorAll('[data-mv-promo]').forEach(function(el){el.hidden=false});var b=document.querySelector('[data-mv-banner]');if(!b)return;try{if(localStorage.getItem(${key}))return}catch(e){}b.hidden=false;var c=b.querySelector('[data-mv-close]');if(c)c.addEventListener('click',function(ev){ev.preventDefault();ev.stopPropagation();try{localStorage.setItem(${key},'1')}catch(e){}b.hidden=true})})();</script>`;
}
