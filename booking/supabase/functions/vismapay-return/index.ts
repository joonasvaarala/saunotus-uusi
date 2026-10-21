import { createClient } from "npm:@supabase/supabase-js@2";
import { realDb } from "../_shared/vismapay_db.ts";
import { handle } from "./handler.ts";

Deno.serve(async (req) => {
  try { return await handle(req, { db: realDb(createClient, Deno.env), env: Deno.env, fetch: (u, i) => fetch(u, i) }); }
  catch (e) { console.error("vismapay-return", (e as Error).message); return new Response("Maksun paluuta ei voitu käsitellä.", { status: 500, headers: { "content-type": "text/plain; charset=utf-8" } }); }
});
