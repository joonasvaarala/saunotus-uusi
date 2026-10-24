// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/booking153_test.ts
// booking_153: pohjavalinta (tyovuoro_kysely / vuorotarjous-varapohja), uudet viestilajit, 08–21-ikkuna,
// tervetuloviesti ja oma sivu. Ei verkkoa: fetch on aina testin oma.
import { assert, assertEquals } from "jsr:@std/assert@1";
import templates from "../../../../docs/whatsapp-templates.json" with { type: "json" };
import {
  handleClaimedMessage,
  planMessage,
  redactTemplatePayload,
  resolveTemplate,
  type ClaimedMessage,
  type Settings,
  type TemplateSettings,
  type WhatsappEnv,
} from "./whatsapp.ts";
import { processInboundMessage, type InboundDeps, type StoreResult } from "./inbound.ts";
import { handleMyPageRequest, myRoute, validStaffToken, type MyPageDb } from "./mypage.ts";
import { readTemplateSettings } from "./sender.ts";

const STAFF = "aaaaaaaa-0000-4000-8000-0000000000a1";
const NOW = Date.parse("2026-10-22T09:00:00.000Z");
const PAGE_TOKEN = "eyJwIjoiYWFhYWFhYWEtMDAwMC00MDAwIiwibiI6IngifQ.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";
const ENV: WhatsappEnv = { token: "t", phoneNumberId: "123456", appSecret: "s", verifyToken: "v" };

const TPL: TemplateSettings = {
  offer: { name: "tyovuoro_kysely", approved: false, fallback: "vuorotarjous" },
  round_reminder: { name: "tyovuoro_muistutus", approved: false },
  already_taken: { name: "tyovuoro_jo_mennyt", approved: false },
  day_digest: { name: "tyovuoro_paivan_kooste", approved: false },
};

function msg(over: Partial<ClaimedMessage> = {}): ClaimedMessage {
  return {
    id: 7, kind: "offer", channel: "whatsapp", staff_id: STAFF, attempts: 0, wamid: null, status: "sending",
    phone_raw: "040 123 4567", email: "testi@example.test", role_type: "heater",
    starts_at: "2026-10-24T13:00:00.000Z", ends_at: "2026-10-24T17:00:00.000Z", deadline_at: "2026-10-24T09:00:00.000Z",
    ask_no: null, ask_count: null, token: "payload.sig", staff_whatsapp_enabled: true, bot_channel: false, ...over,
  };
}

function settings(over: Partial<Settings> = {}): Settings {
  return { sender_enabled: true, whatsapp_enabled: true, whatsapp_dry_run: false, allow_staff_ids: [STAFF], templates: TPL, ...over };
}

Deno.test("tarjous: varapohja vuorotarjous kunnes tyovuoro_kysely on hyväksytty", () => {
  const p1 = planMessage(msg(), settings());
  assert(p1.action === "send" && p1.payload.type === "template");
  assertEquals(p1.payload.template.name, "vuorotarjous");
  const approved = { ...TPL, offer: { ...TPL.offer, approved: true } };
  const p2 = planMessage(msg({ kind: "reminder" }), settings({ templates: approved }));
  assert(p2.action === "send" && p2.payload.type === "template");
  assertEquals(p2.payload.template.name, "tyovuoro_kysely");
  const body = p2.payload.template.components[0];
  assertEquals(body.type === "body" ? body.parameters.map((x) => x.text) : [], ["lämmitysvuoro", "la 24.10.2026 klo 16:00–20:00", "24.10.2026 klo 12:00"]);
  const button = p2.payload.template.components[1];
  assertEquals(button.type === "button" ? button.parameters[0].text : "", "payload.sig");
});

Deno.test("ilman pohja-asetuksia vanha käytös säilyy", () => {
  const p = planMessage(msg(), settings({ templates: undefined }));
  assert(p.action === "send" && p.payload.type === "template");
  assertEquals(p.payload.template.name, "vuorotarjous");
  assertEquals(resolveTemplate(msg({ kind: "filled" }), undefined), { kind: "legacy" });
});

Deno.test("hyväksymätön uusi pohja: 24 h ikkunassa vapaamuotoinen, muuten sähköposti, ei rikkinäistä lähetystä", () => {
  const reminder = msg({ kind: "reminder", subkind: "round_reminder", body: "Muistutus ... token=abc\n\n–Tapio" });
  const closed = planMessage(reminder, settings());
  assert(closed.action === "release");
  assertEquals([closed.reason, closed.channel], ["template_not_approved", "email"]);
  const noEmail = planMessage({ ...reminder, email: null }, settings());
  assert(noEmail.action === "release" && noEmail.channel === "whatsapp");
  const open = planMessage({ ...reminder, session_open: true }, settings());
  assert(open.action === "send" && open.payload.type === "text");
  assert(open.payload.type === "text" && open.payload.text.body.includes("–Tapio"));
  const red = redactTemplatePayload(open.payload);
  assert(red.type === "text" && red.text.body.includes("token=***") && !red.text.body.includes("token=abc") && red.to.includes("*"));
});

Deno.test("hyväksytyt uudet pohjat: muistutus, jo mennyt ja päivän kooste", () => {
  const ok: TemplateSettings = {
    ...TPL,
    round_reminder: { name: "tyovuoro_muistutus", approved: true },
    already_taken: { name: "tyovuoro_jo_mennyt", approved: true },
    day_digest: { name: "tyovuoro_paivan_kooste", approved: true },
  };
  const r = planMessage(msg({ kind: "reminder", subkind: "round_reminder" }), settings({ templates: ok }));
  assert(r.action === "send" && r.payload.type === "template" && r.payload.template.name === "tyovuoro_muistutus" && r.payload.template.components.length === 2);
  const a = planMessage(msg({ kind: "filled", subkind: "already_taken" }), settings({ templates: ok }));
  assert(a.action === "send" && a.payload.type === "template" && a.payload.template.name === "tyovuoro_jo_mennyt" && a.payload.template.components.length === 1);
  const d = planMessage(msg({ kind: "alert", subkind: "day_digest", page_token: PAGE_TOKEN, digest: { date_label: "27.11.2026", items: "Lämmitysvuoro 10:00–14:00; Lämmitysvuoro 16:00–20:00" } }), settings({ templates: ok }));
  assert(d.action === "send" && d.payload.type === "template" && d.payload.template.name === "tyovuoro_paivan_kooste");
  const comps = d.action === "send" && d.payload.type === "template" ? d.payload.template.components : [];
  assertEquals(comps[0].type === "body" ? comps[0].parameters.map((x) => x.text) : [], ["27.11.2026", "Lämmitysvuoro 10:00–14:00; Lämmitysvuoro 16:00–20:00"]);
  assertEquals(comps[1].type === "button" ? comps[1].parameters[0].text : "", PAGE_TOKEN);
  const noTok = planMessage(msg({ kind: "alert", subkind: "day_digest", page_token: null, digest: { date_label: "x", items: "y" } }), settings({ templates: ok }));
  assert(noTok.action === "release" && noTok.reason === "no_token");
});

Deno.test("koosteviesti ei koskaan lähde vanhalla joonas_tyhja_vuoro-pohjalla; ilmoitukset vain vapaamuotoisina", () => {
  const d = planMessage(msg({ kind: "alert", subkind: "day_digest", page_token: PAGE_TOKEN }), settings());
  assert(d.action === "release" && d.reason === "template_not_approved");
  const n = planMessage(msg({ kind: "alert", subkind: "th_3wk", body: "x" }), settings());
  assert(n.action === "release" && n.reason === "template_not_approved");
});

Deno.test("WhatsApp-ikkunan ulkopuolella ei lähetetä", async () => {
  let called = 0;
  const fetchImpl = (() => { called += 1; return Promise.resolve(new Response("{}")); }) as typeof fetch;
  const res = await handleClaimedMessage(msg(), settings({ whatsapp_hours_open: false }), ENV, fetchImpl, () => {}, NOW);
  assertEquals([res.action, res.error, called], ["release", "quiet_hours", 0]);
});

Deno.test("vapaamuotoinen viesti lähtee postSessionilla", async () => {
  const bodies: unknown[] = [];
  const fetchImpl = ((_u: string, init: RequestInit) => {
    bodies.push(JSON.parse(String(init.body)));
    return Promise.resolve(new Response(JSON.stringify({ messages: [{ id: "wamid.S" }] }), { status: 200 }));
  }) as typeof fetch;
  const res = await handleClaimedMessage(msg({ subkind: "already_taken", kind: "filled", body: "Vuoro on jo mennyt.\n\n–Tapio", session_open: true }),
    settings(), ENV, fetchImpl, () => {}, NOW);
  assertEquals(res.action, "sent");
  assertEquals((bodies[0] as { type: string }).type, "text");
});

Deno.test("pohja-asetukset luetaan claimista turvallisesti", () => {
  assertEquals(readTemplateSettings(null), undefined);
  const t = readTemplateSettings({ offer: { name: "tyovuoro_kysely", approved: "true", fallback: "vuorotarjous" } });
  assertEquals(t?.offer, { name: "tyovuoro_kysely", approved: false, fallback: "vuorotarjous" });
  const bad = resolveTemplate(msg(), { offer: { name: "Bad Name!", approved: true, fallback: "vuorotarjous" } });
  assert(bad.kind === "template" && bad.name === "vuorotarjous");
});

Deno.test("META-pohjat on kirjattu docs/whatsapp-templates.json:iin (UTILITY, fi, ei emojeja, muuttuja ei alussa/lopussa)", () => {
  const list = (templates as unknown as { booking_153_templates: Array<{ name: string; category: string; language: string; components: Array<{ type: string; text?: string }> }> }).booking_153_templates;
  assertEquals(list.map((t) => t.name).sort(), ["tyovuoro_jo_mennyt", "tyovuoro_kysely", "tyovuoro_muistutus", "tyovuoro_paivan_kooste"]);
  for (const t of list) {
    assertEquals([t.category, t.language], ["UTILITY", "fi"]);
    const body = t.components.find((c) => c.type === "BODY")?.text ?? "";
    assert(!/^\s*\{\{/.test(body) && !/\}\}[.!]?\s*$/.test(body), t.name);
    assert(!/\p{Extended_Pictographic}/u.test(body), t.name);
    assertEquals(t.components.find((c) => c.type === "FOOTER")?.text, "Tapio");
  }
});

// ---------------- tervetuloviesti
function inboundDeps(store: StoreResult, welcome: { send: boolean; body: string | null } | null) {
  const sent: Array<{ to: string; body: string }> = [];
  const outbound: unknown[] = [];
  let welcomeCalls = 0;
  const deps: InboundDeps = {
    store: () => Promise.resolve(store),
    act: () => Promise.resolve({ replyBody: null, buttons: [], shiftId: null, suppressed: false }),
    send: (to, body) => { sent.push({ to, body }); return Promise.resolve({ ok: true, wamid: "wamid.W" }); },
    markHandled: () => Promise.resolve(),
    storeOutbound: (r) => { outbound.push(r); return Promise.resolve(); },
    log: () => {},
  };
  if (welcome) deps.welcome = () => { welcomeCalls += 1; return Promise.resolve(welcome); };
  return { deps, sent, outbound, calls: () => welcomeCalls };
}
const INBOUND = { wamid: "wamid.IN", from: "358401234567", type: "text", text: "moi", buttonId: null, at: null };
const STORED: StoreResult = { id: "m1", duplicate: false, handled: false, inboundEnabled: false, staffId: STAFF, replyTo: "+358401234567" };

Deno.test("tervetulo: tietokannan päätös lähetetään vapaamuotoisena ja tallennetaan", async () => {
  const t = inboundDeps(STORED, { send: true, body: "Hei Hilma. ... –Tapio" });
  await processInboundMessage(INBOUND, t.deps);
  assertEquals(t.sent, [{ to: "+358401234567", body: "Hei Hilma. ... –Tapio" }]);
  assertEquals(t.outbound.length, 1);
});

Deno.test("tervetulo: asetus pois / jo lähetetty → ei viestiä; tuntematon numero → ei edes kysytä", async () => {
  const off = inboundDeps(STORED, { send: false, body: null });
  await processInboundMessage(INBOUND, off.deps);
  assertEquals(off.sent.length, 0);
  const unknown = inboundDeps({ ...STORED, staffId: null }, { send: true, body: "x" });
  await processInboundMessage(INBOUND, unknown.deps);
  assertEquals([unknown.sent.length, unknown.calls()], [0, 0]);
  const dup = inboundDeps({ ...STORED, duplicate: true }, { send: true, body: "x" });
  await processInboundMessage(INBOUND, dup.deps);
  assertEquals([dup.sent.length, dup.calls()], [0, 0]);
});

// ---------------- oma sivu
function pageDb(result: Record<string, unknown>) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const db: MyPageDb = { rpc: (name, args) => { calls.push({ name, args }); return Promise.resolve({ data: result, error: null }); } };
  return { db, calls };
}

Deno.test("oma sivu: reitit ja tokenin muoto", () => {
  assertEquals(myRoute("GET", "/shift-offer-engine/api/my"), "my");
  assertEquals(myRoute("POST", "/shift-offer-engine/api/my/respond"), "my_respond");
  assertEquals(myRoute("POST", "/shift-offer-engine/api/my"), "invalid");
  assertEquals(myRoute("GET", "/shift-offer-engine/api/offers"), null);
  assert(validStaffToken(PAGE_TOKEN));
  assert(!validStaffToken("payload.sig") && !validStaffToken("") && !validStaffToken(null) && !validStaffToken(PAGE_TOKEN + "<"));
});

Deno.test("oma sivu: huono token ei kutsu tietokantaa; noindex ja no-store", async () => {
  const t = pageDb({ ok: true });
  const bad = await handleMyPageRequest(new Request("https://x/functions/v1/shift-offer-engine/api/my?token=abc"), t.db);
  assertEquals([bad.status, t.calls.length], [400, 0]);
  const good = await handleMyPageRequest(new Request(`https://x/functions/v1/shift-offer-engine/api/my?token=${PAGE_TOKEN}`), t.db);
  assertEquals(good.status, 200);
  assertEquals(good.headers.get("x-robots-tag"), "noindex, nofollow");
  assertEquals(good.headers.get("cache-control"), "no-store");
  assertEquals(t.calls[0], { name: "shift_staff_page", args: { p_token: PAGE_TOKEN } });
});

Deno.test("oma sivu: tietokannan bad_token → 400; vastaus välittää vain sallitut arvot", async () => {
  const t = pageDb({ ok: false, error: "bad_token" });
  const res = await handleMyPageRequest(new Request(`https://x/api/my?token=${PAGE_TOKEN}`), t.db);
  assertEquals(res.status, 400);
  const r = pageDb({ result: "accepted", page: { ok: true } });
  const bad = await handleMyPageRequest(new Request("https://x/api/my/respond", { method: "POST", body: JSON.stringify({ token: PAGE_TOKEN, offer_id: "x", response: "accept" }) }), r.db);
  assertEquals([bad.status, r.calls.length], [400, 0]);
  const ok = await handleMyPageRequest(new Request("https://x/api/my/respond", {
    method: "POST",
    body: JSON.stringify({ token: PAGE_TOKEN, offer_id: "11111111-2222-4333-8444-555555555555", response: "decline" }),
  }), r.db);
  assertEquals(ok.status, 200);
  assertEquals(r.calls[0].name, "shift_staff_page_respond");
  assertEquals(r.calls[0].args.p_response, "decline");
});
