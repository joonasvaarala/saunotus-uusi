// HALL-AVOIMET-01: Avoimet maksut (Tilaukset › Avoimet maksut, Tarkista-osio, ⋯-valikon ja "näytä lisää" -painikkeen nimet).
// Oletukset FI+EN; tuontitiedosto: content/site-texts.pending-import-169.json. Paikkamerkit {{var:nimi}}.
import { getLang } from './talous-i18n.js';

export const OP_TEXTS = {
  fi: {
    'ui.admin.open_payments.tab': 'Avoimet maksut',
    'ui.admin.open_payments.links': 'Maksulinkit',
    'ui.admin.open_payments.refunds': 'Hyvitykset',
    'ui.admin.open_payments.more_actions': 'Lisää toimintoja',
    'ui.admin.open_payments.load_more': 'Näytä lisää ({{var:n}} jäljellä)',
    'ui.admin.open_payments.review_title': 'Avoimet maksut',
    'ui.admin.open_payments.review_hint': 'Maksulinkkejä tai hyvityksiä, jotka vaativat toimenpiteitä. Jono on Tilaukset-sivun Avoimet maksut -välilehdellä.',
    'ui.admin.open_payments.review_links': 'Maksulinkit, jotka vaativat toimenpiteitä: {{var:n}}',
    'ui.admin.open_payments.review_refunds': 'Hyvitykset, jotka ovat epäonnistuneet tai odottaneet yli vuorokauden: {{var:n}}',
    'ui.admin.open_payments.review_open': 'Avaa Avoimet maksut',
  },
  en: {
    'ui.admin.open_payments.tab': 'Open payments',
    'ui.admin.open_payments.links': 'Payment links',
    'ui.admin.open_payments.refunds': 'Refunds',
    'ui.admin.open_payments.more_actions': 'More actions',
    'ui.admin.open_payments.load_more': 'Show more ({{var:n}} left)',
    'ui.admin.open_payments.review_title': 'Open payments',
    'ui.admin.open_payments.review_hint': 'Payment links or refunds that need action. The queue is in the Open payments tab of Orders.',
    'ui.admin.open_payments.review_links': 'Payment links needing action: {{var:n}}',
    'ui.admin.open_payments.review_refunds': 'Refunds that failed or have waited over a day: {{var:n}}',
    'ui.admin.open_payments.review_open': 'Open Open payments',
  },
};

export function op(key, vars, lang = getLang()) {
  const raw = OP_TEXTS[lang]?.[key] ?? OP_TEXTS.fi[key] ?? key;
  return String(raw).replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}
