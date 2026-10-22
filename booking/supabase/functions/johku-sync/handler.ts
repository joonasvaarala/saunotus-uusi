// johku-sync: vain Johku-rivien upsert ja peruutus. Ei lukuavaimia, ei muita tauluja.
// Tunnistus: otsake x-johku-sync-secret == JOHKU_SYNC_SECRET (vakiokokoinen vertailu).
import { secretOk } from "./auth.ts";

export type Env = { get(name: string): string | undefined };
export type RpcResult = { data: unknown; error: { message?: string; details?: string; code?: string } | null };
export type Db = {
  state(): Promise<unknown>;
  apply(payload: unknown): Promise<unknown>;
  giftCards(rows: unknown): Promise<unknown>;
  log(row: unknown): Promise<unknown>;
};

const FORBIDDEN = new Set([
  "payments", "receipts", "email_outbox", "accounting_outbox", "refunds",
  "payment_lines", "hidden_at", "service_role", "service_role_key",
]);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

export function forbiddenKey(node: unknown): string | null {
  if (Array.isArray(node)) {
    for (const x of node) {
      const hit = forbiddenKey(x);
      if (hit) return hit;
    }
    return null;
  }
  if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node as Record<string, unknown>)) {
      if (FORBIDDEN.has(k)) return k;
      const hit = forbiddenKey(v);
      if (hit) return hit;
    }
  }
  return null;
}

function rpcError(e: RpcResult["error"] | null) {
  if (!e) return { code: "db_error" };
  const code = e.code === "BK001" && e.details ? e.details : (e.details || e.code || "db_error");
  return { code: String(code).slice(0, 80) };
}

export async function handle(req: Request, deps: { db: Db; env: Env }): Promise<Response> {
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  const expected = deps.env.get("JOHKU_SYNC_SECRET");
  if (!expected) return json({ ok: false, error: "misconfigured" }, 503);
  if (!secretOk(expected, req.headers.get("x-johku-sync-secret"))) return json({ ok: false, error: "unauthorized" }, 401);
  let payload: Record<string, unknown> = {};
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return json({ ok: false, error: "invalid_json" }, 400);
  const bad = forbiddenKey(payload);
  if (bad) return json({ ok: false, error: "forbidden_key", key: bad }, 400);
  const action = payload.action;
  try {
    if (action === "state") return json({ ok: true, state: await deps.db.state() });
    if (action === "apply") return json({ ok: true, result: await deps.db.apply(payload.payload ?? {}) });
    if (action === "gift_cards") {
      const rows = payload.rows;
      if (!Array.isArray(rows)) return json({ ok: false, error: "invalid_param" }, 400);
      const result = await deps.db.giftCards(rows);
      return json({ ok: true, result });
    }
    if (action === "log") return json({ ok: true, result: await deps.db.log(payload.row ?? {}) });
    return json({ ok: false, error: "unknown_action" }, 400);
  } catch (e) {
    const err = (e as { error?: RpcResult["error"] }).error ?? (e as RpcResult["error"]);
    return json({ ok: false, error: rpcError(err && typeof err === "object" ? err : { message: "db_error" }) }, 500);
  }
}

export function realDb(createClient: (url: string, key: string, opts: unknown) => {
  schema: (name: string) => { rpc: (fn: string, args?: Record<string, unknown>) => Promise<RpcResult> };
}, env: Env): Db {
  const sb = createClient(env.get("SUPABASE_URL")!, env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const bk = sb.schema("booking");
  const unwrap = async (p: Promise<RpcResult>) => {
    const r = await p;
    if (r.error) {
      const wrapped = new Error("rpc") as Error & { error: RpcResult["error"] };
      wrapped.error = r.error;
      throw wrapped;
    }
    return r.data;
  };
  return {
    state: () => unwrap(bk.rpc("svc_johku_sync_state")),
    apply: (payload) => unwrap(bk.rpc("svc_johku_sync_apply", { p_payload: payload })),
    giftCards: (rows) => unwrap(bk.rpc("svc_gift_cards_johku_upsert", { p_rows: rows })),
    log: (row) => unwrap(bk.rpc("svc_johku_sync_log", { p_row: row })),
  };
}
