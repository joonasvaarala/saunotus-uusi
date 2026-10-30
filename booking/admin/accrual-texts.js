// Suoriteperusteinen raportti (booking_219). Oletukset FI+EN, samat kuin content/site-texts.pending-import-105.json.
import { getLang } from './talous-i18n.js';

export const ACCRUAL_TEXTS = {
  fi: {
    'ui.admin.accrual.basis_payment': 'Kassaperuste',
    'ui.admin.accrual.basis_service': 'Suoriteperuste',
    'ui.admin.accrual.basis_legend': 'Raportin peruste',
    'ui.admin.accrual.basis_note': 'Palvelupäivä (varaus tai tapahtuma). Kassaperusteinen ALV-raportti säilyy ennallaan: ennakon vero erääntyy maksupäivänä.',
    'ui.admin.accrual.sales': 'Myynti palvelupäivän mukaan',
    'ui.admin.accrual.refunds': 'Hyvitykset palvelupäivän mukaan',
    'ui.admin.accrual.sales_vat': 'Myynnin ALV palvelupäivän mukaan',
    'ui.admin.accrual.refunds_vat': 'Hyvitysten ALV palvelupäivän mukaan',
    'ui.admin.accrual.no_refunds': 'Ei hyvityksiä tällä palvelujaksolla.',
    'ui.admin.accrual.advances': 'Saadut ennakot',
    'ui.admin.accrual.advances_note': 'Maksettu viimeistään jakson lopussa, palvelupäivä sen jälkeen. Hyvitykset siihen päivään asti on vähennetty.',
    'ui.admin.accrual.advances_services': 'Saadut ennakot, palvelut',
    'ui.admin.accrual.gift_cards': 'Käyttämättömät lahjakortit',
    'ui.admin.accrual.gift_cards_note': 'Oma lahjakortti on ennakko, kunnes se lunastetaan tai vanhenee. Arvonlisävero on kirjattu myynnissä.',
    'ui.admin.accrual.advances_total': 'Ennakot yhteensä',
    'ui.admin.accrual.as_of': 'Tilanne {{var:date}}',
    'ui.admin.accrual.csv': 'Suorite CSV',
    'ui.admin.accrual.col_product': 'Tuote',
    'ui.admin.accrual.col_count': 'kpl',
    'ui.admin.accrual.col_net': 'Veroton',
    'ui.admin.accrual.col_vat_pct': 'ALV %',
    'ui.admin.accrual.col_vat_eur': 'ALV €',
    'ui.admin.accrual.col_gross': 'Brutto',
    'ui.admin.accrual.total': 'Yhteensä',
    'ui.admin.accrual.empty': 'Ei myyntiä tällä palvelujaksolla.',
  },
  en: {
    'ui.admin.accrual.basis_payment': 'Cash basis',
    'ui.admin.accrual.basis_service': 'Service date',
    'ui.admin.accrual.basis_legend': 'Report basis',
    'ui.admin.accrual.basis_note': 'Service date (booking or event). The cash-basis VAT report is unchanged: VAT on an advance is due on the payment date.',
    'ui.admin.accrual.sales': 'Sales by service date',
    'ui.admin.accrual.refunds': 'Refunds by service date',
    'ui.admin.accrual.sales_vat': 'Sales VAT by service date',
    'ui.admin.accrual.refunds_vat': 'Refund VAT by service date',
    'ui.admin.accrual.no_refunds': 'No refunds in this service period.',
    'ui.admin.accrual.advances': 'Advances received',
    'ui.admin.accrual.advances_note': 'Paid on or before the period end, with the service date after that. Refunds up to that date are deducted.',
    'ui.admin.accrual.advances_services': 'Advances received, services',
    'ui.admin.accrual.gift_cards': 'Unused gift cards',
    'ui.admin.accrual.gift_cards_note': 'A gift card issued here is an advance until it is redeemed or expires. VAT was recorded at sale.',
    'ui.admin.accrual.advances_total': 'Advances total',
    'ui.admin.accrual.as_of': 'Balance on {{var:date}}',
    'ui.admin.accrual.csv': 'Service-date CSV',
    'ui.admin.accrual.col_product': 'Product',
    'ui.admin.accrual.col_count': 'Qty',
    'ui.admin.accrual.col_net': 'Net',
    'ui.admin.accrual.col_vat_pct': 'VAT %',
    'ui.admin.accrual.col_vat_eur': 'VAT €',
    'ui.admin.accrual.col_gross': 'Gross',
    'ui.admin.accrual.total': 'Total',
    'ui.admin.accrual.empty': 'No sales in this service period.',
  },
};

export function accrualText(key, vars = {}, lang = getLang()) {
  const bag = ACCRUAL_TEXTS[lang] || ACCRUAL_TEXTS.fi;
  let text = bag[key] || ACCRUAL_TEXTS.fi[key] || key;
  for (const [name, value] of Object.entries(vars)) text = text.replaceAll(`{{var:${name}}}`, String(value));
  return text;
}
