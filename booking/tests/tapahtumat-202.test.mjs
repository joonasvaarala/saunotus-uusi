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
