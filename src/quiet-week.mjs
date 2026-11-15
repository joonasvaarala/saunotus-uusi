// booking_162: hiljaisten aikojen ale sivuston viikko-ohjelmassa (etusivu + saunavuorot): tekstit (sivutekstit ui.site.quiet_*,
// varateksti = sama kuin content/site-texts.pending-import-59.json). Ale haetaan selaimessa (booking/shop/src/week-grid.js) public_quiet_offersista;
// tekstit viedään viikko-ohjelman data-vk-texts-attribuuttiin (src/week-grid.mjs).
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
