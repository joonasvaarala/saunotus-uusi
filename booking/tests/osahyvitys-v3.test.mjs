// Tilausnäkymä v3 PR 3 (booking_282–284): osahyvityksen puhdas logiikka, tekstit (pending-import-139), UI-liput ja migraatioiden/rollbackien rakenne.
// Ajo: node --test booking/tests/osahyvitys-v3.test.mjs. Rahavirrat testataan SQL:llä: booking/supabase/tests/talous/t282_*.sql, t283_*.sql, t284_*.sql.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as P from '../admin/partial-refund-logic.js';
import { PARTIAL_REFUND_TEXTS, prText, PREFIX } from '../admin/partial-refund-texts.js';
import { REDUCE_TEXTS, rt } from '../shop/src/reduce-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');

const info = (o = {}) => ({ ok: true, partial_refunds_enabled: true, can_refund: true, order_status: 'confirmed', overpaid: 29, refundable_max: 29, non_refundable_amount: 0, invoice_locked: false,
  payments: [{ payment_id: 11, provider: 'manual', method: 'card_terminal', cap: 30, kind: 'refundable', online: false }, { payment_id: 12, provider: 'montonio', method: 'montonio', cap: 57, kind: 'refundable', online: true }], gift_cards: [], ...o });

test('ylisuoritus: lippu, oikeus, laskulukko, peruttu ja tyhjä → piilossa palvelimen syyllä; muuten summa palvelimelta', () => {
  assert.equal(P.overpaymentView(null).show, false);
  assert.equal(P.overpaymentView(info({ partial_refunds_enabled: false })).reason, 'disabled', 'lippu pois → ei ominaisuutta');
  assert.equal(P.overpaymentView(info({ partial_refunds_enabled: undefined })).reason, 'disabled', 'puuttuva lippu = pois');
  assert.equal(P.overpaymentView(info({ can_refund: false })).reason, 'no_permission');
  assert.equal(P.overpaymentView(info({ invoice_locked: true })).reason, 'invoice_locked');
  assert.equal(P.overpaymentView(info({ order_status: 'cancelled' })).reason, 'cancelled');
  assert.equal(P.overpaymentView(info({ refundable_max: 0.04 })).reason, 'nothing', 'alle 0,05 € ei hyvitettävää');
  const v = P.overpaymentView(info());
  assert.equal(v.show, true); assert.equal(v.max, 29); assert.equal(v.payments.length, 2);
  const g = P.overpaymentView(info({ payments: [{ payment_id: 1, provider: 'manual', method: 'gift_card', cap: 20, kind: 'gift_card' }], refundable_max: 29 }));
  assert.equal(g.show, false, 'lahjakorttimaksua ei tarjota hyvitettäväksi');
});

test('summan tarkistus: 0,05 € minimi, enintään max, kaksi desimaalia', () => {
  assert.deepEqual(P.checkAmount('0,04', 29), { ok: false, amount: 0.04, error: 'too_small' });
  assert.equal(P.checkAmount('0,05', 29).ok, true);
  assert.equal(P.checkAmount('29,00', 29).ok, true);
  assert.equal(P.checkAmount('29,01', 29).error, 'too_big');
  assert.equal(P.checkAmount('10,555', 29).error, 'invalid');
  assert.equal(P.checkAmount('', 29).error, 'invalid');
  assert.equal(P.checkAmount('abc', 29).error, 'invalid');
  assert.equal(P.checkAmount('12.5', 29).amount, 12.5);
});

test('muutoksen hyvitysvaihe: näkyy vain pienennyksessä, kun lippu + oikeus + hyvitettävää', () => {
  const prev = (o = {}) => ({ ok: true, old_total: 87, new_total: 58, diff: -29, overpaid_after: 29, refundable_max: 29, non_refundable_amount: 0, partial_refunds_enabled: true, can_refund: true, invoice_locked: false, refund_plan: [], ...o });
  const v = P.changeRefundView(prev());
  assert.equal(v.show, true); assert.equal(v.max, 29); assert.equal(v.diff, -29);
  assert.equal(P.changeRefundView(prev({ partial_refunds_enabled: false })).reason, 'disabled');
  assert.equal(P.changeRefundView(prev({ can_refund: false })).reason, 'no_permission');
  assert.equal(P.changeRefundView(prev({ invoice_locked: true })).reason, 'invoice_locked');
  assert.equal(P.changeRefundView(prev({ diff: 10, new_total: 97, overpaid_after: 0, refundable_max: 0 })).reason, 'price_up', 'suurennus: lisämaksu, ei hyvitystä');
  assert.equal(P.changeRefundView(prev({ refundable_max: 0, overpaid_after: 0, diff: -29 })).reason, 'none');
  assert.equal(P.changeRefundView(null).reason, 'missing');
  // argumentit
  assert.deepEqual(P.changeArgs({ refund: 'diff', notify: 'yes', reason: 'x' }, v), { p_refund_amount: 29, p_refund_reason: 'x', p_notify: true });
  assert.deepEqual(P.changeArgs({ refund: 'partial', amount: '12.5', notify: 'no' }, v), { p_refund_amount: 12.5, p_refund_reason: null, p_notify: false });
  assert.deepEqual(P.changeArgs({ refund: 'none', notify: 'no' }, v), { p_notify: false }, 'Älä hyvitä nyt: ei summaa');
});

test('koko tilauksen peruutus: yksi rivi / maksu, verkkomaksut ensin, minimi 0,05 €, lahjakortti/kumppani ei koskaan', () => {
  const i = info({ payments: [{ payment_id: 11, provider: 'manual', method: 'card_terminal', cap: 30, kind: 'refundable', online: false },
    { payment_id: 12, provider: 'montonio', method: 'montonio', cap: 57, kind: 'refundable', online: true },
    { payment_id: 13, provider: 'manual', method: 'gift_card', cap: 20, kind: 'gift_card', online: false },
    { payment_id: 14, provider: 'manual', method: 'partner_voucher_elamyslahjat', cap: 40, kind: 'partner_voucher', online: false }] });
  assert.deepEqual(P.allocateCancelRefund(i, 'full'), [{ payment_id: 12, amount: 57 }, { payment_id: 11, amount: 30 }]);
  assert.deepEqual(P.allocateCancelRefund(i, 'partial', 60), [{ payment_id: 12, amount: 57 }, { payment_id: 11, amount: 3 }], 'verkkomaksu ensin');
  assert.deepEqual(P.allocateCancelRefund(i, 'partial', 10), [{ payment_id: 12, amount: 10 }]);
  assert.deepEqual(P.allocateCancelRefund(i, 'none'), []);
  const small = info({ payments: [{ payment_id: 12, provider: 'montonio', cap: 0.04, kind: 'refundable', online: true }] });
  assert.deepEqual(P.allocateCancelRefund(small, 'full'), [], 'Montonion minimi 0,05 €');
  const ids = P.allocateCancelRefund(i, 'full').map((x) => x.payment_id);
  assert.equal(new Set(ids).size, ids.length, 'yksi hyvitys / maksu');
  assert.ok(!ids.includes(13) && !ids.includes(14));
  const cv = P.cancelAllRefundView(i);
  assert.equal(cv.show, true); assert.equal(cv.max, 87);
  assert.equal(P.cancelAllRefundView(info({ partial_refunds_enabled: false })).reason, 'disabled');
  assert.equal(P.cancelAllRefundView(i, { used: true }).reason, 'partly_used');
  assert.equal(P.cancelAllRefundView(info({ invoice_locked: true })).reason, 'invoice_locked', 'laskulukossa hyvitys estetty, peruutus ei');
  assert.deepEqual(P.cancelOrderArgs({ orderId: 5, refund: [], notify: true, giftKeep: false }), { p_order_id: 5, p_reason: 'henkilökunta', p_refund: null, p_notify: true, p_gift_card_keep: false });
  const so = P.syntheticCancelOptions(info({ gift_cards: [{ amount: 20, code_last4: '8001', valid_to: '2027-01-01', keep_allowed: true }], payments: i.payments }), { firstReservationId: 9, hasEmail: true });
  assert.equal(so.gift_card_choice_required, true); assert.equal(so.partner_share, 40); assert.equal(so.customer_email, true);
});

test('virhekoodit → tekstiavaimet', () => {
  assert.equal(P.errorKey({ code: 'amount_exceeds_refundable' }), 'errors.amount_exceeds_refundable');
  assert.equal(P.errorKey({ message: 'xx partial_refunds_disabled' }), 'errors.partial_refunds_disabled');
  assert.equal(P.errorKey({ code: 'capacity_exceeded' }), null);
});

test('tekstit: FI = EN, paikkamerkit, ei HTML:ää, pending-import-139 täsmää, ei päällekkäisyyttä muiden tuontien kanssa', () => {
  assert.deepEqual(Object.keys(PARTIAL_REFUND_TEXTS.fi).sort(), Object.keys(PARTIAL_REFUND_TEXTS.en).sort());
  const rows = JSON.parse(read('content/site-texts.pending-import-139.json'));
  const admin = rows.filter((r) => r.key.startsWith(PREFIX));
  assert.equal(admin.length, Object.keys(PARTIAL_REFUND_TEXTS.fi).length * 2);
  const seen = new Set();
  for (const r of rows) {
    assert.ok(r.key.startsWith(PREFIX) || r.key.startsWith('ui.public.order_change.reduce.'), r.key);
    if (r.key.startsWith(PREFIX)) assert.equal(r.text, PARTIAL_REFUND_TEXTS[r.lang][r.key], r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.ok(r.text.length <= r.max_len, r.key);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((x) => x[0]), r.key);
    assert.doesNotMatch(r.text, /<|>|https?:/, r.key);
    assert.equal(seen.has(`${r.key}|${r.lang}`), false, `kaksoisrivi ${r.key}`); seen.add(`${r.key}|${r.lang}`);
  }
  const pubFi = rows.filter((r) => r.key.startsWith('ui.public.order_change.reduce.') && r.lang === 'fi').map((r) => r.key).sort();
  const pubEn = rows.filter((r) => r.key.startsWith('ui.public.order_change.reduce.') && r.lang === 'en').map((r) => r.key).sort();
  assert.deepEqual(pubFi, pubEn);
  for (const f of readdirSync(join(root, 'content')).filter((n) => /^site-texts\.(pending-import|imported|fallback).*\.json$/.test(n) && n !== 'site-texts.pending-import-139.json')) {
    const j = JSON.parse(read(`content/${f}`)); const other = Array.isArray(j) ? j : j.texts || [];
    for (const r of other) assert.ok(!String(r.key).startsWith(PREFIX) && !String(r.key).startsWith('ui.public.order_change.reduce.'), `${r.key} myös ${f}`);
  }
  assert.equal(prText('refund.max', { amount: '29,00 €' }, 'fi'), 'enintään 29,00 €');
  assert.equal(prText('refund.none', null, 'en'), 'Do not refund');
});

test('käyttöliittymä: ominaisuus piiloon kun lippu pois; oikeudet; ei suoria taulukirjoituksia; ei kovakoodattuja värejä', () => {
  const files = ['views/partial-refund-flow.js', 'views/order-cancel-flow.js', 'partial-refund-logic.js', 'partial-refund-texts.js'];
  for (const f of files) {
    const s = read(`booking/admin/${f}`);
    assert.doesNotMatch(s, /#[0-9a-f]{6}\b|style:/i, f);
    assert.doesNotMatch(s, /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u, f);
    assert.doesNotMatch(s, /dbSelect\('(orders|reservations|payments|refunds)'|\.from\(|insert\(|upsert\(/, f);
  }
  const flow = read('booking/admin/views/partial-refund-flow.js');
  assert.match(flow, /overpaymentView\(info\)/); assert.match(flow, /if \(!view\.show\) return null/, 'nappi puuttuu kokonaan, kun palvelin ei salli');
  assert.match(flow, /ctx\.can\('payments\.refund'\)/);
  assert.match(flow, /if \(!view\.show\) return \{ skip: true/, 'muutoksen hyvitysvaihe ohitetaan, kun lippu pois / ei oikeutta / ei hyvitettävää');
  const cancel = read('booking/admin/views/order-cancel-flow.js');
  assert.match(cancel, /partialEnabled\(st\.info\)/, 'atominen peruutus ja Hyvitä osa vain lipun ollessa päällä');
  assert.match(cancel, /admin_cancel_order/); assert.match(cancel, /p_refund_amount/);
  const view = read('booking/admin/views/order-view.js');
  assert.match(view, /data-slot': 'ov-over'/); assert.match(view, /overpaymentView\(info\)\.show/);
  assert.match(read('booking/admin/views/order-card.js'), /changeRefundStep\(/);
  // PR 1:n turvallinen oletus säilyy: ilman infoa (null) peruutusdialogi toimii kuten ennen
  assert.match(cancel, /st\.info = await loadRefundInfo/);
});

test('asiakkaan tilaussivu: ennakkohyvitys vahvistetaan summalla, lippu pois → entinen viesti; FI/EN-avaimet samat', () => {
  const shop = read('booking/shop/src/shop.js');
  assert.match(shop, /public_change_preview/); assert.match(shop, /p_expected_refund = st\.reduce\.amount/);
  assert.match(shop, /if \(reason === 'feature_disabled'\) return t\.changePaidPrice/, 'lippu pois: täsmälleen entinen viesti');
  assert.match(shop, /refund_confirmation_required/);
  assert.doesNotMatch(read('booking/shop/src/i18n.js'), /reduce:/, 'asiakasteksit omassa moduulissa (text-registry ei tunne uusia T-lehtiä)');
  assert.deepEqual(Object.keys(REDUCE_TEXTS.fi).sort(), Object.keys(REDUCE_TEXTS.en).sort());
  const pub = JSON.parse(read('content/site-texts.pending-import-139.json')).filter((r) => r.key.startsWith('ui.public.order_change.reduce.'));
  assert.equal(pub.length, Object.keys(REDUCE_TEXTS.fi).length * 2);
  for (const r of pub) assert.equal(r.text, REDUCE_TEXTS[r.lang][r.key.replace('ui.public.order_change.reduce.', '')], r.key);
  assert.equal(rt('fi', 'confirm', { amount: '29,00 €' }), 'Vahvista muutos ja hyvitys 29,00 €');
});

const mig = (n) => readdirSync(join(root, 'booking/supabase/migrations')).find((f) => f.includes(`_booking_${n}_`));
const roll = (n) => readdirSync(join(root, 'booking/supabase/rollbacks')).find((f) => f.includes(`_booking_${n}_ROLLBACK`));

test('migraatiot 282–284: tiedostot, aikaleimat, rollbackit, liput oletuksena pois, ei Edge/maksurajapintakutsuja, revoke public/anon', () => {
  for (const n of [282, 283, 284]) {
    assert.ok(mig(n), `migraatio ${n}`); assert.ok(roll(n), `rollback ${n}`);
    const m = mig(n); assert.ok(m > '20261111211923', 'aikaleima myöhempi kuin booking_286');
    const sql = read(`booking/supabase/migrations/${m}`);
    assert.doesNotMatch(sql, /net\.http_post|vault\.|https?:\/\//, 'ei ulkoisia kutsuja');
    assert.match(sql, /set search_path = ''|SET search_path TO ''/, 'security definer + search_path');
    assert.match(sql, /revoke all on function/i);
    const rb = read(`booking/supabase/rollbacks/${roll(n)}`);
    assert.match(rb, /md5\(pg_get_functiondef/, 'rollback tarkistaa nykyisen version'); assert.match(rb, /set local lock_timeout/);
  }
  const s282 = read(`booking/supabase/migrations/${mig(282)}`), s283 = read(`booking/supabase/migrations/${mig(283)}`), s284 = read(`booking/supabase/migrations/${mig(284)}`);
  assert.match(s282, /'partial_refunds_enabled', 'false'::jsonb/); assert.match(s284, /'customer_auto_partial_refund_enabled', 'false'::jsonb/);
  for (const k of ['admin_change_booking_preview', 'admin_change_booking(']) assert.ok(s282.includes(k), k);
  for (const k of ['admin_refund_overpayment', 'admin_cancel_order', 'admin_order_refund_info']) assert.ok(s283.includes(k), k);
  for (const k of ['public_change_preview', 'p_expected_refund', 'cancellation_tier', 'customer_reduce_full_refund_days_private']) assert.ok(s284.includes(k), k);
  // palvelin tarkistaa liput
  assert.match(s282, /if not booking\._flag_on\('partial_refunds_enabled'\)/); assert.match(s283, /if not booking\._flag_on\('partial_refunds_enabled'\)/);
  assert.match(s284, /_flag_on\('customer_auto_partial_refund_enabled'\) and booking\._flag_on\('partial_refunds_enabled'\)/);
  // booking_288: ei päällekkäistä linkkien sulkulogiikkaa
  const code = (sql) => sql.split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');
  for (const sql of [s282, s283, s284]) assert.doesNotMatch(code(sql), /_close_cancelled_order_links|orders_cancel_close_links|create trigger/i, '288:n logiikkaa ei kopioida eikä muuteta');
  assert.match(s283, /booking_288/, 'yhteistoiminta dokumentoitu');
  // 287/288 -tiedostoja ei lisätä repoon tässä PR:ssä
  assert.ok(!mig(287) && !mig(288));
  // admin_refund-polku: ei uutta rajapintakutsua, Montonio käyttää refunds.status = requested
  assert.match(s284, /'requested', 'montonio'/);
});
