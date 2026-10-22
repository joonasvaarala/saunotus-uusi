// Jonon käsittely: varaa rivit, rakenna malli, soita Metalle vain kun kytkimet sallivat.
// Salaisuudet tulevat kutsujalta (WHATSAPP_*). Tätä tiedostoa ei ajeta testeissä verkkoon.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  handleClaimedMessage,
  handleWebhookRequest,
  type ClaimedMessage,
  type CompleteResult,
  type SenderLog,
  type Settings,
  type StatusUpdate,
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
  };
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

export function webhookResponse(
  req: Request,
  env: WhatsappEnv,
  apply: (update: StatusUpdate) => Promise<void>,
): Promise<Response> {
  return handleWebhookRequest(req, env, apply);
}
