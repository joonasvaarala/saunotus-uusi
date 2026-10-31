// booking_153 sääntö 8: henkilökunnan oma sivu (pysyvä henkilökohtainen linkki ilman kirjautumista).
// GET  /api/my?token=…            → omat avoimet ja vastatut vuorot (booking.shift_staff_page)
// POST /api/my/respond {token, offer_id, response: accept|decline} → vastaus tai sen muutos
// Token tarkistetaan tietokannassa (HMAC + nonce, uusittavissa ja peruttavissa hallinnasta).
// Vastauksessa on vain tämän henkilön omat tiedot, ei muiden nimiä. Ei HTML:ää.

import { corsHeaders, pageOrigins } from "./core.ts";

export type MyPageDb = {
  rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: { message?: string } | null }>;
};

export type MyRoute = "my" | "my_respond" | "my_options" | "invalid" | null;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN = /^[A-Za-z0-9_-]{20,400}\.[A-Za-z0-9_-]{20,100}$/;

export function myRoute(method: string, pathname: string): MyRoute {
  const my = pathname.endsWith("/api/my");
  const respond = pathname.endsWith("/api/my/respond");
  if (!my && !respond) return null;
  if (method === "OPTIONS") return "my_options";
  if (my) return method === "GET" ? "my" : "invalid";
  return method === "POST" ? "my_respond" : "invalid";
}

export function validStaffToken(token: unknown): token is string {
  return typeof token === "string" && TOKEN.test(token);
}

function json(origin: string | null, status: number, body: unknown, allowed: readonly string[]): Response {
  const headers = new Headers({
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-robots-tag": "noindex, nofollow",
    "referrer-policy": "no-referrer",
  });
  const cors = corsHeaders(origin, allowed);
  if (cors) for (const [key, value] of Object.entries(cors)) headers.set(key, value);
  return new Response(JSON.stringify(body), { status, headers });
}

const BAD = { ok: false, error: "bad_token" };

export async function handleMyPageRequest(
  req: Request,
  db: MyPageDb,
  pageEnv?: { origins?: string; supabaseUrl?: string },
): Promise<Response> {
  const allowed = pageOrigins(pageEnv?.origins, pageEnv?.supabaseUrl);
  const url = new URL(req.url);
  const origin = req.headers.get("origin");
  const route = myRoute(req.method, url.pathname);
  if (route === "my_options") {
    const cors = corsHeaders(origin, allowed);
    if (!cors) return new Response(null, { status: 403, headers: { vary: "origin" } });
    return new Response(null, { status: 204, headers: { ...cors, "cache-control": "no-store" } });
  }
  if (route === "my") {
    const token = url.searchParams.get("token");
    if (!validStaffToken(token)) return json(origin, 400, BAD, allowed);
    const { data, error } = await db.rpc("shift_staff_page", { p_token: token });
    if (error || !data || typeof data !== "object" || (data as { ok?: unknown }).ok !== true) return json(origin, 400, BAD, allowed);
    return json(origin, 200, data, allowed);
  }
  if (route === "my_respond") {
    const body = await req.json().catch(() => null);
    const rec = body && typeof body === "object" && !Array.isArray(body) ? body as Record<string, unknown> : {};
    if (!validStaffToken(rec.token)) return json(origin, 400, BAD, allowed);
    const offer = typeof rec.offer_id === "string" && UUID.test(rec.offer_id) ? rec.offer_id : null;
    const response = rec.response === "accept" || rec.response === "decline" ? rec.response : null;
    if (!offer || !response) return json(origin, 400, { ok: false, error: "bad_request" }, allowed);
    const { data, error } = await db.rpc("shift_staff_page_respond", { p_token: rec.token, p_offer_id: offer, p_response: response });
    if (error || !data || typeof data !== "object") return json(origin, 400, BAD, allowed);
    const row = data as Record<string, unknown>;
    return json(origin, row.result === "bad_token" ? 400 : 200, row, allowed);
  }
  return new Response("method not allowed", { status: 405 });
}
