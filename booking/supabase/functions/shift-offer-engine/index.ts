// shift-offer-engine: vapaiden vuorojen tarjoaminen (SPEC.md).
// EI deployata tästä haarasta. EI lähetä viestejä. EI aja migraatioita.
//
// Autentikointi:
//   * tick (POST ilman tokenia): header x-sync-secret = env SYNC_CRON_SECRET (vakioaikavertailu)
//   * vastaus (GET/POST ?token=): HMAC-token tarkistetaan tietokannassa (shift_offer_verify_token).
//     Avain on vain vault-salaisuus shift_offer_token_secret. Edge-funktiolla ei ole omaa avainta.
//     GET vain näyttää vahvistuksen; vastaus kirjataan POST-lomakkeella
//     (selain ei hyväksy vuoroa linkin esihakuna).
//   * tietokanta: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY
// Kuivaharjoitus: ?dry_run=1 tai JSON {"dryRun":true} tai shift_offer_engine_settings.dry_run.
// Lähettäjä: shift_offer_engine_settings.sender_enabled oletus false (jono jää queued).
// Päälläkin vain stubi, joka merkitsee rivit skipped — ei sent, ei WhatsAppia eikä sähköpostia.
//
// Cron (EHDOTUS, ei luoda tässä). Salaisuus vaultista kuten calendar-sync-v2
// (vault.decrypted_secrets.name = calendar_sync_cron_secret). Aja muutaman minuutin välein:
//
//   select cron.schedule('shift-offer-engine-5m', '*/5 * * * *', $cron$
//     select net.http_post(
//       url := 'https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine',
//       body := '{}'::jsonb,
//       headers := jsonb_build_object(
//         'content-type', 'application/json',
//         'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'calendar_sync_cron_secret')
//       ),
//       timeout_milliseconds := 50000);
//   $cron$);
//
// Token-avain (ei repoissa, ei edge-ympäristössä): vault-salaisuus shift_offer_token_secret.
// Kuivaharjoitus käsin: sama kutsu, body {"dryRun":true} tai ?dry_run=1.
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  dryRunRequested,
  helsinkiMorning,
  parseAction,
  requestIntent,
  respondPage,
  secretMatches,
  senderDecision,
  type TickBody,
} from "./core.ts";

const log = (event: string, data: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ fn: "shift-offer-engine", event, ...data }));

function page(html: string, status = 200): Response {
  return new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8" } });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const token = url.searchParams.get("token");
  const intent = requestIntent(req.method, token);
  if (intent === "invalid") return new Response("method not allowed", { status: 405 });

  if (intent === "respond") {
    const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: verified, error: verifyError } = await supa.rpc("shift_offer_verify_token", { p_token: token });
    const tok = verified && typeof verified === "object"
      ? verified as { ok?: boolean; offer_id?: string; staff_id?: string }
      : null;
    if (verifyError || tok?.ok !== true || !tok.offer_id || !tok.staff_id) return page(respondPage(null, "bad_token"), 400);
    let action = parseAction(url.searchParams.get("r"));
    let until = url.searchParams.get("until");
    if (req.method === "POST") {
      const form = await req.formData().catch(() => null);
      action = parseAction(form?.get("r")?.toString() ?? url.searchParams.get("r"));
      until = form?.get("until")?.toString() ?? until;
    }
    if (req.method === "GET" || !action) return page(respondPage(action, null));
    const snooze = action === "snooze" ? helsinkiMorning(until ?? "") : null;
    if (action === "snooze" && !snooze) return page(respondPage(action, null));
    const { data, error } = await supa.rpc("shift_offer_engine_respond", {
      p_offer_id: tok.offer_id,
      p_staff_id: tok.staff_id,
      p_response: action,
      p_snooze_until: snooze,
      p_token: token,
    });
    if (error) {
      log("respond_failed", { error: "rpc" });
      return page(respondPage(action, "bad_token"), 400);
    }
    const result = typeof data === "object" && data && "result" in data ? String((data as { result: string }).result) : "bad_token";
    log("responded", { result });
    return page(respondPage(action, result));
  }

  const expected = Deno.env.get("SYNC_CRON_SECRET") ?? "";
  const provided = req.headers.get("x-sync-secret") ?? "";
  if (!(await secretMatches(provided, expected))) return new Response("unauthorized", { status: 401 });

  let body: TickBody = {};
  try {
    if (req.headers.get("content-length") !== "0") {
      const parsed = await req.json();
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) body = parsed as TickBody;
    }
  } catch {
    body = {};
  }

  const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: cfg } = await supa.from("shift_offer_engine_settings").select("dry_run, sender_enabled").eq("id", true).maybeSingle();
  const dryRun = dryRunRequested(url, body, cfg?.dry_run === true);
  const { data, error } = await supa.rpc("shift_offer_tick", { p_dry_run: dryRun });
  if (error) {
    log("tick_failed", { error: "rpc" });
    return Response.json({ ok: false, error: "tick_failed" }, { status: 500 });
  }
  let sender: unknown = { sender_enabled: false, sent: 0 };
  if (!dryRun && senderDecision(cfg?.sender_enabled === true) === "mark_stub") {
    const drained = await supa.rpc("shift_offer_sender_drain", { p_limit: 50 });
    sender = drained.data ?? { ok: false };
  }
  log("tick", { dryRun, actions: Array.isArray((data as { actions?: unknown })?.actions) ? (data as { actions: unknown[] }).actions.length : 0 });
  return Response.json({ ok: true, dryRun, tick: data, sender });
});
