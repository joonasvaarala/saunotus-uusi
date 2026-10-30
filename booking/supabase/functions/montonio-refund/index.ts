import { createClient } from "npm:@supabase/supabase-js@2";
import { authorizeServiceRoleOrPermission } from "../_shared/service_role_auth.ts";
import { realDb } from "../_shared/montonio_db.ts";
import { handle } from "./handler.ts";

async function authorize(req: Request): Promise<boolean> {
  return authorizeServiceRoleOrPermission(req.headers.get("authorization"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), async (auth) => {
    const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const refund = await userClient.schema("booking").rpc("has_permission", { p_permission: "payments.refund" });
    if (!refund.error && refund.data === true) return true;
    const manage = await userClient.schema("booking").rpc("has_permission", { p_permission: "bookings.manage" });
    if (!manage.error && manage.data === true) return true;
    const adm = await userClient.schema("booking").rpc("is_admin");
    return !adm.error && adm.data === true;
  });
}

Deno.serve(async (req) => {
  try { return await handle(req, { db: realDb(createClient, Deno.env), env: Deno.env, fetch: (u, i) => fetch(u, i), authorize }); }
  catch (e) { console.error("montonio-refund", (e as Error).message); return new Response(JSON.stringify({ ok: false, code: "internal_error" }), { status: 500, headers: { "content-type": "application/json" } }); }
});
