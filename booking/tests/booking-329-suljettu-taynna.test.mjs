// booking_329 (backlog 86, Joonas t1843u/t1844u): meidän oma käsisulku yleisellä vuorolla näkyy asiakkaalle "Täynnä"
// (status 'full', remaining 0) ja vuoroon voi liittyä jonoon; sulun avaus/poisto/siirto lähettää jonoilmoituksen (triggeri).
// Migraatio = PRODin schema_migrations-teksti tavu-identtisenä; rollback palauttaa booking_291-määrittelyn (= booking_328-tila).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { visibleWaitlistSlots, fullyBooked, hasWaitlistSlots, waitlistParty } from "../shop/src/waitlist-logic.js";
import { buildWeek } from "../shop/src/week-grid-logic.js";

const root = new URL("../supabase/", import.meta.url);
const V = "20261121031432";
const md5 = (b) => createHash("md5").update(b).digest("hex");
const migRaw = readFileSync(new URL(`migrations/${V}_booking_329_space_block_waitlist.sql`, root));
const rbRaw = readFileSync(new URL(`rollbacks/${V}_booking_329_ROLLBACK.sql`, root));
const mig = migRaw.toString("utf8");
const rb = rbRaw.toString("utf8");
const m291 = readFileSync(new URL("migrations/20261113101830_booking_291_rule_closure_exempt_student_treatments.sql", root), "utf8");
const fnOf = (s) => { const i = s.indexOf("CREATE OR REPLACE FUNCTION booking._sessions("); const j = s.indexOf("$function$", s.indexOf("$function$", i) + 10); return i < 0 || j < 0 ? "" : s.slice(i, j + 10); };

test("migraatio = PRODin booking_329 (md5)", () => {
  assert.equal(md5(migRaw), "f1c3d59b0fb2355e0d99a46202ffb195");
});

test("migraatio: oma käsisulku → yleinen vuoro full/0, tapahtuma- ja kalenterisulut ennallaan; triggeri", () => {
  assert.match(mig, /and not \(c\.mode <> 'exclusive' and b\.closure_event_id is null and b\.event_block_id is null\)\) then 'unavailable'/);
  assert.match(mig, /mb\.closure_event_id is null and mb\.event_block_id is null\)\s*then 'full'/);
  assert.match(mig, /then 0 else least\(/);
  assert.match(mig, /create trigger space_blocks_zz_waitlist after update or delete on booking\.space_blocks\s+for each row execute function booking\._space_blocks_waitlist_trg\(\)/i);
  assert.match(mig, /_notify_waitlist_for_window/);
  assert.doesNotMatch(mig, /\bpublic\./, "ei koske public-skeemaan");
});

test("rollback: md5-vahti, triggeri ja funktio pois, _sessions = booking_291-määrittely", () => {
  assert.match(rb, /<> '9fba454852769a41afdd3a183e460298'/);
  assert.match(rb, /drop trigger if exists space_blocks_zz_waitlist on booking\.space_blocks;/);
  assert.match(rb, /drop function if exists booking\._space_blocks_waitlist_trg\(\);/);
  const f = fnOf(rb);
  assert.ok(f.length > 3000);
  assert.equal(f, fnOf(m291), "palautus = booking_291:n _sessions tavu tavulta");
  assert.doesNotMatch(f, /booking_329/);
  assert.match(rb, /^begin;/m);
  assert.match(rb, /^commit;/m);
  // 329-versio eroaa vain 329-lisäysten osalta
  const f329 = fnOf(mig);
  assert.ok(f329.includes("booking_329") && f329 !== f);
});

// UI: sama käsittely kuin kapasiteetiltaan täydellä vuorolla.
const sess = (status, remaining, extra = {}) => ({ rule_id: 135, product_id: 1, session_date: "2026-12-28", mode: "shared", status, remaining, min_persons: 1, max_persons: 6,
  starts_at: "2026-12-28T13:00:00Z", ends_at: "2026-12-28T15:00:00Z", ...extra });

test("varaussivu: suljettu yleinen vuoro (full, 0) näkyy jonotettavana, unavailable piilossa", () => {
  const closed = sess("full", 0);
  const rows = [closed, sess("unavailable", 0, { rule_id: 1 })];
  assert.deepEqual(visibleWaitlistSlots(rows).map((r) => r.rule_id), [135], "full näkyy, unavailable ei");
  assert.equal(hasWaitlistSlots(rows), true);
  assert.equal(fullyBooked(rows), true, "päivä = Täynnä → Liity jonoon");
  // remaining 0 ei riko henkilömäärävalitsinta: jonon määrä tulee vuoron min/max:sta, ei remainingista
  assert.deepEqual(waitlistParty(closed, { category: "public_sauna" }), { kind: "general", min: 1, max: 6 });
});

test("viikko-ohjelma: suljettu yleinen vuoro (full, 0) = Täynnä kuten kapasiteetiltaan täysi", () => {
  const cat = [{ id: 1, slug: "yleinensauna", name: "Yleinen vuoro", category: "public_sauna" }];
  const r = { ...sess("full", 0), slug: "yleinensauna", category: "public_sauna", unit_price: 35, base_price: null };
  const args = { start: "2026-12-28", today: "2026-12-28", now: Date.parse("2026-12-28T06:00:00Z"), catalog: cat, care: [], events: [], offers: [], lang: "fi",
    hrefs: { product: (s, d) => `/varaa/#/tuote/${s}/${d}`, day: (d) => `/varaa/#/paiva/${d}` } };
  const closed = buildWeek({ ...args, rows: [r] }).days.find((d) => d.date === "2026-12-28");
  const cap = buildWeek({ ...args, rows: [{ ...r, remaining: 0 }] }).days.find((d) => d.date === "2026-12-28");
  assert.equal(closed.public.length, 1, "vuoro ei katoa");
  assert.equal(closed.public[0].full, true);
  assert.deepEqual(closed.public, cap.public);
  const gone = buildWeek({ ...args, rows: [{ ...r, status: "unavailable" }] }).days.find((d) => d.date === "2026-12-28");
  assert.equal(gone.public.length, 0, "unavailable (esim. tapahtumasulku) ei näy");
});
