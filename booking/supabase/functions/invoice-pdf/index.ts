// invoice-pdf: GET ?t=<invoices.public_token> -> application/pdf. verify_jwt=false (tokeni on salaisuus).
import { createClient } from "npm:@supabase/supabase-js@2";
import { buildInvoicePdf, INVOICE_PDF_TEXTS } from "./render.ts";
import { fetchSiteTexts, makeT } from "../_shared/site_texts.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "GET") return new Response("method not allowed", { status: 405, headers: cors });
  const t = new URL(req.url).searchParams.get("t") ?? "";
  if (!UUID.test(t)) return new Response("not found", { status: 404, headers: cors });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await sb.schema("booking").rpc("invoice_by_token", { p_token: t });
  if (error) return new Response("error", { status: 500, headers: cors });
  if (!data) return new Response("not found", { status: 404, headers: cors });
  const no = data.invoice_no ? String(data.invoice_no) : "";
  const path = no ? `${no}.pdf` : "";
  let bytes: Uint8Array | null = null;
  if (path) {
    try { const dl = await sb.storage.from("invoices").download(path); if (dl.data) bytes = new Uint8Array(await dl.data.arrayBuffer()); } catch { /* ei välimuistia */ }
  }
  if (!bytes) {
    const st = await fetchSiteTexts({ url: Deno.env.get("SUPABASE_URL"), anonKey: Deno.env.get("SUPABASE_ANON_KEY"), prefixes: ["email.invoice_pdf."] });
    bytes = await buildInvoicePdf(data, makeT(INVOICE_PDF_TEXTS, st?.rows, st?.settings));
    if (path) {
      try {
        const up = await sb.storage.from("invoices").upload(path, bytes, { contentType: "application/pdf", upsert: true });
        if (!up.error) await sb.schema("booking").rpc("invoice_set_pdf", { p_invoice_id: data.id, p_path: path });
      } catch { /* välimuisti on vain optimointi */ }
    }
  }
  const name = data.kind === "credit" ? "hyvityslasku" : "lasku";
  return new Response(bytes, { headers: { ...cors, "content-type": "application/pdf", "content-disposition": `inline; filename="${name}-${no || data.id}.pdf"`, "cache-control": "private, max-age=300" } });
});
