// Koulutus vaihe 1: linkkituote ei listaudu, kassa laskee loppusumman lisävalinnoista, verkossa vain varausmaksu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { trainingQuote, listedProducts, isTrainingProduct, TRAINING_TEXTS } from '../shop/src/training-signup.js';
import { buildSeries } from '../admin/events-logic.js';

const read = (p) => readFileSync(new URL('../' + p, import.meta.url), 'utf8');

test('loppusumma = kurssihinta + lisät, verkossa vain varausmaksu', () => {
  const q = trainingQuote({
    coursePrice: 1500, deposit: 200,
    offers: [{ code: 'single_room', price: 200, available: true }, { code: 'internship', price: 500, available: true }],
    selected: ['single_room', 'internship'],
  });
  assert.equal(q.base, 1500);
  assert.equal(q.addonsTotal, 700);
  assert.equal(q.total, 2200);
  assert.equal(q.deposit, 200);
  assert.equal(q.payNow, 200);
  assert.equal(q.remaining, 2000);
  assert.equal(q.blocked, null);
});

test('kurssihinta puuttuu: loppusummaa ei keksitä', () => {
  const q = trainingQuote({ coursePrice: null, deposit: 200, offers: [{ code: 'single_room', price: 200, available: true }], selected: ['single_room'] });
  assert.equal(q.total, null);
  assert.equal(q.remaining, null);
  assert.equal(q.payNow, 200);
  assert.equal(q.addonsTotal, 200);
});

test('täysi yhden hengen huone estää valinnan', () => {
  const q = trainingQuote({ coursePrice: 1500, deposit: 200, offers: [{ code: 'single_room', price: 200, available: false }], selected: ['single_room'] });
  assert.equal(q.blocked, 'single_room');
});

test('15 päivän koulutus mahtuu sarjaan, tavallinen tapahtuma ei', () => {
  const long = buildSeries({ category: 'training', dates: '2026-11-30', times: '10:00', duration_minutes: 21600, max_persons: 6, single_room_max: 2 });
  assert.equal(long.ok, true);
  assert.equal(long.patches[0].duration_minutes, 21600);
  assert.equal(long.patches[0].single_room_max, 2);
  assert.equal(long.patches[0].max_persons, 6);
  assert.equal(buildSeries({ category: 'training', dates: '2026-11-30', times: '10:00', duration_minutes: 120, max_persons: 7 }).error, 'bad_max');
  assert.equal(buildSeries({ dates: '2026-11-30', times: '10:00', duration_minutes: 21600 }).error, 'bad_duration');
});

test('listed:false ei jää listaan', () => {
  const rows = listedProducts([{ id: 1, slug: 'a' }, { id: 2, slug: 'sauna-healing', listed: false }, { id: 3, listed: true }]);
  assert.deepEqual(rows.map((p) => p.id), [1, 3]);
  assert.equal(isTrainingProduct({ category: 'training' }), true);
  assert.equal(isTrainingProduct({ deposit: true }), true);
});

test('kauppa hakee suoran linkin eikä näytä linkkituotetta listoissa', () => {
  const shop = read('shop/src/shop.js');
  assert.match(shop, /public_product_by_slug/);
  assert.match(shop, /listedProducts\(/);
  assert.match(shop, /isTrainingProduct\(p\)\) return trainingSignup/);
  const form = read('shop/src/training-signup.js');
  assert.match(form, /public_create_training_signup/);
  assert.doesNotMatch(form, /Montonio|montonio/i);
});

test('vahvistusviesti ei lupaa koko kurssin maksua', () => {
  const texts = read('../booking/supabase/functions/send-emails/texts.ts');
  assert.match(texts, /Kurssia ei ole maksettu kokonaan/);
  assert.match(texts, /Loppusumma laskutetaan myöhemmin/);
  assert.match(read('../booking/supabase/functions/send-emails/templates.ts'), /email\.training\.intro/);
});

test('tekstit FI ja EN, ei kulmasulkeita', () => {
  for (const lang of ['fi', 'en']) {
    for (const [k, v] of Object.entries(TRAINING_TEXTS[lang])) {
      assert.equal(typeof v, 'string', k);
      assert.doesNotMatch(v, /</);
    }
  }
  const raw = readFileSync(new URL('../../content/site-texts.pending-import-114.json', import.meta.url), 'utf8');
  assert.doesNotMatch(raw, /</);
  const rows = JSON.parse(raw);
  assert.ok(rows.some((r) => r.key === 'admin.events.channel_link' && r.lang === 'fi'));
  assert.ok(rows.some((r) => r.key === 'ui.shop.training.balance_later' && r.lang === 'en'));
});
