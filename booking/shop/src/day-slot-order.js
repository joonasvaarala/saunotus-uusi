import { visibleWaitlistSlots } from './waitlist-logic.js';

// Vain julkisen päivänäkymän tuotteen sisäinen vuorolista. Käytä samaa
// saatavuustulosta kuin valinta-/jonopainike; älä laske kapasiteettia uudelleen.
// Aloita aikajärjestyksestä, säilytä se kummassakin ryhmässä (vakaa sort).
export const daySlotsAvailableFirst = (rows) => visibleWaitlistSlots(rows)
  .sort((a, b) => Number((a.r || a).status !== 'available') - Number((b.r || b).status !== 'available'));
