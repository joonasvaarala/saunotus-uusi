// Artikkelien haku: sivutus, vikasietoisuus (välimuisti / tyhjä lista), uudelleenohjaukset, avainten turvatarkistus
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadArticles, makeRpc, makeFixtureRpc, assertPublicKey } from '../../src/articles/source.mjs';

const fx = JSON.parse(readFileSync(new URL('./fixtures/rpc.json', import.meta.url), 'utf8'));
const quiet = { warn() {}, log() {} };
const tmp = () => mkdtempSync(join(tmpdir(), 'art-'));
const load = (o = {}) => loadArticles({ rpc: makeFixtureRpc(fx), log: quiet, ...o });

test('hakee listat ja yksittäiset artikkelit (fi 3, en 1) ja sitemapin', async () => {
  const d = await load();
  assert.equal(d.source, 'rpc');
  assert.equal(d.lang.fi.items.length, 3);
  assert.equal(d.lang.en.items.length, 1);
  assert.equal(d.lang.fi.items[0].article.content_md.includes('rauhoittumista'), true);
  assert.ok(d.lang.fi.items.every((x) => x.seo.canonical && x.seo.json_ld));
  assert.equal(d.sitemap.length, 3);
  assert.equal(d.lang.fi.dbPath, '/saunatietoa/');
});
test('sivutus: yli 50 artikkelia haetaan useassa pyynnössä', async () => {
  const base = fx.list.fi.items[0];
  const many = Array.from({ length: 120 }, (_, i) => ({ ...base, slug: `testi-${i}`, title: `T${i}` }));
  const big = { ...fx, list: { ...fx.list, fi: { ...fx.list.fi, items: many } }, articles: Object.fromEntries(many.map((m) => [`fi/${m.slug}`, { ok: true, article: { ...m, content_md: 'x', images: [] }, seo: { canonical: 'c', json_ld: {} } }])), sitemap: { ok: true, items: [] } };
  const calls = [];
  const inner = makeFixtureRpc(big);
  const rpc = async (n, a) => { if (n === 'public_list_articles') calls.push(a); return inner(n, a); };
  const d = await loadArticles({ rpc, log: quiet });
  assert.equal(d.lang.fi.items.length, 120);
  assert.deepEqual(calls.filter((c) => c.p_lang === 'fi').map((c) => c.p_offset), [0, 50, 100]);
  assert.ok(calls.every((c) => c.p_limit === 50));
});
test('RPC ei vastaa, ei välimuistia → tyhjä lista + varoitus, ei virhettä', async () => {
  const d = await loadArticles({ rpc: async () => { throw new Error('ECONNREFUSED'); }, cacheDir: tmp(), log: quiet });
  assert.equal(d.source, 'none');
  assert.equal(d.lang.fi.items.length + d.lang.en.items.length, 0);
  assert.match(d.warnings.join('\n'), /ECONNREFUSED[\s\S]*tyhjä/);
});
test('RPC ei vastaa, välimuisti olemassa → käytetään edellistä onnistunutta hakua', async () => {
  const dir = tmp();
  try {
    const ok = await load({ cacheDir: dir });
    assert.ok(existsSync(join(dir, 'snapshot.json')));
    const d = await loadArticles({ rpc: async () => { throw new Error('HTTP 503'); }, cacheDir: dir, log: quiet });
    assert.equal(d.source, 'cache');
    assert.equal(d.lang.fi.items.length, ok.lang.fi.items.length);
    assert.match(d.warnings.join('\n'), /HTTP 503/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
test('Supabase-asetuksia ei annettu (rpc puuttuu) → ei kaadu, varoittaa', async () => {
  const d = await loadArticles({ rpc: null, log: quiet });
  assert.equal(d.source, 'none');
  assert.match(d.warnings[0], /BOOKING_ANON_KEY/);
});
test('ARTICLES_STRICT (strict) → virhe heitetään', async () => {
  await assert.rejects(loadArticles({ rpc: async () => { throw new Error('down'); }, strict: true, log: quiet }), /down/);
});
test('yksittäisen artikkelin haku epäonnistuu → varalle välimuisti, muuten artikkeli pois; muut säilyvät', async () => {
  const dir = tmp();
  try {
    await load({ cacheDir: dir });
    const inner = makeFixtureRpc(fx);
    const flaky = async (n, a) => { if (n === 'public_get_article' && a.p_slug === 'miten-saunotaan-oikein') throw new Error('timeout'); return inner(n, a); };
    const withCache = await loadArticles({ rpc: flaky, cacheDir: dir, log: quiet });
    assert.equal(withCache.lang.fi.items.length, 3);
    const noCache = await loadArticles({ rpc: flaky, cacheDir: tmp(), log: quiet });
    assert.equal(noCache.lang.fi.items.length, 2);
    assert.match(noCache.warnings.join('\n'), /miten-saunotaan-oikein[\s\S]*pois/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
test('sitemap-RPC epäonnistuu → sitemap johdetaan listasta (noindex pois)', async () => {
  const inner = makeFixtureRpc(fx);
  const d = await loadArticles({ rpc: async (n, a) => { if (n === 'public_articles_sitemap') throw new Error('x'); return inner(n, a); }, log: quiet });
  assert.deepEqual(d.sitemap.map((s) => s.slug).sort(), ['how-to-sauna', 'miten-saunotaan-oikein', 'savusauna-lampiaminen']);
  assert.match(d.warnings.join('\n'), /sitemap/);
});
const SAVU = { lang: 'fi', from: 'savusauna-vanha-nimi', toLang: 'fi', toSlug: 'savusauna-lampiaminen' };
const EN_OLD = { lang: 'en', from: 'sauna-how-to', toLang: 'en', toSlug: 'how-to-sauna' };
const byKey = (l) => [...l].sort((a, b) => `${a.lang}/${a.from}`.localeCompare(`${b.lang}/${b.from}`));
const rpcCalls = (f, calls) => { const inner = makeFixtureRpc(f); return async (n, a) => { calls.push([n, a]); return inner(n, a); }; };
const row = (o) => ({ lang: 'fi', from_slug: 'a-vanha', from_path: '/x/', from_loc: 'https://x/', to_slug: 'miten-saunotaan-oikein', to_path: '/y/', to_loc: 'https://y/', status: 301, ...o });

test('uudelleenohjaukset: public_articles_redirects() on ensisijainen lähde (ei tarvitse tunnettuja slugeja eikä välimuistia, ei per-slug-kyselyjä)', async () => {
  const calls = [];
  const d = await loadArticles({ rpc: rpcCalls(fx, calls), log: quiet });
  assert.deepEqual(byKey(d.redirects), byKey([SAVU, EN_OLD]));
  assert.equal(d.redirectsSource, 'rpc');
  assert.ok(calls.some(([n]) => n === 'public_articles_redirects'));
  assert.ok(!calls.some(([n, a]) => n === 'public_get_article' && a.p_slug === 'savusauna-vanha-nimi'), 'moved-kyselyjä ei tehdä kun RPC vastaa');
});
test('public_articles_redirects: vain lang/from_slug/to_slug käytetään (polut ja isäntänimet ohitetaan); virheelliset, omat, duplikaatit ja julkaistun artikkelin slug ohitetaan', async () => {
  const f = { ...fx, redirects: { ok: true, items: [
    row({ from_slug: 'a-vanha', from_path: 'https://evil.example/', to_loc: 'https://evil.example/' }),
    row({ from_slug: 'a-vanha' }),                                           // duplikaatti
    row({ from_slug: 'miten-saunotaan-oikein', to_slug: 'miten-saunotaan-oikein' }),   // ohjaa itseensä
    row({ from_slug: 'savusauna-lampiaminen', to_slug: 'miten-saunotaan-oikein' }),    // julkaistu artikkeli voittaa
    row({ from_slug: '../paha' }), row({ from_slug: 'Iso-Kirjain' }), row({ lang: 'sv', from_slug: 'sv-vanha' }), row({ to_slug: 'x y' }), null,
    row({ lang: 'en', from_slug: 'old-guide', to_slug: 'how-to-sauna' }),
  ] } };
  const warns = [];
  const d = await loadArticles({ rpc: makeFixtureRpc(f), log: { warn: (m) => warns.push(m), log() {} } });
  assert.deepEqual(d.redirects, [
    { lang: 'fi', from: 'a-vanha', toLang: 'fi', toSlug: 'miten-saunotaan-oikein' },
    { lang: 'en', from: 'old-guide', toLang: 'en', toSlug: 'how-to-sauna' },
  ]);
  assert.equal(warns.filter((m) => /virheellinen rivi/.test(m)).length, 5);
});
test('public_articles_redirects tyhjä lista → ei ohjauksia (vanha cache ei elvytä poistettuja)', async () => {
  const dir = tmp();
  try {
    await load({ cacheDir: dir, committedSlugs: [{ lang: 'fi', slug: 'savusauna-vanha-nimi' }] });
    const d = await loadArticles({ rpc: makeFixtureRpc({ ...fx, redirects: { ok: true, items: [] } }), log: quiet, cacheDir: dir, committedSlugs: [{ lang: 'fi', slug: 'savusauna-vanha-nimi' }] });
    assert.deepEqual(d.redirects, []);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
test('varakeino: public_articles_redirects ei vastaa → tunnetut slugit kysytään yksitellen (moved → ohjaus; poistettu → ei ohjausta) + varoitus', async () => {
  for (const redirects of [null, { ok: false, code: 'boom' }]) {
    const known = [{ lang: 'fi', slug: 'savusauna-vanha-nimi' }, { lang: 'fi', slug: 'poistettu-artikkeli' }];
    const warns = [], calls = [];
    const d = await loadArticles({ rpc: rpcCalls({ ...fx, redirects }, calls), log: { warn: (m) => warns.push(m), log() {} }, committedSlugs: known });
    assert.deepEqual(d.redirects, [SAVU]);
    assert.equal(d.redirectsSource, 'fallback');
    assert.match(warns.join('\n'), /public_articles_redirects epäonnistui/);
    assert.ok(calls.some(([n, a]) => n === 'public_get_article' && a.p_slug === 'savusauna-vanha-nimi'));
  }
});
test('tunnetut slugit kertyvät välimuistiin: RPC:n antamat vanhat slugit muistetaan, ja varakeino löytää ne vaikka RPC kaatuu', async () => {
  const dir = tmp();
  try {
    const first = await load({ cacheDir: dir });
    assert.ok(first.known.some((k) => k.slug === 'miten-saunotaan-oikein'));
    assert.ok(first.known.some((k) => k.slug === 'savusauna-vanha-nimi'), 'RPC:n vanha slug tallentuu tunnettuihin');
    const down = await loadArticles({ rpc: makeFixtureRpc({ ...fx, redirects: null }), log: quiet, cacheDir: dir });
    assert.deepEqual(byKey(down.redirects), byKey([SAVU, EN_OLD]), 'slug muistetaan ilman committedSlugs-listaa ja ilman redirects-RPC:tä');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
test('koko RPC kaatuu: edellisen onnistuneen haun ohjaukset säilyvät välimuistista', async () => {
  const dir = tmp();
  try {
    await load({ cacheDir: dir });
    const d = await loadArticles({ rpc: async () => { throw new Error('verkko poikki'); }, log: quiet, cacheDir: dir });
    assert.equal(d.source, 'cache');
    assert.deepEqual(byKey(d.redirects), byKey([SAVU, EN_OLD]));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ---- avaimet ja RPC-asiakas ----
const jwt = (role) => `h.${Buffer.from(JSON.stringify({ role })).toString('base64url')}.s`;
test('assertPublicKey: sb_secret ja service_role hylätään, publishable ja anon-JWT sallitaan', () => {
  assert.throws(() => assertPublicKey('sb_secret_abc'), /sb_secret/);
  assert.throws(() => assertPublicKey(jwt('service_role')), /service_role/);
  assert.throws(() => assertPublicKey('jokumuu'), /tuntematon/);
  assert.doesNotThrow(() => assertPublicKey('sb_publishable_abc'));
  assert.doesNotThrow(() => assertPublicKey(jwt('anon')));
  assert.throws(() => makeRpc({ url: 'https://x.supabase.co', key: 'sb_secret_x' }), /sb_secret/);
});
test('makeRpc: POST oikeaan osoitteeseen, skeema booking, uusinta virheessä, {ok:false} palautetaan sellaisenaan', async () => {
  const seen = []; let n = 0;
  const rpc = makeRpc({ url: 'https://x.supabase.co/', key: 'sb_publishable_k', retries: 2, fetchImpl: async (u, o) => {
    seen.push([u, o]); if (++n < 3) return { ok: false, status: 503 };
    return { ok: true, json: async () => ({ ok: false, code: 'not_found' }) };
  } });
  const res = await rpc('public_get_article', { p_slug: 'a', p_lang: 'fi' });
  assert.deepEqual(res, { ok: false, code: 'not_found' });
  assert.equal(seen.length, 3);
  assert.equal(seen[0][0], 'https://x.supabase.co/rest/v1/rpc/public_get_article');
  assert.equal(seen[0][1].method, 'POST');
  assert.equal(seen[0][1].headers['content-profile'], 'booking');
  assert.equal(seen[0][1].headers.apikey, 'sb_publishable_k');
  assert.deepEqual(JSON.parse(seen[0][1].body), { p_slug: 'a', p_lang: 'fi' });
});
test('makeRpc: pysyvä virhe → heittää (loadArticles tekee varajärjestelyn)', async () => {
  const rpc = makeRpc({ url: 'https://x.supabase.co', key: 'sb_publishable_k', retries: 1, fetchImpl: async () => ({ ok: false, status: 500 }) });
  await assert.rejects(rpc('public_list_articles'), /HTTP 500/);
});
