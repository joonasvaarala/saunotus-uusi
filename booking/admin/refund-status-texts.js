// Hyvitysten seuranta › "Tarkista tila Montoniosta" (vain luku, montonio-refund {action:'status'}). Oletukset FI+EN,
// samat kuin content/site-texts.pending-import-196.json. Avaimet ui.admin.refund_watch.status_check.*.
import { getLang } from './talous-i18n.js';

export const RS_TEXTS = {
  fi: {
    'ui.admin.refund_watch.status_check.button': 'Tarkista tila Montoniosta',
    'ui.admin.refund_watch.status_check.title': 'Hyvityksen tila Montoniossa',
    'ui.admin.refund_watch.status_check.read_only': 'Vain tarkistus. Mitään ei muuteta, eikä hyvitystä käynnistetä.',
    'ui.admin.refund_watch.status_check.checking': 'Tarkistetaan…',
    'ui.admin.refund_watch.status_check.local': 'Saunotuksen tiedot',
    'ui.admin.refund_watch.status_check.montonio': 'Montonion tiedot',
    'ui.admin.refund_watch.status_check.status': 'Tila',
    'ui.admin.refund_watch.status_check.provider_status': 'Välittäjän tila',
    'ui.admin.refund_watch.status_check.amount': 'Summa',
    'ui.admin.refund_watch.status_check.created': 'Luotu',
    'ui.admin.refund_watch.status_check.order_status': 'Tilauksen maksutila',
    'ui.admin.refund_watch.status_check.off': 'Montonio-yhteys ei ole käytössä, joten Montonion tilaa ei voitu tarkistaa.',
    'ui.admin.refund_watch.status_check.not_configured': 'Montonion tunnuksia ei ole asetettu, joten Montonion tilaa ei voitu tarkistaa.',
    'ui.admin.refund_watch.status_check.not_found': 'Hyvitystä ei löytynyt.',
    'ui.admin.refund_watch.status_check.forbidden': 'Sinulla ei ole oikeutta tarkistaa hyvityksen tilaa.',
    'ui.admin.refund_watch.status_check.montonio_missing': 'Montonion tilauksella ei ole tätä hyvitystä.',
    'ui.admin.refund_watch.status_check.no_provider_refund_id': 'Hyvitystä ei ole vielä lähetetty Montoniolle, joten Montonion tunnusta ei ole.',
    'ui.admin.refund_watch.status_check.no_order_uuid': 'Maksulta puuttuu Montonion tilaustunnus.',
    'ui.admin.refund_watch.status_check.retry_later': 'Montonioon ei saatu yhteyttä. Yritä hetken päästä uudelleen.',
    'ui.admin.refund_watch.status_check.provider_error': 'Montonio palautti virheen. Yritä myöhemmin uudelleen.',
    'ui.admin.refund_watch.status_check.error': 'Tilaa ei voitu tarkistaa: {{var:error}}',
    'ui.admin.refund_watch.status_check.close': 'Sulje',
  },
  en: {
    'ui.admin.refund_watch.status_check.button': 'Check status from Montonio',
    'ui.admin.refund_watch.status_check.title': 'Refund status in Montonio',
    'ui.admin.refund_watch.status_check.read_only': 'Check only. Nothing is changed and no refund is started.',
    'ui.admin.refund_watch.status_check.checking': 'Checking…',
    'ui.admin.refund_watch.status_check.local': 'Saunotus records',
    'ui.admin.refund_watch.status_check.montonio': 'Montonio records',
    'ui.admin.refund_watch.status_check.status': 'Status',
    'ui.admin.refund_watch.status_check.provider_status': 'Provider status',
    'ui.admin.refund_watch.status_check.amount': 'Amount',
    'ui.admin.refund_watch.status_check.created': 'Created',
    'ui.admin.refund_watch.status_check.order_status': 'Order payment status',
    'ui.admin.refund_watch.status_check.off': 'The Montonio connection is turned off, so the Montonio status could not be checked.',
    'ui.admin.refund_watch.status_check.not_configured': 'Montonio credentials are not set, so the Montonio status could not be checked.',
    'ui.admin.refund_watch.status_check.not_found': 'Refund not found.',
    'ui.admin.refund_watch.status_check.forbidden': 'You do not have permission to check the refund status.',
    'ui.admin.refund_watch.status_check.montonio_missing': 'The Montonio order does not have this refund.',
    'ui.admin.refund_watch.status_check.no_provider_refund_id': 'The refund has not been sent to Montonio yet, so there is no Montonio ID.',
    'ui.admin.refund_watch.status_check.no_order_uuid': 'The payment has no Montonio order ID.',
    'ui.admin.refund_watch.status_check.retry_later': 'Could not reach Montonio. Try again in a moment.',
    'ui.admin.refund_watch.status_check.provider_error': 'Montonio returned an error. Try again later.',
    'ui.admin.refund_watch.status_check.error': 'The status could not be checked: {{var:error}}',
    'ui.admin.refund_watch.status_check.close': 'Close',
  },
};

export function rs(key, vars = {}, lang = getLang()) {
  const bag = RS_TEXTS[lang] || RS_TEXTS.fi;
  let text = bag[key] || RS_TEXTS.fi[key] || key;
  for (const [name, value] of Object.entries(vars)) text = text.replaceAll(`{{var:${name}}}`, String(value));
  return text;
}
