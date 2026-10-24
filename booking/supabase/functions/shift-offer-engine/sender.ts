// Jonon käsittely: varaa rivit, rakenna malli, soita Metalle vain kun kytkimet sallivat.
// Salaisuudet tulevat kutsujalta (WHATSAPP_*). Tätä tiedostoa ei ajeta testeissä verkkoon.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { processInboundMessage, type ActResult, type Intent, type StoreResult } from "./inbound.ts";
import {
  buildSessionPayload,
  classifyHttp,
  handleClaimedMessage,
  handleWebhookRequest,
  messagesUrl,
  postSession,
  type ClaimedMessage,
  type CompleteResult,
  type ParsedInbound,
  type SenderLog,
  type Settings,
  type StatusUpdate,
  type TemplateSettings,
  type WhatsappEnv,
} from "./whatsapp.ts";

export type { WhatsappEnv };

export function readWhatsappEnv(env: { get(name: string): string | undefined }): WhatsappEnv {
  return {
    token: env.get("WHATSAPP_TOKEN") ?? "",
    phoneNumberId: env.get("WHATSAPP_PHONE_NUMBER_ID") ?? "",
    appSecret: env.get("WHATSAPP_APP_SECRET") ?? "",
    verifyToken: env.get("WHATSAPP_VERIFY_TOKEN") ?? "",
  };
}

type ClaimResponse = {
  ok?: boolean;
  sender_enabled?: boolean;
  whatsapp_enabled?: boolean;
  whatsapp_dry_run?: boolean;
  allow_staff_ids?: unknown;
  messages?: unknown;
  templates?: unknown;
  whatsapp_hours_open?: unknown;
};

export type SenderSummary = {
  ok: boolean;
  sender_enabled: boolean;
  whatsapp_enabled?: boolean;
  whatsapp_dry_run?: boolean;
  sent: number;
  dry_run?: number;
  failed_no_contact?: number;
  failed?: number;
  retry?: number;
  released?: number;
  already_sent?: number;
  error?: string;
  transport?: "whatsapp";
};

function asMessage(raw: Record<string, unknown>): ClaimedMessage {
  const num = (v: unknown) => (v == null || v === "" ? null : Number(v));
  return {
    id: Number(raw.id),
    kind: String(raw.kind ?? ""),
    channel: String(raw.channel ?? "none"),
    staff_id: raw.staff_id ? String(raw.staff_id) : null,
    attempts: Number(raw.attempts ?? 0) || 0,
    wamid: raw.wamid ? String(raw.wamid) : null,
    status: String(raw.status ?? "sending"),
    phone_raw: raw.phone_raw == null ? null : String(raw.phone_raw),
    email: raw.email == null ? null : String(raw.email),
    role_type: raw.role_type == null ? null : String(raw.role_type),
    starts_at: raw.starts_at == null ? null : String(raw.starts_at),
    ends_at: raw.ends_at == null ? null : String(raw.ends_at),
    deadline_at: raw.deadline_at == null ? null : String(raw.deadline_at),
    ask_no: num(raw.ask_no),
    ask_count: num(raw.ask_count),
    token: raw.token == null ? null : String(raw.token),
    staff_whatsapp_enabled: raw.staff_whatsapp_enabled === true,
    bot_channel: raw.bot_channel === true,
    subkind: raw.subkind == null ? null : String(raw.subkind),
    body: raw.body == null ? null : String(raw.body),
    session_open: raw.session_open === true,
    page_token: raw.page_token == null ? null : String(raw.page_token),
    digest: raw.digest && typeof raw.digest === "object"
      ? {
        date_label: (raw.digest as Record<string, unknown>).date_label == null ? null : String((raw.digest as Record<string, unknown>).date_label),
        items: (raw.digest as Record<string, unknown>).items == null ? null : String((raw.digest as Record<string, unknown>).items),
      }
      : null,
  };
}

export function readTemplateSettings(raw: unknown): TemplateSettings | undefined {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const out: TemplateSettings = {};
  for (const key of ["offer", "round_reminder", "already_taken", "day_digest"] as const) {
    const v = (raw as Record<string, unknown>)[key];
    if (!v || typeof v !== "object") continue;
    const r = v as Record<string, unknown>;
    out[key] = {
      name: typeof r.name === "string" ? r.name : undefined,
      approved: r.approved === true,
      fallback: typeof r.fallback === "string" ? r.fallback : undefined,
    };
  }
  return out;
}

function tally(summary: SenderSummary, result: CompleteResult) {
  if (result.action === "sent") summary.sent = (summary.sent ?? 0) + 1;
  else if (result.action === "fail_no_contact") summary.failed_no_contact = (summary.failed_no_contact ?? 0) + 1;
  else if (result.action === "fail") summary.failed = (summary.failed ?? 0) + 1;
  else if (result.action === "retry") summary.retry = (summary.retry ?? 0) + 1;
  else if (result.action === "already_sent") summary.already_sent = (summary.already_sent ?? 0) + 1;
  else if (result.action === "release" && result.error === "dry_run") summary.dry_run = (summary.dry_run ?? 0) + 1;
  else if (result.action === "release") summary.released = (summary.released ?? 0) + 1;
}

export async function deliverQueued(
  supa: SupabaseClient,
  env: WhatsappEnv,
  log: SenderLog,
  fetchImpl: typeof fetch = fetch,
  nowMs: () => number = Date.now,
): Promise<SenderSummary> {
  const { data, error } = await supa.rpc("shift_offer_sender_claim", { p_limit: 20 });
  if (error || !data || typeof data !== "object") {
    log("sender_claim_failed", {});
    return { ok: false, sender_enabled: true, sent: 0, error: "claim_failed", transport: "whatsapp" };
  }
  const claim = data as ClaimResponse;
  if (claim.sender_enabled !== true) {
    return { ok: true, sender_enabled: false, sent: 0, transport: "whatsapp" };
  }
  const allow = Array.isArray(claim.allow_staff_ids) ? claim.allow_staff_ids.map((id) => String(id)) : [];
  const settings: Settings = {
    sender_enabled: true,
    whatsapp_enabled: claim.whatsapp_enabled === true,
    whatsapp_dry_run: claim.whatsapp_dry_run !== false,
    allow_staff_ids: allow,
    templates: readTemplateSettings(claim.templates),
    whatsapp_hours_open: claim.whatsapp_hours_open === false ? false : undefined,
  };
  const summary: SenderSummary = {
    ok: true,
    sender_enabled: true,
    whatsapp_enabled: settings.whatsapp_enabled,
    whatsapp_dry_run: settings.whatsapp_dry_run,
    sent: 0,
    dry_run: 0,
    failed_no_contact: 0,
    failed: 0,
    retry: 0,
    released: 0,
    already_sent: 0,
    transport: "whatsapp",
  };
  const messages = Array.isArray(claim.messages) ? claim.messages : [];
  for (const raw of messages) {
    if (!raw || typeof raw !== "object") continue;
    const msg = asMessage(raw as Record<string, unknown>);
    const result = await handleClaimedMessage(msg, settings, env, fetchImpl, log, nowMs());
    tally(summary, result);
    const done = await supa.rpc("shift_offer_sender_complete", { p_result: result });
    if (done.error) log("sender_complete_failed", { message_id: result.id, action: result.action });
  }
  return summary;
}

function asStore(data: unknown): StoreResult | null {
  if (!data || typeof data !== "object") return null;
  const row = data as Record<string, unknown>;
  if (!row.id) return null;
  return {
    id: String(row.id),
    duplicate: row.duplicate === true,
    handled: row.handled === true,
    inboundEnabled: row.inbound_enabled === true,
    staffId: row.staff_id == null ? null : String(row.staff_id),
    replyTo: row.reply_to == null ? null : String(row.reply_to),
  };
}

function asAct(data: unknown): ActResult {
  const row = data && typeof data === "object" ? data as Record<string, unknown> : {};
  const buttons = Array.isArray(row.buttons)
    ? row.buttons.flatMap((raw) => {
      if (!raw || typeof raw !== "object") return [];
      const button = raw as { id?: unknown; title?: unknown };
      if (typeof button.id !== "string" || typeof button.title !== "string") return [];
      return [{ id: button.id, title: button.title }];
    })
    : [];
  return {
    replyBody: typeof row.reply_body === "string" ? row.reply_body : null,
    buttons,
    shiftId: row.shift_id == null ? null : String(row.shift_id),
    suppressed: row.suppressed === true,
  };
}

// Tallentaa saapuvan viestin aina. Vastaus vain jos whatsapp_inbound_enabled ja numero on henkilöstöä.
// Tuntematon numero ei aiheuta Graph-kutsua. Lokissa ei ole numeroa, tekstiä eikä salaisuutta.
export async function deliverInbound(
  supa: SupabaseClient,
  env: WhatsappEnv,
  message: ParsedInbound,
  log: SenderLog,
  fetchImpl: typeof fetch = fetch,
): Promise<void> {
  await processInboundMessage(message, {
    async store(inbound) {
      const { data, error } = await supa.rpc("whatsapp_store_inbound", {
        p_wamid: inbound.wamid,
        p_from: inbound.from,
        p_received_at: inbound.at,
        p_message_type: inbound.type,
        p_text: inbound.text,
        p_button_id: inbound.buttonId,
      });
      if (error) {
        log("whatsapp_inbound_failed", { step: "store" });
        throw new Error("inbound_store_failed");
      }
      return asStore(data);
    },
    async act(messageId, intent: Intent) {
      const { data, error } = await supa.rpc("whatsapp_inbound_act", {
        p_message_id: messageId,
        p_intent: intent,
      });
      if (error) {
        log("whatsapp_inbound_failed", { step: "act" });
        throw new Error("inbound_act_failed");
      }
      return asAct(data);
    },
    async send(to, body, buttons) {
      const payload = buildSessionPayload(to, body, buttons);
      if (!payload || !env.token || !messagesUrl(env.phoneNumberId)) {
        log("whatsapp_inbound_missing_credentials", {});
        return { ok: false, wamid: null };
      }
      let http: { status: number; wamid: string | null };
      try {
        http = await postSession(env, payload, fetchImpl);
      } catch {
        log("whatsapp_inbound_send_failed", { status: 0 });
        throw new Error("inbound_send_retry");
      }
      if (classifyHttp(http.status) === "retry") {
        log("whatsapp_inbound_send_failed", { status: http.status });
        throw new Error("inbound_send_retry");
      }
      if (classifyHttp(http.status) !== "ok" || !http.wamid) {
        log("whatsapp_inbound_send_failed", { status: http.status });
        return { ok: false, wamid: null };
      }
      return { ok: true, wamid: http.wamid };
    },
    async markHandled(messageId, intentOp) {
      const { error } = await supa.rpc("whatsapp_mark_handled", {
        p_message_id: messageId,
        p_by: "shift-offer-engine",
        p_intent: intentOp,
      });
      if (error) {
        log("whatsapp_inbound_failed", { step: "handled" });
        throw new Error("inbound_handled_failed");
      }
    },
    async welcome(messageId) {
      const { data, error } = await supa.schema("booking").rpc("shift_staff_welcome", { p_message_id: messageId });
      if (error || !data || typeof data !== "object") {
        if (error) log("whatsapp_inbound_failed", { step: "welcome" });
        return { send: false, body: null };
      }
      const row = data as Record<string, unknown>;
      return { send: row.send === true, body: typeof row.body === "string" ? row.body : null };
    },
    async storeOutbound(record) {
      const { error } = await supa.rpc("whatsapp_store_outbound", {
        p_staff_id: record.staffId,
        p_phone: record.phone,
        p_text: record.text,
        p_wamid: record.wamid,
        p_shift_id: record.shiftId,
      });
      if (error) log("whatsapp_inbound_failed", { step: "outbound" });
    },
    log,
  });
}

export function webhookResponse(
  req: Request,
  env: WhatsappEnv,
  apply: (update: StatusUpdate) => Promise<void>,
  onMessage?: (message: ParsedInbound) => Promise<void>,
): Promise<Response> {
  return handleWebhookRequest(req, env, apply, onMessage);
}
