// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/core_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  canonicalToken,
  dryRunRequested,
  helsinkiMorning,
  escapeHtml,
  formatDeadline,
  formatShiftWhen,
  parseAction,
  requestIntent,
  respondPage,
  roleTitle,
  senderDecision,
  signToken,
  verifyToken,
  type ShiftOfferCard,
} from "./core.ts";

const OFFER = "11111111-1111-4111-8111-111111111111";
const STAFF = "22222222-2222-4222-8222-222222222222";
const TOKEN = "eyJvIjoiMTExMTExMTEtMTExMS00MTExLTgxMTEtMTExMTExMTExMTExIiwicyI6IjIyMjIyMjIyLTIyMjItNDIyMi04MjIyLTIyMjIyMjIyMjIyMiIsImUiOjIwMDAwMDAwMDB9.pVV62_nGcsqs9VobW5n0oSq2sY92eZqw2BHCrPGbg48";

Deno.test("token matches the SQL canonical HMAC vector", async () => {
  assertEquals(canonicalToken(OFFER, STAFF, 2000000000), `{"o":"${OFFER}","s":"${STAFF}","e":2000000000}`);
  assertEquals(await signToken("test-key", OFFER, STAFF, 2000000000), TOKEN);
  const ok = await verifyToken("test-key", TOKEN, 1_700_000_000);
  assert(ok.ok);
  if (ok.ok) {
    assertEquals(ok.offerId, OFFER);
    assertEquals(ok.staffId, STAFF);
  }
  assertEquals((await verifyToken("test-key", TOKEN, 2_000_000_000)).ok, false);
  assertEquals((await verifyToken("other", TOKEN, 1)).ok, false);
});

Deno.test("dry_run comes from the query, the body, or the setting", () => {
  const url = new URL("https://example.test/functions/v1/shift-offer-engine?dry_run=1");
  assertEquals(dryRunRequested(url, {}, false), true);
  assertEquals(dryRunRequested(new URL("https://example.test/"), { dryRun: true }, false), true);
  assertEquals(dryRunRequested(new URL("https://example.test/"), { dry_run: true }, false), true);
  assertEquals(dryRunRequested(new URL("https://example.test/"), {}, true), true);
  assertEquals(dryRunRequested(new URL("https://example.test/"), { dryRun: false }, false), false);
});

Deno.test("GET with a token does not mutate; POST without a token is a tick", () => {
  assertEquals(requestIntent("GET", "abc.def"), "respond");
  assertEquals(requestIntent("POST", null), "tick");
  assertEquals(requestIntent("POST", "abc.def"), "respond");
  assertEquals(requestIntent("GET", null), "invalid");
  assertEquals(parseAction("accept"), "accept");
  assertEquals(parseAction("nope"), null);
});

const SHIFT: ShiftOfferCard = {
  offerId: "aaaaaaaa-0000-4000-8000-0000000000aa",
  role: "therapist",
  startsAt: "2026-10-24T13:00:00.000Z",
  endsAt: "2026-10-24T17:00:00.000Z",
  deadlineAt: "2026-10-24T09:00:00.000Z",
  snoozeAllowed: true,
};

const OTHER: ShiftOfferCard = {
  offerId: "bbbbbbbb-0000-4000-8000-0000000000bb",
  role: "heater",
  startsAt: "2026-11-02T14:00:00.000Z",
  endsAt: "2026-11-02T18:00:00.000Z",
  deadlineAt: "2026-10-28T10:00:00.000Z",
  snoozeAllowed: false,
};

Deno.test("confirmation page does not accept on its own", () => {
  const html = respondPage({
    result: null,
    acted: null,
    offers: [OTHER, SHIFT],
    focusOfferId: SHIFT.offerId,
    snoozeOpenOfferId: null,
  });
  assert(html.includes("Hyväksy"));
  assert(html.includes("method=\"POST\""));
  assert(html.includes("–Tapio"));
  assert(html.includes("Vahvista vastauksesi"));
  assert(!html.includes("Vuoro on sinun"));
  assert(html.indexOf(SHIFT.offerId) < html.indexOf(OTHER.offerId));
  assert(html.includes("Hoitajavuoro"));
  assert(html.includes("Lauantai 24.10.2026 klo 16:00–20:00"));
  assert(html.includes("Vastaa viimeistään 24.10.2026 klo 12:00"));
  assert(html.includes("<details"));
  assert(html.includes(".snooze[open]{display:grid"));
  assert(!html.includes(".snooze{display:grid"));
  assert(html.includes("Tämä tarjous"));
  assert(html.split("method=\"POST\"").length - 1 === 2);
  assert(!html.includes("kierros"));
  const heater = html.slice(html.indexOf(OTHER.offerId));
  assert(!heater.includes("<details"));
  assert(respondPage({
    result: "already_taken",
    acted: SHIFT,
    offers: [],
    focusOfferId: SHIFT.offerId,
    snoozeOpenOfferId: null,
  }).includes("Vuoro on jo täytetty"));
});

Deno.test("response page escapes dynamic values", () => {
  assertEquals(escapeHtml(`<img src=x onerror="alert(1)">`), "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;");
  const nasty: ShiftOfferCard = {
    ...SHIFT,
    offerId: `"><script>alert(1)</script>`,
    role: "therapist",
  };
  const html = respondPage({
    result: null,
    acted: null,
    offers: [nasty],
    focusOfferId: nasty.offerId,
    snoozeOpenOfferId: null,
  });
  assert(!html.includes("<script>"));
  assert(html.includes("&lt;script&gt;"));
  assert(html.includes("&quot;&gt;&lt;script&gt;"));
  assert(html.includes("Hoitajavuoro"));
  assertEquals(roleTitle("therapist"), "Hoitajavuoro");
  assertEquals(formatShiftWhen(SHIFT.startsAt, SHIFT.endsAt), "Lauantai 24.10.2026 klo 16:00–20:00");
  assertEquals(formatDeadline(SHIFT.deadlineAt), "24.10.2026 klo 12:00");
});

Deno.test("accepted page keeps the shift and the other open offers", () => {
  const html = respondPage({
    result: "accepted",
    acted: SHIFT,
    offers: [SHIFT, OTHER],
    focusOfferId: SHIFT.offerId,
    snoozeOpenOfferId: null,
  });
  assert(html.includes("Vuoro on sinun"));
  assert(html.includes("Hoitajavuoro"));
  assert(html.includes("Lämmitysvuoro"));
  assert(html.includes("https://joonasvaarala.github.io/saunotus-uusi/img/ovi-kaiverrus-1024.webp"));
  assert(html.includes(".arch{position:relative"));
  assert(html.includes("height:252px"));
  assert(html.includes("overflow:hidden"));
  assert(html.includes("button.btn,summary.btn{font-family:system-ui"));
  assert(html.includes("font-size:16px;font-weight:600"));
  assert(html.includes("--green:#2B3A30"));
  assert(html.includes("--bg:#F4EFE7"));
  assert(html.includes("btn primary"));
  const after = html.slice(html.indexOf("Lämmitysvuoro"));
  assert(after.includes("Hyväksy"));
  assert(!html.slice(html.indexOf("Vuoro on sinun"), html.indexOf("Lämmitysvuoro")).includes("name=\"r\""));
});

Deno.test("not_owner keeps the person's own offer buttons", () => {
  const html = respondPage({
    result: "not_owner",
    acted: null,
    offers: [OTHER, SHIFT],
    focusOfferId: SHIFT.offerId,
    snoozeOpenOfferId: null,
  });
  assert(html.includes("Tähän vuoroon ei voi vastata"));
  assert(html.includes("Hyväksy"));
  assert(html.includes("Kieltäydy"));
  assert(html.split("method=\"POST\"").length - 1 === 2);
  assert(html.indexOf(SHIFT.offerId) < html.indexOf(OTHER.offerId));
});

Deno.test("response page ownership sql refuses another staff id", async () => {
  const sql = await Deno.readTextFile(
    new URL("../../migrations/20261022022221_shift_offer_response_page.sql", import.meta.url),
  );
  const fn = sql.slice(
    sql.indexOf("function public.shift_offer_respond_as_staff"),
    sql.indexOf("revoke all on function"),
  );
  assert(fn.includes("p_token text, p_offer_id uuid"));
  assert(!fn.includes("p_staff_id"));
  assert(fn.includes("v_tok->>'staff_id'"));
  assert(fn.includes("rec.staff_id = v_staff"));
  assert(fn.includes("'not_owner'"));
  const list = sql.slice(0, sql.indexOf("function public.shift_offer_respond_as_staff"));
  assert(list.includes("rec.status = 'pending'"));
  assert(list.includes("o.status in ('active', 'paused', 'escalated')"));
  assert(list.includes("rec.deadline_at > now()"));
});

Deno.test("sender switch defaults to leaving the outbox alone", () => {
  assertEquals(senderDecision(false), "leave_queued");
  assertEquals(senderDecision(true), "deliver");
});

Deno.test("snooze morning is 08:00 Europe/Helsinki in winter and summer", () => {
  assertEquals(helsinkiMorning("2027-01-15"), "2027-01-15T06:00:00.000Z");
  assertEquals(helsinkiMorning("2027-07-15"), "2027-07-15T05:00:00.000Z");
  assertEquals(helsinkiMorning("15.1.2027"), null);
  assertEquals(helsinkiMorning("2027-02-31"), null);
});
