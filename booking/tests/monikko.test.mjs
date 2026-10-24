// Monikkokorjaus (Joonas 24.10.2026): lukumäärä 1 → yksikkö ("1 guest", "1 henkilö", "1 minute"), julkaistut site_texts ennallaan.
// Yksikkö tulee valinnaisesta rinnakkaisavaimesta (<avain>One / <avain>_one, tuonti content/site-texts.pending-import-64.json); puuttuu → monikkoavain.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname);
const imp = (p) => import(pathToFileURL(join(root, p)));
const P = await imp('booking/shop/src/plural.js');
const R = await imp('booking/shop/src/text-registry.js');
const { T } = await imp('booking/shop/src/i18n.js');
const { RITUAL_TEXTS } = await imp('booking/shop/src/ritual-addon-texts.js');
const { gtText } = await imp('booking/shop/src/gift-texts.js');
const { ht } = await imp('booking/shop/src/hold-texts.js');
const { OT } = await imp('booking/shop/src/order-texts.js');
const PENDING64 = JSON.parse(readFileSync(join(root, 'content/site-texts.pending-import-64.json'), 'utf8'));
const quiet = () => {};

test('plural.js: Intl.PluralRules fi/en, 1 = yksikkö, muut monikko; merkkijonot ja puuttuvat arvot', () => {
  for (const L of ['fi', 'en']) {
    assert.equal(P.isOne(L, 1), true); assert.equal(P.isOne(L, '1'), true);
    for (const n of [0, 2, 7, 48, '15', null, undefined, 'x', 1.5]) assert.equal(P.isOne(L, n), false, `${L} ${n}`);
  }
  assert.equal(P.pl('en', 1, 'guest', 'guests'), 'guest'); assert.equal(P.pl('en', 3, 'guest', 'guests'), 'guests');
  const d = { fooOne: 'a', 'x.bar_one': 'b' };
  assert.equal(P.oneKey('foo', 'en', { n: 1 }, d), 'fooOne'); assert.equal(P.oneKey('foo', 'en', { n: 2 }, d), 'foo');
  assert.equal(P.oneKey('x.bar', 'en', { minutes: 1 }, d), 'x.bar_one');
  assert.equal(P.oneKey('baz', 'en', { n: 1 }, d), 'baz', 'yksikköavain puuttuu → monikkoavain');
  assert.equal(P.oneKey('foo', 'en', { time: 1 }, d), 'foo', 'vain lukumäärämuuttujat');
});

test('kassan rituaaliyhteenveto ja paikat: 1 guest / 2 guests; FI hlö kummassakin', () => {
  const f = (s, v) => s.replace(/\{(\w+)\}/g, (_, k) => v[k]);
  const pick = (L, k, v) => f(RITUAL_TEXTS[L][P.oneKey(k, L, v, RITUAL_TEXTS[L])], v);
  assert.equal(pick('en', 'ritualSummary', { time: '18:00', n: 1 }), '18:00 · 1 guest');
  assert.equal(pick('en', 'ritualSummary', { time: '18:00', n: 2 }), '18:00 · 2 guests');
  assert.equal(pick('en', 'ritualSpots', { n: 1 }), 'up to 1 guest');
  assert.equal(pick('fi', 'ritualSummary', { time: '18.00', n: 1 }), 'klo 18.00 · 1 hlö');
  assert.equal(RITUAL_TEXTS.en.ritualSummary, '{time} · {n} guests', 'julkaistu monikkoteksti ennallaan');
  const shop = readFileSync(join(root, 'booking/shop/src/shop.js'), 'utf8');
  assert.match(shop, /const rtx = \(k, v\) => \{ const k1 = oneKey\(k, S\.lang, v,/);
});

test('i18n-funktiot: hoidon valinta, enimmäismäärä, maksun pito ja muutosraja yksikössä', () => {
  R.resetSiteTexts();
  assert.equal(T.en.tr.selected('Mon 5 Oct 18:00', 1, '49 €'), 'Selected: Mon 5 Oct 18:00 · 1 guest · 49 €');
  assert.equal(T.en.tr.selected('Mon', 3, '49 €'), 'Selected: Mon · 3 guests · 49 €');
  assert.equal(T.fi.tr.maxPersons(1), 'Enintään 1 henkilö.'); assert.equal(T.fi.tr.maxPersons(4), 'Enintään 4 henkilöä.');
  assert.equal(T.en.tr.maxPersons(1), 'Up to 1 guest.');
  assert.equal(T.en.payHold(1), 'Your spot is held for 1 minute while payment is pending.');
  assert.equal(T.fi.payHold(15), 'Paikkaa pidetään 15 minuuttia maksun odottaessa.');
  assert.match(T.fi.changeInfo(1, 'pe'), /viimeistään 1 tunti ennen/); assert.match(T.en.changeInfo(48, 'Fri'), /48 hours before/);
});

test('tietokannan monikkorivi ilman _one-riviä → koodin yksikkömalli; _one-rivi tietokannassa voittaa', () => {
  R.applySiteTexts([{ key: 'ui.treatment.selected', lang: 'en', text: 'Picked: {{var:when}} · {{var:n}} guests · {{var:price}}' }], { log: quiet });
  assert.equal(T.en.tr.selected('Mon', 2, '5 €'), 'Picked: Mon · 2 guests · 5 €');
  assert.equal(T.en.tr.selected('Mon', 1, '5 €'), 'Selected: Mon · 1 guest · 5 €');
  R.applySiteTexts([{ key: 'ui.treatment.selected', lang: 'en', text: 'Picked: {{var:when}} · {{var:n}} guests · {{var:price}}' }, { key: 'ui.treatment.selected_one', lang: 'en', text: 'Picked: {{var:when}} · {{var:n}} guest · {{var:price}}' }], { log: quiet });
  assert.equal(T.en.tr.selected('Mon', 1, '5 €'), 'Picked: Mon · 1 guest · 5 €');
  R.applySiteTexts([{ key: 'ui.shop.ritual_summary_one', lang: 'en', text: '{{var:time}} – {{var:n}} person' }], { log: quiet });
  assert.equal(T.en.ritualSummaryOne ?? RITUAL_TEXTS.en.ritualSummaryOne, '{time} – {n} person');
  R.resetSiteTexts();
  assert.equal(T.en.tr.selected('Mon', 1, '5 €'), 'Selected: Mon · 1 guest · 5 €');
});

test('lahjakortti-, pito- ja tilaussivun tekstit: yksikkö kun luku on 1', () => {
  R.resetSiteTexts();
  assert.equal(gtText('en', 'persons', { n: 1 }), 'For 1 person'); assert.equal(gtText('en', 'persons', { n: 2 }), 'For 2 people');
  assert.equal(gtText('en', 'valid', { months: 1 }), 'Valid for 1 month'); assert.equal(gtText('en', 'valid', { months: 12 }), 'Valid for 12 months');
  assert.match(gtText('fi', 'maxCards', { n: 1 }), /enintään 1 kortti\./);
  assert.match(ht('en', 'mustPay', { minutes: 1 }), /within 1 minute,/); assert.match(ht('en', 'checkout.lead', { minutes: 30 }), /30 minutes/);
  assert.match(ht('en', 'checkout.lead', { minutes: 1 }), /1 minute when/);
  assert.match(OT.fi.cancelRuleOne, /\{hours\} tunti ennen/); assert.match(OT.en.cancelClosedOne, /\{hours\} hour\./);
  const order = readFileSync(join(root, 'booking/shop/src/order.js'), 'utf8');
  for (const k of ['cancelRule', 'cancelClosed', 'closedHoldExpired']) assert.match(order, new RegExp(`t\\[oneKey\\('${k}', L, `));
});

test('pending-import-64: vain uudet *_one-avaimet, FI+EN, vastaa koodin oletuksia, ei HTML:ää; monikkoavaimet eivät muutu', () => {
  const all = R.collectDefaults();
  const keys = [...new Set(PENDING64.map((r) => r.key))];
  assert.equal(keys.length, 20); assert.equal(PENDING64.length, 40);
  for (const k of keys) {
    assert.match(k, /_one$/);
    for (const L of ['fi', 'en']) {
      const p = PENDING64.find((r) => r.key === k && r.lang === L); assert.ok(p, `${k}|${L}`);
      const w = all.find((r) => r.key === k && r.lang === L); assert.ok(w, `${k}|${L} koodissa`);
      assert.equal(p.text, w.text); assert.equal(p.kind, 'plain'); assert.ok(!p.text.includes('<')); assert.match(p.reason, /monikkokorjaus/);
      assert.equal(p.class, R.classFor(k.replace(/_one$/, ''), all.find((r) => r.key === k.replace(/_one$/, '') && r.lang === 'fi')?.text || ''));
    }
    assert.ok(all.some((r) => r.key === k.replace(/_one$/, '')), `${k}: monikkoavain on olemassa`);
  }
  assert.ok(!keys.some((k) => /price_per|per_person/.test(k)), "'20 € / hlö' ennallaan");
});
