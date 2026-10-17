// procountor-sync (RUNKO, mode off/dry_run): siirtää booking.accounting_outbox-rivit Procountoriin (ks. /workspace/procountor/PLAN_fi.md, draft/procountor-sync.DRAFT.ts).
// dry_run: laskee/validoi jonon, ei kutsu Procountoria. Toteutus (vaihe E): OAuth2 (PROCOUNTOR_CLIENT_ID/SECRET/API_KEY), POST /invoices (myynti-/hyvityslasku) ja /payments, dedupe_key = idempotenssiavain, kirjaa procountor_ids.
// accounting_outbox täyttyy vain kun integration_config.procountor.mode <> 'off' (sisältö = kuitin snapshot).
import { createClient } from "npm:@supabase/supabase-js@2";
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });
Deno.serve(async () => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const bk = sb.schema("booking");
  const cfg = await bk.from("integration_config").select("mode").eq("key", "procountor").maybeSingle();
  const { count } = await bk.from("accounting_outbox").select("id", { count: "exact", head: true }).in("status", ["pending", "failed"]);
  return json({ ok: false, implemented: false, mode: cfg.data?.mode ?? "off", pending: count ?? 0, have_secrets: !!Deno.env.get("PROCOUNTOR_CLIENT_ID") }, 501);
});
