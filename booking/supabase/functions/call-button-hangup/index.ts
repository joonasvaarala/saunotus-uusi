// call-button-hangup (verify_jwt = false). Terassin hälytysnappi, booking_340–342. Logiikka: ../_shared/call_button.js
// Salaisuudet vain Edge-ympäristössä: CALL_BUTTON_WEBHOOK_SECRET, ELKS_API_USERNAME, ELKS_API_PASSWORD, ELKS_FROM_NUMBER
// (valinnainen CALL_BUTTON_AUDIO_BASE). Puhelinnumeroa tai salaisuuksia ei lokiteta.
import { createClient } from "npm:@supabase/supabase-js@2";
// @ts-ignore: puhdas JS-moduuli (testataan node --testillä)
import { handleHangup } from "../_shared/call_button.js";

const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});
const rpc = async (fn: string, args: Record<string, unknown>) => {
  const { data, error } = await admin.schema("booking").rpc(fn, args);
  return { data, error };
};

Deno.serve(async (req: Request) => {
  try {
    return await handleHangup(req, { rpc, env: Deno.env, fetch: (u: string, i?: RequestInit) => fetch(u, i) });
  } catch (e) {
    console.error("call-button-hangup: virhe", (e as Error)?.name ?? "error");
    return new Response(JSON.stringify({ ok: false, code: "retry" }), { status: 503, headers: { "content-type": "application/json" } });
  }
});
