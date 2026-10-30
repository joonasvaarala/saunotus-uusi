// report-pdf: kind=daily|month|range|transactions|giftcards|fees. verify_jwt=true.
// Kutsuu admin_report_* kutsujan JWT:llä, joten reports.daily / reports.view pysyy voimassa.
import { createClient } from "npm:@supabase/supabase-js@2";
import { buildReportPdf, REPORT_PDF_TEXTS } from "./render.ts";
import { fetchSiteTexts, makeT } from "../_shared/site_texts.ts";

const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type", "access-control-allow-methods": "GET, POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "content-type": "application/json" } });
const ALLOWED = new Set(["daily", "month", "range", "transactions", "giftcards", "fees"]);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const url = new URL(req.url);
  let q: Record<string, string> = Object.fromEntries(url.searchParams);
  if (req.method === "POST") { try { q = { ...q, ...(await req.json()) }; } catch { /* ignore */ } }
  const auth = req.headers.get("authorization") ?? "";
  if (!auth) return json({ ok: false, code: "unauthorized" }, 401);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const kind = ALLOWED.has(q.kind) ? q.kind : "daily";
  const rpc = kind === "fees" ? sb.schema("booking").rpc("admin_report_provider_fees", { p_from: q.from, p_to: q.to, p_format: "json" })
    : kind === "month" ? sb.schema("booking").rpc("admin_report_month", { p_ym: q.ym })
    : kind === "range" ? sb.schema("booking").rpc("admin_report_range", { p_from: q.from, p_to: q.to })
    : kind === "transactions" ? sb.schema("booking").rpc("admin_report_transactions", { p_from: q.from, p_to: q.to })
    : kind === "giftcards" ? sb.schema("booking").rpc("admin_report_gift_cards", { p_filter: q.filter || "all", p_format: "json" })
    : sb.schema("booking").rpc("admin_report_daily", { p_date: q.date });
  const { data, error } = await rpc;
  if (error) {
    const code = (error as { details?: string }).details ?? error.code;
    return json({ ok: false, code, message: error.message }, code === "forbidden" || code === "not_authenticated" ? 403 : 400);
  }
  const st = await fetchSiteTexts({ url: Deno.env.get("SUPABASE_URL"), anonKey: Deno.env.get("SUPABASE_ANON_KEY"), prefixes: ["ui.admin.reports.", "ui.admin.giftcards.vat_"] });
  const lang = q.lang === "en" ? "en" : "fi";
  const bytes = await buildReportPdf(data, kind, lang, makeT(REPORT_PDF_TEXTS, st?.rows, st?.settings));
  const file = kind === "month" ? q.ym : kind === "daily" ? q.date : kind === "giftcards" ? (q.filter || "all") : `${q.from}_${q.to}`;
  return new Response(bytes, { headers: { ...cors, "content-type": "application/pdf", "content-disposition": `inline; filename="raportti_${kind}_${file}.pdf"`, "cache-control": "no-store" } });
});
