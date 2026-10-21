// Visma Pay / Paybyway REST w3.2 (https://www.vismapay.com/docs/web_payments/).
// Sama isäntä testille ja tuotannolle. Erotus on kauppiasavaimissa, ei osoitteessa.
// Testitila lukee VAIN VISMAPAY_TEST_*. Tuotanto lukee VISMAPAY_LIVE_* ja sen puuttuessa VISMAPAY_API_KEY + VISMAPAY_PRIVATE_KEY.
// Yksityinen avain ei lähde selaimeen eikä lokiin. authcode lasketaan vain palvelimella.

import { timingSafeEqual, type Env, type Fetch } from "./mobilepay.ts";

export const API_BASE = "https://www.vismapay.com/pbwapi";
export const API_VERSION = "w3.2";
export const CHARGE_PATH = "/token/";

export type PayEnv = "test" | "live";
export type Creds = { apiKey: string; privateKey: string; env: PayEnv };

const enc = new TextEncoder();

export async function hmacSha256Hex(privateKey: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(privateKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
}

/** Paluu- ja notify-MAC: RETURN_CODE|ORDER_NUMBER ja SETTLED / INCIDENT_ID vain jos ne on asetettu. */
export function returnMacMessage(q: { RETURN_CODE?: string; ORDER_NUMBER?: string; SETTLED?: string; INCIDENT_ID?: string }): string {
  const parts = [q.RETURN_CODE ?? "", q.ORDER_NUMBER ?? ""];
  if (q.SETTLED != null && q.SETTLED !== "") parts.push(q.SETTLED);
  if (q.INCIDENT_ID != null && q.INCIDENT_ID !== "") parts.push(q.INCIDENT_ID);
  return parts.join("|");
}

export function refundMacMessage(returnCode: string, refundId: string): string {
  return `${returnCode}|${refundId}`;
}

export async function macMatches(privateKey: string, message: string, given: string | null | undefined): Promise<boolean> {
  if (!given) return false;
  const expected = await hmacSha256Hex(privateKey, message);
  return timingSafeEqual(expected, String(given).trim().toUpperCase());
}

/** Testitila ei koskaan käytä live-avaimia. Live suosii VISMAPAY_LIVE_* ja hyväksyy vanhat nimet vain livessä. */
export function readCreds(env: Env, mode: PayEnv): Creds | null {
  if (mode === "test") {
    const apiKey = env.get("VISMAPAY_TEST_API_KEY");
    const privateKey = env.get("VISMAPAY_TEST_PRIVATE_KEY");
    if (!apiKey || !privateKey) return null;
    return { apiKey, privateKey, env: "test" };
  }
  const apiKey = env.get("VISMAPAY_LIVE_API_KEY") || env.get("VISMAPAY_API_KEY");
  const privateKey = env.get("VISMAPAY_LIVE_PRIVATE_KEY") || env.get("VISMAPAY_PRIVATE_KEY");
  if (!apiKey || !privateKey) return null;
  return { apiKey, privateKey, env: "live" };
}

export function chargeUrl(token: string): string {
  return `${API_BASE}${CHARGE_PATH}${encodeURIComponent(token)}`;
}

export function safeChargeUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" || u.hostname !== "www.vismapay.com") return null;
    if (!u.pathname.startsWith("/pbwapi/token/")) return null;
    if (u.pathname.length < "/pbwapi/token/".length + 8) return null;
    return u.href;
  } catch {
    return null;
  }
}

/** Korttitunnisteesta vain brand ja last4. Ei PAN-numeroa, ei card_tokenia, ei sähköpostia. */
export function scrubSource(source: unknown): Record<string, string> | null {
  if (!source || typeof source !== "object") return null;
  const s = source as Record<string, unknown>;
  const out: Record<string, string> = {};
  if (typeof s.object === "string" && s.object) out.object = s.object.slice(0, 40);
  if (typeof s.brand === "string" && s.brand) out.brand = s.brand.slice(0, 40);
  if (s.last4 != null && String(s.last4)) out.last4 = String(s.last4).replace(/\D/g, "").slice(-4);
  return Object.keys(out).length ? out : null;
}

export class VismaError extends Error {
  constructor(public status: number, public op: string, public body: unknown) { super(`vismapay_${op}_${status}`); }
  get transient() { return this.status === 0 || this.status === 429 || this.status >= 500; }
  summary() {
    const b = this.body as Record<string, unknown> | null;
    const result = b && typeof b === "object" ? b.result : undefined;
    const errors = b && typeof b === "object" && Array.isArray(b.errors) ? b.errors.map((x) => String(x).slice(0, 160)).slice(0, 6) : undefined;
    return { op: this.op, status: this.status, result: result ?? null, errors: errors ?? null };
  }
}

export class VismaApi {
  constructor(private creds: Creds, private fetchImpl: Fetch = fetch) {}

  private async auth(message: string): Promise<string> {
    return hmacSha256Hex(this.creds.privateKey, message);
  }

  private async post(op: string, path: string, body: Record<string, unknown>): Promise<any> {
    let res: Response;
    try {
      res = await this.fetchImpl(`${API_BASE}${path}`, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify(body),
      });
    } catch (e) {
      throw new VismaError(0, op, { result: null, errors: [String((e as Error).message ?? e).slice(0, 160)] });
    }
    const text = await res.text();
    let data: unknown = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text.slice(0, 200) }; }
    if (!res.ok) throw new VismaError(res.status, op, data);
    return data;
  }

  async authPayment(p: {
    orderNumber: string; amountMinor: number; currency: string; returnUrl: string; notifyUrl: string;
    lang: string; tokenValidUntil: string; customer?: Record<string, string> | null;
  }): Promise<{ result: number; token?: string; type?: string; errors?: string[] }> {
    const authcode = await this.auth(`${this.creds.apiKey}|${p.orderNumber}`);
    const body: Record<string, unknown> = {
      version: API_VERSION,
      api_key: this.creds.apiKey,
      order_number: p.orderNumber,
      amount: p.amountMinor,
      currency: p.currency || "EUR",
      payment_method: {
        type: "e-payment",
        return_url: p.returnUrl,
        notify_url: p.notifyUrl,
        lang: p.lang || "fi",
        token_valid_until: p.tokenValidUntil,
        override_auto_settlement: 2,
      },
      authcode,
    };
    if (p.customer && Object.keys(p.customer).length) body.customer = p.customer;
    return this.post("auth_payment", "/auth_payment", body);
  }

  async checkStatus(orderNumber: string): Promise<{ result: number; settled?: number; source?: unknown }> {
    const authcode = await this.auth(`${this.creds.apiKey}|${orderNumber}`);
    return this.post("check_payment_status", "/check_payment_status", {
      version: API_VERSION, api_key: this.creds.apiKey, order_number: orderNumber, authcode,
    });
  }

  async getPayment(orderNumber: string): Promise<{ result: number; payment?: any; errors?: string[] }> {
    const authcode = await this.auth(`${this.creds.apiKey}|${orderNumber}`);
    return this.post("get_payment", "/get_payment", {
      version: API_VERSION, api_key: this.creds.apiKey, order_number: orderNumber, authcode,
    });
  }

  async capture(orderNumber: string): Promise<{ result: number; errors?: string[] }> {
    const authcode = await this.auth(`${this.creds.apiKey}|${orderNumber}`);
    return this.post("capture", "/capture", {
      version: API_VERSION, api_key: this.creds.apiKey, order_number: orderNumber, authcode,
    });
  }

  async createRefund(p: { orderNumber: string; amountMinor: number; email?: string | null; notifyUrl: string }): Promise<{ result: number; type?: string; refund_id?: number | string; refund_url?: string; errors?: string[] }> {
    const authcode = await this.auth(`${this.creds.apiKey}|${p.orderNumber}`);
    const body: Record<string, unknown> = {
      version: API_VERSION, api_key: this.creds.apiKey, order_number: p.orderNumber,
      amount: p.amountMinor, notify_url: p.notifyUrl, authcode,
    };
    if (p.email) body.email = p.email;
    return this.post("create_refund", "/create_refund", body);
  }

  async getRefund(refundId: string): Promise<{ result: number; refund?: any; errors?: string[] }> {
    const authcode = await this.auth(`${this.creds.apiKey}|${refundId}`);
    return this.post("get_refund", "/get_refund", {
      version: API_VERSION, api_key: this.creds.apiKey, refund_id: refundId, authcode,
    });
  }
}

export function functionBase(env: Env): string | null {
  const raw = env.get("SUPABASE_URL");
  if (!raw) return null;
  try {
    const u = new URL(raw);
    if (u.protocol !== "https:") return null;
    return u.origin.replace(/\/+$/, "") + "/functions/v1";
  } catch {
    return null;
  }
}

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/;

/** Asiakasobjekti Vismaan. Puhelinnumeroa ei lähetetä (w3.2-customer ei tunne kenttää). Tyhjät kentät jäävät pois. */
export function customerPayload(c: Record<string, unknown> | null | undefined): Record<string, string> | null {
  if (!c || typeof c !== "object") return null;
  const out: Record<string, string> = {};
  const put = (k: string, v: unknown, max: number) => {
    const s = typeof v === "string" ? v.trim() : "";
    if (s) out[k] = s.slice(0, max);
  };
  put("firstname", c.firstname, 40);
  put("lastname", c.lastname, 40);
  if (typeof c.email === "string" && EMAIL_RE.test(c.email.trim()) && c.email.trim().length <= 200) out.email = c.email.trim();
  put("address_street", c.address_street, 100);
  put("address_city", c.address_city, 80);
  put("address_zip", c.address_zip, 12);
  put("address_country", c.address_country, 2);
  return Object.keys(out).length ? out : null;
}

export const ORDER_NUMBER_RE = /^sauna-[a-z0-9_-]{4,80}$/;
export const REFUND_DONE = new Set([9, 10, 16]);
export const REFUND_PENDING = new Set([6, 7, 8]);
export const REFUND_REJECTED = new Set([11, 12, 13]);
export const PAY_SETTLED = new Set([4, 5, 15]);
