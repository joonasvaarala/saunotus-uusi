// shift-offer-engine: vapaiden vuorojen tarjoaminen (SPEC.md).
// EI deployata tästä haarasta. EI lähetä viestejä. EI aja migraatioita.
//
// Autentikointi:
//   * tick (POST ilman tokenia): header x-sync-secret = env SYNC_CRON_SECRET (vakioaikavertailu)
//   * vastauslinkki (GET ?token=): 302 sivulle SHIFT_OFFER_PAGE_BASE/vuoro/?token= (oletus GitHub Pages).
//     Sivu hakee JSON:n GET /api/offers ja kirjaa vastauksen POST /api/respond.
//     HMAC-token tarkistetaan tietokannassa (shift_offer_verify_token). Avain on vain vault-salaisuus
//     shift_offer_token_secret. Edge-funktiolla ei ole omaa avainta. GET ei muuta rivejä.
//   * tietokanta: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY
// Kuivaharjoitus: ?dry_run=1 tai JSON {"dryRun":true} tai shift_offer_engine_settings.dry_run.
// Lähettäjä: sender_enabled oletus false (jono jää queued).
// WhatsApp: whatsapp_enabled oletus false, whatsapp_dry_run oletus true, allowlist tyhjä.
// Henkilö saa WhatsAppin vain jos staff.whatsapp_enabled on päällä ja numero normalisoituu.
// Joonas ja Otto eivät saa WhatsAppia: rivi jää kanavalle bot, tilaan bot_channel.
// Oikea lähetys vaatii kaikki kytkimet ja allowlistan. Kuivaharjoitus lokittaa peitetyn rungon eikä kutsu Metan.
// sending ilman wamidia ei palaa jonoon: 10 min jälkeen tila on unknown (tarkistetaan käsin).
// Webhook: GET/POST /webhook (WHATSAPP_VERIFY_TOKEN, X-Hub-Signature-256 / WHATSAPP_APP_SECRET).
// Saapuva viesti tallennetaan aina public.whatsapp_messages-tauluun. Itsepalveluvastaus vain jos
// whatsapp_inbound_enabled (oletus false). Tuntemattomalle numerolle ei vastata. Tarjousmallit eivät muutu.
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
// booking_153: oma sivu GET /api/my?token= ja POST /api/my/respond (mypage.ts). Saman päivän kooste,
// kierroksen loppumuistutus ja "jo mennyt" -viesti käyttävät pohjia vain, kun shift_offer.wa_templates
// merkitsee ne hyväksytyiksi; muuten vapaamuotoinen viesti 24 h ikkunassa tai sähköposti. WhatsApp vain 08–21.
// Tervetuloviesti henkilökunnan ensimmäiseen viestiin: booking.shift_staff_welcome (asetus, oletus pois).
//
// Token-avain (ei repoissa, ei edge-ympäristössä): vault-salaisuus shift_offer_token_secret.
// Kuivaharjoitus käsin: sama kutsu, body {"dryRun":true} tai ?dry_run=1.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { handleOfferRequest, type OfferDb } from "./api.ts";
import {
  dryRunRequested,
  secretMatches,
  senderDecision,
  shiftRoute,
  type TickBody,
} from "./core.ts";
import { handleMyPageRequest, myRoute, type MyPageDb } from "./mypage.ts";
import { deliverInbound, deliverQueued, readWhatsappEnv, webhookResponse } from "./sender.ts";

function db(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function offerDb(supa: SupabaseClient): OfferDb {
  return {
    async rpc(name, args) {
      const { data, error } = await supa.rpc(name, args);
      return { data, error };
    },
  };
}

// booking_153: oma sivu käyttää booking-skeeman funktioita (vain service_role).
function myPageDb(supa: SupabaseClient): MyPageDb {
  return {
    async rpc(name, args) {
      const { data, error } = await supa.schema("booking").rpc(name, args);
      return { data, error };
    },
  };
}

const log = (event: string, data: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ fn: "shift-offer-engine", event, ...data }));

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
    }, async (message) => {
      await deliverInbound(supa, env, message, log);
    });
  }
  if (myRoute(req.method, url.pathname)) return handleMyPageRequest(req, myPageDb(db()));
  const token = url.searchParams.get("token");
  const route = shiftRoute(req.method, url.pathname, token);
  if (route === "invalid") return new Response("method not allowed", { status: 405 });
  if (route !== "tick") {
    const res = await handleOfferRequest(req, offerDb(db()), Deno.env.get("SHIFT_OFFER_PAGE_BASE"));
    if (route === "respond") {
      const copy = res.clone();
      const body = await copy.json().catch(() => null);
      const result = body && typeof body === "object" ? (body as { result?: unknown }).result : null;
      if (typeof result === "string") log("responded", { result });
    }
    return res;
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
