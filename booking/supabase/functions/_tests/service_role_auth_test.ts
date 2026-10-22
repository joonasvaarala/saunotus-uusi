// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/_tests/service_role_auth_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { authorizeServiceRoleOrPermission, isServiceRoleBearer, jwtHasServiceRoleClaim } from "../_shared/service_role_auth.ts";

const SECRET = "sb_secret_test_not_a_jwt";
const LEGACY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN4Ym9mbnVpc2Vtc3BncXVveHl2Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTcxMDAwMDAwMCwiZXhwIjoyMDAwMDAwMDAwfQ.c2lnbmF0dXJl";
const UTF8 = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwibm90ZSI6IsOkIn0.c2ln";
const USER = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYXV0aGVudGljYXRlZCIsInVzZXJfbWV0YWRhdGEiOnsicm9sZSI6InNlcnZpY2Vfcm9sZSJ9fQ.c2ln";
const PROTO = "h.eyJfX3Byb3RvX18iOnsicm9sZSI6InNlcnZpY2Vfcm9sZSJ9fQ.sig";
const HEADER_ROLE = "eyJhbGciOiJub25lIiwicm9sZSI6InNlcnZpY2Vfcm9sZSJ9.eyJyb2xlIjoiYXV0aGVudGljYXRlZCJ9.sig";

Deno.test("täsmäys hyväksyy asetetun avaimen eikä trimmaa", () => {
  assertEquals(isServiceRoleBearer(SECRET, SECRET), true);
  assertEquals(isServiceRoleBearer(LEGACY, LEGACY), true);
  assertEquals(isServiceRoleBearer(SECRET + " ", SECRET), false);
  assertEquals(isServiceRoleBearer(" " + SECRET, SECRET), false);
  assertEquals(isServiceRoleBearer(SECRET.toUpperCase(), SECRET), false);
  assertEquals(isServiceRoleBearer("sb_secret_other", SECRET), false);
  assertEquals(isServiceRoleBearer(SECRET, undefined), false);
  assertEquals(jwtHasServiceRoleClaim(SECRET), false);
});

Deno.test("legacy service_role-JWT kelpaa vaikka avain on uusi salaisuus", () => {
  assertEquals(jwtHasServiceRoleClaim(LEGACY), true);
  assertEquals(isServiceRoleBearer(LEGACY, SECRET), true);
  assertEquals(isServiceRoleBearer(LEGACY, undefined), true);
  assertEquals(jwtHasServiceRoleClaim(UTF8), true);
});

Deno.test("käyttäjän JWT ja väärä role-claim eivät ole palvelurooli", () => {
  assertEquals(jwtHasServiceRoleClaim(USER), false);
  assertEquals(isServiceRoleBearer(USER, SECRET), false);
  assertEquals(jwtHasServiceRoleClaim(HEADER_ROLE), false);
  assertEquals(jwtHasServiceRoleClaim("h.eyJyb2xlIjoiYW5vbiJ9.s"), false);
  assertEquals(jwtHasServiceRoleClaim("h.eyJyb2xlIjoiU0VSVklDRV9ST0xFIn0.s"), false);
  assertEquals(jwtHasServiceRoleClaim("h.eyJyb2xlIjoic2VydmljZV9yb2xlICJ9.s"), false);
  assertEquals(jwtHasServiceRoleClaim("h.eyJyb2xlIjpbInNlcnZpY2Vfcm9sZSJdfQ.s"), false);
  assertEquals(jwtHasServiceRoleClaim("h.eyJyb2xlIjp0cnVlfQ.s"), false);
  assertEquals(jwtHasServiceRoleClaim("h.e30.s"), false);
  assertEquals(jwtHasServiceRoleClaim("h.W10.s"), false);
});

Deno.test("__proto__ ei tee service_rolesta eikä saastuta Objectia", () => {
  assertEquals(jwtHasServiceRoleClaim(PROTO), false);
  assertEquals(({} as { role?: unknown }).role, undefined);
});

Deno.test("rikkinäinen token ei heitä", () => {
  const samples = [
    "",
    "abc",
    "a.b",
    "a.b.c.d",
    ".eyJyb2xlIjoic2VydmljZV9yb2xlIn0.sig",
    "h.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.",
    "h.@@@.s",
    "h.bm90IGpzb24.s",
    "h.__4.s",
    "h." + "A".repeat(9000) + ".s",
    "h.eyJyb2xlIjoic2VydmljZV9yb2xlIn0=.s",
  ];
  for (const token of samples) {
    assertEquals(jwtHasServiceRoleClaim(token), false, token.slice(0, 24));
    assertEquals(isServiceRoleBearer(token, SECRET), false, token.slice(0, 24));
  }
});

Deno.test("authorize: palvelurooli ei kysy oikeutta, käyttäjä kysyy samalla otsikolla", async () => {
  const calls: string[] = [];
  const allow = async (auth: string) => { calls.push(auth); return auth.endsWith("staff"); };
  assertEquals(await authorizeServiceRoleOrPermission(null, SECRET, allow), false);
  assertEquals(await authorizeServiceRoleOrPermission("", SECRET, allow), false);
  assertEquals(await authorizeServiceRoleOrPermission("Token " + SECRET, SECRET, allow), false);
  assertEquals(await authorizeServiceRoleOrPermission("Bearer" + SECRET, SECRET, allow), false);
  assertEquals(calls, []);

  assertEquals(await authorizeServiceRoleOrPermission("Bearer " + SECRET, SECRET, allow), true);
  assertEquals(await authorizeServiceRoleOrPermission("bearer " + SECRET, SECRET, allow), true);
  assertEquals(await authorizeServiceRoleOrPermission("BEARER " + LEGACY, SECRET, allow), true);
  assertEquals(calls, []);

  assertEquals(await authorizeServiceRoleOrPermission("Bearer " + USER, SECRET, allow), false);
  assertEquals(await authorizeServiceRoleOrPermission("Bearer staff", SECRET, allow), true);
  assertEquals(calls, ["Bearer " + USER, "Bearer staff"]);

  const denied = await authorizeServiceRoleOrPermission("Bearer user-jwt", SECRET, async () => false);
  assertEquals(denied, false);
  const extra = await authorizeServiceRoleOrPermission("Bearer " + SECRET + "x", SECRET, async (auth) => auth === "Bearer " + SECRET + "x");
  assert(extra);
});
