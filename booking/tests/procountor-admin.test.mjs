// Procountor-asetuskortin tekstit: sanakirja ja pending-import täsmäävät, näkymä ei kovakoodaa uusia lauseita.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const texts = await import(pathToFileURL(join(root, 'admin/procountor-texts.js')));
const imported = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-11.json'), 'utf8'));
const pending = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-15.json'), 'utf8'));
const settings = readFileSync(join(root, 'admin/views/settings.js'), 'utf8');
const migration = readFileSync(join(root, 'supabase/migrations/20261019010300_booking_103_procountor_settings.sql'), 'utf8');
const ACCOUNTS = { rounding: '3740', sales_by_vat: { '25.5': '3000' }, clearing_by_method: { cash: '1910' } };

test('sanakirjan avaimet ovat joko tuodussa 11:ssä tai vain uudessa 15:ssä', () => {
  const oldKeys = new Set(imported.filter((r) => r.key.startsWith('ui.admin.procountor.')).map((r) => r.key));
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(texts.PROCOUNTOR_TEXTS[lang])) {
      const pool = oldKeys.has(key) ? imported : pending;
      const row = pool.find((r) => r.key === key && r.lang === lang);
      assert.ok(row, key + ' ' + lang);
      assert.equal(row.text, text);
      assert.equal(row.class, 'normal');
      assert.deepEqual(row.placeholders, []);
      assert.equal(row.text.includes('http'), false);
      if (oldKeys.has(key)) assert.equal(pending.some((r) => r.key === key), false, key);
      else assert.equal(imported.some((r) => r.key === key), false, key);
    }
  }
  assert.equal(new Set(pending.map((r) => r.key + '|' + r.lang)).size, pending.length);
  for (const row of pending.filter((r) => /^ui\.admin\.procountor\.sales_(25_5|13_5|0|14|24|10)$/.test(r.key))) {
    assert.match(row.reason, /ALV-kanta/);
    assert.match(row.text, /25|13|14|24|10|0/);
  }
  assert.match(texts.PROCOUNTOR_TEXTS.fi['ui.admin.procountor.bank_keep'], /henkilökunnalle ja ylläpitäjille/);
  assert.equal(texts.PROCOUNTOR_TEXTS.fi['ui.admin.procountor.bank_keep'].includes('vain ylläpitäjälle'), false);
});

test('mock: live_incomplete, säilytys ja tyhjennys, esikatselu ei lähetä', async () => {
  const { createAdminMock } = await import(pathToFileURL(join(root, 'admin/options-mock.js')));
  const mock = createAdminMock({ role: 'manager' });
  await assert.rejects(() => mock.rpc('admin_set_procountor_settings', { p: { mode: 'live', approved_by: '' } }), (e) => e.code === 'approval_required');
  await assert.rejects(() => mock.rpc('admin_set_procountor_settings', { p: { mode: 'live', approved_by: 'Joonas 2026-10-18', vat_status: '', accounts: { sales_by_vat: {}, clearing_by_method: {} } } }), (e) => e.code === 'live_incomplete');
  await assert.rejects(() => mock.rpc('admin_set_procountor_settings', { p: { mode: 'dry_run', api_key: 'ei' } }), (e) => e.code === 'secrets_not_allowed');
  const saved = await mock.rpc('admin_set_procountor_settings', { p: { mode: 'dry_run', environment: 'sandbox', approved_by: 'Joonas 2026-10-18', vat_status: '12', bank_account: 'FI21 1234 5600 0007 85', accounts: ACCOUNTS } });
  assert.equal(saved.mode, 'dry_run');
  assert.equal(saved.environment, 'pts');
  assert.equal(saved.bank_account, 'FI2112345600000785');
  const kept = await mock.rpc('admin_set_procountor_settings', { p: { mode: 'dry_run', accounts: ACCOUNTS } });
  assert.equal(kept.approved_by, 'Joonas 2026-10-18');
  assert.equal(kept.vat_status, '12');
  assert.equal(kept.bank_account, 'FI2112345600000785');
  const cleared = await mock.rpc('admin_set_procountor_settings', { p: { mode: 'dry_run', approved_by: '', vat_status: '', bank_account: '', accounts: ACCOUNTS } });
  assert.equal(cleared.approved_by, '');
  assert.equal(cleared.vat_status, '');
  assert.equal(cleared.bank_account, '');
  const live = await mock.rpc('admin_set_procountor_settings', { p: { mode: 'live', approved_by: 'Joonas 2026-10-18', vat_status: '12', accounts: ACCOUNTS } });
  assert.equal(live.mode, 'live');
  const preview = await mock.rpc('admin_procountor_preview_daily', { p_date: '2032-06-15' });
  assert.equal(preview.sent, false);
  const staff = createAdminMock({ role: 'staff' });
  assert.equal(staff.state.perms.includes('settings.edit'), false);
  assert.equal(staff.state.perms.includes('quotes.manage'), false);
});

test('asetusnäkymä käyttää tekstifunktiota eikä upota Procountor-lauseita', () => {
  assert.match(settings, /loadProcountorTexts/);
  assert.match(settings, /procountorText/);
  assert.match(settings, /data-testid": "procountor-status"|'data-testid': 'procountor-status'/);
  assert.match(settings, /procountor-settings/);
  assert.match(settings, /admin_get_procountor_settings/);
  assert.match(settings, /admin_set_procountor_settings/);
  assert.match(settings, /admin_procountor_status/);
  assert.equal(settings.includes('procountor-edit-mode'), false);
  assert.equal(settings.includes('procountor-edit-env'), false);
  assert.equal(settings.includes('procountor-daily'), false);
  assert.match(settings, /mode: cfg\.mode/);
  assert.match(settings, /environment: cfg\.environment/);
  assert.match(settings, /daily_enabled: cfg\.daily_enabled === true/);
  assert.equal(settings.includes('Harjoitusajo'), false);
  assert.equal(settings.includes('Tilit puuttuvat'), false);
  assert.match(migration, /live_incomplete/);
  assert.match(migration, /p \? 'approved_by'/);
  assert.match(migration, /p \? 'bank_account'/);
  assert.match(migration, /p \? 'vat_status'/);
});

test('tilit tallentuvat, tila ja päiväkirjaus pysyvät', async () => {
  const { createAdminMock } = await import(pathToFileURL(join(root, 'admin/options-mock.js')));
  const mock = createAdminMock({ role: 'admin' });
  await mock.rpc('admin_set_procountor_settings', { p: {
    mode: 'dry_run', environment: 'prod', daily_enabled: true, approved_by: 'Joonas 2026-10-18', vat_status: '12', accounts: ACCOUNTS,
  } });
  const before = await mock.rpc('admin_get_procountor_settings');
  const saved = await mock.rpc('admin_set_procountor_settings', { p: {
    mode: before.mode,
    environment: before.environment,
    daily_enabled: before.daily_enabled === true,
    approved_by: before.approved_by,
    vat_status: '13',
    api_prefix: before.api_prefix,
    bank_account: before.bank_account,
    accounts: { rounding: '1910', sales_by_vat: { '25.5': '3000' }, clearing_by_method: { card_terminal: '1910' } },
  } });
  assert.equal(saved.mode, 'dry_run');
  assert.equal(saved.environment, 'prod');
  assert.equal(saved.daily_enabled, true);
  assert.equal(saved.vat_status, '13');
  assert.equal(saved.accounts.rounding, '1910');
  assert.equal(saved.accounts.sales_by_vat['25.5'], '3000');
  assert.equal(saved.accounts.clearing_by_method.card_terminal, '1910');
});
