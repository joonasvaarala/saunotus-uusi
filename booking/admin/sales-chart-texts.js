// Talous-sivun myyntikäyrän tekstit (FI + EN). Avaimet: ui.admin.sales_chart.* (§18).
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu, rivi puuttuu tai paikkamerkki ei täyty → SALES_CHART_TEXTS.
// Tuonti: content/site-texts.pending-import-4.json (alkuperäiset) ja pending-import-7.json (akseli).
// Bottiavustus ajaa admin_texts_import; ei ylikirjoita olemassa olevia.
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.sales_chart.';

export const SALES_CHART_TEXTS = {
  fi: {
    'ui.admin.sales_chart.title': 'Myynti ja ALV',
    'ui.admin.sales_chart.year': 'Vuosi',
    'ui.admin.sales_chart.prev_year': 'Edellinen vuosi',
    'ui.admin.sales_chart.next_year': 'Seuraava vuosi',
    'ui.admin.sales_chart.legend_net': 'Myynti ilman ALV',
    'ui.admin.sales_chart.legend_vat': 'ALV',
    'ui.admin.sales_chart.legend_unsplit': 'Brutto, ALV ei eritelty',
    'ui.admin.sales_chart.total_gross': 'Vuoden myynti sis. ALV',
    'ui.admin.sales_chart.total_net': 'Ilman ALV',
    'ui.admin.sales_chart.total_vat': 'ALV',
    'ui.admin.sales_chart.basis': 'Kassaperuste: kuitin antamispäivä (Helsinki), ei käyntipäivä. Tuleva kuukausi on tyhjä, kunnes maksu on kirjattu. Lahjakortit lasketaan samoin kuin myyntiraportissa.',
    'ui.admin.sales_chart.empty': 'Tälle vuodelle ei ole myyntiä.',
    'ui.admin.sales_chart.unavailable': 'Myyntikäyrä ei ole käytettävissä.',
    'ui.admin.sales_chart.load_failed': 'Myyntikäyrän lataus epäonnistui.',
    'ui.admin.sales_chart.loading': 'Ladataan myyntikäyrää.',
    'ui.admin.sales_chart.bar_label': '{{var:month}}: ilman ALV {{var:net}}, ALV {{var:vat}}, erittelemätön brutto {{var:unsplit}}, yhteensä {{var:gross}}',
    'ui.admin.sales_chart.includes_johku': 'Pylväissä on uuden järjestelmän kuitit ja Johku-myynti. Johku-myynti ei sisälly raportteihin, CSV-vientiin eikä kuitteihin.',
    'ui.admin.sales_chart.chart_label': 'Kuukausittainen myynti',
    'ui.admin.sales_chart.future': 'Tuleva kuukausi',
    'ui.admin.sales_chart.axis_label': 'Euroa',
  },
  en: {
    'ui.admin.sales_chart.title': 'Sales and VAT',
    'ui.admin.sales_chart.year': 'Year',
    'ui.admin.sales_chart.prev_year': 'Previous year',
    'ui.admin.sales_chart.next_year': 'Next year',
    'ui.admin.sales_chart.legend_net': 'Sales excluding VAT',
    'ui.admin.sales_chart.legend_vat': 'VAT',
    'ui.admin.sales_chart.legend_unsplit': 'Gross, VAT not itemised',
    'ui.admin.sales_chart.total_gross': 'Year sales incl. VAT',
    'ui.admin.sales_chart.total_net': 'Excluding VAT',
    'ui.admin.sales_chart.total_vat': 'VAT',
    'ui.admin.sales_chart.basis': 'Cash basis: the receipt issue date (Helsinki), not the visit date. A future month stays empty until a payment is recorded. Gift cards are counted the same way as in the sales report.',
    'ui.admin.sales_chart.empty': 'No sales for this year.',
    'ui.admin.sales_chart.unavailable': 'The sales chart is not available.',
    'ui.admin.sales_chart.load_failed': 'The sales chart could not be loaded.',
    'ui.admin.sales_chart.loading': 'Loading the sales chart.',
    'ui.admin.sales_chart.bar_label': '{{var:month}}: excluding VAT {{var:net}}, VAT {{var:vat}}, unitemised gross {{var:unsplit}}, total {{var:gross}}',
    'ui.admin.sales_chart.includes_johku': 'The bars include receipts from the new system and Johku sales. Johku sales are not included in reports, CSV export, or receipts.',
    'ui.admin.sales_chart.chart_label': 'Monthly sales',
    'ui.admin.sales_chart.future': 'Future month',
    'ui.admin.sales_chart.axis_label': 'Euros',
  },
};

let db = new Map();
let loaded = false;

export function fillChartText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  const tokens = [...String(raw).matchAll(/\{\{([^{}]*)\}\}/g)];
  for (const m of tokens) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  if (/\{\{|\}\}/.test(fillChartText(raw, vars))) return null;
  return fillChartText(raw, vars);
}

/** Lukee ui.admin.sales_chart.*-rivit. Virhe tai väärä vastaus ei kaada näkymää. */
export async function loadSalesChartTexts(rpcFn) {
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

export function clearSalesChartTextCache() {
  db = new Map();
  loaded = false;
}

export function chartText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return String(filled);
  const raw = SALES_CHART_TEXTS[lang]?.[key] ?? SALES_CHART_TEXTS.fi[key] ?? key;
  const out = vars ? fillChartText(raw, vars) : raw;
  return out == null ? '' : String(out);
}
