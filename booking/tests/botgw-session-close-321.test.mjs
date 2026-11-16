// booking_321 + edge: session_close kulkee bot-gatewayn läpi (sessions_list/help: botgw-sessions-327.test.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../supabase/", import.meta.url);
const mig = readFileSync(new URL("migrations/20261115145705_booking_321_otto_bot_close_sessions.sql", root), "utf8");
const core = readFileSync(new URL("functions/bot-gateway/core.ts", root), "utf8");

test("tietokanta tuntee session_closen scopella sessions.close; edge myös, kirjoituksena", () => {
  assert.match(mig, /when 'session_close' then 'sessions\.close'/);
  assert.match(core, /^  session_close: \{\n    write: true,/m);
  for (const k of ["space_id", "space", "starts_at", "ends_at", "rule_id", "date", "reason"]) {
    assert.match(mig, new RegExp(`a->>'${k}'`), k);
  }
});

test("booking_321 ei vielä tuntenut sessions_listiä eikä helpiä (tulevat booking_327:ssä)", () => {
  for (const a of ["sessions_list", "help"]) assert.doesNotMatch(mig, new RegExp(`when '${a}'`), a);
});

test("ei poisto- eikä avaustoimintoa", () => {
  assert.doesNotMatch(core, /^  session_(open|delete|reopen|unblock): \{/m);
});
