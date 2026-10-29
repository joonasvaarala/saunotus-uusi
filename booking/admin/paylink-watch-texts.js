// Seurattavat maksut (booking_215). Oletukset FI+EN, samat kuin content/site-texts.pending-import-102.json.
// Paikkamerkit {{var:nimi}}. Näkymä käyttää näitä, kunnes tekstit on tuotu ja kytketty site_texts-hakuun.
import { getLang } from './talous-i18n.js';

export const PW_TEXTS = {
  fi: {
    'ui.admin.paylink_watch.title': 'Seurattavat maksut',
    'ui.admin.paylink_watch.intro': 'Avoimet maksulinkit. Ennakkomaksu muistutetaan 3 päivän jälkeen ja vuorokausi ennen eräpäivää. Paikan päällä annettu linkki muistutetaan 3 päivän välein, enintään 4 kertaa.',
    'ui.admin.paylink_watch.empty': 'Ei avoimia maksulinkkejä.',
    'ui.admin.paylink_watch.search': 'Hae nimellä tai tilausnumerolla',
    'ui.admin.paylink_watch.filter.all': 'Kaikki',
    'ui.admin.paylink_watch.filter.watching': 'Seurannassa',
    'ui.admin.paylink_watch.filter.paused': 'Keskeytetyt',
    'ui.admin.paylink_watch.filter.needs_action': 'Vaatii toimenpiteitä',
    'ui.admin.paylink_watch.col.amount': 'Summa',
    'ui.admin.paylink_watch.col.customer': 'Asiakas',
    'ui.admin.paylink_watch.col.order': 'Tilaus / varaus',
    'ui.admin.paylink_watch.col.age': 'Linkin ikä',
    'ui.admin.paylink_watch.col.due': 'Eräpäivä',
    'ui.admin.paylink_watch.col.reminders': 'Muistutukset',
    'ui.admin.paylink_watch.col.next': 'Seuraava muistutus',
    'ui.admin.paylink_watch.col.status': 'Tila',
    'ui.admin.paylink_watch.col.actions': 'Toiminnot',
    'ui.admin.paylink_watch.age': '{{var:days}} pv {{var:hours}} h',
    'ui.admin.paylink_watch.age_hours': '{{var:hours}} h',
    'ui.admin.paylink_watch.no_due': 'Ei eräpäivää',
    'ui.admin.paylink_watch.reminders_none': 'Ei vielä',
    'ui.admin.paylink_watch.reminders_n': '{{var:n}} kpl, viimeisin {{var:when}}',
    'ui.admin.paylink_watch.next_none': '–',
    'ui.admin.paylink_watch.status.watching': 'Seurannassa',
    'ui.admin.paylink_watch.status.paused': 'Muistutukset keskeytetty',
    'ui.admin.paylink_watch.status.needs_action': 'Vaatii toimenpiteitä',
    'ui.admin.paylink_watch.kind.prepaid': 'Ennakkomaksu',
    'ui.admin.paylink_watch.kind.onsite': 'Paikan päällä',
    'ui.admin.paylink_watch.action.remind_now': 'Lähetä muistutus nyt',
    'ui.admin.paylink_watch.action.pause': 'Keskeytä muistutukset',
    'ui.admin.paylink_watch.action.handled': 'Merkitse hoidetuksi',
    'ui.admin.paylink_watch.handled_title': 'Merkitse hoidetuksi',
    'ui.admin.paylink_watch.handled_body': 'Kirjaa {{var:amount}} käsin. Avoin maksulinkki perutaan ja kuitti jää kirjanpitoon. Asiakkaalle ei lähde erillistä kuittiviestiä.',
    'ui.admin.paylink_watch.method': 'Maksutapa',
    'ui.admin.paylink_watch.note': 'Muistiinpano',
    'ui.admin.paylink_watch.confirm_handled': 'Kirjaa maksu',
    'ui.admin.paylink_watch.sent': 'Muistutus laitettu jonoon.',
    'ui.admin.paylink_watch.paused_ok': 'Muistutukset keskeytetty.',
    'ui.admin.paylink_watch.handled_ok': 'Maksu kirjattu{{var:receipt}}.',
    'ui.admin.paylink_watch.receipt_bit': ', kuitti {{var:no}}',
    'ui.admin.paylink_watch.no_perm': 'Tarvitset oikeuden payments.manage.',
    'ui.admin.paylink_watch.count': '{{var:n}} avointa linkkiä',
    'ui.admin.paylink_watch.reservation_more': '+ {{var:n}} muuta',
    'ui.admin.paylink_watch.loading': 'Ladataan…',
    'ui.admin.paylink_watch.order_link': 'Tilaus {{var:no}}',
  },
  en: {
    'ui.admin.paylink_watch.title': 'Payments to follow',
    'ui.admin.paylink_watch.intro': 'Open payment links. A prepaid link is reminded after 3 days and one day before the due date. An on-site link is reminded every 3 days, at most 4 times.',
    'ui.admin.paylink_watch.empty': 'No open payment links.',
    'ui.admin.paylink_watch.search': 'Search by name or order number',
    'ui.admin.paylink_watch.filter.all': 'All',
    'ui.admin.paylink_watch.filter.watching': 'Watching',
    'ui.admin.paylink_watch.filter.paused': 'Paused',
    'ui.admin.paylink_watch.filter.needs_action': 'Needs action',
    'ui.admin.paylink_watch.col.amount': 'Amount',
    'ui.admin.paylink_watch.col.customer': 'Customer',
    'ui.admin.paylink_watch.col.order': 'Order / booking',
    'ui.admin.paylink_watch.col.age': 'Link age',
    'ui.admin.paylink_watch.col.due': 'Due date',
    'ui.admin.paylink_watch.col.reminders': 'Reminders',
    'ui.admin.paylink_watch.col.next': 'Next reminder',
    'ui.admin.paylink_watch.col.status': 'Status',
    'ui.admin.paylink_watch.col.actions': 'Actions',
    'ui.admin.paylink_watch.age': '{{var:days}} d {{var:hours}} h',
    'ui.admin.paylink_watch.age_hours': '{{var:hours}} h',
    'ui.admin.paylink_watch.no_due': 'No due date',
    'ui.admin.paylink_watch.reminders_none': 'None yet',
    'ui.admin.paylink_watch.reminders_n': '{{var:n}}, last {{var:when}}',
    'ui.admin.paylink_watch.next_none': '–',
    'ui.admin.paylink_watch.status.watching': 'Watching',
    'ui.admin.paylink_watch.status.paused': 'Reminders paused',
    'ui.admin.paylink_watch.status.needs_action': 'Needs action',
    'ui.admin.paylink_watch.kind.prepaid': 'Prepaid',
    'ui.admin.paylink_watch.kind.onsite': 'On site',
    'ui.admin.paylink_watch.action.remind_now': 'Send reminder now',
    'ui.admin.paylink_watch.action.pause': 'Pause reminders',
    'ui.admin.paylink_watch.action.handled': 'Mark handled',
    'ui.admin.paylink_watch.handled_title': 'Mark handled',
    'ui.admin.paylink_watch.handled_body': 'Record {{var:amount}} manually. The open payment link is cancelled and the receipt stays in the books. No separate receipt email is sent.',
    'ui.admin.paylink_watch.method': 'Payment method',
    'ui.admin.paylink_watch.note': 'Note',
    'ui.admin.paylink_watch.confirm_handled': 'Record payment',
    'ui.admin.paylink_watch.sent': 'Reminder queued.',
    'ui.admin.paylink_watch.paused_ok': 'Reminders paused.',
    'ui.admin.paylink_watch.handled_ok': 'Payment recorded{{var:receipt}}.',
    'ui.admin.paylink_watch.receipt_bit': ', receipt {{var:no}}',
    'ui.admin.paylink_watch.no_perm': 'You need the payments.manage permission.',
    'ui.admin.paylink_watch.count': '{{var:n}} open links',
    'ui.admin.paylink_watch.reservation_more': '+ {{var:n}} more',
    'ui.admin.paylink_watch.loading': 'Loading…',
    'ui.admin.paylink_watch.order_link': 'Order {{var:no}}',
  },
};

function fill(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

export function pw(key, vars, lang = getLang()) {
  const raw = PW_TEXTS[lang]?.[key] || PW_TEXTS.fi[key] || key;
  return fill(raw, vars);
}

export function linkAge(iso, lang = getLang(), now = new Date()) {
  const ms = Math.max(0, now.getTime() - new Date(iso).getTime());
  const hours = Math.floor(ms / 3600000);
  const days = Math.floor(hours / 24);
  if (!days) return pw('ui.admin.paylink_watch.age_hours', { hours }, lang);
  return pw('ui.admin.paylink_watch.age', { days, hours: hours % 24 }, lang);
}
