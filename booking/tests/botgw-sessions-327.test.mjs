// booking_327: sessions_list (vain luku) ja help. Migraation, rollbackin ja bot-gatewayn toimintolistan yhtenäisyys.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

const root = new URL("../supabase/", import.meta.url);
const V = "20261116065919";
const migRaw = readFileSync(new URL(`migrations/${V}_booking_327_botgw_sessions_list_help.sql`, root));
const mig = migRaw.toString("utf8");
const rb = readFileSync(new URL(`rollbacks/${V}_booking_327_ROLLBACK.sql`, root), "utf8");
const core = readFileSync(new URL("functions/bot-gateway/core.ts", root), "utf8");
const PRE = "59cbd540a8775b841c566b4f73b507e9"; // booking_321

test("migraatio on sama kuin PRODin schema_migrations (md5)", () => {
  assert.equal(createHash("md5").update(migRaw).digest("hex"), "5ca60df90785e458e117fe8e9ec44d10");
});

test("migraatio: ennakkoehto booking_321, scope-kartta ja sessions.read", () => {
  assert.match(mig, new RegExp(`<> '${PRE}'`));
  assert.match(mig, /when 'sessions_list' then 'sessions\.read'/);
  assert.match(mig, /when 'help' then 'me'/);
  assert.match(mig, /'sessions\.close', 'sessions\.read'\]/);
  assert.match(mig, /c := botgw\._client\(p_key_hash, 'sessions\.close'\)/); // sessions.close riittää luvulle
});

test("sessions_list ei ole kirjoitus eikä palauta henkilö- tai maksutietoja", () => {
  for (const l of mig.match(/'own_shift_release',[^)]*\)/g)) assert.doesNotMatch(l, /sessions_list|'help'/);
  const fn = mig.slice(mig.indexOf("botgw._sessions_list(p_args"), mig.indexOf("$function$;", mig.indexOf("botgw._sessions_list(p_args")));
  assert.ok(fn.length > 1000);
  assert.doesNotMatch(fn, /email|phone|order_id|payment|unit_price|customer/i);
});

test("rollback palauttaa booking_321-version", () => {
  assert.match(rb, new RegExp(`<> '${PRE}'`));
  assert.doesNotMatch(rb, /when 'sessions_list'/);
});

test("edge: sessions_list ja help lukutoimintoina", () => {
  assert.match(core, /^  sessions_list: \{\n    write: false,/m);
  assert.match(core, /^  help: \{ write: false, fields: \{\} \},/m);
  for (const k of ["date", "from", "to", "space_id", "space", "product_id"]) assert.match(mig, new RegExp(`a->>'${k}'`), k);
});
