// Hallinnan tuotevalinnan PUHDAS logiikka (booking_50): tekstit FI/EN, nimi kielen mukaan, varauksen valinnan luku eri RPC-muodoista. Ei DOMia eikä verkkoa → node --test.
export const OPT_TEXTS = {
  fi: {
    label: 'Hoito', notChosen: 'valitsematta', choose: 'Valitse hoito', required: 'Hoito valitaan varaukselle (pakollinen).',
    optional: 'Hoito (valinnainen)', change: 'Vaihda hoito', save: 'Tallenna hoito', saved: 'Hoito tallennettu', savedMail: 'Hoito tallennettu, asiakkaalle lähetetään viesti',
    notify: 'Ilmoita muutoksesta asiakkaalle sähköpostilla', missingHint: 'Tämän varauksen hoitoa ei ole valittu. Valitse hoito alta.',
    current: 'Nykyinen valinta', noChange: 'Valitse toinen hoito ennen tallennusta.', none: 'Ei valintaa', missingBadgeTitle: 'Hoitoa ei ole valittu',
    err_option_required: 'Valitse hoito.', err_invalid_option: 'Valittu hoito ei kelpaa tälle tuotteelle. Päivitä sivu ja valitse uudelleen.', err_no_options: 'Pakollinen valinta vaatii vähintään yhden aktiivisen hoidon.',
    err_forbidden: 'Ei oikeutta tähän toimintoon.',
  },
  en: {
    label: 'Treatment', notChosen: 'not chosen', choose: 'Choose treatment', required: 'A treatment must be chosen for this booking (required).',
    optional: 'Treatment (optional)', change: 'Change treatment', save: 'Save treatment', saved: 'Treatment saved', savedMail: 'Treatment saved, the customer will be notified',
    notify: 'Notify the customer of the change by email', missingHint: 'No treatment has been chosen for this booking. Choose one below.',
    current: 'Current choice', noChange: 'Choose a different treatment before saving.', none: 'No choice', missingBadgeTitle: 'No treatment chosen',
    err_option_required: 'Choose a treatment.', err_invalid_option: 'The chosen treatment is not valid for this product. Refresh the page and choose again.', err_no_options: 'A required choice needs at least one active treatment.',
    err_forbidden: 'You do not have permission for this action.',
  },
};
export const otFor = (lang, k, vars) => { const v = OPT_TEXTS[lang]?.[k] ?? OPT_TEXTS.fi[k] ?? k; return vars ? v.replace(/\{(\w+)\}/g, (_, n) => (vars[n] == null ? '' : vars[n])) : v; };
export const optNameFor = (o, lang) => (o ? (lang === 'en' && o.name_en ? o.name_en : o.name) || o.code || '' : '');
// Varauksen valinta mistä tahansa lähteestä: admin_list_reservations (option_name/option_name_en/option_missing) tai admin_day_view / admin_get_order (option {name,name_en} + option_missing).
export function optionOfFor(r, lang) {
  if (!r) return { name: '', missing: false };
  const o = r.option ? { name: r.option.name, name_en: r.option.name_en, code: r.option.code } : r.option_name ? { name: r.option_name, name_en: r.option_name_en, code: r.option_code } : null;
  return { name: o ? optNameFor(o, lang) : '', missing: !o && r.option_missing === true };
}
