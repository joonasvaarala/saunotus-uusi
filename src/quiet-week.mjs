// booking_162: hiljaisten aikojen ale sivuston viikko-ohjelmassa (etusivu + saunavuorot). Rakennusvaiheessa vain data-attribuutit:
// tekstit (sivutekstit ui.site.quiet_*, varateksti = sama kuin content/site-texts.pending-import-59.json) ja yksityisvuorotuotteiden nimet/slugit.
// Ajonaikainen lisäys: booking/shop/src/quiet-week.js. Vapaat jälkilöylyt (kb 26) haetaan public_availabilitysta;
// hiljaisen ajan ale public_quiet_offersista. Jos kumpikaan haku ei onnistu, viikko-ohjelma ei muutu.
import { tx } from './site-texts.mjs';

export const QUIET_SITE_TEXTS = Object.freeze({
  'ui.site.quiet_badge': { fi: '−{{var:pct}} %', en: '−{{var:pct}}%' },
  'ui.site.quiet_sr': { fi: 'Hiljaisen ajan ale {{var:pct}} %: normaalihinta {{var:was}}, nyt {{var:now}}.', en: 'Quiet-time discount {{var:pct}}%: regular price {{var:was}}, now {{var:now}}.' },
  'ui.site.quiet_note': {
    fi: 'Hiljaisen ajan ale: vielä vapaat yksityisvuorot lähipäivinä alennettuun hintaan. Hinta lukitaan, kun teet varauksen.',
    en: 'Quiet-time discount: private sessions still available in the next few days at a reduced price. The price is locked when you book.',
  },
});
const quiet = { warn: () => {} };
// {{var:x}} → {x}: selain täyttää prosentin ja hinnat (sama muoto kuin kaupan teksteissä).
const KEEP = { pct: '{pct}', was: '{was}', now: '{now}' };
const varTokens = (s) => String(s).replace(/\{\{var:(\w+)\}\}/g, '{$1}');
export const quietSiteText = (key, lang) => tx(key, lang, { fallback: varTokens(QUIET_SITE_TEXTS[key][lang] ?? QUIET_SITE_TEXTS[key].fi), vars: KEEP, log: quiet });

// Yksityisvuorotuotteet: kb.products.category = 'private_sauna' (booking_163:n jälkeen booking_url osoittaa uuteen kauppaan,
// joten vanha Johku-polku /yksityisvuorot/ on vain varalla).
/** Viikko-ohjelman <ol>-elementin attribuutit (HTML-escapattuina). products = kb.products, name = (p) => nimi kielellä. */
export function quietWeekAttrs(lang, { esc, products, reserve }) {
  const map = Object.fromEntries((products || []).filter((p) => (p.category === 'private_sauna' || /\/yksityisvuorot\//.test(p.booking_url || '')) && p.slug)
    .map((p) => [p.id, { n: (lang === 'en' && p.name_en) || p.name, s: p.slug }]));
  const a = { badge: quietSiteText('ui.site.quiet_badge', lang), sr: quietSiteText('ui.site.quiet_sr', lang), note: quietSiteText('ui.site.quiet_note', lang), reserve, products: JSON.stringify(map) };
  return ` data-quiet-week${Object.entries(a).map(([k, v]) => ` data-quiet-${k}="${esc(v)}"`).join('')}`;
}
