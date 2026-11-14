// Viikko-ohjelma rakennusvaiheessa (etusivu + saunavuorot): staattinen varaversio ilman JS:ää.
// Rakenne tulee kb.hours-tiedoista (viikonpäivät ilman päivämääriä, ei hintoja eikä vapaita aikoja). Selain (booking/shop/src/week-grid.js) korvaa sen
// live-datalla: päivämäärät, vapaat ajat, hinnat, hoidot, tapahtumat ja viikkonavigointi. Sama näkymä (week-grid-view.js) piirtää molemmat.
import { site, kb, e, bookingUrl, money } from './lib.mjs';
import { tx } from './site-texts.mjs';
import { liveCatalogName } from './catalog-live.mjs';
import { quietSiteText } from './quiet-week.mjs';
import { weekGridTexts } from '../booking/shop/src/week-grid-texts.js';
import { weekGridTree, toHtml } from '../booking/shop/src/week-grid-view.js';
import { HIDDEN_PUBLIC_SLUGS, HIDDEN_CARE_SLUGS } from '../booking/shop/src/week-grid-logic.js';

const quiet = { warn: () => {} };
/** Koulutukset-linkki kielen mukaan (Joonas t1776u): FI saunakoulutus.fi, EN saunahealer.com. */
export const TRAINING_URLS = Object.freeze({ fi: 'https://saunakoulutus.fi', en: 'https://saunahealer.com' });
export const trainingUrl = (lang) => TRAINING_URLS[lang] || TRAINING_URLS.fi;

export function gridTexts(lang) {
  const u = site.ui[lang];
  const tokens = (t) => String(t).replace(/\{\{var:(\w+)\}\}/g, '{$1}');
  return weekGridTexts((key, def) => tx(key, lang, { fallback: tokens(def[lang] ?? def.fi), vars: { n: '{n}', a: '{a}', b: '{b}' }, log: quiet }), {
    lang, daysLong: u.daysLong, today: u.today, newTab: u.openNewTab,
    quietBadge: quietSiteText('ui.site.quiet_badge', lang), quietSr: quietSiteText('ui.site.quiet_sr', lang),
  });
}

const clock = (t, lang) => { const [hh, mm] = String(t).slice(0, 5).split(':'); return `${Number(hh)}${lang === 'en' ? ':' : '.'}${mm}`; };

function staticModel(lang) {
  const prod = (id) => kb.products.find((x) => x.id === id);
  const own = prod(25);
  const days = [];
  for (let d = 1; d <= 7; d++) {
    const rows = kb.hours.filter((h) => h.weekday === d);
    const pub = rows.filter((h) => h.opens && h.closes && !['ritual', 'private_only'].includes(h.session_type)).map((h) => {
      const p = prod(h.product_id);
      if (!p || HIDDEN_PUBLIC_SLUGS.includes(p.slug)) return null;
      const lab = site.sessionLabels[d >= 6 && h.session_type === 'public' ? 'weekend' : h.session_type]?.[lang] || '';
      return { slug: p.slug, name: liveCatalogName(p.slug, lang) || lab, href: bookingUrl(p.booking_url, lang), time: `${clock(h.opens, lang)}–${clock(h.closes, lang)}`, price: p.price ? money(p.price, lang) : '', dur: '', low: null, full: false, chips: [] };
    }).filter(Boolean);
    const care = rows.filter((h) => h.session_type === 'ritual').map((h) => prod(h.product_id)).filter((p) => p && !HIDDEN_CARE_SLUGS.includes(p.slug))
      .map((p) => ({ name: liveCatalogName(p.slug, lang) || site.sessionLabels.ritual[lang], href: bookingUrl(p.booking_url, lang) }));
    days.push({ wd: d, date: null, public: pub, publicNone: rows.some((h) => h.session_type === 'private_only') && !pub.length, own: own ? { href: bookingUrl(own.booking_url, lang), price: '', was: '', pct: '', full: false } : null, after: [], care, events: [] });
  }
  return { start: null, end: null, week: null, range: '', todayIdx: -1, days, hasEvents: false, careLater: false, nav: { prev: false, next: false, now: false }, hint: [], error: false };
}

/** opt: { heading: true → kicker + otsikko (etusivu), links: { all } (etusivu), moreHref }. */
export function weekGrid(lang, opt = {}) {
  const u = site.ui[lang], T = gridTexts(lang);
  const o = { heading: opt.heading ? { kicker: u.weekKicker, title: T.title } : null, links: opt.links ? { training: trainingUrl(lang), all: opt.links.all } : null };
  // data-quiet-week: build lisää kaupan skriptin (quiet-week.js) sivulle. data-vk-texts = koko tekstisanakirja (myös ale-tekstit) selaimelle.
  const root = `<div class="vk" data-vk data-quiet-week data-vk-opts="${e(JSON.stringify(o))}" data-vk-texts="${e(JSON.stringify(T))}">`;
  return `${root}${weekGridTree(staticModel(lang), T, o).map(toHtml).join('')}</div>`;
}
