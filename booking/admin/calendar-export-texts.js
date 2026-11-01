// Varauskalenterin asetuskortin tekstit (FI + EN). Avaimet: ui.admin.calendar_export.*
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu tai rivi puuttuu → CALENDAR_EXPORT_TEXTS.
// Tuonti: content/site-texts.pending-import-26.json täydentää 25:ttä. booking_228: pending-import-116.json.
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.calendar_export.';

export const CALENDAR_EXPORT_TEXTS = {
  fi: {
    'ui.admin.calendar_export.title': 'Varauskalenteri',
    'ui.admin.calendar_export.lead': 'Hoidot, yksityisvaraukset, saunotusrituaalit ja tapahtumat viedään omiksi tapahtumikseen. Arjen yleinen vuoro näkyy koko vuoron mittaisena, kun sillä on varaus. Turvetorstai näkyy erikseen. Viikonloppuna yleiset vuorot ovat yksi palkki päivässä. Kalenterit ovat Savusauna, Rauni ja Lovi. Yhteinen kalenteri on vain varalla. Sulku- ja vuorokalentereita ei käytetä. Kalenterissa tehty muutos ei muuta varausta. Oletus on pois päältä.',
    'ui.admin.calendar_export.mode': 'Tila',
    'ui.admin.calendar_export.mode_off': 'Pois päältä',
    'ui.admin.calendar_export.mode_dry_run': 'Harjoitusajo',
    'ui.admin.calendar_export.mode_live': 'Käytössä',
    'ui.admin.calendar_export.shared': 'Yhteinen kalenteri',
    'ui.admin.calendar_export.shared_hint': 'Vain varalla, jos resurssilla ei ole omaa tunnusta. Tyhjä tunnus ei vie tapahtumaa.',
    'ui.admin.calendar_export.resources': 'Resurssien kalenterit',
    'ui.admin.calendar_export.resource_hint': 'Tämän resurssin tapahtumat. Savusauna, Rauni ja Lovi riittävät. Viikonlopun yleisten vuorojen palkki menee Savusaunaan.',
    'ui.admin.calendar_export.admin_url': 'Hallinnan osoite',
    'ui.admin.calendar_export.admin_url_hint': 'Tyhjä käyttää sivuston hallintaa. Osoitteessa ei saa olla tunnusta.',
    'ui.admin.calendar_export.timezone': 'Aikavyöhyke',
    'ui.admin.calendar_export.window_back': 'Päiviä taaksepäin',
    'ui.admin.calendar_export.window_forward': 'Päiviä eteenpäin',
    'ui.admin.calendar_export.fast': 'Nopea päivitys',
    'ui.admin.calendar_export.fast_hint': 'Päivittää noin minuutin kuluessa uudesta varauksesta. Muuten päivitys käy viiden minuutin välein.',
    'ui.admin.calendar_export.save': 'Tallenna varauskalenteri',
    'ui.admin.calendar_export.saved': 'Varauskalenteri tallennettu',
    'ui.admin.calendar_export.preview': 'Esikatsele',
    'ui.admin.calendar_export.preview_private': 'Yksityisiä tapahtumia',
    'ui.admin.calendar_export.preview_shifts': 'Vuoropalkkeja',
    'ui.admin.calendar_export.preview_persons': 'Henkilöitä vuoropalkissa',
    'ui.admin.calendar_export.preview_days': 'Päiväpalkkeja',
    'ui.admin.calendar_export.preview_bookings': 'Varausta',
    'ui.admin.calendar_export.preview_rituals': 'Rituaaleja',
    'ui.admin.calendar_export.preview_events': 'Tapahtumia',
    'ui.admin.calendar_export.preview_weekdays': 'Arjen vuoroja',
    'ui.admin.calendar_export.preview_weekends': 'Viikonloppupalkkeja',
    'ui.admin.calendar_export.preview_unconfigured': 'Ilman kalenteria',
    'ui.admin.calendar_export.preview_not_sent': 'Mitään ei lähetetä.',
    'ui.admin.calendar_export.last': 'Viimeisin ajo',
    'ui.admin.calendar_export.last_none': 'Ei ajoja',
    'ui.admin.calendar_export.last_ok': 'Onnistui',
    'ui.admin.calendar_export.unavailable': 'Varauskalenterin asetuksia ei saatu haettua. Vienti ei ole käytössä.',
    'ui.admin.calendar_export.dry_note': 'Harjoitusajo ei kirjoita kalenteriin.',
    'ui.admin.calendar_export.off_note': 'Pois päältä ei vie varauksia.',
    'ui.admin.calendar_export.error_invalid': 'Kalenterin tunnus ei kelpaa.',
    'ui.admin.calendar_export.error_closure': 'Sulkukalenteria ei käytetä varauksille.',
    'ui.admin.calendar_export.error_shift': 'Vuorokalenteria ei käytetä varauksille.',
  },
  en: {
    'ui.admin.calendar_export.title': 'Booking calendar',
    'ui.admin.calendar_export.lead': 'Treatments, private bookings, sauna rituals and events are exported as their own events. A weekday public shift is shown for its full scheduled length when it has a booking. Turvetorstai is separate. On weekends, public shifts are one bar per day. The calendars are Savusauna, Rauni and Lovi. The shared calendar is only a fallback. Closure and shift calendars are not used. An edit in the calendar does not change the booking. The default is off.',
    'ui.admin.calendar_export.mode': 'Mode',
    'ui.admin.calendar_export.mode_off': 'Off',
    'ui.admin.calendar_export.mode_dry_run': 'Dry run',
    'ui.admin.calendar_export.mode_live': 'On',
    'ui.admin.calendar_export.shared': 'Shared calendar',
    'ui.admin.calendar_export.shared_hint': 'Fallback only, when the resource has no id of its own. An empty id exports nothing.',
    'ui.admin.calendar_export.resources': 'Resource calendars',
    'ui.admin.calendar_export.resource_hint': 'Events for this resource. Savusauna, Rauni and Lovi are enough. The weekend public-shift bar goes to Savusauna.',
    'ui.admin.calendar_export.admin_url': 'Admin address',
    'ui.admin.calendar_export.admin_url_hint': 'Empty uses the site admin. The address must not contain a login.',
    'ui.admin.calendar_export.timezone': 'Time zone',
    'ui.admin.calendar_export.window_back': 'Days back',
    'ui.admin.calendar_export.window_forward': 'Days ahead',
    'ui.admin.calendar_export.fast': 'Fast update',
    'ui.admin.calendar_export.fast_hint': 'Updates within about a minute of a new booking. Otherwise the update runs every five minutes.',
    'ui.admin.calendar_export.save': 'Save booking calendar',
    'ui.admin.calendar_export.saved': 'Booking calendar saved',
    'ui.admin.calendar_export.preview': 'Preview',
    'ui.admin.calendar_export.preview_private': 'Private events',
    'ui.admin.calendar_export.preview_shifts': 'Shift bars',
    'ui.admin.calendar_export.preview_persons': 'People on shift bars',
    'ui.admin.calendar_export.preview_days': 'Day bars',
    'ui.admin.calendar_export.preview_bookings': 'Bookings',
    'ui.admin.calendar_export.preview_rituals': 'Rituals',
    'ui.admin.calendar_export.preview_events': 'Events',
    'ui.admin.calendar_export.preview_weekdays': 'Weekday shifts',
    'ui.admin.calendar_export.preview_weekends': 'Weekend bars',
    'ui.admin.calendar_export.preview_unconfigured': 'Without a calendar',
    'ui.admin.calendar_export.preview_not_sent': 'Nothing is sent.',
    'ui.admin.calendar_export.last': 'Latest run',
    'ui.admin.calendar_export.last_none': 'No runs',
    'ui.admin.calendar_export.last_ok': 'Succeeded',
    'ui.admin.calendar_export.unavailable': 'Booking calendar settings could not be loaded. Export is off.',
    'ui.admin.calendar_export.dry_note': 'A dry run does not write to the calendar.',
    'ui.admin.calendar_export.off_note': 'Off does not export bookings.',
    'ui.admin.calendar_export.error_invalid': 'The calendar id is not valid.',
    'ui.admin.calendar_export.error_closure': 'A closure calendar is not used for bookings.',
    'ui.admin.calendar_export.error_shift': 'A shift calendar is not used for bookings.',
  },
};

let db = new Map();
let loaded = false;

export async function loadCalendarExportTexts(rpcFn) {
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

export function clearCalendarExportTextCache() {
  db = new Map();
  loaded = false;
}

export function calendarExportText(key, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  if (live) return live;
  return CALENDAR_EXPORT_TEXTS[lang]?.[key] ?? CALENDAR_EXPORT_TEXTS.fi[key] ?? key;
}
