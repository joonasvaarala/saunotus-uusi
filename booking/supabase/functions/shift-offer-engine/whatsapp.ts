// WhatsApp Cloud API -sovitin vuorotarjousjonolle. Ei lue Deno.env:iä eikä soita verkkoon
// itse: kutsuja antaa fetchin ja salaisuudet. Oikea lähetys vaatii kytkimet, allowlistan,
// staff.whatsapp_enabled ja whatsapp_dry_run = false. Kuivaharjoitus lokittaa peitetyn
// JSON-rungon eikä kutsu Metan rajapintaa. Puhelinnumero ja vastauspoletti eivät jää lokiin
// eikä last_payloadiin. Metalle lähtevä runko on peittämätön.

import { secretMatches, timingSafeEqual } from "./core.ts";

export const GRAPH_API_VERSION = "v25.0";
export const TEMPLATE_LANGUAGE = "fi";
export const MAX_SEND_ATTEMPTS = 8;

export const KIND_TEMPLATE = {
  offer: "vuorotarjous",
  reminder: "vuorotarjous",
  filled: "vuoro_taytetty",
  cancelled: "tarjous_peruttu",
  exhausted_ask: "joonas_tyhja_vuoro",
  alert: "joonas_tyhja_vuoro",
} as const;

export type MessageKind = keyof typeof KIND_TEMPLATE;
export type TemplateName = (typeof KIND_TEMPLATE)[MessageKind];

const BUTTON_TEMPLATES = new Set<TemplateName>(["vuorotarjous", "joonas_tyhja_vuoro"]);

export type TextParam = { type: "text"; text: string };
export type BodyComponent = { type: "body"; parameters: TextParam[] };
export type ButtonComponent = {
  type: "button";
  sub_type: "url";
  index: "0";
  parameters: TextParam[];
};
export type TemplatePayload = {
  messaging_product: "whatsapp";
  recipient_type: "individual";
  to: string;
  type: "template";
  template: {
    // booking_153: nimi voi tulla asetuksesta (shift_offer.wa_templates), esim. tyovuoro_kysely.
    name: TemplateName | string;
    language: { code: typeof TEMPLATE_LANGUAGE };
    components: Array<BodyComponent | ButtonComponent>;
  };
};

export type ClaimedMessage = {
  id: number;
  kind: string;
  channel: string;
  staff_id: string | null;
  attempts: number;
  wamid: string | null;
  status: string;
  phone_raw: string | null;
  email: string | null;
  role_type: string | null;
  starts_at: string | null;
  ends_at: string | null;
  deadline_at: string | null;
  ask_no: number | null;
  ask_count: number | null;
  token: string | null;
  staff_whatsapp_enabled: boolean;
  bot_channel: boolean;
  // booking_153 (valinnaiset; vanha claim ei anna näitä → vanha käytös)
  subkind?: string | null;
  body?: string | null;
  session_open?: boolean;
  page_token?: string | null;
  digest?: { date_label?: string | null; items?: string | null } | null;
};

// booking_153: Metan pohjat asetuksesta shift_offer.wa_templates. Pohjaa käytetään vain, kun approved = true.
export type TemplateSetting = { name?: string; approved?: boolean; fallback?: string };
export type TemplateSettings = {
  offer?: TemplateSetting;
  round_reminder?: TemplateSetting;
  already_taken?: TemplateSetting;
  day_digest?: TemplateSetting;
};

export type Settings = {
  sender_enabled: boolean;
  whatsapp_enabled: boolean;
  whatsapp_dry_run: boolean;
  allow_staff_ids: string[];
  templates?: TemplateSettings;
  // booking_153 (d): WhatsApp vain 08–21 Europe/Helsinki. false = ei lähetetä nyt.
  whatsapp_hours_open?: boolean;
};

export type WhatsappEnv = {
  token: string;
  phoneNumberId: string;
  appSecret: string;
  verifyToken: string;
};

export type CompleteResult = {
  id: number;
  action: "sent" | "retry" | "fail" | "fail_no_contact" | "release" | "already_sent" | "bot_channel";
  channel?: "whatsapp" | "email" | "none";
  to?: string | null;
  wamid?: string | null;
  error?: string | null;
  retry_at?: string | null;
  attempts?: number;
  payload?: TemplatePayload | SessionPayload | null;
};

export type Plan =
  | { action: "already_sent" }
  | { action: "fail_no_contact" }
  | { action: "fail"; error: string }
  | {
    action: "release";
    reason: string;
    channel: "whatsapp" | "email" | "none";
    to: string | null;
    payload: TemplatePayload | SessionPayload | null;
    delayMinutes: number;
  }
  | { action: "send"; payload: TemplatePayload | SessionPayload; to: string }
  | { action: "bot_channel" };

const TERMINAL = new Set(["sent", "delivered", "read", "failed", "failed_no_contact", "skipped", "unknown", "bot_channel"]);

// Tuotannon staff.id. Vuoroviestit näille kahdelle eivät lähde WhatsAppiin, vaikka lippu olisi päällä.
export const BOT_STAFF_IDS = [
  "5ab2ba62-97b2-4712-b500-a47a898036a5",
  "2975633f-c53f-48d6-8a38-41cae0be5a83",
] as const;

export function isBotStaff(msg: { staff_id: string | null; bot_channel?: boolean }): boolean {
  if (msg.bot_channel) return true;
  const id = msg.staff_id?.toLowerCase();
  return !!id && BOT_STAFF_IDS.some((known) => known === id);
}
export const STALE_SEND_LOCK_MS = 10 * 60 * 1000;
const enc = new TextEncoder();

// 040…, 00358…, 358… ja +358… → E.164. Vain suomalaiset matkapuhelimet (4… tai 50…).
export function normalizeFinnishPhone(input: unknown): string | null {
  let s = String(input ?? "").trim().replace(/[\s\-().]/g, "");
  if (!s) return null;
  if (s.startsWith("00")) s = `+${s.slice(2)}`;
  let digits: string;
  if (s.startsWith("+")) digits = s.slice(1);
  else if (s.startsWith("0")) digits = `358${s.slice(1)}`;
  else if (s.startsWith("358")) digits = s;
  else return null;
  if (!/^\d+$/.test(digits) || !digits.startsWith("358")) return null;
  const national = digits.slice(3);
  if (national.length < 6 || national.length > 12) return null;
  if (!(national.startsWith("4") || national.startsWith("50"))) return null;
  return `+${digits}`;
}

// +358401234567 → +358*******67. Tähtiä sisältävä arvo jätetään, jotta peitto on idempotentti.
export function maskPhoneE164(phone: string): string {
  if (!phone) return "***";
  if (phone.includes("*")) return phone;
  if (phone.length < 6) return "***";
  return `${phone.slice(0, 4)}${"*".repeat(phone.length - 6)}${phone.slice(-2)}`;
}

export function redactTemplatePayload(payload: TemplatePayload): TemplatePayload;
export function redactTemplatePayload(payload: SessionPayload): SessionPayload;
export function redactTemplatePayload(payload: TemplatePayload | SessionPayload): TemplatePayload | SessionPayload;
export function redactTemplatePayload(payload: TemplatePayload | SessionPayload): TemplatePayload | SessionPayload {
  if (payload.type !== "template") return redactSessionPayload(payload);
  return {
    ...payload,
    to: maskPhoneE164(payload.to),
    template: {
      ...payload.template,
      components: payload.template.components.map((component) => {
        if (component.type !== "button") return component;
        return {
          ...component,
          parameters: component.parameters.map((param) => ({ ...param, text: "***" })),
        };
      }),
    },
  };
}

// Istuntoviestin teksti sisältää linkkipoletteja: ne peitetään ennen lokia ja last_payloadia.
export function redactSessionPayload(payload: SessionPayload): SessionPayload {
  const hide = (text: string) => text.replace(/token=[^&\s]+/g, "token=***");
  if (payload.type === "text") {
    return { ...payload, to: maskPhoneE164(payload.to), text: { ...payload.text, body: hide(payload.text.body) } };
  }
  return {
    ...payload,
    to: maskPhoneE164(payload.to),
    interactive: { ...payload.interactive, body: { text: hide(payload.interactive.body.text) } },
  };
}

// Sama sääntö kuin shift_offer_sender_claim: vanha sending-lukko ilman wamidia ei palaa jonoon.
export function staleSendingResolution(
  status: string,
  wamid: string | null,
  lockedAtMs: number | null,
  nowMs: number,
): "unknown" | "leave" {
  if (status !== "sending" || wamid || lockedAtMs == null) return "leave";
  if (nowMs - lockedAtMs < STALE_SEND_LOCK_MS) return "leave";
  return "unknown";
}

export function messagesUrl(phoneNumberId: string): string | null {
  if (!/^\d{5,}$/.test(phoneNumberId)) return null;
  return `https://graph.facebook.com/${GRAPH_API_VERSION}/${phoneNumberId}/messages`;
}

export function roleLabel(role: string | null): string {
  if (role === "heater") return "lämmitysvuoro";
  if (role === "reception") return "vastaanottovuoro";
  if (role === "therapist") return "hoitajavuoro";
  return "vuoro";
}

export function askLabel(kind: string, askNo: number | null, askCount: number | null): string {
  if (kind === "alert") return "hälytys";
  return `${askNo ?? 1}/${askCount ?? 3}`;
}

export function templateText(value: string): string {
  const s = value.replace(/[\r\n\t]+/g, " ").replace(/ {2,}/g, " ").trim();
  return (s || "–").slice(0, 900);
}

const WD = ["su", "ma", "ti", "ke", "to", "pe", "la"];

function helsinkiWall(iso: string): { y: number; m: number; d: number; hh: string; mi: string } | null {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Helsinki",
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
  const parts = fmt.formatToParts(date);
  const pick = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const y = Number(pick("year"));
  const m = Number(pick("month"));
  const d = Number(pick("day"));
  if (!y || !m || !d) return null;
  const hour = pick("hour") === "24" ? "00" : pick("hour");
  return { y, m, d, hh: hour, mi: pick("minute") };
}

export function formatShiftWhen(startsAt: string | null, endsAt: string | null): string {
  if (!startsAt) return "ajankohta puuttuu";
  const start = helsinkiWall(startsAt);
  if (!start) return "ajankohta puuttuu";
  const wd = WD[new Date(Date.UTC(start.y, start.m - 1, start.d)).getUTCDay()];
  const date = `${String(start.d).padStart(2, "0")}.${String(start.m).padStart(2, "0")}.${start.y}`;
  let clock = `${start.hh}:${start.mi}`;
  if (endsAt) {
    const end = helsinkiWall(endsAt);
    if (end) clock += `–${end.hh}:${end.mi}`;
  }
  return `${wd} ${date} klo ${clock}`;
}

export function formatDeadline(deadlineAt: string | null): string {
  if (!deadlineAt) return "pian";
  const w = helsinkiWall(deadlineAt);
  if (!w) return "pian";
  return `${String(w.d).padStart(2, "0")}.${String(w.m).padStart(2, "0")}.${w.y} klo ${w.hh}:${w.mi}`;
}

export function templateForKind(kind: string): TemplateName | null {
  if (kind in KIND_TEMPLATE) return KIND_TEMPLATE[kind as MessageKind];
  return null;
}

export function buildTemplatePayload(msg: ClaimedMessage, phoneE164: string): TemplatePayload | null {
  const name = templateForKind(msg.kind);
  if (!name) return null;
  const when = templateText(formatShiftWhen(msg.starts_at, msg.ends_at));
  const role = templateText(roleLabel(msg.role_type));
  const body: TextParam[] = name === "joonas_tyhja_vuoro"
    ? [
      { type: "text", text: role },
      { type: "text", text: when },
      { type: "text", text: templateText(askLabel(msg.kind, msg.ask_no, msg.ask_count)) },
    ]
    : name === "vuorotarjous"
    ? [
      { type: "text", text: role },
      { type: "text", text: when },
      { type: "text", text: templateText(formatDeadline(msg.deadline_at)) },
    ]
    : [
      { type: "text", text: role },
      { type: "text", text: when },
    ];
  const components: Array<BodyComponent | ButtonComponent> = [{ type: "body", parameters: body }];
  if (BUTTON_TEMPLATES.has(name)) {
    if (!msg.token) return null;
    components.push({
      type: "button",
      sub_type: "url",
      index: "0",
      parameters: [{ type: "text", text: msg.token }],
    });
  }
  return {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: phoneE164,
    type: "template",
    template: { name, language: { code: TEMPLATE_LANGUAGE }, components },
  };
}

// booking_153: mikä pohja viestille. "legacy" = vanha KIND_TEMPLATE-käytös (ei pohja-asetuksia tai
// vanha viestilaji), "session" = ei hyväksyttyä pohjaa → vapaamuotoinen viesti 24 h ikkunassa tai sähköposti.
export type TemplateChoice =
  | { kind: "legacy" }
  | { kind: "template"; name: string; params: string[]; buttonToken: string | null; needsButton: boolean }
  | { kind: "session" };

const NOTICE_SUBKINDS = /^(vacant|th_)/;

export function resolveTemplate(msg: ClaimedMessage, templates: TemplateSettings | undefined): TemplateChoice {
  if (!templates) return { kind: "legacy" };
  const role = templateText(roleLabel(msg.role_type));
  const when = templateText(formatShiftWhen(msg.starts_at, msg.ends_at));
  const deadline = templateText(formatDeadline(msg.deadline_at));
  const sub = msg.subkind ?? null;
  const approved = (t: TemplateSetting | undefined) => !!t && t.approved === true && !!t.name && /^[a-z0-9_]+$/.test(t.name);
  if (sub === "round_reminder") {
    const t = templates.round_reminder;
    return approved(t) ? { kind: "template", name: t!.name!, params: [role, when, deadline], buttonToken: msg.token, needsButton: true } : { kind: "session" };
  }
  if (sub === "already_taken") {
    const t = templates.already_taken;
    return approved(t) ? { kind: "template", name: t!.name!, params: [role, when], buttonToken: null, needsButton: false } : { kind: "session" };
  }
  if (sub === "day_digest") {
    const t = templates.day_digest;
    const date = templateText(msg.digest?.date_label ?? "");
    const items = templateText(msg.digest?.items ?? "");
    return approved(t) ? { kind: "template", name: t!.name!, params: [date, items], buttonToken: msg.page_token ?? null, needsButton: true } : { kind: "session" };
  }
  if (sub && NOTICE_SUBKINDS.test(sub)) return { kind: "session" };
  if (msg.kind === "offer" || msg.kind === "reminder") {
    const t = templates.offer;
    const fallback = t?.fallback && /^[a-z0-9_]+$/.test(t.fallback) ? t.fallback : KIND_TEMPLATE.offer;
    const name = approved(t) ? t!.name! : fallback;
    return { kind: "template", name, params: [role, when, deadline], buttonToken: msg.token, needsButton: true };
  }
  return { kind: "legacy" };
}

export function buildChosenTemplate(choice: Extract<TemplateChoice, { kind: "template" }>, phoneE164: string): TemplatePayload | null {
  const components: Array<BodyComponent | ButtonComponent> = [
    { type: "body", parameters: choice.params.map((text) => ({ type: "text", text: templateText(text) })) },
  ];
  if (choice.needsButton) {
    if (!choice.buttonToken) return null;
    components.push({ type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: choice.buttonToken }] });
  }
  return {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: phoneE164,
    type: "template",
    template: { name: choice.name, language: { code: TEMPLATE_LANGUAGE }, components },
  };
}

function allowlisted(settings: Settings, staffId: string | null): boolean {
  if (!staffId) return false;
  const want = staffId.toLowerCase();
  return settings.allow_staff_ids.some((id) => id.toLowerCase() === want);
}

function release(
  reason: string,
  channel: "whatsapp" | "email" | "none",
  to: string | null,
  payload: TemplatePayload | SessionPayload | null,
  delayMinutes: number,
): Plan {
  return { action: "release", reason, channel, to, payload, delayMinutes };
}

export function planMessage(msg: ClaimedMessage, settings: Settings): Plan {
  if (msg.wamid || TERMINAL.has(msg.status) || msg.status !== "sending") return { action: "already_sent" };
  if (isBotStaff(msg) || msg.channel === "bot") return { action: "bot_channel" };
  const phone = normalizeFinnishPhone(msg.phone_raw);
  const email = msg.email?.trim() || null;
  if (!phone && !email) return { action: "fail_no_contact" };
  if (!phone) return release("email_pending", "email", email, null, 360);
  if (!msg.staff_whatsapp_enabled) return release("staff_whatsapp_disabled", "whatsapp", phone, null, 15);
  if (!settings.whatsapp_enabled) return release("whatsapp_disabled", "whatsapp", phone, null, 15);
  if (!allowlisted(settings, msg.staff_id)) return release("not_allowlisted", "whatsapp", phone, null, 15);
  if (settings.whatsapp_hours_open === false) return release("quiet_hours", "whatsapp", phone, null, 30);
  const choice = resolveTemplate(msg, settings.templates);
  if (choice.kind === "session") {
    // Ei hyväksyttyä pohjaa: vapaamuotoinen viesti vain avoimessa 24 h ikkunassa, muuten sähköposti (tai odotus).
    const session = msg.session_open && msg.body ? buildSessionPayload(phone, msg.body) : null;
    if (!session) return release("template_not_approved", email ? "email" : "whatsapp", email ?? phone, null, 360);
    if (!settings.sender_enabled) return release("sender_disabled", "whatsapp", phone, null, 15);
    if (settings.whatsapp_dry_run) return release("dry_run", "whatsapp", phone, session, 15);
    return { action: "send", payload: session, to: phone };
  }
  if (choice.kind === "template") {
    const chosen = buildChosenTemplate(choice, phone);
    if (!chosen) return release("no_token", "whatsapp", phone, null, 60);
    if (!settings.sender_enabled) return release("sender_disabled", "whatsapp", phone, null, 15);
    if (settings.whatsapp_dry_run) return release("dry_run", "whatsapp", phone, chosen, 15);
    return { action: "send", payload: chosen, to: phone };
  }
  const payload = buildTemplatePayload(msg, phone);
  if (!payload) {
    if (!templateForKind(msg.kind)) return { action: "fail", error: "unknown_kind" };
    return release("no_token", "whatsapp", phone, null, 60);
  }
  if (!settings.sender_enabled) return release("sender_disabled", "whatsapp", phone, null, 15);
  if (settings.whatsapp_dry_run) return release("dry_run", "whatsapp", phone, payload, 15);
  return { action: "send", payload, to: phone };
}

function isoAfter(nowMs: number, minutes: number): string {
  return new Date(nowMs + minutes * 60_000).toISOString();
}

function fromPlan(msg: ClaimedMessage, plan: Plan, nowMs: number): CompleteResult {
  if (plan.action === "bot_channel") return { id: msg.id, action: "bot_channel", to: null, payload: null };
  if (plan.action === "already_sent") return { id: msg.id, action: "already_sent" };
  if (plan.action === "fail_no_contact") {
    return { id: msg.id, action: "fail_no_contact", channel: "none", to: null, error: "no_phone", payload: null };
  }
  if (plan.action === "fail") {
    return { id: msg.id, action: "fail", channel: "whatsapp", to: normalizeFinnishPhone(msg.phone_raw), error: plan.error, payload: null };
  }
  if (plan.action === "release") {
    return {
      id: msg.id,
      action: "release",
      channel: plan.channel,
      to: plan.to,
      error: plan.reason,
      retry_at: isoAfter(nowMs, plan.delayMinutes),
      payload: plan.payload ? redactTemplatePayload(plan.payload) : null,
    };
  }
  return { id: msg.id, action: "already_sent" };
}

export function classifyHttp(status: number): "ok" | "retry" | "fail" {
  if (status >= 200 && status < 300) return "ok";
  if (status === 429 || status >= 500) return "retry";
  if (status >= 400 && status < 500) return "fail";
  return "retry";
}

export function retryPlan(attempts: number, nowMs: number): { retry: boolean; attempts: number; retryAt: string } {
  const next = attempts + 1;
  const minutes = Math.min(360, next * next);
  return { retry: next < MAX_SEND_ATTEMPTS, attempts: next, retryAt: isoAfter(nowMs, minutes) };
}

export function readSendResponse(status: number, body: string): { wamid: string | null; error: string | null } {
  let json: unknown = null;
  try {
    json = JSON.parse(body);
  } catch {
    json = null;
  }
  const messages = json && typeof json === "object" && json && "messages" in json
    ? (json as { messages?: unknown }).messages
    : null;
  const first = Array.isArray(messages) ? messages[0] : null;
  const id = first && typeof first === "object" && first && "id" in first ? (first as { id?: unknown }).id : null;
  const err = json && typeof json === "object" && json && "error" in json
    ? (json as { error?: { message?: unknown; code?: unknown } }).error
    : null;
  const error = err && typeof err === "object"
    ? `${err.code ?? ""} ${typeof err.message === "string" ? err.message : ""}`.trim().slice(0, 500)
    : status >= 400 ? body.slice(0, 300) : null;
  return { wamid: typeof id === "string" && id ? id : null, error: error || null };
}

export async function postTemplate(
  env: WhatsappEnv,
  payload: TemplatePayload,
  fetchImpl: typeof fetch,
): Promise<{ status: number; wamid: string | null; error: string | null }> {
  const url = messagesUrl(env.phoneNumberId);
  if (!url || !env.token) return { status: 0, wamid: null, error: "missing_credentials" };
  const res = await fetchImpl(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  return { status: res.status, ...readSendResponse(res.status, text) };
}

export type SenderLog = (event: string, data: Record<string, unknown>) => void;

export async function handleClaimedMessage(
  msg: ClaimedMessage,
  settings: Settings,
  env: WhatsappEnv,
  fetchImpl: typeof fetch,
  log: SenderLog,
  nowMs: number,
): Promise<CompleteResult> {
  if (msg.wamid || TERMINAL.has(msg.status) || msg.status !== "sending") {
    return { id: msg.id, action: "already_sent" };
  }
  const plan = planMessage(msg, settings);
  if (plan.action === "release" && plan.reason === "dry_run" && plan.payload) {
    log("whatsapp_dry_run", {
      message_id: msg.id,
      url: messagesUrl(env.phoneNumberId) ??
        `https://graph.facebook.com/${GRAPH_API_VERSION}/{WHATSAPP_PHONE_NUMBER_ID}/messages`,
      body: redactTemplatePayload(plan.payload),
    });
  }
  if (plan.action !== "send") return fromPlan(msg, plan, nowMs);
  if (!env.token || !messagesUrl(env.phoneNumberId)) {
    log("whatsapp_missing_credentials", { message_id: msg.id, body: redactTemplatePayload(plan.payload) });
    return fromPlan(msg, release("missing_credentials", "whatsapp", plan.to, plan.payload, 30), nowMs);
  }
  // Synkroninen varaus ennen ensimmäistä awaitia: sama olio ei lähde kahdesti.
  msg.wamid = "pending";
  let http: { status: number; wamid: string | null; error: string | null };
  try {
    http = plan.payload.type === "template"
      ? await postTemplate(env, plan.payload, fetchImpl)
      : await postSession(env, plan.payload, fetchImpl);
  } catch {
    msg.wamid = null;
    const again = retryPlan(msg.attempts, nowMs);
    if (!again.retry) {
      msg.status = "failed";
      return { id: msg.id, action: "fail", channel: "whatsapp", to: plan.to, error: "network", attempts: again.attempts, payload: redactTemplatePayload(plan.payload) };
    }
    return {
      id: msg.id,
      action: "retry",
      channel: "whatsapp",
      to: plan.to,
      error: "network",
      retry_at: again.retryAt,
      attempts: again.attempts,
      payload: redactTemplatePayload(plan.payload),
    };
  }
  const httpClass = classifyHttp(http.status);
  const kind = httpClass === "ok" && http.wamid ? "ok" : httpClass === "ok" ? "retry" : httpClass;
  if (kind === "ok" && http.wamid) {
    msg.wamid = http.wamid;
    msg.status = "sent";
    return {
      id: msg.id,
      action: "sent",
      channel: "whatsapp",
      to: plan.to,
      wamid: http.wamid,
      error: null,
      attempts: msg.attempts + 1,
      payload: redactTemplatePayload(plan.payload),
    };
  }
  msg.wamid = null;
  if (kind === "fail") {
    msg.status = "failed";
    return {
      id: msg.id,
      action: "fail",
      channel: "whatsapp",
      to: plan.to,
      error: http.error ?? `http_${http.status}`,
      attempts: msg.attempts + 1,
      payload: redactTemplatePayload(plan.payload),
    };
  }
  const again = retryPlan(msg.attempts, nowMs);
  if (!again.retry) {
    msg.status = "failed";
    return {
      id: msg.id,
      action: "fail",
      channel: "whatsapp",
      to: plan.to,
      error: http.error ?? `http_${http.status}`,
      attempts: again.attempts,
      payload: redactTemplatePayload(plan.payload),
    };
  }
  return {
    id: msg.id,
    action: "retry",
    channel: "whatsapp",
    to: plan.to,
    error: http.error ?? `http_${http.status}`,
    retry_at: again.retryAt,
    attempts: again.attempts,
    payload: redactTemplatePayload(plan.payload),
  };
}

// Sama järjestys kuin shift_offer_whatsapp_apply_status: read, failed_no_contact, failed ja unknown
// eivät peruudu. failed ei nouse delivered/readiksi, sent < delivered < read.
export function nextOutboxStatus(current: string, incoming: "sent" | "delivered" | "read" | "failed"): string | null {
  if (current === "read" || current === "failed_no_contact" || current === "failed" || current === "unknown") return null;
  if (incoming === "failed") return "failed";
  if (incoming === "read") return "read";
  if (incoming === "delivered" && (current === "queued" || current === "sending" || current === "sent")) return "delivered";
  if (incoming === "sent" && (current === "queued" || current === "sending")) return "sent";
  return null;
}

export function lockForSend<T extends { id: number; status: string; wamid: string | null }>(rows: T[], id: number): T | null {
  const row = rows.find((r) => r.id === id);
  if (!row || row.wamid || row.status !== "queued") return null;
  row.status = "sending";
  return row;
}

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function webhookSignatureHex(secret: string, raw: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const data = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
  const sig = await crypto.subtle.sign("HMAC", key, data);
  return toHex(sig);
}

export async function verifyHubSignature(secret: string, raw: Uint8Array, header: string | null): Promise<boolean> {
  if (!secret || !header) return false;
  const expected = `sha256=${await webhookSignatureHex(secret, raw)}`;
  return timingSafeEqual(expected, header.trim());
}

export async function readChallenge(params: URLSearchParams, expected: string): Promise<string | null> {
  if (params.get("hub.mode") !== "subscribe") return null;
  const challenge = params.get("hub.challenge");
  if (!challenge) return null;
  const got = params.get("hub.verify_token") ?? "";
  if (!(await secretMatches(got, expected))) return null;
  return challenge;
}

export type StatusUpdate = {
  wamid: string;
  status: "sent" | "delivered" | "read" | "failed";
  error: string | null;
  at: string | null;
};

export type ParsedInbound = {
  wamid: string;
  from: string;
  type: string;
  text: string | null;
  buttonId: string | null;
  at: string | null;
};

export type ReplyButton = { id: string; title: string };

export type SessionPayload =
  | {
    messaging_product: "whatsapp";
    recipient_type: "individual";
    to: string;
    type: "text";
    text: { body: string; preview_url: false };
  }
  | {
    messaging_product: "whatsapp";
    recipient_type: "individual";
    to: string;
    type: "interactive";
    interactive: {
      type: "button";
      body: { text: string };
      action: { buttons: Array<{ type: "reply"; reply: { id: string; title: string } }> };
    };
  };

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function inboundText(raw: Record<string, unknown>): { type: string; text: string | null; buttonId: string | null } {
  const type = typeof raw.type === "string" && raw.type ? raw.type.slice(0, 32) : "unknown";
  if (type === "text") {
    const text = asRecord(raw.text);
    return { type, text: typeof text?.body === "string" ? text.body : "", buttonId: null };
  }
  if (type === "button") {
    const button = asRecord(raw.button);
    return {
      type,
      text: typeof button?.text === "string" ? button.text : "",
      buttonId: typeof button?.payload === "string" ? button.payload : null,
    };
  }
  if (type === "interactive") {
    const interactive = asRecord(raw.interactive);
    const button = asRecord(interactive?.button_reply) ?? asRecord(interactive?.list_reply);
    return {
      type,
      text: typeof button?.title === "string" ? button.title : "",
      buttonId: typeof button?.id === "string" ? button.id : null,
    };
  }
  return { type, text: null, buttonId: null };
}

// Saapuvat viestit. Statukset ovat parseWebhookStatuses-funktiossa. Ei lokita numeroa eikä tekstiä.
export function parseWebhookMessages(body: unknown): ParsedInbound[] {
  const root = asRecord(body);
  if (!root || !Array.isArray(root.entry)) return [];
  const out: ParsedInbound[] = [];
  for (const entry of root.entry) {
    const changes = asRecord(entry)?.changes;
    if (!Array.isArray(changes)) continue;
    for (const change of changes) {
      const value = asRecord(asRecord(change)?.value);
      const messages = value && Array.isArray(value.messages) ? value.messages : [];
      for (const raw of messages) {
        const row = asRecord(raw);
        if (!row || typeof row.id !== "string" || !row.id || typeof row.from !== "string" || !row.from) continue;
        const parsed = inboundText(row);
        const ts = typeof row.timestamp === "string" || typeof row.timestamp === "number" ? String(row.timestamp) : "";
        const at = /^\d+$/.test(ts) ? new Date(Number(ts) * 1000).toISOString() : null;
        out.push({
          wamid: row.id.slice(0, 200),
          from: row.from.slice(0, 32),
          type: parsed.type,
          text: parsed.text == null ? null : parsed.text.slice(0, 4000),
          buttonId: parsed.buttonId ? parsed.buttonId.slice(0, 256) : null,
          at,
        });
      }
    }
  }
  return out;
}

export function sessionDestination(phone: string): string | null {
  return normalizeFinnishPhone(phone) ?? (/^\+\d{6,20}$/.test(phone) ? phone : null);
}

// Istuntoviesti 24 h ikkunassa. Nappien otsikko enintään 20 merkkiä, enintään 3 nappia.
// Yli 1024 merkin teksti lähtee tavallisena tekstinä, koska interaktiivisen rungon raja on 1024.
export function buildSessionPayload(to: string, body: string, buttons: ReplyButton[] = []): SessionPayload | null {
  const phone = sessionDestination(to);
  const clean = body.replace(/\u0000/g, "").trim();
  if (!phone || !clean) return null;
  const usable = buttons
    .map((b) => ({ id: b.id.trim().slice(0, 256), title: b.title.trim().slice(0, 20) }))
    .filter((b) => b.id && b.title)
    .slice(0, 3);
  if (usable.length === 0 || clean.length > 1024) {
    return {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: phone,
      type: "text",
      text: { body: clean.slice(0, 4000), preview_url: false },
    };
  }
  return {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: phone,
    type: "interactive",
    interactive: {
      type: "button",
      body: { text: clean },
      action: { buttons: usable.map((b) => ({ type: "reply", reply: { id: b.id, title: b.title } })) },
    },
  };
}

export async function postSession(
  env: WhatsappEnv,
  payload: SessionPayload,
  fetchImpl: typeof fetch,
): Promise<{ status: number; wamid: string | null; error: string | null }> {
  const url = messagesUrl(env.phoneNumberId);
  if (!url || !env.token) return { status: 0, wamid: null, error: "missing_credentials" };
  const res = await fetchImpl(url, {
    method: "POST",
    headers: { authorization: `Bearer ${env.token}`, "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  return { status: res.status, ...readSendResponse(res.status, text) };
}

export function parseWebhookStatuses(body: unknown): StatusUpdate[] {
  if (!body || typeof body !== "object") return [];
  const entries = (body as { entry?: unknown }).entry;
  if (!Array.isArray(entries)) return [];
  const out: StatusUpdate[] = [];
  for (const entry of entries) {
    const changes = entry && typeof entry === "object" ? (entry as { changes?: unknown }).changes : null;
    if (!Array.isArray(changes)) continue;
    for (const change of changes) {
      const value = change && typeof change === "object" ? (change as { value?: { statuses?: unknown } }).value : null;
      const statuses = value && Array.isArray(value.statuses) ? value.statuses : [];
      for (const raw of statuses) {
        if (!raw || typeof raw !== "object") continue;
        const row = raw as { id?: unknown; status?: unknown; timestamp?: unknown; errors?: unknown };
        const status = row.status;
        if (status !== "sent" && status !== "delivered" && status !== "read" && status !== "failed") continue;
        if (typeof row.id !== "string" || !row.id) continue;
        const err = Array.isArray(row.errors) ? row.errors[0] : null;
        const error = err && typeof err === "object"
          ? `${(err as { code?: unknown }).code ?? ""} ${(err as { title?: unknown }).title ?? ""} ${(err as { message?: unknown }).message ?? ""}`.trim().slice(0, 500)
          : null;
        const ts = typeof row.timestamp === "string" || typeof row.timestamp === "number" ? String(row.timestamp) : "";
        const at = /^\d+$/.test(ts) ? new Date(Number(ts) * 1000).toISOString() : null;
        out.push({ wamid: row.id, status, error: error || null, at });
      }
    }
  }
  return out;
}

export async function handleWebhookRequest(
  req: Request,
  env: WhatsappEnv,
  apply: (update: StatusUpdate) => Promise<void>,
  onMessage?: (message: ParsedInbound) => Promise<void>,
): Promise<Response> {
  const url = new URL(req.url);
  if (req.method === "GET") {
    const challenge = await readChallenge(url.searchParams, env.verifyToken);
    if (challenge === null) return new Response("forbidden", { status: 403 });
    return new Response(challenge, { status: 200, headers: { "content-type": "text/plain; charset=utf-8" } });
  }
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const raw = new Uint8Array(await req.arrayBuffer());
  const ok = await verifyHubSignature(env.appSecret, raw, req.headers.get("x-hub-signature-256"));
  if (!ok) return new Response("invalid signature", { status: 401 });
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return new Response("bad json", { status: 400 });
  }
  const updates = parseWebhookStatuses(body);
  const messages = parseWebhookMessages(body);
  try {
    for (const update of updates) await apply(update);
    if (onMessage) {
      for (const message of messages) await onMessage(message);
    }
  } catch {
    return Response.json({ ok: false }, { status: 500 });
  }
  return Response.json({ ok: true, statuses: updates.length, messages: messages.length });
}
