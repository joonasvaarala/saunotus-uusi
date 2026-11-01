// Asetussivun kortit: tarkistus, mock-tallennus ja tekstit. Ei verkkoa eikä tietokantaa.
// SQL: booking/supabase/tests/talous/t123_settings_ui.sql (Bottiavustus ajaa).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createAdminMock } from '../admin/options-mock.js';
import { applySection, exampleBundle, ibanOk, modeBadgeKind, modeTextKey, overviewNotices, validateSection } from '../admin/settings-logic.js';
import { SETTINGS_TEXTS } from '../admin/settings-texts.js';

const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');
const pending31 = JSON.parse(read('../../content/site-texts.pending-import-31.json'));
const pending109 = JSON.parse(read('../../content/site-texts.pending-import-109.json'));
const older = ['12', '16', '24', '29'].flatMap((n) => JSON.parse(read(`../../content/site-texts.pending-import-${n}.json`)));

const seller = () => {
  const { logo_url, ...rest } = exampleBundle().settings.seller;
  return rest;
};

test('yritys, rajat, käteinen ja tuntematon osio', () => {
  const ok = validateSection('business', { business_name: 'Sipoonjoen Perinnesauna', seller: seller() });
  assert.equal(ok.ok, true);
  assert.equal(ok.value.seller.business_id, '3018112-1');
  assert.equal('logo_url' in ok.value.seller, false);
  const badId = validateSection('business', { business_name: 'Sipoonjoen Perinnesauna', seller: { ...seller(), business_id: '3018112-2' } });
  assert.equal(badId.ok, false);
  assert.equal(badId.code, 'invalid_value');
  const sneaky = validateSection('pause', { public_booking_enabled: false, public_payment_mode: 'hold_until_paid' });
  assert.equal(sneaky.ok, false);
  const cash = validateSection('payment_methods', { methods: { card_terminal: true, cash: true } });
  assert.equal(cash.code, 'cash_not_accepted');
  const mail = validateSection('email_sender', { from_name: 'Sauna', reply_to: 'savusauna@saunotus.fi', test_recipients: [] });
  assert.equal(mail.ok, false);
  assert.equal(validateSection('vismapay', { mode: 'live' }).code, 'unknown_section');
  assert.equal(validateSection('booking_group', { checkout_group_threshold_persons: 101, checkout_group_hold_days: 7, annual_card_max_persons: 1 }).ok, false);
  assert.equal(validateSection('booking_group', { checkout_group_threshold_persons: 0, checkout_group_hold_days: 7, annual_card_max_persons: 1 }).ok, true);
  assert.equal(ibanOk('FI21 1234 5600 0007 85'), 'FI2112345600000785');
  assert.equal(ibanOk(''), '');
  assert.equal(ibanOk('FI00'), null);
});

test('mock säilyttää logon, synkkaa pidon eikä koske live-tilaan', async () => {
  const mock = createAdminMock({ role: 'manager' });
  const before = await mock.rpc('admin_settings_bundle');
  assert.equal(before.qr_only, false);
  assert.equal(before.montonio.mode, 'off');
  assert.equal(before.vismapay, undefined);
  assert.equal(before.mobilepay, undefined);
  assert.equal(before.resend.allowlist_on, true);
  assert.equal(before.resend.allowlist_count, 2);
  before.settings.seller.logo_url = 'https://example.test/logo.png';
  mock.state.settingsUi.settings.seller.logo_url = 'https://example.test/logo.png';
  await mock.rpc('admin_save_settings', { p_section: 'business', p: { business_name: 'Sipoonjoen Perinnesauna', seller: seller() } });
  const saved = await mock.rpc('admin_settings_bundle');
  assert.equal(saved.settings.seller.logo_url, 'https://example.test/logo.png');
  assert.equal(saved.settings.seller.footer, 'Kiitos käynnistä!');
  await mock.rpc('admin_save_settings', { p_section: 'payment_hold', p: { checkout_hold_minutes: 20, checkout_mobilepay_grace_minutes: 10, checkout_mobilepay_max_wait_minutes: 25 } });
  assert.equal(mock.state.settingsUi.settings.hold_minutes, 20);
  assert.equal(mock.state.settingsUi.settings.checkout_hold_minutes, 20);
  await assert.rejects(() => mock.rpc('admin_save_settings', { p_section: 'technical', p: { limits: { rl_ip_per_10min: 12 } } }), (e) => e.code === 'forbidden');
  await assert.rejects(() => mock.rpc('admin_save_settings', { p_section: 'payment_methods', p: { methods: { cash: true, card_terminal: true } } }), (e) => e.code === 'cash_not_accepted');
  const admin = createAdminMock({ role: 'admin' });
  await admin.rpc('admin_save_settings', { p_section: 'technical', p: { limits: { rl_ip_per_10min: 13 } } });
  assert.equal(admin.state.settingsUi.settings.rl_ip_per_10min, 13);
  const staff = createAdminMock({ role: 'staff', perms: ['pos.use'] });
  const qr = await staff.rpc('admin_settings_bundle');
  assert.equal(qr.qr_only, true);
  assert.equal(qr.settings, undefined);
  const state = exampleBundle();
  state.montonio.mode = 'test';
  state.vismapay = { mode: 'test' };
  state.mobilepay = { mode: 'test' };
  state.resend.mode = 'live';
  state.resend.allowlist_on = false;
  assert.deepEqual(overviewNotices(state), ['warn_pay_test']);
  state.montonio.mode = 'live';
  assert.deepEqual(overviewNotices(state), ['warn_pay_live']);
  assert.equal(modeBadgeKind('live'), 'ok');
  assert.equal(modeTextKey('live'), 'mode_live');
  applySection(state, 'email_sender', { from_name: 'Perinnesauna', reply_to: 'savusauna@saunotus.fi' });
  assert.equal(state.resend.from, 'Perinnesauna <savusauna@saunotus.fi>');
  assert.equal(state.resend.mode, 'live');
  assert.equal(state.resend.allowlist_on, false);
});

test('pending-import-31: uudet asetustekstit, FI+EN, ei päällekkäin', () => {
  const taken = new Set(older.map((r) => `${r.key}|${r.lang}`));
  const seen = new Set();
  assert.ok(pending31.length >= 2);
  assert.equal(pending31.length % 2, 0);
  for (const row of pending31) {
    assert.match(row.key, /^ui\.admin\.settings\.[a-z0-9_]+$/);
    assert.ok(row.lang === 'fi' || row.lang === 'en');
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.equal(row.text.trim(), row.text);
    assert.ok(row.max_len >= row.text.length);
    assert.equal(row.text.includes('{{'), false);
    assert.equal(/https?:|www\./i.test(row.text), false);
    assert.equal(taken.has(`${row.key}|${row.lang}`), false);
    assert.equal(seen.has(`${row.key}|${row.lang}`), false);
    seen.add(`${row.key}|${row.lang}`);
    const newer = pending109.find((r) => r.key === row.key && r.lang === row.lang);
    const live = SETTINGS_TEXTS[row.lang][row.key];
    if (newer) assert.equal(live, newer.text);
    else if (live !== undefined) assert.equal(live, row.text);
  }
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(SETTINGS_TEXTS[lang])) {
      if (!key.startsWith('ui.admin.settings.') && !key.startsWith('ui.admin.qr.')) continue;
      const row = pending109.find((r) => r.key === key && r.lang === lang) || pending31.find((r) => r.key === key && r.lang === lang) || older.find((r) => r.key === key && r.lang === lang);
      assert.ok(row, key + ' ' + lang);
      assert.equal(row.text, text);
    }
  }
});

test('pending-import-109: päivitetyt asetustekstit, FI+EN', () => {
  const seen = new Set();
  assert.equal(pending109.length, 6);
  assert.equal(pending109.length % 2, 0);
  for (const row of pending109) {
    assert.match(row.key, /^ui\.admin\.settings\.[a-z0-9_]+$/);
    assert.ok(row.lang === 'fi' || row.lang === 'en');
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.equal(row.text.trim(), row.text);
    assert.ok(row.max_len >= row.text.length);
    assert.equal(SETTINGS_TEXTS[row.lang][row.key], row.text);
    assert.equal(seen.has(`${row.key}|${row.lang}`), false);
    seen.add(`${row.key}|${row.lang}`);
  }
  assert.equal(SETTINGS_TEXTS.fi['ui.admin.settings.warn_allowlist_open'], undefined);
});

test('migraatio ei poista avaimia eikä kirjoita live-tilaa', () => {
  const sql = read('../supabase/migrations/20261021175349_booking_123_settings_ui.sql');
  const rb = read('../supabase/rollbacks/20261021175349_booking_123_ROLLBACK.sql');
  assert.match(sql, /admin_settings_bundle/);
  assert.match(sql, /admin_save_settings/);
  assert.match(sql, /current_staff_role\(\) is distinct from 'admin'/);
  assert.match(sql, /cash_not_accepted/);
  assert.match(sql, /hold_minutes/);
  assert.equal(/delete\s+from\s+booking\.settings/i.test(sql), false);
  assert.equal(/admin_set_vismapay_mode/.test(sql), false);
  assert.equal(/admin_set_procountor_settings/.test(sql), false);
  assert.match(rb, /drop function if exists booking\.admin_save_settings/);
  const sql225 = read('../supabase/migrations/20261101081500_booking_225_settings_montonio.sql');
  assert.match(sql225, /'montonio', jsonb_build_object\('mode'/);
  assert.equal(/'vismapay'/.test(sql225), false);
  assert.equal(/'mobilepay'/.test(sql225), false);
  assert.equal(/update\s+booking\.integration_config/i.test(sql225), false);
  assert.equal(/insert\s+into\s+booking\.integration_config/i.test(sql225), false);
  assert.equal(/delete\s+from\s+booking\.integration_config/i.test(sql225), false);
  assert.match(sql225, /grant execute on function booking\.admin_settings_bundle\(\) to authenticated, service_role/);
  const view = read('../admin/views/settings.js');
  assert.equal(view.includes('bundle.vismapay'), false);
  assert.equal(view.includes('bundle.mobilepay'), false);
  assert.equal(view.includes('warn_allowlist_open'), false);
  assert.match(view, /bundle\.montonio\?\.mode/);
  assert.match(read('../../.github/workflows/pages.yml'), /node --test booking\/tests\/asetukset\.test\.mjs/);
  assert.match(read('../../.github/workflows/pages.yml'), /t123 \(booking\/supabase\/tests\/talous\/t123_settings_ui\.sql\)/);
});
