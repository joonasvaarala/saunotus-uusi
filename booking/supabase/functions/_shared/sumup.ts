// SumUp Solo + Cloud API – Pikakassan korttipääte (booking_295). Dokumentaatio: https://developer.sumup.com/terminal-payments/cloud-api/
// Avaimet vain Edge-salaisuuksina. Selaimeen ei koskaan palauteta avainta, affiliate keytä eikä webhook-salaisuutta.
// HUOM: endpointit ja kentät on kirjattu SumUpin dokumentaation mukaan, mutta niitä ei ole ajettu oikeaa SumUpia vastaan (ks. SUMUP_TILA.md).
import type { Env, Fetch } from "./mobilepay.ts";

export const SECRET_NAMES = ["SUMUP_API_KEY", "SUMUP_AFFILIATE_KEY", "SUMUP_AFFILIATE_APP_ID", "SUMUP_MERCHANT_CODE", "SUMUP_WEBHOOK_SECRET"] as const;
export const DEFAULT_API_URL = "https://api.sumup.com";
const ID_RE = /^[A-Za-z0-9_-]{4,64}$/;
const PAIRING_RE = /^[A-Za-z0-9]{6,12}$/;

export type SumupConfig = { apiUrl: string; apiKey: string; affiliateKey: string; appId: string; merchantCode: string; webhookSecret: string };

/** SUMUP_ENV: test-tila vaatii 'sandbox', live-tila 'live'. Ristiin kytkentä (esim. sandbox-avaimet liveen) estetään. */
export function envMatchesMode(env: Env, mode: string): boolean {
  const e = (env.get("SUMUP_ENV") ?? "").trim();
  return (mode === "test" && e === "sandbox") || (mode === "live" && e === "live");
}

export function missingSecrets(env: Env): string[] {
  return SECRET_NAMES.filter((n) => !(env.get(n) ?? "").trim());
}

export function readConfig(env: Env): SumupConfig | null {
  if (missingSecrets(env).length) return null;
  const raw = (env.get("SUMUP_API_URL") ?? DEFAULT_API_URL).trim().replace(/\/+$/, "");
  let u: URL;
  try { u = new URL(raw); } catch { return null; }
  if (u.protocol !== "https:") return null;
  const mc = env.get("SUMUP_MERCHANT_CODE")!.trim();
  if (!/^[A-Za-z0-9_-]{2,32}$/.test(mc)) return null;
  return {
    apiUrl: raw,
    apiKey: env.get("SUMUP_API_KEY")!.trim(),
    affiliateKey: env.get("SUMUP_AFFILIATE_KEY")!.trim(),
    appId: env.get("SUMUP_AFFILIATE_APP_ID")!.trim(),
    merchantCode: mc,
    webhookSecret: env.get("SUMUP_WEBHOOK_SECRET")!.trim(),
  };
}

export const validId = (s: unknown): s is string => typeof s === "string" && ID_RE.test(s);
export const validPairingCode = (s: unknown): s is string => typeof s === "string" && PAIRING_RE.test(s.trim());
export const toMinor = (eur: number) => Math.round(Number(eur) * 100);

/** Vakioaikainen merkkijonovertailu (webhook-salaisuus). */
export function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

export type TxOutcome = { state: "pending" | "paid" | "failed" | "cancelled"; status: string | null; transactionId: string | null; amount: number | null; currency: string | null };

/** GET transactions?client_transaction_id=… → tila. Tuntematon tila = pending. Vain SUCCESSFUL on paid. */
export function mapTransaction(data: any): OutcomeOrNull {
  if (!data || typeof data !== "object") return null;
  const status = typeof data.status === "string" ? data.status.toUpperCase() : null;
  const transactionId = validId(data.id) ? data.id : validId(data.transaction_id) ? data.transaction_id : null;
  const amount = typeof data.amount === "number" ? data.amount : null;
  const currency = typeof data.currency === "string" ? data.currency : null;
  const state = status === "SUCCESSFUL" ? "paid" : status === "FAILED" ? "failed" : status === "CANCELLED" ? "cancelled" : "pending";
  return { state, status, transactionId, amount, currency };
}
type OutcomeOrNull = TxOutcome | null;

export class SumupError extends Error {
  constructor(public code: string, message: string, public status: number | null = null, public transient = false) { super(message); }
  summary() { return { code: this.code, status: this.status, message: this.message.slice(0, 200) }; }
}

export class SumupApi {
  constructor(private cfg: SumupConfig, private fetchFn: Fetch) {}
  private get m() { return encodeURIComponent(this.cfg.merchantCode); }

  private async call(method: string, path: string, body?: unknown, okEmpty = false): Promise<any> {
    let res: Response;
    try {
      res = await this.fetchFn(this.cfg.apiUrl + path, {
        method,
        headers: { "content-type": "application/json", authorization: `Bearer ${this.cfg.apiKey}` },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (e) {
      throw new SumupError("network", (e as Error).message || "network", null, true);
    }
    const text = await res.text();
    let j: any = null;
    try { j = text ? JSON.parse(text) : null; } catch { /* ei JSON */ }
    const msg = String(j?.message ?? j?.error_message ?? j?.detail ?? `HTTP ${res.status}`);
    if (res.status === 401 || res.status === 403) throw new SumupError("unauthorized", msg, res.status);
    if (res.status === 404) throw new SumupError("not_found", msg, res.status);
    if (res.status === 429 || res.status >= 500) throw new SumupError("provider_unavailable", msg, res.status, true);
    if (!res.ok) throw new SumupError("provider_error", msg, res.status);
    return j ?? (okEmpty ? {} : {});
  }

  /** POST /v0.1/merchants/{code}/readers {pairing_code, name} → lukija (status processing → paired kun lukija vahvistaa). */
  pairReader(pairingCode: string, name: string) {
    return this.call("POST", `/v0.1/merchants/${this.m}/readers`, { pairing_code: pairingCode.trim().toUpperCase(), name }) as Promise<{ id?: string; name?: string; status?: string; device?: { model?: string } }>;
  }
  /** GET /v0.1/merchants/{code}/readers → { items: [...] } */
  listReaders() {
    return this.call("GET", `/v0.1/merchants/${this.m}/readers`) as Promise<{ items?: { id?: string; name?: string; status?: string }[] }>;
  }
  getReader(readerId: string) {
    return this.call("GET", `/v0.1/merchants/${this.m}/readers/${encodeURIComponent(readerId)}`) as Promise<{ id?: string; name?: string; status?: string }>;
  }
  /**
   * POST /v0.1/merchants/{code}/readers/{id}/checkout. total_amount.value on pienimmässä yksikössä (minor_unit 2).
   * affiliate (app_id, key, foreign_transaction_id) lisätään palvelimella. return_url = webhook (sumup-notify, salaisuus kyselyparametrina).
   * Vastaus 201: { data: { client_transaction_id } }.
   */
  readerCheckout(a: { readerId: string; amountMinor: number; currency: string; foreignId: string; description: string; returnUrl: string | null }) {
    const body: Record<string, unknown> = {
      total_amount: { value: a.amountMinor, currency: a.currency, minor_unit: 2 },
      description: a.description,
      affiliate: { app_id: this.cfg.appId, key: this.cfg.affiliateKey, foreign_transaction_id: a.foreignId },
    };
    if (a.returnUrl) body.return_url = a.returnUrl;
    return this.call("POST", `/v0.1/merchants/${this.m}/readers/${encodeURIComponent(a.readerId)}/checkout`, body) as Promise<{ data?: { client_transaction_id?: string } }>;
  }
  /** POST …/readers/{id}/terminate (202): keskeyttää lukijan käynnissä olevan checkoutin. */
  readerTerminate(readerId: string) {
    return this.call("POST", `/v0.1/merchants/${this.m}/readers/${encodeURIComponent(readerId)}/terminate`, {}, true);
  }
  /** GET /v2.1/merchants/{code}/transactions?client_transaction_id=… → transaktio (404 = ei vielä olemassa). */
  async transactionByClientId(clientTxId: string): Promise<TxOutcome | null> {
    try {
      const d = await this.call("GET", `/v2.1/merchants/${this.m}/transactions?client_transaction_id=${encodeURIComponent(clientTxId)}`);
      return mapTransaction(Array.isArray(d?.items) ? d.items[0] : d);
    } catch (e) {
      if (e instanceof SumupError && e.code === "not_found") return null;
      throw e;
    }
  }
  /** POST /v0.1/me/refund/{txn_id} (204). Ilman amount-kenttää koko summa; osittainen vain, jos amount annetaan. */
  refund(transactionId: string, amountEur?: number) {
    return this.call("POST", `/v0.1/me/refund/${encodeURIComponent(transactionId)}`, amountEur === undefined ? {} : { amount: amountEur }, true);
  }
}
