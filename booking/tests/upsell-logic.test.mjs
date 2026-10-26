import test from 'node:test';
import assert from 'node:assert/strict';
import { visitDate, rankSlots, candidates, shortPlain, safeSlug, dropRepeatedName, excerpt, stripNameHeading, durationText, personsText, mergeFacts } from '../shop/src/upsell-logic.js';
const day='2026-11-15';
const visits=[{starts_at:'2026-11-15T15:00:00Z',ends_at:'2026-11-15T17:00:00Z',status:'confirmed'}];
const slots=[
 {start:'2026-11-15T18:00:00Z',end:'2026-11-15T18:30:00Z'},
 {start:'2026-11-15T13:00:00Z',end:'2026-11-15T15:00:00Z'},
 {start:'2026-11-15T17:00:00Z',end:'2026-11-15T17:30:00Z'},
 {start:'2026-11-16T17:00:00Z',end:'2026-11-16T17:30:00Z'},
];
test('Helsinki date handles UTC timezone correctly',()=>assert.equal(visitDate('2026-11-14T23:30:00Z'),day));
test('slots outside visit day excluded',()=>assert.equal(rankSlots(slots,visits,day).length,3));
test('adjacent slots come before remote slot',()=>assert.equal(rankSlots(slots,visits,day).slice(0,2).every(s=>!!s.fit),true));
test('immediately before labeled before',()=>assert.equal(rankSlots(slots,visits,day).find(s=>s.start===slots[1].start).fit,'before'));
test('fallback is behind active suggestions',()=>assert.deepEqual(candidates({products:[{product_id:2,slots:[1]},{product_id:3,suggested:true,slots:[1]}]},[1]).map(p=>p.product_id),[3,2]));
test('already ordered product removed',()=>assert.deepEqual(candidates({products:[{product_id:3,slots:[1]}]},[3]),[]));
test('no empty availability cards',()=>assert.equal(candidates({products:[{product_id:2,slots:[]}]}).length,0));
test('rich description sanitized to plain text',()=>assert.equal(shortPlain('<p>Hei &nbsp; tervetuloa!</p>'), 'Hei   tervetuloa!'.replace(/\s+/g,' ').trim()));
test('unsafe slugs do not form URLs',()=>assert.equal(safeSlug('https://attacker/'),''));
const saunaHtml = '<h3>Saunotus</h3><p>Saunotus on kahden tunnin kokonaisvaltainen saunaelämys, jossa lämpö ja löyly yhdistyvät.</p>';
test('heading plus sentence that repeats the name collapses once', () => {
  assert.equal(dropRepeatedName('Saunotus', shortPlain(saunaHtml, 500)), 'Saunotus on kahden tunnin kokonaisvaltainen saunaelämys, jossa lämpö ja löyly yhdistyvät.');
});
test('a single leading name stays in the sentence', () => {
  assert.equal(dropRepeatedName('Saunotus', 'Saunotus yhdistää löylyn ja vihdat'), 'Saunotus yhdistää löylyn ja vihdat');
});
test('name is not stripped from a longer word', () => {
  assert.equal(dropRepeatedName('Saunotus', 'Saunotus Saunotusrituaali'), 'Saunotus Saunotusrituaali');
});
test('intro does not prefix the product name', () => {
  const text = excerpt({ name: 'Saunotus', name_en: 'Guided Sauna Session (Saunotus)', description: saunaHtml, description_en: '<h3>Guided Sauna Session (Saunotus)</h3><p>A guided sauna session is two hours.</p>' }, 'fi', 180, false);
  assert.equal(text.startsWith('Saunotus Saunotus'), false);
  assert.match(text, /^Saunotus on kahden tunnin/);
});
test('english heading that is only the name is not repeated', () => {
  const text = excerpt({ name: 'Saunotus', name_en: 'Guided Sauna Session (Saunotus)', description_en: '<h3>Guided Sauna Session (Saunotus)</h3><p>A guided sauna session is two hours.</p>' }, 'en', 180, false);
  assert.match(text, /^A guided sauna session is two hours/);
});
test('dialog description drops a heading that is only the name', () => {
  assert.match(stripNameHeading(saunaHtml, 'Saunotus'), /^<p>Saunotus on kahden/);
  assert.equal(stripNameHeading('<h2>Syvä mutta lempeä</h2><p>Teksti.</p>', 'Saunotus').startsWith('<h2>'), true);
});
test('duration and persons come from catalog-shaped fields', () => {
  const row = mergeFacts({ product_id: 11, name: 'Saunotus', price_from: 210 }, { id: 11, duration_text: '2 h', duration_minutes: 120, capacity_min: 1, capacity_max: 2 });
  assert.equal(durationText(row, 'fi'), '2 h');
  assert.equal(personsText(row), '1–2');
  assert.equal(durationText({ duration_minutes: 90 }, 'en'), '1 h 30 min');
});
