// Savusaunan musta viikko – kampanjasivu /musta-viikko/ ja /en/black-week/.
// Ei navigointi- eikä sivukarttalinkkejä. Julkaistaan suoralla osoitteella (noindex,nofollow, ei JSON-LD).
import { tx } from './site-texts.mjs';
import { e, pageHref, money } from './lib.mjs';
import { mustaViikkoPicture, MUSTA_VIIKKO_IMAGE_ALT } from './musta-viikko.mjs';

/** Kampanja päättyy ma 30.11.2026 klo 10 (Eurooppa/Helsinki, UTC+2). */
export const MUSTA_VIIKKO_ENDS = '2026-11-30T10:00:00+02:00';

export function mustaViikkoActive(now = Date.now()) {
  const t = typeof now === 'number' ? now : Date.parse(now);
  return Number.isFinite(t) && t < Date.parse(MUSTA_VIIKKO_ENDS);
}

/** Pakettikoodit (?paketti=). Nimet ja ehdot tulevat teksteistä (sama sanamuoto kuin kannassa). */
export const MUSTA_VIIKKO_OFFERS = Object.freeze([
  { code: 'bf_jalkiloylyt_mato', price: 130, nameKey: 'ui.site.mvp_a_name', termsKey: 'ui.site.mvp_a_terms' },
  { code: 'mv_yleiset_mato', price: 50, nameKey: 'ui.site.mvp_b_name', termsKey: 'ui.site.mvp_b_terms' },
]);

export const MUSTA_VIIKKO_PAGE_TEXTS = Object.freeze({
  'ui.site.mvp_kicker': { fi: 'Kampanja', en: 'Campaign' },
  'ui.site.mvp_title': { fi: 'Savusaunan musta viikko', en: 'Smoke Sauna Black Week' },
  'ui.site.mvp_lead': {
    fi: 'Kaksi lahjakorttia, voimassa 6 kuukautta arkisin ma–to.',
    en: 'Two gift cards, valid for 6 months on weekdays Mon–Thu.',
  },
  'ui.site.mvp_meta_title': {
    fi: 'Savusaunan musta viikko | Sipoonjoen Perinnesauna',
    en: 'Smoke Sauna Black Week | Sipoonjoki Heritage Sauna',
  },
  'ui.site.mvp_meta_desc': {
    fi: 'Jälkilöylylahjakortti 130 € ja yleisten vuorojen lahjakortti 2 hengelle 50 €. Voimassa 6 kk, ma–to.',
    en: 'After Session Sauna gift card €130 and a public session gift card for 2 people €50. Valid 6 months, Mon–Thu.',
  },
  'ui.site.mvp_a_name': { fi: 'Jälkilöylylahjakortti', en: 'After Session Sauna gift card' },
  'ui.site.mvp_a_terms': {
    fi: 'Voimassa 6 kk, ma–to. Ei voimassa 24.–30.12.',
    en: 'Valid 6 months, Mon–Thu. Not valid 24–30 Dec.',
  },
  'ui.site.mvp_b_name': { fi: 'Yleisten vuorojen lahjakortti 2 hengelle', en: 'Public session gift card for 2 people' },
  'ui.site.mvp_b_terms': {
    fi: 'Voimassa 6 kk, ma–to. 2 henkeä, voi käyttää kahdessa osassa. Ei voimassa 24.–30.12. Turvetorstaina maksetaan erotus.',
    en: 'Valid 6 months, Mon–Thu. 2 people, can be used in two parts. Not valid 24–30 Dec. On Peat Thursday the difference is paid.',
  },
  'ui.site.mvp_cta': { fi: 'Osta lahjakortti', en: 'Buy a gift card' },
  'ui.site.mvp_ended': { fi: 'Musta viikko on päättynyt', en: 'Black Week has ended' },
  'ui.site.mvp_ended_lead': {
    fi: 'Kampanja ei ole enää käynnissä. Voit tutustua saunaan etusivulla tai ostaa lahjakortin tavallisesta valikoimasta.',
    en: 'This campaign is no longer running. You can explore the sauna on the homepage or buy a gift card from our regular selection.',
  },
  'ui.site.mvp_ended_home': { fi: 'Etusivulle', en: 'To the homepage' },
  'ui.site.mvp_ended_gift': { fi: 'Lahjakortteihin', en: 'To gift cards' },
});

const quiet = { warn() {} };
export const mvpText = (key, lang) => tx(key, lang, {
  fallback: MUSTA_VIIKKO_PAGE_TEXTS[key][lang] ?? MUSTA_VIIKKO_PAGE_TEXTS[key].fi,
  log: quiet,
});

export function mustaViikkoOfferHref(code, lang) {
  return `${pageHref('gift', lang)}?paketti=${encodeURIComponent(code)}`;
}

export function mustaViikkoMeta(lang) {
  return { title: mvpText('ui.site.mvp_meta_title', lang), description: mvpText('ui.site.mvp_meta_desc', lang) };
}

function offersHtml(lang) {
  return `<div class="mvp-offers" data-mvp-offers>${MUSTA_VIIKKO_OFFERS.map((o) => {
    const href = mustaViikkoOfferHref(o.code, lang);
    return `<article class="mvp-offer" data-mvp-offer="${e(o.code)}"><h2>${e(mvpText(o.nameKey, lang))}</h2><p class="mvp-terms">${e(mvpText(o.termsKey, lang))}</p><p class="mvp-price">${e(money(o.price, lang))}</p><p class="mvp-cta"><a class="btn gold" href="${e(href)}">${e(mvpText('ui.site.mvp_cta', lang))}</a></p></article>`;
  }).join('')}</div>`;
}

function endedHtml(lang, { hidden = false } = {}) {
  return `<div class="mvp-ended" data-mvp-ended${hidden ? ' hidden' : ''}><h2>${e(mvpText('ui.site.mvp_ended', lang))}</h2><p class="mvp-ended-lead">${e(mvpText('ui.site.mvp_ended_lead', lang))}</p><p class="mvp-ended-actions"><a class="btn gold" href="${pageHref('home', lang)}">${e(mvpText('ui.site.mvp_ended_home', lang))}</a><a class="btn ghost" href="${pageHref('gift', lang)}">${e(mvpText('ui.site.mvp_ended_gift', lang))}</a></p></div>`;
}

export function mustaViikkoBootScript() {
  const ends = JSON.stringify(MUSTA_VIIKKO_ENDS);
  return `<script>(function(){if(Date.now()<Date.parse(${ends}))return;var o=document.querySelector('[data-mvp-offers]');var n=document.querySelector('[data-mvp-ended]');if(o)o.hidden=true;if(n)n.hidden=false})();</script>`;
}

export function mustaViikkoBody(lang, now = Date.now()) {
  const active = mustaViikkoActive(now);
  const title = mvpText('ui.site.mvp_title', lang);
  const alt = MUSTA_VIIKKO_IMAGE_ALT[lang] || MUSTA_VIIKKO_IMAGE_ALT.fi;
  const pic = mustaViikkoPicture({ alt, cls: 'mvp-hero-img', loading: 'eager', fetchpriority: 'high', sizes: '100vw' });
  const hero = `<header class="mvp-hero"><div class="mvp-hero-media">${pic}</div><div class="mvp-hero-in"><p class="kicker">${e(mvpText('ui.site.mvp_kicker', lang))}</p><h1>${e(title)}</h1><p class="mvp-lead">${e(mvpText('ui.site.mvp_lead', lang))}</p></div></header>`;
  const inner = active
    ? `${offersHtml(lang)}${endedHtml(lang, { hidden: true })}${mustaViikkoBootScript()}`
    : `${endedHtml(lang)}`;
  return `<section class="mvp" data-mvp aria-label="${e(title)}">${hero}<div class="wrap">${inner}</div></section>`;
}
