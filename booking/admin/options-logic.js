// Hallinnan tuotevalinnan PUHDAS logiikka (booking_50): tekstit FI/EN, nimi kielen mukaan, varauksen valinnan luku eri RPC-muodoista. Ei DOMia eikä verkkoa → node --test.
export const OPT_TEXTS = {
  fi: {
    label: 'Hoito', notChosen: 'valitsematta', choose: 'Valitse hoito', required: 'Hoito valitaan varaukselle (pakollinen).',
    optional: 'Hoito (valinnainen)', change: 'Vaihda hoito', save: 'Tallenna hoito', saved: 'Hoito tallennettu', savedMail: 'Hoito tallennettu, asiakkaalle lähetetään viesti',
    notify: 'Ilmoita muutoksesta asiakkaalle sähköpostilla', missingHint: 'Tämän varauksen hoitoa ei ole valittu. Valitse hoito alta.',
    current: 'Nykyinen valinta', noChange: 'Valitse toinen hoito ennen tallennusta.', none: 'Ei valintaa', missingBadgeTitle: 'Hoitoa ei ole valittu',
    err_option_required: 'Valitse hoito.', err_invalid_option: 'Valittu hoito ei kelpaa tälle tuotteelle. Päivitä sivu ja valitse uudelleen.', err_no_options: 'Pakollinen valinta vaatii vähintään yhden aktiivisen hoidon.',
    err_forbidden: 'Ei oikeutta tähän toimintoon.',
    mgTitle: 'Tuotevalinnat (hoidot)', mgLead: 'Tuotteen vaihtoehdot, joista asiakas valitsee varauksen yhteydessä (esim. Saunahoidon hoito). Hinta ei muutu valinnan mukaan. Poisto = passivointi: vanhat varaukset säilyttävät valintansa.',
    mgRequired: 'Pakollinen', mgOptional: 'Valinnainen', mgNoActive: 'Ei aktiivisia vaihtoehtoja', mgWithout: '{n} tulevaa varausta ilman valintaa', mgAdd: 'Lisää vaihtoehto', mgSettings: 'Asetukset', mgEmpty: 'Ei tuotteita, joilla on vaihtoehtoja.',
    mgInactive: 'passiivinen', mgReadonly: 'Vaihtoehtojen muokkaus vaatii oikeuden catalog.edit.',
    fCode: 'Koodi', fCodeHint: 'Pienet kirjaimet, numerot ja alaviiva (a–z, 0–9, _), enintään 40 merkkiä. Koodia ei voi vaihtaa jälkeenpäin.', fName: 'Nimi (suomi)', fNameEn: 'Nimi (englanti)', fSort: 'Järjestys', fActive: 'Aktiivinen (näkyy asiakkaalle ja hallinnassa valittavana)',
    fDesc: 'Kuvaus (suomi, valinnainen)', fDescEn: 'Kuvaus (englanti, valinnainen)', fRequired: 'Valinta on pakollinen varausta tehdessä', fLabel: 'Valitsimen otsikko (suomi)', fLabelEn: 'Valitsimen otsikko (englanti)',
    mgSaveOpt: 'Tallenna vaihtoehto', mgSaveSet: 'Tallenna asetukset', mgSavedOpt: 'Vaihtoehto tallennettu', mgSavedSet: 'Asetukset tallennettu', mgEditOpt: 'Muokkaa vaihtoehtoa', mgNewOpt: 'Uusi vaihtoehto', mgSettingsOf: 'Asetukset',
    mgCodeInvalid: 'Koodi: käytä vain pieniä kirjaimia, numeroita ja alaviivaa (enintään 40 merkkiä).', mgNameMissing: 'Anna vaihtoehdon nimi.',
    reminder: '{n} tulevaa hoitovarausta ilman valittua hoitoa.', reminderLink: 'Avaa varaukset', err_invalid_param: 'Tarkista kentät: koodi tai nimi ei kelpaa.', err_product_not_found: 'Tuotetta ei löytynyt.',
  },
  en: {
    label: 'Treatment', notChosen: 'not chosen', choose: 'Choose treatment', required: 'A treatment must be chosen for this booking (required).',
    optional: 'Treatment (optional)', change: 'Change treatment', save: 'Save treatment', saved: 'Treatment saved', savedMail: 'Treatment saved, the customer will be notified',
    notify: 'Notify the customer of the change by email', missingHint: 'No treatment has been chosen for this booking. Choose one below.',
    current: 'Current choice', noChange: 'Choose a different treatment before saving.', none: 'No choice', missingBadgeTitle: 'No treatment chosen',
    err_option_required: 'Choose a treatment.', err_invalid_option: 'The chosen treatment is not valid for this product. Refresh the page and choose again.', err_no_options: 'A required choice needs at least one active treatment.',
    err_forbidden: 'You do not have permission for this action.',
    mgTitle: 'Product options (treatments)', mgLead: 'Options the customer chooses from when booking (e.g. the treatment for Sauna treatment). The price does not change with the choice. Removing = deactivating: existing bookings keep their choice.',
    mgRequired: 'Required', mgOptional: 'Optional', mgNoActive: 'No active options', mgWithout: '{n} upcoming bookings without a choice', mgAdd: 'Add option', mgSettings: 'Settings', mgEmpty: 'No products with options.',
    mgInactive: 'inactive', mgReadonly: 'Editing options requires the catalog.edit permission.',
    fCode: 'Code', fCodeHint: 'Lower-case letters, digits and underscore (a-z, 0-9, _), up to 40 characters. The code cannot be changed later.', fName: 'Name (Finnish)', fNameEn: 'Name (English)', fSort: 'Sort order', fActive: 'Active (shown to customers and selectable in the admin)',
    fDesc: 'Description (Finnish, optional)', fDescEn: 'Description (English, optional)', fRequired: 'A choice is required when booking', fLabel: 'Picker title (Finnish)', fLabelEn: 'Picker title (English)',
    mgSaveOpt: 'Save option', mgSaveSet: 'Save settings', mgSavedOpt: 'Option saved', mgSavedSet: 'Settings saved', mgEditOpt: 'Edit option', mgNewOpt: 'New option', mgSettingsOf: 'Settings',
    mgCodeInvalid: 'Code: use only lower-case letters, digits and underscore (up to 40 characters).', mgNameMissing: 'Enter a name for the option.',
    reminder: '{n} upcoming treatment bookings have no treatment chosen.', reminderLink: 'Open bookings', err_invalid_param: 'Check the fields: the code or name is not valid.', err_product_not_found: 'Product not found.',
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
