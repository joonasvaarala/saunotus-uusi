// soefix (B4, C1/C2, B9, virhekoodien siivous): WhatsApp ja sähköposti mockattu – ei oikeita lähetyksiä.
// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/soefix_test.ts
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  channelUnusable,
  handleClaimedMessage,
  planMessage,
  readSendResponse,
  resolveTemplate,
  type ClaimedMessage,
  type Settings,
  type TemplateSettings,
  type WhatsappEnv,
} from "./whatsapp.ts";
import { processInboundMessage, type InboundDeps, type StoreResult, type WelcomeResult } from "./inbound.ts";
import { readTemplateSettings } from "./sender.ts";

const STAFF = "aaaaaaaa-0000-4000-8000-0000000000b2";
const NOW = Date.parse("2026-10-25T10:00:00.000Z");
const ENV: WhatsappEnv = { token: "t", phoneNumberId: "123456", appSecret: "s", verifyToken: "v" };
// tuotannon wa_templates migraation jälkeen (fallback poistettu)
const PROD_TPL: TemplateSettings = {
  offer: { name: "tyovuoro_kysely", approved: false },
  round_reminder: { name: "tyovuoro_muistutus", approved: false },
  already_taken: { name: "tyovuoro_jo_mennyt", approved: false },
  day_digest: { name: "tyovuoro_paivan_kooste", approved: false },
};
const APPROVED: TemplateSettings = { ...PROD_TPL, offer: { name: "tyovuoro_kysely", approved: true } };

function msg(over: Partial<ClaimedMessage> = {}): ClaimedMessage {
  return {
    id: 11, kind: "offer", channel: "whatsapp", staff_id: STAFF, attempts: 0, wamid: null, status: "sending",
    phone_raw: "040 765 4321", email: "lammittaja@example.test", role_type: "heater",
    starts_at: "2026-10-27T13:00:00.000Z", ends_at: "2026-10-27T17:00:00.000Z", deadline_at: "2026-10-26T09:00:00.000Z",
    ask_no: null, ask_count: null, token: "payload.sig", staff_whatsapp_enabled: true, bot_channel: false, ...over,
  };
}
function settings(over: Partial<Settings> = {}): Settings {
  return { sender_enabled: true, whatsapp_enabled: true, whatsapp_dry_run: false, allow_staff_ids: [STAFF], templates: PROD_TPL, ...over };
}
function metaMock(status: number, body: unknown) {
  const calls: string[] = [];
  const f = ((_u: string, init: RequestInit) => {
    calls.push(String(init.body));
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as typeof fetch;
  return { f, calls };
}
const noFetch = (() => { throw new Error("Meta-kutsu ei sallittu"); }) as typeof fetch;

Deno.test("B4: hyväksymätön offer-pohja → sähköposti heti, ei koskaan vuorotarjous", async () => {
  for (const kind of ["offer", "reminder"]) {
    const r = await handleClaimedMessage(msg({ kind }), settings(), ENV, noFetch, () => {}, NOW);
    assertEquals([r.action, r.channel, r.to, r.error], ["release", "email", "lammittaja@example.test", "template_not_approved"]);
    assert(!JSON.stringify(r).includes("vuorotarjous"));
  }
  // vanha asetus jossa fallback: fallback ohitetaan lukuvaiheessa
  const legacy = readTemplateSettings({ offer: { name: "tyovuoro_kysely", approved: false, fallback: "vuorotarjous" } });
  assertEquals(resolveTemplate(msg(), legacy), { kind: "unapproved" });
  assertEquals(resolveTemplate(msg(), undefined), { kind: "unapproved" });
  // hyväksytty → tyovuoro_kysely
  const ok = resolveTemplate(msg(), APPROVED);
  assert(ok.kind === "template" && ok.name === "tyovuoro_kysely");
});

Deno.test("B4: hiljaisina tunteina hyväksymätön tarjous menee silti sähköpostiin (ei jää odottamaan WhatsAppia)", () => {
  const p = planMessage(msg(), settings({ whatsapp_hours_open: false }));
  assert(p.action === "release" && p.channel === "email" && p.delayMinutes === 0);
  const q = planMessage(msg(), settings({ whatsapp_hours_open: false, templates: APPROVED }));
  assert(q.action === "release" && q.reason === "quiet_hours" && q.channel === "whatsapp");
});

Deno.test("C1/C2: ei toimivaa kanavaa → fail_no_contact / no_working_channel", async () => {
  const cases: Array<[Partial<ClaimedMessage>, Partial<Settings>]> = [
    [{ phone_raw: null, email: null }, {}],
    [{ email: null }, {}], // hyväksymätön pohja, ei sähköpostia
    [{ email: null }, { whatsapp_enabled: false, templates: APPROVED }],
    [{ email: null, staff_whatsapp_enabled: false }, { templates: APPROVED }],
    [{ email: null }, { allow_staff_ids: [], templates: APPROVED }],
    [{}, { email_enabled: false }], // sähköposti pois asetuksista
    [{ email: "ei-osoite" }, {}], // kelvoton osoite
  ];
  for (const [m, s] of cases) {
    const r = await handleClaimedMessage(msg(m), settings(s), ENV, noFetch, () => {}, NOW);
    assertEquals([r.action, r.channel, r.error], ["fail_no_contact", "none", "no_working_channel"], JSON.stringify([m, s]));
  }
  // puhelin puuttuu mutta sähköposti on → sähköposti heti
  const e = planMessage(msg({ phone_raw: null }), settings());
  assert(e.action === "release" && e.channel === "email" && e.reason === "no_phone" && e.delayMinutes === 0);
});

Deno.test("C1: Metan pohja-/vastaanottajavirhe 4xx → sähköposti; ilman sähköpostia no_working_channel; muu 4xx → failed", async () => {
  const meta = metaMock(400, { error: { code: 132001, message: "Template name does not exist in the translation" } });
  const row = msg();
  const r = await handleClaimedMessage(row, settings({ templates: APPROVED }), ENV, meta.f, () => {}, NOW);
  assertEquals([r.action, r.channel, r.error, meta.calls.length], ["release", "email", "wa_132001", 1]);
  // sama rivi ei lähde toista kertaa samassa ajossa
  const again = await handleClaimedMessage(row, settings({ templates: APPROVED }), ENV, meta.f, () => {}, NOW);
  assertEquals([again.action, meta.calls.length], ["already_sent", 1]);

  const meta2 = metaMock(400, { error: { code: 131026, message: "Message undeliverable to +358407654321" } });
  const n = await handleClaimedMessage(msg({ email: null }), settings({ templates: APPROVED }), ENV, meta2.f, () => {}, NOW);
  assertEquals([n.action, n.error], ["fail_no_contact", "no_working_channel:wa_131026"]);

  const meta3 = metaMock(400, { error: { code: 100, message: "Invalid parameter +358407654321" } });
  const f = await handleClaimedMessage(msg(), settings({ templates: APPROVED }), ENV, meta3.f, () => {}, NOW);
  assertEquals([f.action, f.error], ["fail", "wa_100"]);
  assert(![r.error, n.error, f.error].join(" ").includes("358407654321"));
});

Deno.test("virhetekstistä jää vain koodi (ei numeroita/tekstiä Metalta)", () => {
  assertEquals(readSendResponse(400, JSON.stringify({ error: { code: 131047, message: "Re-engagement +358401111111" } })).error, "wa_131047");
  assertEquals(readSendResponse(500, "<html>+358401111111</html>").error, "http_500");
  assertEquals(readSendResponse(200, JSON.stringify({ messages: [{ id: "wamid.X" }] })), { wamid: "wamid.X", error: null });
  assert(channelUnusable("wa_132000") && channelUnusable("wa_132999") && channelUnusable("wa_131050"));
  assert(!channelUnusable("wa_133000") && !channelUnusable("wa_131000") && !channelUnusable("http_400") && !channelUnusable(null));
});

Deno.test("onnistunut WhatsApp-lähetys hyväksytyllä pohjalla", async () => {
  const meta = metaMock(200, { messages: [{ id: "wamid.OK" }] });
  const r = await handleClaimedMessage(msg(), settings({ templates: APPROVED }), ENV, meta.f, () => {}, NOW);
  assertEquals([r.action, r.wamid, meta.calls.length], ["sent", "wamid.OK", 1]);
  assert(meta.calls[0].includes("tyovuoro_kysely") && !meta.calls[0].includes("vuorotarjous"));
});

// ---------------- B9 tervetuloviesti
const STORED: StoreResult = { id: "m9", duplicate: false, handled: false, inboundEnabled: false, staffId: STAFF, replyTo: "+358407654321" };
const INBOUND = { wamid: "wamid.IN9", from: "358407654321", type: "text", text: "moi", buttonId: null, at: null };

function deps(store: StoreResult, welcome: WelcomeResult, send: InboundDeps["send"]) {
  const marks: string[] = [];
  const outbound: unknown[] = [];
  const d: InboundDeps = {
    store: () => Promise.resolve(store),
    act: () => Promise.resolve({ replyBody: null, buttons: [], shiftId: null, suppressed: false }),
    send,
    markHandled: () => Promise.resolve(),
    storeOutbound: (r) => { outbound.push(r); return Promise.resolve(); },
    log: () => {},
    welcome: () => Promise.resolve(welcome),
    welcomeSent: (s, w) => { marks.push(`sent:${s}:${w}`); return Promise.resolve(); },
    welcomeRelease: (s) => { marks.push(`release:${s}`); return Promise.resolve(); },
  };
  return { d, marks, outbound };
}

Deno.test("B9: welcome_sent_at vasta onnistuneesta lähetyksestä", async () => {
  const ok = deps(STORED, { send: true, body: "Hei Aino! Tervetuloa", staffId: STAFF }, () => Promise.resolve({ ok: true, wamid: "wamid.W" }));
  await processInboundMessage(INBOUND, ok.d);
  assertEquals([ok.marks, ok.outbound.length], [[`sent:${STAFF}:wamid.W`], 1]);

  const bad = deps(STORED, { send: true, body: "Hei", staffId: STAFF }, () => Promise.resolve({ ok: false, wamid: null }));
  await processInboundMessage(INBOUND, bad.d);
  assertEquals([bad.marks, bad.outbound.length], [[`release:${STAFF}`], 0]);

  const boom = deps(STORED, { send: true, body: "Hei", staffId: STAFF }, () => Promise.reject(new Error("verkko")));
  await assertRejects(() => processInboundMessage(INBOUND, boom.d));
  assertEquals(boom.marks, [`release:${STAFF}`]);

  // ei vastaanottajaa → varaus vapautetaan, ei lähetystä
  const noTo = deps({ ...STORED, replyTo: null as unknown as string }, { send: true, body: "Hei", staffId: STAFF }, () => { throw new Error("ei"); });
  await processInboundMessage(INBOUND, noTo.d);
  assertEquals(noTo.marks, [`release:${STAFF}`]);

  // uudelleentoimitus: tietokanta päättää; send=false → ei mitään
  const dup = deps({ ...STORED, duplicate: true }, { send: false, body: null }, () => { throw new Error("ei"); });
  await processInboundMessage(INBOUND, dup.d);
  assertEquals(dup.marks, []);
});
