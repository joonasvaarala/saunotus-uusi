// Tuotevalinta (product_options, migraatio booking_50; sopimus: booking/docs/KOODARI_talous_A_D_fi.md §15): kaupan PUHDAS logiikka (ei DOMia, ei verkkoa) → node --test.
// Palvelin on totuus: pakollisuus = product_config.option_required JA vähintään yksi aktiivinen vaihtoehto. UI vain ohjaa ja näyttää virheet; palvelin tarkistaa aina.

export const OPTION_ERRORS = ['option_required', 'invalid_option'];
export const isOptionError = (code) => OPTION_ERRORS.includes(code);

const asList = (v) => (Array.isArray(v) ? v : []);
const clean = (s) => String(s ?? '').trim();

// Vaihtoehdon nimi/kuvaus kielen mukaan (EN puuttuu → suomi)
export const optName = (o, lang) => (o ? clean((lang === 'en' && o.name_en) || o.name) : '');
export const optDesc = (o, lang) => (o ? clean((lang === 'en' && o.description_en) || o.description) : '');

// public_catalog()-rivi → { options[], required, label, label_en }. Vain aktiiviset vaihtoehdot, sort_order-järjestys (palvelin järjestää jo; varmistetaan).
export function normOptions(row) {
  const options = asList(row?.options)
    .filter((o) => o && o.code && o.active !== false)
    .map((o) => ({ id: o.id ?? null, code: String(o.code), name: clean(o.name) || String(o.code), name_en: clean(o.name_en) || null, description: clean(o.description) || null, description_en: clean(o.description_en) || null, sort_order: +o.sort_order || 0 }))
    .sort((a, b) => a.sort_order - b.sort_order);
  return { options, required: !!row?.option_required && options.length > 0, label: clean(row?.option_label) || null, label_en: clean(row?.option_label_en) || null };
}
// Tuotteelle (adapterin muotoilema: { options, option_required, … }) vaadittu valinta?
export const needsOption = (p) => !!p?.option_required && asList(p?.options).length > 0;
export const hasOptions = (p) => asList(p?.options).length > 0;
export const findOption = (p, code) => asList(p?.options).find((o) => o.code === code) || null;
// URL-parametrin (?o=…) koodi → voimassa oleva koodi tai null
export const validCode = (p, code) => (findOption(p, clean(code).toLowerCase()) ? clean(code).toLowerCase() : null);
// Valitsimen otsikko: tuotteen option_label(_en) tai oletus
export const optLabel = (p, lang, fallback) => clean(lang === 'en' ? p?.option_label_en || p?.option_label : p?.option_label) || fallback;

// Valitsimen otsikko varaus-/tilausriviltä (booking_52): public_get_booking items[] ja public_get_order reservations[] palauttavat option_label (tilauksen kielellä) sekä option_label_fi / option_label_en.
// Sivun kieli voittaa tilauksen kielen; puuttuessa null → kutsuja käyttää nykyistä oletusotsikkoa.
export const rowLabel = (row, lang) => clean(lang === 'en' ? row?.option_label_en || row?.option_label : row?.option_label_fi || row?.option_label) || null;

// Jatkaminen sallittu? (pakollinen valinta tehty)
export const optionOk = (p, code) => !needsOption(p) || !!validCode(p, code);

// RPC-argumentit: p_option_code lähetetään vain kun koodi on annettu (vanha kutsu ilman valintaa toimii ennallaan)
export const withOption = (args, code) => (code ? { ...args, p_option_code: String(code) } : args);

// public_add_to_order: varausrivi { type:'reservation', product_id, persons, start, option_code? }
export const reservationItem = ({ productId, persons, start, optionCode }) => ({ type: 'reservation', product_id: +productId, persons: +persons, start, ...(optionCode ? { option_code: String(optionCode) } : {}) });

// Tilaussivu (public_get_order): varauksen valinta + vaihtoehdot
export const reservationOption = (r) => r?.option || null;
export const reservationChoices = (r) => asList(r?.option_choices);
export const optionMissingOnOrder = (r) => !r?.option && reservationChoices(r).length > 0;
export const optionChanged = (r, code) => !!code && code !== (r?.option?.code ?? null);
