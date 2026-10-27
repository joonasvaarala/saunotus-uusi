// montonio-start. test/live: Orders API. dry_run/off: ei HTTP:tä.
import { createClient } from "npm:@supabase/supabase-js@2";
import { realDb } from "../_shared/montonio_db.ts";
import { asRedirect, handle } from "./handler.ts";

Deno.serve(async (req) => {
  try {
    const res = await handle(req, { db: realDb(createClient, Deno.env), env: Deno.env, fetch: (u, i) => fetch(u, i) });
    return await asRedirect(req, res);
  } catch (e) {
    console.error("montonio-start", (e as Error).message);
    return new Response(JSON.stringify({ ok: false, code: "internal_error" }), { status: 500, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });
  }
});
