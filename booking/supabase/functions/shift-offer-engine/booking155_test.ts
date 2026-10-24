// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/booking155_test.ts
// booking_155: tyovuoro_kysely-pohjan muuttujat Metan live-tekstiin sopiviksi. Ei verkkoa.
import { assert, assertEquals } from "jsr:@std/assert@1";
import templates from "../../../../docs/whatsapp-templates.json" with { type: "json" };
import { formatDeadlineShort, formatShiftWhenShort, resolveTemplate, roleShort, type ClaimedMessage } from "./whatsapp.ts";

const LIVE = "Hei, työvuoroon tarvitaan tekijää. Vuoro: {{1}}, aika {{2}}. Voitko tulla töihin? Vastaathan viimeistään {{3}} mennessä alla olevasta painikkeesta.";
const NOW = Date.parse("2026-10-24T12:00:00Z");

Deno.test("lyhyet muodot: rooli, aika ja vastausaika", () => {
  assertEquals([roleShort("heater"), roleShort("reception"), roleShort("therapist"), roleShort(null)], ["Lämmitys", "Vastaanotto", "Hoitaja", "Työvuoro"]);
  assertEquals(formatShiftWhenShort("2026-10-31T10:00:00Z", "2026-10-31T16:00:00Z", NOW), "la 31.10. klo 12–18");
  assertEquals(formatShiftWhenShort("2026-11-07T08:30:00Z", "2026-11-07T12:45:00Z", NOW), "la 7.11. klo 10.30–14.45");
  assertEquals(formatShiftWhenShort("2027-01-02T10:00:00Z", null, NOW), "la 2.1.2027 klo 12");
  assertEquals(formatDeadlineShort("2026-10-29T10:00:00Z", NOW), "to 29.10. klo 12");
  assertEquals(formatDeadlineShort(null, NOW), "pian");
});

Deno.test("live-teksti luetaan luontevasti, kun pohja on hyväksytty", () => {
  const m = {
    id: 1, kind: "offer", channel: "whatsapp", staff_id: "s", attempts: 0, wamid: null, status: "sending", phone_raw: "0401234567", email: null,
    role_type: "heater", starts_at: "2026-10-31T10:00:00Z", ends_at: "2026-10-31T16:00:00Z", deadline_at: "2026-10-29T10:00:00Z",
    ask_no: null, ask_count: null, token: "tok.sig", staff_whatsapp_enabled: true, bot_channel: false,
  } as ClaimedMessage;
  const c = resolveTemplate(m, { offer: { name: "tyovuoro_kysely", approved: true, fallback: "vuorotarjous" } });
  assert(c.kind === "template");
  assertEquals(c.name, "tyovuoro_kysely");
  assertEquals(c.params[0], "Lämmitys");
  const text = LIVE.replace("{{1}}", c.params[0]).replace("{{2}}", c.params[1]).replace("{{3}}", c.params[2]);
  assert(/^Hei, työvuoroon tarvitaan tekijää\. Vuoro: Lämmitys, aika la 31\.10\.(2026)? klo 12–18\. Voitko tulla töihin\? Vastaathan viimeistään to 29\.10\.(2026)? klo 12 mennessä/.test(text), text);
  // varapohja vuorotarjous pitää vanhat muodot
  const f = resolveTemplate(m, { offer: { name: "tyovuoro_kysely", approved: false, fallback: "vuorotarjous" } });
  assert(f.kind === "template");
  assertEquals(f.name, "vuorotarjous");
  assertEquals(f.params[0], "lämmitysvuoro");
});

Deno.test("docs/whatsapp-templates.json: tyovuoro_kysely = Metan live-teksti sellaisenaan", () => {
  const t = (templates as { booking_153_templates: Array<{ name: string; components: Array<{ type: string; text?: string }> }> }).booking_153_templates
    .find((x) => x.name === "tyovuoro_kysely");
  assertEquals(t?.components.find((c) => c.type === "BODY")?.text, LIVE);
});
