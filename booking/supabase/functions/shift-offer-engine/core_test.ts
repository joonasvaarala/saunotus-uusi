// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/core_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  canonicalToken,
  dryRunRequested,
  helsinkiMorning,
  escapeHtml,
  formatDeadline,
  formatShiftWhen,
  offerPageLocation,
  pageBase,
  pageOrigins,
  parseAction,
  roleTitle,
  shiftRoute,
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

Deno.test("WhatsApp GET redirects and only the JSON routes answer", () => {
  assertEquals(shiftRoute("GET", "/functions/v1/shift-offer-engine", "abc.def"), "redirect");
  assertEquals(shiftRoute("POST", "/functions/v1/shift-offer-engine", null), "tick");
  assertEquals(shiftRoute("POST", "/functions/v1/shift-offer-engine", "abc.def"), "invalid");
  assertEquals(shiftRoute("GET", "/functions/v1/shift-offer-engine", null), "invalid");
  assertEquals(shiftRoute("GET", "/functions/v1/shift-offer-engine/api/offers", "abc.def"), "offers");
  assertEquals(shiftRoute("POST", "/functions/v1/shift-offer-engine/api/respond", null), "respond");
  assertEquals(shiftRoute("OPTIONS", "/functions/v1/shift-offer-engine/api/offers", null), "options");
  assertEquals(parseAction("accept"), "accept");
  assertEquals(parseAction("nope"), null);
  assertEquals(pageBase(undefined), "https://saunotus.fi");
  assertEquals(pageBase("https://saunotus.fi/"), "https://saunotus.fi");
  assertEquals(pageBase("https://joonasvaarala.github.io/saunotus-uusi"), "https://joonasvaarala.github.io/saunotus-uusi");
  const prod = "https://sxbofnuisemspgquoxyv.supabase.co";
  const dev = "https://aoejjmfzulhkhxbehphs.supabase.co";
  assertEquals(pageBase("https://joonasvaarala.github.io/saunotus-uusi", prod), "https://saunotus.fi");
  assertEquals(pageBase("https://joonasvaarala.github.io/saunotus-uusi/", dev), "https://joonasvaarala.github.io/saunotus-uusi");
  assertEquals(pageOrigins(undefined), ["https://saunotus.fi", "https://www.saunotus.fi"]);
  assertEquals(pageOrigins("https://joonasvaarala.github.io", prod).includes("https://joonasvaarala.github.io"), false);
  assertEquals(pageOrigins("https://joonasvaarala.github.io", dev).includes("https://joonasvaarala.github.io"), true);
  assertEquals(pageOrigins("https://evil.example/vuoro", dev).includes("https://evil.example"), false);
  assertEquals(
    offerPageLocation("https://saunotus.fi/", "a+b/c=d"),
    "https://saunotus.fi/vuoro/?token=a%2Bb%2Fc%3Dd",
  );
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

Deno.test("shift text stays in Finnish Helsinki time", () => {
  assertEquals(escapeHtml(`<img src=x onerror="alert(1)">`), "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;");
  assertEquals(roleTitle("therapist"), "Hoitajavuoro");
  assertEquals(formatShiftWhen(SHIFT.startsAt, SHIFT.endsAt), "Lauantai 24.10.2026 klo 16:00–20:00");
  assertEquals(formatDeadline(SHIFT.deadlineAt), "24.10.2026 klo 12:00");
  assertEquals(roleTitle(OTHER.role), "Lämmitysvuoro");
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
