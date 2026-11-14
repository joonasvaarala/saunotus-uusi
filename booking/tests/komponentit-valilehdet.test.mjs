// YHT-02/03: yhteiset perusosat ja yksi välilehtikomponentti hallinnassa; ryhmän sisällä yksi H1.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');

test('ui.js: emptyState, skeleton, alertBox, pageHead, chip, tabs käyttävät ux-/tl-luokkia', () => {
  const ui = read('booking/admin/ui.js');
  for (const name of ['emptyState', 'skeleton', 'alertBox', 'pageHead', 'chip']) assert.match(ui, new RegExp(`export const ${name} = `));
  assert.match(ui, /export function tabs\(/);
  assert.match(ui, /class: 'ux-empty'/); assert.match(ui, /class: 'ux-skeleton'/); assert.match(ui, /ux-alert ux-alert--\$\{kind\}/);
  assert.match(ui, /ArrowRight: i \+ 1, ArrowLeft: i - 1, Home: 0, End: items\.length - 1/);
  assert.match(ui, /'aria-controls': it\.controls \|\| null/);
});

test('välilehdet: kaikki hallinnan välilehtirivit tulevat tabs()-funktiosta', () => {
  for (const f of ['nav-group', 'talous', 'lahjakortit', 'orders', 'events', 'settings', 'koulutukset', 'customer-message-panel']) {
    const s = read(`booking/admin/views/${f}.js`);
    assert.match(s, /tabs(?: as tabList)? \}? ?from '\.\.\/ui\.js'|, tabs(?: as tabList)?[,}]/, f);
    assert.doesNotMatch(s, /class: '(tl-tabs|set-tabs)[^']*', role: 'tablist'/, f);
    assert.doesNotMatch(s, /tl-tabbtn\$\{/, f);   // ei pelkkää active-luokkaa
  }
  const css = read('booking/admin/admin.css');
  assert.doesNotMatch(css, /\.set-tab\{/);
  assert.match(css, /@media\(max-width:560px\)\{\.tl-tabs\{overflow-x:auto/);
});

test('ryhmän sisällä yksi H1: näkymän sama otsikko poistetaan, muut H2:ksi', () => {
  const ng = read('booking/admin/views/nav-group.js');
  assert.match(ng, /oneH1\(panel, \[heading\.textContent, navText\(selected\.labelKey\)\]\)/);
  assert.match(ng, /export function oneH1/);
});

test('tyylitarkistus: admin.css ei kasvata heksavärien tai asteikon ulkopuolisten fonttikokojen määrää', async () => {
  const { checkAdminCss, BASELINE } = await import('../../scripts/check-admin-css.mjs');
  const r = checkAdminCss(read('booking/admin/admin.css'));
  assert.ok(r.hex <= BASELINE.hex, `hex ${r.hex} > ${BASELINE.hex}`);
  assert.ok(r.size <= BASELINE.size, `size ${r.size} > ${BASELINE.size}`);
  assert.deepEqual(checkAdminCss(':root{--a:#fff}.x{color:#123456;font-size:17px}'), { hex: 1, size: 1 });
});
