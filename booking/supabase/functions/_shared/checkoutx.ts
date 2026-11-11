// CheckoutX (Surfboard Payments) – Pikakassan kortti puhelimella. Vain demo-ympäristö (booking_286).
// Ohjeet: https://www.surfboardpayments.com/developers/guides/interapp-integration/
// Avaimet vain Edge-salaisuuksina. Selaimeen ei koskaan palauteta avainta, salaisuutta eikä API-osoitetta.
import type { Env, Fetch } from "./mobilepay.ts";

export const SECRET_NAMES = ["SURFBOARD_API_URL", "SURFBOARD_API_KEY", "SURFBOARD_API_SECRET", "SURFBOARD_MERCHANT_ID"] as const;
export const REGISTER_SECRET_NAMES = [...SECRET_NAMES, "SURFBOARD_STORE_ID"] as const;
/** ISO 4217 numeerinen: EUR. */
export const CURRENCY_EUR = "978";
export const DEEP_LINK_BASE = "checkoutx://com.surfboard.checkoutx";
/** Selainkassan paluu: Android Chrome tuodaan eteen samaan välilehteen (Surfboardin varmistama). */
export const RETURN_TARGETS: Record<string, string> = {
  chrome: "googlechrome://com.android.chrome",
};
const ID_RE = /^[A-Za-z0-9_-]{4,64}$/;

export type CxConfig = { apiUrl: string; apiKey: string; apiSecret: string; merchantId: string; storeId: string | null };

/** CHECKOUTX_ENV=demo on pakollinen. Muuten (myös live) → null: tässä versiossa ei ole tuotantotilaa. */
export function envAllowed(env: Env): boolean {
  return (env.get("CHECKOUTX_ENV") ?? "").trim() === "demo";
}

export function missingSecrets(env: Env, names: readonly string[] = SECRET_NAMES): string[] {
  return names.filter((n) => !(env.get(n) ?? "").trim());
}

export function readConfig(env: Env): CxConfig | null {
  if (missingSecrets(env).length) return null;
  const raw = env.get("SURFBOARD_API_URL")!.trim().replace(/\/+$/, "");
  let u: URL;
  try { u = new URL(raw); } catch { return null; }
  if (u.protocol !== "https:") return null;
  return {
    apiUrl: raw,
    apiKey: env.get("SURFBOARD_API_KEY")!.trim(),
    apiSecret: env.get("SURFBOARD_API_SECRET")!.trim(),
    merchantId: env.get("SURFBOARD_MERCHANT_ID")!.trim(),
    storeId: (env.get("SURFBOARD_STORE_ID") ?? "").trim() || null,
  };
}

/** URL-turvallinen base64 ilman täytettä (Surfboardin JS-esimerkki). UTF-8. */
export function b64url(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function returnUrl(target: unknown): string {
  return RETURN_TARGETS[typeof target === "string" ? target : "chrome"] ?? RETURN_TARGETS.chrome;
}

export function transactionLink(terminalId: string, interAppJwt: string, target: unknown = "chrome"): string {
  const data = b64url(JSON.stringify({ terminalId, interAppJWToken: interAppJwt }));
  return `${DEEP_LINK_BASE}/transaction?redirectUrl=${b64url(returnUrl(target))}&data=${data}`;
}

export function registerLink(registrationCode: string, target: unknown = "chrome"): string {
  const data = b64url(JSON.stringify({ registrationCode }));
  return `${DEEP_LINK_BASE}/register?redirectUrl=${b64url(returnUrl(target))}&data=${data}`;
}

export function configureLink(target: unknown = "chrome"): string {
  return `${DEEP_LINK_BASE}/configure?redirectUrl=${b64url(returnUrl(target))}`;
}

export const toMinor = (eur: number) => Math.round(Number(eur) * 100);
export const validId = (s: unknown): s is string => typeof s === "string" && ID_RE.test(s);

export type OrderOutcome = { state: "pending" | "paid" | "failed" | "cancelled"; orderStatus: string | null; paymentId: string | null; failureReason: string | null };

/** GET /orders/:id/status → tila. Tuntematon tila = pending (lista on avoin, uusia arvoja tulee ilmoittamatta). */
export function mapOrderStatus(data: any): OrderOutcome {
  const orderStatus = typeof data?.orderStatus === "string" ? data.orderStatus : null;
  const payments: any[] = Array.isArray(data?.payments) ? data.payments : [];
  const completed = payments.find((p) => p?.paymentStatus === "PAYMENT_COMPLETED");
  const ids: any[] = Array.isArray(data?.paymentIds) ? data.paymentIds : [];
  const paymentId = (completed?.paymentId ?? ids[0] ?? null) as string | null;
  const last = payments.length ? payments[payments.length - 1] : null;
  const failureReason = (last?.failureReason ?? null) as string | null;
  if (orderStatus === "PAYMENT_COMPLETED") return { state: "paid", orderStatus, paymentId, failureReason: null };
  if (orderStatus === "PAYMENT_CANCELLED") return { state: "cancelled", orderStatus, paymentId: null, failureReason };
  const busy = payments.some((p) => ["PAYMENT_INITIATED", "PAYMENT_PROCESSING", "PAYMENT_PROCESSED"].includes(p?.paymentStatus));
  if (orderStatus === "PENDING" && payments.length && !busy && payments.every((p) => ["PAYMENT_FAILED", "PAYMENT_CANCELLED"].includes(p?.paymentStatus))) {
    return { state: last?.paymentStatus === "PAYMENT_CANCELLED" ? "cancelled" : "failed", orderStatus, paymentId: null, failureReason };
  }
  return { state: "pending", orderStatus, paymentId: null, failureReason: null };
}

export class CxError extends Error {
  constructor(public code: string, message: string, public status: number | null = null, public transient = false) { super(message); }
  summary() { return { code: this.code, status: this.status, message: this.message.slice(0, 200) }; }
}

/** Surfboard Carbon API. Vastaus { status: SUCCESS|ERROR, data, message }; virheet tulevat usein HTTP 200:lla. */
export class SurfboardApi {
  constructor(private cfg: CxConfig, private fetchFn: Fetch) {}

  private async call(method: string, path: string, body?: unknown): Promise<any> {
    let res: Response;
    try {
      res = await this.fetchFn(this.cfg.apiUrl + path, {
        method,
        headers: {
          "content-type": "application/json",
          "API-KEY": this.cfg.apiKey,
          "API-SECRET": this.cfg.apiSecret,
          "MERCHANT-ID": this.cfg.merchantId,
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (e) {
      throw new CxError("network", (e as Error).message || "network", null, true);
    }
    const text = await res.text();
    let j: any = null;
    try { j = text ? JSON.parse(text) : null; } catch { /* ei JSON */ }
    if (res.status === 401 || res.status === 403) throw new CxError("unauthorized", j?.message || "unauthorized", res.status);
    if (res.status >= 500 || res.status === 429) throw new CxError("provider_unavailable", j?.message || `HTTP ${res.status}`, res.status, true);
    if (!res.ok) throw new CxError("provider_error", j?.message || `HTTP ${res.status}`, res.status);
    if (!j || j.status !== "SUCCESS") throw new CxError("provider_error", j?.message || "ERROR", res.status);
    return j.data ?? {};
  }

  createOrder(a: { terminalId: string; referenceId: string; amountMinor: number; lineName: string; lineId: string }) {
    const amount = { regular: a.amountMinor, total: a.amountMinor, currency: CURRENCY_EUR };
    return this.call("POST", "/orders", {
      "terminal$id": a.terminalId,
      referenceId: a.referenceId,
      orderLines: [{ id: a.lineId, name: a.lineName, quantity: 1, amount }],
      totalOrderAmount: { regular: a.amountMinor, total: a.amountMinor, currency: CURRENCY_EUR },
      controlFunctions: { initiatePaymentsOptions: { paymentMethod: "CARD" }, cancelPreviousPendingOrder: true },
    }) as Promise<{ orderId?: string; paymentId?: string; interAppJWT?: string }>;
  }
  orderStatus(orderId: string) { return this.call("GET", `/orders/${encodeURIComponent(orderId)}/status`); }
  cancelOrder(orderId: string) { return this.call("DELETE", `/orders/${encodeURIComponent(orderId)}`); }
  voidPayment(paymentId: string) { return this.call("PUT", `/payments/${encodeURIComponent(paymentId)}/void`); }
  interappCode() {
    if (!this.cfg.storeId) throw new CxError("not_configured", "SURFBOARD_STORE_ID puuttuu");
    return this.call("GET", `/merchants/${encodeURIComponent(this.cfg.merchantId)}/stores/${encodeURIComponent(this.cfg.storeId)}/terminals/interapp`) as Promise<{ registrationCode?: string }>;
  }
  interappDetails(code: string) {
    if (!this.cfg.storeId) throw new CxError("not_configured", "SURFBOARD_STORE_ID puuttuu");
    return this.call("GET", `/merchants/${encodeURIComponent(this.cfg.merchantId)}/stores/${encodeURIComponent(this.cfg.storeId)}/terminals/interapp/${encodeURIComponent(code)}`) as Promise<{ registrationStatus?: string; terminalId?: string }>;
  }
}
