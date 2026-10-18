// procountor-sync: päivän myyntikirjaus ja laskun välitys.
// Ilman tunnuksia tai kun mode ei ole live: dry_run, Procountoria ei kutsuta.
// Päiväkirja ei tyhjennä accounting_outboxia (kuitit jonossa eivät ole toinen myyntikirjaus).
import { apiPrefix, originFor, ProcountorClient, ProcountorError, readCreds, type Env, type Fetch } from "./client.ts";
import { buildProcountorInvoice, linkCustomer, type NormalizedInvoice } from "./invoice.ts";

export type RpcResult = { data: any; error: { message?: string; details?: string; code?: string } | null };
export type Db = {
  cronOk(secret: string | null): Promise<boolean>;
  config(): Promise<{ mode: string; settings: Record<string, unknown> }>;
  dailyPrepare(date: string | null, forceDryRun: boolean): Promise<any>;
  invoiceReserve(args: { key: string; request: unknown; channel: string; businessDate: string; blockers: string[]; forceDryRun: boolean }): Promise<any>;
  mark(id: number, status: string, error: string | null, response: Record<string, unknown> | null): Promise<any>;
};

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

function dbError(e: RpcResult["error"]) {
  if (!e) return null;
  return { code: e.code === "BK001" && e.details ? e.details : (e.code ?? "db_error"), message: e.message ?? "" };
}

function postBody(request: Record<string, unknown>) {
  const { status: _status, ...rest } = request;
  return rest;
}

async function markFailure(db: Db, id: number, err: unknown) {
  if (err instanceof ProcountorError && (err.status === 0 || err.status >= 500)) {
    await db.mark(id, "needs_review", `post_unconfirmed:${err.op}:${err.status}`, null);
    return { status: "needs_review", error: "post_unconfirmed" };
  }
  const summary = err instanceof ProcountorError ? err.summary() : { op: "send", status: 0, message: String((err as Error)?.message ?? err) };
  await db.mark(id, "failed", `${summary.op}:${summary.status}:${summary.message}`.slice(0, 500), null);
  return { status: "failed", error: summary.message || summary.op };
}

export async function deliverInvoice(args: {
  db: Db;
  client: ProcountorClient | null;
  invoice: NormalizedInvoice;
  idempotencyKey: string;
  settings: Record<string, unknown>;
  forceDryRun: boolean;
}): Promise<{ http: number; body: Record<string, unknown> }> {
  const built = buildProcountorInvoice(args.invoice, {
    vatStatus: args.settings.vat_status as string | number | null,
    bankAccount: args.settings.bank_account as string | null,
  });
  if (!built.ok || !built.channel || !built.request) {
    return { http: 400, body: { ok: false, error: "invalid_invoice", errors: built.errors, blockers: built.blockers } };
  }
  const reserved = await args.db.invoiceReserve({
    key: args.idempotencyKey,
    request: built.request,
    channel: built.channel,
    businessDate: args.invoice.date,
    blockers: built.blockers,
    forceDryRun: args.forceDryRun,
  });
  if (reserved?.action === "already") {
    return { http: 200, body: { ok: true, action: "already", id: reserved.id, invoice_id: reserved.invoice_id ?? null, status: "sent" } };
  }
  if (reserved?.action === "in_progress") return { http: 409, body: { ok: false, error: "in_progress", id: reserved.id } };
  if (reserved?.action !== "send") {
    return { http: 200, body: { ok: true, action: reserved?.action ?? "dry_run", id: reserved?.id, status: reserved?.status, reason: reserved?.reason ?? null, channel: built.channel, request: built.request } };
  }
  if (!args.client) {
    await args.db.mark(reserved.id, "dry_run", "credentials_missing", null);
    return { http: 200, body: { ok: true, action: "dry_run", id: reserved.id, status: "dry_run", reason: "credentials_missing", request: built.request } };
  }
  const id = reserved.id as number;
  let step = (reserved.step as string | null) ?? null;
  let invoiceId = reserved.invoice_id as number | null;
  try {
    if (!invoiceId) {
      const linked = await linkCustomer(args.client, args.invoice, built.channel);
      const body = postBody(built.request);
      if (linked.partnerId) body.partnerId = linked.partnerId;
      const created = await args.client.call("invoice_create", "POST", "/invoices", { body }) as { id?: number; ledgerReceiptId?: number };
      if (!created?.id) {
        await args.db.mark(id, "needs_review", "post_unconfirmed:invoice_create:no_id", null);
        return { http: 502, body: { ok: false, error: "post_unconfirmed", id } };
      }
      invoiceId = created.id;
      step = "created";
      await args.db.mark(id, "processing", null, { invoice_id: invoiceId, ledger_receipt_id: created.ledgerReceiptId ?? null, step, warnings: linked.warnings });
    }
    if (step !== "approved" && step !== "sent") {
      await args.client.call("invoice_approve", "PUT", `/invoices/${invoiceId}/approve`, { body: {} });
      step = "approved";
      await args.db.mark(id, "processing", null, { invoice_id: invoiceId, step });
    }
    await args.client.call("invoice_send", "PUT", `/invoices/${invoiceId}/send`, { body: {} });
    await args.db.mark(id, "sent", null, { invoice_id: invoiceId, step: "sent" });
    return { http: 200, body: { ok: true, action: "sent", id, invoice_id: invoiceId, status: "sent", channel: built.channel } };
  } catch (e) {
    const unconfirmed = e instanceof ProcountorError && (e.status === 0 || e.status >= 500);
    const summary = e instanceof ProcountorError ? e.summary() : { op: "send", status: 0, message: String((e as Error)?.message ?? e) };
    const status = unconfirmed ? "needs_review" : "failed";
    const message = unconfirmed ? `post_unconfirmed:${summary.op}:${summary.status}` : `${summary.op}:${summary.status}:${summary.message}`.slice(0, 500);
    await args.db.mark(id, status, message, invoiceId ? { invoice_id: invoiceId, step: step ?? "created" } : null);
    return { http: 502, body: { ok: false, error: unconfirmed ? "post_unconfirmed" : (summary.message || summary.op), id, invoice_id: invoiceId, status } };
  }
}

export async function handle(req: Request, deps: { db: Db; env: Env; fetchImpl?: Fetch }): Promise<Response> {
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  const ok = await deps.db.cronOk(req.headers.get("x-sync-secret"));
  if (!ok) return json({ ok: false, error: "unauthorized" }, 401);
  let payload: any = {};
  try { payload = await req.json(); } catch { payload = {}; }
  const cfg = await deps.db.config();
  const settings = cfg.settings ?? {};
  const environment = settings.environment === "prod" ? "prod" : "pts";
  const creds = readCreds(deps.env);
  const forceDryRun = cfg.mode !== "live" || !creds;
  const client = creds ? new ProcountorClient(creds, environment, apiPrefix(String(settings.api_prefix ?? "")), deps.fetchImpl) : null;

  const action = payload?.action === "send_invoice" ? "send_invoice" : "daily";
  if (action === "daily") {
    let prepared: any;
    try { prepared = await deps.db.dailyPrepare(typeof payload?.date === "string" ? payload.date : null, !creds); }
    catch (e) { return json({ ok: false, error: dbError(e as RpcResult["error"]) ?? { code: "db_error", message: String((e as Error).message ?? e) } }, 500); }
    if (prepared?.action !== "send") {
      return json({ ok: true, action: prepared?.action ?? "skip", id: prepared?.id ?? null, status: prepared?.status ?? null, business_date: prepared?.business_date ?? null, reason: prepared?.reason ?? null, environment: originFor(environment) === "https://api.procountor.com" ? "prod" : "pts", request: prepared?.request ?? null });
    }
    if (!client) {
      await deps.db.mark(prepared.id, "dry_run", "credentials_missing", null);
      return json({ ok: true, action: "dry_run", id: prepared.id, status: "dry_run", reason: "credentials_missing", business_date: prepared.business_date });
    }
    try {
      const saved = await client.call("ledger", "POST", "/ledgerreceipts", { query: { createReconciliation: "true" }, body: postBody(prepared.request) }) as { id?: number };
      if (!saved?.id) {
        await deps.db.mark(prepared.id, "needs_review", "post_unconfirmed:ledger:no_id", null);
        return json({ ok: false, error: "post_unconfirmed", id: prepared.id }, 502);
      }
      await deps.db.mark(prepared.id, "sent", null, { ledger_receipt_id: saved.id, step: "sent" });
      return json({ ok: true, action: "sent", id: prepared.id, status: "sent", business_date: prepared.business_date, ledger_receipt_id: saved.id });
    } catch (e) {
      const marked = await markFailure(deps.db, prepared.id, e);
      return json({ ok: false, error: marked.error, id: prepared.id, status: marked.status }, 502);
    }
  }

  const key = typeof payload?.idempotency_key === "string" ? payload.idempotency_key : "";
  if (!/^[A-Za-z0-9._:-]{1,120}$/.test(key)) return json({ ok: false, error: "invalid_param", message: "idempotency_key" }, 400);
  try {
    const out = await deliverInvoice({ db: deps.db, client: forceDryRun ? null : client, invoice: payload.invoice, idempotencyKey: key, settings, forceDryRun });
    return json(out.body, out.http);
  } catch (e) {
    const err = dbError((e as { error?: RpcResult["error"] }).error ?? null);
    return json({ ok: false, error: err ?? { code: "db_error", message: String((e as Error).message ?? e) } }, 500);
  }
}

export function realDb(createClient: (url: string, key: string, opts: unknown) => any, env: Env): Db {
  const sb = createClient(env.get("SUPABASE_URL")!, env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const bk = sb.schema("booking");
  const unwrap = async (p: Promise<RpcResult>) => {
    const r = await p;
    if (r.error) throw r.error;
    return r.data;
  };
  return {
    cronOk: async (secret) => {
      const r = await bk.rpc("_cron_secret_ok", { p_secret: secret });
      return !r.error && r.data === true;
    },
    config: async () => {
      const r = await bk.from("integration_config").select("mode,settings").eq("key", "procountor").maybeSingle();
      if (r.error) throw r.error;
      return { mode: r.data?.mode ?? "off", settings: r.data?.settings ?? {} };
    },
    dailyPrepare: (date, forceDryRun) => unwrap(bk.rpc("procountor_daily_prepare", { p_date: date, p_force_dry_run: forceDryRun })),
    invoiceReserve: (a) => unwrap(bk.rpc("procountor_invoice_reserve", {
      p_key: a.key, p_request: a.request, p_channel: a.channel, p_business_date: a.businessDate, p_blockers: a.blockers, p_force_dry_run: a.forceDryRun,
    })),
    mark: (id, status, error, response) => unwrap(bk.rpc("procountor_export_mark", { p_id: id, p_status: status, p_error: error, p_response: response })),
  };
}
