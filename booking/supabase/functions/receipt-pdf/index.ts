// receipt-pdf: GET ?t=<receipts.public_token> [&o=<orders.public_token>] -> application/pdf (pdf-lib).
// verify_jwt=false (kuittitoken on salaisuus). Välimuistin polku on kuittirivin public_token + snapshotin tiiviste,
// ei kuittinumero: uudelleen käytetty numero ei saa palauttaa toisen kuitin tiedostoa.
// Piirto: render.ts (buildReceiptPdf). Logo haetaan seller.logo_url:sta; jos hakeminen epäonnistuu tai osoite puuttuu, PDF tehdään ilman logoa.
import { createClient } from "npm:@supabase/supabase-js@2";
import { buildReceiptPdf, RECEIPT_PDF_TEXTS } from "./render.ts";
import { fetchSiteTexts, makeT } from "../_shared/site_texts.ts";
import { decideReceiptPdf, isPdfBytes, storageReadAllowed } from "./cache.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "GET") return new Response("method not allowed", { status: 405, headers: cors });
  const url = new URL(req.url);
  const t = url.searchParams.get("t") ?? "";
  const rawOrder = url.searchParams.get("o");
  const orderTok = rawOrder && rawOrder.length > 0 ? rawOrder : null;
  if (!UUID.test(t) || (orderTok && !UUID.test(orderTok))) return new Response("not found", { status: 404, headers: cors });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await sb.schema("booking").rpc("receipt_by_token", { p_token: t });
  if (error) return new Response("error", { status: 500, headers: cors });
  if (!data) return new Response("not found", { status: 404, headers: cors });
  const decision = decideReceiptPdf({
    requestedToken: t,
    requestedOrderToken: orderTok,
    receiptNo: String(data.receipt_no ?? ""),
    publicToken: String(data.public_token ?? ""),
    contentHash: String(data.content_hash ?? ""),
    pdfObjectKey: String(data.pdf_object_key ?? ""),
    orderPublicToken: String(data.order_public_token ?? ""),
  });
  if (decision.action === "deny") return new Response("not found", { status: 404, headers: cors });
  const path = decision.path;
  let bytes: Uint8Array | null = null;
  if (path && storageReadAllowed(path, path)) {
    try {
      const dl = await sb.storage.from("receipts").download(path);
      if (dl.data) bytes = new Uint8Array(await dl.data.arrayBuffer());
    } catch { /* ei välimuistia */ }
    if (!isPdfBytes(bytes)) bytes = null;
  }
  if (!bytes) {
    // tekstit tietokannasta (email.receipt_pdf.*; §18) → repon oletus jos haku epäonnistuu
    const st = await fetchSiteTexts({ url: Deno.env.get("SUPABASE_URL"), anonKey: Deno.env.get("SUPABASE_ANON_KEY"), prefixes: ["email.receipt_pdf."] });
    bytes = await buildReceiptPdf(data.snapshot, makeT(RECEIPT_PDF_TEXTS, st?.rows, st?.settings));
    if (path && storageReadAllowed(path, path)) {
      try {
        const up = await sb.storage.from("receipts").upload(path, bytes, { contentType: "application/pdf", upsert: true });
        if (!up.error) await sb.schema("booking").rpc("receipt_set_pdf", { p_receipt_id: data.id, p_path: path });
      } catch { /* välimuisti on vain optimointi */ }
    }
  }
  const no = String(data.receipt_no ?? data.id);
  return new Response(bytes, { headers: { ...cors, "content-type": "application/pdf", "content-disposition": `inline; filename="${data.kind === "refund_receipt" ? "hyvityskuitti" : "kuitti"}-${no}.pdf"`, "cache-control": "private, no-store" } });
});
