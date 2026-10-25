import test from 'node:test';
import assert from 'node:assert/strict';
import { visitDate, rankSlots, candidates, shortPlain, safeSlug } from '../shop/src/upsell-logic.js';
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
