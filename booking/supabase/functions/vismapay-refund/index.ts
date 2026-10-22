import { createClient } from "npm:@supabase/supabase-js@2";
import { authorizeServiceRoleOrPermission } from "../_shared/service_role_auth.ts";
import { realDb } from "../_shared/vismapay_db.ts";
import { handle } from "./handler.ts";

// Auth: service role -avain (täsmäys) tai portin varmentama service_role-JWT, tai henkilökunta jolla payments.refund.
async function authorize(req: Request): Promise<boolean> {
  return authorizeServiceRoleOrPermission(req.headers.get("authorization"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), async (auth) => {
    const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data, error } = await userClient.schema("booking").rpc("has_permission", { p_permission: "payments.refund" });
    return !error && data === true;
  });
}

Deno.serve(async (req) => {
  try { return await handle(req, { db: realDb(createClient, Deno.env), env: Deno.env, fetch: (u, i) => fetch(u, i), authorize }); }
  catch (e) { console.error("vismapay-refund", (e as Error).message); return new Response(JSON.stringify({ ok: false, code: "internal_error" }), { status: 500, headers: { "content-type": "application/json" } }); }
});
