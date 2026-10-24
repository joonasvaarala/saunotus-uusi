// Lasku-PDF (pdf-lib, WinAnsi). Myyjä, ostaja ja pankkitiedot tulevat laskun snapshotista.
// Pohja seuraa receipt-pdf:n rakennetta ja käyttää yhteisiä PDF-apuja.
import { PDFDocument, StandardFonts, type Color, type PDFFont, type PDFPage } from "npm:pdf-lib@1.17.1";
import qrcode from "npm:qrcode-generator@1.4.4";
import { CODE128_PATTERNS, buildEpcQrPayload, buildVirtualBarcode, code128CValues, isValidBic, isValidIban } from "../_shared/payment-codes.ts";
import { fetchPdfLogo, pdfSan, PDF_BRAND, wrapPdfText } from "../_shared/pdf-layout.ts";
import { makeT, type TFn } from "../_shared/site_texts.ts";
import { INVOICE_PDF_TEXTS } from "./texts.ts";
export { INVOICE_PDF_TEXTS };

export const san = pdfSan;
const money = (n: number, loc: string) => (loc === "en" ? Number(n).toFixed(2) : Number(n).toFixed(2).replace(".", ",")) + " EUR";
// Veroton á-hinta voi olla neljän desimaalin johdettu luku (verollinen peruste). Näytä 2–4 desimaalia, rivisumma pysyy kahdessa.
const unitPrice = (n: number, loc: string) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return money(0, loc);
  const sign = v < 0 ? "-" : "";
  let s = Math.abs(v).toFixed(4).replace(/0+$/, "").replace(/\.$/, "");
  const frac = s.includes(".") ? s.length - s.indexOf(".") - 1 : 0;
  if (frac < 2) s = Math.abs(v).toFixed(2);
  if (loc !== "en") s = s.replace(".", ",");
  return `${sign}${s} EUR`;
};

const dateText = (value: unknown): string => {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value ?? ""));
  return m ? `${m[3]}.${m[2]}.${m[1]}` : String(value ?? "");
};

const paymentDays = (from: unknown, to: unknown): number | null => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(from ?? "")) || !/^\d{4}-\d{2}-\d{2}$/.test(String(to ?? ""))) return null;
  const days = Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
  return Number.isFinite(days) && days >= 0 ? days : null;
};

const present = (value: unknown): string => String(value ?? "").trim();
const addressLines = (party: any): string[] => {
  const direct = present(party.address);
  if (direct && (!party.street || direct !== present(party.street))) return [direct];
  return [
    present(party.street || party.address),
    [party.zip || party.postal_code, party.city].map(present).filter(Boolean).join(" "),
    present(party.country && party.country !== "FI" ? party.country : ""),
  ].filter(Boolean);
};

function drawCode128(page: PDFPage, value: string, x: number, y: number, width: number, height: number, color: Color): boolean {
  const values = code128CValues(value);
  if (!values) return false;
  const patterns = values.map((v) => CODE128_PATTERNS[v]);
  const modules = patterns.reduce((sum, pattern) => sum + [...pattern].reduce((n, w) => n + Number(w), 0), 0);
  const quiet = 57; // noin 20 mm kummallakin puolella Finanssialan ohjeen mukaan
  const moduleWidth = (width - quiet * 2) / modules;
  if (moduleWidth <= 0) return false;
  let cursor = x + quiet;
  for (const pattern of patterns) {
    [...pattern].forEach((w, i) => {
      const barWidth = Number(w) * moduleWidth;
      if (i % 2 === 0) page.drawRectangle({ x: cursor, y, width: barWidth, height, color });
      cursor += barWidth;
    });
  }
  return true;
}

function drawQr(page: PDFPage, payload: string, x: number, y: number, size: number, color: Color): boolean {
  try {
    const qr = qrcode(0, "M");
    qr.addData(payload, "Byte");
    qr.make();
    const count = qr.getModuleCount();
    const quiet = 4;
    const module = size / (count + quiet * 2);
    page.drawRectangle({ x, y, width: size, height: size, color: PDF_BRAND.white });
    for (let row = 0; row < count; row++) {
      for (let col = 0; col < count; col++) {
        if (qr.isDark(row, col)) {
          page.drawRectangle({
            x: x + (col + quiet) * module,
            y: y + size - (row + quiet + 1) * module,
            width: module + 0.05,
            height: module + 0.05,
            color,
          });
        }
      }
    }
    return true;
  } catch {
    return false;
  }
}

export interface InvoicePdfAssets {
  /** Paikallista esikatselua ja deterministisiä testejä varten; tuotannossa logo haetaan seller.logo_url:sta. */
  logoBytes?: Uint8Array | null;
}

export async function buildInvoicePdf(inv: any, tfn: TFn = makeT(INVOICE_PDF_TEXTS), assets: InvoicePdfAssets = {}): Promise<Uint8Array> {
  const loc = inv.locale === "en" ? "en" : "fi";
  const TX = (key: string, vars?: Record<string, string | number | null | undefined>) => tfn(key, loc, vars);
  const seller = inv.seller_snapshot || {};
  const buyer = inv.customer || inv.customer_snapshot || {};
  const pdf = await PDFDocument.create();
  pdf.setTitle(san(inv.invoice_no || TX("email.invoice_pdf.doc_draft")));
  pdf.setProducer("Saunotus booking");
  pdf.setCreator("booking");
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const PAGE_W = 595.28; const PAGE_H = 841.89; const M = 43; const W = PAGE_W - 2 * M;
  let page = pdf.addPage([PAGE_W, PAGE_H]);
  let y = PAGE_H - M;
  const text = (value: unknown, x: number, yy: number, size = 9, f: PDFFont = font, color: Color = PDF_BRAND.text) =>
    page.drawText(san(value), { x, y: yy, size, font: f, color });
  const right = (value: unknown, xr: number, yy: number, size = 9, f: PDFFont = font, color: Color = PDF_BRAND.text) => {
    const clean = san(value);
    text(clean, xr - f.widthOfTextAtSize(clean, size), yy, size, f, color);
  };
  const rule = (x1: number, yy: number, x2: number, color: Color = PDF_BRAND.brown, thickness = 0.6) =>
    page.drawLine({ start: { x: x1, y: yy }, end: { x: x2, y: yy }, thickness, color });
  const title = inv.status === "draft" ? TX("email.invoice_pdf.doc_draft") : inv.kind === "credit" ? TX("email.invoice_pdf.doc_credit") : TX("email.invoice_pdf.doc_invoice");

  let logoBytes = assets.logoBytes;
  if (logoBytes === undefined) logoBytes = await fetchPdfLogo(seller.logo_url);
  let logo: null | Awaited<ReturnType<typeof pdf.embedPng>> = null;
  if (logoBytes) {
    try {
      logo = logoBytes[0] === 0x89 && logoBytes[1] === 0x50 ? await pdf.embedPng(logoBytes) : await pdf.embedJpg(logoBytes);
    } catch { /* lasku toimii ilman logoa */ }
  }

  // Brändätty ylätunniste: sama logo- ja yritysrakenne kuin kuittipohjassa.
  page.drawRectangle({ x: 0, y: 687, width: PAGE_W, height: PAGE_H - 687, color: PDF_BRAND.cream });
  page.drawRectangle({ x: 0, y: 833, width: PAGE_W, height: 9, color: PDF_BRAND.green });
  if (logo) {
    const scale = Math.min(49 / logo.width, 67 / logo.height);
    page.drawImage(logo, { x: M, y: 744, width: logo.width * scale, height: logo.height * scale });
  }
  const sellerX = logo ? 105 : M;
  text(seller.legal_name || seller.name, sellerX, 796, 12, bold, PDF_BRAND.green);
  const tradeName = present(seller.name);
  if (tradeName && tradeName !== present(seller.legal_name)) text(tradeName, sellerX, 780, 8.5, font, PDF_BRAND.brown);
  const sellerDetails = [
    [present(seller.business_id) && `${TX("email.invoice_pdf.business_id")}: ${present(seller.business_id)}`, present(seller.vat_id) && `${TX("email.invoice_pdf.vat_id")}: ${present(seller.vat_id)}`].filter(Boolean).join("  ·  "),
    [present(seller.address), [seller.zip, seller.city].map(present).filter(Boolean).join(" ")].filter(Boolean).join(", "),
    [present(seller.email), present(seller.phone)].filter(Boolean).join("  ·  "),
  ].filter(Boolean);
  sellerDetails.forEach((value, i) => text(value, sellerX, 761 - i * 13, 8.2, font, PDF_BRAND.muted));

  text(title, 343, 793, 26, bold, PDF_BRAND.green);
  rule(343, 782, PAGE_W - M, PDF_BRAND.brown, 1);
  const termDays = paymentDays(inv.invoice_date, inv.due_date);
  const meta: [string, string][] = [
    [TX("email.invoice_pdf.number"), present(inv.invoice_no)],
    [TX("email.invoice_pdf.date"), dateText(inv.invoice_date)],
    [TX("email.invoice_pdf.due"), dateText(inv.due_date)],
    [TX("email.invoice_pdf.reference"), present(inv.reference_no)],
  ];
  if (termDays != null) meta.push([TX("email.invoice_pdf.payment_term"), TX("email.invoice_pdf.payment_term_value", { days: termDays })]);
  meta.filter(([, value]) => value).forEach(([label, value], i) => {
    text(label.toUpperCase(), 343, 765 - i * 14, 6.8, bold, PDF_BRAND.brown);
    right(value, PAGE_W - M, 765 - i * 14, 8.7, i === 0 ? bold : font, PDF_BRAND.green);
  });

  // Ostaja
  y = 660;
  text(TX("email.invoice_pdf.buyer").toUpperCase(), M, y, 7.5, bold, PDF_BRAND.brown);
  y -= 17;
  text(buyer.company_name || buyer.name, M, y, 11.5, bold, PDF_BRAND.green);
  addressLines(buyer).forEach((value, i) => text(value, M, y - 15 - i * 12, 8.8));
  const buyerRight: [string, string][] = [
    [TX("email.invoice_pdf.business_id"), present(buyer.business_id)],
    [TX("email.invoice_pdf.vat_id"), present(buyer.vat_id)],
    [TX("email.invoice_pdf.einvoice"), [buyer.einvoice_address, buyer.einvoice_operator].map(present).filter(Boolean).join(" / ")],
  ];
  buyerRight.forEach(([label, value], i) => {
    if (!value) return;
    if (i === 2) {
      text(label.toUpperCase(), 325, y - 31, 6.6, bold, PDF_BRAND.brown);
      text(value, 325, y - 43, 8.2, font, PDF_BRAND.text);
    } else {
      text(label.toUpperCase(), 325, y - i * 15, 6.6, bold, PDF_BRAND.brown);
      text(value, 425, y - i * 15, 8.5, bold, PDF_BRAND.text);
    }
  });
  y = 575;

  const columns = { desc: M, qty: 314, unit: 405, vat: 463, gross: PAGE_W - M };
  const drawTableHeader = () => {
    page.drawRectangle({ x: M, y: y - 7, width: W, height: 24, color: PDF_BRAND.green });
    text(TX("email.invoice_pdf.desc"), columns.desc + 8, y, 7.4, bold, PDF_BRAND.white);
    right(TX("email.invoice_pdf.qty"), columns.qty, y, 7.4, bold, PDF_BRAND.white);
    right(TX("email.invoice_pdf.unit_price"), columns.unit, y, 7.1, bold, PDF_BRAND.white);
    right(`${TX("email.invoice_pdf.vat")} %`, columns.vat, y, 7.4, bold, PDF_BRAND.white);
    right(TX("email.invoice_pdf.gross"), columns.gross - 8, y, 7.4, bold, PDF_BRAND.white);
    y -= 22;
  };
  const continuationPage = () => {
    page = pdf.addPage([PAGE_W, PAGE_H]);
    page.drawRectangle({ x: 0, y: 814, width: PAGE_W, height: 28, color: PDF_BRAND.green });
    text(seller.legal_name || seller.name, M, 824, 9, bold, PDF_BRAND.white);
    right(`${title} ${present(inv.invoice_no)}`, PAGE_W - M, 824, 9, bold, PDF_BRAND.white);
    y = 780;
    drawTableHeader();
  };

  drawTableHeader();
  for (const l of inv.lines || []) {
    const descriptions = wrapPdfText(l.description, font, 8.6, columns.qty - columns.desc - 30);
    const rowHeight = Math.max(23, descriptions.length * 11 + 9);
    if (y - rowHeight < 62) continuationPage();
    descriptions.forEach((value, i) => text(value, columns.desc + 8, y - i * 11, 8.6));
    right([present(l.quantity), present(l.unit)].filter(Boolean).join(" "), columns.qty, y, 8.3);
    right(unitPrice(l.unit_price_net, loc), columns.unit, y, 8.1);
    right(`${present(l.vat_rate).replace(".", loc === "en" ? "." : ",")} %`, columns.vat, y, 8.3);
    right(money(l.line_gross, loc), columns.gross - 8, y, 8.3, bold, PDF_BRAND.green);
    y -= rowHeight;
    rule(M, y + 6, M + W, PDF_BRAND.cream, 0.8);
  }

  if (y < 345) {
    page = pdf.addPage([PAGE_W, PAGE_H]);
    page.drawRectangle({ x: 0, y: 814, width: PAGE_W, height: 28, color: PDF_BRAND.green });
    text(seller.legal_name || seller.name, M, 824, 9, bold, PDF_BRAND.white);
    right(`${title} ${present(inv.invoice_no)}`, PAGE_W - M, 824, 9, bold, PDF_BRAND.white);
    y = 780;
  } else y -= 8;

  // ALV-erittely käyttää valmiiksi laskettua snapshotia; laskenta tai pyöristys ei muutu.
  text(TX("email.invoice_pdf.vat_breakdown").toUpperCase(), M, y, 7.5, bold, PDF_BRAND.brown);
  y -= 17;
  text(`${TX("email.invoice_pdf.vat")} %`, M, y, 7.3, bold, PDF_BRAND.muted);
  right(TX("email.invoice_pdf.net"), 164, y, 7.3, bold, PDF_BRAND.muted);
  right(TX("email.invoice_pdf.vat"), 241, y, 7.3, bold, PDF_BRAND.muted);
  right(TX("email.invoice_pdf.gross"), 322, y, 7.3, bold, PDF_BRAND.muted);
  y -= 13;
  for (const group of inv.vat_breakdown || []) {
    text(`${present(group.rate).replace(".", loc === "en" ? "." : ",")} %`, M, y, 8.3);
    right(money(group.net, loc), 164, y, 8.3);
    right(money(group.vat, loc), 241, y, 8.3);
    right(money(group.gross, loc), 322, y, 8.3);
    y -= 13;
  }

  const totalTop = y + 35;
  page.drawRectangle({ x: 347, y: totalTop - 50, width: PAGE_W - M - 347, height: 50, color: PDF_BRAND.green });
  text(TX("email.invoice_pdf.payable").toUpperCase(), 359, totalTop - 18, 7.3, bold, PDF_BRAND.cream);
  right(money(inv.total_gross || 0, loc), PAGE_W - M - 12, totalTop - 38, 16, bold, PDF_BRAND.white);
  if (present(inv.notes)) {
    const notes = wrapPdfText(inv.notes, font, 8, W);
    y -= 9;
    notes.forEach((value) => { text(value, M, y, 8, font, PDF_BRAND.muted); y -= 11; });
  }
  y = Math.min(y - 20, totalTop - 68);

  if (y < 255) {
    page = pdf.addPage([PAGE_W, PAGE_H]);
    page.drawRectangle({ x: 0, y: 814, width: PAGE_W, height: 28, color: PDF_BRAND.green });
    text(seller.legal_name || seller.name, M, 824, 9, bold, PDF_BRAND.white);
    right(`${title} ${present(inv.invoice_no)}`, PAGE_W - M, 824, 9, bold, PDF_BRAND.white);
    y = 775;
  }

  // Maksuosa: tyhjiä pankkitietoja ei korvata viivoilla. Koodit vain kelvollisellä IBANilla ja BICillä.
  const paymentTop = y;
  const paymentFields: [string, string][] = [
    [TX("email.invoice_pdf.bank"), present(seller.bank_name)],
    [TX("email.invoice_pdf.iban"), present(seller.iban)],
    [TX("email.invoice_pdf.bic"), present(seller.bic)],
    [TX("email.invoice_pdf.reference"), present(inv.reference_no)],
    [TX("email.invoice_pdf.due"), dateText(inv.due_date)],
  ];
  page.drawRectangle({ x: M, y: paymentTop - 110, width: W, height: 110, color: PDF_BRAND.cream });
  text(TX("email.invoice_pdf.payment_details").toUpperCase(), M + 12, paymentTop - 19, 7.5, bold, PDF_BRAND.brown);
  paymentFields.filter(([, value]) => value).forEach(([label, value], i) => {
    text(label.toUpperCase(), M + 12, paymentTop - 38 - i * 13, 6.5, bold, PDF_BRAND.brown);
    text(value, M + 97, paymentTop - 38 - i * 13, 8.4, label === "IBAN" ? bold : font, PDF_BRAND.green);
  });
  text(TX("email.invoice_pdf.payable").toUpperCase(), 351, paymentTop - 20, 6.8, bold, PDF_BRAND.brown);
  right(money(inv.total_gross || 0, loc), PAGE_W - M - 12, paymentTop - 39, 14, bold, PDF_BRAND.green);

  const hasAccount = isValidIban(seller.iban) && isValidBic(seller.bic);
  const barcode = hasAccount ? buildVirtualBarcode({
    iban: seller.iban,
    amount: inv.total_gross,
    reference: inv.reference_no,
    dueDate: inv.due_date,
  }) : null;
  const epc = hasAccount ? buildEpcQrPayload({
    bic: seller.bic,
    beneficiary: seller.legal_name || seller.name,
    iban: seller.iban,
    amount: inv.total_gross,
    reference: inv.reference_no,
    fallbackRemittance: inv.invoice_no,
  }) : null;
  if (epc && drawQr(page, epc, PAGE_W - M - 58, paymentTop - 103, 52, PDF_BRAND.green)) {
    right(TX("email.invoice_pdf.scan_to_pay"), PAGE_W - M - 4, paymentTop - 49, 5.8, bold, PDF_BRAND.brown);
  }

  let footerY = paymentTop - 127;
  if (barcode) {
    text(`${TX("email.invoice_pdf.quick_payment").toUpperCase()} · ${TX("email.invoice_pdf.virtual_barcode")} v${barcode.version}`, M, footerY, 6.7, bold, PDF_BRAND.brown);
    footerY -= 41;
    drawCode128(page, barcode.value, M, footerY, W, 31, PDF_BRAND.ink);
    footerY -= 12;
    const virtualSize = Math.min(7.2, (W - 8) / bold.widthOfTextAtSize(barcode.value, 1));
    text(barcode.value, M + (W - bold.widthOfTextAtSize(barcode.value, virtualSize)) / 2, footerY, virtualSize, bold, PDF_BRAND.green);
    footerY -= 18;
  }
  rule(M, footerY + 7, M + W, PDF_BRAND.brown, 0.5);
  text(TX("email.invoice_pdf.late_interest"), M, footerY - 5, 7.2, font, PDF_BRAND.muted);
  text(TX("email.invoice_pdf.privacy"), M, footerY - 16, 7.2, font, PDF_BRAND.muted);
  right(present(seller.web), PAGE_W - M, footerY - 16, 7.2, bold, PDF_BRAND.brown);

  return pdf.save();
}
