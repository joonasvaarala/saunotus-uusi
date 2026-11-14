// KAUPPA-VAHVISTUS-01: vahvistussivulla jokaisessa tilassa yksi otsikko, yksi tilamerkki ja yksi päätoiminto; vahvistetusta tilasta yksi klikkaus tilaussivulle.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { confirmPageKind, showsThanksHeading, primaryAction, orderPageHref } from '../shop/src/confirm-heading.js';
import { T } from '../shop/src/i18n.js';

const rd = (f) => readFileSync(new URL(`../../${f}`, import.meta.url), 'utf8');
const code = (f) => rd(f).replace(/^\s*\/\/.*$/gm, '');

test('päätoiminto tilan mukaan: maksu / Hallitse varausta / Yritä uudelleen tai Tee uusi varaus', () => {
  assert.equal(primaryAction('finish'), 'pay');
  assert.equal(primaryAction('confirmed'), 'manage');
  assert.equal(primaryAction('preliminary'), 'manage');
  assert.equal(primaryAction('expired', { hasRetry: true }), 'retry');
  assert.equal(primaryAction('expired'), 'new');
  assert.equal(primaryAction('cancelled', { hasRetry: true }), 'retry');
  assert.equal(primaryAction('cancelled'), 'new');
  assert.equal(primaryAction('missing'), null);
});
test('jokaisella tilalla täsmälleen yksi päätoiminto (ei kahta kilpailevaa)', () => {
  const cases = [
    [{ status: 'pending' }, { awaiting: true }, 'finish'],
    [{ status: 'confirmed' }, { confirmed: true }, 'confirmed'],
    [{ status: 'expired' }, { expired: true }, 'expired'],
    [{ status: 'cancelled' }, { cancelled: true }, 'cancelled'],
  ];
  for (const [b, co, kind] of cases) {
    assert.equal(confirmPageKind(b, co, false), kind);
    assert.ok(primaryAction(kind, { hasRetry: kind === 'expired' || kind === 'cancelled' }), kind);
  }
});
test('kiitos-otsikko vain vahvistetussa tilassa (muualla H1 + tilamerkki riittävät)', () => {
  assert.equal(showsThanksHeading('confirmed'), true);
  for (const k of ['finish', 'expired', 'cancelled', 'preliminary']) assert.equal(showsThanksHeading(k), false, k);
});
test('tilaussivun osoite: sama token, kieli ja kokeilutila säilyvät', () => {
  const tok = '11111111-2222-3333-4444-555555555555';
  assert.equal(orderPageHref({ token: tok }), `/tilaus/?t=${tok}`);
  assert.equal(orderPageHref({ token: tok, lang: 'en' }), `/en/order/?t=${tok}`);
  assert.equal(orderPageHref({ token: tok, lang: 'en', orderHref: { fi: '/tilaus/', en: '/en/order/' }, mock: true }), `/en/order/?t=${tok}&mock=1`);
});
test('vahvistussivu: Hallitse varausta -painike, ei toistavaa H2:ta, ei confirm()-ikkunaa, peruutuksen virheenkäsittely', () => {
  const s = code('booking/shop/src/shop.js');
  assert.match(s, /'data-testid': 'conf-manage', href: orderHref, text: t\.manageBooking/);
  assert.doesNotMatch(s, /h2\.awaiting/);
  assert.doesNotMatch(s, /[^.\w]confirm\(/);
  assert.match(s, /try \{ r = await rpc\('public_cancel_booking'/);
  assert.match(s, /showNew: !unpaidEnd, titleVisible: false/);
  assert.match(s, /class: 'btn gold', 'data-testid': 'conf-retry'/);
  assert.match(s, /'data-testid': 'conf-email-sent'/);
  // muutos-painike toissijainen (yksi kulta)
  assert.match(s, /class: 'btn light', href: `#\$\{token\}\/muuta`/);
});
test('vahvistussivun peruutusohje ohjaa tilaussivulle, ei pelkkään sähköpostiin', () => {
  assert.doesNotMatch(T.fi.confCancelHint, /sähköposti/i);
  assert.match(T.fi.confCancelHint, /Hallitse varausta/);
  assert.match(T.en.confCancelHint, /Manage booking/);
  assert.equal(T.fi.manageBooking, 'Hallitse varausta');
  assert.equal(T.en.manageBooking, 'Manage booking');
});
test('tekstit FI+EN: tuonti 168 = koodin oletukset', () => {
  const rows = JSON.parse(rd('content/site-texts.pending-import-168.json'));
  const want = { manage_booking: 'manageBooking', conf_email_sent: 'confEmailSent', new_booking: 'newBooking', conf_change: 'confChange', conf_change_locked: 'confChangeLocked', conf_cancel_hint: 'confCancelHint', conf_cancel_hint_locked: 'confCancelHintLocked' };
  assert.equal(rows.length, Object.keys(want).length * 2);
  for (const [k, p] of Object.entries(want)) for (const lang of ['fi', 'en']) {
    const r = rows.find((x) => x.key === `ui.shop.${k}` && x.lang === lang);
    assert.equal(r?.text, T[lang][p].replace(/\{(\w+)\}/g, '{{var:$1}}'), `${k} ${lang}`);
  }
  assert.ok(!/REDACTED|<|[\u{1F300}-\u{1FAFF}]/u.test(JSON.stringify(rows)));
});
test('hold-ui: otsikko voidaan piilottaa ja uusi-varaus-linkki jättää pois (shop antaa oman päätoiminnon)', () => {
  const s = rd('booking/shop/src/hold-ui.js');
  assert.match(s, /showNew = true, titleVisible = true/);
  assert.match(s, /if \(showNew\) kids\.push/);
});
