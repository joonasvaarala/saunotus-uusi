// HALL-ASETUKSET-01: yksi tallennuspalkki (muutoslaskuri), siirretyt kortit ja Järjestelmä-välilehden rajaus. Ei verkkoa eikä tietokantaa.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { diffCount, dirtySections, validateSection } from '../admin/settings-logic.js';
import { SETTINGS_TEXTS } from '../admin/settings-texts.js';

const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');
const pending167 = JSON.parse(read('../../content/site-texts.pending-import-167.json'));

test('diffCount laskee muuttuneet kentät, myös sisäkkäiset', () => {
  assert.equal(diffCount({ a: 1, b: 2 }, { a: 1, b: 2 }), 0);
  assert.equal(diffCount({ a: 1, b: 2 }, { a: 1, b: 3 }), 1);
  assert.equal(diffCount({ seller: { name: 'A', city: 'X' }, n: 'k' }, { seller: { name: 'B', city: 'Y' }, n: 'k' }), 2);
  assert.equal(diffCount({ methods: { card_terminal: true } }, { methods: { card_terminal: false } }), 1);
  assert.equal(diffCount({ a: null }, { a: null }), 0);
  assert.equal(diffCount({ a: 1 }, { a: 1, b: 2 }), 1);
});

test('dirtySections: vain muuttuneet osiot ja kenttien summa', () => {
  const res = dirtySections([
    { id: 'pause', base: { public_booking_enabled: true }, now: { public_booking_enabled: false } },
    { id: 'invoice', base: { invoice_due_days: 14, iban: '' }, now: { invoice_due_days: 14, iban: '' } },
    { id: 'booking_window', base: { booking_horizon_days: 90, public_treatment_horizon_days: 30 }, now: { booking_horizon_days: 120, public_treatment_horizon_days: 45 } },
  ]);
  assert.deepEqual(res.dirty, ['pause', 'booking_window']);
  assert.equal(res.count, 3);
  assert.deepEqual(dirtySections([]), { dirty: [], count: 0 });
  assert.deepEqual(dirtySections(null), { dirty: [], count: 0 });
});

test('muuttuneen osion arvo tarkistetaan samalla validoinnilla kuin ennen', () => {
  assert.equal(validateSection('pause', { public_booking_enabled: false }).ok, true);
  assert.equal(validateSection('invoice', { invoice_due_days: 0, iban: '', bic: '', name: '' }).ok, false);
});

test('Asetukset-näkymä: pitoajat vain pidä-kunnes-maksettu -tilassa, Järjestelmä-osiot kiinni, ei vanhoja tilakortteja', () => {
  const src = read('../admin/views/settings.js');
  assert.match(src, /holdMode\s*\?/);
  assert.match(src, /if \(holdMode\)/);
  assert.match(src, /hold_until_paid/);
  assert.equal(src.includes("badge('', tx('mode_off'))"), false, 'Saunabotin tila ei ole kovakoodattu');
  assert.equal(src.includes("saveBar("), false, 'korttikohtaiset tallennuspainikkeet poistettu');
  assert.match(src, /createSaveBar/);
  const widgets = read('../admin/settings-widgets.js');
  assert.match(widgets, /class: 'card set-fold'/);
  assert.equal(/open: open \|\| null/.test(widgets), true);
  // Siirretyt kortit
  assert.equal(src.includes('mailPanel'), false);
  assert.equal(src.includes('giftPanel'), false);
  assert.equal(src.includes('renderQrPanel'), false);
  assert.match(read('../admin/views/messages.js'), /mailSettingsPanel/);
  assert.match(read('../admin/views/lahjakortit.js'), /giftSettingsPanel/);
  assert.match(read('../admin/views/products.js'), /renderQrPanel/);
  const cards = read('../admin/settings-cards.js');
  for (const section of ['email_sender', 'email_staff', 'gift_own', 'gift_partner']) assert.match(cards, new RegExp(`'${section}'`));
});

test('pending-import-167: FI+EN, vastaa sanakirjoja, ei paikkamerkkejä', () => {
  assert.ok(pending167.length >= 2);
  assert.equal(pending167.length % 2, 0);
  const seen = new Set();
  for (const row of pending167) {
    assert.ok(row.lang === 'fi' || row.lang === 'en');
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.equal(row.text.trim(), row.text);
    assert.ok(row.max_len >= row.text.length);
    assert.equal(/https?:|www\./i.test(row.text), false);
    assert.equal(seen.has(`${row.key}|${row.lang}`), false);
    seen.add(`${row.key}|${row.lang}`);
    if (row.key.startsWith('ui.admin.settings.') || row.key.startsWith('ui.admin.qr.')) assert.equal(SETTINGS_TEXTS[row.lang][row.key], row.text, row.key);
  }
  for (const key of pending167.map((r) => r.key)) {
    assert.ok(seen.has(`${key}|fi`) && seen.has(`${key}|en`), key);
  }
});
