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
  const title = kind === "transactions" ? TX("ui.admin.reports.pdf_transactions") : kind === "giftcards" ? TX("ui.admin.reports.pdf_giftcards") : kind === "fees" ? TX("ui.admin.reports.fee_title") : kind === "methods" ? TX("ui.admin.reports.pdf_methods") : kind === "accrual" ? TX("ui.admin.reports.pdf_service") : kind === "invoices" ? TX("ui.admin.reports.pdf_invoices") : TX("ui.admin.reports.r_sales");
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
  const basisKey = kind === "accrual" ? "ui.admin.reports.basis_service" : kind === "giftcards" ? "ui.admin.reports.basis_giftcards" : kind === "invoices" ? "ui.admin.reports.basis_invoices" : "ui.admin.reports.basis_document";
  if (from) { text(TX("ui.admin.reports.pdf_period", { from, to }) + (kind === "fees" ? "" : " · " + TX(basisKey)), M, 7, font, grey); y -= 18; }

  if (kind === "fees") {
    const basis = (b: string) => b === "actual" ? TX("ui.admin.reports.fee_basis_actual") : b === "estimated" ? TX("ui.admin.reports.fee_basis_estimated") : TX("ui.admin.reports.fee_basis_missing");
    const head = [TX("ui.admin.reports.fee_col_provider"), TX("ui.admin.reports.fee_col_method"), TX("ui.admin.reports.fee_col_basis"), TX("ui.admin.reports.fee_col_count"), TX("ui.admin.reports.fee_col_gross"), TX("ui.admin.reports.fee_col_fee"), TX("ui.admin.reports.fee_col_net")];
    const cols = [0, 120, 230, 300, 350, 420, 500];
    const line = (r: any) => [String(r.provider_label || r.provider || ""), String(r.method_label || r.method || ""), basis(String(r.basis || "")), String(r.count ?? ""), eur(r.gross), r.fee == null ? "–" : eur(r.fee), r.net == null ? "–" : eur(r.net)];
    const rows = Array.isArray(rep.rows) ? rep.rows : [];
    table(TX("ui.admin.reports.fee_sales"), head, cols, rows.filter((r: any) => r.direction !== "refund").map(line));
    table(TX("ui.admin.reports.fee_refunds"), head, cols, rows.filter((r: any) => r.direction === "refund").map(line));
    const tot = rep.totals || {};
    if (Number(tot.missing) > 0) { need(28); text(TX("ui.admin.reports.fee_missing_note"), M, 7, font, grey); y -= 14; }
    else if (tot.settlement != null) { need(16); text(`${TX("ui.admin.reports.fee_settlement")}: ${eur(tot.settlement)}`, M, 10, bold); y -= 14; }
    need(28); text(TX("ui.admin.reports.fee_net_note"), M, 7, font, grey);
    return await pdf.save();
  }
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
    const own = rep.own || {};
    const cols = [0, 78, 160, 280, 350, 410, 470, 520, 570, 640, 700, 760];
    const roll = (rep.balance && rep.balance.native_paid) || (rep.gift_card_period && rep.gift_card_period.open && rep.gift_card_period.open.native_paid) || {};
    const johku = (rep.statistics && rep.statistics.johku && rep.statistics.johku.balance) || {};
    const blank = (b: any) => ["opening", "sold", "redeemed", "other", "expired", "closing"].every((k) => Math.abs(Number(b?.[k] || 0)) < 0.005);
    const balHead = [TX("ui.admin.reports.col_product"), TX("ui.admin.reports.gc_opening"), TX("ui.admin.reports.gc_sold_period"), TX("ui.admin.reports.gc_redeemed_period"), TX("ui.admin.reports.gc_expired"), TX("ui.admin.reports.gc_closing")];
    const balCols = [0, 160, 240, 320, 400, 515];
    const srcKey: Record<string, string> = { native_paid: "ui.admin.reports.gc_bucket_own", native_complimentary: "ui.admin.reports.gc_bucket_free", johku: "ui.admin.reports.gc_bucket_johku", elamyslahjat: "ui.admin.reports.gc_src_elamyslahjat", kokemuskauppa: "ui.admin.reports.gc_src_kokemuskauppa", offerilla: "ui.admin.reports.gc_src_offerilla", kiitoskauppa: "ui.admin.reports.gc_src_kiitoskauppa", partner_other: "ui.admin.reports.gc_src_partner_other", partner_voucher: "ui.admin.reports.gc_src_partner_legacy" };
    const pair = (on: boolean, n: unknown, moneyN: unknown) => on ? `${n ?? 0} · ${eur(moneyN)}` : "–";
    if (rep.activity && Array.isArray(rep.activity.rows)) {
      const rows = rep.activity.rows as any[];
      const ownZero = rows.find((x) => x.source === "native_paid");
      const johkuRow = rows.find((x) => x.source === "johku");
      const zeroOwn = !ownZero || ["opening", "sold_gross", "redeemed_gross", "expired_gross", "closing"].every((k) => Math.abs(Number(ownZero[k] || 0)) < 0.005);
      const johkuMove = johkuRow && ["opening", "sold_gross", "redeemed_gross", "expired_gross", "closing"].some((k) => Math.abs(Number(johkuRow[k] || 0)) >= 0.005);
      if (zeroOwn && johkuMove) { need(28); text(TX("ui.admin.reports.gc_only_johku"), M, 7, font, grey); y -= 14; }
      const otherCell = (x: any) => x.balance_applicable === false ? "–" : Math.abs(Number(x.other_gross || 0)) < 0.005 ? "" : eur(x.other_gross);
      const actHead = [TX("ui.admin.reports.col_product"), TX("ui.admin.reports.gc_col_mark"), TX("ui.admin.reports.gc_sold_period"), TX("ui.admin.reports.gc_redeemed_period"), TX("ui.admin.reports.gc_expired"), TX("ui.admin.reports.gc_other"), TX("ui.admin.reports.gc_closing")];
      const actCols = [0, 110, 190, 280, 370, 470, 560];
      const actRows = rows.map((x) => [TX(srcKey[x.source] || "ui.admin.reports.gc_src_partner_other"), x.accounting ? TX("ui.admin.reports.gc_accounting") : TX("ui.admin.reports.gc_info_only"), pair(x.sold_applicable !== false, x.sold_count, x.sold_gross), `${x.redeemed_count ?? 0} · ${eur(x.redeemed_gross)}`, pair(x.balance_applicable !== false, x.expired_count, x.expired_gross), otherCell(x), x.balance_applicable === false ? "–" : eur(x.closing)]);
      const tot = rep.activity.totals || {};
      actRows.push([TX("ui.admin.reports.gc_activity_total"), "–", pair(true, tot.sold_count, tot.sold_gross), `${tot.redeemed_count ?? 0} · ${eur(tot.redeemed_gross)}`, pair(true, tot.expired_count, tot.expired_gross), otherCell({ balance_applicable: true, other_gross: tot.other_gross }), eur(tot.closing)]);
      table(TX("ui.admin.reports.gc_activity_title"), actHead, actCols, actRows);
      need(28); text(TX("ui.admin.reports.gc_activity_total_note"), M, 7, font, grey); y -= 14;
      if (rows.some((x) => Math.abs(Number(x.other_gross || 0)) >= 0.005)) { need(36); text(TX("ui.admin.reports.gc_other_note"), M, 7, font, grey); y -= 14; }
      if (johkuRow) { need(28); text(TX("ui.admin.reports.gc_johku_liability"), M, 7, font, grey); y -= 14; }
      if (rows.some((x) => x.group === "partner")) { need(28); text(TX("ui.admin.reports.gc_partner_note"), M, 7, font, grey); y -= 14; }
      for (const x of rows) {
        const events = Array.isArray(x.events) ? x.events : [];
        if (!events.length) continue;
        const reasonKey: Record<string, string> = { johku_sync: "ui.admin.reports.gc_reason_johku_sync", johku_adjust: "ui.admin.reports.gc_reason_johku_adjust", refund: "ui.admin.reports.gc_reason_refund", adjust: "ui.admin.reports.gc_reason_adjust", cancel_refund: "ui.admin.reports.gc_reason_cancel_refund", single_order_forfeit: "ui.admin.reports.gc_reason_forfeit" };
        const kindOf = (e: any) => e.kind === "other" ? TX(reasonKey[String(e.reason || "")] || "ui.admin.reports.gc_reason_other") : e.kind === "sale" ? TX("ui.admin.reports.gc_kind_sale") : e.kind === "opening" ? TX("ui.admin.reports.gc_kind_opening") : e.kind === "expiry" ? TX("ui.admin.reports.gc_kind_expiry") : TX("ui.admin.reports.kind_redemption");
        table(TX(srcKey[x.source] || "ui.admin.reports.gc_src_partner_other"), [TX("ui.admin.reports.col_kind"), TX("ui.admin.reports.col_date"), TX("ui.admin.reports.gc_col_order"), TX("ui.admin.reports.col_gross"), TX("ui.admin.reports.gc_col_code")], [0, 140, 230, 320, 420], events.map((e: any) => [`${kindOf(e)}${e.value_card ? " · " + TX("ui.admin.reports.gc_value_card") : ""}`, dfi(String(e.date || "")), e.order_no == null ? "–" : String(e.order_no), eur(e.amount), String(e.code_masked || "")]));
      }
    } else {
      table(TX("ui.admin.reports.gc_open_title"), balHead, balCols, [
        [TX("ui.admin.reports.gc_bucket_own"), eur(roll.opening), eur(roll.sold), eur(roll.redeemed), eur(roll.expired), eur(roll.closing)],
      ]);
      if (blank(roll) && !blank(johku)) { need(28); text(TX("ui.admin.reports.gc_only_johku"), M, 7, font, grey); y -= 14; }
      table(TX("ui.admin.reports.gc_johku"), balHead, balCols, [
        [TX("ui.admin.reports.gc_bucket_johku"), eur(johku.opening), eur(johku.sold), eur(johku.redeemed), eur(johku.expired), eur(johku.closing)],
      ]);
      need(28); text(TX("ui.admin.reports.gc_johku_liability"), M, 7, font, grey); y -= 14;
    }
    table(TX("ui.admin.reports.gc_own"), head, cols, (own.rows || []).map(line));
    need(20); text(TX("ui.admin.reports.gc_multi_note"), M, 7, font, grey);
    return await pdf.save();
  }
  if (kind === "invoices") {
    const head = [TX("ui.admin.reports.inv_no"), TX("ui.admin.reports.col_customer"), TX("ui.admin.reports.col_date"), TX("ui.admin.reports.inv_due"), TX("ui.admin.reports.col_net"), TX("ui.admin.reports.col_vat_eur"), TX("ui.admin.reports.col_gross"), TX("ui.admin.reports.col_status")];
    const st = (s: string) => TX(`ui.admin.reports.inv_status_${s}`);
    const line = (x: any) => [String(x.invoice_no ?? ""), String(x.customer ?? ""), dfi(String(x.invoice_date ?? "")), dfi(String(x.due_date ?? "")), eur(x.net), eur(x.vat), eur(x.gross), st(String(x.status ?? "open"))];
    table(TX("ui.admin.reports.r_invoices"), head, [0, 70, 180, 240, 300, 360, 430, 500], (rep.invoices || []).map(line));
    table(TX("ui.admin.reports.inv_credits"), head, [0, 70, 180, 240, 300, 360, 430, 500], (rep.credits || []).map(line));
    return await pdf.save();
  }
  if (kind === "accrual") {
    const t = rep.totals ?? {};
    const prodHead = [TX("ui.admin.reports.col_product"), TX("ui.admin.reports.col_count"), TX("ui.admin.reports.col_net"), TX("ui.admin.reports.col_gross"), TX("ui.admin.reports.col_vat_eur"), TX("ui.admin.reports.col_vat_pct")];
    const prodCols = [0, 210, 270, 350, 430, 515];
    const lineOf = (p: any) => [String(p.product ?? ""), String(p.quantity ?? ""), eur(p.net), eur(p.gross), eur(p.vat), rate(p.rate, loc)];
    table(TX("ui.admin.reports.sales_list"), prodHead, prodCols, (rep.sales_by_product || []).map(lineOf));
    table(TX("ui.admin.reports.refunds_by_product"), prodHead, prodCols, (rep.refunds_by_product || []).map(lineOf));
    const adv = rep.advances || {};
    table(TX("ui.admin.reports.pdf_service"), ["", TX("ui.admin.reports.col_gross")], [0, 515], [
      [TX("ui.admin.reports.pdf_sales"), eur(t.gross)],
      [TX("ui.admin.reports.pdf_refunds"), eur(t.refunds_gross)],
      [TX("ui.admin.reports.pdf_after"), eur(adv.total_gross)],
    ]);
    return await pdf.save();
  }
  if (kind === "methods") {
    const methods = rep.by_method || [];
    const rates = [...(rep.by_vat || [])].sort((a: any, b: any) => Number(a.rate) - Number(b.rate));
    const cell = (m: string, rateN: number) => (rep.by_method_vat || []).find((x: any) => x.method === m && Number(x.rate) === Number(rateN));
    table(TX("ui.admin.reports.payments"), [TX("ui.admin.reports.col_method"), TX("ui.admin.reports.col_gross")], [0, 515], methods.map((m: any) => [String(m.label ?? m.method ?? ""), eur(Number(m.gross ?? 0) + Number(m.refunds ?? 0))]));
    if (rates.length) {
      const cols = [0, ...rates.map((_: any, i: number) => 180 + i * 80), 180 + rates.length * 80];
      table(TX("ui.admin.reports.by_vat"), [TX("ui.admin.reports.col_method"), ...rates.map((v: any) => rate(v.rate, loc)), TX("ui.admin.reports.total")], cols, methods.map((m: any) => [String(m.label ?? m.method ?? ""), ...rates.map((v: any) => { const c = cell(m.method, v.rate); return c ? eur(c.gross) : "–"; }), eur((rep.by_method_vat || []).filter((x: any) => x.method === m.method).reduce((s: number, x: any) => s + Number(x.gross || 0), 0))]));
    }
    const rec = rep.reconciliation || {};
    const money = rec.money_received ?? 0;
    const diff = rec.methods_difference ?? 0;
    table(TX("ui.admin.reports.reconcile"), ["", TX("ui.admin.reports.col_gross")], [0, 515], [
      [TX("ui.admin.reports.money_received"), eur(money)],
      [TX("ui.admin.reports.pdf_after"), eur(rep.totals?.gross_after_refunds)],
      [TX("ui.admin.reports.gc_redemptions_row"), eur(rec.gift_card_redemptions)],
      [TX("ui.admin.reports.gc_sales_row"), eur(rec.gift_card_sales)],
      [TX("ui.admin.reports.invoiced_line"), eur(rec.invoiced)],
      [TX("ui.admin.reports.reconcile_diff"), eur(diff)],
    ]);
    const opens = (rep.open && rep.open.rows) || [];
    table(TX("ui.admin.reports.open_title"), [TX("ui.admin.reports.col_voucher"), TX("ui.admin.reports.col_customer"), TX("ui.admin.reports.col_gross")], [0, 180, 400], opens.map((x: any) => [String(x.voucher ?? ""), String(x.customer ?? ""), eur(x.gross)]));
    return await pdf.save();
  }

  const t = rep.totals ?? {};
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
  const vatHead = [TX("ui.admin.reports.col_vat_pct"), TX("ui.admin.reports.col_net"), TX("ui.admin.reports.col_gross"), TX("ui.admin.reports.col_vat_eur")];
  const vatCols = [0, 180, 300, 420];
  const vatLine = (v: any) => [rate(v.rate, loc), eur(v.net), eur(v.gross), eur(v.vat)];
  if (Array.isArray(rep.by_vat_sales)) table(TX("ui.admin.reports.vat_sales"), vatHead, vatCols, rep.by_vat_sales.map(vatLine));
  if (Array.isArray(rep.by_vat_refunds)) table(TX("ui.admin.reports.vat_refunds"), vatHead, vatCols, rep.by_vat_refunds.map(vatLine));
  const vatRows = Array.isArray(rep.by_vat) ? rep.by_vat : (rep.vat_summary || []);
  table(TX("ui.admin.reports.vat_net"), vatHead, vatCols, vatRows.map(vatLine));
  need(28); text(TX("ui.admin.reports.vat_breakdown_note"), M, 7, font, grey); y -= 16;
  const gcp = rep.gift_card_period || {};
  const sold = gcp.sold || {};
  need(20); text(TX("ui.admin.reports.gc_summary_title"), M, 12, bold); y -= 16;
  table(TX("ui.admin.reports.gc_sold"), [TX("ui.admin.reports.col_product"), TX("ui.admin.reports.col_count"), TX("ui.admin.reports.col_gross")], [0, 250, 515], (sold.lines || []).map((p: any) => [String(p.product ?? ""), String(p.quantity ?? ""), eur(p.gross)]));
  need(28); text(TX("ui.admin.reports.gc_multi_note"), M, 7, font, grey); y -= 16;
  const rec = rep.reconciliation;
  if (rec) {
    const rows = [
      [TX("ui.admin.reports.reconcile_sales"), eur(rec.sales_gross)],
      [TX("ui.admin.reports.reconcile_refunds"), eur(rec.refunds_gross)],
      [TX("ui.admin.reports.reconcile_products"), eur(rec.product_gross)],
    ];
    if (Math.abs(Number(rec.vat_rounding ?? 0)) >= 0.005 || rec.rounding_code) rows.push([TX("ui.admin.reports.rounding_row"), eur(rec.vat_rounding)]);
    if (Math.abs(Number(rec.cash_rounding ?? 0)) >= 0.005) rows.push([TX("ui.admin.reports.cash_rounding"), eur(rec.cash_rounding)]);
    table(TX("ui.admin.reports.reconcile"), ["", TX("ui.admin.reports.col_gross")], [0, 515], rows);
    if (rec.rounding_code) { need(28); text(TX("ui.admin.reports.vat_rounding_note"), M, 7, font, grey); y -= 16; }
  }
  if (rep.by_day) table(TX("ui.admin.reports.day"), [TX("ui.admin.reports.col_date"), TX("ui.admin.reports.col_gross")], [0, 515], rep.by_day.map((d: any) => [dfi(d.date), eur(d.gross)]));
  return await pdf.save();
}
