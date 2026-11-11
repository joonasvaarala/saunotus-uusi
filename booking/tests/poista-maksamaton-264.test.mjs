// booking_264: maksamattoman tilauksen poisto (arkistointi). Logiikka, tekstit FI+EN, suodatin, datakerros, mock, migraatio + rollback (staattisesti).
// Tietokantakäytös: supabase/tests/checkout/t264_unpaid_order_delete.sql ja t264_race.py (paikallinen Postgres).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const L = await import(pathToFileURL(join(root, 'admin/order-delete-logic.js')));
const T = await import(pathToFileURL(join(root, 'admin/order-delete-texts.js')));
const F = await import(pathToFileURL(join(root, 'admin/orders-filter.js')));
const OT = await import(pathToFileURL(join(root, 'admin/orders-texts.js')));
const A = await import(pathToFileURL(join(root, 'admin/talous-api.js')));
const { createMock } = await import(pathToFileURL(join(root, 'admin/talous-mock.js')));
const MIG = readFileSync(join(root, 'supabase/migrations/20261111141559_booking_264_unpaid_order_delete.sql'), 'utf8');
const RB = readFileSync(join(root, 'supabase/rollbacks/20261111141559_booking_264_ROLLBACK.sql'), 'utf8');
const VIEW = readFileSync(join(root, 'admin/views/talous-orders.js'), 'utf8');
// booking_264 R4: poisto yhteisessä varaus-/tilauskortissa (PR #331 korvasi Tilaukset-rivin laajennuksen kortilla)
const CARD = readFileSync(join(root, 'admin/views/order-card-delete.js'), 'utf8');
const CARDMAIN = readFileSync(join(root, 'admin/views/order-card.js'), 'utf8');

const TOKEN = '11111111-2222-4333-8444-555555555555';
const sess = (extra = {}) => ({ code: 'provider_session_unresolved', sessions: [{ provider: 'montonio', checkable: true }], ...extra });

test('paneelin tila: palvelin päättää, käyttöliittymä ei arvaa', () => {
  assert.equal(L.deletePanelMode(null), null);
  assert.equal(L.deletePanelMode({ ok: false }), null);
  assert.equal(L.deletePanelMode({ ok: true, archived: true, can_delete: false }), 'archived');
  assert.equal(L.deletePanelMode({ ok: true, can_delete: true, deletable: true, blockers: [] }), 'delete');
  assert.equal(L.deletePanelMode({ ok: true, can_delete: false, deletable: true, blockers: [] }), null, 'ei oikeutta → ei nappia');
  assert.equal(L.deletePanelMode({ ok: true, can_delete: true, deletable: true, blockers: [{ code: 'receipts' }] }), null, 'ristiriita → ei nappia');
  assert.equal(L.deletePanelMode({ ok: true, can_delete: true, deletable: false, blockers: [sess()] }), 'session');
  assert.equal(L.deletePanelMode({ ok: true, can_delete: true, deletable: false, blockers: [sess(), { code: 'settled_payment' }] }), null, 'maksettu → ei poisto-osiota');
  assert.equal(L.deletePanelMode({ ok: true, can_delete: true, deletable: false, blockers: [{ code: 'invoice' }] }), null);
  assert.equal(L.deletePanelMode({ ok: true, can_delete: true, deletable: false, blockers: [] }), null);
});

test('avatun maksun tarkistus vain palvelimen antamalla tokenilla; ei aikarajaa', () => {
  assert.equal(L.canVerifySession({ verify_order_token: TOKEN }), true);
  assert.equal(L.canVerifySession({ verify_order_token: null }), false);
  assert.equal(L.canVerifySession({ verify_order_token: 'x' }), false);
  assert.equal(L.verifyOutcome({ ok: true, payment_status: 'pending', results: [{ outcome: 'cancelled' }] }), 'closed');
  assert.equal(L.verifyOutcome({ ok: true, payment_status: 'paid', results: [] }), 'paid');
  assert.equal(L.verifyOutcome({ ok: true, results: [{ outcome: 'cancelled' }, { outcome: 'paid' }] }), 'paid');
  assert.equal(L.verifyOutcome({ ok: true, results: [{ outcome: 'pending' }] }), 'pending');
  assert.equal(L.verifyOutcome({ ok: true, results: [] }), 'pending', 'ei tuloksia ≠ suljettu');
  assert.equal(L.verifyOutcome({ ok: true, results: [{ outcome: 'not_configured' }] }), 'failed');
  assert.equal(L.verifyOutcome({ ok: false }), 'failed');
  assert.equal(L.verifyOutcome(null), 'failed');
  const src = readFileSync(join(root, 'admin/order-delete-logic.js'), 'utf8');
  assert.doesNotMatch(src, /Date\.now|minutes|expires/i, 'poistettavuus ei perustu kellonaikaan');
});

test('vaikutusrivit ja estetekstit', () => {
  assert.deepEqual(L.effectLines({ effects: { reservations: 2, pending_payments: 1, queued_emails: 0, order_status: 'pending' } }), [['effect_reservations', 2], ['effect_payments', 1]]);
  assert.deepEqual(L.effectLines({ effects: { reservations: 0, pending_payments: 0, queued_emails: 3, order_status: 'cancelled' } }), [['effect_cancelled', 0], ['effect_emails', 3]]);
  assert.deepEqual(L.effectLines(null), []);
  assert.equal(L.blockerKey('invoice'), 'blocker.invoice');
  assert.equal(L.blockerKey('something_new'), 'blocker.unknown');
  for (const c of L.BLOCKER_CODES) assert.match(MIG, new RegExp(`'code', '${c}'`), `SQL tuntee koodin ${c}`);
  const blk = MIG.slice(MIG.indexOf('create or replace function booking._order_delete_blockers'), MIG.indexOf('create or replace function booking.admin_order_delete_check'));
  const sqlCodes = [...blk.matchAll(/jsonb_build_object\('code', '([a-z_]+)'/g)].map((m) => m[1]).filter((c) => c !== 'not_found');
  assert.ok(sqlCodes.length >= 15);
  for (const c of new Set(sqlCodes)) assert.ok(L.BLOCKER_CODES.includes(c), `UI tuntee koodin ${c}`);
});

test('tekstit FI ja EN: samat avaimet, ei tyhjiä, ei lupausta pankin pysäyttämisestä', () => {
  const fi = Object.keys(T.ORDER_DELETE_TEXTS.fi).sort(), en = Object.keys(T.ORDER_DELETE_TEXTS.en).sort();
  assert.deepEqual(fi, en);
  for (const lang of ['fi', 'en']) for (const [k, v] of Object.entries(T.ORDER_DELETE_TEXTS[lang])) assert.ok(String(v).trim(), `${lang} ${k}`);
  for (const c of L.BLOCKER_CODES) assert.ok(T.ORDER_DELETE_TEXTS.fi[`ui.admin.order_delete.${L.blockerKey(c)}`], c);
  assert.equal(T.deleteText('title', { no: 15001 }, 'fi'), 'Poistetaanko maksamaton tilaus #15001?');
  assert.equal(T.deleteText('title', { no: 15001 }, 'en'), 'Delete unpaid order #15001?');
  assert.match(T.deleteText('session_text', null, 'fi'), /ei voi sulkea meidän päästämme/);
  assert.match(T.deleteText('session_text', null, 'fi'), /Pelkkä ajan kuluminen ei riitä/);
  assert.match(T.deleteText('intro', null, 'fi'), /Asiakkaalle ei lähetetä viestiä/);
  assert.equal(OT.ORDER_TEXTS.fi['ui.admin.orders.pay_archived'], 'Poistetut');
  assert.equal(OT.ORDER_TEXTS.en['ui.admin.orders.pay_archived'], 'Deleted');
});

test('suodatin: poistettu vain archived-valinnassa, paitsi myöhäinen maksu tai tarkka numerohaku', () => {
  assert.ok(F.PAYMENT_FILTERS.includes('archived'));
  assert.deepEqual(F.PAYMENT_FILTERS.slice(0, 6), ['paid', 'unpaid', 'invoiced', 'all', 'refunded', 'cancelled'], 'vanhat suodattimet ja järjestys ennallaan');
  const arch = { status: 'cancelled', payment_status: 'unpaid', archived_at: '2026-11-08T10:00:00Z', payments: [] };
  for (const f of ['paid', 'unpaid', 'invoiced', 'all', 'refunded', 'cancelled']) assert.equal(F.matchesPaymentFilter(arch, f), false, f);
  assert.equal(F.matchesPaymentFilter(arch, 'archived'), true);
  assert.equal(F.matchesPaymentFilter(arch, 'all', { exactNumber: true }), true);
  const late = { ...arch, payment_status: 'paid', payments: [{ status: 'paid', amount: 10 }] };
  assert.equal(F.matchesPaymentFilter(late, 'all'), true);
  assert.equal(F.matchesPaymentFilter(late, 'cancelled'), true);
  assert.equal(F.matchesPaymentFilter(late, 'archived'), true);
  const cancelledOnly = { status: 'cancelled', payment_status: 'unpaid', payments: [] };
  assert.equal(F.matchesPaymentFilter(cancelledOnly, 'cancelled'), true, 'tavallinen peruttu (ei arkistoitu) näkyy kuten ennen');
  assert.equal(F.matchesPaymentFilter(cancelledOnly, 'archived'), false);
});

test('datakerros: RPC-nimet ja parametrit; esto tulee virheenä; tarkistus ei heitä', async () => {
  assert.equal(A.RPC.orderDeleteCheck, 'admin_order_delete_check');
  assert.equal(A.RPC.deleteUnpaidOrder, 'admin_delete_unpaid_order');
  const calls = [], fnCalls = [];
  const replies = { admin_order_delete_check: { ok: true, deletable: true, can_delete: true, blockers: [] },
    admin_delete_unpaid_order: { ok: false, code: 'provider_session_unresolved', message: 'x', blockers: [{ code: 'provider_session_unresolved' }] } };
  const api = A.createTalousApi({ rpc: async (n, a) => { calls.push([n, a]); return replies[n]; }, io: { fn: async (n, b) => { fnCalls.push([n, b]); return { ok: true, results: [{ outcome: 'cancelled' }] }; } }, mock: false });
  assert.deepEqual(await api.orderDeleteCheck(7), replies.admin_order_delete_check);
  assert.deepEqual(calls[0], ['admin_order_delete_check', { p_order_id: 7 }]);
  await assert.rejects(() => api.deleteUnpaidOrder({ orderId: 7, reason: 'testi' }), (e) => e.code === 'provider_session_unresolved' && e.details.blockers.length === 1);
  assert.deepEqual(calls[1], ['admin_delete_unpaid_order', { p_order_id: 7, p_reason: 'testi' }]);
  await api.deleteUnpaidOrder({ orderId: 8, reason: null }).catch(() => {});
  assert.deepEqual(calls[2], ['admin_delete_unpaid_order', { p_order_id: 8 }]);
  const v = await api.montonioVerify(TOKEN);
  assert.deepEqual(fnCalls[0], ['montonio-notify', { action: 'reconcile', order_token: TOKEN }]);
  assert.equal(L.verifyOutcome(v), 'closed');
  const missing = A.createTalousApi({ rpc: async () => { throw Object.assign(new Error('Could not find the function'), { status: 404, code: 'PGRST202' }); }, mock: false });
  assert.equal(await missing.orderDeleteCheck(1), null, 'puuttuva RPC → ei poisto-osiota, ei mock-varaa');
  await assert.rejects(() => missing.deleteUnpaidOrder({ orderId: 1 }), (e) => e.code === 'feature_not_ready');
  const broken = A.createTalousApi({ rpc: async () => ({}), io: { fn: async () => { throw new Error('net'); } }, mock: false });
  assert.equal((await broken.montonioVerify(TOKEN)).ok, false);
  assert.equal(A.normOrderRow({ order_id: 1, archived_at: '2026-11-08T10:00:00Z', archived_late_paid: true }).archived_late_paid, true);
  assert.equal(A.normOrderRow({ order_id: 1 }).archived_at, null);
});

test('mock: esto, poisto, idempotenssi ja listat', async () => {
  const mock = createMock({ n: 300, today: '2026-11-08', delay: 0 });
  const unpaid = mock.orders.find((o) => o.is_native && o.payment_status === 'unpaid' && !o.receipts.length && !o.payments.some((p) => p.provider_ref));
  const paid = mock.orders.find((o) => o.is_native && o.payment_status === 'paid');
  assert.ok(unpaid && paid);
  const before = (await mock.rpc('admin_list_orders', { p_payment_filter: 'all', p_limit: 200 })).total;
  const chk = await mock.rpc('admin_order_delete_check', { p_order_id: unpaid.order_id });
  assert.equal(chk.deletable, true);
  assert.equal(L.deletePanelMode(chk), 'delete');
  const pchk = await mock.rpc('admin_order_delete_check', { p_order_id: paid.order_id });
  assert.equal(pchk.deletable, false);
  assert.equal(L.deletePanelMode(pchk), null);
  const blocked = await mock.rpc('admin_delete_unpaid_order', { p_order_id: paid.order_id });
  assert.equal(blocked.ok, false);
  assert.ok(blocked.blockers.some((b) => b.code === 'settled_payment'));
  const res = await mock.rpc('admin_delete_unpaid_order', { p_order_id: unpaid.order_id, p_reason: 'testi' });
  assert.equal(res.ok, true);
  assert.equal((await mock.rpc('admin_delete_unpaid_order', { p_order_id: unpaid.order_id })).already, true);
  assert.equal((await mock.rpc('admin_list_orders', { p_payment_filter: 'all', p_limit: 200 })).total, before - 1);
  const arch = await mock.rpc('admin_list_orders', { p_payment_filter: 'archived', p_limit: 200 });
  assert.deepEqual(arch.rows.map((r) => r.order_id), [unpaid.order_id]);
  assert.equal(arch.rows[0].status, 'cancelled');
  assert.equal(L.archivedBadge(arch.rows[0]), 'archived');
  const byNo = await mock.rpc('admin_list_orders', { p_payment_filter: 'all', p_search: String(unpaid.order_no) });
  assert.equal(byNo.total, 1, 'tarkka numerohaku löytää poistetun');
  const after = await mock.rpc('admin_order_delete_check', { p_order_id: unpaid.order_id });
  assert.equal(L.deletePanelMode(after), 'archived');
  await assert.rejects(() => mock.rpc('admin_list_orders', { p_payment_filter: 'nope' }), (e) => e.code === 'invalid_param');
  await assert.rejects(() => mock.rpc('admin_delete_unpaid_order', { p_order_id: unpaid.order_id, p_reason: 'x'.repeat(501) }), (e) => e.code === 'invalid_param');
});

test('kortti: nappi vain palvelimen tarkistuksesta, vahvistusdialogi, ei poistoa ilman vahvistusta', () => {
  assert.match(CARDMAIN, /import \{ orderDeleteBlock \} from '\.\/order-card-delete\.js'/);
  assert.match(CARDMAIN, /\[check\] = await Promise\.all\(\[api\.orderDeleteCheck\(Number\(id\) \|\| id\), loadDeleteTexts\(rpc\)\]\); \} catch \{ check = null; \}/);
  assert.match(CARDMAIN, /orderDeleteBlock\(\{ api, order, check, onDeleted: \(\) => after\(\), onRecheck: \(\) => fetchOrder\(\) \}\)/);
  assert.match(CARDMAIN, /body\.append\(hero, alerts, primary, sections, secondary, more, move, footer, delBox\)/, 'poisto viimeisenä, erillään muista toiminnoista');
  assert.match(CARDMAIN, /drawOrder\(token\);\n      drawDelete\(token\);/);
  assert.match(CARD, /const mode = deletePanelMode\(check\);/);
  assert.match(CARD, /'data-testid': 'btn-delete-order', text: deleteText\('button'\),\n      onclick: \(\) => openDeleteDialog\(\{ api, order, check, onDone: onDeleted \}\)/);
  assert.match(CARD, /class: 'btn danger oc-delete-btn'/, 'vaarallisen näköinen');
  assert.match(CARD, /formDialog\(deleteText\('title'/);
  assert.match(CARD, /submit\.className = 'btn danger'/);
  assert.match(CARD, /api\.montonioVerify\(check\.verify_order_token\)/);
  assert.equal((CARD.match(/submitUnpaidDelete\(api/g) || []).length, 1, 'poisto vain dialogin lähetyksestä');
  assert.doesNotMatch(CARD, /api\.deleteUnpaidOrder\(/, 'kutsu vain submitUnpaidDelete-apufunktion kautta');
  assert.doesNotMatch(VIEW, /deleteUnpaidOrder|orderDeleteCheck|deleteDialog/, 'Tilaukset-välilehdellä ei toista (kuollutta) poistopolkua');
  const iAwait = CARD.indexOf('await submitUnpaidDelete('), iToast = CARD.indexOf("toast(res.already ? deleteText('already')");
  assert.ok(iAwait > 0 && iToast > iAwait, 'onnistumisilmoitus vasta onnistuneen kutsun jälkeen');
});

test('migraatio: lukot ilman NOWAITia, ei _refresh_order_payment, 263 ennallaan, md5-vartijat, ACL', () => {
  const del = MIG.slice(MIG.indexOf('create or replace function booking.admin_delete_unpaid_order'), MIG.indexOf('-- admin_list_orders: booking_270-runko'));
  assert.ok(del.length > 1000);
  assert.doesNotMatch(del, /nowait/i);
  assert.doesNotMatch(del, /_refresh_order_payment/);
  assert.doesNotMatch(MIG, /create or replace function booking\.payment_mark_paid/i);
  assert.doesNotMatch(MIG, /create or replace function booking\.montonio_payment_(prepare|apply)/i);
  assert.match(MIG, /'b35618b8cd17fa9e7c5902719d0804a2'/);
  assert.match(MIG, /'56edffa64fbd99c14f8ea3a4bf126cd3', 'cad71198827bd7fd03426f146b43b424'/);
  assert.match(del, /_require_permission\('bookings\.manage'\);\s+perform booking\._require_permission\('payments\.manage'\)/);
  const iPay = del.indexOf('from booking.payments x where x.id = any(v_expected) order by x.id for update skip locked');
  const iOrd = del.indexOf('from booking.orders where id = p_order_id for update');
  const iBlk = del.indexOf('v_b := booking._order_delete_blockers(o.id)');
  assert.ok(iOrd > 0 && iPay > iOrd && iBlk > iPay, 'tilaus → täydellinen maksujoukko SKIP LOCKED → esteet');
  assert.match(MIG, /revoke all on function booking\._order_delete_blockers\(bigint\) from public, anon, authenticated;/);
  assert.match(MIG, /check \(archived_at is null or status = 'cancelled'\)/);
  assert.match(MIG, /coalesce\(a\.outcome, ''\) <> 'cancelled'/, 'vain varmennettu päättyminen avaa poiston');
  assert.doesNotMatch(MIG.slice(0, MIG.indexOf('-- Narrow base132 candidate loop')), /interval '\d+ (minutes|hours)'/, 'ei aikarajaan perustuvaa oletusta');
  assert.match(RB, /'cad71198827bd7fd03426f146b43b424', '56edffa64fbd99c14f8ea3a4bf126cd3'/);
  assert.match(RB, /drop function if exists booking\.admin_delete_unpaid_order\(bigint, text\)/);
  assert.match(RB, /if exists \(select 1 from booking\.orders where archived_at is not null\)/, 'rollback ei hävitä arkistotietoa');
});

test('korjaus 2 (6edf538-katselmointi): MobilePay-viite estää aina, sending estää, jono normaalisti, selitystila', () => {
  const blk = MIG.slice(MIG.indexOf('create or replace function booking._order_delete_blockers'), MIG.indexOf('create or replace function booking.admin_order_delete_check'));
  assert.match(blk, /p\.provider in \('mobilepay', 'visma_pay'\)/);
  assert.doesNotMatch(blk, /p\.provider = 'mobilepay' and p\.status = 'pending'/, 'MobilePay-esto ei saa riippua paikallisesta tilasta');
  assert.match(blk, /e\.status = 'sending'/);
  assert.doesNotMatch(MIG, /waitlist_waiting|lock table booking\.waitlist_entries/, 'jono: ei estettä eikä taululukkoa (Joonas 8.11. 19.10)');
  assert.doesNotMatch(MIG, /waitlist_spot_freed/, 'jonoviestiä ei vaimenneta');
  assert.ok(!L.BLOCKER_CODES.includes('waitlist_waiting'));
  for (const c of ['email_sending']) {
    assert.ok(L.BLOCKER_CODES.includes(c));
    for (const lang of ['fi', 'en']) assert.ok(T.ORDER_DELETE_TEXTS[lang][`ui.admin.order_delete.blocker.${c}`], `${lang} ${c}`);
  }
  const base = { ok: true, can_delete: true, deletable: false };
  assert.equal(L.deletePanelMode({ ...base, blockers: [{ code: 'email_sending' }] }), 'blocked');
  assert.equal(L.deletePanelMode({ ...base, blockers: [{ code: 'email_sending' }, { code: 'provider_session_unresolved' }] }), 'blocked');
  assert.equal(L.deletePanelMode({ ...base, blockers: [{ code: 'email_sending' }, { code: 'receipts' }] }), null, 'kova este → ei osiota');
  assert.equal(L.deletePanelMode({ ...base, blockers: [{ code: 'provider_session_unresolved' }] }), 'session');
  assert.match(CARD, /'data-testid': 'order-delete-blocked'/);
  assert.match(T.ORDER_DELETE_TEXTS.fi['ui.admin.order_delete.waitlist'], /vapautuu muille.*jonottajia.*tavallisen ilmoituksen/);
  assert.match(T.ORDER_DELETE_TEXTS.en['ui.admin.order_delete.waitlist'], /available to others.*waiting list.*usual spot-freed notice/);
});

test('korjaus 2: claim/send-vs-archive-sopimus SQL:ssä (lukko ennen esteitä, failed skipataan, insert-trigger)', () => {
  const del = MIG.slice(MIG.indexOf('create or replace function booking.admin_delete_unpaid_order'), MIG.indexOf('-- admin_list_orders: booking_270'));
  const iMail = del.indexOf('from booking.email_outbox x where x.id = any(v_expected) order by x.id for update skip locked');
  const iBlk = del.indexOf('v_b := booking._order_delete_blockers(o.id)');
  assert.ok(iMail > 0 && iBlk > iMail, 'sähköpostirivit lukitaan ennen esteitä');
  assert.match(del, /e\.status in \('pending', 'failed'\)/);
  assert.doesNotMatch(del, /nowait/i);
  assert.match(MIG, /create trigger email_outbox_archived_bi before insert or update on booking\.email_outbox/);
  assert.match(MIG, /for key share/);
  assert.match(MIG, /email_outbox_claim_base_132\(integer\)'::regprocedure\)\);\s+if v not in \('0b10986533285645d8592449a90a1e0c'/);
});

test('korjaus 3: rollback vartioi jokaisen muutettavan/pudotettavan funktion md5:llä ennen muutoksia', () => {
  const pre = RB.slice(0, RB.indexOf('end $pre$;'));
  for (const sig of ['booking.admin_list_orders(', 'booking._order_delete_blockers(bigint)', 'booking.admin_order_delete_check(bigint)',
    'booking.admin_delete_unpaid_order(bigint,text)', 'booking._email_outbox_archived_bi()']) assert.ok(pre.includes(`'${sig}`), sig);
  const drops = [...RB.matchAll(/drop function if exists (booking\.[a-z_]+)\(/g)].map((m) => m[1]);
  assert.ok(drops.length >= 4);
  for (const d of drops) assert.ok(pre.includes(`'${d}(`), `pudotettava ${d} vartioitu`);
  assert.ok(RB.indexOf('end $pre$;') < RB.indexOf('CREATE OR REPLACE FUNCTION booking.admin_list_orders'), 'vartija ennen muutoksia');
  assert.match(pre, /raise exception 'rollback booking_264: tuntematon versio/);
  assert.match(RB, /drop trigger if exists email_outbox_archived_bi on booking\.email_outbox/);
});

test('lukkovirhe (40P01/55P03/57014) näkyy virheenä, ei onnistumisena', async () => {
  for (const code of ['40P01', '55P03', '57014']) {
    const api = A.createTalousApi({ rpc: async () => { const e = new Error('lukko'); e.code = code; throw e; }, io: {}, mock: false });
    await assert.rejects(() => api.deleteUnpaidOrder({ orderId: 1 }), (e) => e.code === code || /lukko/.test(e.message), code);
  }
  for (const code of ['40P01', '55P03', '57014']) {
    const api = A.createTalousApi({ rpc: async () => { const e = new Error('lukko'); e.code = code; throw e; }, io: {}, mock: false });
    await assert.rejects(() => L.submitUnpaidDelete(api, { orderId: 1 }, (k) => k), (e) => e.kind === 'failed' && e.message === 'failed', code);
  }
});


test('Tarkista late-payment count, note validation and isolated mock acknowledgment', async () => {
  const R = await import('../admin/review-logic.js');
  const { createAdminMock } = await import('../admin/options-mock.js');
  const mock = createAdminMock({ latePaymentScenario: true, perms: ['payments.manage'] });
  const before = await mock.rpc('admin_review_list');
  assert.equal(before.archived_late_payments.length, 1);
  assert.ok(R.attentionKeysWithItems(before).includes('archived_late_payments'));
  const count = R.reviewAttentionCount(before);
  for (const n of ['', ' x ', 'x'.repeat(1001)]) assert.equal(R.latePaymentAckNoteOk(n), false);
  assert.equal(R.latePaymentAckNoteOk('  done  '), true);
  await assert.rejects(mock.rpc('admin_ack_archived_late_payment', { p_payment_id: 264001, p_note: 'x' }));
  const args = R.latePaymentAckArgs(before.archived_late_payments[0], '  done  ');
  assert.deepEqual(args, { p_payment_id: 264001, p_note: 'done' });
  assert.equal((await mock.rpc('admin_ack_archived_late_payment', args)).already, false);
  assert.equal((await mock.rpc('admin_ack_archived_late_payment', args)).already, true);
  assert.equal(R.reviewAttentionCount(await mock.rpc('admin_review_list')), count - 1);
  const forbidden = createAdminMock({ latePaymentScenario: true, perms: [] });
  await assert.rejects(forbidden.rpc('admin_ack_archived_late_payment', args));
  assert.equal(forbidden.state.latePaymentAcknowledged, undefined);
  assert.equal((await createAdminMock().rpc('admin_review_list')).archived_late_payments.length, 0);
  assert.ok(mock.state.calls.every((c) => ['admin_review_list','admin_ack_archived_late_payment'].includes(c.name)));
});


test('first post-claim failure/dead is uncertain; no network-error-text exception', () => {
  const guard = MIG.slice(MIG.indexOf('create or replace function booking._email_outbox_archived_bi()'), MIG.indexOf('drop trigger if exists email_outbox_archived_bi'));
  assert.match(guard, /old.status = 'sending' and new.status in \('pending','failed','dead'\)/);
  assert.equal((guard.match(/new.status in \('failed','dead'\) and new.attempts > 0/g) || []).length, 2, 'UPDATE and imported INSERT claim history both covered');
  assert.doesNotMatch(guard, /last_error.*(timeout|network)|network.*last_error/i, 'no unverifiable pre-POST classification by text');
});


test('poiston lähetys: busy / ei oikeutta / esto ovat virheitä selkokielisinä, ei koskaan onnistumista', async () => {
  const text = (k, e) => (k === 'blocked' ? `blocked:${(e?.details?.blockers || []).map((b) => b.code).join(',')}` : k);
  const busyApi = A.createTalousApi({ rpc: async () => ({ ok: false, code: 'busy', message: 'busy retry' }), mock: false });
  await assert.rejects(L.submitUnpaidDelete(busyApi, { orderId: 7 }, text), (e) => e.kind === 'busy' && e.message === 'busy' && e.code === undefined);
  const deniedApi = A.createTalousApi({ rpc: async () => { throw Object.assign(new Error('permission denied for function admin_delete_unpaid_order'), { code: '42501', status: 403 }); }, mock: false });
  await assert.rejects(L.submitUnpaidDelete(deniedApi, { orderId: 7 }, text), (e) => e.kind === 'forbidden' && e.message === 'forbidden');
  const forbiddenApi = A.createTalousApi({ rpc: async () => { throw Object.assign(new Error('Ei oikeutta'), { code: 'forbidden', status: 400 }); }, mock: false });
  await assert.rejects(L.submitUnpaidDelete(forbiddenApi, { orderId: 7 }, text), (e) => e.kind === 'forbidden');
  const blockedApi = A.createTalousApi({ rpc: async () => ({ ok: false, code: 'reservation_started', blockers: [{ code: 'reservation_started' }, { code: 'order_completed' }] }), mock: false });
  await assert.rejects(L.submitUnpaidDelete(blockedApi, { orderId: 7 }, text), (e) => e.kind === 'blocked' && e.message === 'blocked:reservation_started,order_completed');
  await assert.rejects(L.submitUnpaidDelete({ deleteUnpaidOrder: async () => null }, { orderId: 7 }, text), (e) => e.kind === 'failed');
  const calls = [];
  const res = await L.submitUnpaidDelete({ deleteUnpaidOrder: async (a) => { calls.push(a); return { ok: true, order_no: 15007 }; } }, { orderId: 7, reason: '  testi  ' }, text);
  assert.equal(res.ok, true);
  assert.deepEqual(calls, [{ orderId: 7, reason: 'testi' }]);
  await L.submitUnpaidDelete({ deleteUnpaidOrder: async (a) => { calls.push(a); return { ok: true }; } }, { orderId: 8, reason: '   ' }, text);
  assert.deepEqual(calls[1], { orderId: 8, reason: null });
  for (const lang of ['fi', 'en']) for (const k of ['forbidden', 'busy', 'failed', 'blocked_help', 'danger_label']) assert.ok(T.ORDER_DELETE_TEXTS[lang][`ui.admin.order_delete.${k}`], `${lang} ${k}`);
  assert.match(T.deleteText('forbidden', null, 'fi'), /ei ole oikeutta.*ennallaan/);
});

test('R4: maksamaton mennyt/saapunut tilaus (#15012-tyyppi) näyttää syyn, maksettu ei näytä mitään', async () => {
  const base = { ok: true, can_delete: true, deletable: false };
  assert.equal(L.deletePanelMode({ ...base, blockers: [{ code: 'order_completed' }, { code: 'reservation_started' }] }), 'blocked');
  assert.equal(L.deletePanelMode({ ...base, blockers: [{ code: 'reservation_started' }] }), 'blocked');
  assert.equal(L.deletePanelMode({ ...base, blockers: [{ code: 'external_order' }] }), 'blocked');
  assert.equal(L.deletePanelMode({ ...base, blockers: [{ code: 'reservation_started' }, { code: 'settled_payment' }] }), null);
  assert.equal(L.deletePanelMode({ ...base, blockers: [{ code: 'payment_status' }, { code: 'order_completed' }] }), null);
  assert.equal(L.deletePanelMode({ ...base, can_delete: false, blockers: [{ code: 'reservation_started' }] }), null, 'ei oikeutta → ei mitään');
  for (const c of L.NOT_UNPAID_CODES.filter((x) => x !== 'not_found')) assert.ok(L.BLOCKER_CODES.includes(c), c);
  const mock = createMock({ n: 400, seed: 264 });
  const nowIso = new Date().toISOString();
  const all = await mock.rpc('admin_list_orders', { p_payment_filter: 'unpaid', p_limit: 200 });
  const past = all.rows.find((r) => r.is_native && r.payment_status === 'unpaid' && r.first_start && r.first_start < nowIso);
  assert.ok(past, 'mockissa on mennyt maksamaton tilaus');
  const chk = await mock.rpc('admin_order_delete_check', { p_order_id: past.order_id });
  assert.ok(chk.blockers.some((b) => b.code === 'reservation_started'));
  assert.equal(L.deletePanelMode(chk), 'blocked');
  await assert.rejects(() => A.rpcBackend(mock.rpc).deleteUnpaidOrder({ orderId: past.order_id }), (e) => e.details?.blockers?.some((b) => b.code === 'reservation_started'));
});

test('late-payment financial visibility and FI/EN keys follow existing permission/text model', async () => {
  const { createAdminMock } = await import('../admin/options-mock.js');
  const { REVIEW_TEXTS } = await import('../admin/review-texts.js');
  assert.deepEqual((await createAdminMock({latePaymentScenario:true,perms:[]}).rpc('admin_review_list')).archived_late_payments,[]);
  const view=readFileSync(join(root,'admin/views/review.js'),'utf8');
  for(const key of Object.keys(REVIEW_TEXTS.fi).filter(k=>k.includes('.late_'))) {
    assert.ok(REVIEW_TEXTS.en[key]); assert.ok(view.includes(key), key);
  }
  assert.match(MIG,/case when booking.has_permission\('payments.manage'\) then booking._archived_late_payment_review_rows\(\) else '\[\]'/);
});

test('tekstit: pending-import-133 FI+EN = koodin oletukset (ui.admin.order_delete.*), paikkamerkit täsmäävät', () => {
  const rows = JSON.parse(readFileSync(join(root, '../content/site-texts.pending-import-133.json'), 'utf8'));
  const ph = (s) => [...new Set(String(s).match(/\{\{var:[a-z0-9_]+\}\}/g) || [])].sort();
  for (const lang of ['fi', 'en']) for (const [key, text] of Object.entries(T.ORDER_DELETE_TEXTS[lang])) {
    const row = rows.find((r) => r.key === key && r.lang === lang);
    assert.ok(row, `${lang} ${key}`);
    assert.equal(row.text, text, `${lang} ${key}`);
    assert.deepEqual([...row.placeholders].sort(), ph(text), `${lang} ${key}`);
    assert.ok(row.text.length <= row.max_len);
  }
  assert.equal(new Set(rows.map((r) => `${r.key}|${r.lang}`)).size, rows.length, 'ei tuplarivejä');
  assert.ok(rows.every((r) => r.class === 'normal' && r.kind === 'plain'));
});
