// booking_289: asiakaspuolen saatavuushaun kutsujen vähentäminen. Tulosten pitää olla samat kuin kuukausi kerrallaan haettuna.
import test from 'node:test';
import assert from 'node:assert/strict';
import { MonthCache, createProductMonthLoader, groupMonthRuns } from '../shop/src/product-months.js';
import { ensureAllMonths, resetMonthAvailabilityLoader } from '../shop/src/availability-months.js';

const pad = (n) => String(n).padStart(2, '0');
// Palvelinmalli: joka päivä 2 vuoroa / tuote (aloitusajat tarkoituksella sekaisin), vain 2026-01-01…2027-02-28 (horisontti).
const dayRows = (id, ds) => (ds < '2026-01-01' || ds > '2027-02-28' ? [] : [
  { product_id: id, rule_id: id * 10 + 2, session_date: ds, starts_at: `${ds}T17:00:00Z`, ends_at: `${ds}T18:00:00Z`, status: +ds.slice(-2) % 3 ? 'available' : 'full' },
  { product_id: id, rule_id: id * 10 + 1, session_date: ds, starts_at: `${ds}T09:00:00Z`, ends_at: `${ds}T10:00:00Z`, status: 'available' },
]);
const eachDay = (from, to) => { const out = []; for (let d = new Date(`${from}T12:00:00Z`); d <= new Date(`${to}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + 1)) out.push(d.toISOString().slice(0, 10)); return out; };
function fakeRpc(calls, { fail = false } = {}) {
  return async (name, a) => {
    calls.push([name, { ...a }]);
    await Promise.resolve();
    if (fail) throw new Error('boom');
    assert.ok((new Date(`${a.p_to}T00:00:00Z`) - new Date(`${a.p_from}T00:00:00Z`)) / 864e5 <= 92, 'SQL:n 92 pv raja');
    const ids = name === 'public_availability' ? [a.p_product_id] : [1, 7];
    // palvelin palauttaa rivit eri järjestyksessä kuin aloitusaika → lataajan pitää lajitella
    return eachDay(a.p_from, a.p_to).flatMap((ds) => ids.flatMap((id) => dayRows(id, ds)));
  };
}
const snapshot = (months) => JSON.parse(JSON.stringify([...months].sort(([a], [b]) => a.localeCompare(b))));

test('groupMonthRuns: peräkkäiset kuukaudet ryhmiin, enintään 92 päivää, aukot katkaisevat', () => {
  assert.deepEqual(groupMonthRuns([[2026, 9], [2026, 10]]), [[[2026, 9], [2026, 10]]]);
  assert.deepEqual(groupMonthRuns([[2026, 9], [2026, 11]]), [[[2026, 9]], [[2026, 11]]]);
  assert.equal(groupMonthRuns([[2026, 6], [2026, 7], [2026, 8]]).length, 1);          // 1.7.–30.9. = 91 pv välissä
  assert.equal(groupMonthRuns([[2026, 6], [2026, 7], [2026, 8], [2026, 9]]).length, 2); // neljä kuukautta ei mahdu
  assert.deepEqual(groupMonthRuns([[2026, 11], [2027, 0]]), [[[2026, 11], [2027, 0]]]); // vuodenvaihde
  assert.deepEqual(groupMonthRuns([]), []);
});

test('loadSpan: sama tulos kuin kuukausi kerrallaan, selvästi vähemmän kutsuja', async () => {
  const callsA = [], callsB = [];
  const mA = new MonthCache(), mB = new MonthCache();
  const a = createProductMonthLoader({ months: mA, rpc: fakeRpc(callsA) });
  const b = createProductMonthLoader({ months: mB, rpc: fakeRpc(callsB) });
  const span = await a.loadSpan(7, '2026-03-15', '2027-01-20');            // 11 kuukautta
  // viite: kuukausi kerrallaan (vanha toteutus)
  const ref = {};
  for (let i = 0; i < 11; i++) {
    const y = 2026 + Math.floor((2 + i) / 12), m = (2 + i) % 12;
    const part = await b.loadMonth(7, y, m);
    for (const [d, rows] of Object.entries(part)) if (d >= '2026-03-15' && d <= '2027-01-20') ref[d] = rows;
  }
  assert.deepEqual(span, ref);
  assert.deepEqual(snapshot(mA), snapshot(mB));
  assert.equal(callsB.length, 11);
  assert.equal(callsA.length, 4);                                           // 11 kk / ≤ 3 kk per kutsu
  const day = span['2026-04-03'];
  assert.deepEqual(day.map((r) => r.starts_at), ['2026-04-03T09:00:00Z', '2026-04-03T17:00:00Z']);   // lajiteltu
  for (const [, args] of callsA) assert.deepEqual(Object.keys(args).sort(), ['p_from', 'p_product_id', 'p_to']);
});

test('loadMonth: rinnakkaiset samat haut jakavat yhden kutsun; välimuistista ei kutsuta; tyhjä kuukausi on {}', async () => {
  const calls = [];
  const months = new MonthCache();
  const { loadMonth } = createProductMonthLoader({ months, rpc: fakeRpc(calls) });
  const [x, y, z] = await Promise.all([loadMonth(1, 2026, 9), loadMonth(1, 2026, 9), loadMonth(2, 2026, 9)]);
  assert.equal(calls.length, 2);                                            // tuotteet 1 ja 2
  assert.equal(x, y);
  assert.ok(z['2026-10-05']);
  await loadMonth(1, 2026, 9);
  assert.equal(calls.length, 2);
  assert.deepEqual(await loadMonth(1, 2028, 0), {});                        // horisontin jälkeen: ei rivejä, silti välimuistissa
  const n = calls.length;
  await loadMonth(1, 2028, 0);
  assert.equal(calls.length, n);
  assert.equal(calls[0][1].p_from, '2026-10-01');
  assert.equal(calls[0][1].p_to, '2026-10-31');
});

test('loadMonth: virhettä ei välimuistiteta; tyhjennys (varaus tehty) ei jaa vanhaa hakua eikä kirjoita sen tulosta', async () => {
  const months = new MonthCache();
  let fail = true, calls = 0, release;
  const gate = new Promise((r) => { release = r; });
  const rpc = async () => { calls++; if (fail) throw new Error('boom'); await gate; return dayRows(1, '2026-10-05'); };
  const { loadMonth } = createProductMonthLoader({ months, rpc });
  await assert.rejects(loadMonth(1, 2026, 9), /boom/);
  assert.equal(months.size, 0);
  fail = false;
  const old = loadMonth(1, 2026, 9);                                        // hidas haku alkaa
  months.clear();                                                           // käyttäjä varasi → välimuisti tyhjennetään
  const fresh = loadMonth(1, 2026, 9);                                      // ei saa jakaa vanhaa hakua
  release();
  await Promise.all([old, fresh]);
  assert.equal(calls, 3);
  assert.ok(months.has('1:2026-9'));                                        // uusi haku kirjoitti, vanha ei ylikirjoittanut tyhjennyksen jälkeen
});

test('ensureAllMonths: viikko kuukauden vaihteessa = yksi kutsu, tulos sama kuin kuukausi kerrallaan', async () => {
  const catalog = [{ id: 1 }, { id: 7 }, { id: 48 }];
  resetMonthAvailabilityLoader();
  const callsA = [], mA = new Map();
  await ensureAllMonths({ pairs: [[2026, 9], [2026, 10], [2026, 9]], catalog, months: mA, rpc: fakeRpc(callsA), fallback: async () => assert.fail('ei varapolkua'), audience: 'consumer' });
  resetMonthAvailabilityLoader();
  const callsB = [], mB = new Map();
  for (const p of [[2026, 9], [2026, 10]]) await ensureAllMonths({ pairs: [p], catalog, months: mB, rpc: fakeRpc(callsB), fallback: async () => assert.fail('ei varapolkua'), audience: 'consumer' });
  assert.equal(callsA.length, 1);
  assert.equal(callsB.length, 2);
  assert.deepEqual(callsA[0][1], { p_from: '2026-10-01', p_to: '2026-11-30', p_audience: 'consumer' });
  assert.deepEqual(snapshot(mA), snapshot(mB));
  assert.deepEqual(mA.get('48:2026-10'), {});
  assert.equal(mA.size, 6);
});

test('ensureAllMonths: ei-peräkkäiset kuukaudet erillisinä kutsuina, jo ladattu kuukausi ohitetaan, varapolku säilyy', async () => {
  resetMonthAvailabilityLoader();
  const catalog = [{ id: 1 }, { id: 7 }];
  const calls = [], months = new Map();
  await ensureAllMonths({ pairs: [[2026, 9]], catalog, months, rpc: fakeRpc(calls), fallback: async () => {} });
  await ensureAllMonths({ pairs: [[2026, 9], [2026, 11], [2026, 10]], catalog, months, rpc: fakeRpc(calls), fallback: async () => {} });
  assert.equal(calls.length, 2);                                            // loka ohitettu; marras+joulu yhdessä
  assert.deepEqual(calls[1][1], { p_from: '2026-11-01', p_to: '2026-12-31', p_audience: 'consumer' });
  resetMonthAvailabilityLoader();
  const old = []; const m2 = new Map();
  const missing = async () => { throw Object.assign(new Error('function does not exist'), { code: '42883' }); };
  await ensureAllMonths({ pairs: [[2026, 9], [2026, 10]], catalog, months: m2, rpc: missing, fallback: async (id, y, mo) => { old.push(`${id}:${y}-${mo}`); m2.set(`${id}:${y}-${mo}`, {}); } });
  assert.deepEqual(old.sort(), ['1:2026-10', '1:2026-9', '7:2026-10', '7:2026-9']);
});
