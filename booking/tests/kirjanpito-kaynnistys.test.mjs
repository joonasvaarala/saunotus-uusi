// booking_218–219: hyvitysten seuranta, käsin kirjattu hyvitys, suoriteperuste ja käyttöönoton nollausskripti.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveAdminPath, navGroupById, visibleGroupTabs } from '../admin/admin-navigation.js';
import { NAV_TEXTS } from '../admin/nav-texts.js';
import { RW_TEXTS } from '../admin/refund-watch-texts.js';
import { ACCRUAL_TEXTS } from '../admin/accrual-texts.js';
import { createAdminMock } from '../admin/options-mock.js';
import { createTalousApi } from '../admin/talous-api.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');

test('navigaatio: Hyvitysten seuranta on Kassa ja talous -välilehti', () => {
  assert.equal(NAV_TEXTS.fi['ui.admin.nav.refund_watch'], 'Hyvitysten seuranta');
  assert.equal(NAV_TEXTS.en['ui.admin.nav.refund_watch'], 'Refund follow-up');
  assert.deepEqual(resolveAdminPath('hyvitysten-seuranta'), { path: 'kassa', legacyReservations: false, groupId: 'cash', tabId: 'hyvitykset' });
  const cash = navGroupById('cash');
  const can = (list) => (p) => list.includes(p);
  assert.deepEqual(visibleGroupTabs(cash, can(['payments.manage'])).map((t) => t.id), ['talous', 'seurattavat']);
  assert.equal(visibleGroupTabs(cash, can(['bookings.manage'])).find((t) => t.id === 'hyvitykset').view, 'refund-watch');
  assert.equal(visibleGroupTabs(cash, can(['giftcards.manage'])).some((t) => t.id === 'hyvitykset'), false);
  const view = src('admin/views/refund-watch.js');
  assert.match(view, /data-testid': 'refund-watch'/);
  assert.match(view, /admin_record_manual_refund|manual\(/);
  assert.match(view, /data-aging/);
  assert.match(view, /Kirjaa käsin tehty hyvitys|refund_watch\.manual/);
});

test('tuontitiedosto 105: FI+EN, ei päällekkäin, vastaa sanakirjoja', () => {
  const rows = JSON.parse(src('../content/site-texts.pending-import-105.json'));
  const taken = new Set();
  for (const f of readdirSync(join(root, '../content'))) {
    if (f === 'site-texts.pending-import-105.json' || !/^site-texts\.(pending-import-|imported|fallback)/.test(f) || !f.endsWith('.json')) continue;
    const j = JSON.parse(readFileSync(join(root, '../content', f), 'utf8'));
    const list = Array.isArray(j) ? j : j.texts || [];
    for (const r of list) if (r?.key) taken.add(`${r.key}|${r.lang}`);
  }
  const seen = new Set();
  for (const r of rows) {
    assert.equal(seen.has(`${r.key}|${r.lang}`), false, r.key);
    seen.add(`${r.key}|${r.lang}`);
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, `${r.key} on jo toisessa tuonnissa`);
    assert.ok(r.text.length <= r.max_len, r.key);
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.doesNotMatch(r.text, /</);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{(?:var|setting):[a-z0-9_]+\}\}/g)].map((m) => m[0]));
  }
  for (const bag of [RW_TEXTS, ACCRUAL_TEXTS]) {
    for (const lang of ['fi', 'en']) {
      for (const [key, text] of Object.entries(bag[lang])) {
        assert.equal(rows.find((r) => r.key === key && r.lang === lang)?.text, text, key);
      }
    }
  }
  assert.equal(rows.find((r) => r.key === 'ui.admin.refund_watch.manual' && r.lang === 'fi').text, 'Kirjaa käsin tehty hyvitys');
  assert.equal(rows.find((r) => r.key === 'ui.admin.accrual.advances' && r.lang === 'fi').text, 'Saadut ennakot');
  assert.match(src('supabase/migrations/20261030111918_booking_218_refund_watch.sql'), /admin_record_manual_refund/);
  assert.match(src('supabase/migrations/20261030111923_booking_219_accrual_report.sql'), /admin_report_accrual/);
  assert.match(src('admin/views/talous-reports.js'), /r-report-\$\{id\}/);
  assert.match(src('admin/views/talous-reports.js'), /basis_service/);
  assert.match(src('admin/views/talous-reports.js'), /reportAccrualCsv/);
});

test('nollausskripti ei ole migraatio, kuivaharjoitus on oletus, triggerit kytketään takaisin', () => {
  const sql = src('scripts/reset_before_launch.sql');
  assert.equal(readdirSync(join(root, 'supabase/migrations')).some((f) => f.includes('reset_before_launch')), false);
  assert.match(sql, /select booking\.cutover_reset\(true\)/);
  assert.doesNotMatch(sql, /^select booking\.cutover_reset\(false\)/m);
  assert.match(sql, /disable trigger receipts_guard/);
  assert.match(sql, /enable trigger receipts_guard/);
  assert.match(sql, /disable trigger gift_card_ledger_append_only/);
  assert.match(sql, /enable trigger gift_card_ledger_append_only/);
  assert.match(sql, /disable trigger invoices_lock/);
  assert.match(sql, /enable trigger invoices_lock/);
  assert.match(sql, /disable trigger invoice_lines_lock/);
  assert.match(sql, /enable trigger invoice_lines_lock/);
  assert.match(sql, /johku_import/);
  assert.match(sql, /cutover_reset_verify/);
  assert.match(sql, /revoke all on function booking\.cutover_reset\(boolean\)/);
  assert.doesNotMatch(sql.replace(/--.*$/gm, ''), /\bcommit\s*;/i);
  assert.match(src('supabase/tests/talous/t218_refund_watch.sql'), /TESTRESULT/);
  assert.match(src('supabase/tests/talous/t219_accrual.sql'), /TESTRESULT/);
  assert.match(src('supabase/tests/talous/t220_launch_reset.sql'), /TESTRESULT/);
  assert.match(src('README.md'), /reset_before_launch\.sql/);
});

test('kokeilutila: ikääntyvä hyvitys, uudelleenyritys ja käsinkirjaus', async () => {
  const mock = createAdminMock({ perms: ['bookings.manage'], role: 'staff' });
  const listed = await mock.rpc('admin_list_open_refunds', {});
  assert.equal(listed.rows.length, 3);
  assert.equal(listed.rows.some((r) => r.aging && r.status === 'processing'), true);
  assert.equal(listed.aging_count >= 1, true);
  const denied = createAdminMock({ perms: ['payments.manage'], role: 'staff' });
  await assert.rejects(() => denied.rpc('admin_list_open_refunds', {}), (e) => e.code === 'forbidden');
  const adminOnly = createAdminMock({ perms: [], role: 'admin' });
  assert.equal((await adminOnly.rpc('admin_list_open_refunds', {})).total, 3);
  const retried = await mock.rpc('admin_retry_provider_refund', { p_refund_id: 60 });
  assert.equal(retried.status, 'requested');
  await assert.rejects(() => mock.rpc('admin_retry_provider_refund', { p_refund_id: 62 }), (e) => e.code === 'provider_no_retry');
  const done = await mock.rpc('admin_record_manual_refund', {
    p_refund_id: 61, p_amount: 58, p_refunded_on: '2026-10-28', p_provider_ref: 'portal-61', p_note: 'Tehty Montonion portaalissa',
  });
  assert.equal(done.status, 'done');
  assert.equal(done.receipt_no, 'H-2026-000001');
  const after = await mock.rpc('admin_list_open_refunds', {});
  assert.equal(after.rows.some((r) => r.refund_id === 61), false);
});

test('suorite-CSV käyttää samaa erotinta ja tiedostonimeä', async () => {
  const api = createTalousApi({ mock: true });
  const report = await api.reportAccrual('2026-11-01', '2026-11-30');
  assert.equal(report.basis.includes('palvelupäivä'), true);
  assert.equal(report.advances.gift_cards_unused.vat_at_sale, true);
  assert.equal(report.sales_by_product[0].gross, 57);
  const csv = await api.reportAccrualCsv(report.period.from, report.period.to);
  assert.match(csv.filename, /^palvelupaiva_2026-11-01_2026-11-30\.csv$/);
  assert.match(csv.content, /osio;tuote;alv_%/);
  assert.match(csv.content, /ennakko;Lahjakortit kayttamatta/);
  assert.equal(csv.content.includes('\r\n') || csv.content.includes('myynti;'), true);
});
