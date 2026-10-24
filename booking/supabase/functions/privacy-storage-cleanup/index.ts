// privacy-storage-cleanup (booking_160): poistaa säilytysajan päättyneiden kuitti-, lasku- ja lahjakortti-PDF:ien tiedostot
// Supabase Storage -API:lla (storage.from(bucket).remove(paths)). EI poista storage.objects-rivejä SQL:llä (Supabase: tiedosto jäisi).
// Kutsuja: pg_cron (POST + x-sync-secret, booking._cron_secret_ok) tai käsin. verify_jwt = false (config.toml).
// Lista: booking.privacy_storage_due() (vain rivit, joilla pdf_deleted_at on asetettu privacy_retention_run-ajossa).
// Poisto vain kun privacy_retention.enabled = true JA privacy_retention.dry_run = false; muuten vain lista/määrät.
// Pyyntö {"dry_run": true} pakottaa kuivaharjoituksen.
import { createClient } from "npm:@supabase/supabase-js@2";
import { planRemoval } from "./core.ts";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const bk = sb.schema("booking");
  const auth = await bk.rpc("_cron_secret_ok", { p_secret: req.headers.get("x-sync-secret") });
  if (auth.error || auth.data !== true) return json({ ok: false, error: "unauthorized" }, 401);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* tyhjä runko */ }
  const due = await bk.rpc("privacy_storage_due", { p_limit: 1000 });
  if (due.error) return json({ ok: false, error: "due_failed" }, 500);
  const plan = planRemoval(due.data, body?.dry_run === true);
  if (plan.mode !== "remove") {
    return json({ ok: true, mode: plan.mode, total: plan.total, listed: plan.batches.reduce((n, b) => n + b.paths.length, 0), rejected: plan.rejected });
  }
  let removed = 0; const errors: string[] = [];
  for (const b of plan.batches) {
    const r = await sb.storage.from(b.bucket).remove(b.paths);
    if (r.error) errors.push(`${b.bucket}: ${r.error.message}`.slice(0, 200));
    else removed += (r.data ?? []).length;
  }
  return json({ ok: errors.length === 0, mode: "remove", total: plan.total, removed, rejected: plan.rejected, errors });
});
