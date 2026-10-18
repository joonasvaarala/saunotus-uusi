// Hallinnan päivänäkymän uudet tekstit (FI + EN). Avaimet: ui.admin.day.* (§18).
// Hallinta ei vielä hae public_get_site_texts -vastauksia (kuten muu hallinta: sanakirja on varateksti).
// Tuonti: content/site-texts.pending-import-4.json (admin_texts_import, ei ylikirjoita). Kieli sama avain
// kuin Talous-näkymässä (booking.admin.lang / ?lang=). Paikkamerkki {{var:amount}} täytetään käyttöhetkellä.

export const DAY_TEXTS = {
  fi: {
    'ui.admin.day.revenue_title': 'Päivän tuotto',
    'ui.admin.day.revenue_vat': 'sis. alv',
    'ui.admin.day.revenue_pending': 'Vahvistamatta {{var:amount}}',
    'ui.admin.day.revenue_unpaid': 'Josta maksamatta {{var:amount}}',
    'ui.admin.day.revenue_unavailable': 'Päivän tuotto ja tapahtumat eivät ole vielä käytettävissä.',
    'ui.admin.day.event_badge': 'Tapahtuma',
    'ui.admin.day.event_all_day': 'Koko päivä',
  },
  en: {
    'ui.admin.day.revenue_title': "Day's revenue",
    'ui.admin.day.revenue_vat': 'incl. VAT',
    'ui.admin.day.revenue_pending': 'Unconfirmed {{var:amount}}',
    'ui.admin.day.revenue_unpaid': 'Of which unpaid {{var:amount}}',
    'ui.admin.day.revenue_unavailable': "The day's revenue and events are not available yet.",
    'ui.admin.day.event_badge': 'Event',
    'ui.admin.day.event_all_day': 'All day',
  },
};

const LANGS = ['fi', 'en'];
function currentLang() {
  try {
    const q = new URLSearchParams(typeof location !== 'undefined' ? location.search : '');
    const hq = new URLSearchParams(typeof location !== 'undefined' ? (location.hash || '').split('?')[1] || '' : '');
    const stored = typeof localStorage !== 'undefined' ? localStorage.getItem('booking.admin.lang') : null;
    const l = hq.get('lang') || q.get('lang') || stored;
    return LANGS.includes(l) ? l : 'fi';
  } catch { return 'fi'; }
}
export const dayLang = () => currentLang();

export function fillDayText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}
export function dayText(key, vars, lang = currentLang()) {
  const raw = DAY_TEXTS[lang]?.[key] ?? DAY_TEXTS.fi[key] ?? key;
  return vars ? fillDayText(raw, vars) : raw;
}
