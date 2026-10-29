// Hallinnan navigaation, yläpalkin, pikahaun ja Tilaukset-näkymän tekstit (FI + EN). Avaimet: ui.admin.nav.* (paketti 05).
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu, rivi puuttuu tai paikkamerkki ei täyty → NAV_TEXTS.
// Tuonti: content/site-texts.pending-import-38.json (alkuperäiset avaimet) ja
// content/site-texts.pending-import-88.json (ryhmien ja välilehtien nimet). Ei ylikirjoita olemassa olevia.
import { getLang } from './talous-i18n.js';
import { getSiteTexts } from './site-texts-cache.js';

export const PREFIX = 'ui.admin.nav.';

export const NAV_TEXTS = {
  fi: {
    'ui.admin.nav.orders': 'Tilaukset',
    'ui.admin.nav.reservations': 'Varaukset',
    'ui.admin.nav.orders_tabs': 'Tilaukset ja varaukset',
    'ui.admin.nav.loading': 'Ladataan…',
    'ui.admin.nav.load_failed': 'Näkymän lataus epäonnistui: {{var:error}}',
    'ui.admin.nav.search_label': 'Pikahaku',
    'ui.admin.nav.search_open': 'Avaa pikahaku',
    'ui.admin.nav.search_placeholder': 'Hae nimeä, numeroa tai koodia',
    'ui.admin.nav.search_results': 'Pikahaun tulokset',
    'ui.admin.nav.searching': 'Haetaan…',
    'ui.admin.nav.no_results': 'Ei hakutuloksia.',
    'ui.admin.nav.kind_customer': 'Asiakas',
    'ui.admin.nav.kind_reservation': 'Varaus',
    'ui.admin.nav.kind_order': 'Tilaus',
    'ui.admin.nav.kind_giftcard': 'Lahjakortti',
    'ui.admin.nav.new_reservation': 'Uusi varaus',
    'ui.admin.nav.review': 'Tarkista',
    'ui.admin.nav.user_menu': 'Käyttäjävalikko',
    'ui.admin.nav.user_fallback': 'Käyttäjä',
    'ui.admin.nav.role': 'Rooli: {{var:role}}',
    'ui.admin.nav.open_shop': 'Avaa kauppa',
    'ui.admin.nav.new_tab': '(avautuu uuteen välilehteen)',
    'ui.admin.nav.expand': 'Laajenna valikko',
    'ui.admin.nav.collapse': 'Pienennä valikko',
    'ui.admin.nav.sort_legend': 'Lajittelujärjestys',
    'ui.admin.nav.sort_soon': 'Varausaika (tulevat lähin ensin)',
    'ui.admin.nav.sort_newest': 'Uusin tilaus ensin',
    'ui.admin.nav.sort_oldest': 'Vanhin tilaus ensin',
    'ui.admin.nav.customer_not_found': 'Asiakasta ei löytynyt',
    'ui.admin.nav.cash_finance': 'Kassa ja talous',
    'ui.admin.nav.spaces_blocks': 'Tilat ja sulut',
    'ui.admin.nav.pos': 'Pikakassa',
    'ui.admin.nav.finance': 'Talous',
    'ui.admin.nav.paylink_watch': 'Seurattavat maksut',
    'ui.admin.nav.invoices': 'Laskut',
    'ui.admin.nav.products': 'Tuotteet',
    'ui.admin.nav.events': 'Tapahtumat',
    'ui.admin.nav.discounts': 'Alennuskoodit',
    'ui.admin.nav.quiet_hours': 'Hiljaiset ajat',
    'ui.admin.nav.resources': 'Resurssit',
    'ui.admin.nav.closures': 'Kalenterisulut',
    'ui.admin.nav.settings': 'Asetukset',
    'ui.admin.nav.users': 'Käyttäjät',
  },
  en: {
    'ui.admin.nav.orders': 'Orders',
    'ui.admin.nav.reservations': 'Reservations',
    'ui.admin.nav.orders_tabs': 'Orders and reservations',
    'ui.admin.nav.loading': 'Loading…',
    'ui.admin.nav.load_failed': 'Could not load the view: {{var:error}}',
    'ui.admin.nav.search_label': 'Quick search',
    'ui.admin.nav.search_open': 'Open quick search',
    'ui.admin.nav.search_placeholder': 'Search by name, number or code',
    'ui.admin.nav.search_results': 'Quick search results',
    'ui.admin.nav.searching': 'Searching…',
    'ui.admin.nav.no_results': 'No results.',
    'ui.admin.nav.kind_customer': 'Customer',
    'ui.admin.nav.kind_reservation': 'Reservation',
    'ui.admin.nav.kind_order': 'Order',
    'ui.admin.nav.kind_giftcard': 'Gift card',
    'ui.admin.nav.new_reservation': 'New reservation',
    'ui.admin.nav.review': 'Review',
    'ui.admin.nav.user_menu': 'User menu',
    'ui.admin.nav.user_fallback': 'User',
    'ui.admin.nav.role': 'Role: {{var:role}}',
    'ui.admin.nav.open_shop': 'Open shop',
    'ui.admin.nav.new_tab': '(opens in a new tab)',
    'ui.admin.nav.expand': 'Expand menu',
    'ui.admin.nav.collapse': 'Collapse menu',
    'ui.admin.nav.sort_legend': 'Sort order',
    'ui.admin.nav.sort_soon': 'Reservation time (upcoming soonest first)',
    'ui.admin.nav.sort_newest': 'Newest order first',
    'ui.admin.nav.sort_oldest': 'Oldest order first',
    'ui.admin.nav.customer_not_found': 'Customer not found',
    'ui.admin.nav.cash_finance': 'Cash and finance',
    'ui.admin.nav.spaces_blocks': 'Spaces and closures',
    'ui.admin.nav.pos': 'Quick till',
    'ui.admin.nav.finance': 'Finance',
    'ui.admin.nav.paylink_watch': 'Payments to follow',
    'ui.admin.nav.invoices': 'Invoices',
    'ui.admin.nav.products': 'Products',
    'ui.admin.nav.events': 'Events',
    'ui.admin.nav.discounts': 'Discount codes',
    'ui.admin.nav.quiet_hours': 'Quiet hours',
    'ui.admin.nav.resources': 'Resources',
    'ui.admin.nav.closures': 'Calendar blocks',
    'ui.admin.nav.settings': 'Settings',
    'ui.admin.nav.users': 'Users',
  },
};

let db = new Map();
let loaded = false;

export function fillNavText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  const out = fillNavText(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}

/** Ottaa käyttöön päivänipun (admin_day_bundle.site_texts) tai erillisen haun ui.admin.nav.*-rivit. */
export function primeNavTexts(rows) {
  if (!Array.isArray(rows)) return false;
  const next = new Map();
  for (const r of rows) {
    if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX)) continue;
    if (r.lang !== 'fi' && r.lang !== 'en') continue;
    if (typeof r.text !== 'string' || !r.text.trim()) continue;
    next.set(`${r.key}|${r.lang}`, r.text);
  }
  db = next;
  loaded = true;
  return true;
}

/** Lukee ui.admin.nav.*-rivit jaetusta välimuistista. Virhe ei kaada näkymää (sanakirja jää voimaan). */
export async function loadNavTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    return primeNavTexts(t.texts);
  } catch {
    return false;
  }
}

export function clearNavTextCache() { db = new Map(); loaded = false; }

export function navText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = NAV_TEXTS[lang]?.[key] ?? NAV_TEXTS.fi[key] ?? key;
  return vars ? fillNavText(raw, vars) : raw;
}
