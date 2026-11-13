// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/booking274_test.ts
// booking_274: linkin vuoron tila (focus), varaotsikot, pelkkä "ei" WhatsAppissa ja palvelinvirhe ≠ "Linkki ei kelpaa".
// Ei verkkoa: tietokanta on testin oma.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handleOfferRequest, type OfferDb } from "./api.ts";
import { resultTitle } from "./core.ts";
import { isBareNo, parseIntent, processInboundMessage, type InboundDeps, type Intent } from "./inbound.ts";
import { handleMyPageRequest, type MyPageDb } from "./mypage.ts";

const FOCUS = "aaaaaaaa-0000-4000-8000-0000000000aa";
const OTHER = "bbbbbbbb-0000-4000-8000-0000000000bb";
const STAFF = "22222222-2222-4222-8222-222222222222";
const TEXT = "Lämmitysvuoro ke 18.11. klo 10–16 on jo täytetty. Kiitos!";

const OTHER_OFFER = {
  offer_id: OTHER, role_type: "heater", starts_at: "2026-11-20T08:00:00.000Z", ends_at: "2026-11-20T14:00:00.000Z",
  deadline_at: "2026-11-19T10:00:00.000Z", snooze_allowed: false,
};
const FOCUS_OFFER = { ...OTHER_OFFER, offer_id: FOCUS, starts_at: "2026-11-18T08:00:00.000Z", ends_at: "2026-11-18T14:00:00.000Z" };

function focus(state: string, title: string | null, text: string | null) {
  return { state, title, text, offer_id: FOCUS, role_type: "heater", starts_at: FOCUS_OFFER.starts_at, ends_at: FOCUS_OFFER.ends_at, deadline_at: null, when: "Lämmitysvuoro ke 18.11. klo 10–16" };
}

function openRow(f: unknown, offers: unknown[]) {
  return { ok: true, staff_id: STAFF, focus_offer_id: FOCUS, focus: f, offers };
}

type Rpc = { data: unknown; error: { message?: string } | null };

function dbSeq(opens: Array<Rpc | (() => never)>, respond?: Rpc | (() => never)): OfferDb & { names: string[] } {
  const names: string[] = [];
  let i = 0;
  return {
    names,
    async rpc(name) {
      names.push(name);
      if (name === "shift_offer_open_for_token") {
        const r = opens[Math.min(i++, opens.length - 1)];
        return typeof r === "function" ? r() : r;
      }
      if (name === "shift_offer_respond_as_staff" && respond) return typeof respond === "function" ? respond() : respond;
      throw new Error("unexpected rpc " + name);
    },
  };
}

const ok = (data: unknown): Rpc => ({ data, error: null });

async function get(db: OfferDb) {
  const res = await handleOfferRequest(new Request("https://x.supabase.co/functions/v1/shift-offer-engine/api/offers?token=tok"), db, undefined);
  return { status: res.status, body: await res.json() };
}

async function post(db: OfferDb, body: Record<string, unknown>) {
  const res = await handleOfferRequest(new Request("https://x.supabase.co/functions/v1/shift-offer-engine/api/respond", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token: "tok", ...body }),
  }), db, undefined);
  return { status: res.status, body: await res.json() };
}

Deno.test("GET: jo mennyt linkin vuoro → 200, result filled_other, tietokannan otsikko ja teksti, muut tarjoukset säilyvät", async () => {
  const { status, body } = await get(dbSeq([ok(openRow(focus("filled_other", "Tämä vuoro on jo mennyt", TEXT), [OTHER_OFFER]))]));
  assertEquals(status, 200);
  assertEquals([body.ok, body.result, body.title, body.message, body.focus_state], [true, "filled_other", "Tämä vuoro on jo mennyt", TEXT, "filled_other"]);
  assertEquals(body.offers.map((o: { offer_id: string }) => o.offer_id), [OTHER]);
});

Deno.test("GET: kaikki ei-avoimet tilat palautuvat; otsikko puuttuu → varaotsikko", async () => {
  for (const state of ["yours", "expired", "withdrawn", "cancelled", "declined", "not_recipient"]) {
    const { status, body } = await get(dbSeq([ok(openRow(focus(state, null, "Teksti."), []))]));
    assertEquals([status, body.result, body.message, body.title], [200, state, "Teksti.", resultTitle(state)], state);
  }
});

Deno.test("GET: avoin linkin vuoro tai vanha rajapinta (ei focusta) → vanha käytös", async () => {
  const a = await get(dbSeq([ok(openRow(focus("open", null, null), [FOCUS_OFFER, OTHER_OFFER]))]));
  assertEquals([a.body.result, a.body.title, a.body.message, a.body.focus_state, a.body.offers[0].offer_id], [null, "Vahvista vastauksesi", null, "open", FOCUS]);
  const b = await get(dbSeq([ok({ ok: true, staff_id: STAFF, focus_offer_id: FOCUS, offers: [OTHER_OFFER] })]));
  assertEquals([b.body.result, b.body.title, b.body.message, b.body.focus_state], [null, "Vahvista vastauksesi", null, null]);
});

Deno.test("POST: already_taken linkin vuoroon → ladataan uudelleen ja näytetään focus-otsikko ja -teksti", async () => {
  for (const result of ["already_taken", "already_filled", "offer_closed", "not_recipient", "invalid_state"]) {
    const db = dbSeq([
      ok(openRow(focus("open", null, null), [FOCUS_OFFER])),
      ok(openRow(focus("filled_other", "Tämä vuoro on jo mennyt", TEXT), [])),
    ], ok({ result, offer_id: FOCUS, role_type: "heater" }));
    const { status, body } = await post(db, { response: "accept" });
    assertEquals(status, 200);
    assertEquals([body.result, body.title, body.message, body.focus_state], [result, "Tämä vuoro on jo mennyt", TEXT, "filled_other"], result);
    assertEquals(db.names.filter((n) => n === "shift_offer_open_for_token").length, 2);
  }
});

Deno.test("POST: hyväksytty vastaus ei saa focus-tekstiä; toisen tarjouksen tulos ei käytä linkin vuoron tekstiä", async () => {
  const acc = await post(dbSeq([
    ok(openRow(focus("open", null, null), [FOCUS_OFFER])),
    ok(openRow(focus("yours", "Vuoro on sinun", "on sinun"), [])),
  ], ok({ result: "accepted", offer_id: FOCUS })), { response: "accept" });
  assertEquals([acc.body.result, acc.body.title, acc.body.message], ["accepted", "Vuoro on sinun", null]);
  const other = await post(dbSeq([
    ok(openRow(focus("filled_other", "Tämä vuoro on jo mennyt", TEXT), [OTHER_OFFER])),
  ], ok({ result: "already_taken", offer_id: OTHER })), { response: "accept", offer_id: OTHER });
  assertEquals([other.body.result, other.body.title, other.body.message], ["already_taken", "Vuoro on jo täytetty", null]);
});

Deno.test("resultTitle: booking_274-varaotsikot", () => {
  assertEquals(resultTitle("filled_other"), "Tämä vuoro on jo mennyt");
  assertEquals(resultTitle("expired"), "Vastausaika on päättynyt");
  assertEquals(resultTitle("withdrawn"), "Vuoroa ei enää tarjota sinulle");
  assertEquals(resultTitle("cancelled"), "Vuoro on peruttu");
  assertEquals(resultTitle("yours"), "Vuoro on sinun");
  assertEquals(resultTitle("bad_token"), "Linkki ei kelpaa");
  assertEquals(resultTitle(null), "Vahvista vastauksesi");
});

Deno.test("virheerottelu: kelvoton poletti = Linkki ei kelpaa (400), tietokantavirhe = palvelinvirhe (503)", async () => {
  const bad = await get(dbSeq([ok({ ok: false, error: "bad_token" })]));
  assertEquals([bad.status, bad.body.result, bad.body.title], [400, "bad_token", "Linkki ei kelpaa"]);
  const SERVER = "Jokin meni vikaan, yritä hetken päästä uudelleen.";
  const dbErr = await get(dbSeq([{ data: null, error: { message: "boom" } }]));
  assertEquals([dbErr.status, dbErr.body.ok, dbErr.body.result, dbErr.body.title], [503, false, "server_error", SERVER]);
  const thrown = await get(dbSeq([() => { throw new Error("network"); }]));
  assertEquals([thrown.status, thrown.body.result], [503, "server_error"]);
  const respondErr = await post(dbSeq([ok(openRow(focus("open", null, null), [FOCUS_OFFER]))], { data: null, error: { message: "x" } }), { response: "accept" });
  assertEquals([respondErr.status, respondErr.body.result, respondErr.body.title], [503, "server_error", SERVER]);
  assertEquals(respondErr.body.offers.length, 1);
  const respondBad = await post(dbSeq([ok({ ok: false })]), { response: "accept" });
  assertEquals([respondBad.status, respondBad.body.result], [400, "bad_token"]);
});

Deno.test("oma sivu: tietokantavirhe 503 server_error, kelvoton poletti 400 bad_token", async () => {
  const TOKEN = "eyJwIjoiYWFhYWFhYWEtMDAwMC00MDAwIiwibiI6IngifQ.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";
  const mk = (r: Rpc | (() => never)): MyPageDb => ({ async rpc() { return typeof r === "function" ? r() : r; } });
  const url = "https://x.supabase.co/functions/v1/shift-offer-engine/api/my?token=" + TOKEN;
  const a = await handleMyPageRequest(new Request(url), mk({ data: null, error: { message: "x" } }));
  assertEquals([a.status, (await a.json()).error], [503, "server_error"]);
  const b = await handleMyPageRequest(new Request(url), mk(ok({ ok: false, error: "bad_token" })));
  assertEquals([b.status, (await b.json()).error], [400, "bad_token"]);
  const c = await handleMyPageRequest(new Request(url), mk(() => { throw new Error("net"); }));
  assertEquals(c.status, 503);
});

Deno.test("parseIntent: pelkkä 'ei' → unknown ilman odottavaa muutosta, abort kun muutos odottaa tai tieto puuttuu", () => {
  assertEquals(parseIntent("ei", null, { pendingAction: false }), { op: "unknown" });
  assertEquals(parseIntent("Ei.", null, { pendingAction: false }), { op: "unknown" });
  assertEquals(parseIntent("ei", null, { pendingAction: true }), { op: "abort" });
  assertEquals(parseIntent("ei", null), { op: "abort" });
  assertEquals(parseIntent("peruuta", null, { pendingAction: false }), { op: "abort" });
  assertEquals(parseIntent("en pääse", null, { pendingAction: false }), { op: "unknown" });
  assert(isBareNo(" EI! ", null) && !isBareNo("ei", "n:x") && !isBareNo("ei käy", null));
});

function inboundDeps(text: string, pending: boolean | "throw" | "absent") {
  const acts: Intent[] = [];
  const lookups: string[] = [];
  const deps: InboundDeps = {
    store: () => Promise.resolve({ id: "m1", duplicate: false, handled: false, inboundEnabled: true, staffId: STAFF, replyTo: "+358401110001" }),
    act: (_id, intent) => { acts.push(intent); return Promise.resolve({ replyBody: null, buttons: [], shiftId: null, suppressed: false }); },
    send: () => Promise.resolve({ ok: true, wamid: "w" }),
    markHandled: () => Promise.resolve(),
    storeOutbound: () => Promise.resolve(),
    log: () => {},
  };
  if (pending !== "absent") {
    deps.hasPendingAction = (staff) => {
      lookups.push(staff);
      if (pending === "throw") return Promise.reject(new Error("db"));
      return Promise.resolve(pending);
    };
  }
  const message = { wamid: "w1", from: "358401110001", type: "text", text, buttonId: null, at: null };
  return { deps, message, acts, lookups };
}

Deno.test("processInboundMessage: 'ei' kysyy odottavan muutoksen; muu teksti ei kysy", async () => {
  const cases: Array<[string, boolean | "throw" | "absent", string, number]> = [
    ["ei", false, "unknown", 1],
    ["ei", true, "abort", 1],
    ["ei", "throw", "abort", 1],
    ["ei", "absent", "abort", 0],
    ["en pääse", false, "unknown", 0],
    ["peruuta", false, "abort", 0],
  ];
  for (const [text, pending, op, lookups] of cases) {
    const t = inboundDeps(text, pending);
    await processInboundMessage(t.message, t.deps);
    assertEquals([t.acts[0]?.op, t.lookups.length], [op, lookups], `${text} ${pending}`);
    if (lookups) assertEquals(t.lookups[0], STAFF);
  }
});
