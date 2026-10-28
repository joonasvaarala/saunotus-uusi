// booking_149 (Joonaksen päätös 24.10.2026): asiakkaan itse tekemä peruutus ja hyvitys (tilaussivun peruutuspyyntö) ei ole sallittu,
// jos vuoron alkuun on alle 48 h (asetus customer_change_hours_before). Hallinnan peruutukset ja hyvitykset toimivat aina.
// Ei verkkoa eikä tietokantaa. SQL-käytös (49 h ok, 47 h estetty, hallinta aina ok): booking/supabase/tests/peruutus/t149_customer_cancel_48h.sql (paikallinen PG17).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const MIG = 'booking/supabase/migrations/20261024115808_booking_149_customer_cancel_48h.sql';
const RB = 'booking/supabase/rollbacks/20261024115808_booking_149_ROLLBACK.sql';
const { OT } = await import(pathToFileURL(join(root, 'shop/src/order-texts.js')));
const { normOrder, createOrderApi } = await import(pathToFileURL(join(root, 'shop/src/order-api.js')));
const { createOrderMock } = await import(pathToFileURL(join(root, 'shop/src/order-mock.js')));
const R = await import(pathToFileURL(join(root, 'shop/src/text-registry.js')));
const fnNames = (sql) => [...sql.matchAll(/create or replace function\s+booking\.(\w+)/gi)].map((m) => m[1]).sort();

test('migraatio: yksi booking_149, vain peruutuksen funktiot, ei public-skeemaa eikä muiden avointen töiden funktioita', () => {
  const names = readdirSync(join(repo, 'booking/supabase/migrations')).filter((n) => /booking_149_/.test(n));
  assert.deepEqual(names, ['20261024115808_booking_149_customer_cancel_48h.sql']);
  const sql = read(MIG);
  assert.deepEqual(fnNames(sql), ['_customer_cancel_deadline', 'public_get_order', 'public_request_cancel']);
  assert.doesNotMatch(sql, /\bpublic\.\w+/i, 'ei public-skeemaa');
  for (const f of ['public_join_waitlist', '_gc_product_name', 'admin_list_gift_cards', '_annual_card_email_trg', '_annual_card_mail', 'admin_annual_card_for_order', 'email_outbox_claim',
    'admin_cancel_reservation', 'admin_refund', 'admin_refund_order', 'admin_resolve_order_request', 'admin_set_reservation_status', 'admin_change_booking', 'public_cancel_booking'])
    assert.ok(!fnNames(sql).includes(f), `${f} ei muutu`);
  assert.match(sql, /customer_change_hours_before/);
  assert.match(sql, /on conflict \(key\) do nothing/i, 'asetus lisätään vain jos puuttuu (tuotannossa 48)');
  assert.match(sql, /'cancel_too_late'/);
  assert.match(sql, /revoke all on function booking\._customer_cancel_deadline\(bigint\) from public, anon, authenticated/i);
  assert.match(sql, /security definer/i);
});

test('rollback: palauttaa public_get_order- ja public_request_cancel-määritelmät, poistaa apufunktion, ei cancel_too_late-koodia', () => {
  const rb = read(RB);
  assert.deepEqual(fnNames(rb), ['public_get_order', 'public_request_cancel']);
  assert.match(rb, /drop function if exists booking\._customer_cancel_deadline\(bigint\)/i);
  const body = rb.replace(/--.*$/gm, '').replace(/drop function if exists booking\._customer_cancel_deadline\(bigint\);/i, '');
  assert.doesNotMatch(body, /cancel_too_late|cancel_deadline|cancel_closed/);
  assert.doesNotMatch(rb, /\bpublic\.\w+/i);
});

test('SQL-testi t149 on olemassa ja kattaa 49 h / 47 h / hallinnan', () => {
  const t = read('booking/supabase/tests/peruutus/t149_customer_cancel_48h.sql');
  for (const s of ["interval '49 hours'", "interval '47 hours'", 'admin_cancel_reservation', 'admin_refund', 'admin_resolve_order_request', 'cancel_too_late', 'TESTRESULT']) assert.ok(t.includes(s), s);
  assert.doesNotMatch(t, /@(?!example\.test)[a-z0-9.-]+\.[a-z]{2,}/i, 'vain feikkiosoitteita');
});

test('normOrder: uudet kentät; puuttuva can_request_cancel = null (vanha backend)', () => {
  const o = normOrder({ order_no: 1, status: 'confirmed', can_request_cancel: false, cancel_deadline: '2026-11-01T10:00:00Z', cancel_hours_before: 48, cancel_closed: true });
  assert.equal(o.can_request_cancel, false); assert.equal(o.cancel_deadline, '2026-11-01T10:00:00Z'); assert.equal(o.cancel_hours_before, 48); assert.equal(o.cancel_closed, true);
  const old = normOrder({ order_no: 1, status: 'confirmed' });
  assert.equal(old.can_request_cancel, null); assert.equal(old.cancel_closed, false); assert.equal(old.cancel_deadline, null);
});

test('mock: yli 48 h → peruutuspyyntö sallittu; alle 48 h → suljettu ja palvelin hylkää (cancel_too_late)', async () => {
  const open = createOrderApi({ mock: true, token: 'x', mockFactory: () => createOrderMock({}) });
  let o = await open.get();
  assert.equal(o.can_request_cancel, true); assert.equal(o.cancel_closed, false); assert.equal(o.cancel_hours_before, 48);
  assert.ok(Date.parse(o.cancel_deadline) > Date.now());
  assert.equal((await open.requestCancel({ reason: '' })).ok, true);
  o = await open.get();
  assert.equal(o.can_request_cancel, false); assert.equal(o.cancel_closed, false, 'avoin pyyntö: ei suljettu-tekstiä'); assert.equal(o.cancel_request.status, 'open');

  const closed = createOrderApi({ mock: true, token: 'x', mockFactory: () => createOrderMock({ scenario: 'peruutus-suljettu' }) });
  o = await closed.get();
  assert.equal(o.can_request_cancel, false); assert.equal(o.cancel_closed, true);
  const h = (Date.parse(o.reservations[0].starts_at) - Date.now()) / 36e5;
  assert.ok(h > 0 && h < 48, `vuoroon ${h} h`);
  const r = await closed.requestCancel({ reason: '' });
  assert.equal(r.ok, false); assert.equal(r.code, 'cancel_too_late');
  assert.equal((await closed.get()).cancel_request, null);
});

test('tilaussivu: lomake vain kun palvelin sallii; rajan jälkeen teksti + mailto; cancel_too_late → päivitys; korttien alle ei yhteystietoriviä', () => {
  const js = read('booking/shop/src/order.js');
  assert.match(js, /function cancelBody\(o, note\)/);
  assert.match(js, /if \(o\.can_request_cancel == null\) return \[note, cancelForm\(\)\];/, 'vanha backend kuten ennen');
  assert.match(js, /if \(o\.cancel_closed\) return \[emailText\(t\[oneKey\('cancelClosed', L, \{ hours \}, t\)\]/);
  assert.match(js, /if \(!o\.can_request_cancel\) return \[note\];/, 'ei lomaketta kun peruutus ei ole sallittu');
  assert.match(js, /href: `mailto:\$\{email\}`, 'data-testid': 'order-email'/);
  assert.match(js, /r\.code === 'cancel_too_late'/);
  const page = js.split("data-testid': 'order-page'")[1].split(');')[0];
  assert.ok(page && !page.includes('phoneBox'), 'tilaussivun korttien alle ei tule puhelin–sähköposti-riviä');
});

test('tekstit: FI+EN samat avaimet, {hours}/{date}/{email}, ei numeroa käsin, ei HTML:ää eikä emojeja', () => {
  for (const k of ['cancelRule', 'cancelClosed', 'err.cancel_too_late']) {
    for (const L of ['fi', 'en']) {
      const s = OT[L][k];
      assert.ok(typeof s === 'string' && s.length > 10, `${L}.${k}`);
      assert.doesNotMatch(s, /[<>]|\p{Extended_Pictographic}/u);
      assert.doesNotMatch(s, /299 ?2866/);
    }
  }
  assert.match(OT.fi.cancelRule, /\{hours\} tuntia ennen vuoron alkua.*\{date\}.*Alle \{hours\} tuntia ennen vuoroa peruutus ei ole enää mahdollinen/);
  assert.match(OT.en.cancelRule, /\{hours\} hours before.*\{date\}.*no longer possible/);
  for (const L of ['fi', 'en']) {
    assert.match(OT[L].cancelClosed, /\{hours\}.*\{email\}/);
    assert.match(OT[L].cancelClosedOne, /\{hours\}.*\{email\}/);
    assert.doesNotMatch(OT[L].cancelClosed + OT[L].cancelClosedOne, /\{phone\}|soita|call us/i);
  }
  assert.match(OT.fi.cancelClosed, /lähetä meille sähköpostia: \{email\}\./);
  assert.match(OT.en.cancelClosed, /email us: \{email\}\./);
  assert.match(OT.fi.changeNote, /lähetä meille sähköpostia:$/);
  assert.match(OT.en.changeNote, /email us:$/);
  assert.match(OT.fi.changeClosed, /lähetä meille sähköpostia:$/);
  assert.match(OT.en.changeClosed, /email us:$/);
});

test('pending-import-49 vastaa koodin oletuksia (ui.order.*), FI+EN, paikkamerkit, ei <-merkkiä, ei muissa tuontitiedostoissa', () => {
  const rows = JSON.parse(read('content/site-texts.pending-import-49.json'));
  const defaults = new Map(R.collectDefaults().map((r) => [`${r.key}|${r.lang}`, r.text]));
  const keys = ['ui.order.cancel_rule', 'ui.order.cancel_closed', 'ui.order.err.cancel_too_late'];
  assert.equal(rows.length, keys.length * 2);
  for (const r of rows) {
    const w = `${r.key} [${r.lang}]`;
    assert.ok(keys.includes(r.key), w); assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.equal(r.text, defaults.get(`${r.key}|${r.lang}`), w);
    assert.equal(r.kind, 'plain', w); assert.ok(['normal', 'protected'].includes(r.class), w);
    assert.ok(r.max_len >= r.text.length, w);
    assert.deepEqual([...r.placeholders].sort(), [...new Set(r.text.match(/\{\{[^{}]*\}\}/g) || [])].sort(), w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\//, w);
  }
  assert.ok(rows.find((r) => r.key === 'ui.order.cancel_closed' && r.lang === 'fi').text.includes('{{var:email}}'));
  assert.ok(!rows.some((r) => r.text.includes('{{var:phone}}')));
  for (const k of keys) assert.ok(rows.some((r) => r.key === k && r.lang === 'fi') && rows.some((r) => r.key === k && r.lang === 'en'), k);
  for (const f of readdirSync(join(repo, 'content'))) {
    if (!/^site-texts\.(pending-import|imported|fallback)/.test(f) || f === 'site-texts.pending-import-49.json' || !f.endsWith('.json')) continue;
    const j = JSON.parse(read(`content/${f}`)); const list = Array.isArray(j) ? j : j.texts || [];
    for (const r of list) assert.ok(!keys.includes(r.key), `${f}: ${r.key}`);
  }
});
