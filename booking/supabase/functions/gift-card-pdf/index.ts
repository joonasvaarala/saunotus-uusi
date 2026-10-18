// gift-card-pdf: GET ?t=<gift_cards.public_token> [&lang=fi|en] -> application/pdf (pdf-lib). verify_jwt=false: vain UUID-tokeni (salaisuus) avaa; muuten 404.
// Sisältö: booking.svc_get_gift_card_pdf_data(token) (service_role; ei IP-rate limitiä, public_get_gift_card käyttää samaa). Ei välimuistia: saldo/voimassaolo/tila voivat muuttua.
// Logo: seller.logo_url (4 s aikaraja; epäonnistuessa PDF ilman logoa). Maksamaton/mitätöity kortti -> 409 not ready (ei PDF:ää).
import { createClient } from "npm:@supabase/supabase-js@2";
import { buildGiftCardPdf, GIFT_CARD_PDF_TEXTS } from "./render.ts";
import { fetchSiteTexts, makeT } from "../_shared/site_texts.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type" };

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "GET" && req.method !== "HEAD") return new Response("method not allowed", { status: 405, headers: cors });
  const u = new URL(req.url);
  const t = u.searchParams.get("t") ?? "";
  if (!UUID.test(t)) return new Response("not found", { status: 404, headers: cors });
  const lang = u.searchParams.get("lang");
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await sb.schema("booking").rpc("svc_get_gift_card_pdf_data", { p_public_token: t.toLowerCase() });
  if (error) return new Response("error", { status: 500, headers: cors });
  if (!data?.ok) return new Response(data?.code === "not_ready" ? "not ready" : "not found", { status: data?.code === "not_ready" ? 409 : 404, headers: cors });
  const logo = await fetchLogo(data.seller?.logo_url);
  let bytes: Uint8Array;
  // tekstit tietokannasta (email.gift_card_pdf.*; §18) → repon oletus jos haku epäonnistuu
  const st = await fetchSiteTexts({ url: Deno.env.get("SUPABASE_URL"), anonKey: Deno.env.get("SUPABASE_ANON_KEY"), prefixes: ["email.gift_card_pdf."] });
  try { bytes = await buildGiftCardPdf(data, logo, lang === "en" || lang === "fi" ? lang : undefined, makeT(GIFT_CARD_PDF_TEXTS, st?.rows, st?.settings)); } catch (_e) { return new Response("error", { status: 500, headers: cors }); }
  return new Response(req.method === "HEAD" ? null : bytes, { headers: { ...cors, "content-type": "application/pdf", "content-disposition": `inline; filename="lahjakortti.pdf"`, "cache-control": "private, no-store" } });
});
