// Saapumismerkintä: pallo ilman tekstiä, aria-label + title, tilamerkki "Saapunut", "Ei saapunut" ⋯-valikossa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = (p) => readFileSync(new URL(`../../${p}`, import.meta.url), 'utf8');
const parts = read('booking/admin/views/dayparts.js');
const css = read('booking/admin/admin.css');

test('Saapumispallo: ei näkyvää tekstiä, kiinteä aria-label, title ja aria-pressed', () => {
  assert.doesNotMatch(parts, /ARRIVE_LABEL/);
  assert.doesNotMatch(parts, /arrive-txt/);
  assert.doesNotMatch(parts, /text: 'Saapui'/);
  assert.match(parts, /arriveAriaLabel = \(r\) => `Saapunut, \$\{r\.customer_name/);
  assert.match(parts, /'aria-label': arriveAriaLabel\(r\)/);
  assert.match(parts, /setAttribute\('aria-pressed'/);
  assert.match(parts, /b\.title = on \? 'Saapunut \(paina peruaksesi\)'/);
  // aria-labelia ei vaihdeta tilan mukaan (vain aria-pressed kertoo tilan)
  assert.doesNotMatch(parts, /setAttribute\('aria-label'/);
});
test('CSS: saapumismerkintä on 44 px pallo, merkin väri läpinäkyvä kun ei painettu', () => {
  assert.match(css, /\.arrive\{[^}]*border-radius:50%/);
  assert.match(css, /\.arrive\{[^}]*color:transparent/);
  assert.match(css, /\.arrive\{[^}]*height:44px/);
  assert.match(css, /\.arrive\{[^}]*min-height:44px/);
  assert.doesNotMatch(css, /\.arrive\{[^}]*padding:0 14px/);
});
test('Ei saapunut: ⋯-valikossa, no_show-RPC ja vahvistus tilausnäkymän tekstein', () => {
  assert.match(parts, /overflowMenu\(\[\['noShow'/);
  assert.match(parts, /p_status: 'no_show'/);
  assert.match(parts, /orderText\('ui\.admin\.res\.no_show_text'\)/);
  assert.match(parts, /arrivalActionsAllowed\(r, now\)/);
});
test('Tilamerkki: completed näkyy päivänäkymässä sanalla Saapunut', () => {
  const day = read('booking/admin/views/day.js');
  assert.match(day, /arrivalStatusBadge\(r\.status\)/);
  assert.match(read('booking/admin/ui.js'), /badge\('st-completed', 'Saapunut'\)/);
});
test('Kokeilutilan mock tukee admin_set_reservation_status', () => {
  assert.match(read('booking/admin/options-mock.js'), /admin_set_reservation_status:/);
});
