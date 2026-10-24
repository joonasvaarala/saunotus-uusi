// node --test booking/tests/viestit-toimitustapa.test.mjs
// Paketti 09 / booking_141: viestin toimitustapa (ajastettu lähetys tai ohjeet tilauksen yhteydessä).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { emptyMessage, timingLabel, validateMessage } from '../admin/messages-logic.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024140000_booking_141_message_delivery_mode.sql';
const RB = 'booking/supabase/rollbacks/20261024140000_booking_141_ROLLBACK.sql';
const message = { name: 'Ennen käyntiä', category: 'instruction', active: true,
  subject_fi: 'Hei {asiakas_nimi}', short_fi: '<p>Ota pyyhe</p>', body_fi: '<h2>Tulo-ohje</h2>', product_ids: [7] };

test('vanhat kutsut oletuksena ajastettuja ja ohje voidaan jättää ilman ajastusta', () => {
  assert.equal(emptyMessage().delivery_mode, 'scheduled');
  const r = validateMessage(message);
  assert.equal(r.ok, true);
  assert.equal(r.value.delivery_mode, 'scheduled');
  assert.equal(r.value.send_amount, null);
  assert.equal(timingLabel(r.value), 'Ei ajastettua lähetystä');
});

test('order_only tyhjentää kaikki ajastuskentät', () => {
  const r = validateMessage({ ...message, delivery_mode: 'order_only', send_amount: 2,
    send_unit: 'days', send_direction: 'before', send_anchor: 'arrival' });
  assert.equal(r.ok, true);
  assert.equal(r.value.delivery_mode, 'order_only');
  assert.deepEqual([r.value.send_amount, r.value.send_unit, r.value.send_direction, r.value.send_anchor], [null, null, null, null]);
  assert.equal(r.value.short_fi, '<p>Ota pyyhe</p>');
  assert.equal(r.value.body_fi, '<h2>Tulo-ohje</h2>');
  assert.equal(timingLabel(r.value), 'Ohjeet tilauksen yhteydessä');
  assert.equal(timingLabel({ delivery_mode: 'order_only', send_amount: 2, send_unit: 'days', send_direction: 'after', send_anchor: 'booking' }), 'Ohjeet tilauksen yhteydessä');
});

test('ajastus toimii ja muut luokat eivät voi valita order_only-tilaa', () => {
  const r = validateMessage({ ...message, delivery_mode: 'scheduled', send_amount: '2',
    send_unit: 'days', send_direction: 'before', send_anchor: 'arrival' });
  assert.equal(r.ok, true);
  assert.equal(r.value.send_amount, 2);
  assert.match(timingLabel(r.value), /2 päivää ennen saapumista/);
  assert.equal(validateMessage({ ...message, delivery_mode: 'wrong' }).code, 'invalid_delivery_mode');
  assert.equal(validateMessage({ ...message, category: 'feedback', delivery_mode: 'order_only' }).code, 'invalid_delivery_mode');
  assert.equal(validateMessage({ ...message, category: 'after_marketing', delivery_mode: 'order_only' }).code, 'invalid_delivery_mode');
});

test('booking_141: migraatio rakentuu uusimpien määritelmien päälle', () => {
  const sql = read(MIG);
  assert.match(sql, /booking_141/);
  assert.match(sql, /add column delivery_mode text not null default 'scheduled'/);
  assert.match(sql, /delivery_mode in \('scheduled', 'order_only'\)/);
  assert.match(sql, /messages_order_only_no_timing/);
  assert.match(sql, /messages_order_only_instruction check \(delivery_mode = 'scheduled' or category = 'instruction'\)/);
  assert.match(sql, /and m\.delivery_mode = 'scheduled'\n\s+and m\.send_amount is not null/);
  assert.match(sql, /if m\.delivery_mode = 'order_only' then\n\s+return jsonb_build_object\('active', false/);
  assert.match(sql, /create or replace function booking\.admin_save_message\(p_id bigint, p_data jsonb\)/);
  assert.match(sql, /'product_ids','delivery_mode'\]/);
  assert.match(sql, /set status = 'skipped', last_error = 'order_only'/);
  assert.match(sql, /create or replace function booking\._order_message_rows/);
  // booking_122: rich-tieto säilyy (uusin _order_message_rows / _product_message_mail)
  assert.match(sql, /'rich', booking\._message_is_rich\(v_template\)/);
  for (const key of ['title', 'short_text', 'short_rich', 'body', 'text', 'rich', 'delivery_mode', 'link_url']) assert.ok(sql.includes(`'${key}'`), key);
  // Ei uutta wrapperia, ei oikeusmuutoksia, ei lähetystilan / kytkimen muutoksia
  assert.doesNotMatch(sql, /_admin_save_message_pre/);
  assert.doesNotMatch(sql, /^\s*(grant|revoke)\b/im);
  assert.doesNotMatch(sql, /resend\.mode|email\.mode|whatsapp/i);
  assert.doesNotMatch(sql, /insert into booking\.settings|update booking\.settings/);
  assert.doesNotMatch(sql, /\bpublic\./);
});

test('booking_141: rollback palauttaa booking_121/122-määrittelyt ja poistaa sarakkeen', () => {
  const rb = read(RB);
  for (const f of ['admin_save_message(p_id bigint, p_data jsonb)', 'admin_list_messages()', 'messages_dispatch(p_limit integer DEFAULT 50)',
    '_order_message_rows(p_order_id bigint, p_locale text, p_full boolean)', '_product_message_mail(p_outbox_id bigint)']) {
    assert.ok(rb.includes(`CREATE OR REPLACE FUNCTION booking.${f}`), f);
  }
  assert.doesNotMatch(rb, /delivery_mode'|m\.delivery_mode|v_mode/);
  assert.match(rb, /drop constraint if exists messages_order_only_no_timing/);
  assert.match(rb, /drop constraint if exists messages_order_only_instruction/);
  assert.match(rb, /drop column if exists delivery_mode/);
  assert.ok(rb.indexOf('drop column if exists delivery_mode') > rb.lastIndexOf('CREATE OR REPLACE FUNCTION'), 'funktiot ensin, sarake viimeisenä');
  const t = read('booking/supabase/tests/messages/t141_message_delivery_mode.sql');
  assert.match(t, /raise exception 'TESTRESULT/);
  assert.match(t, /@example\.test/);
});

test('hallinnan lomakkeessa on toimitustapa ja ajastuksen piilotus', () => {
  const js = read('booking/admin/views/messages.js');
  assert.match(js, /message-delivery-mode/);
  assert.match(js, /Ohjeet tilauksen yhteydessä \(ei erillistä lähetystä\)/);
  assert.match(js, /timingBox\.hidden = orderOnly/);
  assert.match(js, /control\.disabled = orderOnly/);
  assert.match(js, /orderOnlyOption\.disabled = !instruction/);
  assert.match(js, /delivery_mode: deliveryMode\.value/);
  assert.match(js, /invalid_delivery_mode/);
  const mock = read('booking/admin/options-mock.js');
  assert.match(mock, /delivery_mode: 'scheduled', active: false/);
  assert.match(mock, /data\.delivery_mode = prev\.delivery_mode/);
});

test('tilaussivu: lyhyt ohje aina näkyvissä, täysi ohje napin takana', () => {
  const page = read('booking/shop/src/order.js');
  assert.match(page, /g\.short_text/);
  assert.match(page, /'data-testid': 'guide-previews'/);
  assert.match(page, /g\.short_rich === true/);
  assert.match(page, /'data-testid': 'guide-toggle'/);
  assert.match(page, /hidden: true, 'data-testid': 'guide-body'/);
  assert.match(page, /previews, btn, panel/);
  const mock = read('booking/shop/src/order-mock.js');
  assert.match(mock, /short_text: locale === 'en' \? 'Bring a towel\.' : 'Ota mukaan pyyhe\.'/);
  assert.match(mock, /delivery_mode: 'order_only'/);
  const css = read('booking/shop/src/shop.css');
  assert.match(css, /\.ord-guide-short\{white-space:pre-wrap/);
  assert.match(css, /\.ord-guide-short\.bk-rich\{white-space:normal\}|\.ord-guide-short\.bk-rich\{white-space:normal/);
  // Ei uusia tekstiavaimia: nykyiset guideTitle/guideShow/guideHide/guideLead riittävät.
  const texts = read('booking/shop/src/order-texts.js');
  for (const k of ['guideTitle', 'guideShow', 'guideHide', 'guideLead']) assert.equal(texts.split(`${k}:`).length - 1, 2, k);
});

test('order-api normOrder välittää lyhyen ohjeen ja toimitustavan tilaussivulle', async () => {
  const { normOrder } = await import('../shop/src/order-api.js');
  const o = normOrder({ order_no: 'T1', instructions: [
    { id: 1, title: 'Ennen käyntiä', short_text: 'Ota pyyhe', short_rich: false, body: 'Täysi ohje', rich: false, delivery_mode: 'order_only', link_url: null },
    { id: 2, title: 'Vanha muoto', body: 'Vain täysi ohje' },
    { id: 3, title: 'Tyhjä', short_text: 'x', body: '  ' },
  ] });
  assert.equal(o.instructions.length, 2);
  assert.deepEqual([o.instructions[0].short_text, o.instructions[0].short_rich, o.instructions[0].delivery_mode], ['Ota pyyhe', false, 'order_only']);
  assert.deepEqual([o.instructions[1].short_text, o.instructions[1].short_rich, o.instructions[1].delivery_mode], ['', false, 'scheduled']);
  assert.equal(normOrder({ instructions: [{ body: 'b', short_text: '<p>x</p>', short_rich: 'true' }] }).instructions[0].short_rich, false);
});
