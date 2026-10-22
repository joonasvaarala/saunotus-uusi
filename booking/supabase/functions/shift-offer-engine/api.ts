// Vastaussivun JSON-rajapinta ja WhatsApp-linkin ohjaus. Ei HTML:ää.
// GET /shift-offer-engine?token= → 302 staattiselle sivulle.
// GET /api/offers ja POST /api/respond ovat JSON. Henkilö tulee vain poletista.

import {
  corsHeaders,
  helsinkiMorning,
  offerJson,
  offerPageLocation,
  pageBase,
  parseAction,
  resultTitle,
  shiftRoute,
  type OfferJson,
  type ShiftOfferCard,
} from "./core.ts";

export type OfferDb = {
  rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: { message?: string } | null }>;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function cardFromRow(raw: Record<string, unknown>): ShiftOfferCard | null {
  const id = raw.offer_id ? String(raw.offer_id) : "";
  if (!id) return null;
  return {
    offerId: id,
    role: raw.role_type == null ? "" : String(raw.role_type),
    startsAt: raw.starts_at == null ? null : String(raw.starts_at),
    endsAt: raw.ends_at == null ? null : String(raw.ends_at),
    deadlineAt: raw.deadline_at == null ? null : String(raw.deadline_at),
    snoozeAllowed: raw.snooze_allowed === true,
  };
}

async function loadOpenOffers(db: OfferDb, token: string): Promise<
  { ok: true; focusOfferId: string; offers: ShiftOfferCard[] } | { ok: false }
> {
  const { data, error } = await db.rpc("shift_offer_open_for_token", { p_token: token });
  if (error || !data || typeof data !== "object") return { ok: false };
  const row = data as { ok?: boolean; focus_offer_id?: unknown; offers?: unknown };
  if (row.ok !== true || typeof row.focus_offer_id !== "string" || !row.focus_offer_id) return { ok: false };
  const offers = Array.isArray(row.offers)
    ? row.offers.flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const card = cardFromRow(item as Record<string, unknown>);
      return card ? [card] : [];
    })
    : [];
  return { ok: true, focusOfferId: row.focus_offer_id, offers };
}

export type OfferPayload = {
  ok: boolean;
  result: string | null;
  title: string;
  focus_offer_id: string | null;
  acted: OfferJson | null;
  snooze_open_offer_id: string | null;
  offers: OfferJson[];
};

function ordered(focus: string | null, offers: ShiftOfferCard[]): ShiftOfferCard[] {
  return [...offers].sort((a, b) => {
    const af = a.offerId === focus ? 0 : 1;
    const bf = b.offerId === focus ? 0 : 1;
    if (af !== bf) return af - bf;
    return String(a.startsAt ?? "").localeCompare(String(b.startsAt ?? ""));
  });
}

function payload(
  result: string | null,
  focus: string | null,
  offers: ShiftOfferCard[],
  acted: ShiftOfferCard | null,
  snoozeOpen: string | null,
): OfferPayload {
  return {
    ok: result !== "bad_token",
    result,
    title: resultTitle(result),
    focus_offer_id: focus,
    acted: acted ? offerJson(acted) : null,
    snooze_open_offer_id: snoozeOpen,
    offers: ordered(focus, offers).map(offerJson),
  };
}

function json(origin: string | null, status: number, body: OfferPayload): Response {
  const headers = new Headers({
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  const cors = corsHeaders(origin);
  if (cors) for (const [key, value] of Object.entries(cors)) headers.set(key, value);
  return new Response(JSON.stringify(body), { status, headers });
}

export async function handleOfferRequest(req: Request, db: OfferDb, pageBaseEnv: string | undefined): Promise<Response> {
  const url = new URL(req.url);
  const origin = req.headers.get("origin");
  const queryToken = url.searchParams.get("token");
  const route = shiftRoute(req.method, url.pathname, queryToken);
  if (route === "options") {
    const cors = corsHeaders(origin);
    if (!cors) return new Response(null, { status: 403, headers: { vary: "origin" } });
    return new Response(null, { status: 204, headers: { ...cors, "cache-control": "no-store" } });
  }
  if (route === "redirect") {
    return new Response(null, {
      status: 302,
      headers: {
        location: offerPageLocation(pageBase(pageBaseEnv), queryToken ?? ""),
        "cache-control": "no-store",
        "referrer-policy": "no-referrer",
      },
    });
  }
  if (route === "offers") {
    const token = queryToken ?? "";
    if (!token) return json(origin, 400, payload("bad_token", null, [], null, null));
    const open = await loadOpenOffers(db, token);
    if (!open.ok) return json(origin, 400, payload("bad_token", null, [], null, null));
    return json(origin, 200, payload(null, open.focusOfferId, open.offers, null, null));
  }
  if (route !== "respond") return new Response("method not allowed", { status: 405 });

  const body = await req.json().catch(() => null);
  const record = body && typeof body === "object" && !Array.isArray(body) ? body as Record<string, unknown> : null;
  const token = typeof record?.token === "string" ? record.token : "";
  if (!token) return json(origin, 400, payload("bad_token", null, [], null, null));
  const open = await loadOpenOffers(db, token);
  if (!open.ok) return json(origin, 400, payload("bad_token", null, [], null, null));
  const action = parseAction(typeof record?.response === "string" ? record.response : null);
  const show = (result: string | null, acted: ShiftOfferCard | null, offers: ShiftOfferCard[], snoozeOpen: string | null, status = 200) =>
    json(origin, status, payload(result, open.focusOfferId, offers, acted, snoozeOpen));
  if (!action) return show(null, null, open.offers, null);
  const posted = typeof record?.offer_id === "string" ? record.offer_id : "";
  const target = posted ? (UUID.test(posted) ? posted : "") : open.focusOfferId;
  if (!target) return show("not_owner", null, open.offers, null);
  const until = typeof record?.until === "string" ? record.until : "";
  const snooze = action === "snooze" ? helsinkiMorning(until) : null;
  if (action === "snooze" && !snooze) return show(null, null, open.offers, target);
  const { data, error } = await db.rpc("shift_offer_respond_as_staff", {
    p_token: token,
    p_offer_id: target,
    p_response: action,
    p_snooze_until: snooze,
  });
  if (error || !data || typeof data !== "object") return show("bad_token", null, open.offers, null, 400);
  const row = data as Record<string, unknown>;
  const result = typeof row.result === "string" ? row.result : "bad_token";
  const again = await loadOpenOffers(db, token);
  return show(result, cardFromRow(row), again.ok ? again.offers : open.offers, null, result === "bad_token" ? 400 : 200);
}
