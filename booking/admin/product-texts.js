// Hallinnan tuotelistan "Lisää tuote" -tekstit (FI+EN). Tuotannossa sama sisältö tuodaan site_texts-tauluun
// (content/site-texts.pending-import-19.json; lyhyt kuvaus booking_156: pending-import-56.json; myyntikanavat booking_316: pending-import-174.json).
// Sanakirja on varalla, kunnes tuonti on ajettu.
// public_get_site_texts peittää ui.admin.product.*-avaimet. Haku epäonnistuu tai rivi puuttuu → sanakirja.
// Hintoja ja ALV-kantoja ei ole näissä teksteissä.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const PREFIX = 'ui.admin.product.';

export const PRODUCT_TEXTS = {
  fi: {
    'ui.admin.product.add': 'Lisää tuote',
    'ui.admin.product.new_title': 'Uusi tuote',
    'ui.admin.product.create': 'Luo tuote',
    'ui.admin.product.created': 'Tuote luotu',
    'ui.admin.product.name_fi': 'Nimi (suomi)',
    'ui.admin.product.name_en': 'Nimi (englanti)',
    'ui.admin.product.name_en_hint': 'Valinnainen. Tyhjä kenttä tallentaa saman nimen kuin suomeksi.',
    'ui.admin.product.price': 'Hinta euroina (sis. alv)',
    'ui.admin.product.price_text': 'Hintateksti',
    'ui.admin.product.price_text_hint': 'Vapaaehtoinen. Tyhjä kenttä täytetään hinnasta.',
    'ui.admin.product.vat': 'Alv-prosentti',
    'ui.admin.product.category': 'Kategoria',
    'ui.admin.product.cat_rental': 'Tuotteet ja vuokrat',
    'ui.admin.product.cat_other': 'Muu',
    'ui.admin.product.active': 'Aktiivinen',
    'ui.admin.product.sell_hint': 'Tuote on myytävissä pikakassassa ja QR-koodilla.',
    'ui.admin.product.age': 'Ikärajallinen',
    'ui.admin.product.next': 'Tallennuksen jälkeen tuotteen voi lisätä pikakassaan ja sille voi tehdä QR-koodin.',
    'ui.admin.product.link_pos': 'Avaa pikakassa',
    'ui.admin.product.link_qr': 'Avaa QR-koodin tulostus',
    'ui.admin.product.pos_hint': 'Rastita pikakassa ja tallenna asetukset.',
    'ui.admin.product.qr_hint': 'QR-koodi tehdään Tuotteet-sivun osiossa QR-koodin tulostus.',
    'ui.admin.product.duplicate': 'Samanniminen aktiivinen tuote on jo olemassa',
    'ui.admin.product.short_fi': 'Lyhyt kuvaus (suomi)',
    'ui.admin.product.short_en': 'Lyhyt kuvaus (englanti)',
    'ui.admin.product.short_hint': 'Näkyy tuotekortissa ja tuotesivun yläosassa. Pidä se muutaman virkkeen mittaisena. Tyhjä kenttä näyttää otteen kuvauksesta.',
    'ui.admin.product.desc_fi': 'Kuvaus (suomi)',
    'ui.admin.product.desc_en': 'Kuvaus (englanti)',
    'ui.admin.product.tab_basic': 'Perustiedot',
    'ui.admin.product.tab_prices': 'Hinnat',
    'ui.admin.product.tab_sales': 'Myynti ja näkyvyys',
    'ui.admin.product.tab_image': 'Kuva',
    'ui.admin.product.tab_options': 'Valinnat ja lisäpalvelut',
    'ui.admin.product.tab_upsell': 'Lisämyynti',
    'ui.admin.product.tabs_label': 'Tuotteen osiot',
    'ui.admin.product.back': 'Takaisin tuotteisiin',
    'ui.admin.product.save': 'Tallenna muutokset',
    'ui.admin.product.saving': 'Tallennetaan…',
    'ui.admin.product.discard': 'Hylkää muutokset',
    'ui.admin.product.clean': 'Ei tallentamattomia muutoksia.',
    'ui.admin.product.dirty': 'Tallentamatta: {{var:tabs}}.',
    'ui.admin.product.saved_all': 'Muutokset tallennettu.',
    'ui.admin.product.saved_part': 'Osa muutoksista tallentui ({{var:count}} osaa). Ei tallentunut: {{var:failed}}',
    'ui.admin.product.saved_none': 'Mikään ei tallentunut. {{var:failed}}',
    'ui.admin.product.save_invalid': 'Korjaa merkityt kentät ennen tallennusta.',
    'ui.admin.product.step_product': 'Perustiedot ja hinta',
    'ui.admin.product.step_training': 'Koulutuksen hinnat ja lisävalinnat',
    'ui.admin.product.step_config': 'Myynti ja näkyvyys',
    'ui.admin.product.step_image': 'Kuva',
    'ui.admin.product.step_upsell': 'Lisämyynti',
    'ui.admin.product.step_variant': 'Hintavariantti {{var:name}}',
    'ui.admin.product.leave_title': 'Tallentamattomia muutoksia',
    'ui.admin.product.leave_body': 'Tuotteessa on muutoksia, joita ei ole tallennettu. Jos poistut, ne häviävät.',
    'ui.admin.product.leave_yes': 'Hylkää muutokset',
    'ui.admin.product.leave_no': 'Jatka muokkausta',
    'ui.admin.product.price_text_auto': 'Päivittyy hinnan mukana, kunnes muokkaat sitä itse.',
    'ui.admin.product.price_text_manual': 'Muokattu käsin, joten se ei päivity hinnan mukana.',
    'ui.admin.product.price_text_reset': 'Palauta teksti hinnasta',
    'ui.admin.product.price_text_stale': 'Hinta on muuttunut, mutta hintateksti on kirjoitettu käsin. Tarkista se ennen tallennusta.',
    'ui.admin.product.err_name': 'Nimi ei voi olla tyhjä.',
    'ui.admin.product.err_price': 'Anna hinta numerona, nolla tai suurempi.',
    'ui.admin.product.err_vat': 'Valitse alv-prosentti.',
    'ui.admin.product.err_number': 'Anna numero.',
    'ui.admin.product.image_remove_pending': 'Kuva poistetaan, kun tallennat muutokset.',
    'ui.admin.product.image_undo': 'Kumoa poisto',
    'ui.admin.product.image_pending': 'Valittu kuva tallentuu, kun tallennat muutokset.',
    'ui.admin.product.options_note': 'Tuotevalinnat ja lisäpalvelut ovat yhteisiä kaikille tuotteille. Muokkaa niitä tämän sivun alaosan Tuotevalinnat- ja Lisäpalvelut-osioissa.',
    'ui.admin.product.upsell_missing': 'Lisämyynnin asetukset eivät ole käytettävissä.',
    // booking_316 / HALL-TUOTTEET-03: myyntikanavien monivalinta (pending-import-174; vis_*-rivit samat kuin tuonnissa 166)
    'ui.admin.product.channels_title': 'Myyntikanavat',
    'ui.admin.product.channels_lead': 'Valitse kaikki kanavat, joissa tuotetta myydään. Kanavat tulevat järjestelmän kanavalistasta.',
    'ui.admin.product.channels_none': 'Ei yhtään kanavaa: tuotetta ei myydä missään kanavassa. Hallinnassa se on edelleen käytettävissä.',
    'ui.admin.product.channels_inactive': 'ei käytössä',
    'ui.admin.product.channels_load_error': 'Myyntikanavia ei voitu ladata, joten niitä ei voi nyt muuttaa. Lataa sivu uudelleen.',
    'ui.admin.product.channels_qr_blocked': 'QR-myynti ei ole mahdollinen ikärajalliselle tuotteelle eikä alkoholille.',
    'ui.admin.product.channels_pos_blocked': 'Lahjakortteja ja kausikortteja ei myydä pikakassassa tuotepainikkeena.',
    'ui.admin.product.channels_gift_hint': 'Lahjakorttikauppa: lahjakorttipaketti näkyy kaupassa vain, kun kaikki sen tuotteet ovat tässä kanavassa.',
    'ui.admin.product.channels_public_hint': 'Verkkokauppa, Upotus ja Suora linkki tekevät tuotteesta varattavan verkossa.',
    'ui.admin.product.vis_hidden': 'Piilotettu',
    'ui.admin.product.vis_hidden_hint': 'Ei käytössä missään: ei myyntikanavissa, kassalla eikä hallinnan tuotevalinnoissa.',
    'ui.admin.product.vis_note': 'Huomioi:',
    'ui.admin.product.vis_why_no_config': 'Tuotetta ei ole otettu mukaan varausjärjestelmään, joten se ei voi olla verkossa.',
    'ui.admin.product.vis_why_lifecycle_old': 'Tuote on vanha tuote, eikä vanhoja tuotteita myydä verkossa.',
    'ui.admin.product.vis_why_no_image': 'Kuva puuttuu: tuote näkyy kaupassa ilman kuvaa.',
  },
  en: {
    'ui.admin.product.add': 'Add product',
    'ui.admin.product.new_title': 'New product',
    'ui.admin.product.create': 'Create product',
    'ui.admin.product.created': 'Product created',
    'ui.admin.product.name_fi': 'Name in Finnish',
    'ui.admin.product.name_en': 'Name in English',
    'ui.admin.product.name_en_hint': 'Optional. An empty field saves the same name as in Finnish.',
    'ui.admin.product.price': 'Price in euros, including VAT',
    'ui.admin.product.price_text': 'Price text',
    'ui.admin.product.price_text_hint': 'Optional. An empty field is filled from the price.',
    'ui.admin.product.vat': 'VAT rate',
    'ui.admin.product.category': 'Category',
    'ui.admin.product.cat_rental': 'Products and rentals',
    'ui.admin.product.cat_other': 'Other',
    'ui.admin.product.active': 'Active',
    'ui.admin.product.sell_hint': 'The product can be sold in the quick till and with a QR code.',
    'ui.admin.product.age': 'Age-restricted',
    'ui.admin.product.next': 'After saving, the product can be added to the quick till and a QR code can be printed for it.',
    'ui.admin.product.link_pos': 'Open quick till',
    'ui.admin.product.link_qr': 'Open QR printing',
    'ui.admin.product.pos_hint': 'Tick the quick till box and save the settings.',
    'ui.admin.product.qr_hint': 'The QR code is created in the QR code printing section of the Products page.',
    'ui.admin.product.duplicate': 'An active product with this name already exists',
    'ui.admin.product.short_fi': 'Short description in Finnish',
    'ui.admin.product.short_en': 'Short description in English',
    'ui.admin.product.short_hint': 'Shown on the product card and at the top of the product page. Keep it to a few sentences. If empty, an excerpt of the description is shown.',
    'ui.admin.product.desc_fi': 'Description in Finnish',
    'ui.admin.product.desc_en': 'Description in English',
    'ui.admin.product.tab_basic': 'Basic details',
    'ui.admin.product.tab_prices': 'Prices',
    'ui.admin.product.tab_sales': 'Sales and visibility',
    'ui.admin.product.tab_image': 'Image',
    'ui.admin.product.tab_options': 'Choices and extras',
    'ui.admin.product.tab_upsell': 'Upsell',
    'ui.admin.product.tabs_label': 'Product sections',
    'ui.admin.product.back': 'Back to products',
    'ui.admin.product.save': 'Save changes',
    'ui.admin.product.saving': 'Saving…',
    'ui.admin.product.discard': 'Discard changes',
    'ui.admin.product.clean': 'No unsaved changes.',
    'ui.admin.product.dirty': 'Not saved: {{var:tabs}}.',
    'ui.admin.product.saved_all': 'Changes saved.',
    'ui.admin.product.saved_part': 'Some changes were saved ({{var:count}} parts). Not saved: {{var:failed}}',
    'ui.admin.product.saved_none': 'Nothing was saved. {{var:failed}}',
    'ui.admin.product.save_invalid': 'Fix the marked fields before saving.',
    'ui.admin.product.step_product': 'Basic details and price',
    'ui.admin.product.step_training': 'Training prices and extra choices',
    'ui.admin.product.step_config': 'Sales and visibility',
    'ui.admin.product.step_image': 'Image',
    'ui.admin.product.step_upsell': 'Upsell',
    'ui.admin.product.step_variant': 'Price variant {{var:name}}',
    'ui.admin.product.leave_title': 'Unsaved changes',
    'ui.admin.product.leave_body': 'This product has changes that are not saved. If you leave, they are lost.',
    'ui.admin.product.leave_yes': 'Discard changes',
    'ui.admin.product.leave_no': 'Keep editing',
    'ui.admin.product.price_text_auto': 'Updates with the price until you edit it yourself.',
    'ui.admin.product.price_text_manual': 'Edited by hand, so it does not change with the price.',
    'ui.admin.product.price_text_reset': 'Restore text from price',
    'ui.admin.product.price_text_stale': 'The price has changed, but the price text was written by hand. Check it before saving.',
    'ui.admin.product.err_name': 'The name cannot be empty.',
    'ui.admin.product.err_price': 'Enter the price as a number, zero or higher.',
    'ui.admin.product.err_vat': 'Choose a VAT rate.',
    'ui.admin.product.err_number': 'Enter a number.',
    'ui.admin.product.image_remove_pending': 'The image is removed when you save the changes.',
    'ui.admin.product.image_undo': 'Undo removal',
    'ui.admin.product.image_pending': 'The selected image is saved when you save the changes.',
    'ui.admin.product.options_note': 'Product choices and extras are shared by all products. Edit them in the Product choices and Extras sections at the bottom of this page.',
    'ui.admin.product.upsell_missing': 'Upsell settings are not available.',
    // booking_316 / HALL-TUOTTEET-03: myyntikanavien monivalinta (pending-import-174; vis_*-rivit samat kuin tuonnissa 166)
    'ui.admin.product.channels_title': 'Sales channels',
    'ui.admin.product.channels_lead': 'Select every channel where the product is sold. The channels come from the system channel list.',
    'ui.admin.product.channels_none': 'No channels: the product is not sold in any channel. It can still be used in the admin.',
    'ui.admin.product.channels_inactive': 'not in use',
    'ui.admin.product.channels_load_error': 'The sales channels could not be loaded, so they cannot be changed now. Reload the page.',
    'ui.admin.product.channels_qr_blocked': 'QR sales are not possible for age-restricted products or alcohol.',
    'ui.admin.product.channels_pos_blocked': 'Gift cards and season cards are not sold as quick till product buttons.',
    'ui.admin.product.channels_gift_hint': 'Gift card shop: a gift card package is shown in the shop only when all of its products are in this channel.',
    'ui.admin.product.channels_public_hint': 'Online shop, Embed and Direct link make the product bookable online.',
    'ui.admin.product.vis_hidden': 'Hidden',
    'ui.admin.product.vis_hidden_hint': 'Not in use anywhere: not in sales channels, at the till or in admin product pickers.',
    'ui.admin.product.vis_note': 'Note:',
    'ui.admin.product.vis_why_no_config': 'The product is not part of the booking system, so it cannot be online.',
    'ui.admin.product.vis_why_lifecycle_old': 'This is an old product, and old products are not sold online.',
    'ui.admin.product.vis_why_no_image': 'The image is missing: the product is shown in the shop without an image.',
  },
};

let db = new Map();
let loaded = false;

export async function loadProductTexts(rpcFn) {
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

export function clearProductTextCache() {
  clearSiteTextsCache();
  db = new Map();
  loaded = false;
}

export function productText(key, lang = getLang()) {
  const full = key.startsWith(PREFIX) ? key : PREFIX + key;
  const live = db.get(`${full}|${lang}`);
  if (live) return live;
  return PRODUCT_TEXTS[lang]?.[full] || PRODUCT_TEXTS.fi[full] || key;
}
