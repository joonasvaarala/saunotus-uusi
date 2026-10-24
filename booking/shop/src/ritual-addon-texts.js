// Saunarituaali yleisen vuoron lisäpalveluna (booking_166): kaupan tekstit FI + EN. Yhdistetään T-sanakirjaan (i18n.js) → sivutekstiavaimet
// ui.shop.ritual_* ja virheet ui.shop.error_ritual_addon_* (text-registry.js: camelCase → snake_case). Tuonti: content/site-texts.pending-import-62.json.
// {min}/{price}/{n}/{time} täytetään kutsuhetkellä (fillText). Ei hintoja tekstissä: hinta tulee palvelimelta (public_ritual_addon).
export const RITUAL_TEXTS = {
  fi: {
    ritualTitle: 'Saunotusrituaali vuoron yhteyteen',
    ritualLead: 'Saunottajan ohjaama {min} minuutin rituaali hoitosauna Raunissa pienryhmässä. Valitse aika ennen vuoroa, sen aikana tai lopuksi.',
    ritualPrice: '{price} / hlö',
    ritualNone: 'Ei rituaalia',
    ritualBefore: 'ennen vuoroa',
    ritualStart: 'vuoron alussa',
    ritualDuring: 'vuoron aikana',
    ritualEnd: 'vuoron päätteeksi',
    ritualSpots: 'enintään {n} hlö',
    ritualQty: 'Rituaaliin osallistuu',
    ritualFewer: 'Vähemmän osallistujia',
    ritualMore: 'Enemmän osallistujia',
    ritualSummary: 'klo {time} · {n} hlö',
    ritualLost: 'Valitsemasi rituaaliaika ei ole enää vapaana tälle henkilömäärälle. Valitse toinen aika.',
    ritualAnnual: 'Vuosikorttivaraukseen ei voi lisätä rituaalia.',
    ritualConfNote: 'Varaukseen kuuluu saunotusrituaali. Muutokset ja peruutukset sähköpostilla, niin siirrämme vuoron ja rituaalin yhdessä:',
  },
  en: {
    ritualTitle: 'Add a sauna ritual to your session',
    ritualLead: 'A {min}-minute ritual led by a sauna host in the healing sauna Rauni, in a small group. Choose a time before, during or at the end of your session.',
    ritualPrice: '{price} / person',
    ritualNone: 'No ritual',
    ritualBefore: 'before the session',
    ritualStart: 'at the start',
    ritualDuring: 'during the session',
    ritualEnd: 'at the end',
    ritualSpots: 'up to {n} guests',
    ritualQty: 'Ritual guests',
    ritualFewer: 'Fewer guests',
    ritualMore: 'More guests',
    ritualSummary: '{time} · {n} guests',
    ritualLost: 'The ritual time you chose is no longer available for this number of guests. Please choose another time.',
    ritualAnnual: 'A ritual cannot be added to an annual card booking.',
    ritualConfNote: 'Your booking includes a sauna ritual. For changes and cancellations please email us and we will move the session and the ritual together:',
  },
};
// Palvelimen virhekoodit (BK001 detail, _ritual_addon_attach) → T.errors (ui.shop.error_ritual_addon_*)
export const RITUAL_ERRORS = {
  fi: {
    ritual_addon_full: 'Valittu rituaaliaika ei ole enää vapaana. Valitse toinen aika tai jatka ilman rituaalia.',
    ritual_addon_time: 'Rituaalin aika ei sovi valitulle vuorolle. Valitse jokin tarjolla olevista ajoista.',
    ritual_addon_persons: 'Tarkista rituaalin osallistujamäärä.',
    ritual_addon_unavailable: 'Saunotusrituaali ei ole juuri nyt varattavissa. Jatka ilman rituaalia.',
    ritual_addon_not_allowed: 'Rituaalia ei voi lisätä tähän vuoroon.',
    ritual_addon_invalid: 'Rituaalin valinta on virheellinen. Valitse aika uudelleen.',
  },
  en: {
    ritual_addon_full: 'The ritual time you chose is no longer available. Choose another time or continue without the ritual.',
    ritual_addon_time: 'This ritual time does not fit the selected session. Choose one of the times shown.',
    ritual_addon_persons: 'Please check the number of ritual guests.',
    ritual_addon_unavailable: 'The sauna ritual cannot be booked right now. Please continue without the ritual.',
    ritual_addon_not_allowed: 'A ritual cannot be added to this session.',
    ritual_addon_invalid: 'The ritual selection is not valid. Please choose the time again.',
  },
};
