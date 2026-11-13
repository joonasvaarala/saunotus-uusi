// PR 4 (booking_285): asiakkaiden yhdistäminen ja anonymisointi. Puhdas logiikka, tekstit (pending-import-142), migraation ja UI:n rakenne.
// Ajo: node --test booking/tests/asiakas-yhdistaminen-285.test.mjs. Kantatestit: booking/supabase/tests/t285_customer_merge_anonymize.sql
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as A from '../admin/customer-admin-logic.js';
import { CUSTOMER_ADMIN_TEXTS } from '../admin/customer-admin-texts.js';
import { ORDER_VIEW_TEXTS } from '../admin/order-view-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261113064842_booking_285_customer_merge_anonymize.sql';

test('panelAccess: vain oikeus + kytkin; anonymisoitu/yhdistetty asiakas ei saa toimintoja', () => {
  const on = { can_admin: true, merge_enabled: true, anonymize_enabled: false };
  assert.deepEqual(A.panelAccess({ canAdmin: true, status: on }), { merge: true, anonymize: false, hint: false });
  assert.deepEqual(A.panelAccess({ canAdmin: false, status: on }), { merge: false, anonymize: false, hint: true });
  assert.deepEqual(A.panelAccess({ canAdmin: true, status: null }), { merge: false, anonymize: false, hint: false }, 'vanha palvelin → ei mitään');
  assert.deepEqual(A.panelAccess({ canAdmin: true, status: { can_admin: true, merge_enabled: false, anonymize_enabled: false } }), { merge: false, anonymize: false, hint: false }, 'kytkimet pois → piilossa');
  assert.equal(A.panelAccess({ canAdmin: true, status: { merge_enabled: true, anonymize_enabled: true }, anonymized: true }).anonymize, false);
  assert.equal(A.panelAccess({ canAdmin: true, status: { merge_enabled: true }, mergedInto: 4 }).merge, false);
  assert.equal(A.panelAccess({ canAdmin: true, status: { can_admin: false, anonymize_enabled: true } }).anonymize, false, 'palvelin voittaa');
});

test('suunta, laskurit, varoitukset ja vahvistusehdot', () => {
  assert.deepEqual(A.mergeDirection(5, 9), { keep: 5, merge: 9 });
  assert.deepEqual(A.mergeDirection(5, 9, true), { keep: 9, merge: 5 });
  const rows = A.mergeCountRows({ orders: 2, gift_cards: 0, annual_cards: 1, newsletter_x: 3 });
  assert.deepEqual(rows.map((r) => r.key), ['customer_view.merge.count.orders', 'customer_view.merge.count.annual_cards', 'customer_view.merge.count.other']);
  assert.deepEqual(rows[2].vars, { table: 'newsletter_x', n: 3 });
  assert.deepEqual(A.warningRows({ warnings: ['unknown_customer_triggers:a,b', 'different_email'] }, 'merge').map((r) => r.vars), [{ names: 'a,b' }, {}]);
  assert.deepEqual(A.blockerRows({ blockers: ['kind_mismatch'] }, 'merge'), [{ key: 'customer_view.merge.blocker.kind_mismatch' }]);
  assert.equal(A.canConfirmMerge({ plan: { ok: true }, checked: true }), true);
  assert.equal(A.canConfirmMerge({ plan: { ok: false }, checked: true }), false);
  assert.equal(A.canConfirmMerge({ plan: { ok: true, already_merged: true }, checked: true }), false);
  assert.equal(A.canConfirmMerge({ plan: { ok: true }, checked: false }), false);
  assert.equal(A.canConfirmAnonymize({ plan: { ok: true }, checked: true, reason: 'ab' }), false);
  assert.equal(A.canConfirmAnonymize({ plan: { ok: true }, checked: true, reason: 'syy' }), true);
  assert.equal(A.canConfirmAnonymize({ plan: { ok: true }, checked: true, reason: 'syy', busy: true }), false);
});

test('tekstit: FI = EN, kaikki käytetyt avaimet olemassa, pending-import-142 täsmää', () => {
  assert.deepEqual(Object.keys(CUSTOMER_ADMIN_TEXTS.fi).sort(), Object.keys(CUSTOMER_ADMIN_TEXTS.en).sort());
  for (const k of Object.keys(CUSTOMER_ADMIN_TEXTS.fi)) { assert.equal(ORDER_VIEW_TEXTS.fi[k], CUSTOMER_ADMIN_TEXTS.fi[k]); assert.equal(ORDER_VIEW_TEXTS.en[k], CUSTOMER_ADMIN_TEXTS.en[k]); }
  const rows = JSON.parse(read('content/site-texts.pending-import-142.json'));
  assert.equal(rows.length, Object.keys(CUSTOMER_ADMIN_TEXTS.fi).length * 2);
  for (const r of rows) {
    assert.equal(r.text, CUSTOMER_ADMIN_TEXTS[r.lang][r.key], r.key);
    assert.ok(r.text.length <= r.max_len); assert.doesNotMatch(r.text, /<|>|https?:/, r.key);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((x) => x[0]));
  }
  // jokainen palvelimen estokoodi ja varoitus on käännetty
  const sql = read(MIG);
  const codes = (re) => [...sql.matchAll(re)].map((m) => m[1]);
  for (const c of codes(/v_block := v_block \|\| '\["([a-z_]+)"\]'/g)) {
    const grp = ['future_reservations', 'unpaid_orders', 'active_annual_card', 'pending_emails', 'open_voucher_claims', 'active_waitlist'].includes(c) ? 'anonymize' : 'merge';
    assert.ok(CUSTOMER_ADMIN_TEXTS.fi[`ui.admin.customer_view.${grp}.blocker.${c}`], c);
  }
  for (const c of codes(/v_warn := v_warn \|\| '\["([a-z_]+)"\]'/g)) assert.ok(CUSTOMER_ADMIN_TEXTS.fi[`ui.admin.customer_view.merge.warning.${c}`] || CUSTOMER_ADMIN_TEXTS.fi[`ui.admin.customer_view.anonymize.warning.${c}`], c);
});

test('migraatio: kytkimet oletuksena false eikä kytketä päälle missään; oikeus; ei kosketa 287/288-funktioihin', () => {
  const sql = read(MIG);
  assert.match(sql, /'customer_anonymize_enabled', 'false'::jsonb/);
  assert.match(sql, /'customer_merge_enabled', 'false'::jsonb/);
  assert.doesNotMatch(sql, /update\s+booking\.settings|'customer_(merge|anonymize)_enabled',\s*'true'/i, 'ei kytkimen päällekytkentää');
  assert.match(sql, /\('admin', 'customers\.admin'\), \('manager', 'customers\.admin'\)/);
  assert.equal((sql.match(/_require_permission\('customers\.admin'\)/g) || []).length, 4, 'jokainen muuttava/esikatselu-funktio tarkistaa oikeuden');
  assert.doesNotMatch(sql, /svc_raise_order_price|_close_cancelled_order_links|orders_cancel_close_links|admin_list_payment_link_watch|payment_link_reminders_sweep/);
  for (const f of ['admin_merge_customers(bigint, bigint, boolean, text)', 'admin_anonymize_customer(bigint, text, boolean)', 'admin_merge_customers_preview(bigint, bigint)', 'admin_anonymize_customer_preview(bigint)'])
    assert.match(sql, new RegExp(`revoke all on function booking\\.${f.replace(/[()]/g, '\\$&')} from public, anon`), f);
  const rb = read('booking/supabase/rollbacks/20261113064842_booking_285_ROLLBACK.sql');
  assert.match(rb, /raise exception/); assert.match(rb, /drop function if exists booking\.admin_merge_customers/);
});

test('UI: RPC-kutsut vain paneelissa, ei kovakoodattuja värejä eikä emojeja, suora taulukirjoitus puuttuu', () => {
  const panel = read('booking/admin/views/customer-admin-panel.js');
  for (const r of ['admin_customer_admin_status', 'admin_merge_customers_preview', 'admin_merge_customers', 'admin_anonymize_customer_preview', 'admin_anonymize_customer']) assert.match(panel, new RegExp(`'${r}'`), r);
  for (const f of ['views/customer-admin-panel.js', 'customer-admin-logic.js', 'customer-admin-texts.js', 'views/customer-view.js']) {
    const s = read(`booking/admin/${f}`);
    assert.doesNotMatch(s, /#[0-9a-f]{6}\b|style:/i, f);
    assert.doesNotMatch(s, /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u, f);
    assert.doesNotMatch(s, /dbSelect\(|\.from\(|insert\(|upsert\(/, f);
  }
  assert.match(panel, /p_confirm: true/); assert.match(panel, /cv-merge-check/); assert.match(panel, /cv-anon-check/);
});
