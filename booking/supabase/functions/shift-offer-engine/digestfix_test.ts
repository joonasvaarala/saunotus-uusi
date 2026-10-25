// digestfix #3 (20261025171500_day_digest_fixes): päivän kooste (day_digest) noudattaa tarjouksen sääntöä (soefix B4/C1):
// hyväksymätön day_digest-pohja → sähköposti heti, myös hiljaisina tunteina ja vaikka 24 h -ikkuna olisi auki.
// Hyväksytty pohja → odottaa aamuun kuten tarjous. Ei verkkoa: fetch heittää virheen.
// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/digestfix_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handleClaimedMessage, planMessage, resolveTemplate, type ClaimedMessage, type Settings, type TemplateSettings, type WhatsappEnv } from "./whatsapp.ts";

const STAFF = "aaaaaaaa-0000-4000-8000-0000000000d1";
const NOW = Date.parse("2026-10-25T20:30:00.000Z"); // 22.30 Helsinki
const ENV: WhatsappEnv = { token: "t", phoneNumberId: "123456", appSecret: "s", verifyToken: "v" };
const PAGE_TOKEN = "eyJwIjoiYWFhYWFhYWEtMDAwMC00MDAwIiwibiI6IngifQ.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";
const PROD_TPL: TemplateSettings = {
  offer: { name: "tyovuoro_kysely", approved: false },
  round_reminder: { name: "tyovuoro_muistutus", approved: false },
  already_taken: { name: "tyovuoro_jo_mennyt", approved: false },
  day_digest: { name: "tyovuoro_paivan_kooste", approved: false },
};
const DIGEST_OK: TemplateSettings = { ...PROD_TPL, day_digest: { name: "tyovuoro_paivan_kooste", approved: true } };
const noFetch = (() => { throw new Error("Meta-kutsu ei sallittu"); }) as typeof fetch;

function digest(over: Partial<ClaimedMessage> = {}): ClaimedMessage {
  return {
    id: 21, kind: "alert", channel: "whatsapp", staff_id: STAFF, attempts: 0, wamid: null, status: "sending",
    phone_raw: "040 765 4321", email: "kooste@example.test", role_type: "heater",
    starts_at: "2026-11-27T08:00:00.000Z", ends_at: "2026-11-27T12:00:00.000Z", deadline_at: null,
    ask_no: null, ask_count: null, token: "payload.sig", staff_whatsapp_enabled: true, bot_channel: false,
    subkind: "day_digest", page_token: PAGE_TOKEN, session_open: true,
    body: "Hei Dora.\nSinulle on useampi vuoroasia 27.11.2026: x; y.\nVastaa omalla sivullasi: https://example.test/?token=abc\n\n–Tapio",
    digest: { date_label: "27.11.2026", items: "Lämmitys x; Lämmitys y" }, ...over,
  };
}
function settings(over: Partial<Settings> = {}): Settings {
  return { sender_enabled: true, whatsapp_enabled: true, whatsapp_dry_run: false, allow_staff_ids: [STAFF], templates: PROD_TPL, ...over };
}

Deno.test("digestfix #3: hyväksymätön day_digest-pohja = unapproved (kuten tarjous), myös ilman pohja-asetuksia", () => {
  assertEquals(resolveTemplate(digest(), PROD_TPL), { kind: "unapproved" });
  assertEquals(resolveTemplate(digest(), undefined), { kind: "unapproved" });
  assertEquals(resolveTemplate(digest(), { ...PROD_TPL, day_digest: { name: "Huono Nimi", approved: true } }), { kind: "unapproved" });
  const ok = resolveTemplate(digest(), DIGEST_OK);
  assert(ok.kind === "template" && ok.name === "tyovuoro_paivan_kooste" && ok.buttonToken === PAGE_TOKEN);
});

Deno.test("digestfix #3: yöllä hyväksymätön kooste → sähköposti heti (delay 0), ei quiet_hours-odotusta, ei vapaamuotoista", () => {
  const night = planMessage(digest(), settings({ whatsapp_hours_open: false }));
  assert(night.action === "release");
  assertEquals([night.reason, night.channel, night.to, night.delayMinutes], ["template_not_approved", "email", "kooste@example.test", 0]);
  // päivällä ja 24 h -ikkuna auki: silti sähköposti (tarjouksen B4-sääntö), ei session-viestiä
  const day = planMessage(digest(), settings({ whatsapp_hours_open: true }));
  assert(day.action === "release");
  assertEquals([day.reason, day.channel, day.delayMinutes], ["template_not_approved", "email", 0]);
  // ilman sähköpostia → no_working_channel kuten tarjous
  const none = planMessage(digest({ email: null }), settings({ whatsapp_hours_open: false }));
  assert(none.action === "fail_no_contact" && none.error === "no_working_channel");
});

Deno.test("digestfix #3: yöllä hyväksytty kooste odottaa aamuun (quiet_hours), kuten hyväksytty tarjous", async () => {
  const p = planMessage(digest(), settings({ whatsapp_hours_open: false, templates: DIGEST_OK }));
  assert(p.action === "release" && p.reason === "quiet_hours" && p.channel === "whatsapp");
  const r = await handleClaimedMessage(digest(), settings({ whatsapp_hours_open: false }), ENV, noFetch, () => {}, NOW);
  assertEquals([r.action, r.channel, r.to, r.error], ["release", "email", "kooste@example.test", "template_not_approved"]);
});
