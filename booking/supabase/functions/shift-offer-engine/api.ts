// Vastaussivun JSON-rajapinta ja WhatsApp-linkin ohjaus. Ei HTML:ää.
// GET /shift-offer-engine?token= → 302 staattiselle sivulle.
// GET /api/offers ja POST /api/respond ovat JSON. Henkilö tulee vain poletista.

import {
  corsHeaders,
  helsinkiMorning,
  offerJson,
  offerPageLocation,
  pageBase,
  pageOrigins,
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

// booking_274: linkin tarjouksen tila tälle henkilölle (shift_offer_open_for_token.focus).
// state: open | yours | filled_other | expired | withdrawn | cancelled | declined | not_recipient.
// title ja text ovat tietokannan valmiit tekstit; open-tilassa text on null.
export type OfferFocus = {
  state: string;
  title: string | null;
  text: string | null;
  offerId: string | null;
};

function focusFromRow(raw: unknown): OfferFocus | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.state !== "string" || !r.state) return null;
  const str = (v: unknown) => (typeof v === "string" && v.trim() ? v : null);
  return { state: r.state, title: str(r.title), text: str(r.text), offerId: str(r.offer_id) };
}

// Ei-avoin fokus, jolla on näytettävä teksti (muuten vanha käytös).
function closedFocus(focus: OfferFocus | null): OfferFocus | null {
  return focus && focus.state !== "open" && focus.text ? focus : null;
}

// error "bad_token" = oikeasti kelvoton / vanhentunut poletti; "server_error" = tietokanta- tai verkkovirhe.
type Loaded =
  | { ok: true; focusOfferId: string; focus: OfferFocus | null; offers: ShiftOfferCard[] }
  | { ok: false; error: "bad_token" | "server_error" };

async function loadOpenOffers(db: OfferDb, token: string): Promise<Loaded> {
  let res: { data: unknown; error: { message?: string } | null };
  try {
    res = await db.rpc("shift_offer_open_for_token", { p_token: token });
  } catch {
    return { ok: false, error: "server_error" };
  }
  const { data, error } = res;
  if (error || !data || typeof data !== "object") return { ok: false, error: "server_error" };
  const row = data as { ok?: boolean; focus_offer_id?: unknown; offers?: unknown; focus?: unknown };
  if (row.ok !== true || typeof row.focus_offer_id !== "string" || !row.focus_offer_id) return { ok: false, error: "bad_token" };
  const offers = Array.isArray(row.offers)
    ? row.offers.flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const card = cardFromRow(item as Record<string, unknown>);
      return card ? [card] : [];
    })
    : [];
  return { ok: true, focusOfferId: row.focus_offer_id, focus: focusFromRow(row.focus), offers };
}

export type OfferPayload = {
  ok: boolean;
  result: string | null;
  title: string;
  // booking_274: fokustarjouksen tila ja valmis teksti (null = ei erillistä tilatekstiä)
  focus_state: string | null;
  message: string | null;
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
  state: OfferFocus | null = null,
  shown: OfferFocus | null = null,
): OfferPayload {
  return {
    ok: result !== "bad_token" && result !== "server_error",
    result,
    title: shown?.title ?? resultTitle(result),
    focus_state: state?.state ?? null,
    message: shown?.text ?? null,
    focus_offer_id: focus,
    acted: acted ? offerJson(acted) : null,
    snooze_open_offer_id: snoozeOpen,
    offers: ordered(focus, offers).map(offerJson),
  };
}

function json(origin: string | null, status: number, body: OfferPayload, allowed: readonly string[]): Response {
  const headers = new Headers({
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  const cors = corsHeaders(origin, allowed);
  if (cors) for (const [key, value] of Object.entries(cors)) headers.set(key, value);
  return new Response(JSON.stringify(body), { status, headers });
}

export async function handleOfferRequest(
  req: Request,
  db: OfferDb,
  pageBaseEnv: string | undefined,
  pageEnv?: { origins?: string; supabaseUrl?: string },
): Promise<Response> {
  const allowed = pageOrigins(pageEnv?.origins, pageEnv?.supabaseUrl);
  const base = pageBase(pageBaseEnv, pageEnv?.supabaseUrl);
  const url = new URL(req.url);
  const origin = req.headers.get("origin");
  const queryToken = url.searchParams.get("token");
  const route = shiftRoute(req.method, url.pathname, queryToken);
  if (route === "options") {
    const cors = corsHeaders(origin, allowed);
    if (!cors) return new Response(null, { status: 403, headers: { vary: "origin" } });
    return new Response(null, { status: 204, headers: { ...cors, "cache-control": "no-store" } });
  }
  if (route === "redirect") {
    return new Response(null, {
      status: 302,
      headers: {
        location: offerPageLocation(base, queryToken ?? ""),
        "cache-control": "no-store",
        "referrer-policy": "no-referrer",
      },
    });
  }
  const failed = (error: "bad_token" | "server_error") =>
    json(origin, error === "server_error" ? 503 : 400, payload(error, null, [], null, null), allowed);
  if (route === "offers") {
    const token = queryToken ?? "";
    if (!token) return failed("bad_token");
    const open = await loadOpenOffers(db, token);
    if (!open.ok) return failed(open.error);
    // booking_274: linkin vuoro ei ole enää auki (esim. jo mennyt) → kerro se, älä näytä "Ei avoimia tarjouksia".
    // Muut avoimet tarjoukset säilyvät listassa.
    const closed = closedFocus(open.focus);
    if (closed && !open.offers.some((o) => o.offerId === open.focusOfferId)) {
      return json(origin, 200, payload(closed.state, open.focusOfferId, open.offers, null, null, open.focus, closed), allowed);
    }
    return json(origin, 200, payload(null, open.focusOfferId, open.offers, null, null, open.focus), allowed);
  }
  if (route !== "respond") return new Response("method not allowed", { status: 405 });

  const body = await req.json().catch(() => null);
  const record = body && typeof body === "object" && !Array.isArray(body) ? body as Record<string, unknown> : null;
  const token = typeof record?.token === "string" ? record.token : "";
  if (!token) return failed("bad_token");
  const open = await loadOpenOffers(db, token);
  if (!open.ok) return failed(open.error);
  const action = parseAction(typeof record?.response === "string" ? record.response : null);
  const show = (
    result: string | null,
    acted: ShiftOfferCard | null,
    offers: ShiftOfferCard[],
    snoozeOpen: string | null,
    status = 200,
    state: OfferFocus | null = open.focus,
    shown: OfferFocus | null = null,
  ) => json(origin, status, payload(result, open.focusOfferId, offers, acted, snoozeOpen, state, shown), allowed);
  if (!action) return show(null, null, open.offers, null);
  const posted = typeof record?.offer_id === "string" ? record.offer_id : "";
  const target = posted ? (UUID.test(posted) ? posted : "") : open.focusOfferId;
  if (!target) return show("not_owner", null, open.offers, null);
  const until = typeof record?.until === "string" ? record.until : "";
  const snooze = action === "snooze" ? helsinkiMorning(until) : null;
  if (action === "snooze" && !snooze) return show(null, null, open.offers, target);
  let res: { data: unknown; error: { message?: string } | null };
  try {
    res = await db.rpc("shift_offer_respond_as_staff", {
      p_token: token,
      p_offer_id: target,
      p_response: action,
      p_snooze_until: snooze,
    });
  } catch {
    return show("server_error", null, open.offers, null, 503);
  }
  const { data, error } = res;
  // Tietokantavirhe ei ole "Linkki ei kelpaa": poletti tarkistettiin juuri kelvolliseksi.
  if (error || !data || typeof data !== "object") return show("server_error", null, open.offers, null, 503);
  const row = data as Record<string, unknown>;
  const result = typeof row.result === "string" ? row.result : "bad_token";
  const again = await loadOpenOffers(db, token);
  const offers = again.ok ? again.offers : open.offers;
  const state = again.ok ? again.focus : open.focus;
  // booking_274: vuoro ei ole enää auki → tietokannan otsikko ja teksti (vain linkin omalle vuorolle).
  const closed = CLOSED_RESULTS.has(result) && target === open.focusOfferId ? closedFocus(state) : null;
  return show(result, cardFromRow(row), offers, null, result === "bad_token" ? 400 : 200, state, closed);
}

const CLOSED_RESULTS = new Set(["already_taken", "already_filled", "offer_closed", "not_recipient", "invalid_state"]);
