// Pikakassan tekstit (FI+EN). Tuotannossa sama sisältö tuodaan site_texts-tauluun (pending-import-12).
// Uudet muokkaus- ja QR-myyntitekstit: pending-import-16 (POS_EDIT_TEXTS).
// Maksupopupin uudet avaimet: pending-import-17 (POS_PAY_TEXTS). Sanakirja on varalla, kunnes tuonti on ajettu.
// Maksulinkin sähköposti: pending-import-18 (POS_LINK_TEXTS). Allekirjoitus Tapio on email.payment_link.sign_name.
// Asiakaskentän uusi otsikko ja vihje: pending-import-113 (POS_CUSTOMER_TEXTS). Vanhat ui.pos.email / email_help jäävät tuoduiksi.
// public_get_site_texts peittää ui.pos.*-avaimet. Haku epäonnistuu tai rivi puuttuu → sanakirja.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const POS_TEXTS = {
  fi: {
    'nav': 'Pikakassa',
    'title': 'Pikakassa',
    'pay': 'Maksa',
    'lines': 'Maksurivit',
    'total': 'Yhteensä',
    'empty': 'Ostoskori on tyhjä',
    'remove': 'Poista',
    'qty': 'Määrä',
    'method': 'Maksutapa',
    'method_link': 'Maksulinkki',
    'method_mobilepay': 'MobilePay',
    'method_qr': 'QR-koodi',
    'method_push': 'Pyyntö puhelimeen',
    'method_terminal': 'Korttipääte',
    'terminal_later': 'Tulossa',
    'phone': 'Puhelinnumero',
    'phone_invalid': 'Anna suomalainen matkapuhelinnumero',
    'paid': 'Maksettu',
    'waiting': 'Odotetaan maksua',
    'link_help': 'Asiakas avaa linkin tai skannaa koodin',
    'qr_help': 'Asiakas skannaa koodin omalla puhelimellaan',
    'push_help': 'Pyyntö lähtee asiakkaan MobilePay-sovellukseen',
    'no_products': 'Pikakassaan ei ole valittu tuotteita',
    'pick_method': 'Valitse maksutapa maksuriveistä',
    'gift_blocked': 'Lahjakortti myydään Talous-näkymässä',
    'age': 'Ikärajallinen',
    'devices': 'Kylmälaitteet',
    'device_name': 'Laitteen nimi',
    'device_location': 'Sijainti',
    'device_add': 'Lisää laite',
    'device_print': 'Tulosta QR',
    'print_help': 'Skannaa koodi ja maksa juoma puhelimella',
    'product_pos': 'Näytä pikakassassa',
    'product_pos_sort': 'Pikakassan järjestys',
    'product_fridge': 'Myytävissä kylmälaitteessa',
    'product_age': 'Ikärajallinen tuote',
    'fridge_warn': 'Kylmälaitteeseen vain virvoitusjuomia',
    'alcohol_warn': 'Tuotteen nimi näyttää alkoholilta, sitä ei voi myydä kylmälaitteessa',
    'next': 'Seuraava asiakas',
    'close': 'Sulje',
    'mp_off': 'MobilePay ei ole käytössä',
    'visma_off': 'Verkkomaksu ei ole käytössä',
    'badge_pos': 'Pikakassa',
    'badge_fridge': 'Kylmälaite',
    'pay_legal': 'Maksu vahvistetaan ennen luovutusta. Kuitti syntyy, kun maksu on kirjautunut.',
  },
  en: {
    'nav': 'Quick till',
    'title': 'Quick till',
    'pay': 'Pay',
    'lines': 'Payment lines',
    'total': 'Total',
    'empty': 'The cart is empty',
    'remove': 'Remove',
    'qty': 'Quantity',
    'method': 'Payment method',
    'method_link': 'Payment link',
    'method_mobilepay': 'MobilePay',
    'method_qr': 'QR code',
    'method_push': 'Request to phone',
    'method_terminal': 'Card terminal',
    'terminal_later': 'Coming later',
    'phone': 'Phone number',
    'phone_invalid': 'Enter a Finnish mobile number',
    'paid': 'Paid',
    'waiting': 'Waiting for payment',
    'link_help': 'The customer opens the link or scans the code',
    'qr_help': 'The customer scans the code with their own phone',
    'push_help': 'The request is sent to the customer MobilePay app',
    'no_products': 'No products are selected for the till',
    'pick_method': 'Choose a payment method from the lines',
    'gift_blocked': 'Gift cards are sold in the finance view',
    'age': 'Age restricted',
    'devices': 'Fridges',
    'device_name': 'Device name',
    'device_location': 'Location',
    'device_add': 'Add device',
    'device_print': 'Print QR',
    'print_help': 'Scan the code and pay for the drink on your phone',
    'product_pos': 'Show in the quick till',
    'product_pos_sort': 'Till order',
    'product_fridge': 'Sold in the fridge',
    'product_age': 'Age-restricted product',
    'fridge_warn': 'Only soft drinks belong in the fridge',
    'alcohol_warn': 'The product name looks like alcohol and cannot be sold from the fridge',
    'next': 'Next customer',
    'close': 'Close',
    'mp_off': 'MobilePay is not enabled',
    'visma_off': 'Online payment is not enabled',
    'badge_pos': 'Till',
    'badge_fridge': 'Fridge',
    'pay_legal': 'Payment is confirmed before the goods are handed over. The receipt is created when the payment is recorded.',
  },
};

export const POS_EDIT_TEXTS = {
  fi: {
    edit: 'Muokkaa pikakassaa',
    add: 'Lisää tuote pikakassaan',
    search: 'Hae tuotetta',
    in_till: 'Pikakassassa',
    not_shop: 'Ei näy verkkokaupassa',
    up: 'Siirrä ylös',
    down: 'Siirrä alas',
    done: 'Valmis',
    empty_help: 'Lisää tuotteita pikakassaan. Mukana voivat olla myös tuotteet, jotka eivät näy verkkokaupassa.',
    qr_sale: 'Ostettavissa QR-linkillä',
    qr_sale_hint: 'Linkki ei näytä tuotetta verkkokaupan listassa. Ikärajallista tuotetta ei voi valita.',
    alcohol_qr: 'Tuotteen nimi näyttää alkoholilta, sitä ei voi myydä QR-linkillä',
    badge_qr: 'QR-linkki',
    added: 'Tuote lisätty pikakassaan',
    removed_pos: 'Tuote poistettu pikakassasta',
  },
  en: {
    edit: 'Edit the quick till',
    add: 'Add a product to the quick till',
    search: 'Search for a product',
    in_till: 'On the till',
    not_shop: 'Hidden from the shop',
    up: 'Move up',
    down: 'Move down',
    done: 'Done',
    empty_help: 'Add products to the till. Products that are hidden from the shop can be included.',
    qr_sale: 'Purchasable with a QR link',
    qr_sale_hint: 'The link does not list the product in the shop. An age-restricted product cannot be selected.',
    alcohol_qr: 'The product name looks like alcohol and cannot be sold with a QR link',
    badge_qr: 'QR link',
    added: 'Product added to the quick till',
    removed_pos: 'Product removed from the quick till',
  },
};

export const POS_LINK_TEXTS = {
  fi: {
    email: 'Asiakkaan sähköposti',
    email_help: 'Maksulinkki lähetetään tähän osoitteeseen',
    email_invalid: 'Tarkista sähköpostiosoite',
    email_required: 'Anna sähköpostiosoite',
    link_sent_to: 'Linkki lähtee osoitteeseen',
    mail_pending: 'Viesti on jonossa',
    mail_sent: 'Viesti on lähetetty',
    mail_dry_run: 'Testitila: viesti ei lähde oikeasti',
    mail_failed: 'Viestin lähetys epäonnistui',
    mail_resend: 'Lähetä uudelleen',
    mail_off: 'Sähköpostilähetys ei ole käytössä',
    vismapay_off: 'Verkkomaksu ei ole käytössä, joten maksulinkillä ei voi maksaa',
  },
  en: {
    email: 'Customer email',
    email_help: 'The payment link is sent to this address',
    email_invalid: 'Check the email address',
    email_required: 'Enter an email address',
    link_sent_to: 'The link is sent to',
    mail_pending: 'The message is queued',
    mail_sent: 'The message has been sent',
    mail_dry_run: 'Test mode: the message is not actually sent',
    mail_failed: 'Sending the message failed',
    mail_resend: 'Send again',
    mail_off: 'Email sending is turned off',
    vismapay_off: 'Online payment is off, so the payment link cannot be used',
  },
};

export const POS_CUSTOMER_TEXTS = {
  fi: {
    customer: 'Asiakas (nimi tai sähköposti)',
    customer_help: 'Hae asiakasrekisteristä tai kirjoita sähköposti. Maksulinkki lähetetään tähän osoitteeseen.',
    customer_list: 'Asiakkaat',
  },
  en: {
    customer: 'Customer (name or email)',
    customer_help: 'Search the customer register or type an email. The payment link is sent to this address.',
    customer_list: 'Customers',
  },
};

export const POS_PAY_TEXTS = {
  fi: {
    pay_title: 'Maksu',
    amount: 'Summa',
    confirm: 'Vahvista maksu',
    choose_method: 'Valitse maksutapa',
    wait: 'Odotetaan',
  },
  en: {
    pay_title: 'Payment',
    amount: 'Amount',
    confirm: 'Confirm payment',
    choose_method: 'Choose a payment method',
    wait: 'Please wait',
  },
};


export const POS_CUSTOM_TEXTS = {
  fi: {
    custom_add: 'Lisää vapaa rivi',
    custom_title: 'Vapaa rivi',
    custom_description: 'Kuvaus',
    custom_qty: 'Määrä',
    custom_price: 'Yksikköhinta (€)',
    custom_vat: 'ALV',
    custom_save: 'Lisää koriin',
    custom_cancel: 'Peruuta',
    custom_open: 'Vapaan rivin kentät',
    description_required: 'Anna kuvaus',
    description_long: 'Kuvaus on liian pitkä (enintään 200 merkkiä)',
    description_invalid: 'Kuvaus ei ole kelvollinen',
    quantity_invalid: 'Määrän pitää olla 1–20',
    price_invalid: 'Anna hinta euroina (esim. 5,50)',
    vat_invalid: 'Valitse sallittu ALV-kanta',
    vat_breakdown: 'ALV-erittely',
  },
  en: {
    custom_add: 'Add custom line',
    custom_title: 'Custom line',
    custom_description: 'Description',
    custom_qty: 'Quantity',
    custom_price: 'Unit price (€)',
    custom_vat: 'VAT',
    custom_save: 'Add to cart',
    custom_cancel: 'Cancel',
    custom_open: 'Custom line fields',
    description_required: 'Enter a description',
    description_long: 'Description is too long (max 200 characters)',
    description_invalid: 'Description is not valid',
    quantity_invalid: 'Quantity must be 1–20',
    price_invalid: 'Enter the price in euros (e.g. 5.50)',
    vat_invalid: 'Choose an allowed VAT rate',
    vat_breakdown: 'VAT breakdown',
  },
};

// Kortti puhelimella (CheckoutX / Surfboard demo, booking_286): pending-import-141 (POS_CHECKOUTX_TEXTS). Näkyy vain testitilassa.
export const POS_CHECKOUTX_TEXTS = {
  fi: {
    method_checkoutx: 'Kortti puhelimella (CheckoutX)',
    cx_test_note: 'Testiympäristö: CheckoutX-maksut mitätöidään, eikä rahaa veloiteta.',
    cx_phone: 'Tämä puhelin',
    cx_pick: 'Valitse puhelin',
    cx_no_terminal: 'Tätä puhelinta ei ole liitetty CheckoutX:ään.',
    cx_register: 'Liitä tämä puhelin CheckoutX:ään',
    cx_register_label: 'Puhelimen nimi',
    cx_register_wait: 'Vahvista liitos CheckoutX-sovelluksessa ja palaa sitten tähän näkymään.',
    cx_register_done: 'Puhelin on liitetty CheckoutX:ään.',
    cx_register_expired: 'Liitoskoodi vanheni. Yritä uudelleen.',
    cx_register_admin: 'Pyydä ylläpitäjää liittämään tämä puhelin CheckoutX:ään.',
    cx_open: 'Avaa CheckoutX',
    cx_configure: 'Valmistele CheckoutX',
    cx_waiting_help: 'Asiakas koskettaa korttia tai puhelinta tämän puhelimen takaosaan. Palaa sitten tähän näkymään.',
    cx_failed: 'Korttimaksu ei onnistunut.',
    cx_cancelled: 'Korttimaksu peruttiin.',
    cx_retry: 'Yritä uudelleen',
    cx_cancel: 'Peru maksu',
    cx_already_paid: 'Asiakas ehti maksaa, joten maksua ei peruttu.',
    cx_off: 'Kortti puhelimella ei ole käytössä.',
    cx_not_configured: 'CheckoutX-tunnukset puuttuvat. Maksua ei aloitettu.',
    cx_not_connected: 'Puhelimen CheckoutX ei ole yhteydessä. Valmistele CheckoutX ja yritä uudelleen.',
    cx_unavailable: 'CheckoutX ei vastaa juuri nyt. Yritä hetken kuluttua uudelleen.',
    cx_provider_error: 'CheckoutX ei hyväksynyt maksua. Yritä uudelleen.',
    cx_in_progress: 'Tilauksella on jo avoin maksu toisella maksutavalla.',
    cx_forbidden: 'Sinulla ei ole oikeutta tähän toimintoon.',
  },
  en: {
    method_checkoutx: 'Card on phone (CheckoutX)',
    cx_test_note: 'Test environment: CheckoutX payments are voided and no money is charged.',
    cx_phone: 'This phone',
    cx_pick: 'Choose phone',
    cx_no_terminal: 'This phone is not linked to CheckoutX.',
    cx_register: 'Link this phone to CheckoutX',
    cx_register_label: 'Phone name',
    cx_register_wait: 'Confirm the link in the CheckoutX app, then come back to this view.',
    cx_register_done: 'The phone is linked to CheckoutX.',
    cx_register_expired: 'The link code expired. Please try again.',
    cx_register_admin: 'Ask an administrator to link this phone to CheckoutX.',
    cx_open: 'Open CheckoutX',
    cx_configure: 'Prepare CheckoutX',
    cx_waiting_help: 'The customer taps their card or phone on the back of this phone. Then come back to this view.',
    cx_failed: 'The card payment did not go through.',
    cx_cancelled: 'The card payment was cancelled.',
    cx_retry: 'Try again',
    cx_cancel: 'Cancel payment',
    cx_already_paid: 'The customer had already paid, so the payment was not cancelled.',
    cx_off: 'Card on phone is not in use.',
    cx_not_configured: 'CheckoutX credentials are missing. The payment was not started.',
    cx_not_connected: 'CheckoutX on this phone is not connected. Prepare CheckoutX and try again.',
    cx_unavailable: 'CheckoutX is not responding right now. Please try again shortly.',
    cx_provider_error: 'CheckoutX did not accept the payment. Please try again.',
    cx_in_progress: 'The order already has an open payment with another method.',
    cx_forbidden: 'You do not have permission for this action.',
  },
};

const PREFIX = 'ui.pos.';
let db = new Map();
let loaded = false;

export async function loadPosTexts(rpcFn) {
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

export function clearPosTextCache() {
  clearSiteTextsCache();
  db = new Map();
  loaded = false;
}

export function posText(key, lang = getLang()) {
  const live = db.get(`${PREFIX}${key}|${lang}`);
  if (live) return live;
  return POS_TEXTS[lang]?.[key] || POS_EDIT_TEXTS[lang]?.[key] || POS_PAY_TEXTS[lang]?.[key] || POS_LINK_TEXTS[lang]?.[key] || POS_CUSTOMER_TEXTS[lang]?.[key] || POS_CUSTOM_TEXTS[lang]?.[key] || POS_CHECKOUTX_TEXTS[lang]?.[key]
    || POS_TEXTS.fi[key] || POS_EDIT_TEXTS.fi[key] || POS_PAY_TEXTS.fi[key] || POS_LINK_TEXTS.fi[key] || POS_CUSTOMER_TEXTS.fi[key] || POS_CUSTOM_TEXTS.fi[key] || POS_CHECKOUTX_TEXTS.fi[key] || key;
}
