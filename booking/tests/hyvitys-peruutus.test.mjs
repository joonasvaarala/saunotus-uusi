// Hallinnan hyvitys ↔ peruutus (booking_136): tilauksen hyvitys kysyy, perutaanko varaukset; varauksen peruutus kysyy,
// hyvitetäänkö varauksen osuus. Oletus aina Ei. Ei verkkoa eikä tietokantaa (SQL-testi: booking/supabase/tests/talous/t136_refund_cancel.sql).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const MIG = 'booking/supabase/migrations/20261024073642_booking_136_refund_cancel_link.sql';
const RB = 'booking/supabase/rollbacks/20261024073642_booking_136_ROLLBACK.sql';
const T = await import(pathToFileURL(join(root, 'admin/refund-cancel-texts.js')));
const A = await import(pathToFileURL(join(root, 'admin/talous-api.js')));
const { createMock } = await import(pathToFileURL(join(root, 'admin/talous-mock.js')));
const { createAdminMock } = await import(pathToFileURL(join(root, 'admin/options-mock.js')));

test('migraatio: vain uudet booking-funktiot, oikeudet, ei public-skeemaa eikä jonotuslistan funktioita', () => {
  const sql = read(MIG);
  const created = [...sql.matchAll(/create or replace function (booking\.[a-z_0-9]+)\(/g)].map((m) => m[1]);
  assert.deepEqual(created.sort(), ['booking._reservation_refund_plan', 'booking.admin_cancel_reservation', 'booking.admin_refund_order', 'booking.admin_reservation_refund_preview'].sort());
  assert.doesNotMatch(sql, /\bpublic\./, 'ei public-skeemaa');
  assert.doesNotMatch(sql, /_notify_waitlist_for_window|public_waitlist_claim/, 'jonotuslistan funktiot ennallaan');
  assert.doesNotMatch(sql, /create or replace function booking\.(admin_refund|admin_set_reservation_status)\(/, 'olemassa olevat funktiot ennallaan');
  assert.doesNotMatch(sql, /\b(alter|create|drop) table\b/i, 'ei taulumuutoksia');
  assert.doesNotMatch(sql, /integration_config\s+set|update booking\.integration_config/i, 'maksut eivät vaihdu live-tilaan');
  // hyvitysoikeus: payments.refund; peruutus: bookings.manage
  assert.match(sql, /admin_reservation_refund_preview[\s\S]*?_require_permission\('payments\.refund'\)/);
  assert.match(sql, /admin_cancel_reservation[\s\S]*?_require_permission\('bookings\.manage'\);\s*if coalesce\(p_refund, false\) then perform booking\._require_permission\('payments\.refund'\)/);
  assert.match(sql, /admin_refund_order[\s\S]*?_require_permission\('payments\.refund'\);\s*if coalesce\(p_cancel_reservations, false\) then perform booking\._require_permission\('bookings\.manage'\)/);
  // oletukset turvalliset
  assert.match(sql, /p_refund boolean default false/);
  assert.match(sql, /p_cancel_reservations boolean default false/);
  // hyvitys kulkee aina admin_refundin kautta (rajat, kuitit, audit, Visma/MobilePay-tila)
  assert.equal((sql.match(/booking\.admin_refund\(/g) || []).length, 2);
  // sisäinen suunnitelma ei näy rooleille, RPC:t vain kirjautuneille
  assert.match(sql, /revoke all on function booking\._reservation_refund_plan\(bigint\) from public, anon, authenticated;/);
  for (const f of ['admin_reservation_refund_preview(bigint)', 'admin_cancel_reservation(bigint, text, boolean, text)', 'admin_refund_order(bigint, numeric, text, jsonb, boolean)']) {
    assert.ok(sql.includes(`revoke all on function booking.${f} from public, anon;`), f);
    assert.ok(sql.includes(`grant execute on function booking.${f} to authenticated, service_role;`), f);
  }
  // osuus: varauksen rivi + lapsirivit, käsittelyssä olevat hyvitykset vähennetään
  assert.match(sql, /i\.id = r\.order_item_id or i\.parent_item_id = r\.order_item_id/);
  assert.match(sql, /status in \('requested','processing'\)/);
});

test('rollback: poistaa kaikki uudet funktiot, ei koske olemassa oleviin', () => {
  const rb = read(RB);
  for (const f of ['admin_refund_order(bigint, numeric, text, jsonb, boolean)', 'admin_cancel_reservation(bigint, text, boolean, text)', 'admin_reservation_refund_preview(bigint)', '_reservation_refund_plan(bigint)']) {
    assert.ok(rb.includes(`drop function if exists booking.${f};`), f);
  }
  assert.doesNotMatch(rb, /create or replace|public\./);
  const names = readdirSync(join(repo, 'booking/supabase/migrations')).filter((n) => /booking_136/.test(n));
  assert.deepEqual(names, ['20261024073642_booking_136_refund_cancel_link.sql'], 'yksi booking_136-migraatio');
  assert.ok(readdirSync(join(repo, 'booking/supabase/migrations')).filter((n) => /booking_135/.test(n)).length <= 1, 'booking_135 enintään yksi (jonotuslista)');
});

test('tekstit: FI+EN samat avaimet, pending-import-37 vastaa sanakirjaa, ei emojeja eikä HTML:ää', () => {
  const { fi, en } = T.REFUND_CANCEL_TEXTS;
  assert.deepEqual(Object.keys(fi).sort(), Object.keys(en).sort());
  const rows = JSON.parse(read('content/site-texts.pending-import-37.json'));
  assert.equal(rows.length, Object.keys(fi).length * 2);
  const seen = new Set();
  for (const r of rows) {
    assert.ok(r.key.startsWith('ui.admin.refund_cancel.'), r.key);
    assert.ok(!seen.has(`${r.key}|${r.lang}`)); seen.add(`${r.key}|${r.lang}`);
    assert.equal(r.text, T.REFUND_CANCEL_TEXTS[r.lang][r.key], `${r.key} [${r.lang}]`);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.ok(r.max_len >= r.text.length);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((m) => m[0]));
    assert.doesNotMatch(r.text, /[<>]|\p{Extended_Pictographic}/u);
    assert.doesNotMatch(r.text, /\d+[,.]\d{2}\s*€/, 'ei kovakoodattuja hintoja');
  }
  // avain ei ole muissa tuontitiedostoissa
  for (const f of readdirSync(join(repo, 'content'))) {
    if (!/^site-texts\.(pending-import|imported)/.test(f) || f === 'site-texts.pending-import-37.json' || !f.endsWith('.json')) continue;
    for (const r of JSON.parse(read(`content/${f}`))) assert.ok(!String(r.key).startsWith('ui.admin.refund_cancel.'), `${f}: ${r.key}`);
  }
  assert.equal(T.rcText('ui.admin.refund_cancel.refund_yes', { amount: '12,00 €' }, 'fi'), 'Kyllä, hyvitä 12,00 €');
  assert.equal(T.rcText('ui.admin.refund_cancel.order_question', null, 'en'), "Also cancel the order's bookings?");
});

test('tekstit: site_texts-rivi voittaa, rikkinäinen paikkamerkki → sanakirja', async () => {
  T.clearRcTextCache();
  await T.loadRcTexts(null, [{ key: 'ui.admin.refund_cancel.refund_question', lang: 'fi', text: 'Hyvitetäänkö?' }, { key: 'ui.admin.refund_cancel.refund_yes', lang: 'fi', text: 'Hyvitä {{var:summa}}' }, { key: 'ui.admin.day.x', lang: 'fi', text: 'x' }]);
  assert.equal(T.rcText('ui.admin.refund_cancel.refund_question', null, 'fi'), 'Hyvitetäänkö?');
  assert.equal(T.rcText('ui.admin.refund_cancel.refund_yes', { amount: '5 €' }, 'fi'), 'Kyllä, hyvitä 5 €');
  T.clearRcTextCache();
});

test('talous-api: parametrit; oletuksena ei peruutusta eikä hyvitystä', async () => {
  const calls = [];
  const be = A.rpcBackend(async (name, args) => { calls.push([name, args]); return { ok: true }; });
  await be.refundOrder({ paymentId: 5, amount: 10, reason: 'syy' });
  await be.refundOrder({ paymentId: 5, amount: 10, reason: 'syy', cancelReservations: true });
  await be.reservationRefundPreview(7);
  await be.cancelReservation({ reservationId: 7 });
  await be.cancelReservation({ reservationId: 7, refund: true, refundReason: 'asiakas perui' });
  assert.deepEqual(calls, [
    ['admin_refund_order', { p_payment_id: 5, p_amount: 10, p_reason: 'syy' }],
    ['admin_refund_order', { p_payment_id: 5, p_amount: 10, p_reason: 'syy', p_cancel_reservations: true }],
    ['admin_reservation_refund_preview', { p_reservation_id: 7 }],
    ['admin_cancel_reservation', { p_reservation_id: 7 }],
    ['admin_cancel_reservation', { p_reservation_id: 7, p_refund: true, p_refund_reason: 'asiakas perui' }],
  ]);
  // kirjoittava: puuttuva RPC oikeassa tilassa → FeatureNotReady, ei mock-varaa
  const api = A.createTalousApi({ rpc: async () => { const e = new Error('Could not find the function'); e.status = 404; e.code = 'PGRST202'; throw e; }, mock: false });
  await assert.rejects(() => api.cancelReservation({ reservationId: 1 }), (e) => e instanceof A.FeatureNotReady);
  await assert.rejects(() => api.reservationRefundPreview(1), (e) => e instanceof A.FeatureNotReady);
});

test('talous-mock: hyvitys + peruutus vastaa sopimusta', async () => {
  const m = createMock({ delay: 0 });
  const list = await m.rpc('admin_list_orders', { p_payment_filter: 'paid', p_limit: 50 });
  const row = list.rows.find((r) => r.reservation_count > 0 && r.is_native);
  const o = await m.rpc('admin_get_order', { p_order_id: row.order_id });
  const p = o.payments.find((x) => x.status === 'paid' && x.amount > 1);
  assert.ok(p, 'maksettu natiivitilaus löytyy');
  {
    const r0 = await m.rpc('admin_refund_order', { p_payment_id: p.id, p_amount: 1, p_reason: 'testi' });
    assert.equal(r0.cancelled_reservations, 0, 'oletus: ei peruutusta');
    const r1 = await m.rpc('admin_refund_order', { p_payment_id: p.id, p_amount: 1, p_reason: 'testi', p_cancel_reservations: true });
    assert.ok(r1.cancelled_reservations >= 1);
  }
  const res = o.reservations[0];
  const pv = await m.rpc('admin_reservation_refund_preview', { p_reservation_id: res.id });
  assert.ok(pv.total <= o.balance.paid + 0.005, 'osuus ei ylitä maksettua');
  const c0 = await m.rpc('admin_cancel_reservation', { p_reservation_id: res.id });
  assert.equal(c0.refunded_total, 0, 'oletus: ei hyvitystä');
});

test('hallinnan kokeilutila: staff ei saa hyvitysesikatselua eikä perua+hyvittää, manager saa', async () => {
  const staff = createAdminMock({ role: 'staff', perms: ['bookings.manage', 'payments.manage'] });
  const rid = staff.state.reservations.find((r) => r.status === 'confirmed').reservation_id;
  await assert.rejects(() => staff.rpc('admin_reservation_refund_preview', { p_reservation_id: rid }), (e) => /forbidden/.test(e.code || e.message));
  await assert.rejects(() => staff.rpc('admin_cancel_reservation', { p_reservation_id: rid, p_refund: true }), (e) => /forbidden/.test(e.code || e.message));
  assert.equal(staff.state.reservations.find((r) => r.reservation_id === rid).status, 'confirmed');
  const ok = await staff.rpc('admin_cancel_reservation', { p_reservation_id: rid });
  assert.equal(ok.refunded_total, 0);
  const mgr = createAdminMock({ role: 'manager' });
  const r2 = mgr.state.reservations.find((r) => r.status === 'confirmed' && r.payment_status === 'paid');
  const pv = await mgr.rpc('admin_reservation_refund_preview', { p_reservation_id: r2.reservation_id });
  assert.equal(pv.total, +r2.total_gross);
  const done = await mgr.rpc('admin_cancel_reservation', { p_reservation_id: r2.reservation_id, p_refund: true });
  assert.equal(done.refunded_total, +r2.total_gross);
});

test('käyttöliittymä: kysymykset oletuksena Ei, oikeudet tarkistetaan, peruutus kulkee uuden RPC:n kautta', () => {
  const rc = read('booking/admin/views/refund-cancel.js');
  assert.match(rc, /opt\('no', no, true\), opt\('yes', yes, false\)/, 'Ei on valmiiksi valittu');
  assert.match(rc, /if \(canRefund\) \{\s*try \{ plan = await rpc\('admin_reservation_refund_preview'/, 'esikatselu vain payments.refund-oikeudella');
  assert.match(rc, /rpc\('admin_cancel_reservation'/);
  assert.match(rc, /processOnlineRefunds\(online, res\?\.refunds\)/, 'verkkohyvitys käsitellään Edge-funktiolla');
  const sh = read('booking/admin/views/shared.js');
  assert.match(sh, /canRefund: !!can\('payments\.refund'\)/);
  assert.doesNotMatch(sh, /confirm\('Perutaanko varaus\?'\)/, 'vanha confirm korvattu dialogilla');
  const to = read('booking/admin/views/talous-orders.js');
  assert.match(to, /const canRefund = api\.isMock\('refund'\) \|\| ctx\.can\('payments\.refund'\);/, 'hyvitysnappi ennallaan: payments.refund');
  assert.match(to, /ctx\.can\('bookings\.manage'\)\)\s*\n?\s*\? yesNo\(/, 'varausten peruutus vain bookings.manage-oikeudella');
  assert.match(to, /fd\.get\('cancel_reservations'\) === 'yes'/);
  assert.match(to, /cancelRes \? await api\.refundOrder\(\{ \.\.\.args, cancelReservations: true \}\) : await api\.refund\(args\)/, 'Ei → admin_refund ennallaan');
  const css = read('booking/admin/admin.css');
  assert.match(css, /\.rc-opt input\[type=radio\]\{width:22px/, 'radio ei veny 100 %:iin');
  assert.match(css, /\.rc-actions\{display:flex;flex-wrap:wrap/);
  assert.doesNotMatch(css.slice(css.indexOf('booking_136')), /#[0-9a-f]{3,6}\b/i, 'uudet säännöt käyttävät teeman muuttujia');
  assert.ok(read('scripts/build-pages.mjs').includes("'refund-cancel-texts.js', 'views/refund-cancel.js'"));
});

test('mobiili 390 px: myyntikäyrän ruudunlukijataulukko ei levennä Talous-sivua (dialogi ei vaakavieritä)', () => {
  const src = read('booking/admin/views/talous-sales-chart.js');
  assert.match(src, /h\('div', \{ class: 'sr' \}, h\('table', \{ 'data-testid': 'sales-chart-table' \}/, 'taulukko .sr-kääreessä (table ei noudata width:1px)');
  assert.doesNotMatch(src, /h\('table', \{ class: 'sr'/);
  const e2e = read('booking/scripts/e2e-hyvitys-mobiili.mjs');
  assert.match(e2e, /width: 390/);
  assert.match(e2e, /scrollWidth/);
});
