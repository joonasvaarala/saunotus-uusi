import { createClient } from "npm:@supabase/supabase-js@2";
import { realDb } from "../_shared/montonio_db.ts";
import { handle } from "./handler.ts";

Deno.serve(async (req) => {
  try { return await handle(req, { db: realDb(createClient, Deno.env), env: Deno.env, fetch: (u, i) => fetch(u, i) }); }
  catch (e) { console.error("montonio-notify", (e as Error).message); return new Response("retry", { status: 503, headers: { "content-type": "text/plain" } }); }
});
