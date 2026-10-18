// Varaus-/tilaussivujen (booking/shop/build.mjs) staattiset sivutekstit: otsikot, ingressit, meta, noscript. Avaimet §18.2: page.<sivu>.<kenttä>, seo.<sivu>.<kenttä>.
// build.mjs lukee ne tx(avain, kieli, { fallback }) -kutsulla tietokannasta (src/site-texts.mjs); fallback = tässä oleva oletus (ei visuaalista muutosta ennen kuin avaimet on tuotu).
// Yritysnimi kirjoitusasulla "Sipoonjoen Perinnesauna" (iso P; public_settings.business_name yhtenäistetty, booking_65).
export const SHOP_PAGE_TEXTS = [
  { key: 'page.book.title', fi: 'Varaa saunaelämys', en: 'Book a sauna experience' },
  { key: 'page.book.lead', fi: 'Valitse kokemus, päivä ja vuoro – varaus vahvistetaan heti.', en: 'Choose an experience, a day and a session – your booking is confirmed instantly.' },
  { key: 'seo.book.title', fi: 'Varaa saunavuoro verkossa | Sipoonjoen Perinnesauna', en: 'Book a sauna session online | Sipoonjoen Perinnesauna' },
  { key: 'seo.book.description', fi: 'Varaa yleinen saunavuoro tai yksityisvuoro suoraan Sipoonjoen Perinnesaunalle.', en: 'Book a public or private sauna session directly at Sipoonjoen Perinnesauna.' },
  { key: 'page.book.noscript', fi: 'Varauskalenteri vaatii JavaScriptin. Varaa soittamalla', en: 'The booking calendar requires JavaScript. Please book by phone' },
  { key: 'page.book_confirm.title', fi: 'Varausvahvistus', en: 'Booking confirmation' },
  { key: 'seo.book_confirm.title', fi: 'Varausvahvistus | Sipoonjoen Perinnesauna', en: 'Booking confirmation | Sipoonjoen Perinnesauna' },
  { key: 'page.order.title', fi: 'Tilauksesi', en: 'Your order' },
  { key: 'page.order.lead', fi: 'Tilauksen rivit, maksutila ja kuitit.', en: 'Order lines, payment status and receipts.' },
  { key: 'seo.order.title', fi: 'Tilauksesi | Sipoonjoen Perinnesauna', en: 'Your order | Sipoonjoen Perinnesauna' },
  { key: 'page.order.noscript', fi: 'Tilaussivu vaatii JavaScriptin. Ota yhteyttä', en: 'The order page requires JavaScript. Please contact us' },
];
const BY_KEY = new Map(SHOP_PAGE_TEXTS.map((r) => [r.key, r]));
/** Oletusteksti (repon varateksti) avaimelle ja kielelle. */
export const pageDefault = (key, lang) => { const r = BY_KEY.get(key); if (!r) throw new Error(`tuntematon sivuteksti ${key}`); return r[lang === 'en' ? 'en' : 'fi']; };
