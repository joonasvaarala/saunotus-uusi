import { createClient } from "npm:@supabase/supabase-js@2";
import { realDb } from "../_shared/mobilepay.ts";
import { handle } from "./handler.ts";
import { MOBILEPAY_START_TEXTS } from "./texts.ts";
import { fetchSiteTexts, makeT } from "../_shared/site_texts.ts";

Deno.serve(async (req) => {
  try {
    // virheilmoitusten tekstit tietokannasta (ui.mobilepay.*; §18) → repon oletus jos haku epäonnistuu
    const st = await fetchSiteTexts({ url: Deno.env.get("SUPABASE_URL"), anonKey: Deno.env.get("SUPABASE_ANON_KEY"), prefixes: ["ui.mobilepay.start_error_"] });
    return await handle(req, { db: realDb(createClient, Deno.env), env: Deno.env, fetch: (u, i) => fetch(u, i), texts: makeT(MOBILEPAY_START_TEXTS, st?.rows, st?.settings) });
  }
  catch (e) { console.error("mobilepay-start", (e as Error).message); return new Response(JSON.stringify({ ok: false, code: "internal_error" }), { status: 500, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } }); }
});
