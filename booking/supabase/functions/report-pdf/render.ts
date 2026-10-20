// Kirjanpitoraportin PDF (pdf-lib). Tekstit: report-pdf/texts.ts ja tietokannan ui.admin.reports.*.
import { PDFDocument, StandardFonts, rgb, PDFFont } from "npm:pdf-lib@1.17.1";
import { makeT, type TFn } from "../_shared/site_texts.ts";
import { REPORT_PDF_TEXTS } from "./texts.ts";
export { REPORT_PDF_TEXTS };

const DEFAULT_T: TFn = makeT(REPORT_PDF_TEXTS);
export const san = (s: unknown): string => String(s ?? "").replace(/[^\u0020-\u007E\u00A0-\u00FF\u20AC\u2013\u2014\u2018\u2019\u201C\u201D\u2022\u2026]/g, "?");

function money(n: unknown, loc: string): string {
  const x = Number(n ?? 0);
  const v = Number.isFinite(x) ? x : 0;
  const s = (loc === "en" ? v.toFixed(2) : v.toFixed(2).replace(".", ",")) + " €";
  return s;
}
const rate = (n: unknown, loc: string) => (loc === "en" ? String(Number(n ?? 0)) : String(Number(n ?? 0)).replace(".", ",")) + " %";
const dfi = (d: string) => String(d || "").split("-").reverse().join(".");

export async function buildReportPdf(rep: any, kind: string, lang = "fi", tfn: TFn = DEFAULT_T): Promise<Uint8Array> {
  const loc = lang === "en" ? "en" : "fi";
  const TX = (key: string, vars?: Record<string, string | number | null | undefined>) => tfn(key, loc, vars);
  const eur = (n: unknown) => money(n, loc);
  const pdf = await PDFDocument.create();
  const title = kind === "transactions" ? TX("ui.admin.reports.pdf_transactions") : kind === "giftcards" ? TX("ui.admin.reports.pdf_giftcards") : TX("ui.admin.reports.pdf_summary");
  pdf.setTitle(san(title)); pdf.setProducer(san(TX("ui.admin.reports.pdf_heading"))); pdf.setCreator("booking");
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const wide = kind === "transactions" || kind === "giftcards";
  const PW = wide ? 841.89 : 595.28, PH = wide ? 595.28 : 841.89, M = 36;
  let page = pdf.addPage([PW, PH]);
  let y = PH - M;
  const black = rgb(0.1, 0.1, 0.1), grey = rgb(0.4, 0.4, 0.4);
  const need = (h: number) => { if (y - h < M) { page = pdf.addPage([PW, PH]); y = PH - M; } };
  const text = (t: string, x: number, size = 8, f: PDFFont = font, c = black) => page.drawText(san(t), { x, y, size, font: f, color: c });
  const right = (t: string, xr: number, size = 8, f: PDFFont = font) => page.drawText(san(t), { x: xr - f.widthOfTextAtSize(san(t), size), y, size, font: f, color: black });
  const rule = () => { page.drawLine({ start: { x: M, y: y - 3 }, end: { x: PW - M, y: y - 3 }, thickness: 0.4, color: rgb(0.7, 0.7, 0.7) }); };
  const table = (heading: string, head: string[], cols: number[], rows: string[][]) => {
    if (!rows.length && heading === "") return;
    need(36); text(heading, M, 11, bold); y -= 16;
    const draw = (cells: string[], f: PDFFont) => cells.forEach((c, i) => i === 0 ? text(c, M, 8, f) : right(c, M + cols[i], 8, f));
    draw(head, bold); rule(); y -= 13;
    for (const r of rows) { need(12); draw(r, font); y -= 12; }
    y -= 8;
  };
  const period = rep.period || {};
  const from = period.from ? dfi(period.from) : "";
  const to = period.to ? dfi(period.to) : from;
  text(TX("ui.admin.reports.pdf_heading") + " – " + title, M, 13, bold); y -= 16;
  if (from) { text(TX("ui.admin.reports.pdf_period", { from, to }) + " · " + TX("ui.admin.reports.basis"), M, 7, font, grey); y -= 18; }

  if (kind === "transactions") {
    const head = [TX("ui.admin.reports.col_voucher"), TX("ui.admin.reports.col_date"), TX("ui.admin.reports.col_customer"), TX("ui.admin.reports.col_product"), TX("ui.admin.reports.col_qty"), TX("ui.admin.reports.col_net"), TX("ui.admin.reports.col_vat_pct"), TX("ui.admin.reports.col_vat_eur"), TX("ui.admin.reports.col_gross"), TX("ui.admin.reports.col_method"), TX("ui.admin.reports.col_status"), TX("ui.admin.reports.col_kind")];
    const kindLabel = (k: string) => k === "refund" ? TX("ui.admin.reports.kind_refund") : k === "redemption" ? TX("ui.admin.reports.kind_redemption") : TX("ui.admin.reports.kind_sale");
    const rows = (rep.rows || []).map((r: any) => [String(r.voucher ?? ""), dfi(String(r.date ?? "")), String(r.customer ?? ""), String(r.product ?? ""), String(r.quantity ?? ""), eur(r.net), rate(r.vat_rate, loc), eur(r.vat), eur(r.gross), String(r.method_label || r.method || ""), r.status === "open" ? TX("ui.admin.reports.status_open") : TX("ui.admin.reports.status_paid"), kindLabel(String(r.kind ?? ""))]);
    table(title, head, [0, 78, 130, 230, 390, 430, 490, 540, 590, 650, 720, 770], rows);
    need(20); text(TX("ui.admin.reports.open_note"), M, 7, font, grey);
    return await pdf.save();
  }
  if (kind === "giftcards") {
    const head = [TX("ui.admin.reports.gc_col_code"), TX("ui.admin.reports.gc_col_buyer"), TX("ui.admin.reports.gc_col_package"), TX("ui.admin.reports.gc_col_initial"), TX("ui.admin.reports.gc_col_balance"), TX("ui.admin.reports.col_net"), TX("ui.admin.reports.col_vat_pct"), TX("ui.admin.reports.col_vat_eur"), TX("ui.admin.reports.col_gross"), TX("ui.admin.reports.gc_col_sold"), TX("ui.admin.reports.gc_col_valid"), TX("ui.admin.reports.gc_col_status")];
    const line = (x: any) => [String(x.code_masked ?? ""), String(x.buyer ?? ""), String(x.package ?? ""), eur(x.initial), eur(x.balance), eur(x.net), rate(x.vat_rate, loc), eur(x.vat), eur(x.gross), dfi(String(x.sold_on ?? "")), x.valid_to ? dfi(String(x.valid_to)) : "", String(x.status ?? "")];
    const own = rep.own || {}, johku = rep.johku || {};
    const cols = [0, 78, 160, 280, 350, 410, 470, 520, 570, 640, 700, 760];
    table(TX("ui.admin.reports.gc_own"), head, cols, (own.rows || []).map(line));
    need(20); text(TX("ui.admin.reports.gc_paid_note"), M, 7, font, grey); y -= 12;
    if (Number(own.complimentary?.count) > 0) { need(20); text(TX("ui.admin.reports.gc_complimentary"), M, 7, font, grey); y -= 14; }
    table(TX("ui.admin.reports.gc_johku"), head, cols, (johku.rows || []).map(line));
    need(24); text(TX("ui.admin.reports.gc_note"), M, 7, font, grey);
    return await pdf.save();
  }

  const t = rep.totals ?? {};
  const daily = kind === "daily";
  const summary: string[][] = [
    [TX("ui.admin.reports.sales_count"), String(t.receipts ?? 0)],
    [TX("ui.admin.reports.refund_count"), String(t.refund_receipts ?? 0)],
    [TX("ui.admin.reports.pdf_sales"), eur(t.gross)],
    [TX("ui.admin.reports.pdf_refunds"), eur(t.refunds_gross)],
    [TX("ui.admin.reports.pdf_after"), eur(t.net_after_refunds ?? t.gross_after_refunds)],
    [TX("ui.admin.reports.pdf_of_which_vat"), eur(t.vat_after_refunds)],
    [TX("ui.admin.reports.pdf_ex_vat"), eur(t.net_ex_vat_after_refunds)],
  ];
  if (Math.abs(Number(t.rounding ?? 0)) >= 0.005) summary.push([TX("ui.admin.reports.cash_rounding"), eur(t.rounding)]);
  table(title, ["", TX("ui.admin.reports.col_gross")], [0, 515], summary);
  const prodHead = [TX("ui.admin.reports.col_product"), TX("ui.admin.reports.col_count"), TX("ui.admin.reports.col_net"), TX("ui.admin.reports.col_gross"), TX("ui.admin.reports.col_vat_eur"), TX("ui.admin.reports.col_vat_pct")];
  const prodCols = [0, 210, 270, 350, 430, 515];
  const lineOf = (p: any) => [String(p.product ?? ""), String(p.quantity ?? ""), eur(p.net), eur(p.gross), eur(p.vat), rate(p.rate, loc)];
  table(TX("ui.admin.reports.by_product"), prodHead, prodCols, (rep.by_product || []).map(lineOf));
  table(TX("ui.admin.reports.refunds_by_product"), prodHead, prodCols, (rep.refunds_by_product || []).map(lineOf));
  if (!(rep.refunds_by_product || []).length) { need(16); text(TX("ui.admin.reports.no_refunds"), M, 7, font, grey); y -= 14; }
  const vatRows = Array.isArray(rep.vat_summary) ? rep.vat_summary : (rep.by_vat || []);
  table(TX("ui.admin.reports.vat_breakdown"), [TX("ui.admin.reports.col_vat_pct"), TX("ui.admin.reports.col_net"), TX("ui.admin.reports.col_gross"), TX("ui.admin.reports.col_vat_eur")], [0, 180, 300, 420], vatRows.map((v: any) => [rate(v.rate, loc), eur(v.net), eur(v.gross), eur(v.vat)]));
  need(28); text(TX("ui.admin.reports.vat_breakdown_note"), M, 7, font, grey); y -= 16;
  const gcp = rep.gift_card_period || {};
  const sold = gcp.sold || {};
  const comp = gcp.complimentary || {};
  const pre = rep.prepaid_redemptions || {};
  need(20); text(TX("ui.admin.reports.gc_summary_title"), M, 12, bold); y -= 16;
  table(TX("ui.admin.reports.gc_sold"), prodHead, prodCols, (sold.lines || []).map(lineOf));
  need(28); text(TX("ui.admin.reports.gc_sold_note"), M, 7, font, grey); y -= 16;
  table(TX("ui.admin.reports.gc_redeemed"), prodHead, prodCols, (pre.lines || []).map(lineOf));
  need(28); text(TX("ui.admin.reports.prepaid_note"), M, 7, font, grey); y -= 16;
  table(TX("ui.admin.reports.gc_complimentary_title"), [TX("ui.admin.reports.col_product"), TX("ui.admin.reports.col_count"), TX("ui.admin.reports.col_gross")], [0, 250, 515], [
    [TX("ui.admin.reports.gc_comp_issued"), String(comp.issued_count ?? 0), eur(comp.issued_gross)],
    [TX("ui.admin.reports.gc_comp_redeemed"), String(comp.redeemed_count ?? 0), eur(comp.redeemed_gross)],
  ]);
  need(28); text(TX("ui.admin.reports.gc_comp_note"), M, 7, font, grey); y -= 16;
  if (!daily) table(TX("ui.admin.reports.payments"), [TX("ui.admin.reports.col_method"), TX("ui.admin.reports.col_gross")], [0, 515], (rep.by_method || []).map((m: any) => [String(m.label ?? m.method ?? ""), eur(Number(m.gross ?? 0) + Number(m.refunds ?? 0))]));
  const rec = rep.reconciliation;
  if (rec) {
    const rows = [
      [TX("ui.admin.reports.reconcile_sales"), eur(rec.sales_gross)],
      [TX("ui.admin.reports.reconcile_refunds"), eur(rec.refunds_gross)],
      [TX("ui.admin.reports.reconcile_products"), eur(rec.product_gross)],
    ];
    if (!daily) {
      rows.push([TX("ui.admin.reports.reconcile_payments"), eur(rec.payments_gross)]);
      rows.push([TX("ui.admin.reports.reconcile_diff"), eur(rec.difference)]);
    }
    if (Math.abs(Number(rec.vat_rounding ?? 0)) >= 0.005 || rec.rounding_code) rows.push([TX("ui.admin.reports.rounding_row"), eur(rec.vat_rounding)]);
    if (Math.abs(Number(rec.cash_rounding ?? 0)) >= 0.005) rows.push([TX("ui.admin.reports.cash_rounding"), eur(rec.cash_rounding)]);
    table(TX("ui.admin.reports.reconcile"), ["", TX("ui.admin.reports.col_gross")], [0, 515], rows);
    if (rec.rounding_code) { need(28); text(TX("ui.admin.reports.vat_rounding_note"), M, 7, font, grey); y -= 16; }
  }
  if (rep.by_day) table(TX("ui.admin.reports.day"), [TX("ui.admin.reports.col_date"), TX("ui.admin.reports.col_gross")], [0, 515], rep.by_day.map((d: any) => [dfi(d.date), eur(d.gross)]));
  const op = rep.open ?? {};
  if (Number(op.orders) > 0) { need(24); text(`${TX("ui.admin.reports.status_open")}: ${op.orders} · ${eur(op.unpaid)}`, M, 8, font, grey); y -= 12; text(TX("ui.admin.reports.open_note"), M, 7, font, grey); }
  return await pdf.save();
}
