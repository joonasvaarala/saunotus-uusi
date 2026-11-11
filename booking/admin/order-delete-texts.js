// booking_264: maksamattoman tilauksen poisto (arkistointi) – tekstit FI + EN. Avaimet ui.admin.order_delete.* .
// Sivutekstit (site_texts, tuonti content/site-texts.pending-import-133.json) peittävät sanakirjan; haku epäonnistuu tai rivi puuttuu → sanakirja.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const ORDER_DELETE_TEXTS = {
  fi: {
    'ui.admin.order_delete.button': 'Poista maksamaton tilaus',
    'ui.admin.order_delete.title': 'Poistetaanko maksamaton tilaus #{{var:no}}?',
    'ui.admin.order_delete.intro': 'Tilaus siirtyy poistettuihin. Sitä ei näytetä tavallisilla tilauslistoilla, mutta tiedot ja muutoshistoria säilyvät. Asiakkaalle ei lähetetä viestiä.',
    'ui.admin.order_delete.effect_reservations': 'Perutaan {{var:n}} varausta: aika vapautuu muille ja varaus poistuu kalenterista seuraavassa synkronoinnissa.',
    'ui.admin.order_delete.effect_payments': 'Suljetaan {{var:n}} avointa maksuriviä. Maksulinkki ei enää avaa maksua ja muistutukset loppuvat.',
    'ui.admin.order_delete.effect_emails': 'Jonossa olevat {{var:n}} sähköpostia jätetään lähettämättä.',
    'ui.admin.order_delete.effect_cancelled': 'Tilaus on jo peruttu. Poisto vain piilottaa sen listoilta.',
    'ui.admin.order_delete.waitlist': 'Varattu aika vapautuu muille. Jos aikaan on jonottajia, he saavat tavallisen ilmoituksen vapautuneesta paikasta.',
    'ui.admin.order_delete.late_payment': 'Jos asiakas silti maksaa myöhemmin, maksu kirjataan, tilaus pysyy perutuksi ja se palaa näkyviin merkinnällä "maksu saapui". Rahat palautetaan käsin.',
    'ui.admin.order_delete.reason': 'Syy (valinnainen)',
    'ui.admin.order_delete.confirm': 'Poista tilaus',
    'ui.admin.order_delete.done': 'Tilaus #{{var:no}} poistettu.',
    'ui.admin.order_delete.already': 'Tilaus oli jo poistettu.',
    'ui.admin.order_delete.blocked_title': 'Tilausta ei voi poistaa',
    'ui.admin.order_delete.session_title': 'Verkkomaksu on kesken',
    'ui.admin.order_delete.session_text': 'Asiakas on avannut verkkomaksun, eikä maksupalvelu ole vielä vahvistanut sen päättyneen. Avattua maksua ei voi sulkea meidän päästämme, joten tilausta ei voi poistaa ennen vahvistusta. Pelkkä ajan kuluminen ei riitä.',
    'ui.admin.order_delete.session_check_help': 'Tarkista tila hakee maksun tilan suoraan Montoniolta. Kun Montonio kertoo maksun vanhentuneen tai mitätöidyn, poisto avautuu.',
    'ui.admin.order_delete.session_wait_help': 'Tämän maksun tilaa ei voi hakea täältä. Odota maksupalvelun ilmoitusta tai tarkista maksu maksupalvelun hallinnasta.',
    'ui.admin.order_delete.check': 'Tarkista tila',
    'ui.admin.order_delete.check_paid': 'Maksu on maksettu. Tilausta ei poisteta.',
    'ui.admin.order_delete.check_closed': 'Maksupalvelu vahvisti maksun päättyneen.',
    'ui.admin.order_delete.check_pending': 'Maksu on yhä kesken maksupalvelussa.',
    'ui.admin.order_delete.check_failed': 'Tilan haku ei onnistunut. Yritä myöhemmin uudelleen.',
    'ui.admin.order_delete.archived': 'Poistettu {{var:date}}',
    'ui.admin.order_delete.archived_reason': 'Syy: {{var:reason}}',
    'ui.admin.order_delete.archived_late_paid': 'Poistettu – maksu saapui, tarkista',
    'ui.admin.order_delete.archived_late_paid_help': 'Tilaus poistettiin maksamattomana, mutta maksu saapui sen jälkeen. Tilaus pysyy perutuksi. Palauta rahat tai sovi asiakkaan kanssa.',
    'ui.admin.order_delete.blocker.provider_session_unresolved': 'Verkkomaksu on kesken eikä maksupalvelu ole vahvistanut sen päättyneen.',
    'ui.admin.order_delete.blocker.payment_status': 'Tilaus ei ole maksamaton.',
    'ui.admin.order_delete.blocker.settled_payment': 'Tilauksella on maksettu tai hyvitetty maksu.',
    'ui.admin.order_delete.blocker.receipts': 'Tilauksella on kuitti.',
    'ui.admin.order_delete.blocker.refunds': 'Tilauksella on hyvitys.',
    'ui.admin.order_delete.blocker.accounting': 'Tilaus on kirjanpidossa.',
    'ui.admin.order_delete.blocker.invoice': 'Tilauksella on lasku. Korjaa laskutuksen kautta.',
    'ui.admin.order_delete.blocker.gift_card': 'Tilaukseen liittyy lahjakortti.',
    'ui.admin.order_delete.blocker.annual_card': 'Tilaukseen liittyy vuosikortti.',
    'ui.admin.order_delete.blocker.voucher_claim': 'Tilaukseen liittyy kumppanilahjakortin lunastus.',
    'ui.admin.order_delete.blocker.training': 'Koulutuksen osallistuja: käsittele koulutustyökalussa.',
    'ui.admin.order_delete.blocker.reservation_started': 'Varaus on jo alkanut tai toteutunut.',
    'ui.admin.order_delete.blocker.linked_reservations': 'Toisen tilauksen lisäpalvelu on kiinni tämän tilauksen varauksessa.',
    'ui.admin.order_delete.blocker.external_order': 'Johkusta tuotu tilaus käsitellään Johkussa.',
    'ui.admin.order_delete.blocker.external_payment': 'Tilauksella on ulkoisesta järjestelmästä tuotu maksu.',
    'ui.admin.order_delete.blocker.order_completed': 'Toteutunutta tilausta ei voi poistaa.',
    'ui.admin.order_delete.blocker.email_claim_uncertain': 'Aiemman sähköpostiyrityksen päättymistä ei voida todistaa. Poisto estetään; vanhaa lähetystä ei voi perua.',
    'ui.admin.order_delete.blocker.email_sending': 'Tilauksen sähköpostia lähetetään juuri nyt. Yritä hetken kuluttua uudelleen.',
    'ui.admin.order_delete.blocker.unknown': 'Tilausta ei voi poistaa.',
    'ui.admin.order_delete.blocked_help': 'Poisto on mahdollinen vain maksamattomalle tilaukselle, jonka varaus ei ole vielä alkanut.',
    'ui.admin.order_delete.forbidden': 'Sinulla ei ole oikeutta poistaa tilauksia. Poistoon tarvitaan varausten ja maksujen hallintaoikeus. Tilaus on ennallaan.',
    'ui.admin.order_delete.busy': 'Tilausta käsitellään juuri nyt. Tilaus on ennallaan. Yritä hetken kuluttua uudelleen.',
    'ui.admin.order_delete.failed': 'Poisto ei onnistunut. Tilaus on ennallaan.',
    'ui.admin.order_delete.danger_label': 'Vaarallinen toiminto',
  },
  en: {
    'ui.admin.order_delete.button': 'Delete unpaid order',
    'ui.admin.order_delete.title': 'Delete unpaid order #{{var:no}}?',
    'ui.admin.order_delete.intro': 'The order moves to deleted orders. It no longer shows in the normal order lists, but its data and history are kept. The customer gets no message.',
    'ui.admin.order_delete.effect_reservations': '{{var:n}} bookings will be cancelled: the time becomes free and the booking leaves the calendar at the next sync.',
    'ui.admin.order_delete.effect_payments': '{{var:n}} open payment rows will be closed. The payment link stops working and reminders stop.',
    'ui.admin.order_delete.effect_emails': '{{var:n}} queued emails will not be sent.',
    'ui.admin.order_delete.effect_cancelled': 'The order is already cancelled. Deleting only hides it from the lists.',
    'ui.admin.order_delete.waitlist': 'The booked time becomes available to others. If people are on the waiting list for it, they get the usual spot-freed notice.',
    'ui.admin.order_delete.late_payment': 'If the customer still pays later, the payment is recorded, the order stays cancelled and comes back into view marked "payment arrived". Refund manually.',
    'ui.admin.order_delete.reason': 'Reason (optional)',
    'ui.admin.order_delete.confirm': 'Delete order',
    'ui.admin.order_delete.done': 'Order #{{var:no}} deleted.',
    'ui.admin.order_delete.already': 'The order was already deleted.',
    'ui.admin.order_delete.blocked_title': 'The order cannot be deleted',
    'ui.admin.order_delete.session_title': 'Online payment in progress',
    'ui.admin.order_delete.session_text': 'The customer has opened an online payment and the payment provider has not yet confirmed that it ended. We cannot close an opened payment from our side, so the order cannot be deleted until it is confirmed. Waiting alone is not enough.',
    'ui.admin.order_delete.session_check_help': 'Check status asks Montonio for the payment status. When Montonio reports the payment abandoned or voided, deleting becomes possible.',
    'ui.admin.order_delete.session_wait_help': 'The status of this payment cannot be checked from here. Wait for the provider notice or check the payment in the provider dashboard.',
    'ui.admin.order_delete.check': 'Check status',
    'ui.admin.order_delete.check_paid': 'The payment is paid. The order will not be deleted.',
    'ui.admin.order_delete.check_closed': 'The provider confirmed the payment ended.',
    'ui.admin.order_delete.check_pending': 'The payment is still open at the provider.',
    'ui.admin.order_delete.check_failed': 'The status check failed. Try again later.',
    'ui.admin.order_delete.archived': 'Deleted {{var:date}}',
    'ui.admin.order_delete.archived_reason': 'Reason: {{var:reason}}',
    'ui.admin.order_delete.archived_late_paid': 'Deleted – payment arrived, check',
    'ui.admin.order_delete.archived_late_paid_help': 'The order was deleted as unpaid, but a payment arrived afterwards. The order stays cancelled. Refund the money or agree with the customer.',
    'ui.admin.order_delete.blocker.provider_session_unresolved': 'An online payment is open and the provider has not confirmed that it ended.',
    'ui.admin.order_delete.blocker.payment_status': 'The order is not unpaid.',
    'ui.admin.order_delete.blocker.settled_payment': 'The order has a paid or refunded payment.',
    'ui.admin.order_delete.blocker.receipts': 'The order has a receipt.',
    'ui.admin.order_delete.blocker.refunds': 'The order has a refund.',
    'ui.admin.order_delete.blocker.accounting': 'The order is in accounting.',
    'ui.admin.order_delete.blocker.invoice': 'The order has an invoice. Correct it through invoicing.',
    'ui.admin.order_delete.blocker.gift_card': 'The order involves a gift card.',
    'ui.admin.order_delete.blocker.annual_card': 'The order involves an annual card.',
    'ui.admin.order_delete.blocker.voucher_claim': 'The order involves a partner gift card claim.',
    'ui.admin.order_delete.blocker.training': 'Training participant: handle it in the training tool.',
    'ui.admin.order_delete.blocker.reservation_started': 'A booking has already started or taken place.',
    'ui.admin.order_delete.blocker.linked_reservations': 'An add-on of another order is linked to a booking in this order.',
    'ui.admin.order_delete.blocker.external_order': 'Orders imported from Johku are handled in Johku.',
    'ui.admin.order_delete.blocker.external_payment': 'The order has a payment imported from another system.',
    'ui.admin.order_delete.blocker.order_completed': 'A completed order cannot be deleted.',
    'ui.admin.order_delete.blocker.email_claim_uncertain': 'An earlier email attempt may still be active. Deleting is blocked; an old external sender cannot be stopped here.',
    'ui.admin.order_delete.blocker.email_sending': 'An email for this order is being sent right now. Try again in a moment.',
    'ui.admin.order_delete.blocker.unknown': 'The order cannot be deleted.',
    'ui.admin.order_delete.blocked_help': 'Only an unpaid order whose booking has not started yet can be deleted.',
    'ui.admin.order_delete.forbidden': 'You do not have permission to delete orders. Deleting requires booking and payment management rights. The order is unchanged.',
    'ui.admin.order_delete.busy': 'The order is being processed right now. The order is unchanged. Try again in a moment.',
    'ui.admin.order_delete.failed': 'Deleting failed. The order is unchanged.',
    'ui.admin.order_delete.danger_label': 'Dangerous action',
  },
};

const PREFIX = 'ui.admin.order_delete.';
let db = new Map();
let loaded = false;
const fill = (raw, vars) => String(raw ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, v) => (vars && vars[v] != null ? String(vars[v]) : ''));
// Tietokantateksti käytetään vain, jos kaikki sen muuttujat on annettu eikä muita {{…}}-merkintöjä jää.
function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  const out = fill(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}

/** Lukee ui.admin.order_delete.*-rivit. Virhe tai väärä vastaus ei kaada näkymää. */
export async function loadDeleteTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const res = await getSiteTexts(rpcFn);
    if (!res || res.ok !== true || !Array.isArray(res.texts)) return false;
    const next = new Map();
    for (const r of res.texts) {
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

export function clearDeleteTextCache() {
  clearSiteTextsCache();
  db = new Map();
  loaded = false;
}

export function deleteText(key, vars, lang = getLang()) {
  const k = `${PREFIX}${key}`;
  const live = db.get(`${k}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = ORDER_DELETE_TEXTS[lang]?.[k] ?? ORDER_DELETE_TEXTS.fi[k] ?? k;
  return fill(raw, vars);
}
