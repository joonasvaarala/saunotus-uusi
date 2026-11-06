// Joonas 6.11.2026 (t1370u): Koulutukset omana päänavigaation kohtana (#/koulutukset).
// Ei erillistä rinnakkaissivua: sama koulutusten hallinta kuin ennen #/tapahtumat?kategoria=training (views/events.js),
// kategoria lukittuna koulutuksiin. Lisäksi koulutuksen Tekstit-välilehti (kb.products-tekstit FI+EN).
import { render as renderEvents } from './events.js';

export async function render(args) {
  return renderEvents({ ...args, section: 'training' });
}
