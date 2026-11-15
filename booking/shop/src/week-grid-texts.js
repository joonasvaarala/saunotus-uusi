// Viikko-ohjelman tekstit (etusivu + saunavuorot). Avaimet ui.site.vk_*; varateksti = sama kuin content/site-texts.pending-import-171.json (+ 181, joka ohittaa muuttuneet ja lisää uudet).
// Build lukee tekstit sivuteksteistä (src/week-grid.mjs, tx()) ja vie ne .vk-elementin data-vk-texts-attribuuttiin; selain käyttää samoja.
// Paikkamerkki {{var:n}} (ja ale-tekstien {{var:pct}}, {{var:was}}, {{var:now}}) muutetaan muotoon {n} buildissa; selain täyttää arvon (week-grid-view.js).
export const WEEK_GRID_TEXTS = Object.freeze({
  'ui.site.vk_kicker': { prop: 'kicker', fi: 'Saunavuorot', en: 'Sauna sessions' },
  'ui.site.vk_title': { prop: 'title', fi: 'Tulevat päivät saunalla', en: 'Upcoming days at the sauna' },
  'ui.site.vk_prev': { prop: 'prev', fi: 'Edelliset 7 päivää', en: 'Previous 7 days' },
  'ui.site.vk_next': { prop: 'next', fi: 'Seuraavat 7 päivää', en: 'Next 7 days' },
  'ui.site.vk_prev_off': { prop: 'prevOff', fi: 'Edellisiä päiviä ei ole: jakso alkaa tänään', en: 'No earlier days: the period starts today' },
  'ui.site.vk_next_off': { prop: 'nextOff', fi: 'Pidemmälle ei voi selata', en: 'You cannot browse further ahead' },
  'ui.site.vk_now': { prop: 'now', fi: 'Tänään', en: 'Today' },
  'ui.site.vk_week_nav': { prop: 'weekNav', fi: 'Valitse päivä', en: 'Choose a day' },
  'ui.site.vk_day_prev': { prop: 'dayPrev', fi: 'Edellinen päivä', en: 'Previous day' },
  'ui.site.vk_day_next': { prop: 'dayNext', fi: 'Seuraava päivä', en: 'Next day' },
  'ui.site.vk_tab_none': { prop: 'tabNone', fi: 'ei vuoroja', en: 'nothing available' },
  'ui.site.vk_book': { prop: 'book', fi: 'Varaa', en: 'Book' },
  'ui.site.vk_lane_public': { prop: 'laneP', fi: 'Yleiset vuorot', en: 'Public sessions' },
  'ui.site.vk_lane_public_note': { prop: 'noteP', fi: 'Tule muiden joukkoon. Hinta / hlö.', en: 'Join other guests. Price per person.' },
  'ui.site.vk_lane_own': { prop: 'laneO', fi: 'Oma sauna', en: 'Private sauna' },
  'ui.site.vk_lane_own_note': { prop: 'noteO', fi: 'Koko sauna teille. Hinta / seurue.', en: 'The whole sauna for your group. Price per group.' },
  'ui.site.vk_lane_care': { prop: 'laneC', fi: 'Hoidot ja rituaalit', en: 'Treatments and rituals' },
  'ui.site.vk_lane_care_note': { prop: 'noteC', fi: 'Valitse vapaa alkuaika varauksessa.', en: 'Choose a free start time when booking.' },
  'ui.site.vk_care_later': { prop: 'careLater', fi: 'Hoitojen ajat avautuvat lähempänä ajankohtaa.', en: 'Treatment times open closer to the date.' },
  'ui.site.vk_care_error': { prop: 'careError', fi: 'Hoitojen aikoja ei saatu haettua. Yritä hetken päästä uudelleen.', en: 'Could not load treatment times. Please try again in a moment.' },
  'ui.site.vk_none_public': { prop: 'none', fi: 'Ei yleisiä vuoroja', en: 'No public sessions' },
  'ui.site.vk_none_own': { prop: 'noneOwn', fi: 'Ei oman saunan vuoroja', en: 'No private sauna sessions' },
  'ui.site.vk_none_care': { prop: 'noneCare', fi: 'Ei hoitoja tänä päivänä', en: 'No treatments this day' },
  'ui.site.vk_none_day': { prop: 'noneDay', fi: 'Ei tänä päivänä', en: 'Not this day' },
  'ui.site.vk_next_with': { prop: 'nextWith', fi: 'Seuraava {{var:day}} {{var:date}}', en: 'Next: {{var:day}} {{var:date}}' },
  'ui.site.vk_own_name': { prop: 'own', fi: 'Oma saunavuoro', en: 'Private sauna session' },
  'ui.site.vk_from': { prop: 'from', fi: 'alk.', en: 'from' },
  'ui.site.vk_own_dur_range': { prop: 'durRange', fi: '{{var:a}}–{{var:b}} h', en: '{{var:a}}–{{var:b}} h' },
  'ui.site.vk_own_dur_one': { prop: 'durOne', fi: '{{var:n}} h', en: '{{var:n}} h' },
  'ui.site.vk_after': { prop: 'after', fi: 'Jälkilöylyt', en: 'After Session Sauna' },
  'ui.site.vk_per_person': { prop: 'per', fi: '/ hlö', en: '/ person' },
  'ui.site.vk_full': { prop: 'full', fi: 'Täynnä', en: 'Full' },
  'ui.site.vk_left_one': { prop: 'leftOne', fi: '1 paikka jäljellä', en: '1 spot left' },
  'ui.site.vk_left_many': { prop: 'leftMany', fi: '{{var:n}} paikkaa jäljellä', en: '{{var:n}} spots left' },
  'ui.site.vk_left_chip': { prop: 'leftChip', fi: '{{var:n}} jäljellä', en: '{{var:n}} left' },
  'ui.site.vk_legend_free': { prop: 'legFree', fi: 'Vapaa', en: 'Available' },
  'ui.site.vk_legend_low': { prop: 'legLow', fi: 'Vähän jäljellä', en: 'Few left' },
  'ui.site.vk_event_tag': { prop: 'eventTag', fi: 'Tapahtuma', en: 'Event' },
  'ui.site.vk_events_label': { prop: 'evLabel', fi: 'Tapahtumat:', en: 'Events:' },
  'ui.site.vk_events_none': { prop: 'evNone', fi: 'ei näinä päivinä.', en: 'none on these days.' },
  'ui.site.vk_events_next': { prop: 'evNext', fi: 'Seuraavaksi', en: 'Next up:' },
  'ui.site.vk_events_and': { prop: 'evAnd', fi: 'ja', en: 'and' },
  'ui.site.vk_events_full': { prop: 'evFull', fi: 'täynnä, jonoon', en: 'full, join the waitlist' },
  'ui.site.vk_training': { prop: 'training', fi: 'Koulutukset', en: 'Sauna training' },
  'ui.site.vk_all_sessions': { prop: 'all', fi: 'Kaikki vuorot →', en: 'All sessions →' },
  'ui.site.vk_error': { prop: 'error', fi: 'Näiden päivien vapaita aikoja ei saatu haettua. Yritä hetken päästä uudelleen.', en: 'Could not load the free times for these days. Please try again in a moment.' },
});
/** Tekstit: get(key) → merkkijono. Palauttaa { prop: teksti } + yhteiset (päivien nimet, kieli, uusi välilehti, Tänään, hiljaisen ajan ale). */
export function weekGridTexts(get, { lang, daysLong, today, newTab, quietBadge, quietSr }) {
  const T = { lang, daysLong, today, newTab: String(newTab || '').trim(), quietBadge, quietSr };
  for (const [key, def] of Object.entries(WEEK_GRID_TEXTS)) T[def.prop] = get(key, def);
  return T;
}
