// Procountor-asetuskortin tekstit (FI + EN). Avaimet: ui.admin.procountor.*
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu tai rivi puuttuu → PROCOUNTOR_TEXTS.
// Tuonti: content/site-texts.pending-import-11.json (ei ylikirjoita olemassa olevia).
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
