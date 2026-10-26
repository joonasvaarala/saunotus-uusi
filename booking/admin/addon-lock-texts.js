// booking_180: hallinnan lisäpalvelumuokkauksen lukitusviestit (FI/EN); oletukset ennen tuontia 76.
import { getLang } from './talous-i18n.js';

export const ADDON_LOCK_TEXTS = {
  fi: {
    paid: 'maksettu {{var:n}} kpl',
    link: 'maksulinkillä {{var:n}} kpl',
    hint: 'Maksettuja lisäpalveluita ei voi vähentää tästä. Tee hyvitys tilausnäkymässä.',
    link_hint: 'Avoimella maksulinkillä olevia lisäpalveluita voi vähentää, kun maksu on valmistunut tai linkki on vanhentunut.',
    error_paid: 'Lisäpalvelu on jo maksettu. Hyvitä se ensin tilausnäkymässä.',
    error_link: 'Lisäpalvelu on avoimella maksulinkillä. Odota maksua tai linkin vanhenemista.',
    error_unknown: 'Lisäpalvelujen maksutilaa ei voitu varmistaa. Muokkaus on estetty turvallisuussyistä.',
    invoiced: 'Laskutettu ({{var:no}}) – rivit ja maksut lukittu. Korjaa hyvityslaskulla.',
    invoiced_rows: 'Laskutettu ({{var:no}}) – rivit lukittu.',
    error_invoiced: 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.',
    invoiced_hint: 'Tilaus on laskutettu: varauksen voi muuttaa, mutta laskurivit ja summa eivät muutu.',
    persons_invoiced_hint: 'Henkilömäärän muutos ei muuta laskun summaa.',
    cancel_invoiced_hint: 'Laskutettu tilaus: hyvitys tehdään hyvityslaskulla.',
    link_stale: 'Linkin summa ei vastaa enää maksamatonta osuutta – luo uusi linkki.',
    link_unpayable_invoiced: 'Linkkiä ei voi maksaa, koska tilaus on laskutettu.',
  },
  en: {
    paid: '{{var:n}} paid',
    link: '{{var:n}} on payment link',
    hint: 'Paid add-ons cannot be reduced here. Refund them from the order view.',
    link_hint: 'Add-ons on open payment links can be reduced after payment is completed or the link expires.',
    error_paid: 'An add-on has already been paid. Refund it from the order view first.',
    error_link: 'An add-on is on an open payment link. Wait for payment or for the link to expire.',
    error_unknown: 'The payment status of the add-ons could not be verified. Editing is blocked for safety.',
    invoiced: 'Invoiced ({{var:no}}) – lines and payments are locked. Correct with a credit invoice.',
    invoiced_rows: 'Invoiced ({{var:no}}) – lines are locked.',
    error_invoiced: 'This order is invoiced: lines and payments cannot be changed. Correct with a credit invoice.',
    invoiced_hint: 'This order is invoiced: the booking can be changed, but the invoice lines and total stay the same.',
    persons_invoiced_hint: 'Changing the number of guests does not change the invoice total.',
    cancel_invoiced_hint: 'Invoiced order: the refund is made with a credit invoice.',
    link_stale: 'The link amount no longer matches the unpaid part – create a new link.',
    link_unpayable_invoiced: 'The link cannot be paid because the order is invoiced.',
  },
};

export const alt = (key, vars = {}) => {
  const dict = ADDON_LOCK_TEXTS[getLang()] || ADDON_LOCK_TEXTS.fi;
  return (dict[key] || ADDON_LOCK_TEXTS.fi[key] || key).replace(/\{\{var:(\w+)\}\}/g, (_, name) => String(vars[name] ?? ''));
};
