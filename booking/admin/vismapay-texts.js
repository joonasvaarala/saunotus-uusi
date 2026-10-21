// Visma Pay -asetuskortin tekstit (FI + EN). Avaimet: ui.admin.vismapay.*
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu tai rivi puuttuu → VISMAPAY_TEXTS.
// Uudet avaimet: content/site-texts.pending-import-28.json.
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.vismapay.';

export const VISMAPAY_TEXTS = {
  fi: {
    'ui.admin.vismapay.title': 'Visma Pay',
    'ui.admin.vismapay.lead': 'Verkkomaksun tila. Tunnuksia ei näytetä eikä tallenneta tähän.',
    'ui.admin.vismapay.mode': 'Tila',
    'ui.admin.vismapay.mode_off': 'Pois päältä',
    'ui.admin.vismapay.mode_dry_run': 'Harjoitusajo',
    'ui.admin.vismapay.mode_test': 'Testi',
    'ui.admin.vismapay.mode_live': 'Tuotanto',
    'ui.admin.vismapay.approved_by': 'Hyväksyjä',
    'ui.admin.vismapay.approved_hint': 'Nimi ja päivä. Vaaditaan testi- ja tuotantotilassa.',
    'ui.admin.vismapay.approved_required': 'Testi- ja tuotantotila vaativat hyväksyjän nimen ja päivän.',
    'ui.admin.vismapay.secrets': 'Tunnukset asetetaan palvelimen salaisuuksiin, ei tähän lomakkeeseen.',
    'ui.admin.vismapay.test_note': 'Testitilassa asiakas voi maksaa Visma Payn testikortilla. Oikeaa rahaa ei veloiteta.',
    'ui.admin.vismapay.live_note': 'Tuotantotilassa veloitus on oikea. Kokeile ensin pienellä summalla omalla kortilla ja hyvitä se hallinnasta.',
    'ui.admin.vismapay.dry_note': 'Harjoitusajo ei lähetä maksua Visma Payhin eikä veloita.',
    'ui.admin.vismapay.off_note': 'Verkkomaksu on pois päältä. Asiakas ei näe Visma Pay -painiketta.',
    'ui.admin.vismapay.save': 'Tallenna Visma Pay',
    'ui.admin.vismapay.saved': 'Visma Pay -tila tallennettu.',
    'ui.admin.vismapay.unavailable': 'Visma Pay -tilaa ei saatu haettua.',
    'ui.admin.vismapay.version': 'Rajapinta',
    'ui.admin.vismapay.online_on': 'Asiakkaan verkkomaksu on käytössä.',
    'ui.admin.vismapay.online_off': 'Asiakkaan verkkomaksu ei ole käytössä.',
  },
  en: {
    'ui.admin.vismapay.title': 'Visma Pay',
    'ui.admin.vismapay.lead': 'Online payment mode. Credentials are not shown and cannot be saved here.',
    'ui.admin.vismapay.mode': 'Mode',
    'ui.admin.vismapay.mode_off': 'Off',
    'ui.admin.vismapay.mode_dry_run': 'Dry run',
    'ui.admin.vismapay.mode_test': 'Test',
    'ui.admin.vismapay.mode_live': 'Live',
    'ui.admin.vismapay.approved_by': 'Approved by',
    'ui.admin.vismapay.approved_hint': 'Name and date. Required for test and live.',
    'ui.admin.vismapay.approved_required': 'Test and live require the approver name and date.',
    'ui.admin.vismapay.secrets': 'Credentials are set as server secrets, not in this form.',
    'ui.admin.vismapay.test_note': 'In test mode the customer can pay with a Visma Pay test card. No real money is charged.',
    'ui.admin.vismapay.live_note': 'Live mode charges real money. Try a small amount with your own card first, then refund it from admin.',
    'ui.admin.vismapay.dry_note': 'Dry run does not send the payment to Visma Pay and does not charge.',
    'ui.admin.vismapay.off_note': 'Online payment is off. The customer does not see the Visma Pay button.',
    'ui.admin.vismapay.save': 'Save Visma Pay',
    'ui.admin.vismapay.saved': 'Visma Pay mode saved.',
    'ui.admin.vismapay.unavailable': 'The Visma Pay status could not be loaded.',
    'ui.admin.vismapay.version': 'API',
    'ui.admin.vismapay.online_on': 'Customer online payment is on.',
    'ui.admin.vismapay.online_off': 'Customer online payment is off.',
  },
};

let db = new Map();
let loaded = false;

export async function loadVismapayTexts(rpcFn) {
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

export function clearVismapayTextCache() {
  db = new Map();
  loaded = false;
}

export function vismapayText(key, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  if (live) return live;
  return VISMAPAY_TEXTS[lang]?.[key] ?? VISMAPAY_TEXTS.fi[key] ?? key;
}
