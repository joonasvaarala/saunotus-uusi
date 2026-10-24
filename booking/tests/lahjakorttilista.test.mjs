// Lahjakorttilista (hallinta, booking_145): haku myös tuotteella, tiheät rivit, järjestys (uusin / aakkoset / vanhin), 20 kerrallaan, Johku-kortit samassa listassa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const imp = (p) => import(pathToFileURL(join(root, p)));
const read = (p) => readFileSync(join(root, p), 'utf8');
const { createGiftMock } = await imp('admin/giftcards-mock.js');
const G = await imp('admin/giftcards-api.js');
const { GC_FI, GC_EN } = await imp('admin/giftcards-texts.js');
const TODAY = '2026-10-24';
const R = (m, a = {}) => m.rpc('admin_list_gift_cards', a);
const MIG = 'supabase/migrations/20261024180000_booking_145_giftcard_list_search.sql', RB = 'supabase/rollbacks/20261024180000_booking_145_ROLLBACK.sql';

test('Mock: ~45 korttia, joista Johku-kortteja; jokaisella rivillä tuotteen nimi', async () => {
  const m = createGiftMock({ today: TODAY }), all = await R(m, { p_limit: 200 });
  assert.equal(all.total, 45);
  const jk = all.rows.filter((r) => r.source === 'johku');
  assert.equal(jk.length, 31);
  assert.ok(all.rows.every((r) => typeof r.product_name === 'string' && r.product_name.length > 0), 'product_name kaikilla');
  assert.ok(jk.every((r) => r.package_code == null && r.package_name == null), 'Johku-kortilla ei pakettia (kuten tuotannossa)');
  assert.ok(all.rows.every((r) => /@example\.invalid$/.test(r.buyer_email || 'x@example.invalid') && /@example\.invalid$/.test(r.recipient_email || 'x@example.invalid')), 'vain keksittyä dataa');
});

test('Haku: koodi, nimi, sähköposti ja tuote, kirjainkoko ei vaikuta, toimii Johku-korteille', async () => {
  const m = createGiftMock({ today: TODAY });
  const p = await R(m, { p_search: 'SAUNAHOITO -LAHJAKORTTI', p_limit: 200 });
  assert.ok(p.total >= 1 && p.rows.every((r) => r.source === 'johku' && /saunahoito -lahjakortti/i.test(r.product_name)), 'tuotehaku osuu Johku-kortteihin');
  const arki = await R(m, { p_search: 'arkivuoro' }); assert.ok(arki.total >= 1);
  const j = (await R(m, { p_source: 'johku', p_limit: 1 })).rows[0];
  assert.ok((await R(m, { p_search: j.code.toLowerCase() })).rows.some((r) => r.id === j.id), 'Johku-koodi pienillä');
  assert.ok((await R(m, { p_search: j.buyer_email.toUpperCase() })).rows.some((r) => r.id === j.id), 'sähköposti isoilla');
  assert.ok((await R(m, { p_search: 'öhman' })).total >= 1, 'nimi ääkkösillä');
  assert.equal((await R(m, { p_search: 'ei-tällaista-tuotetta' })).total, 0);
});

test('Järjestys: oletus uusin ensin, vanhin ensin, aakkoset (saaja, muuten ostaja; fi-aakkoset; nimettömät viimeisenä)', async () => {
  const m = createGiftMock({ today: TODAY });
  assert.equal(G.GC_SORTS[0], 'created_desc'); assert.ok(G.GC_SORTS.includes('created_asc') && G.GC_SORTS.includes('name_asc'));
  const d = (await R(m, { p_limit: 200 })).rows.map((r) => r.created_at);
  assert.deepEqual(d, [...d].sort().reverse(), 'oletus created_desc');
  const a = (await R(m, { p_sort: 'created_asc', p_limit: 200 })).rows.map((r) => r.created_at);
  assert.deepEqual(a, [...a].sort(), 'created_asc');
  const rows = (await R(m, { p_sort: 'name_asc', p_limit: 200 })).rows, names = rows.map((r) => (r.recipient_name || r.buyer_name || '').trim());
  const named = names.filter(Boolean), col = new Intl.Collator('fi', { sensitivity: 'base' });
  assert.deepEqual(named, [...named].sort(col.compare), 'aakkosjärjestys fi');
  assert.ok(names.indexOf('Åsa Lindqvist') > names.indexOf('Ville Ahonen') && names.indexOf('Ärje Esimerkki') > names.indexOf('Åsa Lindqvist') && names.indexOf('Öhman Testi') > names.indexOf('Ärje Esimerkki'), 'Å < Ä < Ö aakkosten lopussa');
  const firstEmpty = names.findIndex((x) => !x); assert.ok(firstEmpty === -1 || names.slice(firstEmpty).every((x) => !x), 'nimettömät viimeisenä');
});

test('Sivutus: 20 kerrallaan, sivut eivät toista eivätkä hukkaa rivejä', async () => {
  const m = createGiftMock({ today: TODAY }), seen = new Set();
  for (const sort of ['created_desc', 'name_asc', 'created_asc']) {
    seen.clear();
    for (let off = 0; off < 45; off += 20) { const r = await R(m, { p_sort: sort, p_limit: 20, p_offset: off }); assert.equal(r.rows.length, Math.min(20, 45 - off)); r.rows.forEach((x) => seen.add(x.id)); }
    assert.equal(seen.size, 45, sort);
  }
  const src = read('admin/views/talous-giftcards.js');
  assert.match(src, /export const GC_PAGE = 20;/);
  assert.match(src, /limit: GC_PAGE, offset: 0/);
  assert.doesNotMatch(src, /pageSizeSelect/, 'sivukoko kiinteä 20');
  // datakerros välittää p_sort=name_asc ja p_limit=20
  const calls = []; const be = G.rpcBackend(async (n, p) => { calls.push([n, p]); return { total: 0, rows: [] }; });
  await be.list({ search: 'Tuote', sort: 'name_asc', limit: 20, offset: 40 });
  assert.deepEqual(calls[0], ['admin_list_gift_cards', { p_search: 'Tuote', p_sort: 'name_asc', p_limit: 20, p_offset: 40 }]);
});

test('Näkymä: tiheä rivi (koodi, nimi, tuote, saldo, voimassa, tila, lähde), järjestys aina näkyvissä, tuote tiedoissa', () => {
  const src = read('admin/views/talous-giftcards.js'), css = read('admin/admin.css');
  for (const cls of ['tl-main', 'gc-who', 'gc-prod', 'tl-sum', 'tl-date', 'tl-badges', 'gc-src']) assert.ok(src.includes(`'tl-c ${cls}'`), cls);
  assert.match(src, /status: sort,/, 'järjestysvalinta palkissa (filterDrawer status)');
  assert.match(src, /\[t\('gc\.d\.package'\), prodOf\(c\) \|\| '–'\]/);
  assert.match(src, /badge\('src-johku', t\('gcsrc\.johku'\)\)/);
  assert.match(css, /\.tl-list\.gc \.tl-head\{grid-template-columns:auto minmax\(0,1fr\) auto 20px;grid-template-areas:"main who who chev" "prod prod sum chev" "date badges src chev"/);
  assert.match(css, /\.tl-list\.gc \.tl-c\{overflow:hidden;text-overflow:ellipsis;white-space:nowrap/);
  const block = css.slice(css.indexOf('/* Lahjakorttilista (booking_145)'), css.indexOf('/* Lahjakorttilista (booking_145)') + 2500);
  assert.doesNotMatch(block, /#(?:00f|0000ff|1e90ff|2563eb|3b82f6)\b|\bblue\b/i, 'ei sinistä');
});

test('Tekstit FI/EN: uudet avaimet, ei <-merkkiä, haku mainitsee tuotteen', () => {
  for (const k of ['gcsort.name_asc', 'gc.col.product', 'gc.col.source', 'gc.col.who', 'gc.col.valid', 'gc.search']) {
    assert.ok(GC_FI[k] && GC_EN[k], k); assert.ok(!GC_FI[k].includes('<') && !GC_EN[k].includes('<'), k); assert.notEqual(GC_FI[k], GC_EN[k], k);
  }
  assert.match(GC_FI['gc.search'], /tuote/); assert.match(GC_EN['gc.search'], /product/);
  assert.equal(GC_FI['gcsort.created_desc'], 'Uusin ensin'); assert.equal(GC_FI['gcsort.created_asc'], 'Vanhin ensin'); assert.match(GC_FI['gcsort.name_asc'], /^Aakkosjärjestys/);
});

test('Migraatio booking_145: sama allekirjoitus, staff-tarkistus, SECURITY DEFINER, search_path, fi-aakkostus; rollback palauttaa', () => {
  const sql = read(MIG), rb = read(RB);
  // allekirjoitus: parametrit (nimi + tyyppi) samat ja samassa järjestyksessä kuin booking_44:n versiossa (rollback = pg_get_functiondef)
  const sig = (x) => { const m = /create or replace function booking\.admin_list_gift_cards\(([\s\S]*?)\)\s*returns\s+(\w+)/i.exec(x); assert.ok(m, 'admin_list_gift_cards löytyy');
    return [m[1].split(',').map((p) => p.trim().split(/\s+/).slice(0, 2).join(' ').toLowerCase().replace(/ int$/, ' integer')).join(','), m[2].toLowerCase()]; };
  assert.deepEqual(sig(sql), sig(rb));
  assert.equal(sig(sql)[0].split(',').length, 12);
  assert.match(sql, /booking\.is_staff\(\)/); assert.match(sql, /security definer/i); assert.match(sql, /set search_path (to|=) ''/i);
  assert.match(sql, /'name_asc'/); assert.match(sql, /collate "fi-x-icu"/);
  assert.match(sql, /booking\._gc_product_name\(g\) ilike/);
  assert.match(sql, /revoke all on function booking\._gc_product_name\(booking\.gift_cards\) from public, anon, authenticated/i);
  assert.doesNotMatch(sql, /\bpublic\.\w+/, 'ei public-skeemaa');
  assert.doesNotMatch(sql, /\b(insert into|update|delete from)\b/i, 'ei datamuutoksia');
  assert.match(rb, /drop function if exists booking\._gc_product_name\(booking\.gift_cards\)/i);
  assert.doesNotMatch(rb, /name_asc|_gc_product_name\(g\)/, 'rollback = booking_44:n versio');
  const t = read('supabase/tests/talous/t145_giftcard_list.sql');
  assert.match(t, /TESTRESULT/); assert.doesNotMatch(t, /@(?!example\.test)[a-z0-9-]+\.[a-z]/i, 'testidata feikkiä');
});
