// Pikakassan tekstit (FI+EN). Tuotannossa sama sisältö tuodaan site_texts-tauluun (pending-import-12).
// Uudet muokkaus- ja QR-myyntitekstit: pending-import-16 (POS_EDIT_TEXTS).
// Maksupopupin uudet avaimet: pending-import-17 (POS_PAY_TEXTS). Sanakirja on varalla, kunnes tuonti on ajettu.
// public_get_site_texts peittää ui.pos.*-avaimet. Haku epäonnistuu tai rivi puuttuu → sanakirja.
import { getLang } from './talous-i18n.js';

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

const PREFIX = 'ui.pos.';
let db = new Map();
let loaded = false;

export async function loadPosTexts(rpcFn) {
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

export function clearPosTextCache() {
  db = new Map();
  loaded = false;
}

export function posText(key, lang = getLang()) {
  const live = db.get(`${PREFIX}${key}|${lang}`);
  if (live) return live;
  return POS_TEXTS[lang]?.[key] || POS_EDIT_TEXTS[lang]?.[key] || POS_PAY_TEXTS[lang]?.[key] || POS_TEXTS.fi[key] || POS_EDIT_TEXTS.fi[key] || POS_PAY_TEXTS.fi[key] || key;
}
