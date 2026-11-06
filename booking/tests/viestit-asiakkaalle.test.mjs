// node --test booking/tests/viestit-asiakkaalle.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');

const {
  fillCustomerMessage,
  validateCustomerMessageDraft,
  CUSTOMER_MESSAGE_PLACEHOLDERS,
  parseCustomerMessageDates,
  pruneSelectedProductIds,
  groupCustomerMessageProducts,
} = await import(pathToFileURL(join(root, 'booking/admin/customer-message-logic.js')).href);
const { CUSTOMER_MESSAGE_TEXTS, customerMessageText, clearCustomerMessageTextCache } = await import(
  pathToFileURL(join(root, 'booking/admin/customer-message-texts.js')).href
);

const pending129 = JSON.parse(read('content/site-texts.pending-import-129.json'));
const pending130 = JSON.parse(read('content/site-texts.pending-import-130.json'));
const pending = [...pending129, ...pending130];
const migration257 = read('booking/supabase/migrations/20261106220000_booking_257_customer_message.sql');
const migration258 = read('booking/supabase/migrations/20261106234000_booking_258_customer_message_date_products.sql');
const rollback258 = read('booking/supabase/rollbacks/20261106234000_booking_258_ROLLBACK.sql');
const rollback257 = read('booking/supabase/rollbacks/20261106220000_booking_257_ROLLBACK.sql');
const messagesJs = read('booking/admin/views/messages.js');
const panelJs = read('booking/admin/views/customer-message-panel.js');
const eventSend = read('booking/supabase/migrations/20261029072745_booking_213_event_johku_capacity.sql');
const trainingMig = read('booking/supabase/migrations/20261106180719_booking_255_training_workspace.sql');
const t258 = read('booking/supabase/tests/t258_customer_message_date_products.sql');

test('paikkamerkit täyttyvät suomenkielisillä avaimilla', () => {
  assert.equal(CUSTOMER_MESSAGE_PLACEHOLDERS.length, 6);
  const filled = fillCustomerMessage(
    'Hei {asiakkaan nimi}, {tuote} {päivämäärä} {kellonaika} ({henkilömäärä}) {tilauslinkki} {tuntematon}',
    {
      tuote: 'Yleinen vuoro, Avoin lahjakortti',
      paivamaara: '16.06.2027',
      kellonaika: '17:00–19:00',
      asiakkaan_nimi: 'Anna Asiakas',
      henkilomaara: '2',
      tilauslinkki: 'https://saunotus.fi/tilaus/?t=abc',
    },
  );
  assert.equal(filled, 'Hei Anna Asiakas, Yleinen vuoro, Avoin lahjakortti 16.06.2027 17:00–19:00 (2) https://saunotus.fi/tilaus/?t=abc {tuntematon}');
  assert.equal(fillCustomerMessage('Klo {kellonaika} hlö {henkilömäärä}', {}), 'Klo  hlö ');
});

test('luonnoksen tarkistus', () => {
  const base = {
    from: '2027-06-16', to: '2027-06-18', productIds: [33, 33, 38],
    subjectFi: 'Hei', bodyFi: 'Teksti', subjectEn: 'Hi', bodyEn: 'Text',
  };
  const ok = validateCustomerMessageDraft(base);
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.value.product_ids, [33, 38]);
  assert.equal(ok.value.to, '2027-06-18');
  assert.equal(validateCustomerMessageDraft({ ...base, to: '' }).value.to, '2027-06-16');
  assert.equal(validateCustomerMessageDraft({ ...base, from: '' }).code, 'invalid_dates');
  assert.equal(validateCustomerMessageDraft({ ...base, to: '2027-06-10' }).code, 'invalid_dates');
  assert.equal(validateCustomerMessageDraft({ ...base, productIds: [] }).code, 'invalid_products');
  assert.equal(validateCustomerMessageDraft({ ...base, subjectEn: '' }).code, 'invalid_text');
  assert.equal(validateCustomerMessageDraft({ ...base, subjectFi: 'x'.repeat(201) }).code, 'invalid_text');
});

test('päivämäärät ja tuotevalinnan karsinta (booking_258)', () => {
  assert.deepEqual(parseCustomerMessageDates('2027-06-16', '').value, { from: '2027-06-16', to: '2027-06-16' });
  assert.deepEqual(parseCustomerMessageDates('2027-06-16', '2027-06-18').value, { from: '2027-06-16', to: '2027-06-18' });
  assert.equal(parseCustomerMessageDates('', '2027-06-16').code, 'invalid_dates');
  assert.equal(parseCustomerMessageDates('2027-06-18', '2027-06-16').code, 'invalid_dates');
  assert.deepEqual(pruneSelectedProductIds([33, 38, 33, 99, 'x', 0], [33, 40]), [33]);
  assert.deepEqual(pruneSelectedProductIds([1, 2], []), []);
  const { cats, grouped } = groupCustomerMessageProducts([
    { id: 2, name: 'B', category: 'event' },
    { id: 1, name: 'A', category: 'event' },
    { id: 3, name: 'C', category: 'gift_card' },
  ]);
  assert.deepEqual(cats, ['event', 'gift_card']);
  assert.deepEqual(grouped.get('event').map((p) => p.id), [1, 2]);
});

test('pending-import-129+130 ja fallback-tekstit täsmäävät', () => {
  const byKeyLang = new Map();
  for (const row of pending) {
    const w = `${row.key} [${row.lang}]`;
    assert.match(row.key, /^ui\.admin\.customer_message\.[a-z0-9_]+$/);
    assert.ok(['fi', 'en'].includes(row.lang), w);
    assert.equal(row.class, 'normal', w);
    assert.equal(row.kind, 'plain', w);
    assert.ok(row.max_len >= row.text.length, w);
    assert.deepEqual(row.placeholders, []);
    byKeyLang.set(`${row.key}|${row.lang}`, row.text);
  }
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(CUSTOMER_MESSAGE_TEXTS[lang])) {
      assert.equal(byKeyLang.get(`${key}|${lang}`), text, `${key} [${lang}]`);
    }
  }
  assert.ok(pending130.some((r) => r.key === 'ui.admin.customer_message.products_empty' && r.lang === 'fi'));
  assert.ok(pending130.some((r) => r.key === 'ui.admin.customer_message.lead_date_products' && r.lang === 'fi'));
  assert.ok(!pending130.some((r) => r.key === 'ui.admin.customer_message.lead'));
  assert.equal(pending129.length, 78);
  assert.equal(pending130.length, 10);
  clearCustomerMessageTextCache();
  assert.equal(customerMessageText('ui.admin.customer_message.tab', 'fi'), 'Viesti asiakkaalle');
  assert.ok(customerMessageText('ui.admin.customer_message.lead_date_products', 'fi').includes('Tuotevalintaan tulevat vain'));
  assert.equal(customerMessageText('ui.admin.customer_message.products_empty', 'fi'), 'Ei varattuja tai myytyjä tuotteita valitulla päivällä tai aikavälillä.');
  assert.equal(customerMessageText('ui.admin.customer_message.products_empty', 'en'), 'No reserved or sold products for the selected day or date range.');
});

test('migraatio 257/258, rollback ja hallinta', () => {
  assert.match(migration257, /booking_257/);
  assert.match(migration257, /create table if not exists booking\.customer_messages/);
  assert.match(migration257, /admin_customer_message_send/);
  assert.match(migration258, /booking_258/);
  assert.match(migration258, /admin_customer_message_products/);
  assert.match(migration258, /p_product_ids is null or r\.product_id = any/);
  assert.match(migration258, /p_product_ids is null or oi\.product_id = any/);
  assert.match(migration258, /_customer_message_hits\(v_from, v_to, null\)/);
  assert.match(migration258, /_require_permission\('messages\.edit'\)/);
  assert.match(migration258, /Europe\/Helsinki/);
  assert.doesNotMatch(migration258, /create or replace function booking\.admin_event_message_send/);
  assert.doesNotMatch(migration258, /admin_customer_message_send/);
  assert.match(rollback258, /drop function if exists booking\.admin_customer_message_products/);
  assert.match(rollback258, /r\.product_id = any \(p_product_ids\)/);
  assert.doesNotMatch(rollback258, /p_product_ids is null/);
  assert.match(rollback257, /drop table if exists booking\.customer_messages/);
  assert.match(eventSend, /create or replace function booking\.admin_event_message_send/);
  assert.match(trainingMig, /admin_training_message_send/);
  assert.match(messagesJs, /currentMessagesTab/);
  assert.match(messagesJs, /renderCustomerMessagePanel/);
  assert.match(panelJs, /data-testid': 'messages-tab-asiakkaalle'/);
  assert.match(panelJs, /admin_customer_message_products/);
  assert.match(panelJs, /admin_customer_message_send/);
  assert.match(panelJs, /productFetchSeq/);
  assert.match(panelJs, /pruneSelectedProductIds/);
  assert.match(panelJs, /products_empty/);
  assert.match(panelJs, /products_need_dates/);
  assert.match(panelJs, /lead_date_products/);
  assert.doesNotMatch(panelJs, /refs\?\.products/);
  assert.doesNotMatch(panelJs, /refs\.products/);
  assert.match(panelJs, /p_confirm: confirmSend/);
  assert.match(t258, /admin_customer_message_products/);
  assert.match(t258, /C1: 16\.6\. vain tuote 33/);
  assert.match(t258, /C5: tyhjä päivä/);
  assert.match(t258, /E1: esikatselu ei jonota/);
  assert.match(read('.github/workflows/pages.yml'), /booking\/tests\/viestit-asiakkaalle\.test\.mjs/);
});
