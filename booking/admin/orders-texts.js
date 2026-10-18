// Talous-tilauslistan maksusuodattimen tekstit (FI + EN). Avaimet: ui.admin.orders.* .
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu tai rivi puuttuu → ORDER_TEXTS.
// Tuonti: content/site-texts.pending-import-8.json (ei ylikirjoita olemassa olevia).
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.orders.';

export const ORDER_TEXTS = {
  fi: {
    'ui.admin.orders.pay_filter': 'Maksutila',
    'ui.admin.orders.pay_paid': 'Maksetut',
    'ui.admin.orders.pay_unpaid': 'Maksamattomat',
    'ui.admin.orders.pay_invoiced': 'Laskutetut',
    'ui.admin.orders.pay_all': 'Kaikki',
    'ui.admin.orders.pay_refunded': 'Hyvitetyt',
    'ui.admin.orders.pay_cancelled': 'Peruttu',
    'ui.admin.orders.pay_showing': 'Maksutila: {{var:label}}',
    'ui.admin.orders.search_all': 'Haku kaikista tilauksista',
  },
  en: {
    'ui.admin.orders.pay_filter': 'Payment status',
    'ui.admin.orders.pay_paid': 'Paid',
    'ui.admin.orders.pay_unpaid': 'Unpaid',
    'ui.admin.orders.pay_invoiced': 'Invoiced',
    'ui.admin.orders.pay_all': 'All',
    'ui.admin.orders.pay_refunded': 'Refunded',
    'ui.admin.orders.pay_cancelled': 'Cancelled',
    'ui.admin.orders.pay_showing': 'Payment status: {{var:label}}',
    'ui.admin.orders.search_all': 'Search covers all orders',
  },
};

let db = new Map();
let loaded = false;

export function fillOrderText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  const tokens = [...String(raw).matchAll(/\{\{([^{}]*)\}\}/g)];
  for (const m of tokens) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  if (/\{\{|\}\}/.test(fillOrderText(raw, vars))) return null;
  return fillOrderText(raw, vars);
}

/** Lukee ui.admin.orders.*-rivit. Virhe tai väärä vastaus ei kaada näkymää. */
export async function loadOrderTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await rpcFn('public_get_site_texts', { p_lang: null });
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    const next = new Map();
    for (const r of t.texts) {
      if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX)) continue;
      if (r.lang !== 'fi' && r.lang !== 'en') continue;
      if (typeof r.text !== 'string' || !r.text.trim()) continue;
      next.set(`${r.key}|${r.lang}`, r.text);
    }
    db = next;
    loaded = true;
    return true;
  } catch {
    return false;
  }
}

export function clearOrderTextCache() {
  db = new Map();
  loaded = false;
}

export function orderText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = ORDER_TEXTS[lang]?.[key] ?? ORDER_TEXTS.fi[key] ?? key;
  return vars ? fillOrderText(raw, vars) : raw;
}
