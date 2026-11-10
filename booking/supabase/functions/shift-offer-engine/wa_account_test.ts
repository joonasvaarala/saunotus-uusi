// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/wa_account_test.ts
// Metan virhe 132001: numero voi kuulua useaan messaging-tiliin → jokainen /messages-kutsu nimeää tilin
// (messaging_account_id, env WHATSAPP_MESSAGING_ACCOUNT_ID). Tyhjä env → kenttä puuttuu kokonaan.
// Ei verkkoa: fetch on aina testin oma.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  buildChosenTemplate,
  buildSessionPayload,
  buildTemplatePayload,
  handleClaimedMessage,
  postSession,
  postTemplate,
  withMessagingAccount,
  type ClaimedMessage,
  type Settings,
  type TemplateSettings,
  type WhatsappEnv,
} from "./whatsapp.ts";
import { deliverInbound, readWhatsappEnv } from "./sender.ts";

const WABA = "1810665439953162";
const STAFF = "aaaaaaaa-0000-4000-8000-0000000000a1";
const NOW = Date.parse("2026-10-22T09:00:00.000Z");
const BASE: WhatsappEnv = { token: "t", phoneNumberId: "123456", appSecret: "s", verifyToken: "v" };
const WITH: WhatsappEnv = { ...BASE, messagingAccountId: WABA };

const APPROVED: TemplateSettings = {
  offer: { name: "tyovuoro_kysely", approved: true },
  round_reminder: { name: "tyovuoro_muistutus", approved: true },
  already_taken: { name: "tyovuoro_jo_mennyt", approved: true },
  day_digest: { name: "tyovuoro_paivan_kooste", approved: true },
};

function msg(over: Partial<ClaimedMessage> = {}): ClaimedMessage {
  return {
    id: 7, kind: "offer", channel: "whatsapp", staff_id: STAFF, attempts: 0, wamid: null, status: "sending",
    phone_raw: "040 123 4567", email: "testi@example.test", role_type: "heater",
    starts_at: "2026-10-24T13:00:00.000Z", ends_at: "2026-10-24T17:00:00.000Z", deadline_at: "2026-10-24T09:00:00.000Z",
    ask_no: 1, ask_count: 3, token: "payload.sig", staff_whatsapp_enabled: true, bot_channel: false, ...over,
  };
}

function settings(over: Partial<Settings> = {}): Settings {
  return { sender_enabled: true, whatsapp_enabled: true, whatsapp_dry_run: false, allow_staff_ids: [STAFF], templates: APPROVED, ...over };
}

function capture() {
  const bodies: Record<string, unknown>[] = [];
  const fetchImpl = ((_u: string, init: RequestInit) => {
    bodies.push(JSON.parse(String(init.body)));
    return Promise.resolve(new Response(JSON.stringify({ messages: [{ id: `wamid.${bodies.length}` }] }), { status: 200 }));
  }) as typeof fetch;
  return { bodies, fetchImpl };
}

function envOf(values: Record<string, string | undefined>) {
  return { get: (name: string) => values[name] };
}

Deno.test("readWhatsappEnv: WHATSAPP_MESSAGING_ACCOUNT_ID luetaan, tyhjä/puuttuva → ei arvoa", () => {
  assertEquals(readWhatsappEnv(envOf({ WHATSAPP_MESSAGING_ACCOUNT_ID: WABA })).messagingAccountId, WABA);
  assertEquals(readWhatsappEnv(envOf({ WHATSAPP_MESSAGING_ACCOUNT_ID: `  ${WABA} ` })).messagingAccountId, WABA);
  assertEquals(readWhatsappEnv(envOf({ WHATSAPP_MESSAGING_ACCOUNT_ID: "" })).messagingAccountId, undefined);
  assertEquals(readWhatsappEnv(envOf({ WHATSAPP_MESSAGING_ACCOUNT_ID: "   " })).messagingAccountId, undefined);
  assertEquals(readWhatsappEnv(envOf({})).messagingAccountId, undefined);
});

Deno.test("rakentajat: kenttä mukana kun tili annettu, kokonaan pois kun tyhjä", () => {
  const legacy = buildTemplatePayload(msg({ kind: "alert" }), "+358401234567", WABA);
  assertEquals(legacy?.messaging_account_id, WABA);
  const chosen = buildChosenTemplate({ kind: "template", name: "tyovuoro_jo_mennyt", params: ["a", "b"], buttonToken: null, needsButton: false }, "+358401234567", WABA);
  assertEquals(chosen?.messaging_account_id, WABA);
  const text = buildSessionPayload("+358401234567", "Hei", [], WABA);
  const inter = buildSessionPayload("+358401234567", "Hei", [{ id: "a:1", title: "Hyväksy" }], WABA);
  assertEquals([text?.type, text?.messaging_account_id], ["text", WABA]);
  assertEquals([inter?.type, inter?.messaging_account_id], ["interactive", WABA]);
  for (const empty of [undefined, null, "", "  "]) {
    for (const p of [
      buildTemplatePayload(msg({ kind: "alert" }), "+358401234567", empty),
      buildChosenTemplate({ kind: "template", name: "x", params: [], buttonToken: null, needsButton: false }, "+358401234567", empty),
      buildSessionPayload("+358401234567", "Hei", [], empty),
      buildSessionPayload("+358401234567", "Hei", [{ id: "a:1", title: "Hyväksy" }], empty),
    ]) {
      assert(p && !("messaging_account_id" in p), JSON.stringify(p));
    }
  }
});

Deno.test("withMessagingAccount on idempotentti ja poistaa vanhan arvon kun tili tyhjä", () => {
  const p = buildSessionPayload("+358401234567", "Hei", [], WABA)!;
  assertEquals(withMessagingAccount(p, WABA), p);
  assert(!("messaging_account_id" in withMessagingAccount(p, "")));
  assertEquals(withMessagingAccount(p, "999").messaging_account_id, "999");
});

Deno.test("postTemplate / postSession lisäävät kentän aina kun env asetettu", async () => {
  const c = capture();
  const tpl = buildChosenTemplate({ kind: "template", name: "tyovuoro_jo_mennyt", params: ["a", "b"], buttonToken: null, needsButton: false }, "+358401234567")!;
  const ses = buildSessionPayload("+358401234567", "Hei")!;
  await postTemplate(WITH, tpl, c.fetchImpl);
  await postSession(WITH, ses, c.fetchImpl);
  await postTemplate(BASE, tpl, c.fetchImpl);
  await postSession(BASE, ses, c.fetchImpl);
  assertEquals(c.bodies.map((b) => b.messaging_account_id), [WABA, WABA, undefined, undefined]);
  assert(!("messaging_account_id" in c.bodies[2]) && !("messaging_account_id" in c.bodies[3]));
});

// Kaikki jonon lähetyspolut: hyväksytyt pohjat (offer/muistutus/jo mennyt/kooste), vanha KIND_TEMPLATE-pohja ja 24 h -istuntoviesti.
const QUEUE_CASES: Array<[string, Partial<ClaimedMessage>, Partial<Settings>, string]> = [
  ["offer tyovuoro_kysely", {}, {}, "template"],
  ["round_reminder", { kind: "reminder", subkind: "round_reminder" }, {}, "template"],
  ["already_taken", { kind: "filled", subkind: "already_taken" }, {}, "template"],
  ["day_digest", { kind: "alert", subkind: "day_digest", page_token: "tok.sig", digest: { date_label: "27.11.2026", items: "x" } }, {}, "template"],
  ["legacy KIND_TEMPLATE", { kind: "alert" }, { templates: undefined }, "template"],
  ["session 24 h", { kind: "filled", subkind: "already_taken", body: "Vuoro on jo mennyt.", session_open: true }, { templates: { ...APPROVED, already_taken: { name: "tyovuoro_jo_mennyt", approved: false } } }, "text"],
];

for (const [name, over, sOver, type] of QUEUE_CASES) {
  Deno.test(`jono (${name}): messaging_account_id mukana env:n kanssa, puuttuu ilman`, async () => {
    const a = capture();
    const ra = await handleClaimedMessage(msg(over), settings(sOver), WITH, a.fetchImpl, () => {}, NOW);
    assertEquals(ra.action, "sent");
    assertEquals([a.bodies.length, a.bodies[0].type, a.bodies[0].messaging_account_id], [1, type, WABA]);
    const b = capture();
    const rb = await handleClaimedMessage(msg(over), settings(sOver), BASE, b.fetchImpl, () => {}, NOW);
    assertEquals(rb.action, "sent");
    assertEquals([b.bodies.length, b.bodies[0].type], [1, type]);
    assert(!("messaging_account_id" in b.bodies[0]));
  });
}

Deno.test("dry run -loki näyttää saman kentän eikä lähetä", async () => {
  const logs: Array<[string, Record<string, unknown>]> = [];
  const c = capture();
  const r = await handleClaimedMessage(msg(), settings({ whatsapp_dry_run: true }), WITH, c.fetchImpl, (e, d) => logs.push([e, d]), NOW);
  assertEquals([r.action, r.error, c.bodies.length], ["release", "dry_run", 0]);
  const body = logs.find(([e]) => e === "whatsapp_dry_run")?.[1].body as Record<string, unknown>;
  assertEquals(body.messaging_account_id, WABA);
});

function inboundSupa() {
  return {
    async rpc(name: string) {
      if (name === "whatsapp_store_inbound") {
        return { data: { ok: true, id: "m1", duplicate: false, handled: false, inbound_enabled: true, staff_id: STAFF, reply_to: "+358401110001" }, error: null };
      }
      if (name === "whatsapp_inbound_act") {
        return { data: { reply_body: "Vuorosi: ei vuoroja.", buttons: [{ id: "a:1", title: "Hyväksy" }], shift_id: null, suppressed: false }, error: null };
      }
      return { data: null, error: null };
    },
    schema() {
      return { rpc: async () => ({ data: null, error: null }) };
    },
  };
}

Deno.test("saapuvaan vastaaminen (deliverInbound): kenttä mukana env:n kanssa, puuttuu ilman", async () => {
  const parsed = { wamid: "wamid.in", from: "358401110001", type: "text", text: "vuorot", buttonId: null, at: "2026-10-22T17:24:59.000Z" };
  const a = capture();
  await deliverInbound(inboundSupa() as unknown as SupabaseClient, WITH, parsed, () => {}, a.fetchImpl);
  assertEquals([a.bodies.length, a.bodies[0].type, a.bodies[0].messaging_account_id], [1, "interactive", WABA]);
  const b = capture();
  await deliverInbound(inboundSupa() as unknown as SupabaseClient, BASE, parsed, () => {}, b.fetchImpl);
  assertEquals(b.bodies.length, 1);
  assert(!("messaging_account_id" in b.bodies[0]));
});
