// booking_315: Oton botin uutiskirjeluonnokset. Migraation, rollbackin ja bot-gatewayn toimintolistan yhtenäisyys + "vain luonnokset" -rajaus.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../supabase/", import.meta.url);
const mig = readFileSync(new URL("migrations/20261114214038_booking_315_botgw_newsletter_draft.sql", root), "utf8");
const rb = readFileSync(new URL("rollbacks/20261114214038_booking_315_ROLLBACK.sql", root), "utf8");
const core = readFileSync(new URL("functions/bot-gateway/core.ts", root), "utf8");
const OLD = "76ffcbde693f2adb88fa217dd78d20df";
const NEW = "844fa36b3dbeaff91fca60d3ea3291d3";
const NL = ["newsletter_list", "newsletter_get", "newsletter_save"];

test("migraatio: md5-ennakkoehto ja -jälkiehto, scope otto-grok-botille", () => {
  assert.match(mig, new RegExp(`<> '${OLD}'`));
  assert.match(mig, new RegExp(`<> '${NEW}'`));
  assert.match(mig, /array_append\(scopes, 'newsletter\.draft'\)\s+where name = 'otto-grok-bot'/);
  assert.match(mig, /'proposals\.write', 'newsletter\.draft'\]/);
  for (const a of NL) assert.match(mig, new RegExp(`when '${a}' then 'newsletter\\.draft'`));
});

test("rollback: palauttaa vanhan md5:n ja poistaa scopen", () => {
  assert.match(rb, new RegExp(`<> '${NEW}'`));
  assert.match(rb, new RegExp(`<> '${OLD}'`));
  assert.match(rb, /array_remove\(scopes, 'newsletter\.draft'\)/);
  assert.doesNotMatch(rb, /newsletter_save|newsletter_list/);
});

test("vain luonnokset: ei lähetystä, ajastusta, esikatselua eikä lippuja", () => {
  const branch = mig.slice(mig.indexOf("elsif p_action = 'newsletter_list'"), mig.indexOf("insert into botgw.call_log"));
  assert.ok(branch.length > 1000);
  assert.doesNotMatch(branch, /dispatch|_newsletter_flag|newsletter_enabled|newsletter_deliveries|email_outbox|booking\.settings|preview_token\s*:=/i);
  assert.match(branch, /v_nl\.state <> 'draft'/);
  assert.match(branch, /booking\._newsletter_save\(/);
  // suggested_send_at ei ole botin muokattavien avainten listalla
  const keys = branch.match(/if v_txt not in \(([^)]*)\)/)[1];
  assert.doesNotMatch(keys, /suggested_send_at|state/);
});

test("newsletter_save on kirjoitus kaikissa rajoissa; edge ja tietokanta samat toiminnot", () => {
  const writeLists = mig.match(/'own_shift_release',[^)]*\)/g).filter((s) => s.includes("newsletter_save"));
  assert.equal(writeLists.length, 3);
  const edge = [...core.matchAll(/^  (newsletter_\w+): \{/gm)].map((m) => m[1]).sort();
  assert.deepEqual(edge, [...NL].sort());
  assert.match(core, /newsletter_save: \{\n    write: true,/);
});
