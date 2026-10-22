// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/core_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  canonicalToken,
  dryRunRequested,
  helsinkiMorning,
  parseAction,
  requestIntent,
  respondPage,
  senderDecision,
  signToken,
  verifyToken,
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

Deno.test("confirmation page does not accept on its own", () => {
  const html = respondPage(null, null);
  assert(html.includes("Hyväksy"));
  assert(html.includes("method=\"POST\""));
  assert(html.includes("–Tapio"));
  assert(!html.includes("result"));
  assert(respondPage("accept", "already_taken").includes("Vuoro on jo täytetty."));
});

Deno.test("sender switch defaults to leaving the outbox alone", () => {
  assertEquals(senderDecision(false), "leave_queued");
  assertEquals(senderDecision(true), "mark_stub");
});

Deno.test("snooze morning is 08:00 Europe/Helsinki in winter and summer", () => {
  assertEquals(helsinkiMorning("2027-01-15"), "2027-01-15T06:00:00.000Z");
  assertEquals(helsinkiMorning("2027-07-15"), "2027-07-15T05:00:00.000Z");
  assertEquals(helsinkiMorning("15.1.2027"), null);
  assertEquals(helsinkiMorning("2027-02-31"), null);
});
