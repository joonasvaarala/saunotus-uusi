// UX-analyysin vaihe 0: KAUPPA-TILAUS-01 (laskulla maksava yritys ei näe maksutoimintoja), HALL-TILAUS-03 (maksulinkki lähtee oletuksena,
// kun osoite on), KAUPPA-SELAUS-01 (päiväkortin ote ei toista tuotteen nimeä).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { paymentLinkEmail, paymentLinkOutcome } from '../admin/payment-link-logic.js';
import { dayCardExcerpt } from '../shop/src/short-desc.js';
import { TEXTS } from '../admin/talous-texts.js';

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');

test('KAUPPA-TILAUS-01: laskulla maksavalle ei maksunappia, paikan päällä -tekstiä eikä lahjakortin lunastusta', () => {
  const s = read('shop/src/order.js');
  assert.match(s, /import \{ paysByInvoice \} from '\.\/company-pay\.js';/);
  assert.match(s, /const byInvoice = !inv\.locked && paysByInvoice\(o\);/);
  assert.match(s, /: byInvoice \? \(/);
  assert.match(s, /'data-testid': 'invoice-method-pay-note'/);
  assert.match(s, /const giftUse = !inv\.locked && !byInvoice && gift\.redeem/);
});

test('HALL-TILAUS-03: vastaanottaja, tulosilmoitus ja molemmat dialogit', () => {
  assert.equal(paymentLinkEmail({ customer: { email: ' a@b.fi ' } }), 'a@b.fi');
  assert.equal(paymentLinkEmail({ email: 'x@y.com' }), 'x@y.com');
  assert.equal(paymentLinkEmail({ customer: { email: '' } }), null);
  assert.equal(paymentLinkEmail({ customer: { email: 'ei-osoite' } }), null);
  assert.equal(paymentLinkEmail(null), null);
  assert.deepEqual(paymentLinkOutcome({ email_queued: true }, true), { key: 'link.sentTo', tone: 'ok' });
  assert.deepEqual(paymentLinkOutcome({ email_queued: false }, true), { key: 'link.sendFailed', tone: 'warn' });
  assert.deepEqual(paymentLinkOutcome({}, false), { key: 'link.createdOnly', tone: 'ok' });
  for (const l of ['fi', 'en']) for (const k of ['link.emailTo', 'link.noEmail', 'link.send', 'link.sentTo', 'link.sendFailed', 'link.createdOnly']) assert.ok(TEXTS[l][k], `${l} ${k}`);
  assert.match(TEXTS.fi['link.emailTo'], /\{email\}/);
  const ui = read('admin/views/talous-ui.js');
  assert.match(ui, /export function linkEmailControl\(order\)/);
  assert.match(ui, /name: 'email', checked: true/);
  for (const f of ['admin/views/talous-orders.js', 'admin/views/order-add.js']) {
    const s = read(f);
    assert.match(s, /linkEmailControl\((o|order)\)/, f);
    assert.match(s, /mail\.submit/, f);
    assert.match(s, /mail\.report\(/, f);
  }
});

test('KAUPPA-SELAUS-01: päiväkortin ote ilman alun otsikkoa ja ilman kahdesti toistuvaa nimeä', () => {
  const desc = '<h2>Saunahoito</h2><p>Saunahoito on lempeä hoito, jossa saunottaja hoitaa sinua vihdoin ja hunajalla pitkään ja hartaasti.</p>';
  const x = dayCardExcerpt({}, 'fi', desc, 'Saunahoito');
  assert.ok(!x.startsWith('Saunahoito Saunahoito'), x);
  assert.ok(x.startsWith('Saunahoito on lempeä'), x);
  assert.ok(x.length <= 91 && x.endsWith('…'), x);
  assert.equal(dayCardExcerpt({ short_description: '<p>Lyhyt <b>kuvaus</b></p>' }, 'fi', desc, 'Saunahoito'), 'Lyhyt kuvaus');
  assert.equal(dayCardExcerpt({ short_description: 'FI', short_description_en: 'EN' }, 'en', '', 'X'), 'EN');
  assert.equal(dayCardExcerpt({}, 'fi', 'Saunotus Saunotus on rituaali', 'Saunotus'), 'Saunotus on rituaali');
  assert.equal(dayCardExcerpt({}, 'fi', '', 'X'), '');
  assert.match(read('shop/src/shop.js'), /const short = dayCardExcerpt\(p, S\.lang, pdesc\(p\) \|\| '', pname\(p\)\);/);
});
