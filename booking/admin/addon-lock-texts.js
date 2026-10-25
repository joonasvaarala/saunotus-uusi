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
  },
  en: {
    paid: '{{var:n}} paid',
    link: '{{var:n}} on payment link',
    hint: 'Paid add-ons cannot be reduced here. Refund them from the order view.',
    link_hint: 'Add-ons on open payment links can be reduced after payment is completed or the link expires.',
    error_paid: 'An add-on has already been paid. Refund it from the order view first.',
    error_link: 'An add-on is on an open payment link. Wait for payment or for the link to expire.',
    error_unknown: 'The payment status of the add-ons could not be verified. Editing is blocked for safety.',
  },
};

export const alt = (key, vars = {}) => {
  const dict = ADDON_LOCK_TEXTS[getLang()] || ADDON_LOCK_TEXTS.fi;
  return (dict[key] || ADDON_LOCK_TEXTS.fi[key] || key).replace(/\{\{var:(\w+)\}\}/g, (_, name) => String(vars[name] ?? ''));
};
