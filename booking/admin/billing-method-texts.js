// booking_187: yrityksen laskutustapojen FI/EN-oletustekstit.
// Rekisteriavaimet: ui.admin.billing_method.*
import { getLang } from './talous-i18n.js';

export const BILLING_METHOD_TEXTS = {
  fi: {
    label: 'Laskutustapa',
    einvoice: 'Verkkolasku',
    pdf: 'PDF-lasku sähköpostiin',
    online: 'Verkkomaksu (ei laskua)',
    company_details: 'Yritysasiakas – yritystiedot',
  },
  en: {
    label: 'Billing method',
    einvoice: 'E-invoice',
    pdf: 'PDF invoice by email',
    online: 'Online payment (no invoice)',
    company_details: 'Business customer – company details',
  },
};

export const billingMethodText = (key) => {
  const dict = BILLING_METHOD_TEXTS[getLang()] || BILLING_METHOD_TEXTS.fi;
  return dict[key] ?? BILLING_METHOD_TEXTS.fi[key] ?? key;
};
