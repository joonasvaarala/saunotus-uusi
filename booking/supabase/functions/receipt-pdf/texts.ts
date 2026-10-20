// Kuitti-PDF:n asiakasnäkyvät tekstit (sopimus §18, avaimet email.receipt_pdf.<kohta>): repon oletukset = varateksti; tuotannossa luetaan tietokannasta
// (_shared/site_texts.ts). Kuitti on kirjanpitolain/ALV-lain mukainen tosite → kaikki kentät luokkaa protected (hyväksyjinä Joonas ja Otto, §18.6).
// Kuitti-PDF tallennetaan Storageen ensimmäisen haun yhteydessä (muuttumaton tosite): tekstimuutos ei muuta jo luotuja kuitteja.
// Paikkamerkit: {{setting:business_name}}, {{var:…}} (id, ref, date, time).
import type { TextTable } from "../_shared/site_texts.ts";

const P = "protected" as const;
export const RECEIPT_PDF_TEXTS: TextTable = {
  "email.receipt_pdf.producer": { fi: "{{setting:business_name}}", en: "{{setting:business_name}}", cls: P },
  "email.receipt_pdf.business_id": { fi: "Y-tunnus {{var:id}}", en: "Business ID {{var:id}}", cls: P },
  "email.receipt_pdf.vat_id": { fi: "ALV-tunnus {{var:id}}", en: "VAT ID {{var:id}}", cls: P },
  "email.receipt_pdf.title_refund": { fi: "HYVITYSKUITTI", en: "REFUND RECEIPT", cls: P },
  "email.receipt_pdf.title_invoice": { fi: "KUITTI / LASKU", en: "RECEIPT / INVOICE", cls: P },
  "email.receipt_pdf.title": { fi: "KUITTI", en: "RECEIPT", cls: P },
  "email.receipt_pdf.date": { fi: "Päivämäärä", en: "Date", cls: P },
  "email.receipt_pdf.date_value": { fi: "{{var:date}} klo {{var:time}}", en: "{{var:date}} at {{var:time}}", cls: P },
  "email.receipt_pdf.order": { fi: "Tilaus", en: "Order", cls: P },
  "email.receipt_pdf.payment_method": { fi: "Maksutapa", en: "Payment method", cls: P },
  "email.receipt_pdf.original": { fi: "Alkuperäinen kuitti", en: "Original receipt", cls: P },
  "email.receipt_pdf.reason": { fi: "Hyvityksen syy", en: "Reason", cls: P },
  "email.receipt_pdf.buyer": { fi: "Ostaja", en: "Buyer", cls: P },
  "email.receipt_pdf.reference": { fi: "Viitteenne: {{var:ref}}", en: "Your reference: {{var:ref}}", cls: P },
  "email.receipt_pdf.col_item": { fi: "Tuote", en: "Item", cls: P },
  "email.receipt_pdf.col_qty": { fi: "Kpl", en: "Qty", cls: P },
  "email.receipt_pdf.col_unit": { fi: "À hinta", en: "Unit", cls: P },
  "email.receipt_pdf.col_vat": { fi: "ALV", en: "VAT", cls: P },
  "email.receipt_pdf.col_vat_pct": { fi: "ALV %", en: "VAT %", cls: P },
  "email.receipt_pdf.col_vat_eur": { fi: "ALV €", en: "VAT €", cls: P },
  "email.receipt_pdf.col_gross": { fi: "Brutto", en: "Gross", cls: P },
  "email.receipt_pdf.col_total": { fi: "Yhteensä", en: "Total", cls: P },
  "email.receipt_pdf.word_qty": { fi: "kpl", en: "pcs", cls: P },
  "email.receipt_pdf.word_net": { fi: "veroton", en: "excl. VAT", cls: P },
  "email.receipt_pdf.word_vat": { fi: "ALV", en: "VAT", cls: P },
  "email.receipt_pdf.word_gross": { fi: "brutto", en: "gross", cls: P },
  "email.receipt_pdf.giftcard_info": { fi: "Arvonlisävero on kirjattu lahjakortin myynnissä. Tämä erittely on vain tiedoksi, eikä sitä kirjata uudelleen.", en: "VAT was recorded when the gift card was sold. This breakdown is for information only and is not recorded again.", cls: P },
  "email.receipt_pdf.vat_breakdown": { fi: "ALV-erittely", en: "VAT breakdown", cls: P },
  "email.receipt_pdf.col_rate": { fi: "Verokanta", en: "Rate", cls: P },
  "email.receipt_pdf.col_net": { fi: "Veroton", en: "Excl. VAT", cls: P },
  "email.receipt_pdf.total_gross": { fi: "Yhteensä (sis. ALV)", en: "Total (incl. VAT)", cls: P },
  "email.receipt_pdf.of_which_vat": { fi: "josta ALV", en: "of which VAT", cls: P },
  "email.receipt_pdf.rounding": { fi: "Käteispyöristys", en: "Cash rounding", cls: P },
  "email.receipt_pdf.refunded": { fi: "Hyvitetty", en: "Refunded", cls: P },
  "email.receipt_pdf.paid": { fi: "Maksettu", en: "Paid", cls: P },
};
