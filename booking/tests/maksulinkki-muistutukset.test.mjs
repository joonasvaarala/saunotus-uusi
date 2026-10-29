// booking_215: maksulinkkien muistutukset ja Seurattavat maksut -näkymä.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveAdminPath, navGroupById, visibleGroupTabs } from '../admin/admin-navigation.js';
import { NAV_TEXTS } from '../admin/nav-texts.js';
import { PW_TEXTS } from '../admin/paylink-watch-texts.js';
import { createAdminMock } from '../admin/options-mock.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');

test('navigaatio: Seurattavat maksut on Kassa ja talous -välilehti, oikeus payments.manage', () => {
  assert.equal(NAV_TEXTS.fi['ui.admin.nav.paylink_watch'], 'Seurattavat maksut');
  assert.equal(NAV_TEXTS.en['ui.admin.nav.paylink_watch'], 'Payments to follow');
  assert.deepEqual(resolveAdminPath('seurattavat-maksut'), { path: 'kassa', legacyReservations: false, groupId: 'cash', tabId: 'seurattavat' });
  const cash = navGroupById('cash');
  const can = (list) => (p) => list.includes(p);
  assert.deepEqual(visibleGroupTabs(cash, can(['payments.manage'])).map((t) => t.id), ['talous', 'seurattavat']);
  assert.deepEqual(visibleGroupTabs(cash, can(['giftcards.manage'])).map((t) => t.id), ['talous']);
  assert.equal(visibleGroupTabs(cash, can(['payments.manage'])).find((t) => t.id === 'seurattavat').view, 'paylink-watch');
  assert.match(src('admin/views/paylink-watch.js'), /data-testid': 'paylink-watch'/);
  assert.match(src('admin/views/paylink-watch.js'), /admin_payment_link_mark_handled|markHandled/);
  assert.doesNotMatch(src('admin/views/paylink-watch.js'), /montonio/i);
});

test('tuontitiedosto 102: FI+EN, ei päällekkäin, sähköposti ja näkymä', () => {
  const rows = JSON.parse(src('../content/site-texts.pending-import-102.json'));
  const taken = new Set();
  for (const f of readdirSync(join(root, '../content'))) {
    if (!/^site-texts\.pending-import-(?!102\.)/.test(f) || !f.endsWith('.json')) continue;
    const j = JSON.parse(readFileSync(join(root, '../content', f), 'utf8'));
    for (const r of Array.isArray(j) ? j : []) taken.add(`${r.key}|${r.lang}`);
  }
  const seen = new Set();
  for (const r of rows) {
    assert.equal(seen.has(`${r.key}|${r.lang}`), false, r.key);
    seen.add(`${r.key}|${r.lang}`);
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, `${r.key} on jo toisessa tuonnissa`);
    assert.ok(r.text.length <= r.max_len, r.key);
    assert.equal(r.class, 'normal');
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{(?:var|setting):[a-z0-9_]+\}\}/g)].map((m) => m[0]));
  }
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(PW_TEXTS[lang])) {
      const row = rows.find((r) => r.key === key && r.lang === lang);
      assert.equal(row?.text, text, key);
    }
  }
  assert.equal(rows.find((r) => r.key === 'email.payment_link_reminder.pay_button' && r.lang === 'fi').text, 'Maksa verkossa');
  assert.equal(rows.find((r) => r.key === 'email.payment_link_reminder.pay_button' && r.lang === 'en').text, 'Pay online');
  assert.equal(rows.find((r) => r.key === 'ui.admin.nav.paylink_watch' && r.lang === 'fi').text, 'Seurattavat maksut');
});

test('migraatio ei kytke cronia eikä lähetystä; PROD-ajo on erillisessä tiedostossa', () => {
  const sql = src('supabase/migrations/20261029170000_booking_215_payment_link_reminders.sql');
  const rollback = src('supabase/rollbacks/20261029170000_booking_215_ROLLBACK.sql');
  const prod = src('supabase/manual/booking_215_payment_link_reminders_cron.sql');
  assert.match(sql, /payment_link\.reminders_enabled', 'false'/);
  assert.match(sql, /payment_link\.remind_prepaid_after_hours', '72'/);
  assert.match(sql, /payment_link\.remind_before_expiry_hours', '24'/);
  assert.match(sql, /payment_link\.remind_onsite_interval_hours', '72'/);
  assert.match(sql, /payment_link\.remind_onsite_max', '4'/);
  assert.match(sql, /payment_link\.remind_window', '"10-18"'/);
  assert.match(sql, /if not booking\._plr_enabled\(\) then/);
  assert.match(sql, /to_regnamespace\('cron'\) is null/);
  assert.match(sql, /booking_payment_link_reminders/);
  assert.match(sql, /payment_link_reminder:/);
  assert.doesNotMatch(sql, /provider\s*=\s*'montonio'/);
  assert.match(rollback, /email_outbox_claim_base_215/);
  assert.match(rollback, /cron\.unschedule\('booking_payment_link_reminders'\)/);
  assert.match(prod, /Älä aja DEV/);
  assert.match(prod, /'true'::jsonb/);
  assert.match(prod, /\*\/15 \* \* \* \*/);
  assert.match(src('supabase/tests/talous/t215_payment_link_reminders.sql'), /TESTRESULT/);
});

test('kokeilutila: kolme linkkiä, vaatii toimenpiteitä, toiminnot', async () => {
  const mock = createAdminMock({ delay: 0 });
  const list = await mock.rpc('admin_list_payment_link_watch', {});
  assert.equal(list.total, 3);
  const hot = list.rows.find((r) => r.status === 'needs_action');
  assert.equal(hot.customer_name, 'Mikko Mäkinen');
  assert.equal(hot.reminder_count, 4);
  assert.equal(hot.link_expires_at, null);
  assert.equal(list.rows.find((r) => r.status === 'watching').link_kind, 'prepaid');
  await mock.rpc('admin_payment_link_pause_reminders', { p_payment_id: 9101 });
  const paused = (await mock.rpc('admin_list_payment_link_watch', { p_status: 'paused' })).rows;
  assert.ok(paused.some((r) => r.payment_id === 9101));
  const handled = await mock.rpc('admin_payment_link_mark_handled', { p_payment_id: 9102, p_method: 'card_terminal', p_note: 'testi' });
  assert.equal(handled.handled, true);
  assert.equal(handled.receipt_no, '2026-000901');
  assert.equal((await mock.rpc('admin_list_payment_link_watch', {})).total, 2);
  const staff = createAdminMock({ delay: 0, perms: ['bookings.manage'] });
  await assert.rejects(() => staff.rpc('admin_list_payment_link_watch', {}), (e) => e.code === 'forbidden');
});
