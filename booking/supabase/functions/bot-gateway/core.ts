// bot-gateway: Oton botin kapea yhdyskäytävä (koodari_otto.md §1–3). Ydin ilman Supabasea ja ilman Denon palvelinta.
// Kaikki tietokantatyö tehdään public.botgw_call -funktiossa (botgw.call, migraatiot 20261025145539 + 20261025151402):
// henkilö tulee avainriviltä, scopet, rajat, idempotenssi, validoinnit, vuoromuutokset (shift_apply_change -> shift_outbox)
// ja kirjaukset (shift_change_log, audit_log, botgw.call_log). Tämä ydin tekee vain:
//   * kytkin BOTGW_DISABLED=1 -> 503 (tietokantaa ei kutsuta)
//   * vain POST (405), runko enintään 16 kB (413), runko {action, args}
//   * x-bot-key -> sha256 hex -> rpc('botgw_call', {p_key_hash, p_action, p_args})
//   * kevyt muistinvarainen raja: 60/min per tiiviste, 30/min per IP (429, Retry-After: 60)
//   * toimintokohtainen argumenttien muototarkistus (alla ACTIONS); sisällölliset säännöt jäävät tietokantaan
//   * virhekoodien mappaus HTTP-tilaan (§1) ja virheen jälkeen rpc('botgw_log_failure', {p_key_hash, p_action, p_error})
// Lokiin vain action, tulos (HTTP-tila + lyhyt koodi) ja request_id. EI koskaan otsikkoa, avainta, tiivistettä, IP:tä,
// args-sisältöä eikä tietokannan virheviestiä (viesti voi toistaa syötettä, esim. bad_time:<arvo>).
// Ei suoria taulukirjoituksia eikä kalenterikutsuja: ainoat sallitut RPC:t ovat botgw_call ja botgw_log_failure.

export const MAX_BODY_BYTES = 16 * 1024;
export const MAX_ACTION_CHARS = 50;
export const EDGE_LIMIT_PER_KEY = 60;
export const EDGE_LIMIT_PER_IP = 30;
export const RATE_WINDOW_MS = 60_000;
const MIN_KEY_CHARS = 20;
const MAX_KEY_CHARS = 256;

export type RpcName = "botgw_call" | "botgw_log_failure";
export interface RpcError {
  code?: string;
  message?: string;
}
export interface RpcResult {
  data: unknown;
  error: RpcError | null;
}
export type Rpc = (fn: RpcName, args: Record<string, unknown>) => Promise<RpcResult>;

export interface GatewayDeps {
  rpc: Rpc;
  disabled: () => boolean;
  now?: () => number;
  limiter?: RateLimiter;
}

// ---------- Muistinvarainen liukuva ikkuna ----------
export class RateLimiter {
  private hits = new Map<string, number[]>();
  constructor(private maxKeys = 10_000) {}
  /** true = sallittu (ja kirjattu), false = raja täynnä. */
  hit(key: string, limit: number, now: number, windowMs = RATE_WINDOW_MS): boolean {
    const from = now - windowMs;
    const arr = (this.hits.get(key) ?? []).filter((t) => t > from);
    if (arr.length >= limit) {
      this.hits.set(key, arr);
      return false;
    }
    arr.push(now);
    this.hits.delete(key);
    this.hits.set(key, arr);
    if (this.hits.size > this.maxKeys) {
      const oldest = this.hits.keys().next().value;
      if (oldest !== undefined) this.hits.delete(oldest);
    }
    return true;
  }
}

// ---------- Argumenttien muoto (§2) ----------
type FieldType =
  | { t: "uuid" }
  | { t: "date" }
  | { t: "time" }
  | { t: "bool" }
  | { t: "int" }
  | { t: "str"; max: number; pattern?: RegExp }
  | { t: "enum"; values: readonly string[] }
  | { t: "int_array"; max: number }
  | { t: "enum_array"; values: readonly string[] }
  | { t: "object"; maxBytes: number }
  | { t: "passthrough" }; // tietokanta hylkää (field_not_editable, 403)

interface FieldSpec {
  type: FieldType;
  required?: boolean;
  nullable?: boolean;
}
interface ActionSpec {
  write: boolean;
  fields: Record<string, FieldSpec>;
  check?: (a: Record<string, unknown>) => string | null;
}

const ROLES = ["heater", "reception", "therapist"] as const;
const SHIFT_ACTIONS = ["create", "assign", "unassign", "change_time", "cancel"] as const;
const AREAS = ["notifications", "shift_offers", "other"] as const;
const OFFER_RESPONSES = ["accept", "decline", "snooze"] as const; // public.shift_offer_respond
const BACKLOG_STATUSES = ["queued", "in_progress", "waiting", "done"] as const; // feature_backlog_status_check
const BACKLOG_KINDS = ["fix", "project"] as const; // feature_backlog_kind_check
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
// ISO-aika; ilman vyöhykettä tietokanta tulkitsee Europe/Helsinki-ajaksi (botgw._ts).
const TIME_RE = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|z|[+-]\d{2}(:?\d{2})?)?$/;
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i;
const CAL_NAME_RE = /^[^&?\-]+$/;

const f = (type: FieldType, opts: Omit<FieldSpec, "type"> = {}): FieldSpec => ({ type, ...opts });
const uuid = { t: "uuid" } as const;
const date = { t: "date" } as const;
const time = { t: "time" } as const;
const bool = { t: "bool" } as const;
const int = { t: "int" } as const;
const str = (max: number, pattern?: RegExp): FieldType => ({ t: "str", max, pattern });
const enm = (values: readonly string[]): FieldType => ({ t: "enum", values });
const REQ = { required: true };
const OPT_NULL = { nullable: true };
const request_id = f(uuid);

const staffEditable: Record<string, FieldSpec> = {
  name: f(str(100)),
  calendar_name: f(str(50, CAL_NAME_RE)),
  phone: f(str(40), OPT_NULL),
  email: f(str(254, EMAIL_RE), OPT_NULL),
  notes: f(str(1000), OPT_NULL),
  // Ei muokattavissa: välitetään tietokannalle, joka vastaa field_not_editable (403).
  whatsapp_enabled: f({ t: "passthrough" }),
  bot_channel: f({ t: "passthrough" }),
  id: f({ t: "passthrough" }),
  staff_page_token: f({ t: "passthrough" }),
  request_id,
};

export const ACTIONS: Record<string, ActionSpec> = {
  // vanhat (ennallaan)
  me: { write: false, fields: {} },
  my_shifts: { write: false, fields: { from: f(date), to: f(date) } },
  offers_open: { write: false, fields: {} },
  offer_respond: {
    write: true,
    fields: { offer_id: f(uuid, REQ), response: f(enm(OFFER_RESPONSES), REQ), snooze_until: f(time), request_id },
  },
  inbox: { write: false, fields: {} },
  inbox_ack: { write: false, fields: { ids: f({ t: "int_array", max: 200 }, REQ) } },
  backlog_list: { write: false, fields: { all: f(bool) } },
  backlog_update: {
    write: true,
    fields: {
      item_id: f(int, REQ),
      status: f(enm(BACKLOG_STATUSES)),
      note: f(str(2000)),
      task_id: f(int),
      task_done: f(bool),
      request_id,
    },
    check: (a) => ("task_id" in a) !== ("task_done" in a) ? "task_id ja task_done annetaan yhdessä" : null,
  },
  backlog_add: {
    write: true,
    fields: { title: f(str(300), REQ), description: f(str(4000)), category: f(str(100), REQ), kind: f(enm(BACKLOG_KINDS)), request_id },
  },
  // vuorot
  shifts_list: {
    write: false,
    fields: { from: f(date), to: f(date), role: f(enm(ROLES)), staff_id: f(uuid), include_cancelled: f(bool) },
  },
  shift_history: { write: false, fields: { shift_id: f(uuid, REQ) } },
  shift_change: {
    write: true,
    fields: {
      action: f(enm(SHIFT_ACTIONS), REQ),
      shift_id: f(uuid),
      staff_id: f(uuid),
      role: f(enm(ROLES)),
      starts: f(time),
      ends: f(time),
      note: f(str(500)),
      request_id,
    },
    // Rakenne kuten public._shift_validate_change (aikarajat, roolit ja vuoron tila tarkistetaan tietokannassa).
    check: (a) => {
      const act = a.action as string;
      const has = (k: string) => a[k] !== undefined && a[k] !== null;
      if (act === "create") {
        if (has("shift_id")) return "create ei ota shift_id:tä";
        if (!has("role") || !has("starts") || !has("ends")) return "create vaatii roolin, alun ja lopun";
        return null;
      }
      if (!has("shift_id")) return `${act} vaatii shift_id:n`;
      if ((act === "assign" || act === "unassign") && !has("staff_id")) return `${act} vaatii staff_id:n`;
      if ((act === "change_time" || act === "cancel") && has("staff_id")) return `${act} ei ota staff_id:tä`;
      if (act === "change_time" && (!has("starts") || !has("ends"))) return "change_time vaatii alun ja lopun";
      if (act !== "change_time" && (has("starts") || has("ends"))) return `${act} ei ota uusia aikoja`;
      return null;
    },
  },
  shift_reassign: {
    write: true,
    fields: { shift_id: f(uuid, REQ), from_staff_id: f(uuid, REQ), to_staff_id: f(uuid, REQ), note: f(str(500)), request_id },
    check: (a) => String(a.from_staff_id).toLowerCase() === String(a.to_staff_id).toLowerCase() ? "Sama henkilö" : null,
  },
  // henkilöstö
  staff_list: { write: false, fields: { include_inactive: f(bool) } },
  staff_create: {
    write: true,
    fields: {
      ...staffEditable,
      name: f(str(100), REQ),
      calendar_name: f(str(50, CAL_NAME_RE), REQ),
      roles: f({ t: "enum_array", values: ROLES }),
    },
  },
  staff_update: { write: true, fields: { staff_id: f(uuid, REQ), ...staffEditable, active: f(bool) } },
  staff_role_set: { write: true, fields: { staff_id: f(uuid, REQ), role: f(enm(ROLES), REQ), active: f(bool, REQ), request_id } },
  // esteet
  unavailability_list: { write: false, fields: { from: f(date), to: f(date), staff_id: f(uuid) } },
  unavailability_add: { write: true, fields: { staff_id: f(uuid, REQ), starts: f(time, REQ), ends: f(time, REQ), request_id } },
  unavailability_update: { write: true, fields: { id: f(uuid, REQ), starts: f(time, REQ), ends: f(time, REQ), request_id } },
  unavailability_delete: { write: true, fields: { id: f(uuid, REQ), request_id } },
  // ehdotukset
  proposal_add: {
    write: true,
    fields: {
      area: f(enm(AREAS)),
      title: f(str(200), REQ),
      body: f(str(4000), REQ),
      proposed_change: f({ t: "object", maxBytes: 16384 }),
      request_id,
    },
  },
  proposal_list: { write: false, fields: {} },
};

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function checkField(name: string, spec: FieldSpec, v: unknown): string | null {
  if (v === null) return spec.nullable ? null : `bad_arg:${name}`;
  const t = spec.type;
  switch (t.t) {
    case "passthrough":
      return null;
    case "uuid":
      return typeof v === "string" && UUID_RE.test(v) ? null : `bad_arg:${name}`;
    case "date":
      return typeof v === "string" && DATE_RE.test(v) && !Number.isNaN(Date.parse(v)) ? null : `bad_arg:${name}`;
    case "time":
      return typeof v === "string" && v.length <= 40 && TIME_RE.test(v.trim()) ? null : `bad_arg:${name}`;
    case "bool":
      return typeof v === "boolean" ? null : `bad_arg:${name}`;
    case "int":
      return Number.isSafeInteger(v) && (v as number) > 0 ? null : `bad_arg:${name}`;
    case "str":
      if (typeof v !== "string") return `bad_arg:${name}`;
      if (v.length > t.max) return `too_long:${name}`;
      if (t.pattern && v.trim() !== "" && !t.pattern.test(v.trim())) return `bad_arg:${name}`;
      return null;
    case "enum":
      return typeof v === "string" && t.values.includes(v) ? null : `bad_arg:${name}`;
    case "int_array":
      return Array.isArray(v) && v.length <= t.max && v.every((x) => Number.isSafeInteger(x) && x > 0)
        ? null
        : `bad_arg:${name}`;
    case "enum_array":
      return Array.isArray(v) && v.length <= t.values.length && v.every((x) => typeof x === "string" && t.values.includes(x))
        ? null
        : `bad_arg:${name}`;
    case "object":
      if (!isPlainObject(v)) return `bad_arg:${name}`;
      return new TextEncoder().encode(JSON.stringify(v)).length <= t.maxBytes ? null : `too_long:${name}`;
  }
}

/** Palauttaa null tai lyhyen virhekoodin (ei syötteen arvoja). */
export function validateArgs(action: string, args: Record<string, unknown>): string | null {
  const spec = ACTIONS[action];
  if (!spec) return "unknown_action";
  const fields: Record<string, FieldSpec> = { request_id, ...spec.fields }; // request_id sallitaan kaikille (lukutoiminnoissa tietokanta ohittaa sen)
  for (const k of Object.keys(args)) {
    if (!(k in fields)) return `unknown_arg:${k.slice(0, 40).replace(/[^a-z0-9_]/gi, "?")}`;
  }
  for (const [name, fs] of Object.entries(fields)) {
    const v = args[name];
    if (v === undefined) {
      if (fs.required) return `missing_arg:${name}`;
      continue;
    }
    if (fs.required && (v === null || (typeof v === "string" && v.trim() === ""))) return `missing_arg:${name}`;
    const e = checkField(name, fs, v);
    if (e) return e;
  }
  return spec.check ? spec.check(args) : null;
}

// ---------- Virheiden mappaus (§1) ----------
export interface Mapped {
  status: number;
  error: string; // vastaukseen
  logCode: string; // lokiin ja botgw_log_failureen (ei viestisisältöä)
}

const FORBIDDEN_403 = ["forbidden", "not_editable", "field_not_editable", "calendar_managed"];

export function mapDbError(e: RpcError | null | undefined): Mapped {
  const code = String(e?.code ?? "");
  const msg = String(e?.message ?? "");
  const head = msg.split(":")[0].trim();
  switch (code) {
    case "42501":
      if (FORBIDDEN_403.includes(head)) return { status: 403, error: msg.slice(0, 300), logCode: `42501:${head}` };
      return { status: 401, error: "unauthorized", logCode: "42501:unauthorized" };
    case "22023":
      // Validointiviestit (suomeksi / lyhyet koodit) sellaisenaan; eivät sisällä salaisuuksia.
      return { status: 400, error: msg.slice(0, 300) || "invalid", logCode: "22023" };
    case "22P02":
      return { status: 400, error: "bad_input", logCode: "22P02" };
    case "23505":
      return { status: 400, error: "already_exists", logCode: "23505" };
    case "P0002":
      return { status: 404, error: /^[\p{L}\p{N}_ :;,.()-]{1,200}$/u.test(msg) ? msg : "not_found", logCode: "P0002" };
    case "BG429":
      return { status: 429, error: "rate_limited", logCode: "BG429" };
    case "55000":
      return { status: 503, error: "shift_sync_disabled", logCode: "55000" };
    default:
      return { status: 500, error: "internal_error", logCode: code ? `db:${code.slice(0, 10)}` : "db:unknown" };
  }
}

// ---------- Apurit ----------
export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("");
}

const BASE_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...BASE_HEADERS, ...extra } });
}

function logLine(action: string, status: number, result: string, requestId?: string | null) {
  const o: Record<string, unknown> = { fn: "bot-gateway", action, status, result };
  if (requestId && UUID_RE.test(requestId)) o.request_id = requestId;
  console.log(JSON.stringify(o));
}

function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  const first = xff?.split(",")[0]?.trim();
  return first || req.headers.get("x-real-ip")?.trim() || "unknown";
}

/** Lukee rungon enintään max tavua; liian iso -> null. */
async function readBody(req: Request, max: number): Promise<Uint8Array | null> {
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let n = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.byteLength;
    if (n > max) {
      try {
        await reader.cancel();
      } catch { /* ignore */ }
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(n);
  let o = 0;
  for (const c of chunks) {
    out.set(c, o);
    o += c.byteLength;
  }
  return out;
}

// ---------- Käsittelijä ----------
export function createHandler(deps: GatewayDeps): (req: Request) => Promise<Response> {
  const now = deps.now ?? (() => Date.now());
  const limiter = deps.limiter ?? new RateLimiter();

  return async (req: Request): Promise<Response> => {
    let action = "?";
    let keyHash: string | null = null;
    let reqId: string | null = null;

    const fail = async (m: Mapped, extra: Record<string, string> = {}, logToDb = true): Promise<Response> => {
      if (logToDb && keyHash) {
        try {
          const r = await deps.rpc("botgw_log_failure", { p_key_hash: keyHash, p_action: action, p_error: m.logCode });
          if (r.error) console.log(JSON.stringify({ fn: "bot-gateway", action, result: "log_failure_failed" }));
        } catch {
          console.log(JSON.stringify({ fn: "bot-gateway", action, result: "log_failure_failed" }));
        }
      }
      logLine(action, m.status, m.logCode, reqId);
      return json(m.status, { ok: false, error: m.error }, extra);
    };

    // 1) hätäkatkaisu: ei tietokantaa
    if (deps.disabled()) return fail({ status: 503, error: "disabled", logCode: "edge:disabled" }, {}, false);
    // 2) vain POST (ei CORSia: palvelin-palvelin-kutsu, selainta ei tueta)
    if (req.method !== "POST") {
      return fail({ status: 405, error: "method_not_allowed", logCode: "edge:method" }, { allow: "POST" }, false);
    }
    // 3) IP-raja ennen muuta työtä
    const t = now();
    if (!limiter.hit(`ip:${clientIp(req)}`, EDGE_LIMIT_PER_IP, t)) {
      return fail({ status: 429, error: "rate_limited", logCode: "edge:ip_limit" }, { "retry-after": "60" }, false);
    }
    // 4) koko (otsikko + todellinen runko)
    const cl = req.headers.get("content-length");
    if (cl !== null && (!/^\d+$/.test(cl) || Number(cl) > MAX_BODY_BYTES)) {
      return fail({ status: 413, error: "payload_too_large", logCode: "edge:too_large" }, {}, false);
    }
    // 5) avain
    const key = req.headers.get("x-bot-key");
    if (!key || key.length < MIN_KEY_CHARS || key.length > MAX_KEY_CHARS || !/^[\x21-\x7e]+$/.test(key)) {
      return fail({ status: 401, error: "unauthorized", logCode: "edge:no_key" }, {}, false);
    }
    keyHash = await sha256Hex(key);
    if (!limiter.hit(`key:${keyHash}`, EDGE_LIMIT_PER_KEY, t)) {
      // ei tietokantakutsua tulvan aikana
      return fail({ status: 429, error: "rate_limited", logCode: "edge:key_limit" }, { "retry-after": "60" }, false);
    }
    // 6) runko
    const raw = await readBody(req, MAX_BODY_BYTES);
    if (raw === null) return fail({ status: 413, error: "payload_too_large", logCode: "edge:too_large" });
    let body: unknown;
    try {
      body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
    } catch {
      return fail({ status: 400, error: "bad_json", logCode: "edge:bad_json" });
    }
    if (!isPlainObject(body)) return fail({ status: 400, error: "bad_request", logCode: "edge:bad_body" });
    const a = body.action;
    if (typeof a !== "string" || a.length < 1 || a.length > MAX_ACTION_CHARS || !/^[a-z_]+$/.test(a)) {
      return fail({ status: 400, error: "bad_action", logCode: "edge:bad_action" });
    }
    action = a;
    const args = body.args === undefined ? {} : body.args;
    if (!isPlainObject(args)) return fail({ status: 400, error: "args_must_be_object", logCode: "edge:bad_args" });
    if (typeof args.request_id === "string" && UUID_RE.test(args.request_id)) reqId = args.request_id;
    for (const k of Object.keys(body)) {
      if (k !== "action" && k !== "args") return fail({ status: 400, error: "bad_request", logCode: "edge:bad_body" });
    }
    const v = validateArgs(action, args);
    if (v) {
      const status = 400;
      return fail({ status, error: v, logCode: v === "unknown_action" ? "edge:unknown_action" : "edge:validation" });
    }

    // 7) tietokanta
    let res: RpcResult;
    try {
      res = await deps.rpc("botgw_call", { p_key_hash: keyHash, p_action: action, p_args: args });
    } catch {
      return fail({ status: 500, error: "internal_error", logCode: "edge:rpc_failed" });
    }
    if (res.error) {
      const m = mapDbError(res.error);
      return fail(m, m.status === 429 ? { "retry-after": "60" } : {});
    }
    const d = res.data;
    if (!isPlainObject(d) || d.ok !== true) {
      return fail({ status: 500, error: "internal_error", logCode: "edge:bad_db_response" });
    }
    if (typeof d.request_id === "string") reqId = d.request_id;
    logLine(action, 200, d.duplicate === true ? "duplicate" : "ok", reqId);
    return json(200, d);
  };
}
