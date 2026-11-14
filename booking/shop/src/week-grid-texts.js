// Viikko-ohjelman tekstit (etusivu + saunavuorot). Avaimet ui.site.vk_*; varateksti = sama kuin content/site-texts.pending-import-171.json.
// Build lukee tekstit sivuteksteistä (src/week-grid.mjs, tx()) ja vie ne .vk-elementin data-vk-texts-attribuuttiin; selain käyttää samoja.
// Paikkamerkki {{var:n}} (ja ale-tekstien {{var:pct}}, {{var:was}}, {{var:now}}) muutetaan muotoon {n} buildissa; selain täyttää arvon (week-grid-view.js).
export const WEEK_GRID_TEXTS = Object.freeze({
  'ui.site.vk_title': { prop: 'title', fi: 'Tällä viikolla saunassa', en: 'This week at the sauna' },
  'ui.site.vk_title_week': { prop: 'titleWeek', fi: 'Viikko {{var:n}} saunassa', en: 'Week {{var:n}} at the sauna' },
  'ui.site.vk_prev': { prop: 'prev', fi: 'Edellinen viikko', en: 'Previous week' },
  'ui.site.vk_next': { prop: 'next', fi: 'Seuraava viikko', en: 'Next week' },
  'ui.site.vk_week': { prop: 'week', fi: 'Viikko', en: 'Week' },
  'ui.site.vk_now': { prop: 'now', fi: 'Tämä viikko', en: 'This week' },
  'ui.site.vk_week_nav': { prop: 'weekNav', fi: 'Valitse viikko ja päivä', en: 'Choose week and day' },
  'ui.site.vk_lane_public': { prop: 'laneP', fi: 'Yleiset vuorot', en: 'Public sessions' },
  'ui.site.vk_lane_public_note': { prop: 'noteP', fi: 'Tule muiden joukkoon. Hinta / hlö.', en: 'Join other guests. Price per person.' },
  'ui.site.vk_lane_own': { prop: 'laneO', fi: 'Oma sauna', en: 'Private sauna' },
  'ui.site.vk_lane_own_note': { prop: 'noteO', fi: 'Koko sauna teille. Hinta / seurue.', en: 'The whole sauna for your group. Price per group.' },
  'ui.site.vk_lane_care': { prop: 'laneC', fi: 'Hoidot ja rituaalit', en: 'Treatments and rituals' },
  'ui.site.vk_lane_care_note': { prop: 'noteC', fi: 'Valitse vapaa alkuaika varauksessa.', en: 'Choose a free start time when booking.' },
  'ui.site.vk_care_later': { prop: 'careLater', fi: 'Hoitojen ajat avautuvat lähempänä ajankohtaa.', en: 'Treatment times open closer to the date.' },
  'ui.site.vk_none_public': { prop: 'none', fi: 'Ei yleisiä vuoroja', en: 'No public sessions' },
  'ui.site.vk_own_name': { prop: 'own', fi: 'Oma saunavuoro', en: 'Private sauna session' },
  'ui.site.vk_from': { prop: 'from', fi: 'alk.', en: 'from' },
  'ui.site.vk_own_dur_range': { prop: 'durRange', fi: '{{var:a}}–{{var:b}} h', en: '{{var:a}}–{{var:b}} h' },
  'ui.site.vk_own_dur_one': { prop: 'durOne', fi: '{{var:n}} h', en: '{{var:n}} h' },
  'ui.site.vk_after': { prop: 'after', fi: 'Jälkilöylyt', en: 'After Session Sauna' },
  'ui.site.vk_per_person': { prop: 'per', fi: '/ hlö', en: '/ person' },
  'ui.site.vk_full': { prop: 'full', fi: 'Täynnä', en: 'Full' },
  'ui.site.vk_left_one': { prop: 'leftOne', fi: '1 paikka jäljellä', en: '1 spot left' },
  'ui.site.vk_left_many': { prop: 'leftMany', fi: '{{var:n}} paikkaa jäljellä', en: '{{var:n}} spots left' },
  'ui.site.vk_event_tag': { prop: 'eventTag', fi: 'Tapahtuma', en: 'Event' },
  'ui.site.vk_events_label': { prop: 'evLabel', fi: 'Tapahtumat:', en: 'Events:' },
  'ui.site.vk_events_none': { prop: 'evNone', fi: 'ei tällä viikolla.', en: 'none this week.' },
  'ui.site.vk_events_next': { prop: 'evNext', fi: 'Seuraavaksi', en: 'Next up:' },
  'ui.site.vk_events_and': { prop: 'evAnd', fi: 'ja', en: 'and' },
  'ui.site.vk_events_full': { prop: 'evFull', fi: 'täynnä, jonoon', en: 'full, join the waitlist' },
  'ui.site.vk_training': { prop: 'training', fi: 'Koulutukset', en: 'Sauna training' },
  'ui.site.vk_all_sessions': { prop: 'all', fi: 'Kaikki vuorot →', en: 'All sessions →' },
  'ui.site.vk_error': { prop: 'error', fi: 'Viikon vapaita aikoja ei saatu haettua. Yritä hetken päästä uudelleen.', en: 'Could not load the free times for this week. Please try again in a moment.' },
});
/** Tekstit: get(key) → merkkijono. Palauttaa { prop: teksti } + yhteiset (päivien nimet, kieli, uusi välilehti, Tänään, hiljaisen ajan ale). */
export function weekGridTexts(get, { lang, daysLong, today, newTab, quietBadge, quietSr }) {
  const T = { lang, daysLong, today, newTab: String(newTab || '').trim(), quietBadge, quietSr };
  for (const [key, def] of Object.entries(WEEK_GRID_TEXTS)) T[def.prop] = get(key, def);
  return T;
}
