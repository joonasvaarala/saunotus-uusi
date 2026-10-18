// vismapay-start. Live-HTTP Vismaan ei ole toteutettu (ei avaimia tässä). dry_run/off/live tulevat RPC:stä.
import { createClient } from "npm:@supabase/supabase-js@2";
import { realDb } from "../_shared/mobilepay.ts";
import { handle } from "./handler.ts";

Deno.serve(async (req) => {
  try {
    return await handle(req, { db: realDb(createClient, Deno.env) });
  } catch (e) {
    console.error("vismapay-start", (e as Error).message);
    return new Response(JSON.stringify({ ok: false, code: "internal_error", implemented: false }), { status: 500, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });
  }
});
