import { createClient } from "npm:@supabase/supabase-js@2";
import { realDb } from "../_shared/mobilepay.ts";
import { handle } from "./handler.ts";

// Auth: service role -avain (cron) TAI kirjautunut henkilökunta jolla payments.refund -oikeus.
async function authorize(req: Request): Promise<boolean> {
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return false;
  if (auth.slice(7) === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) return true;
  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data, error } = await userClient.schema("booking").rpc("has_permission", { p_permission: "payments.refund" });
  return !error && data === true;
}

Deno.serve(async (req) => {
  try { return await handle(req, { db: realDb(createClient, Deno.env), env: Deno.env, fetch: (u, i) => fetch(u, i), authorize }); }
  catch (e) { console.error("mobilepay-refund", (e as Error).message); return new Response(JSON.stringify({ ok: false, code: "internal_error" }), { status: 500, headers: { "content-type": "application/json" } }); }
});
