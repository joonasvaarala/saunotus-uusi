// booking_321 + edge: session_close kulkee bot-gatewayn läpi; sessions_list/help eivät ole toimintoja (eivät tietokannassa).
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

test("sessions_list ja help puuttuvat sekä tietokannasta että edgestä", () => {
  for (const a of ["sessions_list", "help"]) {
    assert.doesNotMatch(mig, new RegExp(`when '${a}'`), a);
    assert.doesNotMatch(core, new RegExp(`^  ${a}: \\{`, "m"), a);
  }
});

test("ei poisto- eikä avaustoimintoa", () => {
  assert.doesNotMatch(core, /^  session_(open|delete|reopen|unblock): \{/m);
});
