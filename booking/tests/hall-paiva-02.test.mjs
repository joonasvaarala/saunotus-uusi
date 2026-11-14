// HALL-PAIVA-02: Saapui-painike näkyvä, kiinteä aria-label, tilamerkki "Saapunut", "Ei saapunut" ⋯-valikossa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = (p) => readFileSync(new URL(`../../${p}`, import.meta.url), 'utf8');
const parts = read('booking/admin/views/dayparts.js');
const css = read('booking/admin/admin.css');

test('Saapui-painike: näkyvä teksti, kiinteä aria-label ja aria-pressed', () => {
  assert.match(parts, /ARRIVE_LABEL = 'Saapui'/);
  assert.match(parts, /arriveAriaLabel = \(r\) => `Saapunut, \$\{r\.customer_name/);
  assert.match(parts, /'aria-label': arriveAriaLabel\(r\)/);
  assert.match(parts, /setAttribute\('aria-pressed'/);
  // aria-labelia ei vaihdeta tilan mukaan (vain aria-pressed kertoo tilan)
  assert.doesNotMatch(parts, /setAttribute\('aria-label'/);
});
test('CSS: Saapui-painike ei ole läpinäkyvä ympyrä', () => {
  assert.doesNotMatch(css, /\.arrive\{[^}]*color:transparent/);
  assert.match(css, /\.arrive\{[^}]*min-height:44px/);
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
