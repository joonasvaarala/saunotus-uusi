// invoice-dispatch: lukee booking.invoices-jonon (invoice_dispatch_claim) ja kutsuu provider-rajapintaa.
// Ilman Procountor-tunnuksia provider on dry_run. PDF-sähköposti on erillinen send-emails-polku.
// Kutsu: POST + x-sync-secret, kuten send-emails. verify_jwt=false.
import { createClient } from "npm:@supabase/supabase-js@2";
import { providerFor, type NormalizedInvoice } from "../_shared/invoice_provider.ts";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const sb = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const bk = sb.schema("booking");
  const ok = await bk.rpc("_cron_secret_ok", { p_secret: req.headers.get("x-sync-secret") });
  if (ok.error || ok.data !== true) return json({ ok: false, error: "unauthorized" }, 401);
  const modeRow = await bk.from("settings").select("value").eq("key", "invoice_dispatch_mode").maybeSingle();
  const mode = typeof modeRow.data?.value === "string" ? modeRow.data.value : "dry_run";
  const provider = providerFor(mode);
  const claimed = await bk.rpc("invoice_dispatch_claim", { p_limit: 10 });
  if (claimed.error) return json({ ok: false, error: claimed.error.message }, 500);
  const rows: { id: number; invoice: NormalizedInvoice }[] = claimed.data ?? [];
  const stats = { mode, claimed: rows.length, dry_run: 0, sent: 0, failed: 0 };
  for (const row of rows) {
    try {
      const result = await provider.send(row.invoice);
      const status = result.ok ? result.mode : "failed";
      await bk.rpc("invoice_dispatch_mark", { p_id: row.id, p_status: status, p_error: result.error ?? null, p_provider_ref: result.provider_ref ?? null });
      if (status === "sent") stats.sent++;
      else if (status === "dry_run") stats.dry_run++;
      else stats.failed++;
    } catch (e) {
      await bk.rpc("invoice_dispatch_mark", { p_id: row.id, p_status: "failed", p_error: String((e as Error).message ?? e), p_provider_ref: null });
      stats.failed++;
    }
  }
  return json({ ok: true, ...stats });
});
