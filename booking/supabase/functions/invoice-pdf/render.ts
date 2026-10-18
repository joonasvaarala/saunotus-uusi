// Lasku-PDF (pdf-lib, WinAnsi). Myyjä ja ostaja tulevat laskun snapshotista.
import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";
import { makeT, type TFn } from "../_shared/site_texts.ts";
import { INVOICE_PDF_TEXTS } from "./texts.ts";
export { INVOICE_PDF_TEXTS };

export const san = (s: unknown): string => String(s ?? "").replace(/[^\u0020-\u007E\u00A0-\u00FF\u20AC\u2013\u2014\u2018\u2019\u201C\u201D\u2022\u2026]/g, "?");
const money = (n: number, loc: string) => (loc === "en" ? Number(n).toFixed(2) : Number(n).toFixed(2).replace(".", ",")) + " EUR";

export async function buildInvoicePdf(inv: any, tfn: TFn = makeT(INVOICE_PDF_TEXTS)): Promise<Uint8Array> {
  const loc = inv.locale === "en" ? "en" : "fi";
  const TX = (key: string) => tfn(key, loc);
  const seller = inv.seller_snapshot || {};
  const buyer = inv.customer || inv.customer_snapshot || {};
  const pdf = await PDFDocument.create();
  pdf.setTitle(san(inv.invoice_no || TX("email.invoice_pdf.doc_draft")));
  pdf.setCreator("booking");
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const page = pdf.addPage([595.28, 841.89]);
  const ink = rgb(0.12, 0.16, 0.12);
  let y = 800;
  const line = (text: string, size = 10, f = font) => { page.drawText(san(text), { x: 48, y, size, font: f, color: ink }); y -= size + 6; };
  const title = inv.status === "draft" ? TX("email.invoice_pdf.doc_draft") : inv.kind === "credit" ? TX("email.invoice_pdf.doc_credit") : TX("email.invoice_pdf.doc_invoice");
  line(title, 18, bold);
  line(`${TX("email.invoice_pdf.seller")}: ${seller.legal_name || seller.name || "—"}`, 11, bold);
  line(`${TX("email.invoice_pdf.business_id")}: ${seller.business_id || "—"}  ${TX("email.invoice_pdf.vat_id")}: ${seller.vat_id || "—"}`);
  line([seller.address, seller.zip, seller.city].filter(Boolean).join(" ") || "—");
  line(`${seller.email || ""} ${seller.phone || ""}`.trim());
  y -= 8;
  line(`${TX("email.invoice_pdf.buyer")}: ${buyer.company_name || buyer.name || "—"}`, 11, bold);
  line(`${TX("email.invoice_pdf.business_id")}: ${buyer.business_id || "—"}  ${TX("email.invoice_pdf.vat_id")}: ${buyer.vat_id || "—"}`);
  line(buyer.address || [buyer.street, buyer.zip, buyer.city].filter(Boolean).join(" ") || "—");
  if (buyer.einvoice_address) line(`${buyer.einvoice_address} / ${buyer.einvoice_operator || ""}`);
  y -= 8;
  line(`${TX("email.invoice_pdf.number")}: ${inv.invoice_no || "—"}`);
  line(`${TX("email.invoice_pdf.date")}: ${inv.invoice_date || "—"}   ${TX("email.invoice_pdf.due")}: ${inv.due_date || "—"}`);
  line(`${TX("email.invoice_pdf.reference")}: ${inv.reference_no || "—"}`);
  line(`${TX("email.invoice_pdf.bank")}: ${seller.bank_name || "—"}`);
  line(`${TX("email.invoice_pdf.iban")}: ${seller.iban || "—"}   ${TX("email.invoice_pdf.bic")}: ${seller.bic || "—"}`);
  y -= 8;
  line(`${TX("email.invoice_pdf.desc")}    ${TX("email.invoice_pdf.qty")}    ${TX("email.invoice_pdf.unit_price")}    ${TX("email.invoice_pdf.vat")}    ${TX("email.invoice_pdf.gross")}`, 9, bold);
  for (const l of inv.lines || []) {
    line(`${l.description}  ${l.quantity} ${l.unit || ""}  ${money(l.unit_price_net, loc)}  ${l.vat_rate} %  ${money(l.line_gross, loc)}`, 9);
  }
  y -= 6;
  line(`${TX("email.invoice_pdf.vat_breakdown")}`, 11, bold);
  for (const g of inv.vat_breakdown || []) line(`${TX("email.invoice_pdf.vat")} ${g.rate} %   ${TX("email.invoice_pdf.net")} ${money(g.net, loc)}   ${TX("email.invoice_pdf.vat")} ${money(g.vat, loc)}   ${TX("email.invoice_pdf.gross")} ${money(g.gross, loc)}`, 9);
  line(`${TX("email.invoice_pdf.total")}: ${money(inv.total_gross || 0, loc)}`, 12, bold);
  if (inv.notes) line(String(inv.notes), 9);
  y -= 8;
  line(TX("email.invoice_pdf.terms"), 8);
  line(TX("email.invoice_pdf.privacy"), 8);
  return pdf.save();
}
