// node --test booking/tests/viestit-asiakkaalle.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');

const { fillCustomerMessage, validateCustomerMessageDraft, CUSTOMER_MESSAGE_PLACEHOLDERS } = await import(
  pathToFileURL(join(root, 'booking/admin/customer-message-logic.js')).href
);
const { CUSTOMER_MESSAGE_TEXTS, customerMessageText, clearCustomerMessageTextCache } = await import(
  pathToFileURL(join(root, 'booking/admin/customer-message-texts.js')).href
);

const pending = JSON.parse(read('content/site-texts.pending-import-129.json'));
const migration = read('booking/supabase/migrations/20261106220000_booking_257_customer_message.sql');
const rollback = read('booking/supabase/rollbacks/20261106220000_booking_257_ROLLBACK.sql');
const messagesJs = read('booking/admin/views/messages.js');
const panelJs = read('booking/admin/views/customer-message-panel.js');
const eventSend = read('booking/supabase/migrations/20261029072745_booking_213_event_johku_capacity.sql');
const trainingMig = read('booking/supabase/migrations/20261106180719_booking_255_training_workspace.sql');

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

test('pending-import-129 ja fallback-tekstit täsmäävät', () => {
  const seen = new Set();
  assert.equal(pending.length, Object.keys(CUSTOMER_MESSAGE_TEXTS.fi).length * 2);
  for (const row of pending) {
    const w = `${row.key} [${row.lang}]`;
    assert.match(row.key, /^ui\.admin\.customer_message\.[a-z0-9_]+$/);
    assert.ok(['fi', 'en'].includes(row.lang), w);
    assert.equal(row.class, 'normal', w);
    assert.equal(row.kind, 'plain', w);
    assert.ok(row.max_len >= row.text.length, w);
    assert.equal(CUSTOMER_MESSAGE_TEXTS[row.lang][row.key], row.text, w);
    assert.ok(!seen.has(`${row.key}|${row.lang}`), w);
    seen.add(`${row.key}|${row.lang}`);
    assert.deepEqual(row.placeholders, []);
  }
  clearCustomerMessageTextCache();
  assert.equal(customerMessageText('ui.admin.customer_message.tab', 'fi'), 'Viesti asiakkaalle');
  assert.equal(customerMessageText('ui.admin.customer_message.tab', 'en'), 'Message to customer');
});

test('migraatio, rollback ja hallinta', () => {
  assert.match(migration, /booking_257/);
  assert.match(migration, /create table if not exists booking\.customer_messages/);
  assert.match(migration, /admin_customer_message_send/);
  assert.match(migration, /admin_customer_messages_list/);
  assert.match(migration, /_require_permission\('messages\.edit'\)/);
  assert.match(migration, /_event_message_blocked/);
  assert.match(migration, /_enqueue_email\('event_message'/);
  assert.match(migration, /too_many/);
  assert.match(migration, /o\.external_source is null/);
  assert.match(migration, /anonymized_at is null/);
  assert.match(migration, /Europe\/Helsinki/);
  assert.match(migration, /paid_at/);
  assert.match(migration, /\{päivämäärä\}/);
  assert.match(migration, /\{tilauslinkki\}/);
  assert.match(migration, /site_base_url/);
  assert.match(migration, /order_page_path/);
  assert.doesNotMatch(migration, /create or replace function booking\.admin_event_message_send/);
  assert.doesNotMatch(migration, /create or replace function booking\.admin_training_message_send/);
  assert.doesNotMatch(migration, /admin_event_message_send\(/);
  assert.match(rollback, /drop table if exists booking\.customer_messages/);
  assert.match(rollback, /admin_customer_message_send/);
  assert.doesNotMatch(rollback, /admin_event_message_send/);
  assert.match(eventSend, /create or replace function booking\.admin_event_message_send/);
  assert.match(trainingMig, /admin_training_message_send/);
  assert.match(messagesJs, /currentMessagesTab/);
  assert.match(messagesJs, /renderCustomerMessagePanel/);
  assert.match(messagesJs, /messagesTabBar/);
  assert.match(messagesJs, /Näytä ohjeet/);
  assert.match(panelJs, /data-testid': 'messages-tab-asiakkaalle'/);
  assert.match(panelJs, /admin_customer_message_send/);
  assert.match(panelJs, /p_confirm: confirmSend/);
  assert.match(panelJs, /customer-message-subject-\$\{lang\}/);
  assert.match(read('.github/workflows/pages.yml'), /booking\/tests\/viestit-asiakkaalle\.test\.mjs/);
});
