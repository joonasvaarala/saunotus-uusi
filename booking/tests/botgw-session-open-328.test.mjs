// booking_328: Oton botti avaa vain omia sulkujaan (session_open, scope sessions.close). Migraatio, rollback ja edge yhtenäiset.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

const root = new URL("../supabase/", import.meta.url);
const V = "20261116081050";
const md5 = (b) => createHash("md5").update(b).digest("hex");
const migRaw = readFileSync(new URL(`migrations/${V}_booking_328_botgw_session_open.sql`, root));
const rbRaw = readFileSync(new URL(`rollbacks/${V}_booking_328_ROLLBACK.sql`, root));
const chkRaw = readFileSync(new URL("tests/t328_botgw_session_open_TARKISTUKSET.sql", root));
const mig = migRaw.toString("utf8");
const rb = rbRaw.toString("utf8");
const core = readFileSync(new URL("functions/bot-gateway/core.ts", root), "utf8");
const PRE = "9341497d6dbe4848fdc747cf7d4a5622"; // booking_327
const POST = "9a35dfd1d1aa4443df11ede51d49e5fc";

// Edgen ACTIONS-spec ja validateArgs ilman Denoa: poimitaan session_open-rivi ja tarkistetaan muoto.
const specLine = core.match(/^  session_open: (\{.*\}),$/m)?.[1];

test("tiedostot = PRODin migraatio (md5)", () => {
  assert.equal(md5(migRaw), "82a3fddfc943522c3931518a9ac37326");
  assert.equal(md5(rbRaw), "4215cf02885543b1d3ceded2d7bad95f");
  assert.equal(md5(chkRaw), "79dc2b67c0e8d3552dda407b71d2fe39");
});

test("migraatio: md5-vahdit, scope sessions.close, ei poistoa", () => {
  assert.match(mig, new RegExp(`<> '${PRE}'`));
  assert.ok(mig.includes(POST));
  assert.match(mig, /when 'session_open' then 'sessions\.close'/);
  assert.match(mig, /booking\.svc_open_space_block\(v_id, v_actor, c\.staff_id\)/);
  const fn = mig.slice(mig.indexOf("FUNCTION booking.svc_open_space_block"), mig.indexOf("$function$;", mig.indexOf("FUNCTION booking.svc_open_space_block")));
  assert.ok(fn.length > 500);
  assert.doesNotMatch(fn, /delete\s+from/i);
  for (const e of ["not_own_closure", "closure_managed", "event_managed", "already"]) assert.ok(fn.includes(`'${e}'`), e);
  assert.match(fn, /not_found: block/);
});

test("rollback palauttaa booking_327-version", () => {
  assert.ok(rb.includes(PRE));
  assert.doesNotMatch(rb, /when 'session_open'/);
});

test("edge: session_open kirjoituksena, block_id pakollinen int, ei muita kenttiä", () => {
  assert.equal(specLine, "{ write: true, fields: { block_id: f(int, REQ), request_id } }");
  // session_open tulee session_closen jälkeen
  assert.ok(core.indexOf("\n  session_open:") > core.indexOf("\n  session_close:"));
  assert.match(core, /case "int":\n\s+return Number\.isSafeInteger\(v\) && \(v as number\) > 0 \? null : `bad_arg:\$\{name\}`;/);
});

test("edge: 409-koodit ja virhemappaus", () => {
  const list = JSON.parse(core.match(/export const BUSINESS_409 = (\[[^\]]*\]);/)[1]);
  assert.deepEqual(list, ["has_reservations", "not_own_closure", "closure_managed", "event_managed"]);
  assert.match(core, /case "P0002":\n\s+return \{ status: 404, error: [^\n]*"not_found"/);
  assert.match(core, /case "22023":\n(?:\s*\/\/.*\n)?\s+return \{ status: 400,/);
  // already:true on ok:true -> kulkee 200:na (ok !== true -> 500 vain muille)
  assert.match(core, /if \(!isPlainObject\(d\) \|\| d\.ok !== true\)/);
});
