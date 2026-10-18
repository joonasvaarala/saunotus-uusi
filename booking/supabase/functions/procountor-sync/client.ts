// Procountor API -asiakas (M2M, client credentials). Ei salaisuuksia koodissa.
// Lähde: https://dev.procountor.com/m2m-authentication/ ja OpenAPI https://pts-api.procountor.com/api/openapi.json (26.10, haettu 18.10.2026).
// Tunnukset: PROCOUNTOR_CLIENT_ID, PROCOUNTOR_CLIENT_SECRET, PROCOUNTOR_API_KEY, PROCOUNTOR_REDIRECT_URI.

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;
export type Env = { get(key: string): string | undefined };

export const PTS_ORIGIN = "https://pts-api.procountor.com";
export const PROD_ORIGIN = "https://api.procountor.com";
export const SECRET_NAMES = ["PROCOUNTOR_CLIENT_ID", "PROCOUNTOR_CLIENT_SECRET", "PROCOUNTOR_API_KEY", "PROCOUNTOR_REDIRECT_URI"] as const;
const PREFIX_RE = /^\/(?:api|latest\/api|supported\/api|v\d{4}\/api)$/;
const SECRET_KEYS = ["access_token", "api_key", "client_secret", "refresh_token", "authorization", "redirect_uri"];

export type Creds = { clientId: string; clientSecret: string; apiKey: string; redirectUri: string };

export function originFor(environment: string | null | undefined): string {
  return environment === "prod" ? PROD_ORIGIN : PTS_ORIGIN;
}

/** Sallitut polkuetuliitteet. Tuntematon arvo ei ohjaa mielivaltaiseen osoitteeseen. */
export function apiPrefix(raw: string | null | undefined): string {
  const p = (raw ?? "").trim();
  return PREFIX_RE.test(p) ? p : "/supported/api";
}

export function readCreds(env: Env): Creds | null {
  const clientId = env.get("PROCOUNTOR_CLIENT_ID");
  const clientSecret = env.get("PROCOUNTOR_CLIENT_SECRET");
  const apiKey = env.get("PROCOUNTOR_API_KEY");
  const redirectUri = env.get("PROCOUNTOR_REDIRECT_URI");
  if (!clientId || !clientSecret || !apiKey || !redirectUri) return null;
  return { clientId, clientSecret, apiKey, redirectUri };
}

export function redact(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = SECRET_KEYS.includes(k.toLowerCase()) ? "[redacted]" : redact(v);
    }
    return out;
  }
  return value;
}

export class ProcountorError extends Error {
  constructor(public status: number, public op: string, public body: unknown) { super(`procountor_${op}_${status}`); }
  /** POST-uudelleenyritys vain 429:lle. Verkkovirhe (0) ei ole automaattinen uudelleenyritys. */
  get retryablePost() { return this.status === 429; }
  summary() {
    const b = this.body as { errors?: { status?: number; message?: string }[] } | null;
    const messages = Array.isArray(b?.errors) ? b!.errors.map((e) => e?.message).filter(Boolean).join("; ") : "";
    return { op: this.op, status: this.status, message: messages.slice(0, 400) };
  }
}

export class ProcountorClient {
  private token: { value: string; exp: number } | null = null;
  constructor(
    private creds: Creds,
    private environment: string,
    private prefix: string,
    private fetchImpl: Fetch = fetch,
    private now: () => number = () => Date.now(),
  ) {}

  get origin() { return originFor(this.environment); }

  private async raw(op: string, url: string, init: RequestInit): Promise<{ status: number; data: unknown }> {
    let res: Response;
    try { res = await this.fetchImpl(url, init); }
    catch (e) { throw new ProcountorError(0, op, { errors: [{ message: String((e as Error).message ?? e) }] }); }
    const text = await res.text();
    let data: unknown = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = { errors: [{ message: text.slice(0, 300) }] }; }
    return { status: res.status, data };
  }

  async getToken(force = false): Promise<string> {
    if (!force && this.token && this.token.exp > this.now() + 60_000) return this.token.value;
    const body = new URLSearchParams({
      grant_type: "client_credentials",
      client_id: this.creds.clientId,
      client_secret: this.creds.clientSecret,
      redirect_uri: this.creds.redirectUri,
      api_key: this.creds.apiKey,
    });
    const { status, data } = await this.raw("token", `${this.origin}/api/oauth/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    const token = (data as { access_token?: string; expires_in?: number } | null)?.access_token;
    if (status < 200 || status >= 300 || !token) throw new ProcountorError(status || 502, "token", redact(data));
    const ttl = Number((data as { expires_in?: number }).expires_in ?? 3600) * 1000;
    this.token = { value: token, exp: this.now() + ttl };
    return token;
  }

  async call(op: string, method: string, path: string, opts: { query?: Record<string, string>; body?: unknown; headers?: Record<string, string> } = {}): Promise<unknown> {
    const q = opts.query ? "?" + new URLSearchParams(opts.query).toString() : "";
    const url = `${this.origin}${this.prefix}${path}${q}`;
    const send = async (fresh: boolean) => {
      const headers: Record<string, string> = { authorization: `Bearer ${await this.getToken(fresh)}`, accept: "application/json", ...opts.headers };
      if (opts.body !== undefined) headers["content-type"] = "application/json";
      return this.raw(op, url, { method, headers, body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined });
    };
    let res = await send(false);
    if (res.status === 401) {
      this.token = null;
      res = await send(true);
    }
    const retryPost = method === "POST" || method === "PUT" ? res.status === 429 : (res.status === 429 || res.status >= 500);
    if (retryPost) res = await send(false);
    if (res.status < 200 || res.status >= 300) throw new ProcountorError(res.status, op, redact(res.data));
    return res.data;
  }
}
