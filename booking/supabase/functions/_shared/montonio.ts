// Verkkomaksun Stargate-asiakas. Avaimet vain ympäristöstä: MONTONIO_ACCESS_KEY, MONTONIO_SECRET_KEY, MONTONIO_MODE (sandbox|live).
// Pyynnöt ovat HS256-JWT. Paluu- ja ilmoitus-JWT varmennetaan ennen kuin maksu merkitään maksetuksi.
// Asiakkaalle näkyviin viesteihin ei kirjoiteta välittäjän nimeä.

import { timingSafeEqual, type Env, type Fetch } from "./mobilepay.ts";

export const SANDBOX_BASE = "https://sandbox-stargate.montonio.com";
export const LIVE_BASE = "https://stargate.montonio.com";
export const METHODS = ["paymentInitiation", "cardPayments", "applePay", "googlePay", "mobilePay"] as const;
export type PayMethod = typeof METHODS[number];
export type PayEnv = "sandbox" | "live";

const enc = new TextEncoder();
const dec = new TextDecoder();

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
export function b64urlJson(value: unknown): string {
  return b64url(enc.encode(JSON.stringify(value)));
}
export function b64urlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function signJwt(payload: Record<string, unknown>, secret: string): Promise<string> {
  const body = `${b64urlJson({ alg: "HS256", typ: "JWT" })}.${b64urlJson(payload)}`;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(body)));
  return `${body}.${b64url(sig)}`;
}

export type Verified = { ok: true; payload: Record<string, unknown> } | { ok: false; reason: string };

/** Hylkää alg=none ja muun kuin HS256. Vertailu on vakiokestoinen. exp tarkistetaan jos se on numerona. */
export async function verifyJwt(token: string, secret: string, nowSec = Math.floor(Date.now() / 1000)): Promise<Verified> {
  const parts = String(token || "").split(".");
  if (parts.length !== 3 || parts.some((p) => !p)) return { ok: false, reason: "malformed" };
  let header: Record<string, unknown>;
  let payload: Record<string, unknown>;
  try {
    header = JSON.parse(dec.decode(b64urlDecode(parts[0])));
    payload = JSON.parse(dec.decode(b64urlDecode(parts[1])));
  } catch {
    return { ok: false, reason: "malformed" };
  }
  if (header.alg !== "HS256" || (header.typ != null && header.typ !== "JWT")) return { ok: false, reason: "alg" };
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expect = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${parts[0]}.${parts[1]}`)));
  let given: Uint8Array;
  try { given = b64urlDecode(parts[2]); } catch { return { ok: false, reason: "malformed" }; }
  const a = b64url(expect);
  const b = b64url(given);
  if (!timingSafeEqual(a, b)) return { ok: false, reason: "signature" };
  if (typeof payload.exp === "number" && payload.exp < nowSec) return { ok: false, reason: "expired" };
  return { ok: true, payload };
}

export function readCreds(env: Env): { accessKey: string; secretKey: string } | null {
  const accessKey = env.get("MONTONIO_ACCESS_KEY");
  const secretKey = env.get("MONTONIO_SECRET_KEY");
  if (!accessKey || !secretKey) return null;
  return { accessKey, secretKey };
}

/** Tietokannan test = sandbox, live = live. Salaisuuden MONTONIO_MODE pitää täsmätä. Puuttuva tila testissä on sandbox. */
export function resolveHost(dbMode: string, env: Env): { ok: true; env: PayEnv; base: string } | { ok: false; code: string } {
  const secret = (env.get("MONTONIO_MODE") || "").trim().toLowerCase();
  if (dbMode === "test") {
    if (secret && secret !== "sandbox") return { ok: false, code: "mode_mismatch" };
    return { ok: true, env: "sandbox", base: SANDBOX_BASE };
  }
  if (dbMode === "live") {
    if (secret !== "live") return { ok: false, code: "mode_mismatch" };
    return { ok: true, env: "live", base: LIVE_BASE };
  }
  return { ok: false, code: "off" };
}

// Stargate Orders API: bank paymentUrl is sandbox-gateway / gateway.
// Card and wallet paymentUrl is sandbox-checkout / checkout (hosted checkout).
// API bases stay sandbox-stargate / stargate. pay.montonio.com is an older session host.
const HOSTS = new Set([
  "sandbox-stargate.montonio.com",
  "stargate.montonio.com",
  "sandbox-gateway.montonio.com",
  "gateway.montonio.com",
  "pay.montonio.com",
  "sandbox-checkout.montonio.com",
  "checkout.montonio.com",
]);

export function safePaymentUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" || !HOSTS.has(u.hostname)) return null;
    return u.href;
  } catch {
    return null;
  }
}

export function isMethod(v: unknown): v is PayMethod {
  return typeof v === "string" && (METHODS as readonly string[]).includes(v);
}

export function euros(amount: number): number {
  return Math.round(amount * 100) / 100;
}

export function centsEqual(a: number, b: number): boolean {
  return Math.round(Number(a) * 100) === Math.round(Number(b) * 100);
}

export class PayError extends Error {
  constructor(public status: number, public op: string, public body: unknown) { super(`pay_${op}_${status}`); }
  get transient() { return this.status === 0 || this.status === 429 || this.status >= 500; }
  summary() {
    const b = this.body as Record<string, unknown> | null;
    const msg = b && typeof b === "object" ? String(b.message || b.error || "").slice(0, 180) : "";
    return { op: this.op, status: this.status, message: msg || null };
  }
}

export function notSettled(detail: unknown): boolean {
  const s = JSON.stringify(detail ?? "").toLowerCase();
  return /not[_ ]?settl|awaiting_settlement|insufficient_funds|settlement/.test(s);
}

export class PayApi {
  constructor(private accessKey: string, private secretKey: string, private base: string, private fetchImpl: Fetch = fetch, private now: () => number = () => Date.now()) {}

  private async token(payload: Record<string, unknown>): Promise<string> {
    const iat = Math.floor(this.now() / 1000);
    return signJwt({ accessKey: this.accessKey, ...payload, iat, exp: iat + 600 }, this.secretKey);
  }

  private async call(op: string, method: string, path: string, body?: unknown, auth?: string): Promise<any> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (body !== undefined) headers["content-type"] = "application/json";
    if (auth) headers.authorization = `Bearer ${auth}`;
    let res: Response;
    try {
      res = await this.fetchImpl(`${this.base}${path}`, { method, headers, body: body !== undefined ? JSON.stringify(body) : undefined });
    } catch (e) {
      throw new PayError(0, op, { message: String((e as Error).message ?? e).slice(0, 160) });
    }
    const text = await res.text();
    let data: unknown = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = { message: text.slice(0, 180) }; }
    if (!res.ok) throw new PayError(res.status, op, data);
    return data;
  }

  async createOrder(p: {
    merchantReference: string; amount: number; currency: string; locale: string;
    returnUrl: string; notificationUrl: string; method: PayMethod; description: string;
  }): Promise<{ paymentUrl?: string; uuid?: string }> {
    const amount = euros(p.amount);
    const methodOptions: Record<string, string> = { paymentDescription: p.description.slice(0, 120) };
    if (p.method === "paymentInitiation") methodOptions.preferredCountry = "FI";
    const data = await this.token({
      merchantReference: p.merchantReference,
      returnUrl: p.returnUrl,
      notificationUrl: p.notificationUrl,
      grandTotal: amount,
      currency: p.currency || "EUR",
      locale: p.locale === "en" ? "en" : p.locale === "sv" ? "sv" : "fi",
      payment: { amount, currency: p.currency || "EUR", method: p.method, methodOptions },
    });
    return this.call("create_order", "POST", "/api/orders", { data });
  }

  async createRefund(p: { orderUuid: string; amount: number; idempotencyKey: string }): Promise<{ uuid?: string; status?: string; refundUuid?: string }> {
    const data = await this.token({
      orderUuid: p.orderUuid,
      amount: euros(p.amount),
      idempotencyKey: p.idempotencyKey,
    });
    return this.call("create_refund", "POST", "/api/refunds", { data });
  }

  async getOrder(orderUuid: string): Promise<Record<string, unknown>> {
    const auth = await this.token({});
    return this.call("get_order", "GET", `/api/orders/${encodeURIComponent(orderUuid)}`, undefined, auth);
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

/** Asiakkaan paluu tilaussivulle. Kyselyparametri on pay=online, ei välittäjän nimeä. */
export function shopReturn(siteBase: string | null | undefined, orderPath: string | null | undefined, orderToken: string | null | undefined): string | null {
  if (!siteBase || !orderToken) return null;
  let base: URL;
  try { base = new URL(siteBase); } catch { return null; }
  if (base.protocol !== "https:") return null;
  const path = orderPath && orderPath.startsWith("/") ? orderPath : "/tilaus/";
  const u = new URL(base.origin + base.pathname.replace(/\/+$/, "") + path);
  u.searchParams.set("t", orderToken);
  u.searchParams.set("pay", "online");
  return u.toString();
}

export function paymentStatusOf(payload: Record<string, unknown>): string {
  return String(payload.paymentStatus || payload.payment_status || "").toUpperCase();
}

export function refundStatusOf(payload: Record<string, unknown>): string {
  return String(payload.refundStatus || payload.status || "").toUpperCase();
}
