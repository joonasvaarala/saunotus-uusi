// KAUPPA-DIALOGI-01: kaupan ja tilaussivun peruutusvahvistus sivuston omassa dialogissa (ei selaimen confirm()-ikkunaa), tekstit tuonnista 152.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { T } from '../shop/src/i18n.js';
import { OT } from '../shop/src/order-texts.js';
import { siteConfirm } from '../shop/src/site-confirm.js';

const rd = (f) => readFileSync(new URL(`../../${f}`, import.meta.url), 'utf8');
const code = (f) => rd(f).replace(/^\s*\/\/.*$/gm, '');

test('kauppa ja tilaussivu: ei selaimen confirm()-kutsuja, peruutus kysyy siteConfirm-dialogilla', () => {
  for (const f of ['booking/shop/src/shop.js', 'booking/shop/src/order.js']) {
    const s = code(f);
    assert.doesNotMatch(s, /[^.\w]confirm\(/, f);
    assert.match(s, /import \{ siteConfirm \} from '\.\/site-confirm\.js';/, f);
    assert.match(s, /await siteConfirm\(t\.cancelConfirm, \{ yes: t\.cancel(Booking|Submit), no: t\.dialogBack/, f);
  }
});
test('tekstit FI+EN: dialogBack sanakirjoissa ja tuontitiedostossa 152 samalla tekstillä', () => {
  const rows = JSON.parse(rd('content/site-texts.pending-import-152.json'));
  const want = { 'ui.shop.dialog_back': [T.fi.dialogBack, T.en.dialogBack], 'ui.order.dialog_back': [OT.fi.dialogBack, OT.en.dialogBack] };
  assert.equal(rows.length, 4);
  for (const [k, [fi, en]] of Object.entries(want)) {
    assert.equal(rows.find((r) => r.key === k && r.lang === 'fi')?.text, fi);
    assert.equal(rows.find((r) => r.key === k && r.lang === 'en')?.text, en);
  }
  assert.ok(!JSON.stringify(rows).includes('REDACTED'));
});
test('siteConfirm: ilman <dialog>-tukea käytetään selaimen confirm()-varaa', async () => {
  const prev = globalThis.confirm; let asked = null;
  globalThis.confirm = (m) => { asked = m; return true; };
  try { assert.equal(await siteConfirm('Perutaanko?', { yes: 'Kyllä', no: 'Takaisin', doc: { createElement: () => ({}) } }), true); } finally { globalThis.confirm = prev; }
  assert.equal(asked, 'Perutaanko?');
});
test('dialogin tyylit: kosketuskohde ≥44 px, sivuston värimuuttujat', () => {
  const css = rd('booking/shop/src/shop.css');
  assert.match(css, /dialog\.bk-dialog\{[^}]*var\(--ink\)/);
  assert.match(css, /\.bk-dialog-actions \.btn\{min-height:44px/);
});
