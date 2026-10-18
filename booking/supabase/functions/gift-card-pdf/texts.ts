// Lahjakortti-PDF:n asiakasnäkyvät tekstit (sopimus §18, avaimet email.gift_card_pdf.<kohta>): repon oletukset = varateksti; tuotannossa luetaan tietokannasta
// (_shared/site_texts.ts). Paikkamerkit: {{setting:business_name}}, {{var:…}} (date, n, web, contact, id). PDF-säännöt (A4 pysty, hinta vain summalahjakortissa) ovat render.ts:ssä.
// Teksti ajetaan san():n läpi (WinAnsi-kirjasimet), joten DB-teksti ei voi kaataa PDF:n piirtoa.
import type { TextTable } from "../_shared/site_texts.ts";

export const GIFT_CARD_PDF_TEXTS: TextTable = {
  "email.gift_card_pdf.title": { fi: "Lahjakortti", en: "Gift card" },
  "email.gift_card_pdf.producer": { fi: "{{setting:business_name}}", en: "{{setting:business_name}}" },
  "email.gift_card_pdf.open_card_name": { fi: "Käy kaikkiin palveluihimme", en: "Valid for all our services" },
  "email.gift_card_pdf.default_package_name": { fi: "Savusaunalahjakortti", en: "Smoke sauna gift card" },
  "email.gift_card_pdf.includes": { fi: "Sisältää", en: "Includes" },
  "email.gift_card_pdf.for": { fi: "Saajalle", en: "For" },
  "email.gift_card_pdf.from": { fi: "Lahjoittaja", en: "From" },
  "email.gift_card_pdf.code_label": { fi: "Lahjakortin koodi", en: "Gift card code" },
  "email.gift_card_pdf.valid_until": { fi: "Voimassa", en: "Valid until" },
  "email.gift_card_pdf.valid_value": { fi: "{{var:date}} asti", en: "{{var:date}}" },
  "email.gift_card_pdf.persons_label": { fi: "Henkilömäärä", en: "Persons" },
  "email.gift_card_pdf.persons_value": { fi: "{{var:n}} henkilöä", en: "{{var:n}} persons" },
  "email.gift_card_pdf.balance": { fi: "Saldo", en: "Balance" },
  "email.gift_card_pdf.issued": { fi: "Myönnetty", en: "Issued" },
  "email.gift_card_pdf.how_online": { fi: "Varaa aika osoitteessa {{var:web}} ja syötä koodi maksuvaiheessa tai kerro koodi saunalla.", en: "Book at {{var:web}} and enter the code at checkout, or tell us the code at the sauna.", cls: "protected" },
  "email.gift_card_pdf.how_offline": { fi: "Kerro koodi saunalla tai ota yhteyttä: {{var:contact}}.", en: "Tell us the code at the sauna or contact us: {{var:contact}}.", cls: "protected" },
  "email.gift_card_pdf.stamp_expired": { fi: "VANHENTUNUT", en: "EXPIRED" },
  "email.gift_card_pdf.stamp_used": { fi: "KÄYTETTY", en: "USED" },
  "email.gift_card_pdf.footer_name": { fi: "{{setting:business_name}}", en: "{{setting:business_name}}" },
  "email.gift_card_pdf.business_id": { fi: "Y-tunnus {{var:id}}", en: "Business ID {{var:id}}", cls: "protected" },
};
