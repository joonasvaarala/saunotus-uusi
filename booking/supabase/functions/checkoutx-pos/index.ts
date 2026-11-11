// checkoutx-pos (verify_jwt = true). Käyttäjän JWT → oikeudet booking.has_permission-RPC:llä; tietokanta service rolella.
import { createClient } from "npm:@supabase/supabase-js@2";
import { isServiceRoleBearer } from "../_shared/service_role_auth.ts";
import { type Caller, handle } from "./handler.ts";

const env = Deno.env;
const admin = createClient(env.get("SUPABASE_URL")!, env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function caller(req: Request): Promise<Caller | null> {
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return null;
  if (isServiceRoleBearer(auth.slice(7), env.get("SUPABASE_SERVICE_ROLE_KEY"))) return { uid: null, service: true, can: async () => true };
  const user = createClient(env.get("SUPABASE_URL")!, env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data, error } = await user.auth.getUser();
  if (error || !data?.user?.id) return null;
  return {
    uid: data.user.id,
    service: false,
    can: async (perm: string) => {
      const r = await user.schema("booking").rpc("has_permission", { p_permission: perm });
      return !r.error && r.data === true;
    },
  };
}

const db = {
  rpc: async (fn: string, args?: Record<string, unknown>) => { const { data, error } = await admin.schema("booking").rpc(fn, args ?? {}); return { data, error }; },
  cxMode: async () => {
    const { data } = await admin.schema("booking").from("integration_config").select("mode").eq("key", "checkoutx").maybeSingle();
    return data?.mode === "test" ? "test" : "off";
  },
};

Deno.serve(async (req) => {
  try {
    return await handle(req, { db, env, fetch: (u, i) => fetch(u, i), caller });
  } catch (e) {
    console.error("checkoutx-pos", (e as Error).message);
    return new Response(JSON.stringify({ ok: false, code: "internal_error" }), { status: 500, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });
  }
});
