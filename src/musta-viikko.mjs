// Savusaunan musta viikko: suljettava yläbanneri (koko julkinen sivusto) ja etusivun mainoskortti.
// Oletuksena pois päältä. Näkyviin: MUSTA_VIIKKO_ENABLED = true TAI osoiteparametri ?preview=musta-viikko.
// Tuote ostettavissa vain suoralla linkillä. Vaihda slug yhdestä paikasta: MUSTA_VIIKKO_SLUG.
import { tx } from './site-texts.mjs';
import { e, pageHref, money } from './lib.mjs';
import { shopHash } from './event-cards.mjs';

/** Kaupan tuotesivun slug. Vaihda tämä, kun Bottiavustus toimittaa lopullisen slugin. */
export const MUSTA_VIIKKO_SLUG = 'savusaunan-musta-viikko';

/** Kampanja valmiina kaikille kävijöille. Pidä false kunnes slug ja tuote ovat valmiit. */
export const MUSTA_VIIKKO_ENABLED = false;

export const MUSTA_VIIKKO_PREVIEW = 'musta-viikko';
export const MUSTA_VIIKKO_STORAGE_KEY = 'saunotus:musta-viikko:dismissed';
export const MUSTA_VIIKKO_PRICE = 130;

export const MUSTA_VIIKKO_TEXTS = Object.freeze({
  'ui.site.mv_title': { fi: 'Savusaunan musta viikko', en: 'Smoke Sauna Black Week' },
  'ui.site.mv_banner_text': {
    fi: 'Black Friday -lahjakortti, jälkilöylyt ma–to',
    en: 'Black Friday gift card, After Session Sauna Mon–Thu',
  },
  'ui.site.mv_close': { fi: 'Sulje ilmoitus', en: 'Dismiss notice' },
  'ui.site.mv_card_lead': { fi: 'Black Friday -lahjakortti', en: 'Black Friday gift card' },
  'ui.site.mv_card_text': { fi: 'Jälkilöylyt ma–to', en: 'After Session Sauna Mon–Thu' },
  'ui.site.mv_cta': { fi: 'Osta lahjakortti →', en: 'Buy a gift card →' },
});

const quiet = { warn() {} };
export const mvText = (key, lang) => tx(key, lang, { fallback: MUSTA_VIIKKO_TEXTS[key][lang] ?? MUSTA_VIIKKO_TEXTS[key].fi, log: quiet });

export function mustaViikkoHref(lang) {
  return pageHref('book', lang, shopHash(MUSTA_VIIKKO_SLUG));
}

export function mustaViikkoPrice(lang) {
  return money(MUSTA_VIIKKO_PRICE, lang);
}

export function mustaViikkoBannerHtml(lang) {
  const title = mvText('ui.site.mv_title', lang);
  const text = mvText('ui.site.mv_banner_text', lang);
  const price = mustaViikkoPrice(lang);
  const close = mvText('ui.site.mv_close', lang);
  const href = mustaViikkoHref(lang);
  return `<div class="mv-banner" data-mv-banner hidden role="region" aria-label="${e(title)}"><div class="wrap mv-banner-in"><a class="mv-banner-link" href="${e(href)}"><strong>${e(title)}</strong><span>${e(text)} · ${e(price)}</span></a><button type="button" class="mv-banner-close" data-mv-close aria-label="${e(close)}"><span aria-hidden="true">×</span></button></div></div>`;
}

export function mustaViikkoCardHtml(lang) {
  const title = mvText('ui.site.mv_title', lang);
  const lead = mvText('ui.site.mv_card_lead', lang);
  const text = mvText('ui.site.mv_card_text', lang);
  const cta = mvText('ui.site.mv_cta', lang);
  const price = mustaViikkoPrice(lang);
  const href = mustaViikkoHref(lang);
  return `<section class="section strip mv-sec" data-mv-promo hidden><div class="wrap"><a class="card mv-card" href="${e(href)}"><div class="mv-copy"><p class="kicker">${e(lead)}</p><h2>${e(title)}</h2><p class="mv-note">${e(text)}</p></div><div class="mv-actions"><p class="mv-price">${e(price)}</p><span class="btn gold sm">${e(cta)}</span></div></a></div></section>`;
}

export function mustaViikkoBootScript() {
  const enabled = MUSTA_VIIKKO_ENABLED ? 'true' : 'false';
  const preview = JSON.stringify(MUSTA_VIIKKO_PREVIEW);
  const key = JSON.stringify(MUSTA_VIIKKO_STORAGE_KEY);
  return `<script>(function(){var on=${enabled};try{on=on||new URLSearchParams(location.search).get('preview')===${preview}}catch(e){}if(!on)return;document.documentElement.classList.add('mv-on');document.querySelectorAll('[data-mv-promo]').forEach(function(el){el.hidden=false});var b=document.querySelector('[data-mv-banner]');if(!b)return;try{if(localStorage.getItem(${key}))return}catch(e){}b.hidden=false;var c=b.querySelector('[data-mv-close]');if(c)c.addEventListener('click',function(ev){ev.preventDefault();ev.stopPropagation();try{localStorage.setItem(${key},'1')}catch(e){}b.hidden=true})})();</script>`;
}
