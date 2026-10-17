// vismapay-refund (RUNKO, mode off/dry_run): käsittelee booking.refunds-rivit status='requested', provider='visma_pay'.
// Toteutus (vaihe E): POST https://www.vismapay.com/pbwapi/create_refund {version:"w3.2", api_key, order_number, amount:<senttiä>, authcode: HMAC-SHA256(private_key, api_key|order_number), refund_type:"instant"|"email"}
// (create_refund pitää aktivoida Vismalta). Onnistuneesta: päivitä refunds.status='done', provider_refund_id, payments.refunded_amount/status, payment_lines.refunded_gross -> kutsu booking._on_refund_done(refund_id) (hyvityskuitti + viesti).
// Salaisuudet: VISMAPAY_API_KEY, VISMAPAY_PRIVATE_KEY. Tähän asti: admin voi kirjata verkkomaksun hyvityksen käsin (admin_refund p_manual_done).
import { createClient } from "npm:@supabase/supabase-js@2";
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });
Deno.serve(async () => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const cfg = await sb.schema("booking").from("integration_config").select("mode").eq("key", "vismapay").maybeSingle();
  const { count } = await sb.schema("booking").from("refunds").select("id", { count: "exact", head: true }).eq("status", "requested").eq("provider", "visma_pay");
  return json({ ok: false, implemented: false, mode: cfg.data?.mode ?? "off", requested_refunds: count ?? 0 }, 501);
});
