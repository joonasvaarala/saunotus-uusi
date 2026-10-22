// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/inbound_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { parseIntent, processInboundMessage, type ActResult, type InboundDeps, type Intent, type OutboundRecord, type StoreResult } from "./inbound.ts";
import { deliverInbound } from "./sender.ts";
import {
  buildSessionPayload,
  handleWebhookRequest,
  webhookSignatureHex,
  type ParsedInbound,
  type ReplyButton,
  type WhatsappEnv,
} from "./whatsapp.ts";

const PEKKA = "11111111-1111-4111-8111-111111111111";
const OFFER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const ACTION = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const SHIFT = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const POISON = "SALAINEN Paula 03:33";

const env: WhatsappEnv = {
  token: "super-secret-token",
  phoneNumberId: "123456789012345",
  appSecret: "test-app-secret",
  verifyToken: "verify-me",
};

function message(over: Partial<ParsedInbound> = {}): ParsedInbound {
  return {
    wamid: "wamid.1",
    from: "358401110001",
    type: "text",
    text: "vuorot",
    buttonId: null,
    at: "2026-10-22T17:24:59.000Z",
    ...over,
  };
}

function stored(over: Partial<StoreResult> = {}): StoreResult {
  return {
    id: "msg-1",
    duplicate: false,
    handled: false,
    inboundEnabled: true,
    staffId: PEKKA,
    replyTo: "+358401110001",
    ...over,
  };
}

function reply(over: Partial<ActResult> = {}): ActResult {
  return {
    replyBody: "Tulevat vuorosi:\n1. la 24.10.2026 klo 10:00–14:00 lämmitysvuoro\n–Tapio",
    buttons: [],
    shiftId: null,
    suppressed: false,
    ...over,
  };
}

function harness(storeResult: StoreResult, actResult: ActResult | ((intent: Intent) => ActResult)) {
  const sent: Array<{ to: string; body: string; buttons: ReplyButton[] }> = [];
  const outbound: OutboundRecord[] = [];
  const handled: Array<{ id: string; op: string }> = [];
  const acts: Intent[] = [];
  let stores = 0;
  const deps: InboundDeps = {
    async store() {
      stores += 1;
      return storeResult;
    },
    async act(_id, intent) {
      acts.push(intent);
      return typeof actResult === "function" ? actResult(intent) : actResult;
    },
    async send(to, body, buttons) {
      sent.push({ to, body, buttons });
      return { ok: true, wamid: "wamid.OUT" };
    },
    async markHandled(id, op) {
      handled.push({ id, op });
    },
    async storeOutbound(record) {
      outbound.push(record);
    },
    log() {},
  };
  return { deps, sent, outbound, handled, acts, stores: () => stores };
}

Deno.test("parseIntent tunnistaa napit ja selkeät komennot", () => {
  assertEquals(parseIntent("vuorot", null), { op: "own_shifts" });
  assertEquals(parseIntent("  Näytä   vuorot Paula! ", null), { op: "person_shifts", name: "paula" });
  assertEquals(parseIntent("vuorot kaikki", null), { op: "all_shifts" });
  assertEquals(parseIntent("kaikkien vuorot", null), { op: "all_shifts" });
  assertEquals(parseIntent("hyväksy", null), { op: "accept" });
  assertEquals(parseIntent("hyvaksy 2", null), { op: "accept", index: 2 });
  assertEquals(parseIntent("en ota", null), { op: "decline" });
  assertEquals(parseIntent("en voi", null), { op: "unknown" });
  assertEquals(parseIntent("peru 2", null), { op: "prepare_cancel", index: 2 });
  assertEquals(parseIntent("peruuta", null), { op: "abort" });
  assertEquals(parseIntent("anna 2 Paula Testi", null), { op: "prepare_assign", index: 2, name: "paula testi" });
  assertEquals(parseIntent("pois 1 Paula", null), { op: "prepare_unassign", index: 1, name: "paula" });
  assertEquals(parseIntent("aika 2 25.10.2026 16:00-20:00", null), {
    op: "prepare_time",
    index: 2,
    date: "25.10.2026",
    start: "16:00",
    end: "20:00",
  });
  assertEquals(parseIntent("kyllä", null), { op: "confirm" });
  assertEquals(parseIntent("apua", null), { op: "help" });
  assertEquals(parseIntent("vuorot", `a:${OFFER}`), { op: "accept", offer_id: OFFER });
  assertEquals(parseIntent("mitä vain", `y:${ACTION}`), { op: "confirm", action_id: ACTION });
  assertEquals(parseIntent("mitä vain", `n:${ACTION}`), { op: "abort", action_id: ACTION });
  assertEquals(parseIntent("", null), { op: "unknown" });
});

Deno.test("tuntematon numero ei saa vastausta vaikka itsepalvelu on päällä", async () => {
  const box = harness(
    stored({ staffId: null, replyTo: "+358409990099", inboundEnabled: true }),
    reply({ replyBody: POISON, buttons: [{ id: `a:${OFFER}`, title: "Hyväksy" }] }),
  );
  await processInboundMessage(message({ from: "358409990099", text: "vuorot Paula" }), box.deps);
  assertEquals(box.stores(), 1);
  assertEquals(box.acts, []);
  assertEquals(box.sent, []);
  assertEquals(box.outbound, []);
  assertEquals(box.handled, []);
});

Deno.test("allekirjoitettu webhook ei lähetä tuntemattomalle numerolle mitään", async () => {
  const body = JSON.stringify({
    object: "whatsapp_business_account",
    entry: [{
      changes: [{
        value: {
          messages: [{
            from: "358409990099",
            id: "wamid.UNKNOWN",
            type: "text",
            timestamp: "1761153899",
            text: { body: "vuorot Paula" },
          }],
        },
      }],
    }],
  });
  const raw = new TextEncoder().encode(body);
  const sig = await webhookSignatureHex(env.appSecret, raw);
  const box = harness(
    stored({ staffId: null, replyTo: "+358409990099", inboundEnabled: true }),
    reply({ replyBody: POISON, buttons: [{ id: `a:${OFFER}`, title: "Hyväksy" }] }),
  );
  const res = await handleWebhookRequest(new Request("https://example.test/webhook", {
    method: "POST",
    headers: { "x-hub-signature-256": `sha256=${sig}`, "content-type": "application/json" },
    body,
  }), env, async () => {}, async (inbound) => {
    await processInboundMessage(inbound, box.deps);
  });
  assertEquals(res.status, 200);
  assertEquals(box.stores(), 1);
  assertEquals(box.sent, []);
  assertEquals(box.outbound, []);
  assertEquals(JSON.stringify(box.sent).includes(POISON), false);
});

Deno.test("tunnettu työntekijä saa oman vuorolistan ja viesti merkitään käsitellyksi", async () => {
  const body = "Tulevat vuorosi:\n1. la 24.10.2026 klo 10:00–14:00 lämmitysvuoro\n–Tapio";
  const box = harness(stored(), reply({ replyBody: body }));
  await processInboundMessage(message({ text: "vuorot" }), box.deps);
  assertEquals(box.acts, [{ op: "own_shifts" }]);
  assertEquals(box.sent.length, 1);
  assertEquals(box.sent[0].to, "+358401110001");
  assertEquals(box.sent[0].body, body);
  assert(box.sent[0].body.includes("10:00"));
  assert(!box.sent[0].body.includes("Paula"));
  assert(!box.sent[0].body.includes("03:33"));
  assertEquals(box.handled, [{ id: "msg-1", op: "own_shifts" }]);
  assertEquals(box.outbound.length, 1);
  assertEquals(box.outbound[0].staffId, PEKKA);
  assertEquals(box.outbound[0].text, body);
  assertEquals(box.outbound[0].wamid, "wamid.OUT");
});

Deno.test("peruskäyttäjän yritys katsoa toisen vuoroja lähettää vain kiellon", async () => {
  const denial = "Näet vain omat vuorosi. Kirjoita vuorot.\n–Tapio";
  const box = harness(stored(), (intent) => {
    assert(intent.op === "person_shifts" || intent.op === "all_shifts");
    return reply({ replyBody: denial });
  });
  await processInboundMessage(message({ text: "vuorot Paula", wamid: "wamid.person" }), box.deps);
  await processInboundMessage(message({ text: "kaikki vuorot", wamid: "wamid.all" }), box.deps);
  assertEquals(box.sent.map((row) => row.body), [denial, denial]);
  assert(box.sent.every((row) => !row.body.includes("Paula") && !row.body.includes("03:33") && !row.body.includes(POISON)));
});

Deno.test("tarjouksen voi hyväksyä tekstillä tai napilla", async () => {
  const box = harness(stored(), (intent) => {
    assert(intent.op === "accept");
    return reply({ replyBody: "Vuoro on sinun: la 24.10.2026 klo 12:00–16:00 lämmitysvuoro.\n–Tapio", shiftId: SHIFT });
  });
  await processInboundMessage(message({ text: "hyväksy", wamid: "wamid.accept" }), box.deps);
  await processInboundMessage(message({ text: "vuorot", buttonId: `a:${OFFER}`, wamid: "wamid.button" }), box.deps);
  assertEquals(box.acts[0], { op: "accept" });
  assertEquals(box.acts[1], { op: "accept", offer_id: OFFER });
  assertEquals(box.sent.length, 2);
  assertEquals(box.outbound[1].shiftId, SHIFT);
});

Deno.test("ylläpitäjän muutos lähtee vasta vahvistuksesta", async () => {
  let writes = 0;
  const box = harness(stored({ staffId: "33333333-3333-4333-8333-333333333333" }), (intent) => {
    if (intent.op === "prepare_cancel") {
      return reply({
        replyBody: "Vahvistatko peruutuksen: lämmitysvuoro su 25.10.2026 klo 03:33–07:33 (Paula Testi)?\n–Tapio",
        buttons: [
          { id: `y:${ACTION}`, title: "Vahvista" },
          { id: `n:${ACTION}`, title: "Peruuta" },
        ],
        shiftId: SHIFT,
      });
    }
    if (intent.op === "confirm") {
      writes += 1;
      return reply({ replyBody: "Peruin vuoron: lämmitysvuoro su 25.10.2026 klo 03:33–07:33 (Paula Testi).\n–Tapio", shiftId: SHIFT });
    }
    throw new Error(`unexpected ${intent.op}`);
  });
  await processInboundMessage(message({ text: "peru 2", wamid: "wamid.prepare" }), box.deps);
  assertEquals(writes, 0);
  assert(box.sent[0].body.includes("Vahvistatko"));
  assertEquals(box.sent[0].buttons[0].id, `y:${ACTION}`);
  await processInboundMessage(message({ text: "Vahvista", buttonId: `y:${ACTION}`, wamid: "wamid.confirm" }), box.deps);
  assertEquals(writes, 1);
  assertEquals(box.acts[1], { op: "confirm", action_id: ACTION });
  assertEquals(box.outbound.length, 2);
});

Deno.test("itsepalvelu pois päältä ei lähetä, vaikka numero on henkilöstöä", async () => {
  const box = harness(
    stored({ inboundEnabled: false }),
    reply({ replyBody: POISON }),
  );
  await processInboundMessage(message(), box.deps);
  assertEquals(box.acts, []);
  assertEquals(box.sent, []);
  assertEquals(box.outbound, []);
  assertEquals(box.handled, []);
});

Deno.test("jo käsiteltyä kaksoiskappaletta ei käsitellä uudelleen", async () => {
  const box = harness(stored({ duplicate: true, handled: true }), reply({ replyBody: POISON }));
  await processInboundMessage(message(), box.deps);
  assertEquals(box.acts, []);
  assertEquals(box.sent, []);
});

Deno.test("epäonnistunut lähetys jättää viestin käsittelemättä eikä kirjaa outboundia", async () => {
  const box = harness(stored(), reply());
  box.deps.send = async () => ({ ok: false, wamid: null });
  await processInboundMessage(message(), box.deps);
  assertEquals(box.handled, []);
  assertEquals(box.outbound, []);
});

Deno.test("istuntoviesti käyttää nappeja ja preview_url on kiinni", () => {
  const payload = buildSessionPayload("+358401110001", "Vahvistatko peruutuksen?", [
    { id: `y:${ACTION}`, title: "Vahvista tämä heti nyt" },
    { id: `n:${ACTION}`, title: "Peruuta" },
  ]);
  assert(payload);
  assertEquals(payload.type, "interactive");
  if (payload.type !== "interactive") return;
  assertEquals(payload.interactive.action.buttons[0].reply.title, "Vahvista tämä heti n");
  assertEquals(payload.interactive.action.buttons.length, 2);
  const plain = buildSessionPayload("+358401110001", "Tulevat vuorosi.", []);
  assert(plain && plain.type === "text");
  if (plain?.type === "text") assertEquals(plain.text.preview_url, false);
});

Deno.test("deliverInbound ei soita Graphiin tuntemattomalle numerolle", async () => {
  const calls: string[] = [];
  let fetches = 0;
  const supa = {
    async rpc(name: string) {
      calls.push(name);
      if (name === "whatsapp_store_inbound") {
        return {
          data: {
            ok: true,
            id: "msg-unknown",
            duplicate: false,
            handled: false,
            inbound_enabled: true,
            staff_id: null,
            reply_to: "+358409990099",
          },
          error: null,
        };
      }
      if (name === "whatsapp_inbound_act") {
        return {
          data: {
            reply_body: POISON,
            buttons: [{ id: `a:${OFFER}`, title: "Hyväksy" }],
            shift_id: null,
            suppressed: false,
          },
          error: null,
        };
      }
      if (name === "whatsapp_store_outbound" || name === "whatsapp_mark_handled") {
        return { data: null, error: null };
      }
      return { data: null, error: { message: name } };
    },
  };
  await deliverInbound(supa as unknown as SupabaseClient, env, message({ from: "358409990099", text: "vuorot Paula" }), () => {}, async () => {
    fetches += 1;
    return new Response("{}", { status: 200 });
  });
  assertEquals(calls, ["whatsapp_store_inbound"]);
  assertEquals(fetches, 0);
  assert(!calls.includes("whatsapp_store_outbound"));
  assert(!calls.includes("whatsapp_inbound_act"));
});
