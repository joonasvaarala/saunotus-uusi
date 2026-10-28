// Julkaistu lahjakorttivalikoima (booking_196). Sama lista esirenderöinnille, metakuvaukselle,
// Product/Offer-JSON-LD:lle ja kaupan mockille. Elävä kauppa lukee public_gift_card_packages;
// kun kanta on ajan tasalla, nimet ja oletushinnat (2 hlö) ovat nämä. Vuosikortti ei ole
// tässä: se näkyy vain, jos public_annual_card_offer.available (annual_card_sale_enabled).
export const PUBLISHED_GIFT_PACKAGES = [
  {
    code: 'open',
    name: 'Avoin lahjakortti',
    name_en: 'Open gift card',
    description: 'Vapaa summa; käy kaikkiin palveluihin. Voimassa 6 kuukautta.',
    description_en: 'Any amount; valid for all services. Valid for 6 months.',
    kind: 'value',
    is_open: true,
    price: null,
    min_amount: 29,
    max_amount: 500,
    persons: null,
    vat_rate: 25.5,
    valid_months: 6,
    items: []
  },
  {
    code: 'entry_2',
    name: 'Savusaunavuoro',
    name_en: 'Smoke sauna session',
    description: 'Yleinen savusaunavuoro.',
    description_en: 'A public smoke sauna session.',
    kind: 'product',
    is_open: false,
    price: 58,
    min_amount: null,
    max_amount: null,
    persons: 2,
    min_persons: 1,
    max_persons: 6,
    unit_price: 29,
    vat_rate: 25.5,
    valid_months: 6,
    items: [
      {
        label: 'Yleinen vuoro',
        label_en: 'General session',
        kb_product_id: 1,
        unit_price: 29,
        price_type: 'per_person'
      }
    ]
  },
  {
    code: 'peat_mask_2',
    name: 'Savusaunaelämys turvenaamiolla ja jalkakylvyllä',
    name_en: 'Smoke sauna experience with peat mask and foot bath',
    description: 'Yleinen savusaunavuoro sekä omatoiminen turvenaamio ja jalkakylpy.',
    description_en: 'A public smoke sauna session with a self-guided peat mask and foot bath.',
    kind: 'product',
    is_open: false,
    price: 88,
    min_amount: null,
    max_amount: null,
    persons: 2,
    min_persons: 1,
    max_persons: 6,
    unit_price: 44,
    vat_rate: 25.5,
    valid_months: 6,
    items: [
      {
        label: 'Yleinen vuoro',
        label_en: 'General session',
        kb_product_id: 1,
        unit_price: 29,
        price_type: 'per_person'
      },
      {
        label: 'Turvenaamio ja jalkakylpy',
        label_en: 'Peat mask and foot bath',
        addon_code: 'turvenaamio_jalkakylpy',
        unit_price: 15,
        price_type: 'per_person'
      }
    ]
  },
  {
    code: 'saunarituaali_2',
    name: 'Saunotusrituaali ja yleinen vuoro',
    name_en: 'Sauna ritual and public session',
    description: 'Saunarituaali ja yleinen savusaunavuoro yhdessä.',
    description_en: 'The sauna ritual and the public smoke sauna session together.',
    kind: 'product',
    is_open: false,
    price: 98,
    min_amount: null,
    max_amount: null,
    persons: 2,
    min_persons: 1,
    max_persons: 6,
    unit_price: 49,
    vat_rate: 25.5,
    valid_months: 6,
    items: [
      {
        label: 'Saunarituaali ja savusaunavuoro',
        label_en: 'Sauna ritual and smoke sauna session',
        kb_product_id: 7,
        unit_price: 49,
        price_type: 'per_person'
      }
    ]
  },
  {
    code: 'sauna_treatment_2',
    name: 'Savusaunaelämys ja saunahoito',
    name_en: 'Smoke sauna experience and sauna treatment',
    description: 'Yleinen savusaunavuoro ja saunahoito (60 min).',
    description_en: 'A public smoke sauna session and a sauna treatment (60 min).',
    kind: 'product',
    is_open: false,
    price: 192,
    min_amount: null,
    max_amount: null,
    persons: 2,
    min_persons: 1,
    max_persons: 4,
    unit_price: null,
    vat_rate: 25.5,
    valid_months: 6,
    items: [
      {
        label: 'Yleinen vuoro',
        label_en: 'General session',
        kb_product_id: 1,
        unit_price: 29,
        price_type: 'per_person'
      },
      {
        label: 'Saunahoito',
        label_en: 'Sauna treatment',
        kb_product_id: 10,
        unit_price: 99,
        extra_price: 35,
        included: 1,
        price_type: 'base_plus_extra'
      }
    ]
  },
  {
    code: 'saunotus_2',
    name: 'Savusaunaelämys ja saunotus',
    name_en: 'Smoke sauna experience and ritual sauna bathing',
    description: 'Yleinen savusaunavuoro ja saunotus (2 h).',
    description_en: 'A public smoke sauna session and ritual sauna bathing (2 h).',
    kind: 'product',
    is_open: false,
    price: 328,
    min_amount: null,
    max_amount: null,
    persons: 2,
    min_persons: 1,
    max_persons: 2,   // Joonas 28.10.: saunotus enintään 2 hengelle (sama raja booking.gift_card_packages-rivillä)
    unit_price: null,
    vat_rate: 25.5,
    valid_months: 6,
    items: [
      {
        label: 'Yleinen vuoro',
        label_en: 'General session',
        kb_product_id: 1,
        unit_price: 29,
        price_type: 'per_person'
      },
      {
        label: 'Saunotus',
        label_en: 'Ritual sauna bathing',
        kb_product_id: 11,
        unit_price: 210,
        extra_price: 60,
        included: 1,
        price_type: 'base_plus_extra'
      }
    ]
  }
];

export const GIFT_PACKAGE_IMAGE = Object.freeze({
  entry_2: 'j-yleinen',
  peat_mask_2: 'j-lahja-turvenaamio',
  saunarituaali_2: 'rituaali-2',
  sauna_treatment_2: 'j-lahja-hoito',
  saunotus_2: 'saunotus-selka',
});

const euro = (n, lang) => (lang === 'en' ? `€${n}` : `${n} €`);
const joinList = (xs, and) => (xs.length < 2 ? xs.join('') : `${xs.slice(0, -1).join(', ')} ${and} ${xs.at(-1)}`);

/** Metakuvaus samasta valikoimasta. Ei lupaa vuosikorttia (myynti on oletuksena kiinni). */
export function giftMetaDescription(lang) {
  const open = PUBLISHED_GIFT_PACKAGES.find((p) => p.is_open);
  const fixed = PUBLISHED_GIFT_PACKAGES.filter((p) => !p.is_open);
  const bits = fixed.map((p) => `${lang === 'en' ? p.name_en : p.name} ${euro(p.price, lang)}`);
  if (lang === 'en') {
    const list = [`an open gift card from ${euro(open.min_amount, 'en')}`, ...bits];
    return `Give time, warmth and wellbeing: ${joinList(list, 'and')}. Extending the validity of a gift card is free of charge.`;
  }
  const list = [`avoin lahjakortti alk. ${euro(open.min_amount, 'fi')}`, ...bits];
  return `Anna lahjaksi aikaa, lämpöä ja hyvää oloa: ${joinList(list, 'ja')}. Lahjakortin voimassaolon jatkaminen on maksutonta.`;
}
