export const DRINKS_TEXTS = {
  fi: {
    title: 'Juomat',
    lead: 'Valitse juoma ja maksa puhelimella',
    total: 'Yhteensä',
    pay: 'Maksa',
    email: 'Sähköposti kuitille',
    email_hint: 'Vapaaehtoinen',
    mobilepay: 'MobilePay',
    visma: 'Verkkomaksu',
    visma_dry: 'Verkkomaksu on testitilassa, maksua ei veloiteta',
    visma_off: 'Verkkomaksu ei ole juuri nyt käytössä',
    visma_live: 'Verkkomaksun tuotantoyhteys ei ole vielä käytössä',
    paid: 'Maksettu',
    waiting: 'Odotetaan maksua',
    empty: 'Ei juomia myynnissä',
    device: 'Laite',
    no_device: 'QR-koodi ei vastaa käytössä olevaa laitetta',
    qty: 'Määrä',
    add: 'Lisää',
    remove: 'Vähennä',
    invalid_email: 'Sähköposti ei ole kelvollinen',
    pay_legal: 'Hinta sisältää arvonlisäveron. Kuitti lähetetään, jos annat sähköpostin.',
  },
  en: {
    title: 'Drinks',
    lead: 'Choose a drink and pay on your phone',
    total: 'Total',
    pay: 'Pay',
    email: 'Email for the receipt',
    email_hint: 'Optional',
    mobilepay: 'MobilePay',
    visma: 'Online payment',
    visma_dry: 'Online payment is in test mode and is not charged',
    visma_off: 'Online payment is not available right now',
    visma_live: 'The live online payment connection is not available yet',
    paid: 'Paid',
    waiting: 'Waiting for payment',
    empty: 'No drinks for sale',
    device: 'Device',
    no_device: 'This QR code does not match an active device',
    qty: 'Quantity',
    add: 'Add',
    remove: 'Decrease',
    invalid_email: 'The email address is not valid',
    pay_legal: 'The price includes VAT. A receipt is sent if you give an email address.',
  },
};

export const DRINKS_EXTRA = {
  fi: {
    qr_missing: 'Tämä QR-koodi ei ole käytössä',
  },
  en: {
    qr_missing: 'This QR code is not in use',
  },
};

const PREFIX = 'ui.drinks.';
let db = new Map();

export async function loadDrinksTexts(rpcFn) {
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await rpcFn('public_get_site_texts', { p_lang: null });
    const rows = Array.isArray(t?.texts) ? t.texts : [];
    const next = new Map();
    for (const r of rows) {
      if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX)) continue;
      if (r.lang !== 'fi' && r.lang !== 'en') continue;
      if (typeof r.text !== 'string' || !r.text.trim()) continue;
      next.set(`${r.key}|${r.lang}`, r.text);
    }
    if (next.size) db = next;
    return next.size > 0;
  } catch {
    return false;
  }
}

export function drinksText(key, lang = 'fi') {
  const live = db.get(`${PREFIX}${key}|${lang}`);
  if (live) return live;
  return DRINKS_TEXTS[lang]?.[key] || DRINKS_EXTRA[lang]?.[key] || DRINKS_TEXTS.fi[key] || DRINKS_EXTRA.fi[key] || key;
}
