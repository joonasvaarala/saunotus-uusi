// Audit 28.10.2026: kielenvaihto, vahvistusotsikko, saapumisaika, tapahtumavuosi, ehtojen virke.
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { otherPageHref } from '../shop/src/lang-switch.js';
import { confirmPageKind } from '../shop/src/confirm-heading.js';
import { fixArrivalPhrase, fixSwimwearPhrase } from '../shop/src/arrival-phrase.js';
import { dayLabel } from '../shop/src/event-date.js';
import { swimwearKey } from '../shop/src/product-layout.js';

const NOW = Date.parse('2026-10-28T12:00:00Z');

test('kielenvaihto säilyttää tuotteen, päivän ja tilauksen', () => {
  assert.equal(otherPageHref('/en/book/', { search: '', hash: '#/tuote/yleinensauna/2026-10-31' }), '/en/book/#/tuote/yleinensauna/2026-10-31');
  assert.equal(otherPageHref('/varaa/', { search: '?mock=1', hash: '#/varaa/12/2026-10-31/5?n=2' }), '/varaa/?mock=1#/varaa/12/2026-10-31/5?n=2');
  assert.equal(otherPageHref('/en/order/', { search: '?t=abc', hash: '#ord-g' }), '/en/order/?t=abc&lang=en#ord-g');
  assert.equal(otherPageHref('/tilaus/', { search: '?t=abc&lang=en', hash: '' }), '/tilaus/?t=abc&lang=fi');
  assert.equal(otherPageHref('/en/book/confirmation/', { search: '', hash: '#11111111-1111-4111-8111-111111111111' }), '/en/book/confirmation/#11111111-1111-4111-8111-111111111111');
});

test('vahvistusotsikko vain vahvistetussa tilassa; maksua odottava on viimeistely', () => {
  const co = (state) => ({ state, awaiting: state === 'awaiting_payment' || state === 'processing_payment', processing: state === 'processing_payment', preliminary: state === 'preliminary', expired: state === 'expired', cancelled: state === 'cancelled', confirmed: state === 'confirmed' || state === 'confirmed_unpaid' });
  assert.equal(confirmPageKind({ ok: true, status: 'pending', payment_status: 'unpaid' }, co('awaiting_payment'), false), 'finish');
  assert.equal(confirmPageKind({ ok: true, status: 'pending', payment_status: 'unpaid' }, null, false), 'finish');
  assert.equal(confirmPageKind({ ok: true, status: 'confirmed', payment_status: 'paid' }, co('confirmed'), false), 'confirmed');
  assert.equal(confirmPageKind({ ok: true, status: 'confirmed', payment_status: 'unpaid' }, co('confirmed_unpaid'), false), 'confirmed');
  assert.equal(confirmPageKind({ ok: true, status: 'confirmed', payment_status: 'unpaid' }, null, true), 'confirmed');
  assert.equal(confirmPageKind({ ok: true, status: 'confirmed', payment_status: 'invoiced' }, null, true), 'confirmed');
  assert.equal(confirmPageKind({ ok: true, status: 'pending', payment_status: 'unpaid' }, co('preliminary'), false), 'preliminary');
  assert.equal(confirmPageKind({ ok: true, status: 'expired', payment_status: 'unpaid' }, co('expired'), false), 'expired');
  assert.equal(confirmPageKind({ ok: true, status: 'cancelled', payment_status: 'unpaid' }, null, false), 'cancelled');
});

test('saapumisaika: klo päivän jälkeen ja minuutit pisteellä', () => {
  assert.equal(fixArrivalPhrase('Saavu klo 31.10.2026 16:30', 'fi'), 'Saavu 31.10.2026 klo 16.30');
  assert.equal(fixArrivalPhrase('klo 31.10.2026 16:30', 'fi'), '31.10.2026 klo 16.30');
  assert.equal(fixArrivalPhrase('Arrive klo 31.10.2026 16:30', 'en'), 'Arrive 31.10.2026 at 16:30');
  assert.equal(fixArrivalPhrase('Saavu 31.10.2026 klo 16.30', 'fi'), 'Saavu 31.10.2026 klo 16.30');
  assert.equal(fixSwimwearPhrase('Torstain vuorolla uima-asu on vapaaehtoinen. Ota pyyhe.'), 'Torstain vuorolla saunotaan uima-asussa. Ota pyyhe.');
});

test('tapahtuman vuosi vain kun vuosi ei ole kuluva', () => {
  assert.equal(dayLabel('2026-11-14T14:00:00Z', 'fi', NOW), '14.11.');
  assert.equal(dayLabel('2027-02-06T14:00:00Z', 'fi', NOW), '6.2.2027');
  assert.equal(dayLabel('2027-02-06T14:00:00Z', 'en', NOW), '6 Feb 2027');
});

test('uima-asuohje vain yleisille ja ma–ke-vuoroille', () => {
  assert.equal(swimwearKey('yleinensauna'), 'swimPublic');
  assert.equal(swimwearKey('miestensauna-2'), 'swimOptional');
  assert.equal(swimwearKey('morsiussauna'), null);
});

test('ehdot: katkennut maksuvirke on kokonainen, eikä lahjakorttiohje sano käytä koodia', () => {
  const kb = JSON.parse(readFileSync(new URL('../../content/kb/kb.json', import.meta.url), 'utf8'));
  const pay = kb.policies.find((p) => p.id === 5).body;
  assert.match(pay, /Saunavuoron voi maksaa etukäteen verkkokaupassa\. Ostoksia, kuten lahjakortteja, voi maksaa myös paikan päällä kortilla\./);
  assert.doesNotMatch(pay, /lahjakortteja\) voi maksaa/);
  const gift = kb.policies.find((p) => p.id === 8).body;
  assert.match(gift, /Lahjakortin koodi/);
  assert.match(gift, /alennus- tai vuosikorttikoodi on eri kenttä/);
  assert.doesNotMatch(gift, /käytä koodia/);
  const giftEn = kb.policies.find((p) => p.id === 21).body;
  assert.match(giftEn, /Gift card code/);
  assert.doesNotMatch(giftEn, /Apply coupon/);
});
