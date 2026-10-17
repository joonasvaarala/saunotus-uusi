// vismapay-start (RUNKO, mode off/dry_run): GET ?p=<payments.link_token> -> luo tuoreen Visma Pay -tokenin ja ohjaa asiakkaan maksusivulle.
// Toteutus (vaihe E, kun testitunnukset on): 1) hae maksu link_tokenilla (RPC payment_by_link_token – lisätään), tarkista pending + ei vanhentunut,
// 2) POST https://www.vismapay.com/pbwapi/auth_payment  {version:"w3.2", api_key, order_number:<payment.id>-<n>, currency:"EUR", amount:<senttiä>, payment_method:{type:"e-payment", return_url, notify_url, lang, token_valid_until}, customer, products[]}
//    authcode = HMAC-SHA256(private_key, api_key + "|" + order_number) isoin kirjaimin; 3) tallenna token provider_ref:iin, redirect https://www.vismapay.com/pbwapi/token/<token>.
// Salaisuudet: VISMAPAY_API_KEY, VISMAPAY_PRIVATE_KEY. Dokumentaatio: https://www.vismapay.com/docs/web_payments/
import { createClient } from "npm:@supabase/supabase-js@2";
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });
Deno.serve(async () => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const cfg = await sb.schema("booking").from("integration_config").select("mode").eq("key", "vismapay").maybeSingle();
  const mode = cfg.data?.mode ?? "off";
  const haveKeys = !!Deno.env.get("VISMAPAY_API_KEY") && !!Deno.env.get("VISMAPAY_PRIVATE_KEY");
  return json({ ok: false, implemented: false, mode, have_secrets: haveKeys, message: "Verkkomaksu ei ole käytössä – maksu paikan päällä." }, 501);
});
