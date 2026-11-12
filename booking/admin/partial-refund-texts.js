// Tilausnäkymä v3 PR 3 (booking_282–284): osahyvityksen, muutoksen hyvityksen, ylisuorituksen hyvityksen ja atomisen koko tilauksen peruutuksen tekstit
// (FI + EN). Avaimet: ui.admin.order_flow.* (määrittely §6). Sama mekanismi kuin refund-cancel-texts.js: public_get_site_texts peittää sanakirjan,
// sanakirja on varalla. Tuonti: content/site-texts.pending-import-139.json. Tekstit ovat pelkkää tekstiä, ei HTML:ää.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const PREFIX = 'ui.admin.order_flow.';

export const PARTIAL_REFUND_TEXTS = {
  fi: {
    'ui.admin.order_flow.steps.refund': '2 Hyvitys',
    'ui.admin.order_flow.steps.message': '3 Viesti asiakkaalle',
    'ui.admin.order_flow.steps.confirm': '4 Vahvistus',
    'ui.admin.order_flow.refund.question': 'Hyvitetäänkö?',
    'ui.admin.order_flow.refund.partial': 'Hyvitä osa:',
    'ui.admin.order_flow.refund.partial_amount': 'Hyvitettävä summa (€)',
    'ui.admin.order_flow.refund.max': 'enintään {{var:amount}}',
    'ui.admin.order_flow.refund.none': 'Älä hyvitä',
    'ui.admin.order_flow.refund.reason': 'Hyvityksen syy',
    'ui.admin.order_flow.refund.allocation': 'Hyvitys kohdistetaan maksuille: {{var:list}}',
    'ui.admin.order_flow.refund.montonio_note': 'Verkkomaksun hyvitys menee alkuperäiselle maksajalle, yleensä 1–3 pankkipäivässä. Hyvityskuitti syntyy, kun hyvitys on vahvistettu.',
    'ui.admin.order_flow.refund.no_permission': 'Hyvityksen tekee esimies. Osuus jää ylisuoritukseksi Hyvitykset-listalle.',
    'ui.admin.order_flow.refund.invoice_locked': 'Tee hyvityslasku Laskutuksessa.',
    'ui.admin.order_flow.refund.gift_excluded': 'Lahjakortti- ja kumppanikoodiosuutta ei hyvitetä rahana. Raha hyvitetään vain ylimenevältä osalta: {{var:amount}}.',
    'ui.admin.order_flow.refund.amount_invalid': 'Anna hyvitettävä summa: vähintään 0,05 € ja enintään {{var:max}}.',
    'ui.admin.order_flow.message.question': 'Lähetetäänkö asiakkaalle viesti?',
    'ui.admin.order_flow.message.yes_change_with_receipt': 'Kyllä, lähetä muutosvahvistus ja hyvityskuitti',
    'ui.admin.order_flow.message.yes_receipt': 'Kyllä, lähetä hyvityskuitti',
    'ui.admin.order_flow.message.yes_cancel_with_receipt': 'Kyllä, lähetä peruutusvahvistus ja hyvityskuitti',
    'ui.admin.order_flow.message.no': 'Ei, älä lähetä viestiä (kuitti näkyy silti asiakkaan tilaussivulla)',
    'ui.admin.order_flow.message.choose': 'Valitse, lähetetäänkö asiakkaalle viesti.',
    'ui.admin.order_flow.message.no_email': 'Asiakkaalla ei ole sähköpostia, joten viestiä ei lähetetä.',
    'ui.admin.order_flow.change.title': 'Muutoksen hinta ja hyvitys',
    'ui.admin.order_flow.change.new_price': 'Tilauksen summa: {{var:old}} → {{var:new}}',
    'ui.admin.order_flow.change.diff': 'Erotus {{var:diff}}',
    'ui.admin.order_flow.change.overpaid': 'Maksettua on {{var:over}} enemmän kuin uusi summa.',
    'ui.admin.order_flow.change.refund_diff': 'Hyvitä erotus {{var:amount}}',
    'ui.admin.order_flow.change.keep_overpaid': 'Älä hyvitä nyt, jätä ylisuoritukseksi',
    'ui.admin.order_flow.change.extra_payment': 'Uusi summa on suurempi: lisämaksu hoidetaan tilauksen Maksu-kortista (maksulinkki tai maksun otto).',
    'ui.admin.order_flow.change.no_refund_needed': 'Maksettu ei ylitä uutta summaa, hyvitystä ei tarvita.',
    'ui.admin.order_flow.change.preview_failed': 'Hinnan esikatselu ei onnistunut: {{var:error}}',
    'ui.admin.order_flow.change.disabled': 'Osahyvitys ei ole käytössä. Ylisuoritus jää tilaukselle.',
    'ui.admin.order_flow.confirm.change_only': 'Tallenna muutos',
    'ui.admin.order_flow.confirm.change_refund': 'Tallenna muutos ja hyvitä {{var:amount}}',
    'ui.admin.order_flow.confirm.refund_overpaid': 'Hyvitä {{var:amount}}',
    'ui.admin.order_flow.confirm.cancel_all_refund_partial': 'Peru koko tilaus ja hyvitä {{var:amount}}',
    'ui.admin.order_flow.confirm.cancel_refund_partial': 'Peru varaus ja hyvitä {{var:amount}}',
    'ui.admin.order_flow.confirm.back': 'Takaisin',
    'ui.admin.order_flow.over.button': 'Hyvitä ylisuoritus…',
    'ui.admin.order_flow.over.title': 'Hyvitä ylisuoritus',
    'ui.admin.order_flow.over.sub': 'Tilaus #{{var:no}}: maksettua on {{var:over}} enemmän kuin tilauksen summa.',
    'ui.admin.order_flow.over.amount': 'Hyvitettävä summa',
    'ui.admin.order_flow.over.payment': 'Maksu',
    'ui.admin.order_flow.over.payment_auto': 'Automaattisesti (verkkomaksut ensin, sitten käteinen)',
    'ui.admin.order_flow.over.reason_default': 'Ylisuorituksen hyvitys',
    'ui.admin.order_flow.over.non_refundable': 'Ei hyvitettävissä rahana: {{var:amount}} (lahjakortti- tai kumppanikoodiosuus).',
    'ui.admin.order_flow.over.voucher_unused': 'Kumppanilunastus käyttämättä {{var:amount}}',
    'ui.admin.order_flow.over.done': 'Hyvitetty {{var:amount}}.',
    'ui.admin.order_flow.over.nothing': 'Tilauksella ei ole hyvitettävää ylisuoritusta.',
    'ui.admin.order_flow.cancel.atomic_note': 'Koko tilaus perutaan yhdellä toiminnolla: jos jokin vaihe epäonnistuu, mitään ei peruta.',
    'ui.admin.order_flow.cancel.refund_per_payment': 'Yksi hyvitys per maksu: {{var:list}}',
    'ui.admin.order_flow.errors.partial_refunds_disabled': 'Osahyvitys ei ole käytössä.',
    'ui.admin.order_flow.errors.nothing_to_refund': 'Hyvitettävää ylisuoritusta ei ole (se on jo hyvitetty tai käsittelyssä).',
    'ui.admin.order_flow.errors.amount_exceeds_refundable': 'Summa ylittää hyvitettävissä olevan määrän. Päivitä näkymä ja yritä uudelleen.',
    'ui.admin.order_flow.errors.order_invoiced': 'Tilaus on laskutettu: tee korjaus hyvityslaskulla Laskutuksessa.',
    'ui.admin.order_flow.errors.forbidden': 'Hyvitys vaatii esimiehen oikeuden.',
    'ui.admin.order_flow.errors.invalid_amount': 'Hyvityksen vähimmäissumma on 0,05 €.',
  },
  en: {
    'ui.admin.order_flow.steps.refund': '2 Refund',
    'ui.admin.order_flow.steps.message': '3 Message to customer',
    'ui.admin.order_flow.steps.confirm': '4 Confirm',
    'ui.admin.order_flow.refund.question': 'Refund?',
    'ui.admin.order_flow.refund.partial': 'Refund part:',
    'ui.admin.order_flow.refund.partial_amount': 'Amount to refund (€)',
    'ui.admin.order_flow.refund.max': 'up to {{var:amount}}',
    'ui.admin.order_flow.refund.none': 'Do not refund',
    'ui.admin.order_flow.refund.reason': 'Reason for the refund',
    'ui.admin.order_flow.refund.allocation': 'The refund goes to these payments: {{var:list}}',
    'ui.admin.order_flow.refund.montonio_note': 'An online payment refund goes back to the original payer, usually within 1–3 bank days. The refund receipt is created once the refund is confirmed.',
    'ui.admin.order_flow.refund.no_permission': 'A manager makes the refund. The amount stays as an overpayment on the Refunds list.',
    'ui.admin.order_flow.refund.invoice_locked': 'Issue a credit note in Billing.',
    'ui.admin.order_flow.refund.gift_excluded': 'The gift card and partner voucher share is not refunded as money. Only the exceeding part is refunded: {{var:amount}}.',
    'ui.admin.order_flow.refund.amount_invalid': 'Enter an amount of at least €0.05 and at most {{var:max}}.',
    'ui.admin.order_flow.message.question': 'Send a message to the customer?',
    'ui.admin.order_flow.message.yes_change_with_receipt': 'Yes, send the change confirmation and refund receipt',
    'ui.admin.order_flow.message.yes_receipt': 'Yes, send the refund receipt',
    'ui.admin.order_flow.message.yes_cancel_with_receipt': 'Yes, send the cancellation confirmation and refund receipt',
    'ui.admin.order_flow.message.no': 'No, do not send a message (the receipt is still shown on the customer’s order page)',
    'ui.admin.order_flow.message.choose': 'Choose whether to send the customer a message.',
    'ui.admin.order_flow.message.no_email': 'The customer has no email address, so no message is sent.',
    'ui.admin.order_flow.change.title': 'Price and refund for the change',
    'ui.admin.order_flow.change.new_price': 'Order total: {{var:old}} → {{var:new}}',
    'ui.admin.order_flow.change.diff': 'Difference {{var:diff}}',
    'ui.admin.order_flow.change.overpaid': 'The customer has paid {{var:over}} more than the new total.',
    'ui.admin.order_flow.change.refund_diff': 'Refund the difference {{var:amount}}',
    'ui.admin.order_flow.change.keep_overpaid': 'Do not refund now, keep as an overpayment',
    'ui.admin.order_flow.change.extra_payment': 'The new total is higher: take the extra payment from the order’s Payment card (payment link or take payment).',
    'ui.admin.order_flow.change.no_refund_needed': 'The amount paid does not exceed the new total, so no refund is needed.',
    'ui.admin.order_flow.change.preview_failed': 'Price preview failed: {{var:error}}',
    'ui.admin.order_flow.change.disabled': 'Partial refunds are not enabled. The overpayment stays on the order.',
    'ui.admin.order_flow.confirm.change_only': 'Save change',
    'ui.admin.order_flow.confirm.change_refund': 'Save change and refund {{var:amount}}',
    'ui.admin.order_flow.confirm.refund_overpaid': 'Refund {{var:amount}}',
    'ui.admin.order_flow.confirm.cancel_all_refund_partial': 'Cancel the whole order and refund {{var:amount}}',
    'ui.admin.order_flow.confirm.cancel_refund_partial': 'Cancel the reservation and refund {{var:amount}}',
    'ui.admin.order_flow.confirm.back': 'Back',
    'ui.admin.order_flow.over.button': 'Refund overpayment…',
    'ui.admin.order_flow.over.title': 'Refund overpayment',
    'ui.admin.order_flow.over.sub': 'Order #{{var:no}}: the customer has paid {{var:over}} more than the order total.',
    'ui.admin.order_flow.over.amount': 'Amount to refund',
    'ui.admin.order_flow.over.payment': 'Payment',
    'ui.admin.order_flow.over.payment_auto': 'Automatically (online payments first, then cash)',
    'ui.admin.order_flow.over.reason_default': 'Overpayment refund',
    'ui.admin.order_flow.over.non_refundable': 'Not refundable as money: {{var:amount}} (gift card or partner voucher share).',
    'ui.admin.order_flow.over.voucher_unused': 'Partner redemption unused {{var:amount}}',
    'ui.admin.order_flow.over.done': 'Refunded {{var:amount}}.',
    'ui.admin.order_flow.over.nothing': 'The order has no refundable overpayment.',
    'ui.admin.order_flow.cancel.atomic_note': 'The whole order is cancelled in one operation: if any step fails, nothing is cancelled.',
    'ui.admin.order_flow.cancel.refund_per_payment': 'One refund per payment: {{var:list}}',
    'ui.admin.order_flow.errors.partial_refunds_disabled': 'Partial refunds are not enabled.',
    'ui.admin.order_flow.errors.nothing_to_refund': 'There is no refundable overpayment (it has already been refunded or is being processed).',
    'ui.admin.order_flow.errors.amount_exceeds_refundable': 'The amount exceeds what can be refunded. Refresh the view and try again.',
    'ui.admin.order_flow.errors.order_invoiced': 'The order has been invoiced: issue a credit note in Billing.',
    'ui.admin.order_flow.errors.forbidden': 'Refunds require a manager’s permission.',
    'ui.admin.order_flow.errors.invalid_amount': 'The minimum refund is €0.05.',
  },
};

let db = new Map();
let loaded = false;

export function fillPrText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  const out = fillPrText(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}

function prime(rows) {
  if (!Array.isArray(rows)) return false;
  const next = new Map();
  for (const r of rows) {
    if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX)) continue;
    if (r.lang !== 'fi' && r.lang !== 'en') continue;
    if (typeof r.text !== 'string' || !r.text.trim()) continue;
    next.set(`${r.key}|${r.lang}`, r.text);
  }
  db = next; loaded = true;
  return true;
}

export async function loadPrTexts(rpcFn, rows = null) {
  if (prime(rows)) return true;
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    return prime(t.texts);
  } catch { return false; }
}

export function clearPrTextCache() { db = new Map(); loaded = false; clearSiteTextsCache(); }

/** key ilman etuliitettä: prText('refund.partial'). */
export function prText(key, vars, lang = getLang()) {
  const full = key.startsWith(PREFIX) ? key : PREFIX + key;
  const live = db.get(`${full}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = PARTIAL_REFUND_TEXTS[lang]?.[full] ?? PARTIAL_REFUND_TEXTS.fi[full] ?? full;
  return vars ? fillPrText(raw, vars) : raw;
}
