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
// Lähettäjä: sender_enabled oletus false (jono jää queued).
// WhatsApp: whatsapp_enabled oletus false, whatsapp_dry_run oletus true, allowlist tyhjä.
// Henkilö saa WhatsAppin vain jos staff.whatsapp_enabled on päällä ja numero normalisoituu.
// Joonas ja Otto eivät saa WhatsAppia: rivi jää kanavalle bot, tilaan bot_channel.
// Oikea lähetys vaatii kaikki kytkimet ja allowlistan. Kuivaharjoitus lokittaa peitetyn rungon eikä kutsu Metan.
// sending ilman wamidia ei palaa jonoon: 10 min jälkeen tila on unknown (tarkistetaan käsin).
// Webhook: GET/POST /webhook (WHATSAPP_VERIFY_TOKEN, X-Hub-Signature-256 / WHATSAPP_APP_SECRET).
// Salaisuudet vain ympäristöstä: WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_APP_SECRET, WHATSAPP_VERIFY_TOKEN.
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
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  dryRunRequested,
  helsinkiMorning,
  parseAction,
  requestIntent,
  respondPage,
  secretMatches,
  senderDecision,
  type RespondPageInput,
  type ShiftOfferCard,
  type TickBody,
} from "./core.ts";
import { deliverQueued, readWhatsappEnv, webhookResponse } from "./sender.ts";

function db(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

const log = (event: string, data: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ fn: "shift-offer-engine", event, ...data }));

function cardFromRow(raw: Record<string, unknown>): ShiftOfferCard | null {
  const id = raw.offer_id ? String(raw.offer_id) : "";
  if (!id) return null;
  return {
    offerId: id,
    role: raw.role_type == null ? "" : String(raw.role_type),
    startsAt: raw.starts_at == null ? null : String(raw.starts_at),
    endsAt: raw.ends_at == null ? null : String(raw.ends_at),
    deadlineAt: raw.deadline_at == null ? null : String(raw.deadline_at),
    snoozeAllowed: raw.snooze_allowed === true,
  };
}

async function loadOpenOffers(supa: SupabaseClient, token: string): Promise<
  { ok: true; focusOfferId: string; offers: ShiftOfferCard[] } | { ok: false }
> {
  const { data, error } = await supa.rpc("shift_offer_open_for_token", { p_token: token });
  if (error || !data || typeof data !== "object") return { ok: false };
  const row = data as { ok?: boolean; focus_offer_id?: unknown; offers?: unknown };
  if (row.ok !== true || typeof row.focus_offer_id !== "string" || !row.focus_offer_id) return { ok: false };
  const offers = Array.isArray(row.offers)
    ? row.offers.flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const card = cardFromRow(item as Record<string, unknown>);
      return card ? [card] : [];
    })
    : [];
  return { ok: true, focusOfferId: row.focus_offer_id, offers };
}

function page(html: string, status = 200): Response {
  return new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8" } });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (url.pathname.endsWith("/webhook")) {
    const env = readWhatsappEnv(Deno.env);
    const supa = db();
    return webhookResponse(req, env, async (update) => {
      const { error } = await supa.rpc("shift_offer_whatsapp_apply_status", {
        p_wamid: update.wamid,
        p_status: update.status,
        p_error: update.error,
        p_at: update.at,
      });
      if (error) throw new Error("status_failed");
    });
  }
  const token = url.searchParams.get("token");
  const intent = requestIntent(req.method, token);
  if (intent === "invalid") return new Response("method not allowed", { status: 405 });

  if (intent === "respond") {
    const supa = db();
    const open = await loadOpenOffers(supa, token ?? "");
    const blank = { result: "bad_token", acted: null, offers: [], focusOfferId: null, snoozeOpenOfferId: null };
    if (!open.ok) return page(respondPage(blank), 400);
    let action = parseAction(url.searchParams.get("r"));
    let until = url.searchParams.get("until");
    let postedOffer = "";
    if (req.method === "POST") {
      const form = await req.formData().catch(() => null);
      action = parseAction(form?.get("r")?.toString() ?? url.searchParams.get("r"));
      until = form?.get("until")?.toString() ?? until;
      postedOffer = form?.get("offer_id")?.toString() ?? "";
    }
    const show = (extra: Partial<RespondPageInput> = {}, status = 200) => page(respondPage({
      result: null,
      acted: null,
      offers: open.offers,
      focusOfferId: open.focusOfferId,
      snoozeOpenOfferId: null,
      ...extra,
    }), status);
    // GET vain näyttää sivun. Vastaus kirjataan vasta POST-lomakkeella.
    if (req.method === "GET" || !action) return show();
    const target = postedOffer
      ? (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(postedOffer) ? postedOffer : "")
      : open.focusOfferId;
    if (!target) return show({ result: "not_owner" });
    const snooze = action === "snooze" ? helsinkiMorning(until ?? "") : null;
    if (action === "snooze" && !snooze) return show({ snoozeOpenOfferId: target });
    const { data, error } = await supa.rpc("shift_offer_respond_as_staff", {
      p_token: token,
      p_offer_id: target,
      p_response: action,
      p_snooze_until: snooze,
    });
    if (error || !data || typeof data !== "object") {
      log("respond_failed", { error: "rpc" });
      return show({ result: "bad_token" }, 400);
    }
    const row = data as Record<string, unknown>;
    const result = typeof row.result === "string" ? row.result : "bad_token";
    log("responded", { result });
    const again = await loadOpenOffers(supa, token ?? "");
    return show({
      result,
      acted: cardFromRow(row),
      offers: again.ok ? again.offers : open.offers,
    }, result === "bad_token" ? 400 : 200);
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

  const supa = db();
  const { data: cfg } = await supa.from("shift_offer_engine_settings").select("dry_run, sender_enabled").eq("id", true).maybeSingle();
  const dryRun = dryRunRequested(url, body, cfg?.dry_run === true);
  const { data, error } = await supa.rpc("shift_offer_tick", { p_dry_run: dryRun });
  if (error) {
    log("tick_failed", { error: "rpc" });
    return Response.json({ ok: false, error: "tick_failed" }, { status: 500 });
  }
  let sender: unknown = { sender_enabled: false, sent: 0 };
  if (!dryRun && senderDecision(cfg?.sender_enabled === true) === "deliver") {
    sender = await deliverQueued(supa, readWhatsappEnv(Deno.env), log);
  }
  log("tick", { dryRun, actions: Array.isArray((data as { actions?: unknown })?.actions) ? (data as { actions: unknown[] }).actions.length : 0 });
  return Response.json({ ok: true, dryRun, tick: data, sender });
});
