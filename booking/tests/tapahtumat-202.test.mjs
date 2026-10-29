// booking_202: migraation rakenne (ei tietokantaa). Käyttäytyminen: booking/supabase/tests/t202_event_admin.sql.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const mig = readFileSync(join(root, 'booking/supabase/migrations/20261028183000_booking_202_event_admin.sql'), 'utf8');

test('booking_202 on 201:n jälkeen eikä koske hintoihin tai kassaan', () => {
  assert.match(mig, /booking_202/);
  assert.doesNotMatch(mig.replace(/--[^\n]*/g, ''), /update\s+kb\.products\s+set\s+(price|vat)/i);
  assert.doesNotMatch(mig, /public_create_booking|public_checkout/);
  assert.match(mig, /cancelled_at/);
  assert.match(mig, /event_participant_notes/);
  assert.match(mig, /event_messages/);
  assert.match(mig, /enable row level security/);
  assert.match(mig, /revoke all on booking\.event_participant_notes from public, anon, authenticated/);
  assert.match(mig, /_require_staff\(\)/);
  assert.match(mig, /_require_permission\('messages\.edit'\)/);
  assert.match(mig, /_require_permission\('catalog\.edit'\)/);
  assert.match(mig, /admin_event_occurrence_cancel/);
  assert.match(mig, /_enqueue_email\('event_message'/);
  assert.match(mig, /event_message/);
  assert.match(mig, /moved_bookings/);
  assert.match(mig, /_event_message_blocked/);
  assert.match(mig, /provider_name/);
});

test('osallistujavastaus ei sisällä maksuvälittäjää eikä sisäisiä osoitekenttiä', () => {
  const fn = mig.slice(mig.indexOf('function booking.admin_event_participants'), mig.indexOf('function booking.admin_event_participant_note_set'));
  assert.match(fn, /'email', c\.email/);
  assert.match(fn, /'payment_status', o\.payment_status/);
  assert.match(fn, /customer_note/);
  assert.match(fn, /staff_note/);
  assert.doesNotMatch(fn, /payments|provider|billing|address|marketing_consent/);
});

test('siirto menneisyyteen estetään palvelimella ja käyttöliittymässä (Joonas 29.10.)', async () => {
  assert.match(mig, /perform booking\._err\('past_move'/);
  assert.match(mig, /at time zone booking\._tz\(\)\) <= now\(\)/);
  const { isPastMove } = await import(join(root, 'booking/admin/events-logic.js'));
  const now = new Date('2026-10-29T10:00:00Z'); // Helsinki 12:00
  assert.equal(isPastMove({ date: '2026-11-13', start_time: '17:00' }, { date: '2026-10-28', start_time: '17:00' }, now), true);
  assert.equal(isPastMove({ date: '2026-11-13', start_time: '17:00' }, { date: '2026-10-29', start_time: '11:59' }, now), true);
  assert.equal(isPastMove({ date: '2026-11-13', start_time: '17:00' }, { date: '2026-10-29', start_time: '12:01' }, now), false);
  assert.equal(isPastMove({ date: '2026-10-01', start_time: '17:00:00' }, { date: '2026-10-01', start_time: '17:00' }, now), false, 'ennallaan oleva mennyt kerta saa muuttaa muuta');
  const view = readFileSync(join(root, 'booking/admin/views/events.js'), 'utf8');
  assert.match(view, /isPastMove\(\{ date: r\.date/);
  assert.match(view, /'past_move'/);
});

test('esikatselu ei tuplaa tervehdystä (sama sääntö kuin sähköpostipohjassa)', async () => {
  const { customerMessageText } = await import(join(root, 'booking/admin/events-logic.js'));
  assert.match(customerMessageText({ subject: 'a', body: 'Hei kaikki!\nTervetuloa' }).text, /^Hei kaikki!\nTervetuloa/);
  assert.match(customerMessageText({ subject: 'a', body: 'Heinäkuussa nähdään' }).text, /^Hei,\n\nHeinäkuussa/);
  assert.match(customerMessageText({ subject: 'a', body: 'Hello all,\nsee you', lang: 'en' }).text, /^Hello all,\nsee you/);
});
