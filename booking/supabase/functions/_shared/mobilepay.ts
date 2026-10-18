// Vipps MobilePay ePayment API -asiakas ja apurit (jaettu: mobilepay-start / -notify / -refund).
// Ei salaisuuksia koodissa: avaimet luetaan Edge-salaisuuksista (MOBILEPAY_CLIENT_ID, MOBILEPAY_CLIENT_SECRET, MOBILEPAY_SUBSCRIPTION_KEY, MOBILEPAY_MSN, MOBILEPAY_WEBHOOK_SECRET).
// Dokumentaatio: https://developer.vippsmobilepay.com/docs/APIs/epayment-api/  (testipalvelin https://apitest.vipps.no, tuotanto https://api.vipps.no)

export type Mode = "off" | "test" | "live";
export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;
export type Env = { get(key: string): string | undefined };

export const TEST_BASE = "https://apitest.vipps.no";
export const LIVE_BASE = "https://api.vipps.no";
export const SECRET_NAMES = ["MOBILEPAY_CLIENT_ID", "MOBILEPAY_CLIENT_SECRET", "MOBILEPAY_SUBSCRIPTION_KEY", "MOBILEPAY_MSN"] as const;

export type Creds = { clientId: string; clientSecret: string; subscriptionKey: string; msn: string };

export const baseUrl = (mode: Mode) => (mode === "live" ? LIVE_BASE : TEST_BASE);

/** Palauttaa avaimet tai null jos jokin puuttuu (ei koskaan paljasta arvoja). */
export function readCreds(env: Env): Creds | null {
  const clientId = env.get("MOBILEPAY_CLIENT_ID"), clientSecret = env.get("MOBILEPAY_CLIENT_SECRET"), subscriptionKey = env.get("MOBILEPAY_SUBSCRIPTION_KEY"), msn = env.get("MOBILEPAY_MSN");
  if (!clientId || !clientSecret || !subscriptionKey || !msn) return null;
  return { clientId, clientSecret, subscriptionKey, msn };
}
export const missingSecrets = (env: Env) => SECRET_NAMES.filter((n) => !env.get(n));

export const minor = (eur: number) => Math.round(eur * 100);

export class VippsError extends Error {
  constructor(public status: number, public op: string, public body: unknown) { super(`vipps_${op}_${status}`); }
  get transient() { return this.status === 0 || this.status === 429 || this.status >= 500; }
  /** Lyhyt, turvallinen kuvaus lokiin/tauluun (ei otsikoita, ei avaimia). */
  summary() {
    const b = this.body as Record<string, unknown> | string | null;
    const text = typeof b === "string" ? b : b ? JSON.stringify({ title: (b as any).title, detail: (b as any).detail, extraDetails: (b as any).extraDetails, status: (b as any).status }) : "";
    return { op: this.op, status: this.status, body: text.slice(0, 500) };
  }
}

export type VippsPayment = {
  state?: string; reference?: string; amount?: { currency: string; value: number };
  aggregate?: Record<string, { currency: string; value: number } | undefined>;
  userDetails?: { email?: string; firstName?: string; lastName?: string; mobileNumber?: string };
  profile?: { sub?: string };
  captureGuaranteedUntil?: string;
};

const SYSTEM_HEADERS = { "Vipps-System-Name": "sipoonjoen-perinnesauna-booking", "Vipps-System-Version": "1", "Vipps-System-Plugin-Name": "supabase-edge-mobilepay", "Vipps-System-Plugin-Version": "1.0.0" };

export class MobilePayApi {
  private token: { value: string; exp: number } | null = null;
  constructor(public mode: Mode, private creds: Creds, private fetchImpl: Fetch = fetch, private now: () => number = () => Date.now()) {}
  get base() { return baseUrl(this.mode); }

  private async call(op: string, method: string, path: string, opts: { body?: unknown; idempotencyKey?: string; auth?: boolean } = {}): Promise<any> {
    const headers: Record<string, string> = { "Ocp-Apim-Subscription-Key": this.creds.subscriptionKey, "Merchant-Serial-Number": this.creds.msn, ...SYSTEM_HEADERS };
    if (opts.auth !== false) headers["Authorization"] = `Bearer ${await this.getToken()}`;
    if (opts.body !== undefined) headers["Content-Type"] = "application/json";
    if (opts.idempotencyKey) headers["Idempotency-Key"] = opts.idempotencyKey;
    let res: Response;
    try {
      res = await this.fetchImpl(`${this.base}${path}`, { method, headers, body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined });
    } catch (e) { throw new VippsError(0, op, String((e as Error).message ?? e)); }
    const text = await res.text();
    let data: unknown = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!res.ok) throw new VippsError(res.status, op, data);
    return data;
  }

  async getToken(): Promise<string> {
    if (this.token && this.token.exp > this.now() + 60_000) return this.token.value;
    const headers = { "client_id": this.creds.clientId, "client_secret": this.creds.clientSecret, "Ocp-Apim-Subscription-Key": this.creds.subscriptionKey, "Merchant-Serial-Number": this.creds.msn, ...SYSTEM_HEADERS };
    let res: Response;
    try { res = await this.fetchImpl(`${this.base}/accesstoken/get`, { method: "POST", headers, body: "" }); }
    catch (e) { throw new VippsError(0, "token", String((e as Error).message ?? e)); }
    const text = await res.text();
    let d: any = null; try { d = text ? JSON.parse(text) : null; } catch { /* ei JSON */ }
    if (!res.ok || !d?.access_token) throw new VippsError(res.status || 502, "token", { title: d?.error ?? d?.message ?? "token_failed" });
    const ttl = Number(d.expires_in ?? 3600) * 1000;
    this.token = { value: d.access_token, exp: this.now() + ttl };
    return this.token.value;
  }

  createPayment(p: { reference: string; amountMinor: number; currency: string; returnUrl?: string | null; description: string; scope?: string; userFlow?: "WEB_REDIRECT" | "QR" | "PUSH_MESSAGE"; phoneNumber?: string }): Promise<{ redirectUrl?: string; url?: string; reference: string }> {
    const userFlow = p.userFlow ?? "WEB_REDIRECT";
    const body: Record<string, unknown> = {
      amount: { currency: p.currency, value: p.amountMinor }, paymentMethod: { type: "WALLET" }, reference: p.reference,
      userFlow, paymentDescription: p.description.slice(0, 100),
      profile: { scope: p.scope ?? "name email phoneNumber" },
    };
    // WEB_REDIRECT vaatii returnUrlin. QR ja PUSH_MESSAGE eivät (Vipps ePayment userFlow). qrFormat-kuvaa ei pyydetä.
    if (p.returnUrl) body.returnUrl = p.returnUrl;
    if (userFlow === "PUSH_MESSAGE" && p.phoneNumber) body.customer = { phoneNumber: p.phoneNumber };
    return this.call("create", "POST", "/epayment/v1/payments", { idempotencyKey: p.reference, body });
  }
  getPayment(reference: string): Promise<VippsPayment> { return this.call("get", "GET", `/epayment/v1/payments/${encodeURIComponent(reference)}`); }
  capture(reference: string, amountMinor: number, currency: string): Promise<VippsPayment> {
    return this.call("capture", "POST", `/epayment/v1/payments/${encodeURIComponent(reference)}/capture`, { idempotencyKey: `capture-${reference}`, body: { modificationAmount: { currency, value: amountMinor } } });
  }
  cancel(reference: string): Promise<VippsPayment> {
    return this.call("cancel", "POST", `/epayment/v1/payments/${encodeURIComponent(reference)}/cancel`, { idempotencyKey: `cancel-${reference}`, body: {} });
  }
  refund(reference: string, amountMinor: number, currency: string, idempotencyKey: string): Promise<VippsPayment> {
    return this.call("refund", "POST", `/epayment/v1/payments/${encodeURIComponent(reference)}/refund`, { idempotencyKey, body: { modificationAmount: { currency, value: amountMinor } } });
  }
}

export const aggVal = (p: VippsPayment, k: string) => p.aggregate?.[k]?.value ?? 0;

// ---------- webhook-allekirjoitus (https://developer.vippsmobilepay.com/docs/APIs/webhooks-api/request-authentication/) ----------
const enc = new TextEncoder();
const b64 = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf)));
export async function sha256b64(data: Uint8Array | string): Promise<string> {
  return b64(await crypto.subtle.digest("SHA-256", (typeof data === "string" ? enc.encode(data) : data) as BufferSource));
}
export async function hmacb64(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64(await crypto.subtle.sign("HMAC", key, enc.encode(message)));
}
export function timingSafeEqual(a: string, b: string): boolean {
  const x = enc.encode(a), y = enc.encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}
/** Laskee odotetun Authorization-otsikon: "POST\n<pathAndQuery>\n<x-ms-date>;<host>;<contentHash>" -> HMAC-SHA256(secret) base64. */
export async function webhookAuthorization(secret: string, pathAndQuery: string, date: string, host: string, contentHash: string, method = "POST"): Promise<string> {
  const sig = await hmacb64(secret, `${method}\n${pathAndQuery}\n${date};${host};${contentHash}`);
  return `HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature=${sig}`;
}
/**
 * Tarkistaa Vippsin webhookin. Runko luetaan raakana (ei uudelleenserialisoitua JSONia).
 * Polku/host voivat näkyä funktiolle eri muodossa kuin rekisteröidyssä URL:ssa, joten kokeillaan ehdokkaita (kaikki vakioaikavertailulla).
 */
export async function verifyWebhook(args: { secret: string; headers: Headers; rawBody: Uint8Array; pathCandidates: string[]; hostCandidates: string[] }): Promise<boolean> {
  const date = args.headers.get("x-ms-date"), hash = args.headers.get("x-ms-content-sha256"), auth = args.headers.get("authorization");
  if (!date || !hash || !auth) return false;
  if (!timingSafeEqual(hash, await sha256b64(args.rawBody))) return false;
  let ok = false;
  for (const host of args.hostCandidates.filter(Boolean)) for (const path of args.pathCandidates.filter(Boolean)) {
    const expected = await webhookAuthorization(args.secret, path, date, host, hash);
    if (timingSafeEqual(expected, auth)) ok = true;   // ei keskeytetä: aika ei riipu osumasta
  }
  return ok;
}

// ---------- apurit ----------
export const CORS_HEADERS = (origin: string | null, allowed: string | undefined) => {
  const list = (allowed ?? "*").split(",").map((s) => s.trim()).filter(Boolean);
  const allow = list.includes("*") ? "*" : (origin && list.includes(origin) ? origin : list[0] ?? "*");
  return { "access-control-allow-origin": allow, "access-control-allow-headers": "content-type, authorization, apikey, x-client-info", "access-control-allow-methods": "GET, POST, OPTIONS", "vary": "origin" };
};
export const jsonResponse = (o: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra } });

/** PostgREST-virhe -> {code, message}; BK001-poikkeuksen detail on koodi. */
export function dbError(e: { message?: string; details?: string; code?: string } | null | undefined) {
  if (!e) return null;
  return { code: e.code === "BK001" && e.details ? e.details : (e.code ?? "db_error"), message: e.message ?? "" };
}
export const httpForCode = (code: string) =>
  ({ not_found: 404, rate_limited: 429, mobilepay_off: 503, invalid_param: 400, already_paid: 409, nothing_to_pay: 409, order_not_payable: 409, payment_not_pending: 409, link_expired: 410, link_stale: 409, other_provider_started: 409, unsupported_currency: 400 } as Record<string, number>)[code] ?? 500;

export function buildReturnUrl(siteBase: string | null | undefined, orderPath: string | null | undefined, orderToken: string): string | null {
  if (!siteBase) return null;
  let base: URL;
  try { base = new URL(siteBase); } catch { return null; }
  if (base.protocol !== "https:") return null;
  const path = (orderPath && orderPath.startsWith("/")) ? orderPath : "/tilaus/";
  // site_base_url voi sisältää polkuetuliitteen (esim. GitHub Pages -testi https://x.github.io/saunotus-uusi): sama liitos kuin sähköposteissa (site_base_url || order_page_path)
  const u = new URL(base.origin + base.pathname.replace(/\/+$/, "") + path);
  u.searchParams.set("t", orderToken); u.searchParams.set("pay", "mobilepay");
  return u.toString();
}
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ---------- tietokantarajapinta (injektoitava testeissä) ----------
export type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: any; error: { message?: string; details?: string; code?: string } | null }>;
export type Db = { rpc: Rpc; mode: () => Promise<Mode> };

export function realDb(createClient: (url: string, key: string, opts: unknown) => any, env: Env): Db {
  const sb = createClient(env.get("SUPABASE_URL")!, env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  return {
    rpc: (fn, args) => sb.schema("booking").rpc(fn, args ?? {}),
    mode: async () => {
      const { data } = await sb.schema("booking").from("integration_config").select("mode").eq("key", "mobilepay").maybeSingle();
      const m = data?.mode;
      return m === "test" || m === "live" ? m : "off";
    },
  };
}
