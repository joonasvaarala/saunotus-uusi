// Päivän tuotto ja tapahtumat (hallinnan päivänäkymä, booking_68). Puhdas logiikka, ei verkkoa eikä tietokantaa.
// SQL-testi (botti): booking/supabase/tests/day/t68_day_revenue_events.sql. Sääntö: docs/paivanakyma-tuotto.md
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { summarizeRevenue, revenueView, eventsOnDay, eventTimeLabel, eventSortIso, assignDayCards, canSeeDayRevenue, clockIso, helsinkiDate, effectiveStatus } from '../admin/day-logic.js';
import { createAdminMock } from '../admin/options-mock.js';
import { DAY_TEXTS, fillDayText, dayText, loadDayTexts, clearDayTextCache } from '../admin/day-texts.js';

const DAY = '2026-10-20';
const NEXT = '2026-10-21';
const at = (day, hm) => clockIso(day, hm.slice(0, 2), hm.slice(3, 5));
const row = (over) => ({
  reservation_id: 1, starts_at: at(DAY, '17:00'), status: 'confirmed', hold_expires_at: null,
  line_gross: 58, line_vat: 11.79, line_net: 46.21, payment_status: 'paid', hidden: false,
  order_created_at: '2020-01-15T10:00:00.000Z', ...over,
});

test('Helsinki-päivä ja kello (kesäaika +3)', () => {
  assert.equal(helsinkiDate(at(DAY, '00:30')), DAY);
  assert.equal(helsinkiDate('2026-10-19T22:00:00.000Z'), DAY, '22:00Z on jo 20.10. Helsingissä');
  assert.equal(helsinkiDate('2026-10-20T21:30:00.000Z'), NEXT, '21:30Z on jo seuraava päivä');
  assert.equal(clockIso(DAY, 16, 0), '2026-10-20T13:00:00.000Z');
  assert.equal(clockIso('2026-01-20', 16, 0), '2026-01-20T14:00:00.000Z', 'talviaika +2');
});

test('tuotto: peruttu, vanhentunut ja no_show pois; vahvistettu ja toteutunut mukana', () => {
  const now = new Date('2026-10-20T12:00:00.000Z');
  const rows = [
    row({ reservation_id: 1, line_gross: 58, status: 'confirmed' }),
    row({ reservation_id: 2, line_gross: 40, status: 'cancelled' }),
    row({ reservation_id: 3, line_gross: 18, status: 'expired' }),
    row({ reservation_id: 4, line_gross: 29, status: 'no_show' }),
    row({ reservation_id: 5, line_gross: 10, status: 'completed' }),
    row({ reservation_id: 6, line_gross: 99, status: 'pending', hold_expires_at: '2026-10-20T08:00:00.000Z' }),
    row({ reservation_id: 7, line_gross: 7, status: 'confirmed', hidden: true }),
  ];
  assert.equal(effectiveStatus(rows[5], now), 'expired');
  const s = summarizeRevenue(rows, DAY, now);
  assert.equal(s.gross, 68);
  assert.equal(s.count, 2);
  assert.equal(s.pending_count, 0);
  assert.equal(s.basis, 'visit_start');
  assert.equal(s.vat_basis, 'gross_incl_vat');
});

test('tuotto: lahjakortilla maksettu lasketaan rivin arvona, ei nollana', () => {
  const s = summarizeRevenue([row({ line_gross: 59, line_vat: 12, line_net: 47, payment_status: 'paid', gift_card: true })], DAY);
  assert.equal(s.gross, 59);
  assert.equal(s.vat, 12);
  assert.equal(s.net, 47);
  assert.equal(s.unpaid_count, 0);
});

test('tuotto: lisäpalvelu on rivin bruttossa; maksamaton vahvistettu on mukana ja merkitty', () => {
  const s = summarizeRevenue([
    row({ reservation_id: 1, line_gross: 71, payment_status: 'paid' }),
    row({ reservation_id: 2, line_gross: 29, payment_status: 'unpaid' }),
  ], DAY);
  assert.equal(s.gross, 100);
  assert.equal(s.unpaid_gross, 29);
  assert.equal(s.unpaid_count, 1);
});

test('tuotto: voimassa oleva pito on erikseen, ei bruttossa', () => {
  const now = new Date('2026-10-20T12:00:00.000Z');
  const s = summarizeRevenue([
    row({ line_gross: 29, status: 'pending', hold_expires_at: '2026-10-20T12:30:00.000Z', payment_status: 'unpaid' }),
  ], DAY, now);
  assert.equal(s.gross, 0);
  assert.equal(s.count, 0);
  assert.equal(s.pending_gross, 29);
  assert.equal(s.pending_count, 1);
  assert.equal(s.unpaid_count, 0, 'odottava ei ole maksamaton-osajoukkoa');
});

test('tuotto: toisen päivän käynti ei vaikuta, vaikka tilaus olisi luotu tälle päivälle', () => {
  const today = summarizeRevenue([
    row({ reservation_id: 1, starts_at: at(NEXT, '17:00'), order_created_at: at(DAY, '09:00'), line_gross: 200 }),
    row({ reservation_id: 2, starts_at: at(DAY, '16:00'), order_created_at: '2020-01-15T10:00:00.000Z', line_gross: 35 }),
  ], DAY);
  assert.equal(today.gross, 35);
  assert.equal(today.count, 1);
  const next = summarizeRevenue([
    row({ starts_at: at(NEXT, '17:00'), order_created_at: at(DAY, '09:00'), line_gross: 200 }),
  ], NEXT);
  assert.equal(next.gross, 200);
});

test('tuotto: sentit eivät karkaa (10,10 + 20,20)', () => {
  const s = summarizeRevenue([
    row({ reservation_id: 1, line_gross: 10.1, line_vat: 2.05, line_net: 8.05 }),
    row({ reservation_id: 2, line_gross: 20.2, line_vat: 4.1, line_net: 16.1 }),
  ], DAY);
  assert.equal(s.gross, 30.3);
  assert.equal(s.vat, 6.15);
  assert.equal(s.net, 24.15);
});

test('näkymä: puuttuva funktio ei ole nolla euroa; tyhjä päivä on', () => {
  assert.equal(revenueView(null, DAY).available, false);
  assert.equal(revenueView({}, DAY).available, false);
  const empty = revenueView({ revenue_rows: [] }, DAY);
  assert.equal(empty.available, true);
  assert.equal(empty.gross, 0);
  assert.equal(empty.showPending, false);
  assert.equal(empty.showUnpaid, false);
  const marked = revenueView({ revenue_rows: [row({ status: 'pending', hold_expires_at: '2099-01-01T00:00:00.000Z', line_gross: 5, payment_status: 'unpaid' })] }, DAY, new Date('2026-10-20T12:00:00.000Z'));
  assert.equal(marked.showPending, true);
  assert.equal(marked.gross, 0);
});

test('tapahtumat: tyhjä päivä, useita samana päivänä, väärä päivä pois, monen päivän väli', () => {
  const events = [
    { event_id: 1, product_id: 9, starts_on: DAY, time_text: 'klo 18–20', active: true, participants: [] },
    { event_id: 2, product_id: 32, starts_on: DAY, time_text: null, active: true, participants: [] },
    { event_id: 3, product_id: 33, starts_on: NEXT, ends_on: '2026-10-22', active: true, participants: [{ reservation_id: 9, status: 'completed', persons: 1, starts_at: at(NEXT, '10:00'), ends_at: at(NEXT, '12:00') }] },
    { event_id: 4, product_id: 34, starts_on: '2026-10-01', ends_on: '2026-10-02', active: true },
    { event_id: 5, product_id: 35, starts_on: DAY, active: false },
  ];
  assert.deepEqual(eventsOnDay(events, DAY).map((e) => e.event_id), [1, 2]);
  assert.deepEqual(eventsOnDay(events, NEXT).map((e) => e.event_id), [3]);
  assert.deepEqual(eventsOnDay(events, '2026-10-22').map((e) => e.event_id), [3]);
  assert.deepEqual(eventsOnDay(events, '2026-10-23'), []);
  assert.deepEqual(eventsOnDay([], DAY), []);
  assert.deepEqual(eventsOnDay(null, DAY), []);
});

test('aikajana: tapahtuman osallistuja ei toistu slotissa; tyhjä päivä; useita tapahtumia', () => {
  const session = { product_id: 3, starts_at: at(DAY, '16:00'), ends_at: at(DAY, '19:00'), status: 'available', mode: 'shared' };
  const sauna = { reservation_id: 1, product_id: 3, starts_at: session.starts_at, status: 'confirmed', persons: 2 };
  const guest = { reservation_id: 2, product_id: 9, starts_at: at(DAY, '18:00'), status: 'completed', persons: 2, customer_name: 'Meeri' };
  const cancelled = { reservation_id: 3, product_id: 9, starts_at: at(DAY, '18:00'), status: 'cancelled', persons: 1 };
  const adhoc = { reservation_id: 4, product_id: 11, starts_at: at(DAY, '12:00'), ends_at: at(DAY, '14:00'), status: 'confirmed', persons: 1 };
  const events = [
    { event_id: 1, product_id: 9, starts_on: DAY, time_text: 'klo 18–20', participants: [guest, cancelled] },
    { event_id: 2, product_id: 32, starts_on: DAY, time_text: 'klo 16–19 (saunotus alkaa klo 17)', participants: [] },
  ];
  const plan = assignDayCards({ sessions: [session], reservations: [sauna, guest, cancelled, adhoc], events, date: DAY });
  assert.equal(plan.empty, false);
  assert.equal(plan.sessions.length, 1);
  assert.deepEqual(plan.sessions[0].reservations.map((r) => r.reservation_id), [1]);
  assert.equal(plan.events.length, 2);
  assert.deepEqual(plan.events[0].participants.map((p) => p.reservation_id), [2], 'peruttu ei ole kortilla');
  assert.equal(plan.events[1].participants.length, 0);
  assert.deepEqual(plan.slots.map((g) => g.map((r) => r.reservation_id)), [[4]], 'ilman tapahtumapäivää varaus jää slotiksi');
  assert.equal(assignDayCards({ sessions: [], reservations: [], events: [], date: DAY }).empty, true);
  assert.equal(assignDayCards({ sessions: [{ ...session, status: 'closed' }], reservations: [], events: [], date: DAY }).empty, true, 'myymätön suljettu vuoro pysyy piilossa');
});

test('sama alkuaika, eri loppu: varaus vain oikeassa vuorokortissa', () => {
  const day = '2026-11-13';
  const start = clockIso(day, 14, 0);
  const endShort = clockIso(day, 16, 0);
  const endLong = clockIso(day, 21, 0);
  const short = { rule_id: 18, product_id: 25, label: 'Oma savusaunavuoro pe 14–16', starts_at: start, ends_at: endShort, status: 'unavailable', mode: 'exclusive' };
  const long = { rule_id: 16, product_id: 25, label: 'Oma savusaunavuoro pe 14–21', starts_at: start, ends_at: endLong, status: 'unavailable', mode: 'exclusive' };
  const res = {
    reservation_id: 10331, product_id: '25', order_no: 13280, status: 'confirmed', persons: 4,
    starts_at: new Date(start).toISOString().replace('Z', '+00:00'),
    ends_at: new Date(endShort).toISOString().replace('Z', '+00:00'),
  };
  const plan = assignDayCards({ sessions: [long, short], reservations: [res], events: [], date: day });
  assert.deepEqual(plan.sessions.map((c) => c.session.rule_id), [18]);
  assert.deepEqual(plan.sessions[0].reservations.map((r) => r.reservation_id), [10331]);
  assert.equal(plan.slots.length, 0, 'varaus ei jää myös slotiksi');
  assert.equal(plan.sessions.some((c) => c.session.rule_id === 16), false, 'tyhjä unavailable 14–21 ei näy varattuna');

  const byRule = assignDayCards({
    sessions: [long, short],
    reservations: [{ ...res, rule_id: '18', ends_at: endLong }],
    events: [],
    date: day,
  });
  assert.deepEqual(byRule.sessions.map((c) => c.session.rule_id), [18], 'rule_id voittaa ristiriitaisen loppuajan');
  assert.equal(byRule.slots.length, 0);

  const loose = assignDayCards({
    sessions: [long, short],
    reservations: [{ ...res, rule_id: null, ends_at: clockIso(day, 15, 0) }],
    events: [],
    date: day,
  });
  assert.deepEqual(loose.sessions.map((c) => c.session.rule_id), [18], 'ilman tarkkaa osumaa lyhin vuoro');
  assert.equal(loose.slots.length, 0);

  const guest = { reservation_id: 77, product_id: 25, starts_at: start, ends_at: endShort, status: 'confirmed', persons: 1 };
  const withEvent = assignDayCards({
    sessions: [long, short],
    reservations: [res, guest],
    events: [{ event_id: 1, product_id: 25, starts_on: day, time_text: 'klo 14–16', participants: [guest] }],
    date: day,
  });
  assert.deepEqual(withEvent.sessions.flatMap((c) => c.reservations.map((r) => r.reservation_id)), [10331]);
  assert.equal(withEvent.slots.length, 0);
  assert.deepEqual(withEvent.events[0].participants.map((p) => p.reservation_id), [77]);
});

test('kelloteksti järjestää tapahtuman; ilman kelloa loppuun', () => {
  const ev = { time_text: 'klo 16–19 (saunotus alkaa klo 17)', participants: [] };
  assert.equal(eventTimeLabel(ev).kind, 'text');
  assert.equal(eventSortIso(ev, DAY), clockIso(DAY, 16, 0));
  const bare = { time_text: '', participants: [{ starts_at: at(DAY, '11:00'), ends_at: at(DAY, '13:00') }] };
  assert.equal(eventTimeLabel(bare).kind, 'range');
  assert.equal(eventSortIso(bare, DAY), at(DAY, '11:00'));
  assert.equal(eventTimeLabel({ time_text: null, participants: [] }).kind, 'all_day');
  assert.equal(eventSortIso({ participants: [] }, DAY), null);
});

test('tekstit: FI ja EN, paikkamerkit, tuontitiedosto vastaa sanakirjaa', () => {
  assert.deepEqual(Object.keys(DAY_TEXTS.fi).sort(), Object.keys(DAY_TEXTS.en).sort());
  for (const key of Object.keys(DAY_TEXTS.fi)) {
    assert.ok(DAY_TEXTS.fi[key].length > 0 && DAY_TEXTS.en[key].length > 0, key);
    assert.match(key, /^[a-z0-9_]+(\.[a-z0-9_-]+)+$/);
  }
  assert.equal(fillDayText(DAY_TEXTS.fi['ui.admin.day.revenue_pending'], { amount: '29,00 €' }), 'Vahvistamatta 29,00 €');
  assert.equal(fillDayText(DAY_TEXTS.en['ui.admin.day.revenue_unpaid'], { amount: '€10.00' }), 'Of which unpaid €10.00');
  const pending = JSON.parse(readFileSync(new URL('../../content/site-texts.imported-pr68.json', import.meta.url), 'utf8'));
  const keys = new Set(Object.keys(DAY_TEXTS.fi));
  const fallback = JSON.parse(readFileSync(new URL('../../content/site-texts.fallback.json', import.meta.url), 'utf8'));
  const live = (fallback.texts || []).filter((r) => keys.has(r.key));
  assert.equal(live.length, keys.size * 2);
  for (const row of live) assert.equal(row.text, DAY_TEXTS[row.lang][row.key]);
  assert.equal(pending.length, keys.size * 2);
  for (const row of pending) {
    assert.ok(keys.has(row.key), row.key);
    assert.ok(row.lang === 'fi' || row.lang === 'en');
    assert.equal(row.text, DAY_TEXTS[row.lang][row.key]);
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    const found = [...row.text.matchAll(/\{\{[^}]+\}\}/g)].map((m) => m[0]);
    assert.deepEqual(found, row.placeholders);
    for (const ph of found) assert.match(ph, /^\{\{[a-z_]+:[A-Za-z0-9_]+\}\}$/);
  }
  const byKey = new Map();
  for (const row of pending) byKey.set(row.key, (byKey.get(row.key) || 0) + 1);
  for (const n of byKey.values()) assert.equal(n, 2);
});

test('migraatio on vain luku ja noudattaa samaa sääntöä', () => {
  const sql = readFileSync(new URL('../supabase/migrations/20261018165354_booking_68_admin_day_extras.sql', import.meta.url), 'utf8');
  const rollback = readFileSync(new URL('../supabase/rollbacks/20261018165354_booking_68_ROLLBACK.sql', import.meta.url), 'utf8');
  assert.match(sql, /create or replace function booking\.admin_day_extras\(p_date date\)/);
  assert.match(sql, /r\.starts_at >= v_from/);
  assert.match(sql, /r\.starts_at < v_to/);
  assert.match(sql, /hidden_at is null/);
  assert.match(sql, /line_total_gross/);
  assert.match(sql, /parent_item_id/);
  assert.match(sql, /'confirmed', 'completed'/);
  assert.match(sql, /no_show|eff in \('confirmed', 'completed'\)/);
  assert.match(sql, /kb\.event_dates/);
  assert.match(sql, /coalesce\(e\.ends_on, e\.starts_on\)/);
  assert.doesNotMatch(sql, /booking\.payments/);
  assert.doesNotMatch(sql, /o\.created_at\s*>=/);
  assert.doesNotMatch(sql, /alter table/i);
  assert.doesNotMatch(sql, /create table/i);
  assert.match(rollback, /drop function if exists booking\.admin_day_extras\(date\)/);
  const ui = readFileSync(new URL('../admin/views/day.js', import.meta.url), 'utf8');
  assert.match(ui, /revenueView\(/);
  assert.match(ui, /assignDayCards\(/);
  assert.match(ui, /rule_id: ruleId/);
  assert.match(ui, /data-testid': 'day-revenue'/);
  assert.match(ui, /data-testid': 'event'/);
  assert.match(ui, /admin_day_extras/);
  assert.match(ui, /loadDayTexts\(rpc\)/);
  assert.match(ui, /canSeeDayRevenue\(ctx\.role\)/);
  assert.match(ui, /seeMoney \? loadRevenue\(date\) : null/);
  const sql69 = readFileSync(new URL('../supabase/migrations/20261018171000_booking_69_day_revenue_role.sql', import.meta.url), 'utf8');
  const rb69 = readFileSync(new URL('../supabase/rollbacks/20261018171000_booking_69_ROLLBACK.sql', import.meta.url), 'utf8');
  assert.match(sql69, /create or replace function booking\.admin_day_revenue\(p_date date\)/);
  assert.match(sql69, /current_staff_role\(\) not in \('admin', 'manager'\)/);
  assert.match(sql69, /current_staff_role\(\) in \('admin', 'manager'\)/);
  assert.match(sql69, /revoke all on function booking\.admin_day_revenue\(date\) from public, anon, authenticated/);
  assert.doesNotMatch(sql69, /alter table|create table/i);
  assert.match(rb69, /drop function if exists booking\.admin_day_revenue\(date\)/);
  assert.match(rb69, /create or replace function booking\.admin_day_extras\(p_date date\)/);
  const t69 = readFileSync(new URL('../supabase/tests/day/t69_day_revenue_role.sql', import.meta.url), 'utf8');
  assert.match(t69, /t69-staff@example\.test', 'staff'/);
  assert.match(t69, /admin_day_revenue/);
  assert.doesNotMatch(t69, /^\s*set\s+(local\s+)?(lock_timeout|statement_timeout)/im);
  const helpers = readFileSync(new URL('../supabase/tests/fixtures/10_test_helpers.sql', import.meta.url), 'utf8');
  const t68 = readFileSync(new URL('../supabase/tests/day/t68_day_revenue_events.sql', import.meta.url), 'utf8');
  assert.match(helpers, /function test\.mk_user/);
  assert.doesNotMatch(helpers, /on conflict \(email\)/i);
  assert.match(t68, /42501/);
  assert.match(t68, /HHT68TEST001/);
  assert.doesNotMatch(t68, /^\s*set\s+(local\s+)?(lock_timeout|statement_timeout)/im);
});

test('tuotto vain admin ja manager; työntekijä ei saa lukuja eikä erillistä pyyntöä onnistu', async () => {
  assert.equal(canSeeDayRevenue('admin'), true);
  assert.equal(canSeeDayRevenue('manager'), true);
  assert.equal(canSeeDayRevenue('staff'), false);
  assert.equal(canSeeDayRevenue('text_editor'), false);
  assert.equal(canSeeDayRevenue(null), false);
  const staff = createAdminMock({ role: 'staff' });
  const extras = await staff.rpc('admin_day_extras', { p_date: '2035-06-07' });
  assert.equal(extras.revenue, null);
  assert.equal(extras.revenue_rows, null);
  assert.ok(Array.isArray(extras.events));
  await assert.rejects(() => staff.rpc('admin_day_revenue', { p_date: '2035-06-07' }), (e) => e.code === 'forbidden');
  assert.equal(staff.state.calls.some((c) => c.name === 'admin_day_revenue'), true);
  const mgr = createAdminMock({ role: 'manager' });
  const rev = await mgr.rpc('admin_day_revenue', { p_date: '2035-06-07' });
  assert.equal(rev.revenue.gross, 0);
  assert.ok(Array.isArray(rev.revenue_rows));
  const adm = await createAdminMock({ role: 'admin' }).rpc('admin_day_revenue', { p_date: '2035-06-07' });
  assert.equal(adm.revenue.currency, 'EUR');
});

test('päivän tekstit: site_texts peittää sanakirjan, puuttuva tai täyttymätön rivi jää varalle', async () => {
  clearDayTextCache();
  assert.equal(dayText('ui.admin.day.revenue_title', null, 'fi'), 'Päivän tuotto');
  const rpc = async (name) => {
    assert.equal(name, 'public_get_site_texts');
    return { ok: true, texts: [
      { key: 'ui.admin.day.revenue_title', lang: 'fi', text: 'Tuotto (DB)' },
      { key: 'ui.admin.day.revenue_pending', lang: 'fi', text: 'Avoinna {{var:amount}}' },
      { key: 'ui.admin.day.revenue_unpaid', lang: 'fi', text: 'Rikki {{price:1}}' },
      { key: 'ui.other', lang: 'fi', text: 'ei kuulu' },
    ] };
  };
  assert.equal(await loadDayTexts(rpc), true);
  assert.equal(dayText('ui.admin.day.revenue_title', null, 'fi'), 'Tuotto (DB)');
  assert.equal(dayText('ui.admin.day.revenue_title', null, 'en'), "Day's revenue");
  assert.equal(dayText('ui.admin.day.revenue_pending', { amount: '2 €' }, 'fi'), 'Avoinna 2 €');
  assert.equal(dayText('ui.admin.day.revenue_unpaid', { amount: '1 €' }, 'fi'), 'Josta maksamatta 1 €');
  assert.equal(dayText('ui.admin.day.revenue_vat', null, 'fi'), 'sis. alv');
  assert.equal(await loadDayTexts(async () => { throw new Error('verkko'); }), true);
  clearDayTextCache();
  assert.equal(await loadDayTexts(async () => { throw new Error('verkko'); }), false);
  assert.equal(dayText('ui.admin.day.revenue_title', null, 'fi'), 'Päivän tuotto');
});
