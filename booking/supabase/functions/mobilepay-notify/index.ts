import { createClient } from "npm:@supabase/supabase-js@2";
import { realDb } from "../_shared/mobilepay.ts";
import { handle } from "./handler.ts";

Deno.serve(async (req) => {
  try { return await handle(req, { db: realDb(createClient, Deno.env), env: Deno.env, fetch: (u, i) => fetch(u, i) }); }
  catch (e) { console.error("mobilepay-notify", (e as Error).message); return new Response(JSON.stringify({ ok: false, code: "internal_error" }), { status: 500, headers: { "content-type": "application/json" } }); }
});
