// vismapay-notify (RUNKO, mode off/dry_run): Visma Pay kutsuu GET ?RETURN_CODE=0&ORDER_NUMBER=..&SETTLED=..&INCIDENT_ID=..&AUTHCODE=..
// Toteutus (vaihe E): authcode = HMAC-SHA256(private_key, "RETURN_CODE|ORDER_NUMBER|SETTLED|INCIDENT_ID") isoin kirjaimin -> vertaa vakioajassa;
// RETURN_CODE 0 -> check_payment_status (varmistus) -> RPC booking.payment_mark_paid('visma_pay', <provider_ref>, <amount>, <raw>) (luo kuitin ja viestin automaattisesti).
// Salaisuus: VISMAPAY_PRIVATE_KEY (+ VISMAPAY_API_KEY). Idempotentti: payment_mark_paid palauttaa already:true.
import { createClient } from "npm:@supabase/supabase-js@2";
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });
Deno.serve(async () => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const cfg = await sb.schema("booking").from("integration_config").select("mode").eq("key", "vismapay").maybeSingle();
  return json({ ok: false, implemented: false, mode: cfg.data?.mode ?? "off" }, 501);
});
