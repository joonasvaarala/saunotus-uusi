// Oman saunavuoron kaksivaiheinen valinta (alku → kesto): kaupan tekstit FI + EN. Yhdistetään T-sanakirjaan (i18n.js) → sivutekstiavaimet ui.shop.slot_*
// (text-registry.js: camelCase → snake_case). Tuonti: content/site-texts.pending-import-177.json. {start} täytetään kutsuhetkellä.
export const SLOT_START_TEXTS = {
  fi: {
    slotStartTitle: 'Valitse aloitusaika',
    slotStartLead: 'Valitse ensin aloitusaika, sitten kesto.',
    slotDurationTitle: 'Valitse kesto – alkaa {start}',
    slotChangeStart: '← Vaihda aloitusaika',
    slotNoFreeDurations: 'Ei vapaita kestoja valitulle päivälle. Valitse toinen päivä.',
  },
  en: {
    slotStartTitle: 'Choose a start time',
    slotStartLead: 'Choose a start time first, then a duration.',
    slotDurationTitle: 'Choose a duration – starts at {start}',
    slotChangeStart: '← Change start time',
    slotNoFreeDurations: 'No available durations for the selected day. Please pick another day.',
  },
};
