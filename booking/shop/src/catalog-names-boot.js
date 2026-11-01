// Sivut, joilla ei ole viikko-ohjelmaa (quiet-week.js hakee katalogin jo siellä).
// public_catalog epäonnistuu → esirenderöity nimi jää.
import { rpc } from './sb.js';
import { applyCatalogNames } from './catalog-names.js';

const lang = document.documentElement.lang === 'en' ? 'en' : 'fi';
if (window.BOOKING_CONFIG?.url && document.querySelector('[data-catalog-name]')) {
  rpc('public_catalog', {}).then((rows) => {
    if (Array.isArray(rows)) applyCatalogNames(document, rows, lang);
  }).catch(() => { /* staattinen nimi jää */ });
}
