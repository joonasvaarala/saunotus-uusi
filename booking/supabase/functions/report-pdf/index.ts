// report-pdf: GET ?kind=daily&date=YYYY-MM-DD  |  ?kind=month&ym=YYYY-MM  -> application/pdf. verify_jwt=true.
// Kutsuu admin_report_daily / admin_report_month kutsujan omalla JWT:llä, joten RPC:n oikeustarkistus (reports.daily / reports.view) on voimassa.
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type", "access-control-allow-methods": "GET, POST, OPTIONS" };
const san = (s: unknown): string => String(s ?? "").replace(/[^\u0020-\u007E\u00A0-\u00FF\u20AC\u2013\u2014\u2018\u2019\u201C\u201D\u2022\u2026]/g, "?");
const eur = (n: unknown) => Number(n ?? 0).toFixed(2).replace(".", ",") + " €";
const rate = (n: unknown) => String(Number(n)).replace(".", ",") + " %";
const dfi = (d: string) => d.split("-").reverse().join(".");
const tfi = (iso: string) => new Intl.DateTimeFormat("fi-FI", { timeZone: "Europe/Helsinki", day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }).format(new Date(iso)).replace(",", "");
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "content-type": "application/json" } });

async function build(rep: any, title: string): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.setTitle(san(title)); pdf.setProducer("Sipoonjoen perinnesauna"); pdf.setCreator("booking");
  const font = await pdf.embedFont(StandardFonts.Helvetica); const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const PW = 595.28, PH = 841.89, M = 44;
  let page = pdf.addPage([PW, PH]); let y = PH - M;
  const black = rgb(0.1, 0.1, 0.1), grey = rgb(0.4, 0.4, 0.4);
  const need = (h: number) => { if (y - h < M) { page = pdf.addPage([PW, PH]); y = PH - M; } };
  const text = (t: string, x: number, size = 9, f: PDFFont = font, c = black) => page.drawText(san(t), { x, y, size, font: f, color: c });
  const right = (t: string, xr: number, size = 9, f: PDFFont = font) => page.drawText(san(t), { x: xr - f.widthOfTextAtSize(san(t), size), y, size, font: f, color: black });
  const rule = () => page.drawLine({ start: { x: M, y: y - 3 }, end: { x: PW - M, y: y - 3 }, thickness: 0.5, color: rgb(0.7, 0.7, 0.7) });
  const table = (head: string[], cols: number[], rows: string[][], heading: string) => {
    need(40); text(heading, M, 11, bold); y -= 16;
    const draw = (cells: string[], f: PDFFont) => cells.forEach((c, i) => i === 0 ? text(c, M, 9, f) : right(c, M + cols[i], 9, f));
    draw(head, bold); rule(); y -= 14;
    for (const r of rows) { need(14); draw(r, font); y -= 13; }
    y -= 8;
  };
  const t = rep.totals ?? {};
  text("Sipoonjoen perinnesauna – " + title, M, 14, bold); y -= 16;
  text(`Jakso ${dfi(rep.period.from)}${rep.period.from !== rep.period.to ? " – " + dfi(rep.period.to) : ""} · perusteena kuitin antopäivä (kassaperuste) · luotu ${tfi(rep.generated_at)}`, M, 8, font, grey); y -= 22;

  table(["", "Summa"], [0, 507], [
    ["Kuitit (kpl)", String(t.receipts)], ["Hyvityskuitit (kpl)", String(t.refund_receipts)],
    ["Myynti yhteensä (sis. ALV)", eur(t.gross)], ["Hyvitykset", eur(t.refunds_gross)],
    ["Netto hyvitysten jälkeen (sis. ALV)", eur(t.net_after_refunds)], ["josta ALV", eur(t.vat_after_refunds)], ["Veroton", eur(t.net_ex_vat_after_refunds)],
    ["Käteispyöristykset", eur(t.rounding)],
  ], "Yhteenveto");

  table(["Maksutapa", "Kuitteja", "Myynti", "Hyvitykset", "Netto"], [0, 260, 350, 430, 507], (rep.by_method ?? []).map((m: any) => [m.label ?? m.method, String(m.payments), eur(m.gross), eur(m.refunds), eur(Number(m.gross) + Number(m.refunds))]), "Maksutavoittain");
  table(["ALV-kanta", "Veroton", "ALV", "Yhteensä"], [0, 380, 450, 507], (rep.by_vat ?? []).map((v: any) => [rate(v.rate), eur(v.net), eur(v.vat), eur(v.gross)]), "ALV-erittely");
  table(["Tuoteryhmä", "ALV", "Kpl", "Netto (brutto)"], [0, 330, 400, 507], (rep.by_category ?? []).map((c: any) => [c.label ?? c.category, rate(c.rate), String(c.quantity), eur(c.gross)]), "Tuoteryhmittäin");
  if (rep.by_day) table(["Päivä", "Kuitteja", "Myynti", "Hyvitykset", "ALV"], [0, 260, 350, 430, 507], rep.by_day.map((d: any) => [dfi(d.date), String(d.receipts), eur(d.gross), eur(d.refunds), eur(d.vat)]), "Päivittäin");
  if (rep.receipts) table(["Kuitti", "Aika", "Tilaus", "Maksutapa", "Summa"], [0, 160, 230, 360, 507], rep.receipts.map((r: any) => [r.receipt_no, tfi(r.issued_at), String(r.order_no), String(r.method ?? ""), eur(r.gross)]), "Kuitit");
  const un = rep.unreceipted ?? {};
  if (Number(un.payments) > 0) { need(30); text(`Huom: ${un.payments} maksua (${eur(un.amount)}) jaksolla ilman kuittia (ennen kuittijärjestelmää tehdyt maksut).`, M, 8, font, grey); y -= 12; }
  const op = rep.open ?? {};
  if (Number(op.orders) > 0) { need(20); text(`Avoimia maksamattomia tilauksia jaksolla: ${op.orders} kpl, ${eur(op.unpaid)}.`, M, 8, font, grey); }
  return await pdf.save();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const url = new URL(req.url);
  let q: Record<string, string> = Object.fromEntries(url.searchParams);
  if (req.method === "POST") { try { q = { ...q, ...(await req.json()) }; } catch { /* ignore */ } }
  const auth = req.headers.get("authorization") ?? "";
  if (!auth) return json({ ok: false, code: "unauthorized" }, 401);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const kind = q.kind === "month" ? "month" : "daily";
  const { data, error } = kind === "month" ? await sb.schema("booking").rpc("admin_report_month", { p_ym: q.ym }) : await sb.schema("booking").rpc("admin_report_daily", { p_date: q.date });
  if (error) {
    const code = (error as any).details ?? error.code;
    return json({ ok: false, code, message: error.message }, code === "forbidden" || code === "not_authenticated" ? 403 : 400);
  }
  const title = kind === "month" ? `Kuukausiraportti ${q.ym}` : `Päiväraportti ${dfi(String(q.date))}`;
  const bytes = await build(data, title);
  return new Response(bytes, { headers: { ...cors, "content-type": "application/pdf", "content-disposition": `inline; filename="raportti_${kind === "month" ? q.ym : q.date}.pdf"`, "cache-control": "no-store" } });
});
