// Kuitti-PDF:n piirto (pdf-lib). Erotettu index.ts:stä testattavaksi (index.ts käynnistää palvelimen tuonnissa).
// Logo haetaan seller.logo_url:sta; jos hakeminen epäonnistuu tai osoite puuttuu, PDF tehdään ilman logoa.
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";
import { makeT, type TFn } from "../_shared/site_texts.ts";
import { fetchPdfLogo, pdfSan, wrapPdfText } from "../_shared/pdf-layout.ts";
import { RECEIPT_PDF_TEXTS } from "./texts.ts";
export { RECEIPT_PDF_TEXTS };
const DEFAULT_T: TFn = makeT(RECEIPT_PDF_TEXTS);

// pdf-lib StandardFonts = WinAnsi: poistetaan merkit joita ei voi koodata
export const san = pdfSan;
const money = (n: number, loc: string) => (loc === "en" ? round2(n).toFixed(2) : round2(n).toFixed(2).replace(".", ",")) + " €";
/** Puolikas pois nollasta, kuten PostgreSQL numeric round. */
export function round2(n: number): number {
  const x = Number(n);
  if (!Number.isFinite(x)) return 0;
  const s = x < 0 ? -1 : 1;
  return s * Math.round((Math.abs(x) + Number.EPSILON) * 100) / 100;
}
/** line_net on snapshotissa; vanha kuitti ilman sitä johdetaan brutto × kanta / (100 + kanta). */
export function lineAmounts(l: { line_gross?: unknown; line_net?: unknown; vat_rate?: unknown }): { net: number; vat: number; gross: number; rate: number } {
  const gross = Number(l.line_gross ?? 0);
  const rate = Number(l.vat_rate ?? 0);
  const g = Number.isFinite(gross) ? gross : 0;
  const rt = Number.isFinite(rate) ? rate : 0;
  let net: number;
  if (l.line_net != null && l.line_net !== "") net = Number(l.line_net);
  else {
    const div = 100 + rt;
    const vat = div === 0 ? 0 : round2(g * rt / div);
    net = round2(g - vat);
  }
  if (!Number.isFinite(net)) net = 0;
  return { net: round2(net), vat: round2(g - net), gross: round2(g), rate: rt };
}
const rate = (n: number, loc: string) => (loc === "en" ? String(n) : String(n).replace(".", ",")) + " %";
const fmtLocal = (iso: string) => new Intl.DateTimeFormat("fi-FI", { timeZone: "Europe/Helsinki", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(iso)).replace(",", "");

export async function buildReceiptPdf(s: any, tfn: TFn = DEFAULT_T): Promise<Uint8Array> {
  const loc = s.locale === "en" ? "en" : "fi";
  const en = loc === "en";
  /** Asiakasnäkyvä teksti (DB tai repon oletus); piirtofunktiot siivoavat san():lla */
  const TX = (key: string, vars?: Record<string, string | number | null | undefined>) => tfn(key, loc, vars);
  const pdf = await PDFDocument.create();
  pdf.setTitle(san(`${s.receipt_no}`)); pdf.setProducer(san(TX("email.receipt_pdf.producer"))); pdf.setCreator("booking");
  const font = await pdf.embedFont(StandardFonts.Helvetica); const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  let page = pdf.addPage([595.28, 841.89]);
  const M = 48; const W = 595.28 - 2 * M; let y = 841.89 - M;
  const black = rgb(0.1, 0.1, 0.1); const grey = rgb(0.4, 0.4, 0.4);
  const text = (p: PDFPage, t: string, x: number, yy: number, size = 10, f: PDFFont = font, color = black) => p.drawText(san(t), { x, y: yy, size, font: f, color });
  const right = (p: PDFPage, t: string, xr: number, yy: number, size = 10, f: PDFFont = font) => { const w = f.widthOfTextAtSize(san(t), size); p.drawText(san(t), { x: xr - w, y: yy, size, font: f, color: black }); };
  const wrap = wrapPdfText;
  const need = (h: number) => { if (y - h < M) { page = pdf.addPage([595.28, 841.89]); y = 841.89 - M; } };

  // logo
  const logoBytes = await fetchPdfLogo(s.seller?.logo_url);
  let logoH = 0;
  if (logoBytes) {
    try {
      const isPng = logoBytes[0] === 0x89 && logoBytes[1] === 0x50;
      const img = isPng ? await pdf.embedPng(logoBytes) : await pdf.embedJpg(logoBytes);
      const sc = Math.min(140 / img.width, 60 / img.height); logoH = img.height * sc;
      page.drawImage(img, { x: 595.28 - M - img.width * sc, y: y - logoH, width: img.width * sc, height: logoH });
    } catch { /* ilman logoa */ }
  }
  const sel = s.seller ?? {};
  text(page, sel.name ?? "", M, y - 12, 14, bold); y -= 28;
  const sellerLines = [
    [sel.legal_name, TX("email.receipt_pdf.business_id", { id: sel.business_id ?? "" }), TX("email.receipt_pdf.vat_id", { id: sel.vat_id ?? "" })].filter(Boolean).join(", "),
    [sel.address, [sel.zip, sel.city].filter(Boolean).join(" ")].filter(Boolean).join(", "),
    [sel.email, sel.phone, sel.web].filter(Boolean).join("  ·  "),
  ];
  for (const l of sellerLines) { text(page, l, M, y, 9, font, grey); y -= 12; }
  y = Math.min(y, 841.89 - M - logoH - 8) - 14;

  const title = s.document === "refund_receipt" ? TX("email.receipt_pdf.title_refund") : s.invoice_required ? TX("email.receipt_pdf.title_invoice") : TX("email.receipt_pdf.title");
  text(page, `${title} ${s.receipt_no}`, M, y, 16, bold); y -= 22;
  const meta: [string, string][] = [
    [TX("email.receipt_pdf.date"), (() => { const dl = `${s.issued_local}`, i = dl.indexOf(" "); return i < 0 ? dl : TX("email.receipt_pdf.date_value", { date: dl.slice(0, i), time: dl.slice(i + 1) }); })()],
    [TX("email.receipt_pdf.order"), String(s.order_no)],
    [TX("email.receipt_pdf.payment_method"), s.payment?.method_label ?? s.payment?.method ?? ""],
  ];
  if (s.original) meta.push([TX("email.receipt_pdf.original"), `${s.original.receipt_no} (${s.original.issued_local ?? fmtLocal(s.original.issued_at)})`]);
  if (s.reason) meta.push([TX("email.receipt_pdf.reason"), s.reason]);
  for (const [k, v] of meta) { text(page, k + ":", M, y, 10, bold); text(page, v, M + 120, y, 10); y -= 14; }
  if (s.buyer) {
    y -= 4; text(page, TX("email.receipt_pdf.buyer"), M, y, 10, bold); y -= 14;
    const b = s.buyer;
    for (const l of [[b.company, b.name].filter(Boolean).join(", "), (b.business_id ? TX("email.receipt_pdf.business_id", { id: b.business_id }) : ""), [b.address, [b.zip, b.city].filter(Boolean).join(" ")].filter(Boolean).join(", "), b.reference ? TX("email.receipt_pdf.reference", { ref: b.reference }) : ""].filter(Boolean)) { text(page, l, M, y, 10); y -= 13; }
  }
  if (s.informational) { y -= 8; need(28); for (const l of wrap(TX("email.receipt_pdf.giftcard_info"), font, 9, W)) { text(page, l, M, y, 9, font, grey); y -= 12; } }
  y -= 10;
  // rivit
  const cx = { qty: M + 250, net: M + 330, pct: M + 385, vat: M + 445, gross: M + W };
  page.drawLine({ start: { x: M, y: y + 12 }, end: { x: M + W, y: y + 12 }, thickness: 0.8, color: black });
  text(page, TX("email.receipt_pdf.col_item"), M, y, 8, bold);
  right(page, TX("email.receipt_pdf.col_qty"), cx.qty, y, 8, bold);
  right(page, TX("email.receipt_pdf.col_net"), cx.net, y, 8, bold);
  right(page, TX("email.receipt_pdf.col_vat_pct"), cx.pct, y, 8, bold);
  right(page, TX("email.receipt_pdf.col_vat_eur"), cx.vat, y, 8, bold);
  right(page, TX("email.receipt_pdf.col_gross"), cx.gross, y, 8, bold);
  y -= 8; page.drawLine({ start: { x: M, y }, end: { x: M + W, y }, thickness: 0.4, color: grey }); y -= 14;
  for (const l of s.lines) {
    let d = l.description as string;
    if (l.starts_at) d += ` (${new Intl.DateTimeFormat("fi-FI", { timeZone: "Europe/Helsinki", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(l.starts_at)).replace(",", "")}–${new Intl.DateTimeFormat("fi-FI", { timeZone: "Europe/Helsinki", hour: "2-digit", minute: "2-digit" }).format(new Date(l.ends_at))})`;
    const amt = lineAmounts(l);
    const ls = wrap(d, font, 9, cx.qty - 36 - M); need(ls.length * 12 + 6);
    ls.forEach((t, i) => text(page, t, M, y - i * 12, 9));
    right(page, String(l.quantity), cx.qty, y, 8.5);
    right(page, money(amt.net, loc), cx.net, y, 8.5);
    right(page, rate(amt.rate, loc), cx.pct, y, 8.5);
    right(page, money(amt.vat, loc), cx.vat, y, 8.5);
    right(page, money(amt.gross, loc), cx.gross, y, 8.5);
    y -= ls.length * 12 + 4;
  }
  need(140); page.drawLine({ start: { x: M, y: y + 6 }, end: { x: M + W, y: y + 6 }, thickness: 0.4, color: grey }); y -= 10;
  // ALV-erittely
  text(page, TX("email.receipt_pdf.vat_breakdown"), M, y, 10, bold); y -= 14;
  text(page, TX("email.receipt_pdf.col_rate"), M, y, 9, bold); right(page, TX("email.receipt_pdf.col_net"), M + 230, y, 9, bold); right(page, TX("email.receipt_pdf.col_vat"), M + 320, y, 9, bold); right(page, TX("email.receipt_pdf.col_total"), M + 410, y, 9, bold); y -= 13;
  for (const v of s.vat) { text(page, rate(Number(v.rate), loc), M, y, 9.5); right(page, money(Number(v.net), loc), M + 230, y, 9.5); right(page, money(Number(v.vat), loc), M + 320, y, 9.5); right(page, money(Number(v.gross), loc), M + 410, y, 9.5); y -= 13; }
  y -= 8;
  const tot: [string, string, boolean][] = [
    [TX("email.receipt_pdf.total_gross"), money(Number(s.total_gross), loc), true],
    [TX("email.receipt_pdf.of_which_vat"), money(Number(s.total_vat), loc), false],
    [TX("email.receipt_pdf.col_net"), money(Number(s.total_net), loc), false],
  ];
  const rnd = Number(s.rounding ?? 0);
  if (rnd !== 0) tot.push([TX("email.receipt_pdf.rounding"), (rnd > 0 ? "+" : "") + money(rnd, loc), false]);
  tot.push([s.document === "refund_receipt" ? TX("email.receipt_pdf.refunded") : TX("email.receipt_pdf.paid"), money(Number(s.total_paid), loc), true]);
  for (const [k, v, b] of tot) { need(16); text(page, k, M + 250, y, 10, b ? bold : font); right(page, v, M + W, y, 10, b ? bold : font); y -= 15; }
  if (sel.footer) { y -= 14; need(20); for (const l of wrap(sel.footer, font, 9, W)) { text(page, l, M, y, 9, font, grey); y -= 12; } }
  return await pdf.save();
}

