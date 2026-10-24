// Hiljaisten aikojen ale (booking_162): kaupan tekstit FI + EN. Yhdistetään T-sanakirjaan (i18n.js) → sivutekstiavaimet ui.shop.quiet_*
// (text-registry.js: camelCase → snake_case). Tuonti: content/site-texts.pending-import-59.json. {pct}/{was}/{now} täytetään kutsuhetkellä.
export const QUIET_TEXTS = {
  fi: {
    quietBadge: '−{pct} %',
    quietSr: 'Hiljaisen ajan ale {pct} %: normaalihinta {was}, nyt {now}.',
    quietDay: 'hiljaisen ajan ale',
    quietList: 'Hiljaisen ajan ale: vapaita vuoroja lähipäivinä alennettuun hintaan.',
    quietCheckout: 'Hiljaisen ajan ale −{pct} %',
    quietNote: 'Vuoro on vielä vapaa, joten saat sen hiljaisen ajan alennuksella. Hinta lukitaan, kun teet varauksen.',
    quietCodeNote: 'Hiljaisen ajan ale on koodia edullisempi, joten koodia ei käytetä tässä varauksessa. Etuja ei voi yhdistää.',
  },
  en: {
    quietBadge: '−{pct}%',
    quietSr: 'Quiet-time discount {pct}%: regular price {was}, now {now}.',
    quietDay: 'quiet-time discount',
    quietList: 'Quiet-time discount: available sessions in the next few days at a reduced price.',
    quietCheckout: 'Quiet-time discount −{pct}%',
    quietNote: 'This session is still available, so you get it at a quiet-time discount. The price is locked when you book.',
    quietCodeNote: 'The quiet-time discount is better than the code, so the code is not used for this booking. Benefits cannot be combined.',
  },
};
