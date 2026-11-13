// sumup-notify (verify_jwt = false): SumUp kutsuu palvelimelta; tunnistus = ?s= webhook-salaisuus + tilan vahvistus SumUpin rajapinnasta.
import { createClient } from "npm:@supabase/supabase-js@2";
import { handle } from "./handler.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const db = {
  rpc: async (fn: string, args?: Record<string, unknown>) => { const { data, error } = await admin.schema("booking").rpc(fn, args ?? {}); return { data, error }; },
  mode: async () => {
    const { data } = await admin.schema("booking").from("integration_config").select("mode").eq("key", "sumup").maybeSingle();
    return data?.mode === "test" || data?.mode === "live" ? data.mode : "off";
  },
};

Deno.serve(async (req) => {
  try { return await handle(req, { db, env: Deno.env, fetch: (u, i) => fetch(u, i) }); }
  catch (e) { console.error("sumup-notify", (e as Error).message); return new Response("retry", { status: 503, headers: { "content-type": "text/plain" } }); }
});
