// booking-calendar-sync ilman Googlea ja ilman verkkoa.
// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/booking-calendar-sync/core_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { planOps, type DesiredEvent, type ExportPlan } from "./core.ts";

const CAL = "varaukset-test@group.calendar.google.com";
const SHIFT = "vuoro-test@group.calendar.google.com";

function ev(over: Partial<DesiredEvent> = {}): DesiredEvent {
  return {
    event_key: "s:yleinen_arki:2027-01-05T16:00",
    kind: "shift",
    reservation_id: null,
    resource_code: "savusauna",
    google_calendar_id: CAL,
    google_event_id: "bksabcdef0123456789abcd",
    summary: "Naisten sauna 16–19 · 2 hlö (1 varaus)",
    description: "2 hlö, 1 varaus",
    starts_at: "2027-01-05T14:00:00.000Z",
    ends_at: "2027-01-05T17:00:00.000Z",
    content_hash: "shift",
    timezone: "Europe/Helsinki",
    ...over,
  };
}

Deno.test("planOps ohittaa vuorokalenterin eikä kirjoita sinne", () => {
  const onShift = ev({ google_calendar_id: SHIFT });
  const plan: ExportPlan = {
    mode: "live",
    closure_calendar_ids: [],
    shift_calendar_ids: [SHIFT],
    events: [onShift, ev()],
    mapped: [
      { event_key: "d:2027-01-09", google_calendar_id: SHIFT, google_event_id: "bkd20270109" },
      { event_key: "w:2027-01-09", google_calendar_id: CAL, google_event_id: "bkw20270109", content_hash: "old" },
    ],
  };
  const { ops, blocked } = planOps(plan);
  assertEquals(blocked, 2);
  assert(!ops.some((o) => o.calendarId === SHIFT));
  assert(ops.some((o) => o.op === "insert" && o.eventKey === "s:yleinen_arki:2027-01-05T16:00" && o.calendarId === CAL));
  assert(ops.some((o) => o.op === "delete" && o.eventKey === "w:2027-01-09" && o.calendarId === CAL));
  assertEquals(ops.filter((o) => o.eventKey === "d:2027-01-09").length, 0);
});
