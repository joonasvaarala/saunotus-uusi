// HALL-PAIVA-04: päivänäkymän hiljainen päivitys + tulostettava päivälista.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DAY_REFRESH_MS, canAutoRefresh, clockLabel, isEditingElement, isStale, startDayAutoRefresh } from '../admin/day-refresh.js';
import { DAY_TEXTS } from '../admin/day-texts.js';

const root = dirname(fileURLToPath(import.meta.url));
const read = (p) => readFileSync(join(root, p), 'utf8');
const ok = { hidden: false, onDayRoute: true, busy: false, printing: false, dialogOpen: false, editing: false, pendingAction: false };

test('intervalli on 60 s', () => assert.equal(DAY_REFRESH_MS, 60000));

test('canAutoRefresh: vain näkyvä Päivä-näkymä ilman kesken olevaa toimintoa', () => {
  assert.equal(canAutoRefresh(ok), true);
  for (const k of ['hidden', 'busy', 'printing', 'dialogOpen', 'editing', 'pendingAction']) assert.equal(canAutoRefresh({ ...ok, [k]: true }), false, k);
  assert.equal(canAutoRefresh({ ...ok, onDayRoute: false }), false);
  assert.equal(canAutoRefresh(null), false);
});

test('isEditingElement: kentät kyllä, painikkeet ja päivävalitsin-lähtöiset eivät', () => {
  assert.equal(isEditingElement({ tagName: 'TEXTAREA' }), true);
  assert.equal(isEditingElement({ tagName: 'SELECT' }), true);
  assert.equal(isEditingElement({ tagName: 'INPUT', type: 'text' }), true);
  assert.equal(isEditingElement({ tagName: 'INPUT', type: 'checkbox' }), false);
  assert.equal(isEditingElement({ tagName: 'BUTTON' }), false);
  assert.equal(isEditingElement(null), false);
});

test('clockLabel: Helsingin kello pisteellä, aina kaksi numeroa', () => {
  assert.equal(clockLabel(new Date('2026-11-14T12:05:00Z')), '14.05');
  assert.equal(clockLabel(new Date('2026-07-01T06:07:00Z')), '09.07');
  assert.equal(clockLabel(new Date('2026-11-14T22:30:00Z')), '00.30');
});

test('isStale', () => {
  assert.equal(isStale(0, 59999), false);
  assert.equal(isStale(0, 60000), true);
});

test('ajastin päivittää minuutin välein, ei piilossa eikä päällekkäin', async () => {
  let t = 1000, calls = 0, hidden = false, release;
  const listeners = {};
  const doc = { get hidden() { return hidden; }, addEventListener: (n, f) => { listeners[n] = f; }, removeEventListener() {} };
  const c = startDayAutoRefresh({ doc, ms: 20, now: () => t, state: () => ({ onDayRoute: true }), refresh: () => { calls++; return new Promise((r) => { release = r; }); } });
  t += 5000; await new Promise((r) => setTimeout(r, 50));
  assert.equal(calls, 1);                      // käynnistyi
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(calls, 1);                      // edellinen kesken: ei päällekkäin
  release(); await new Promise((r) => setTimeout(r, 5));
  hidden = true; t += 5000; await new Promise((r) => setTimeout(r, 50));
  assert.equal(calls, 1);                      // piilossa: ei päivitystä
  hidden = false; listeners.visibilitychange(); await new Promise((r) => setTimeout(r, 5));
  assert.equal(calls, 2);                      // näkyviin palatessa heti, koska vanhentunut
  release(); c.stop();
});

test('virhe päivityksessä ei kaada ajastinta', async () => {
  let t = 0, calls = 0;
  const c = startDayAutoRefresh({ doc: { hidden: false, addEventListener() {}, removeEventListener() {} }, ms: 10, now: () => (t += 100000), state: () => ({ onDayRoute: true }), refresh: async () => { calls++; throw new Error('x'); } });
  await new Promise((r) => setTimeout(r, 60)); c.stop();
  assert.ok(calls >= 2);
});

test('tekstit: FI+EN-sanakirja ja tuontitiedosto 157 vastaavat toisiaan', () => {
  const rows = JSON.parse(read('../../content/site-texts.pending-import-157.json'));
  const keys = Object.keys(DAY_TEXTS.fi).filter((k) => /updated_at|print_/.test(k));
  assert.equal(keys.length, 10);
  for (const k of keys) {
    assert.ok(DAY_TEXTS.en[k], `EN puuttuu: ${k}`);
    for (const lang of ['fi', 'en']) {
      const r = rows.find((x) => x.key === k && x.lang === lang);
      assert.ok(r, `${k} ${lang}`);
      assert.equal(r.text, DAY_TEXTS[lang][k]);
    }
  }
  assert.equal(rows.length, keys.length * 2);
});

test('johdotus: day.js, admin.js ja tulostustyyli', () => {
  const day = read('../admin/views/day.js'), admin = read('../admin/admin.js'), css = read('../admin/admin.css');
  assert.match(day, /data-testid': 'print-day'/);
  assert.match(day, /data-testid': 'day-updated'/);
  assert.match(day, /class: 'day-print'/);
  assert.match(admin, /startDayAutoRefresh/);
  assert.match(admin, /refreshDaySilently/);
  assert.match(css, /size:A4/);
  assert.match(css, /#view>\*:not\(\.day-print\)/);
});
