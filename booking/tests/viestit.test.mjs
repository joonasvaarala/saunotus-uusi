// node --test booking/tests/viestit.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');

const { messageDecision, fillMessage, validateMessage, timingLabel, GRACE_MS } = await import(pathToFileURL(join(root, 'booking/admin/messages-logic.js')).href);
const { collectDefaults, classFor } = await import(pathToFileURL(join(root, 'booking/shop/src/text-registry.js')).href);
const { tokensOf, KEY_RE, TOKEN_RE, KINDS } = await import(pathToFileURL(join(root, 'booking/shop/src/site-texts-logic.js')).href);

let templates = null;
try { templates = await import(pathToFileURL(join(root, 'booking/supabase/functions/send-emails/templates.ts')).href); }
catch (e) { if (!/ERR_UNKNOWN_FILE_EXTENSION|Unknown file extension/.test(String(e?.code || e))) throw e; }
const skipTs = templates ? false : 'Node ei tue .ts-tuontia (tarvitaan Node >= 22.18)';

const pending = JSON.parse(read('content/site-texts.pending-import-29.json'));
const migration = read('booking/supabase/migrations/20261021140000_booking_121_messages.sql');
const rollback = read('booking/supabase/rollbacks/20261021140000_booking_121_ROLLBACK.sql');
const sendIndex = read('booking/supabase/functions/send-emails/index.ts');

const at = (iso) => new Date(iso).toISOString();
const base = {
  createdAt: '2026-10-21T12:00:00.000Z',
  arrivals: [],
  amount: 1,
  unit: 'minutes',
  direction: 'after',
  anchor: 'booking',
  now: '2026-10-21T12:02:00.000Z',
  orderStatus: 'confirmed',
  paymentStatus: 'paid',
};

test('ajastuspäätös peilaa tietokannan syyt', () => {
  assert.equal(messageDecision({ ...base, external: true }).reason, 'external_import');
  assert.equal(messageDecision({ ...base, orderStatus: 'cancelled' }).reason, 'order_status');
  assert.equal(messageDecision({ ...base, paymentStatus: 'refunded' }).reason, 'refunded');
  assert.equal(messageDecision({ ...base, paymentStatus: 'partially_refunded' }).action, 'send');
  assert.equal(messageDecision({ ...base, amount: null, unit: null, direction: null, anchor: null }).reason, 'no_timing');
  assert.equal(messageDecision({ ...base, now: '2026-10-21T12:00:30.000Z' }).reason, 'not_due');
  const missed = messageDecision({
    ...base, arrivals: ['2026-10-22T12:00:00.000Z'], amount: 2, unit: 'days', direction: 'before', anchor: 'arrival',
  });
  assert.equal(missed.reason, 'missed_at_booking');
  const edge = messageDecision({ ...base, createdAt: '2026-10-01T00:00:00.000Z', now: new Date(Date.parse('2026-10-01T00:01:00.000Z') + GRACE_MS).toISOString() });
  assert.equal(edge.action, 'send');
  const late = messageDecision({ ...base, createdAt: '2026-10-01T00:00:00.000Z', now: new Date(Date.parse('2026-10-01T00:01:00.000Z') + GRACE_MS + 1000).toISOString() });
  assert.equal(late.reason, 'too_late');
  const arrival = {
    createdAt: '2026-10-20T12:00:00.000Z', now: '2026-10-20T13:00:00.000Z', orderStatus: 'confirmed', paymentStatus: 'paid',
    arrivals: ['2026-10-28T15:00:00.000Z', '2026-10-25T15:00:00.000Z'], amount: 1, unit: 'days', direction: 'before', anchor: 'arrival',
  };
  assert.equal(messageDecision(arrival).sendAt, at('2026-10-24T15:00:00.000Z'));
  assert.equal(messageDecision({ ...arrival, direction: 'after' }).sendAt, at('2026-10-29T15:00:00.000Z'));
  const day = messageDecision({ ...base, amount: 1, unit: 'days', direction: 'after', now: '2026-10-21T13:00:00.000Z' });
  assert.equal(day.sendAt, at('2026-10-22T12:00:00.000Z'));
  assert.equal(messageDecision({ ...base, anchor: 'arrival', direction: 'before', unit: 'days', amount: 1 }).reason, 'no_arrival');
});

test('paikkamerkit ja lomake', () => {
  assert.equal(fillMessage('Hei {asiakas_nimi} {tuntematon}', { asiakas_nimi: 'Aada' }), 'Hei Aada {tuntematon}');
  assert.equal(fillMessage('x {linkki}', {}), 'x ');
  const bad = validateMessage({ name: 'Ohje', category: 'instruction', active: true, subject_fi: 'A', body_fi: 'B' });
  assert.equal(bad.ok, false);
  assert.equal(bad.code, 'invalid_text');
  const marketing = validateMessage({ name: 'Palaute', category: 'feedback', active: true, subject_fi: 'A', body_fi: 'B' });
  assert.equal(marketing.code, 'invalid_timing');
  const link = validateMessage({ name: 'Palaute', category: 'feedback', active: false, link_url: 'http://example.test/x' });
  assert.equal(link.code, 'invalid_link');
  const ok = validateMessage({
    name: 'Ohje', category: 'instruction', active: true, subject_fi: 'A', short_fi: 'lyhyt', body_fi: 'täysi',
    link_url: 'https://example.test/arvostelu', product_ids: [10, 10, 8],
  });
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.value.product_ids, [10, 8]);
  assert.equal(ok.value.short_en, null);
  assert.match(timingLabel({ send_amount: 2, send_unit: 'days', send_direction: 'before', send_anchor: 'arrival' }), /2 päivää ennen saapumista/);
  assert.equal(timingLabel({}).startsWith('Ei ajastettua'), true);
});

test('pending-import-29: tilaussivun ja sähköpostin kiinteät tekstit', () => {
  const seen = new Set();
  assert.equal(pending.length, 18);
  for (const r of pending) {
    const w = `${r.key} [${r.lang}]`;
    assert.match(r.key, KEY_RE, w);
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.ok(['normal', 'protected'].includes(r.class), w);
    assert.equal(r.kind, 'plain', w);
    assert.ok(r.max_len >= r.text.length && r.max_len <= 100000, w);
    assert.equal(r.text.trim(), r.text, w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.deepEqual([...r.placeholders].sort(), [...tokensOf(r.text)].sort(), w);
    for (const tok of tokensOf(r.text)) assert.ok(TOKEN_RE.test(tok) && KINDS.includes(tok.slice(2, -2).split(':')[0]), tok);
    assert.ok(r.reason && r.reason.length <= 300, w);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), w);
    seen.add(`${r.key}|${r.lang}`);
  }
  const keys = ['guide_title', 'guide_show', 'guide_hide', 'guide_lead', 'guide_link', 'treat_lead'];
  for (const row of collectDefaults().filter((r) => r.id === 'OT' && keys.some((k) => r.key === `ui.order.${k}`))) {
    const got = pending.find((r) => r.key === row.key && r.lang === row.lang);
    assert.ok(got, row.key);
    assert.equal(got.text, row.text);
    const fi = collectDefaults().find((r) => r.id === 'OT' && r.key === row.key && r.lang === 'fi').text;
    assert.equal(got.class, classFor(row.key, fi));
  }
  assert.equal(pending.filter((r) => r.key.startsWith('ui.order.guide_') || r.key === 'ui.order.treat_lead').length, 12);
});

test('migraatio ja hallinta', () => {
  assert.match(migration, /booking_121/);
  assert.match(migration, /messages\.timed_enabled', 'false'/);
  assert.match(migration, /'messages\.edit'/);
  assert.match(migration, /product_message/);
  assert.match(migration, /booking_messages_dispatch/);
  assert.match(migration, /\[ESIMERKKI EI KÄYTÖSSÄ\]/);
  assert.match(rollback, /drop table if exists booking\.messages/);
  assert.match(rollback, /booking_messages_dispatch/);
  assert.doesNotMatch(rollback, /product_message', case when/);
  assert.match(read('booking/admin/admin.js'), /label: 'Viestit'/);
  assert.match(read('booking/admin/admin.js'), /messages\.edit/);
  assert.match(read('booking/admin/views/messages.js'), /Näytä ohjeet/);
  assert.match(read('booking/admin/views/messages.js'), /data-testid': 'messages-timed'/);
  assert.match(read('booking/shop/src/order.js'), /guide-toggle/);
  assert.match(read('booking/shop/src/order.js'), /upsell-treatments/);
  const allow = sendIndex.indexOf('const blocked = outboxAllowlistBlock');
  const skip = sendIndex.indexOf('const pmBlock = productMessageBlock');
  assert.ok(allow > 0 && skip > allow);
});

test('vahvistus ja tuoteviesti', { skip: skipTs }, async () => {
  const { EMAIL_TEXTS } = await import(pathToFileURL(join(root, 'booking/supabase/functions/send-emails/texts.ts')).href);
  for (const key of ['email.order_confirmation.instructions_title', 'email.product_message.subject_fallback', 'email.product_message.open_link']) {
    for (const lang of ['fi', 'en']) {
      const got = pending.find((r) => r.key === key && r.lang === lang);
      assert.equal(got.text, EMAIL_TEXTS[key][lang], key);
      assert.equal(got.class, classFor(key, EMAIL_TEXTS[key].fi));
    }
  }
  const order = {
    order_no: 15321,
    order_url: 'https://uusi.saunotus.com/tilaus/?t=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c',
    total: 36,
    items: [{ name: 'Yleinen vuoro', quantity: 1, line_total: 36 }],
    reservations: [],
  };
  const plain = templates.render('order_confirmation', { locale: 'fi', to_name: 'Matti Meikäläinen', order }, 'fi');
  const withNotes = templates.render('order_confirmation', {
    locale: 'fi', to_name: 'Matti Meikäläinen',
    order: { ...order, instructions: [{ title: 'Ennen', text: 'Ota mukaan pyyhe' }, { title: '', text: '   ' }] },
  }, 'fi');
  assert.equal(plain.text.includes('Ota mukaan pyyhe'), false);
  assert.equal(plain.text.includes('Ohje'), false);
  assert.ok(withNotes.text.includes('Ohje'));
  assert.ok(withNotes.text.includes('Ota mukaan pyyhe'));
  assert.ok(withNotes.html.includes('Ota mukaan pyyhe'));
  const nasty = templates.render('product_message', {
    locale: 'fi', to_name: 'Matti', order,
    product_message: { active: true, subject: 'Aihe <b>', text: 'Teksti <script>', link_url: 'https://example.test/arvostelu' },
  }, 'fi');
  assert.equal(nasty.subject.includes('<'), false);
  assert.ok(nasty.html.includes('&lt;script&gt;'));
  assert.ok(nasty.html.includes('https://example.test/arvostelu'));
  assert.equal(templates.productMessageBlock({ kind: 'product_message', product_message: { active: false, subject: 'A', text: 'B', order_status: 'confirmed' } }), 'tuoteviesti ei ole käytössä');
  assert.equal(templates.productMessageBlock({ kind: 'product_message', order: { status: 'cancelled' }, product_message: { active: true, subject: 'A', text: 'B' } }), 'tilaus ei ole lähetettävissä');
  assert.equal(templates.productMessageBlock({ kind: 'product_message', product_message: { active: true, subject: 'A', text: 'B', payment_status: 'refunded', order_status: 'confirmed' } }), 'tilaus on hyvitetty');
  assert.equal(templates.productMessageBlock({ kind: 'order_confirmation' }), null);
  const httpLink = templates.render('product_message', {
    locale: 'en', to_name: 'Ann', order, product_message: { subject: 'Hello', text: 'Body', link_url: 'http://example.test/x' },
  }, 'en');
  assert.equal(httpLink.html.includes('http://example.test'), false);
});
