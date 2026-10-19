// Varauskalenterin vienti: tekstit, tunnisteet ja mock. Ei Googlea, ei tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const texts = await import(pathToFileURL(join(root, 'admin/calendar-export-texts.js')));
const logic = await import(pathToFileURL(join(root, 'admin/calendar-export-logic.js')));
const pending = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-25.json'), 'utf8'));
const fallback = JSON.parse(readFileSync(join(repo, 'content/site-texts.fallback.json'), 'utf8'));
const settings = readFileSync(join(root, 'admin/views/settings.js'), 'utf8');
const view = readFileSync(join(root, 'admin/views/calendar-export.js'), 'utf8');
const migration = readFileSync(join(root, 'supabase/migrations/20261019161000_booking_114_calendar_export.sql'), 'utf8');
const ci = readFileSync(join(repo, '.github/workflows/pages.yml'), 'utf8');

test('sanakirja, pending-import-25 ja varateksti täsmäävät', () => {
  const fb = fallback.texts;
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(texts.CALENDAR_EXPORT_TEXTS[lang])) {
      const row = pending.find((r) => r.key === key && r.lang === lang);
      assert.ok(row, key + ' ' + lang);
      assert.equal(row.text, text);
      assert.equal(row.class, 'normal');
      assert.equal(row.kind, 'plain');
      assert.deepEqual(row.placeholders, []);
      assert.equal(row.text.includes('http'), false);
      assert.equal(row.text.includes('@'), false);
      const fbRow = fb.find((r) => r.key === key && r.lang === lang);
      assert.ok(fbRow, 'fallback ' + key);
      assert.equal(fbRow.text, text);
      assert.deepEqual(fbRow.placeholders, []);
    }
  }
  assert.equal(new Set(pending.map((r) => r.key + '|' + r.lang)).size, pending.length);
  assert.equal(pending.length, Object.keys(texts.CALENDAR_EXPORT_TEXTS.fi).length * 2);
  assert.equal(pending.some((r) => r.key.startsWith('ui.admin.calendar_export.') && r.lang === 'fi' && r.lang === 'en'), false);
});

test('tunniste: sähköpostimuoto ja lyhyt tunnus, tyhjä sallitaan, väli ei', () => {
  assert.equal(logic.calendarIdError(''), null);
  assert.equal(logic.calendarIdError('  '), null);
  assert.equal(logic.calendarIdError('varaukset-t114@group.calendar.google.com'), null);
  assert.equal(logic.calendarIdError('savu-t114-cal'), null);
  assert.equal(logic.calendarIdError('lyhyt'), 'invalid_calendar');
  assert.equal(logic.calendarIdError('on väli'), 'invalid_calendar');
  const payload = logic.collectCalendarSettings({
    mode: 'dry_run', timezone: 'Europe/Helsinki', window_back_days: '7', window_forward_days: '180',
    shared_calendar_id: ' savu-t114-cal ', admin_base_url: '', fast_nudge: false,
    resource_calendars: { savusauna: '', rauni: 'rauni-t114-cal' },
  });
  assert.equal(payload.shared_calendar_id, 'savu-t114-cal');
  assert.deepEqual(payload.resource_calendars, { rauni: 'rauni-t114-cal' });
  assert.equal(logic.firstCalendarError(payload), null);
  assert.equal(logic.firstCalendarError({ ...payload, shared_calendar_id: 'huono tunnus' }), 'invalid_calendar');
});

test('mock: oletus pois, sulku ja salaisuus hylätään, esikatselu ei lähetä', async () => {
  const { createAdminMock } = await import(pathToFileURL(join(root, 'admin/options-mock.js')));
  const mock = createAdminMock({ role: 'manager' });
  const cur = await mock.rpc('admin_get_booking_calendar');
  assert.equal(cur.mode, 'off');
  assert.equal(cur.shared_calendar_id, '');
  await assert.rejects(() => mock.rpc('admin_set_booking_calendar', { p: { mode: 'dry_run', api_key: 'ei' } }), (e) => e.code === 'secrets_not_allowed');
  await assert.rejects(() => mock.rpc('admin_set_booking_calendar', { p: { shared_calendar_id: 'sulku-test@group.calendar.google.com' } }), (e) => e.code === 'closure_calendar');
  await assert.rejects(() => mock.rpc('admin_set_booking_calendar', { p: { shared_calendar_id: 'on väli' } }), (e) => e.code === 'invalid_calendar');
  const kept = await mock.rpc('admin_get_booking_calendar');
  assert.equal(kept.mode, 'off');
  assert.equal(kept.shared_calendar_id, '');
  const saved = await mock.rpc('admin_set_booking_calendar', { p: { mode: 'dry_run', shared_calendar_id: 'varaukset-t114@group.calendar.google.com', resource_calendars: { savusauna: 'savu-t114-cal' }, fast_nudge: false } });
  assert.equal(saved.mode, 'dry_run');
  assert.equal(saved.resources.find((r) => r.code === 'savusauna').calendar_id, 'savu-t114-cal');
  const preview = await mock.rpc('admin_booking_calendar_preview');
  assert.equal(preview.sent, false);
  const staff = createAdminMock({ role: 'staff', perms: ['bookings.manage'] });
  await assert.rejects(() => staff.rpc('admin_get_booking_calendar'), (e) => e.code === 'forbidden');
});

test('asetusnäkymä käyttää tekstifunktiota ja RPC:tä, vienti on oletuksena pois', () => {
  assert.match(settings, /loadCalendarExportTexts/);
  assert.match(settings, /renderCalendarExport/);
  assert.match(settings, /admin_get_booking_calendar/);
  assert.match(settings, /tab === 'varaukset'/);
  assert.equal(settings.includes('Varauskalenteri'), false);
  assert.match(view, /admin_set_booking_calendar/);
  assert.match(view, /admin_booking_calendar_preview/);
  assert.match(view, /calendarExportText/);
  assert.equal(view.includes('Harjoitusajo'), false);
  assert.match(migration, /mode', 'off'/);
  assert.match(migration, /booking.skip_cron/);
  assert.match(migration, /closure_calendar/);
  assert.match(migration, /booking-calendar-sync/);
  assert.match(ci, /booking_calendar_sync_test\.ts/);
  assert.match(ci, /varauskalenteri\.test\.mjs/);
});
