// UX-katsaus 28.10.2026: kaupan viimeistely (maksutavat, peruttu varaus, korttilinkki, lahjakortti, vuorolista).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { visibleWaitlistSlots } from '../shop/src/waitlist-logic.js';
import { clockFromIso, clockFromHm, clockRange } from '../shop/src/clock.js';
import { T } from '../shop/src/i18n.js';
import { GT } from '../shop/src/gift-texts.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(resolve(root, p), 'utf8');
const shop = read('booking/shop/src/shop.js');
const order = read('booking/shop/src/order.js');
const redeem = read('booking/shop/src/order-gift.js');
const pending = JSON.parse(read('content/site-texts.pending-import-1028.json'));

test('vuorot järjestyvät alkamisajan mukaan ja loppuunmyyty jää paikalleen', () => {
  const rows = [
    { rule_id: 1, status: 'available', starts_at: '2026-10-31T14:00:00Z' },
    { rule_id: 2, status: 'full', starts_at: '2026-10-31T13:00:00Z' },
    { rule_id: 3, status: 'available', starts_at: '2026-10-31T14:30:00Z' },
    { rule_id: 4, status: 'unavailable', starts_at: '2026-10-31T12:00:00Z' },
  ];
  assert.deepEqual(visibleWaitlistSlots(rows).map((x) => x.rule_id), [2, 1, 3]);
});

test('kellonaika on aina minuutteineen', () => {
  assert.equal(clockFromIso('2026-07-15T13:30:00Z', 'fi'), '16.30');
  assert.equal(clockFromIso('2026-07-15T13:00:00Z', 'fi'), '16.00');
  assert.equal(clockRange('2026-07-15T13:30:00Z', '2026-07-15T15:30:00Z', 'fi'), '16.30–18.30');
  assert.equal(clockFromHm('16:30', 'en'), '16:30');
  assert.equal(clockFromHm('09:00', 'fi'), '9.00');
  assert.match(shop, /clockFromIso\(iso, S\.lang\)/);
});

test('vahvistussivu ei näytä viestipalvelun keskeneräisyyslausetta ja maksamaton peruutus saa yrityspainikkeen', () => {
  assert.doesNotMatch(shop, /text: t\.emailNote/);
  assert.match(shop, /data-testid': 'conf-unpaid'/);
  assert.match(shop, /data-testid': 'conf-retry'/);
  assert.equal(T.fi.unpaidCancel, 'Varausta ei vahvistettu, koska maksua ei suoritettu.');
  assert.equal(T.en.tryAgain, 'Try again');
  assert.equal(T.fi.tr.continueSummary, 'Jatka yhteenvetoon');
  assert.equal(T.en.tr.continueSummary, 'Continue to summary');
});

test('tuotekortti on yksi linkki', () => {
  assert.match(shop, /cardAnchor\(h, bk\(`\/tuote\/\$\{p\.slug\}`\)/);
  assert.match(read('booking/shop/src/treatment-ui.js'), /cardAnchor\(h, bk\(`\/tuote\/\$\{p\.slug\}`\)/);
  assert.match(read('booking/shop/src/card-link.js'), /querySelectorAll\('a'\)/);
});

test('kassa näyttää info-sivun peruutuslauseen ehtoruudun yläpuolella', () => {
  assert.match(shop, /checkout-cancel-rule/);
  assert.match(read('booking/shop/build.mjs'), /page\.info\.cancel_text/);
  assert.match(read('booking/shop/src/treatment-ui.js'), /legalFields\(\{ showCancel: true \}\)/);
});

test('lahjakortin summakenttää ei kysytä ja tilaussivun hoitolista on pois', () => {
  assert.doesNotMatch(redeem, /gc-amount/);
  assert.equal(GT.fi['o.amount'], undefined);
  assert.equal(GT.en['o.amountHint'], undefined);
  assert.match(redeem, /resolveCode\(\{ api, token, code: code\.value \}\)/);
  assert.doesNotMatch(order, /upsell-treatments|treatLead/);
  assert.match(order, /addNewBooking/);
  assert.match(read('booking/shop/src/gift.js'), /gc-payline/);
  assert.match(read('booking/shop/src/gift.js'), /gift-card-\$\{L\}\.webp/);
});

test('maksutapojen merkit ovat jaetussa kansiossa eikä välittäjän nimeä näytetä', () => {
  for (const f of ['apple-pay.svg', 'google-pay.svg', 'mobilepay.svg', 'bank.svg', 'card.svg']) {
    assert.ok(read(`public/img/pay/${f}`).includes('<svg'), f);
  }
  const ui = read('booking/shop/src/online-pay-ui.js');
  assert.match(ui, /apple-pay\.svg/);
  assert.match(ui, /google-pay\.svg/);
  assert.match(ui, /mobilepay\.svg/);
  assert.doesNotMatch(ui, /Montonio|montonio/);
  assert.match(read('src/render.mjs'), /img\/pay\/\$\{id\}\.svg/);
  assert.match(read('src/render.mjs'), /footerPayOnline/);
});

test('tuontitiedosto sisältää uudet FI- ja EN-tekstit', () => {
  const keys = ['ui.shop.unpaid_cancel', 'ui.shop.try_again', 'ui.treatment.continue_summary', 'ui.gift.pay_line', 'ui.gift.preview_alt', 'ui.footer.pay_online', 'page.gift.own.how', 'page.gift.third.pay'];
  for (const key of keys) for (const lang of ['fi', 'en']) {
    const row = pending.find((r) => r.key === key && r.lang === lang);
    assert.ok(row && row.text && row.class === 'normal', `${key} ${lang}`);
  }
  const gift = JSON.parse(read('content/pages/gift.json'));
  assert.match(gift.fi.own.how, /Lahjakortin koodi/);
  assert.doesNotMatch(gift.fi.own.how, /käytä koodia/);
  assert.match(gift.en.own.how, /Gift card code/);
  assert.match(gift.fi.third.pay, /maksuvaiheessa/);
});
