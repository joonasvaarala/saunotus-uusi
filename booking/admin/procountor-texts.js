// Procountor-asetuskortin tekstit (FI + EN). Avaimet: ui.admin.procountor.*
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu tai rivi puuttuu → PROCOUNTOR_TEXTS.
// Tilakortin tekstit: content/site-texts.pending-import-11.json (jo tuotu, älä muuta).
// Lomakkeen uudet avaimet: content/site-texts.pending-import-15.json.
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.procountor.';

export const PROCOUNTOR_TEXTS = {
  fi: {
    'ui.admin.procountor.title': 'Procountor',
    'ui.admin.procountor.lead': 'Kirjanpidon lähetystila. Salaisuuksia ei näytetä.',
    'ui.admin.procountor.mode': 'Tila',
    'ui.admin.procountor.mode_off': 'Pois päältä',
    'ui.admin.procountor.mode_dry_run': 'Harjoitusajo',
    'ui.admin.procountor.mode_live': 'Yhdistetty',
    'ui.admin.procountor.env': 'Ympäristö',
    'ui.admin.procountor.env_pts': 'Testi (PTS)',
    'ui.admin.procountor.env_prod': 'Tuotanto',
    'ui.admin.procountor.daily': 'Päivittäinen myyntikirjaus',
    'ui.admin.procountor.daily_on': 'Käytössä',
    'ui.admin.procountor.daily_off': 'Ei käytössä',
    'ui.admin.procountor.accounts_ok': 'Tilit asetettu',
    'ui.admin.procountor.accounts_missing': 'Tilit puuttuvat',
    'ui.admin.procountor.bank_ok': 'Pankkitili asetettu',
    'ui.admin.procountor.bank_missing': 'Pankkitili puuttuu',
    'ui.admin.procountor.last': 'Viimeisin ajo',
    'ui.admin.procountor.last_none': 'Ei ajoja',
    'ui.admin.procountor.errors': 'Virheet',
    'ui.admin.procountor.errors_none': 'Ei avoimia virheitä',
    'ui.admin.procountor.unavailable': 'Procountor-tilaa ei saatu haettua.',
    'ui.admin.procountor.status_sent': 'Lähetetty',
    'ui.admin.procountor.status_dry_run': 'Harjoitus',
    'ui.admin.procountor.status_failed': 'Epäonnistui',
    'ui.admin.procountor.status_needs_review': 'Tarkistettava',
    'ui.admin.procountor.status_skipped': 'Ohitettu',
    'ui.admin.procountor.status_pending': 'Jonossa',
    'ui.admin.procountor.status_processing': 'Käynnissä',
    'ui.admin.procountor.attempts': 'Yritykset',
    'ui.admin.procountor.edit_title': 'Tilit ja tila',
    'ui.admin.procountor.edit_lead': 'Tallennus ei lähetä mitään. Salaisuuksia ei voi tallentaa tähän.',
    'ui.admin.procountor.save': 'Tallenna Procountor',
    'ui.admin.procountor.saved': 'Procountor-asetukset tallennettu',
    'ui.admin.procountor.approved_by': 'Hyväksyjä',
    'ui.admin.procountor.approved_by_hint': 'Nimi ja päivä. Vaaditaan kun tila on yhdistetty.',
    'ui.admin.procountor.vat_status': 'ALV-tila',
    'ui.admin.procountor.api_prefix': 'API-etuliite',
    'ui.admin.procountor.bank_account': 'Tilinumero verkkolaskulle',
    'ui.admin.procountor.bank_keep': 'Näkyy henkilökunnalle ja ylläpitäjille. Tyhjä kenttä poistaa tilin.',
    'ui.admin.procountor.rounding': 'Pyöristys',
    'ui.admin.procountor.sales_title': 'Myyntitilit',
    'ui.admin.procountor.methods_title': 'Maksutapojen tilit',
    'ui.admin.procountor.sales_25_5': 'Myynti ALV 25,5 %',
    'ui.admin.procountor.sales_13_5': 'Myynti ALV 13,5 %',
    'ui.admin.procountor.sales_0': 'Myynti ALV 0 %',
    'ui.admin.procountor.sales_14': 'Myynti ALV 14 %',
    'ui.admin.procountor.sales_24': 'Myynti ALV 24 %',
    'ui.admin.procountor.sales_10': 'Myynti ALV 10 %',
    'ui.admin.procountor.method_cash': 'Käteinen',
    'ui.admin.procountor.method_card_terminal': 'Korttipääte',
    'ui.admin.procountor.method_mobilepay': 'MobilePay',
    'ui.admin.procountor.method_bank_transfer': 'Tilisiirto',
    'ui.admin.procountor.method_invoice': 'Lasku',
    'ui.admin.procountor.method_gift_card': 'Lahjakortti',
    'ui.admin.procountor.method_partner_voucher': 'Kumppanin etuseteli',
    'ui.admin.procountor.method_visma_pay': 'Visma Pay',
    'ui.admin.procountor.method_annual_card': 'Vuosikortti',
    'ui.admin.procountor.method_pay_later': 'Maksu myöhemmin',
    'ui.admin.procountor.method_other': 'Muu maksutapa',
    'ui.admin.procountor.preview': 'Esikatsele päivä',
    'ui.admin.procountor.preview_date': 'Päivä',
    'ui.admin.procountor.preview_receipts': 'Kuitteja',
    'ui.admin.procountor.preview_not_sent': 'Mitään ei lähetetä.',
    'ui.admin.procountor.missing': 'Puuttuu',
  },
  en: {
    'ui.admin.procountor.title': 'Procountor',
    'ui.admin.procountor.lead': 'Accounting send status. Secrets are not shown.',
    'ui.admin.procountor.mode': 'Mode',
    'ui.admin.procountor.mode_off': 'Off',
    'ui.admin.procountor.mode_dry_run': 'Dry run',
    'ui.admin.procountor.mode_live': 'Connected',
    'ui.admin.procountor.env': 'Environment',
    'ui.admin.procountor.env_pts': 'Test (PTS)',
    'ui.admin.procountor.env_prod': 'Production',
    'ui.admin.procountor.daily': 'Daily sales posting',
    'ui.admin.procountor.daily_on': 'On',
    'ui.admin.procountor.daily_off': 'Off',
    'ui.admin.procountor.accounts_ok': 'Accounts set',
    'ui.admin.procountor.accounts_missing': 'Accounts missing',
    'ui.admin.procountor.bank_ok': 'Bank account set',
    'ui.admin.procountor.bank_missing': 'Bank account missing',
    'ui.admin.procountor.last': 'Last run',
    'ui.admin.procountor.last_none': 'No runs yet',
    'ui.admin.procountor.errors': 'Errors',
    'ui.admin.procountor.errors_none': 'No open errors',
    'ui.admin.procountor.unavailable': 'Procountor status could not be loaded.',
    'ui.admin.procountor.status_sent': 'Sent',
    'ui.admin.procountor.status_dry_run': 'Dry run',
    'ui.admin.procountor.status_failed': 'Failed',
    'ui.admin.procountor.status_needs_review': 'Needs review',
    'ui.admin.procountor.status_skipped': 'Skipped',
    'ui.admin.procountor.status_pending': 'Pending',
    'ui.admin.procountor.status_processing': 'Processing',
    'ui.admin.procountor.attempts': 'Attempts',
    'ui.admin.procountor.edit_title': 'Accounts and mode',
    'ui.admin.procountor.edit_lead': 'Saving does not send anything. Secrets cannot be stored here.',
    'ui.admin.procountor.save': 'Save Procountor',
    'ui.admin.procountor.saved': 'Procountor settings saved',
    'ui.admin.procountor.approved_by': 'Approved by',
    'ui.admin.procountor.approved_by_hint': 'Name and date. Required when the mode is connected.',
    'ui.admin.procountor.vat_status': 'VAT status',
    'ui.admin.procountor.api_prefix': 'API prefix',
    'ui.admin.procountor.bank_account': 'Account for e-invoices',
    'ui.admin.procountor.bank_keep': 'Visible to staff and administrators. An empty field clears the account.',
    'ui.admin.procountor.rounding': 'Rounding',
    'ui.admin.procountor.sales_title': 'Sales accounts',
    'ui.admin.procountor.methods_title': 'Payment accounts',
    'ui.admin.procountor.sales_25_5': 'Sales VAT 25.5%',
    'ui.admin.procountor.sales_13_5': 'Sales VAT 13.5%',
    'ui.admin.procountor.sales_0': 'Sales VAT 0%',
    'ui.admin.procountor.sales_14': 'Sales VAT 14%',
    'ui.admin.procountor.sales_24': 'Sales VAT 24%',
    'ui.admin.procountor.sales_10': 'Sales VAT 10%',
    'ui.admin.procountor.method_cash': 'Cash',
    'ui.admin.procountor.method_card_terminal': 'Card terminal',
    'ui.admin.procountor.method_mobilepay': 'MobilePay',
    'ui.admin.procountor.method_bank_transfer': 'Bank transfer',
    'ui.admin.procountor.method_invoice': 'Invoice',
    'ui.admin.procountor.method_gift_card': 'Gift card',
    'ui.admin.procountor.method_partner_voucher': 'Partner voucher',
    'ui.admin.procountor.method_visma_pay': 'Visma Pay',
    'ui.admin.procountor.method_annual_card': 'Annual card',
    'ui.admin.procountor.method_pay_later': 'Pay later',
    'ui.admin.procountor.method_other': 'Other payment',
    'ui.admin.procountor.preview': 'Preview day',
    'ui.admin.procountor.preview_date': 'Date',
    'ui.admin.procountor.preview_receipts': 'Receipts',
    'ui.admin.procountor.preview_not_sent': 'Nothing is sent.',
    'ui.admin.procountor.missing': 'Missing',
  },
};

let db = new Map();
let loaded = false;

export async function loadProcountorTexts(rpcFn) {
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

export function clearProcountorTextCache() {
  db = new Map();
  loaded = false;
}

export function procountorText(key, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  if (live) return live;
  return PROCOUNTOR_TEXTS[lang]?.[key] ?? PROCOUNTOR_TEXTS.fi[key] ?? key;
}
