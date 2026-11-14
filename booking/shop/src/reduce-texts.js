// Asiakkaan oma pienennys + automaattinen osahyvitys (booking_284): tilaussivun muutosnäkymän tekstit FI + EN.
// Erillinen moduuli (ei i18n.js:n T-sanakirjaa), koska T-sanakirjan lehdet kuuluvat text-registryyn. Avaimet vastaavat
// content/site-texts.pending-import-139.json -tiedoston ui.public.order_change.reduce.*-rivejä (booking_307: lisäksi pending-import-153); paikkamerkit {{var:nimi}}.
export const REDUCE_TEXTS = {
  fi: {
    preview_refund: 'Uusi hinta on {{var:total}}. Hyvitämme {{var:amount}} alkuperäiseen maksutapaan, yleensä 1–3 pankkipäivässä.',
    refund_eta: 'Hyvitys tulee alkuperäiseen maksutapaan yleensä 1–3 pankkipäivässä.',
    checking: 'Tarkistetaan hintaa ja hyvitystä…',
    confirm: 'Vahvista muutos ja hyvitys {{var:amount}}',
    not_allowed_deadline: 'Maksetun varauksen pienennys onnistuu verkossa vain, kun alkuun on vähintään {{var:hours}} h. Ota yhteyttä sähköpostilla.',
    not_allowed_deadline_private: 'Tämän varauksen maksuton pienennys onnistuu verkossa vain, kun alkuun on vähintään {{var:days}} vrk. Ota yhteyttä sähköpostilla.',
    not_allowed_payment_method: 'Tämän varauksen hyvitystä ei voi tehdä automaattisesti (maksutapa). Ota yhteyttä sähköpostilla, niin hoidamme muutoksen.',
    contact_staff: 'Maksetun varauksen hinnan muutos tehdään henkilökunnan kautta. Ota yhteyttä sähköpostilla.',
    changed: 'Hinta tai hyvitys ehti muuttua. Tarkista uusi summa ja vahvista uudelleen.',
    done_title: 'Varaus muutettu',
    done: 'Varaus on muutettu. Hyvitämme {{var:amount}} alkuperäiseen maksutapaan, yleensä 1–3 pankkipäivässä. Saat siitä vahvistuksen sähköpostiin.',
    back: 'Takaisin varaukseen',
    not_allowed_deadline_private_both: 'Tämän varauksen maksuton pienennys onnistuu verkossa vain, kun sekä nykyisen että uuden ajan alkuun on vähintään {{var:days}} vrk. Ota yhteyttä sähköpostilla.',
    not_allowed_not_classified: 'Tämän palvelun varausta ei voi pienentää verkossa. Ota yhteyttä sähköpostilla, niin hoidamme muutoksen.',
    already_moved: 'Tämän varauksen voi siirtää verkossa vain kerran. Ota yhteyttä sähköpostilla, jos haluat siirtää sitä uudelleen.',
  },
  en: {
    preview_refund: 'The new price is {{var:total}}. We will refund {{var:amount}} to your original payment method, usually within 1–3 bank days.',
    refund_eta: 'The refund goes to your original payment method, usually within 1–3 bank days.',
    checking: 'Checking the price and refund…',
    confirm: 'Confirm the change and refund {{var:amount}}',
    not_allowed_deadline: 'A paid booking can be reduced online only when it starts in at least {{var:hours}} h. Please contact us by email.',
    not_allowed_deadline_private: 'This booking can be reduced free of charge online only when it starts in at least {{var:days}} days. Please contact us by email.',
    not_allowed_payment_method: 'A refund for this booking cannot be made automatically (payment method). Please contact us by email and we will take care of the change.',
    contact_staff: 'A price change on a paid booking is made through our staff. Please contact us by email.',
    changed: 'The price or refund changed. Please check the new amount and confirm again.',
    done_title: 'Booking changed',
    done: 'Your booking has been changed. We will refund {{var:amount}} to your original payment method, usually within 1–3 bank days. You will get a confirmation by email.',
    back: 'Back to the booking',
    not_allowed_deadline_private_both: 'This booking can be reduced free of charge online only when both the current and the new time start in at least {{var:days}} days. Please contact us by email.',
    not_allowed_not_classified: 'Bookings for this service cannot be reduced online. Please contact us by email and we will take care of the change.',
    already_moved: 'This booking can be moved online only once. Please contact us by email if you want to move it again.',
  },
};
/** rt('fi', 'confirm', { amount: '29,00 €' }) */
export function rt(lang, key, vars) {
  const raw = REDUCE_TEXTS[lang]?.[key] ?? REDUCE_TEXTS.fi[key] ?? key;
  return String(raw).replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}
