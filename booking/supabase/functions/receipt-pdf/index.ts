// receipt-pdf: GET ?t=<receipts.public_token> -> application/pdf (pdf-lib). verify_jwt=false (tokeni on salaisuus; kuitti on muuttumaton snapshot).
// Logo haetaan seller.logo_url:sta; jos hakeminen epäonnistuu tai osoite puuttuu, PDF tehdään ilman logoa.
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";
import { createClient } from "npm:@supabase/supabase-js@2";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type" };

// pdf-lib StandardFonts = WinAnsi: poistetaan merkit joita ei voi koodata
export const san = (s: unknown): string => String(s ?? "").replace(/[^\u0020-\u007E\u00A0-\u00FF\u20AC\u2013\u2014\u2018\u2019\u201C\u201D\u2022\u2026]/g, "?");
const money = (n: number, loc: string) => (loc === "en" ? n.toFixed(2) : n.toFixed(2).replace(".", ",")) + " €";
const rate = (n: number, loc: string) => (loc === "en" ? String(n) : String(n).replace(".", ",")) + " %";
const fmtLocal = (iso: string) => new Intl.DateTimeFormat("fi-FI", { timeZone: "Europe/Helsinki", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(iso)).replace(",", "");

async function fetchLogo(url?: string | null): Promise<Uint8Array | null> {
  if (!url) return null;
  try {
    const ctl = new AbortController(); const to = setTimeout(() => ctl.abort(), 4000);
    const r = await fetch(url, { signal: ctl.signal }); clearTimeout(to);
    if (!r.ok) return null;
    const b = new Uint8Array(await r.arrayBuffer());
    return b.length > 0 && b.length < 2_000_000 ? b : null;
  } catch { return null; }
}

export async function buildReceiptPdf(s: any): Promise<Uint8Array> {
  const loc = s.locale === "en" ? "en" : "fi";
  const en = loc === "en";
  const pdf = await PDFDocument.create();
  pdf.setTitle(san(`${s.receipt_no}`)); pdf.setProducer("Sipoonjoen Perinnesauna"); pdf.setCreator("booking");
  const font = await pdf.embedFont(StandardFonts.Helvetica); const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  let page = pdf.addPage([595.28, 841.89]);
  const M = 48; const W = 595.28 - 2 * M; let y = 841.89 - M;
  const black = rgb(0.1, 0.1, 0.1); const grey = rgb(0.4, 0.4, 0.4);
  const text = (p: PDFPage, t: string, x: number, yy: number, size = 10, f: PDFFont = font, color = black) => p.drawText(san(t), { x, y: yy, size, font: f, color });
  const right = (p: PDFPage, t: string, xr: number, yy: number, size = 10, f: PDFFont = font) => { const w = f.widthOfTextAtSize(san(t), size); p.drawText(san(t), { x: xr - w, y: yy, size, font: f, color: black }); };
  const wrap = (t: string, f: PDFFont, size: number, maxW: number): string[] => {
    const out: string[] = []; let cur = "";
    for (const w of san(t).split(/\s+/)) { const tt = cur ? cur + " " + w : w; if (f.widthOfTextAtSize(tt, size) > maxW && cur) { out.push(cur); cur = w; } else cur = tt; }
    if (cur) out.push(cur); return out;
  };
  const need = (h: number) => { if (y - h < M) { page = pdf.addPage([595.28, 841.89]); y = 841.89 - M; } };

  // logo
  const logoBytes = await fetchLogo(s.seller?.logo_url);
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
    [sel.legal_name, (en ? "Business ID " : "Y-tunnus ") + (sel.business_id ?? ""), (en ? "VAT ID " : "ALV-tunnus ") + (sel.vat_id ?? "")].filter(Boolean).join(", "),
    [sel.address, [sel.zip, sel.city].filter(Boolean).join(" ")].filter(Boolean).join(", "),
    [sel.email, sel.phone, sel.web].filter(Boolean).join("  ·  "),
  ];
  for (const l of sellerLines) { text(page, l, M, y, 9, font, grey); y -= 12; }
  y = Math.min(y, 841.89 - M - logoH - 8) - 14;

  const title = s.document === "refund_receipt" ? (en ? "REFUND RECEIPT" : "HYVITYSKUITTI") : s.invoice_required ? (en ? "RECEIPT / INVOICE" : "KUITTI / LASKU") : (en ? "RECEIPT" : "KUITTI");
  text(page, `${title} ${s.receipt_no}`, M, y, 16, bold); y -= 22;
  const meta: [string, string][] = [
    [en ? "Date" : "Päivämäärä", `${s.issued_local}`.replace(" ", en ? " at " : " klo ")],
    [en ? "Order" : "Tilaus", String(s.order_no)],
    [en ? "Payment method" : "Maksutapa", s.payment?.method_label ?? s.payment?.method ?? ""],
  ];
  if (s.original) meta.push([en ? "Original receipt" : "Alkuperäinen kuitti", `${s.original.receipt_no} (${s.original.issued_local ?? fmtLocal(s.original.issued_at)})`]);
  if (s.reason) meta.push([en ? "Reason" : "Hyvityksen syy", s.reason]);
  for (const [k, v] of meta) { text(page, k + ":", M, y, 10, bold); text(page, v, M + 120, y, 10); y -= 14; }
  if (s.buyer) {
    y -= 4; text(page, en ? "Buyer" : "Ostaja", M, y, 10, bold); y -= 14;
    const b = s.buyer;
    for (const l of [[b.company, b.name].filter(Boolean).join(", "), (b.business_id ? (en ? "Business ID " : "Y-tunnus ") + b.business_id : ""), [b.address, [b.zip, b.city].filter(Boolean).join(" ")].filter(Boolean).join(", "), b.reference ? (en ? "Your reference: " : "Viitteenne: ") + b.reference : ""].filter(Boolean)) { text(page, l, M, y, 10); y -= 13; }
  }
  y -= 10;
  // rivit
  const cx = { qty: M + W - 215, unit: M + W - 150, vat: M + W - 90, tot: M + W };
  page.drawLine({ start: { x: M, y: y + 12 }, end: { x: M + W, y: y + 12 }, thickness: 0.8, color: black });
  text(page, en ? "Item" : "Tuote", M, y, 9, bold); right(page, en ? "Qty" : "Kpl", cx.qty + 20, y, 9, bold); right(page, en ? "Unit" : "À hinta", cx.unit + 50, y, 9, bold); right(page, en ? "VAT" : "ALV", cx.vat + 30, y, 9, bold); right(page, en ? "Total" : "Yhteensä", cx.tot, y, 9, bold);
  y -= 8; page.drawLine({ start: { x: M, y }, end: { x: M + W, y }, thickness: 0.4, color: grey }); y -= 14;
  for (const l of s.lines) {
    let d = l.description as string;
    if (l.starts_at) d += ` (${new Intl.DateTimeFormat("fi-FI", { timeZone: "Europe/Helsinki", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(l.starts_at)).replace(",", "")}–${new Intl.DateTimeFormat("fi-FI", { timeZone: "Europe/Helsinki", hour: "2-digit", minute: "2-digit" }).format(new Date(l.ends_at))})`;
    const ls = wrap(d, font, 9.5, cx.qty - M - 30); need(ls.length * 12 + 6);
    ls.forEach((t, i) => text(page, t, M, y - i * 12, 9.5));
    right(page, String(l.quantity), cx.qty + 20, y, 9.5); right(page, money(Number(l.unit_gross), loc), cx.unit + 50, y, 9.5); right(page, rate(Number(l.vat_rate), loc), cx.vat + 30, y, 9.5); right(page, money(Number(l.line_gross), loc), cx.tot, y, 9.5);
    y -= ls.length * 12 + 4;
  }
  need(140); page.drawLine({ start: { x: M, y: y + 6 }, end: { x: M + W, y: y + 6 }, thickness: 0.4, color: grey }); y -= 10;
  // ALV-erittely
  text(page, en ? "VAT breakdown" : "ALV-erittely", M, y, 10, bold); y -= 14;
  text(page, en ? "Rate" : "Verokanta", M, y, 9, bold); right(page, en ? "Excl. VAT" : "Veroton", M + 230, y, 9, bold); right(page, en ? "VAT" : "ALV", M + 320, y, 9, bold); right(page, en ? "Total" : "Yhteensä", M + 410, y, 9, bold); y -= 13;
  for (const v of s.vat) { text(page, rate(Number(v.rate), loc), M, y, 9.5); right(page, money(Number(v.net), loc), M + 230, y, 9.5); right(page, money(Number(v.vat), loc), M + 320, y, 9.5); right(page, money(Number(v.gross), loc), M + 410, y, 9.5); y -= 13; }
  y -= 8;
  const tot: [string, string, boolean][] = [
    [en ? "Total (incl. VAT)" : "Yhteensä (sis. ALV)", money(Number(s.total_gross), loc), true],
    [en ? "of which VAT" : "josta ALV", money(Number(s.total_vat), loc), false],
    [en ? "Excl. VAT" : "Veroton", money(Number(s.total_net), loc), false],
  ];
  const rnd = Number(s.rounding ?? 0);
  if (rnd !== 0) tot.push([en ? "Cash rounding" : "Käteispyöristys", (rnd > 0 ? "+" : "") + money(rnd, loc), false]);
  tot.push([s.document === "refund_receipt" ? (en ? "Refunded" : "Hyvitetty") : (en ? "Paid" : "Maksettu"), money(Number(s.total_paid), loc), true]);
  for (const [k, v, b] of tot) { need(16); text(page, k, M + 250, y, 10, b ? bold : font); right(page, v, M + W, y, 10, b ? bold : font); y -= 15; }
  if (sel.footer) { y -= 14; need(20); for (const l of wrap(sel.footer, font, 9, W)) { text(page, l, M, y, 9, font, grey); y -= 12; } }
  return await pdf.save();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "GET") return new Response("method not allowed", { status: 405, headers: cors });
  const t = new URL(req.url).searchParams.get("t") ?? "";
  if (!UUID.test(t)) return new Response("not found", { status: 404, headers: cors });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await sb.schema("booking").rpc("receipt_by_token", { p_token: t });
  if (error) return new Response("error", { status: 500, headers: cors });
  if (!data) return new Response("not found", { status: 404, headers: cors });
  const no = String(data.receipt_no);
  const path = `${no}.pdf`;
  let bytes: Uint8Array | null = null;
  try { const dl = await sb.storage.from("receipts").download(path); if (dl.data) bytes = new Uint8Array(await dl.data.arrayBuffer()); } catch { /* ei välimuistia */ }
  if (!bytes) {
    bytes = await buildReceiptPdf(data.snapshot);
    try {
      const up = await sb.storage.from("receipts").upload(path, bytes, { contentType: "application/pdf", upsert: true });
      if (!up.error) await sb.schema("booking").rpc("receipt_set_pdf", { p_receipt_id: data.id, p_path: path });
    } catch { /* välimuisti on vain optimointi */ }
  }
  return new Response(bytes, { headers: { ...cors, "content-type": "application/pdf", "content-disposition": `inline; filename="${data.kind === "refund_receipt" ? "hyvityskuitti" : "kuitti"}-${no}.pdf"`, "cache-control": "private, max-age=300" } });
});
