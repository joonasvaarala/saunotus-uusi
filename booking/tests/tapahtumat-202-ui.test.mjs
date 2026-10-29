// booking_202: tapahtumahallinnan puhdas logiikka (toisto, tila, CSV, viestin esikatselu) ja mock.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createEventsMock } from '../admin/events-mock.js';
import { buildSeries, repeatDates, occurrenceFlags, participantsToCsv, messageDraft, customerMessageText, weekdayIso } from '../admin/events-logic.js';

test('viikkotoisto: valitut viikonpäivät until-päivään, yhdistyy käsin valittuihin', () => {
  assert.equal(weekdayIso('2026-11-16'), 1);
  const rep = repeatDates({ from: '2026-11-16', until: '2026-11-29', weekdays: [1, 3] });
  assert.equal(rep.ok, true);
  assert.deepEqual(rep.dates, ['2026-11-16', '2026-11-18', '2026-11-23', '2026-11-25']);
  assert.equal(repeatDates({ from: '2026-11-20', until: '2026-11-16', weekdays: [1] }).error, 'bad_range');
  assert.equal(repeatDates({ from: '2026-11-16', until: '2026-11-20', weekdays: [] }).error, 'no_weekdays');
  const series = buildSeries({ dates: ['2026-11-14'], times: ['17:00', '19:00'], repeat: { from: '2026-11-16', until: '2026-11-16', weekdays: [1] }, duration_minutes: 90, max_persons: 8 });
  assert.equal(series.ok, true);
  assert.deepEqual(series.patches.map((p) => `${p.date} ${p.start_time}`), ['2026-11-14 17:00', '2026-11-14 19:00', '2026-11-16 17:00', '2026-11-16 19:00']);
});

test('kerran tila: myynnissä, täynnä, peruttu, myynti suljettu', () => {
  const base = { starts_at: '2026-12-01T15:00:00.000Z', ends_at: '2026-12-01T18:00:00.000Z', active: true, sold_persons: 2, max_persons: 10, deadline_minutes: 0 };
  const now = Date.parse('2026-11-01T12:00:00.000Z');
  assert.equal(occurrenceFlags(base, { saleEnabled: true, now }).status, 'on_sale');
  assert.equal(occurrenceFlags({ ...base, sold_persons: 10 }, { saleEnabled: true, now }).status, 'full');
  assert.equal(occurrenceFlags({ ...base, cancelled_at: '2026-10-01T00:00:00Z', active: false }, { saleEnabled: true, now }).status, 'cancelled');
  assert.equal(occurrenceFlags(base, { saleEnabled: false, now }).status, 'sales_closed');
  assert.equal(occurrenceFlags({ ...base, sold_persons: 10 }, { saleEnabled: false, now }).full, true);
  assert.equal(occurrenceFlags({ ...base, ends_at: '2026-10-01T18:00:00.000Z' }, { saleEnabled: true, now }).status, 'past');
});

test('CSV: BOM, puolipiste, kaavainjektio; viestissä ei automaattista allekirjoitusta (booking_213), hylkää välittäjän nimen', () => {
  const csv = participantsToCsv([{ occurrence: 'Ilta', name: '=Maija', email: 'a@b.fi', phone: '040', persons: 2, order_status: 'Vahvistettu', payment_status: 'Maksettu', booked_at: '1.11.2026', extra: 'Valinta: hunaja', note: 'ovi' }],
    ['kerta', 'nimi', 'sposti', 'puh', 'hlot', 'tila', 'maksu', 'varattu', 'lisa', 'muistio']);
  assert.ok(csv.startsWith('\uFEFF'));
  assert.match(csv, /kerta;nimi;sposti/);
  assert.match(csv, /'=Maija/);
  assert.ok(csv.includes('\r\n'));
  assert.equal(messageDraft({ subject: 'Hei', body: 'Maksu Montonio' }).error, 'provider_name');
  const msg = customerMessageText({ subject: 'Ilta', body: 'Ota pyyhe.', eventName: 'Joulusauna', whenText: '14.11.2026 17:00', lang: 'fi' });
  assert.equal(msg.ok, true);
  assert.match(msg.text, /^Hei,\n\nOta pyyhe\.\n\nTapahtuma: Joulusauna\nAika: 14\.11\.2026 17:00\n$/);
  assert.equal(msg.signature, null);
  assert.doesNotMatch(msg.text, /Tapio|Ystävällisin terveisin/);
  assert.doesNotMatch(msg.text, /montonio|visma|mobilepay/i);
});

test('mock: osallistujat, muistiinpano, peruutus, viestin vahvistus', () => {
  const m = createEventsMock({ today: '2026-10-28' });
  const ev = m.handlers.admin_event_list({ p_include_past: true }).find((p) => p.product_id === 31);
  const evening = ev.rules.find((r) => r.sold_persons === 4 || r.reservation_count === 2);
  const people = m.handlers.admin_event_participants({ p_product_id: 31, p_rule_id: evening.id });
  assert.ok(people.length >= 1);
  assert.equal(people.some((p) => p.email && p.name), true);
  assert.equal('provider' in people[0], false);
  const note = m.handlers.admin_event_participant_note_set({ p_reservation_id: people[0].reservation_id, p_note: 'Tarkista pyyhe' });
  assert.equal(note.note, 'Tarkista pyyhe');
  const preview = m.handlers.admin_event_message_send({ p_product_id: 31, p_rule_id: evening.id, p_subject: 'Muistutus', p_body: 'Nähdään illalla.', p_confirm: false });
  assert.equal(preview.sent, undefined);
  assert.ok(preview.recipient_count >= 1);
  assert.equal(m.handlers.admin_event_messages_list({ p_product_id: 31 }).length, 1);
  const sent = m.handlers.admin_event_message_send({ p_product_id: 31, p_rule_id: null, p_subject: 'Muistutus', p_body: 'Nähdään illalla.', p_confirm: true });
  assert.equal(sent.sent, true);
  assert.equal(m.handlers.admin_event_messages_list({ p_product_id: 31 }).length, 2);
  assert.throws(() => m.handlers.admin_event_message_send({ p_product_id: 31, p_rule_id: null, p_subject: 'X', p_body: 'visma', p_confirm: true }), (e) => e.code === 'provider_name');
  const cancelled = m.handlers.admin_event_occurrence_cancel({ p_id: evening.id });
  assert.ok(cancelled.cancelled_at);
  assert.equal(cancelled.active, false);
  assert.throws(() => m.handlers.admin_event_rule_delete({ p_id: evening.id }), (e) => e.code === 'has_reservations');
});
