// booking_257/258: Viesti asiakkaalle -välilehden asiakaspuolen tarkistus ja paikkamerkit.
// Palvelin täyttää paikkamerkit uudestaan lähetyksessä; tämä on esikatselua ja lomakkeen tarkistusta varten.
// booking_258: päivämäärärajoitettu tuotevalinta (ei koko katalogia).

export const CUSTOMER_MESSAGE_PLACEHOLDERS = [
  { key: 'tuote', token: '{tuote}', helpKey: 'ui.admin.customer_message.var_tuote' },
  { key: 'päivämäärä', token: '{päivämäärä}', helpKey: 'ui.admin.customer_message.var_paiva' },
  { key: 'kellonaika', token: '{kellonaika}', helpKey: 'ui.admin.customer_message.var_kello' },
  { key: 'asiakkaan nimi', token: '{asiakkaan nimi}', helpKey: 'ui.admin.customer_message.var_nimi' },
  { key: 'henkilömäärä', token: '{henkilömäärä}', helpKey: 'ui.admin.customer_message.var_hlot' },
  { key: 'tilauslinkki', token: '{tilauslinkki}', helpKey: 'ui.admin.customer_message.var_linkki' },
];

export const CUSTOMER_MESSAGE_CAT_ORDER = [
  'public_sauna', 'private_sauna', 'corporate', 'treatment', 'ritual', 'ceremony',
  'event', 'gift_card', 'season_card', 'training', 'add_on', 'product_rental', 'other',
];

const TOKEN_VALUES = [
  ['{tuote}', ['tuote']],
  ['{päivämäärä}', ['paivamaara', 'päivämäärä']],
  ['{kellonaika}', ['kellonaika']],
  ['{asiakkaan nimi}', ['asiakkaan_nimi', 'nimi']],
  ['{henkilömäärä}', ['henkilomaara', 'henkilömäärä']],
  ['{tilauslinkki}', ['tilauslinkki']],
];

export function fillCustomerMessage(template, vars = {}) {
  let out = String(template ?? '');
  for (const [token, keys] of TOKEN_VALUES) {
    let value = '';
    for (const k of keys) {
      if (vars[k] != null && vars[k] !== '') { value = String(vars[k]); break; }
    }
    if (out.includes(token)) out = out.split(token).join(value);
  }
  return out;
}

/** Päivämääräpari vastaanottaja-/tuotehaulle. Tyhjä loppu = sama päivä. */
export function parseCustomerMessageDates(from, to) {
  const dateFrom = String(from ?? '').trim();
  const dateTo = String(to ?? '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateFrom)) return { ok: false, code: 'invalid_dates' };
  if (dateTo && !/^\d{4}-\d{2}-\d{2}$/.test(dateTo)) return { ok: false, code: 'invalid_dates' };
  if (dateTo && dateTo < dateFrom) return { ok: false, code: 'invalid_dates' };
  return { ok: true, value: { from: dateFrom, to: dateTo || dateFrom } };
}

/** Poista valinnoista tuotteet, joita ei enää ole päivän/välin listassa. */
export function pruneSelectedProductIds(selectedIds, availableIds) {
  const allow = new Set((availableIds || []).map(Number).filter((n) => Number.isInteger(n) && n > 0));
  return [...new Set((selectedIds || []).map(Number).filter((n) => allow.has(n)))];
}

/** Ryhmittele tuotteet kategorian mukaan (UI-kenttälista). */
export function groupCustomerMessageProducts(products, catOrder = CUSTOMER_MESSAGE_CAT_ORDER) {
  const list = Array.isArray(products) ? products : [];
  const grouped = new Map();
  for (const p of list) {
    const cat = p?.category || 'other';
    if (!grouped.has(cat)) grouped.set(cat, []);
    grouped.get(cat).push(p);
  }
  const cats = [...grouped.keys()].sort((a, b) => {
    const ia = catOrder.indexOf(a); const ib = catOrder.indexOf(b);
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || a.localeCompare(b, 'fi');
  });
  for (const cat of cats) {
    grouped.get(cat).sort((a, b) => String(a.name).localeCompare(String(b.name), 'fi') || (a.id - b.id));
  }
  return { cats, grouped };
}

export function validateCustomerMessageDraft({
  from, to, productIds, subjectFi, bodyFi, subjectEn, bodyEn,
} = {}) {
  const dates = parseCustomerMessageDates(from, to);
  if (!dates.ok) return { ok: false, code: dates.code };
  const ids = [...new Set((productIds || []).map((n) => Number(n)).filter((n) => Number.isInteger(n) && n > 0))];
  if (!ids.length) return { ok: false, code: 'invalid_products' };
  const subject_fi = String(subjectFi ?? '').trim();
  const body_fi = String(bodyFi ?? '').trim();
  const subject_en = String(subjectEn ?? '').trim();
  const body_en = String(bodyEn ?? '').trim();
  if (!subject_fi || !body_fi || !subject_en || !body_en) return { ok: false, code: 'invalid_text' };
  if (subject_fi.length > 200 || subject_en.length > 200) return { ok: false, code: 'invalid_text' };
  if (body_fi.length > 4000 || body_en.length > 4000) return { ok: false, code: 'invalid_text' };
  return {
    ok: true,
    value: {
      from: dates.value.from,
      to: dates.value.to,
      product_ids: ids,
      subject_fi,
      body_fi,
      subject_en,
      body_en,
    },
  };
}
