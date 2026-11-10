// booking_257. Hallinnan Viestit-sivun «Viesti asiakkaalle» -välilehden tekstit (FI + EN).
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu tai rivi puuttuu → CUSTOMER_MESSAGE_TEXTS.
// Tuonti: content/site-texts.pending-import-129.json.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const PREFIX = 'ui.admin.customer_message.';

export const CUSTOMER_MESSAGE_TEXTS = {
  "fi": {
    "ui.admin.customer_message.tab_templates": "Pohjat",
    "ui.admin.customer_message.tab": "Viesti asiakkaalle",
    "ui.admin.customer_message.title": "Viesti asiakkaalle",
    "ui.admin.customer_message.lead": "Valitse yksi päivä tai aikaväli ja tuotteet. Viesti lähtee niille, jotka ovat varanneet valitun tuotteen kyseiselle päivälle (varauksen alkupäivä Helsingissä) tai ostaneet sen (tilauksen maksupäivä Helsingissä). Sama asiakas saa yhden viestin. Peruutetut varaukset, vanhentuneet pidot ja jonotuslista jäävät pois. Markkinointilupaa ei tarvita. Esikatsele ennen lähetystä. Jokainen saa viestin tilauksen kielellä.",
    "ui.admin.customer_message.lead_date_products": "Valitse yksi päivä tai aikaväli. Tuotevalintaan tulevat vain tuotteet, joita tuona päivänä tai välillä on varattu (varauksen alkupäivä Helsingissä) tai myyty (tilauksen maksupäivä Helsingissä). Viesti lähtee niille, jotka ovat varanneet tai ostaneet valitun tuotteen. Sama asiakas saa yhden viestin. Peruutetut varaukset, vanhentuneet pidot ja jonotuslista jäävät pois. Markkinointilupaa ei tarvita. Esikatsele ennen lähetystä. Jokainen saa viestin tilauksen kielellä.",
    "ui.admin.customer_message.from": "Päivä tai alku",
    "ui.admin.customer_message.to": "Loppu",
    "ui.admin.customer_message.to_hint": "Tyhjä = sama päivä. Molemmat päät ovat mukana. Päivämäärät ovat Helsingin aikaa.",
    "ui.admin.customer_message.products": "Tuotteet",
    "ui.admin.customer_message.select_all": "Valitse kaikki",
    "ui.admin.customer_message.clear": "Tyhjennä",
    "ui.admin.customer_message.hidden": "(piilotettu)",
    "ui.admin.customer_message.subject": "Aihe",
    "ui.admin.customer_message.body": "Viesti",
    "ui.admin.customer_message.lang_fi": "Suomi",
    "ui.admin.customer_message.lang_en": "English",
    "ui.admin.customer_message.vars": "Paikkamerkit",
    "ui.admin.customer_message.var_tuote": "Vastaanottajan tuotteet hänen kielellään",
    "ui.admin.customer_message.var_paiva": "Ensisijaisen varauksen tai oston päivämäärä",
    "ui.admin.customer_message.var_kello": "Varauksen kellonaika. Tyhjä ostolle ilman varausaikaa.",
    "ui.admin.customer_message.var_nimi": "Asiakkaan nimi",
    "ui.admin.customer_message.var_hlot": "Henkilömäärä. Tyhjä ostolle ilman varausta.",
    "ui.admin.customer_message.var_linkki": "Linkki tilaussivulle",
    "ui.admin.customer_message.preview": "Esikatsele",
    "ui.admin.customer_message.preview_n": "{n} vastaanottajaa",
    "ui.admin.customer_message.skipped_n": "{n} ilman sähköpostia",
    "ui.admin.customer_message.no_email": "Ei sähköpostia",
    "ui.admin.customer_message.send_confirm": "Kyllä, lähetä viesti valituille",
    "ui.admin.customer_message.send": "Lähetä",
    "ui.admin.customer_message.sent": "Viesti laitettu jonoon",
    "ui.admin.customer_message.none": "Ei vastaanottajia tällä valinnalla.",
    "ui.admin.customer_message.log": "Lähetetyt",
    "ui.admin.customer_message.log_empty": "Ei lähetettyjä viestejä.",
    "ui.admin.customer_message.sample": "Esimerkki ensimmäiselle vastaanottajalle",
    "ui.admin.customer_message.need_preview": "Esikatsele ensin ja vahvista lähetys.",
    "ui.admin.customer_message.error_dates": "Valitse päivä tai aikaväli.",
    "ui.admin.customer_message.error_products": "Valitse vähintään yksi tuote.",
    "ui.admin.customer_message.error_text": "Kirjoita aihe ja viesti suomeksi ja englanniksi.",
    "ui.admin.customer_message.recipients": "Vastaanottajat",
    "ui.admin.customer_message.skipped": "Ohitetut",
    "ui.admin.customer_message.products_need_dates": "Valitse ensin päivä tai aikaväli. Tuotevalintaan tulevat vain kyseisenä päivänä tai välillä varatut tai myydyt tuotteet.",
    "ui.admin.customer_message.products_loading": "Ladataan tuotteita…",
    "ui.admin.customer_message.products_empty": "Ei varattuja tai myytyjä tuotteita valitulla päivällä tai aikavälillä.",
    "ui.admin.customer_message.products_error": "Tuotteiden haku epäonnistui."
  },
  "en": {
    "ui.admin.customer_message.tab_templates": "Templates",
    "ui.admin.customer_message.tab": "Message to customer",
    "ui.admin.customer_message.title": "Message to customer",
    "ui.admin.customer_message.lead": "Choose one day or a date range and the products. The message goes to people who booked a selected product on that day (reservation start date in Helsinki) or bought it (order payment date in Helsinki). Each customer receives one message. Cancelled reservations, expired holds and the waitlist are left out. Marketing consent is not required. Preview before sending. Each person receives the message in their order language.",
    "ui.admin.customer_message.lead_date_products": "Choose one day or a date range. The product list shows only products reserved (reservation start date in Helsinki) or sold (order payment date in Helsinki) on that day or range. The message goes to people who booked or bought a selected product. Each customer receives one message. Cancelled reservations, expired holds and the waitlist are left out. Marketing consent is not required. Preview before sending. Each person receives the message in their order language.",
    "ui.admin.customer_message.from": "Day or start",
    "ui.admin.customer_message.to": "End",
    "ui.admin.customer_message.to_hint": "Leave empty for a single day. Both ends are inclusive. Dates use Helsinki time.",
    "ui.admin.customer_message.products": "Products",
    "ui.admin.customer_message.select_all": "Select all",
    "ui.admin.customer_message.clear": "Clear",
    "ui.admin.customer_message.hidden": "(hidden)",
    "ui.admin.customer_message.subject": "Subject",
    "ui.admin.customer_message.body": "Message",
    "ui.admin.customer_message.lang_fi": "Suomi",
    "ui.admin.customer_message.lang_en": "English",
    "ui.admin.customer_message.vars": "Placeholders",
    "ui.admin.customer_message.var_tuote": "The recipient’s products in their language",
    "ui.admin.customer_message.var_paiva": "Date of the primary booking or purchase",
    "ui.admin.customer_message.var_kello": "Booking time. Empty for a purchase without a reservation time.",
    "ui.admin.customer_message.var_nimi": "Customer name",
    "ui.admin.customer_message.var_hlot": "Party size. Empty for a purchase without a reservation.",
    "ui.admin.customer_message.var_linkki": "Link to the order page",
    "ui.admin.customer_message.preview": "Preview",
    "ui.admin.customer_message.preview_n": "{n} recipients",
    "ui.admin.customer_message.skipped_n": "{n} without an email address",
    "ui.admin.customer_message.no_email": "No email",
    "ui.admin.customer_message.send_confirm": "Yes, send the message to the selected people",
    "ui.admin.customer_message.send": "Send",
    "ui.admin.customer_message.sent": "Message queued",
    "ui.admin.customer_message.none": "No recipients for this selection.",
    "ui.admin.customer_message.log": "Sent",
    "ui.admin.customer_message.log_empty": "No messages sent yet.",
    "ui.admin.customer_message.sample": "Example for the first recipient",
    "ui.admin.customer_message.need_preview": "Preview first and confirm sending.",
    "ui.admin.customer_message.error_dates": "Choose a day or a date range.",
    "ui.admin.customer_message.error_products": "Choose at least one product.",
    "ui.admin.customer_message.error_text": "Write the subject and message in Finnish and English.",
    "ui.admin.customer_message.recipients": "Recipients",
    "ui.admin.customer_message.skipped": "Skipped",
    "ui.admin.customer_message.products_need_dates": "Choose a day or date range first. Only products reserved or sold on that day or range appear here.",
    "ui.admin.customer_message.products_loading": "Loading products…",
    "ui.admin.customer_message.products_empty": "No reserved or sold products for the selected day or date range.",
    "ui.admin.customer_message.products_error": "Could not load products."
  }
};

let db = new Map();
let loaded = false;

export async function loadCustomerMessageTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
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

export function clearCustomerMessageTextCache() {
  clearSiteTextsCache();
  db = new Map();
  loaded = false;
}

export function customerMessageText(key, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  if (live) return live;
  return CUSTOMER_MESSAGE_TEXTS[lang]?.[key] ?? CUSTOMER_MESSAGE_TEXTS.fi[key] ?? key;
}
