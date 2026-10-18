// Sivutekstit tietokannasta (sopimus §18, booking_60–62) + tuote 7 kentät (booking_61) kaupassa:
//  * paikkamerkki-resolveri (tuntematon paikkamerkki kaataa buildin), build-haku (RPC → välimuisti → repon varateksti, ei verkkoa), kaupan ajoaikainen täyttö
//  * voucher_note, timeline(_text), description_en, public_treatment_horizon_days, p_addons (pyyhe) + virhekoodit → site_texts-avaimet (ui.checkout.error_<koodi>)
// Ei verkkoa, ei tietokantaa (tuotannon vastaukset fixtureina: tests/fixtures/prod-catalog-61.json, tests/fixtures/site-texts/rpc.json).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, rmSync, existsSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(join(root, p), 'utf8');
const J = (p) => JSON.parse(rd(p));
const work = mkdtempSync(join(tmpdir(), 'sivutekstit-'));
const tmp = join(work, 'shop');
cpSync(join(root, 'booking/shop/src'), tmp, { recursive: true });
cpSync(join(root, 'booking/shared/sb.js'), join(tmp, 'sb.js'));
const A = await import(pathToFileURL(join(tmp, 'treatments.js')));
const SB = await import(pathToFileURL(join(tmp, 'sb.js')));
const ADD = await import(pathToFileURL(join(tmp, 'treatment-addons.js')));
const ST = await import(pathToFileURL(join(tmp, 'site-texts.js')));
const L = await import(pathToFileURL(join(tmp, 'site-texts-logic.js')));
const M = await import(pathToFileURL(join(tmp, 'treatment-mock.js')));
const { T } = await import(pathToFileURL(join(tmp, 'i18n.js')));
const B = await import(pathToFileURL(join(root, 'src/site-texts.mjs')));
const FX = J('booking/tests/fixtures/prod-catalog-61.json');
const SITE_FX = J('tests/fixtures/site-texts/rpc.json');
const IMPORTED = J('content/site-texts.imported.json');   // 18.10.2026 tuotannon kantaan tuodut avaimet (admin_texts_import, Bottiavustus)
const row7 = () => FX.catalog.find((r) => r.id === 7);
const P7 = () => A.splitCatalog(FX.catalog, new Map()).treatments.find((x) => x.id === 7);
const quiet = { log() {}, warn() {} };
const q = { log: quiet };
const warnings = () => { const w = []; return { log() {}, warn: (m) => w.push(m), w }; };
test.after(() => rmSync(work, { recursive: true, force: true }));

// ================= paikkamerkit (§18.3) =================
const ctx = L.makeContext({ catalog: [{ id: 7, price: 49, duration_minutes: 120 }, { id: 8, price: 20.5, duration_minutes: 20 }], settings: { public_treatment_horizon_days: 14, timezone: 'Europe/Helsinki', obj: { a: 1 } } });
test('paikkamerkit: {{price:7}}, {{duration:7}}, {{setting:…}} täytetään; hinta "49 €" (fi) / "€49" (en); sentit vain tarvittaessa', () => {
  assert.equal(L.fillPlaceholders('Hinta {{price:7}}, kesto {{duration:7}}, ikkuna {{setting:public_treatment_horizon_days}} pv', ctx, 'fi'), 'Hinta 49 €, kesto 2 h, ikkuna 14 pv');
  assert.equal(L.fillPlaceholders('Price {{price:7}} / {{price:8}}', ctx, 'en'), 'Price €49 / €20.50');
  assert.equal(L.fillPlaceholders('{{price:8}}', ctx, 'fi'), '20,50 €');
  assert.equal(L.fillPlaceholders('ei paikkamerkkejä', ctx, 'fi'), 'ei paikkamerkkejä');
  assert.equal(L.fmtMinutes(20), '20 min'); assert.equal(L.fmtMinutes(90), '1 h 30 min'); assert.equal(L.fmtMinutes(120), '2 h');
});
test('TUNTEMATON PAIKKAMERKKI epäonnistuu: tuntematon laji, puuttuva tunniste, tuntematon tuote/asetus, virheellinen muoto, jäännös-{{ }}', () => {
  const bad = ['{{foo:7}}', '{{price}}', '{{price:99}}', '{{duration:99}}', '{{setting:ei_ole}}', '{{setting:obj}}', '{{PRICE:7}}', '{{price:7', 'price:7}}', '{{ price:7 }}', '{{price:7:8}}', '{{}}'];
  for (const t of bad) assert.throws(() => L.fillPlaceholders(`a ${t} b`, ctx, 'fi', { key: 'ui.x.y' }), (e) => e instanceof L.PlaceholderError, `pitää epäonnistua: ${t}`);
  try { L.fillPlaceholders('{{price:99}}', ctx, 'fi', { key: 'ui.x.y' }); } catch (e) { assert.equal(e.key, 'ui.x.y'); assert.equal(e.token, '{{price:99}}'); }
});
test('validateTexts: kaikki ongelmat listataan (tuntematon paikkamerkki, placeholders-kentän ristiriita); kunnolliset rivit läpi', () => {
  const rows = [
    { key: 'ui.a.ok', lang: 'fi', text: 'Hinta {{price:7}}', placeholders: ['{{price:7}}'] },
    { key: 'ui.a.bad', lang: 'fi', text: 'x {{foo:1}}', placeholders: ['{{foo:1}}'] },
    { key: 'ui.a.mismatch', lang: 'en', text: 'x {{price:7}}', placeholders: [] },
    { key: 'ui.a.plain', lang: 'fi', text: 'ei merkkejä' },
  ];
  const p = L.validateTexts(rows, ctx);
  assert.deepEqual(p.map((x) => x.key), ['ui.a.bad', 'ui.a.mismatch']);
  assert.match(p[0].problem, /tuntematon paikkamerkki/); assert.match(p[1].problem, /placeholders/);
  assert.deepEqual(L.validateTexts(rows.filter((r) => r.key.endsWith('ok') || r.key.endsWith('plain')), ctx), []);
});
test('textFor: en puuttuu → fi (fallback), ei tyhjää eikä raakaa avainta; tyhjät/virheelliset rivit ohitetaan; kaatuminen vain strict-tilassa', () => {
  const idx = L.indexTexts([{ key: 'ui.a.b', lang: 'fi', text: 'Suomeksi' }, { key: 'ui.a.b', lang: 'en', text: '   ' }, { key: 'ui.a.c', lang: 'en', text: 'Only EN' }, { key: 'Bad Key', lang: 'fi', text: 'x' }, { key: 'ui.a.d', lang: 'sv', text: 'x' }, { key: 'ui.a.e', lang: 'fi', text: 'Hinta {{price:99}}' }]);
  assert.deepEqual(textFor('ui.a.b', 'en'), { text: 'Suomeksi', lang: 'fi', fallback: true, version: null });
  assert.equal(textFor('ui.a.b', 'fi').fallback, false);
  assert.equal(textFor('ui.a.c', 'fi'), null, 'pelkkä EN-teksti ei korvaa FI:tä (fi pakollinen)'); assert.equal(textFor('ui.a.c', 'en').text, 'Only EN');
  assert.equal(textFor('Bad Key', 'fi'), null); assert.equal(textFor('ui.a.d', 'fi'), null); assert.equal(textFor('ui.puuttuu', 'fi'), null);
  assert.equal(textFor('ui.a.e', 'fi', ctx), null, 'lenient: paikkamerkin arvo puuttuu → null (ei raakaa {{…}})');
  assert.throws(() => textFor('ui.a.e', 'fi', ctx, { strict: true }), L.PlaceholderError);
  function textFor(k, lang, c = null, o = {}) { return L.textFor(idx, k, lang, c, o); }
});

// ================= build: haku, välimuisti, varateksti (§18.9 kohdat 5 ja 9) =================
const rpcOk = (rows, cat = FX.catalog, settings = FX.settings) => async (name) => name === 'public_get_site_texts' ? { ok: true, generated_at: '2026-10-18T10:00:00Z', texts: rows } : name === 'public_catalog' ? cat : name === 'public_settings' ? settings : null;
const rpcDown = async () => { throw new Error('RPC: HTTP 503'); };
const mkRows = (extra = []) => [{ key: 'ui.t.hello', lang: 'fi', text: 'Hei', version: 1, placeholders: [] }, { key: 'ui.t.price', lang: 'fi', text: 'Hinta {{price:7}}', version: 1, placeholders: ['{{price:7}}'] }, ...extra];
test('loadSiteTexts: live-haku onnistuu → source rpc, paikkamerkit täytettävissä tuotannon katalogista ja asetuksista, välimuisti kirjoitetaan', async () => {
  const dir = join(work, 'c1');
  const s = await B.loadSiteTexts({ env: {}, rpc: rpcOk(mkRows()), cacheDir: dir, log: quiet });
  assert.equal(s.source, 'rpc'); assert.equal(s.rows.length, 2); B.setSiteTexts(s);
  assert.equal(B.tx('ui.t.price', 'fi', q), 'Hinta 49 €'); assert.equal(B.tx('ui.t.price', 'en', q), 'Hinta 49 €', 'en puuttuu → fi-teksti (täytetään fi-muotoilulla)');
  assert.ok(existsSync(join(dir, 'snapshot.json')));
});
test('haku epäonnistuu → edellisen haun välimuisti → repon varateksti → (ei mitään) – build EI kaadu, varoitus lokiin', async () => {
  const dir = join(work, 'c2');
  await B.loadSiteTexts({ env: {}, rpc: rpcOk(mkRows()), cacheDir: dir, log: quiet });                     // täyttää välimuistin
  let w = warnings();
  const c = await B.loadSiteTexts({ env: {}, rpc: rpcDown, cacheDir: dir, log: w });
  assert.equal(c.source, 'cache'); assert.equal(c.rows.length, 2); assert.ok(w.w.some((m) => /välimuistia/.test(m)), 'varoitus: käytetään välimuistia');
  w = warnings();
  const fb = await B.loadSiteTexts({ env: {}, rpc: rpcDown, cacheDir: join(work, 'c3-tyhja'), log: w });   // ei välimuistia → repon content/site-texts.fallback.json
  assert.equal(fb.source, 'fallback'); assert.ok(fb.rows.length > 300, `varateksti ${fb.rows.length} riviä`); assert.ok(w.w.some((m) => /varatekstiä/.test(m)));
  const none = await B.loadSiteTexts({ env: {}, rpc: rpcDown, cacheDir: join(work, 'c4'), fallbackFile: join(work, 'ei-ole.json'), log: warnings() });
  assert.equal(none.source, 'none'); assert.equal(none.rows.length, 0);
  B.setSiteTexts(none);
  assert.equal(B.tx('ui.t.hello', 'fi', { fallback: 'Siirtymäajan teksti', log: quiet }), 'Siirtymäajan teksti', 'avainta ei ole → kutsujan varateksti (lokitetaan)');
  assert.throws(() => B.tx('ui.t.hello', 'fi', q), B.MissingTextError, 'ei varatekstiä → ei tyhjää eikä raakaa avainta');
});
test('ILMAN VERKKOA: ei Supabase-asetuksia / saavuttamaton osoite → varateksti, build ei kaadu; SITE_TEXTS_STRICT=1 kaataa', async () => {
  const s = await B.loadSiteTexts({ env: {}, cacheDir: join(work, 'c5'), log: quiet });
  assert.equal(s.source, 'fallback'); assert.ok(s.rows.some((r) => r.key === 'product.7.name'), 'tuotteen 7 nimi varatekstissä');
  const s2 = await B.loadSiteTexts({ env: { BOOKING_SUPABASE_URL: 'http://localhost:1', BOOKING_ANON_KEY: 'sb_publishable_x' }, cacheDir: join(work, 'c6'), log: quiet });
  assert.equal(s2.source, 'fallback');
  await assert.rejects(() => B.loadSiteTexts({ env: { SITE_TEXTS_STRICT: '1' }, rpc: rpcDown, cacheDir: join(work, 'c7'), log: quiet }), /SITE_TEXTS_STRICT/);
  const w = warnings(), sec = await B.loadSiteTexts({ env: { BOOKING_SUPABASE_URL: 'https://x.supabase.co', BOOKING_ANON_KEY: 'sb_secret_x' }, cacheDir: join(work, 'c8'), log: w });
  assert.equal(sec.source, 'fallback', 'sb_secret-avainta ei käytetä (vain julkinen avain) → varateksti'); assert.ok(w.w.some((m) => /sb_secret/.test(m)));
});
test('TUNTEMATON PAIKKAMERKKI KAATAA BUILDIN: live, välimuisti ja varateksti; kaatumisviesti nimeää avaimen', async () => {
  const bad = mkRows([{ key: 'ui.t.bad', lang: 'fi', text: 'Hinta {{price:99}}', placeholders: ['{{price:99}}'] }]);
  await assert.rejects(() => B.loadSiteTexts({ env: {}, rpc: rpcOk(bad), cacheDir: join(work, 'p1'), log: quiet }), /PAIKKAMERKKIVIRHE[\s\S]*ui\.t\.bad \[fi\]/);
  const unk = mkRows([{ key: 'ui.t.unk', lang: 'en', text: 'x {{colour:red}}', placeholders: ['{{colour:red}}'] }]);
  await assert.rejects(() => B.loadSiteTexts({ env: {}, rpc: rpcOk(unk), cacheDir: join(work, 'p2'), log: quiet }), /tuntematon paikkamerkki/);
  await assert.rejects(() => B.loadSiteTexts({ env: {}, rpc: rpcOk(mkRows([{ key: 'ui.t.set', lang: 'fi', text: '{{setting:ei_ole}}', placeholders: ['{{setting:ei_ole}}'] }])), cacheDir: join(work, 'p3'), log: quiet }), /arvoa ei löydy/);
  // välimuistista luettu rikkinäinen teksti kaataa myös (ei hiljaa raakaa {{…}} sivulle)
  const dir = join(work, 'p4'); mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'snapshot.json'), JSON.stringify({ generated_at: 'x', texts: bad, context: { catalog: [{ id: 7, price: 49, duration_minutes: 120 }], settings: {} } }));
  await assert.rejects(() => B.loadSiteTexts({ env: {}, rpc: rpcDown, cacheDir: dir, log: quiet }), /PAIKKAMERKKIVIRHE/);
  // katalogin haku epäonnistuu mutta teksti käyttää {{price:7}} → kb-snapshotin hinta (varalähde), ei kaadu
  const ok = await B.loadSiteTexts({ env: {}, rpc: async (n) => { if (n === 'public_catalog') throw new Error('x'); return rpcOk(mkRows())(n); }, cacheDir: join(work, 'p5'), log: quiet });
  B.setSiteTexts(ok); assert.equal(B.tx('ui.t.price', 'fi', q), 'Hinta 49 €');
});
test('tx(): en puuttuu → fi (lokitetaan); paikkamerkit täytetty; ei koskaan raakaa {{…}}-merkintää', async () => {
  const s = await B.loadSiteTexts({ env: { SITE_TEXTS_FIXTURE: '1' }, cacheDir: join(work, 'f1'), log: quiet }); B.setSiteTexts(s);
  assert.equal(s.source, 'fixture');
  assert.equal(B.tx('ui.test.price_line', 'fi', q), 'Hinta 49 €, kesto 2 h, varausikkuna 14 pv');
  assert.equal(B.tx('ui.test.price_line', 'en', q), 'Price €49, duration 2 h, booking window 14 days');
  const w = warnings(); assert.equal(B.tx('ui.test.fi_only', 'en', { log: w }), 'Vain suomeksi'); assert.ok(w.w.some((m) => /fi-tekstiä/.test(m)));
  for (const r of s.rows) for (const l of ['fi', 'en']) { try { assert.doesNotMatch(B.tx(r.key, l, q), /\{\{|\}\}/); } catch (e) { if (!(e instanceof B.MissingTextError)) throw e; } }
});
test('shopPayload: vain ui.*-avainalue, paikkamerkit täyttämättä (kauppa täyttää ajoaikana)', async () => {
  const s = await B.loadSiteTexts({ env: { SITE_TEXTS_FIXTURE: '1' }, cacheDir: join(work, 'f2'), log: quiet });
  const p = B.shopPayload(s);
  assert.ok(p.texts.length > 0 && p.texts.every((r) => r.key.startsWith('ui.')), 'vain ui.*');
  assert.ok(p.texts.some((r) => r.key === 'ui.test.price_line' && /\{\{price:7\}\}/.test(r.text)), 'paikkamerkki sellaisenaan');
  assert.ok(!p.texts.some((r) => r.key.startsWith('product.')), 'tuotetekstit tulevat katalogista, ei tiedostosta');
  assert.deepEqual(B.shopPayload(s, ['product.7.']).texts.map((r) => r.key).sort(), ['product.7.description', 'product.7.description', 'product.7.duration_text', 'product.7.name', 'product.7.name'].sort());
});
test('varateksti: committed content/site-texts.fallback.json on tuotannon julkaistu snapshot (vain DB:ssä olevat; tuodut ui.checkout.error_* mukana)', () => {
  const fb = J('content/site-texts.fallback.json');
  assert.ok(fb.texts.length >= 300 && fb.context.catalog.length > 0 && fb.context.settings.public_treatment_horizon_days);
  for (const it of IMPORTED) assert.equal(fb.texts.find((r) => r.key === it.key && r.lang === it.lang)?.text, it.text, `tuotu avain on kannassa ja varatekstissä sellaisenaan: ${it.key} [${it.lang}]`);
  assert.ok(fb.texts.every((r) => r.key && r.lang && r.text.trim()));
  assert.deepEqual(L.validateTexts(fb.texts, L.makeContext({ catalog: fb.context.catalog, settings: fb.context.settings, vars: true })), []);
});

// ================= build-integraatio (ajaa oikean build-skriptin) =================
const run = (args, env) => spawnSync('node', args, { cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, ARTICLES_FIXTURE: '1', ARTICLES_IMAGES: '0', ...env } });
test('scripts/build.mjs: tuntematon paikkamerkki → exit ≠ 0 ja virhe nimeää avaimen; fixture-build menee läpi', () => {
  const badFx = join(work, 'bad-fixture.json'); const fx = JSON.parse(JSON.stringify(SITE_FX)); fx.texts.push({ key: 'ui.test.tuntematon', lang: 'fi', text: 'Hinta {{price:999}}', version: 1, placeholders: ['{{price:999}}'] }); writeFileSync(badFx, JSON.stringify(fx));
  const r = run(['scripts/build.mjs'], { DIST: join(work, 'dist-bad'), SITE_ENV: 'test', SITE_TEXTS_FIXTURE: badFx, ARTICLES_CACHE_DIR: join(work, 'ac1'), SITE_TEXTS_CACHE_DIR: join(work, 'sc1') });
  assert.notEqual(r.status, 0, 'build pitää kaatua'); assert.match(r.stderr + r.stdout, /PAIKKAMERKKIVIRHE[\s\S]*ui\.test\.tuntematon/);
  const ok = run(['scripts/build.mjs'], { DIST: join(work, 'dist-ok'), SITE_ENV: 'test', SITE_TEXTS_FIXTURE: '1', ARTICLES_CACHE_DIR: join(work, 'ac2'), SITE_TEXTS_CACHE_DIR: join(work, 'sc2') });
  assert.equal(ok.status, 0, ok.stderr + ok.stdout); assert.match(ok.stdout + ok.stderr, /site-texts: fixture; \d+ riviä/);
});
test('kauppa-build: booking/site-texts.json (vain ui.*), siteTextsUrl sivulle, uudet moduulit mukaan; ilman verkkoa varateksti (ei kaadu)', () => {
  const dist = join(work, 'shop-dist');
  const r = run(['booking/shop/build.mjs'], { SHOP_DIST: dist, SITE_ENV: 'test', SITE_URL: 'http://localhost:4180', SITE_TEXTS_FIXTURE: '1', ARTICLES_CACHE_DIR: join(work, 'ac3'), SITE_TEXTS_CACHE_DIR: join(work, 'sc3') });
  assert.equal(r.status, 0, r.stderr + r.stdout);
  const j = JSON.parse(readFileSync(join(dist, 'booking/site-texts.json'), 'utf8'));
  assert.ok(j.texts.length >= 10 && j.texts.every((x) => x.key.startsWith('ui.'))); assert.equal(j.source, 'fixture');
  for (const f of ['treatment-addons.js', 'site-texts.js', 'site-texts-logic.js']) assert.ok(existsSync(join(dist, 'booking', f)), `${f} kopioitu`);
  for (const p of ['varaa/index.html', 'en/book/index.html']) assert.match(readFileSync(join(dist, p), 'utf8'), /"siteTextsUrl":"\/booking\/site-texts\.json"/);
  const dist2 = join(work, 'shop-dist2');
  const r2 = run(['booking/shop/build.mjs'], { SHOP_DIST: dist2, SITE_ENV: 'test', SITE_URL: 'http://localhost:4180', BOOKING_SUPABASE_URL: 'http://localhost:1', BOOKING_ANON_KEY: 'sb_publishable_x', ARTICLES_CACHE_DIR: join(work, 'ac4'), SITE_TEXTS_CACHE_DIR: join(work, 'sc4') });
  assert.equal(r2.status, 0, 'haku epäonnistuu → varateksti, build ei kaadu\n' + r2.stderr);
  assert.match(r2.stdout + r2.stderr, /site-texts: fallback; \d+ riviä/); assert.match(r2.stderr, /site-texts: VAROITUS: haku epäonnistui/);
  const fbUi = JSON.parse(readFileSync(join(dist2, 'booking/site-texts.json'), 'utf8')).texts; assert.ok(fbUi.length >= 10 && fbUi.every((x) => x.key.startsWith('ui.')), 'varateksti (kannan tuodut ui.*-avaimet) päätyy kauppaan');
});

// ================= kaupan ajoaikainen täyttö =================
test('kauppa: createTexts täyttää paikkamerkit ajoajan katalogista/asetuksista; en puuttuu → fi; avain puuttuu / arvo puuttuu → null', () => {
  const rows = [...SITE_FX.texts];
  const t = ST.createTexts({ lang: 'fi', rows, format: { price: (n) => `${n} €`, duration: (m) => L.fmtMinutes(m) } });
  assert.equal(t.tx('ui.test.price_line'), null, 'ennen dataa: paikkamerkin arvoa ei ole → null (ei raakaa {{…}})');
  t.setData({ catalog: FX.catalog, settings: FX.settings });
  assert.equal(t.tx('ui.test.price_line'), 'Hinta 49 €, kesto 2 h, varausikkuna 14 pv');
  t.setData({ catalog: FX.catalog.map((r) => (r.id === 7 ? { ...r, price: 55 } : r)), settings: { public_treatment_horizon_days: 21 } });
  assert.equal(t.tx('ui.test.price_line'), 'Hinta 55 €, kesto 2 h, varausikkuna 21 pv', 'hinta ja ikkuna päivittyvät ajoaikaisesta datasta');
  const en = ST.createTexts({ lang: 'en', rows, format: { price: (n) => `€${n}` } }); en.setData({ catalog: FX.catalog, settings: FX.settings });
  assert.equal(en.tx('ui.test.price_line'), 'Price €49, duration 2 h, booking window 14 days'); assert.equal(en.tx('ui.test.fi_only'), 'Vain suomeksi'); assert.equal(en.tx('ui.ei.ole'), null);
  assert.equal(en.has('ui.test.fi_only'), true); assert.equal(en.has('ui.ei.ole'), false);
});
test('kauppa: loadShopTexts ei heitä (puuttuva tiedosto / virhe / rikkinäinen JSON → [])', async () => {
  assert.deepEqual(await ST.loadShopTexts(null), []);
  assert.deepEqual(await ST.loadShopTexts('/x', async () => ({ ok: false })), []);
  assert.deepEqual(await ST.loadShopTexts('/x', async () => { throw new Error('offline'); }), []);
  assert.deepEqual(await ST.loadShopTexts('/x', async () => ({ ok: true, json: async () => { throw new Error('bad json'); } })), []);
  assert.equal((await ST.loadShopTexts('/x', async () => ({ ok: true, json: async () => ({ texts: [{ key: 'ui.a.b', lang: 'fi', text: 'x' }] }) }))).length, 1);
});

// ================= tuote 7: kentät (booking_61, §18.11) =================
test('tuote 7: voucher_note(_en) erillisenä (ei kuvauksessa), description_en käyttöön, timeline-kentät läpi; muut tuotteet ilman kenttiä ennallaan', () => {
  const p = P7(), r = row7();
  assert.equal(p.voucher_note, r.voucher_note); assert.equal(p.voucher_note_en, r.voucher_note_en);
  assert.match(p.voucher_note, /Elämyslahjojen lahjakortilla/); assert.match(p.voucher_note_en, /Elämyslahjat gift card/);
  assert.ok(!p.description.includes(p.voucher_note), 'lahjakorttihuomautus ei ole enää kuvauksessa (kannassa)');
  assert.equal(p.description_en, r.description_en); assert.match(p.description_en, /^Open sauna ritual/);
  assert.equal(p.timeline.length, 2, 'booking_64: vain näkyvät jaksot'); assert.equal(p.timeline_text, r.timeline_text); assert.equal(p.timeline_text_en, r.timeline_text_en);
  const t = A.splitCatalog(FX.catalog, new Map()).treatments.find((x) => x.id === 10);
  assert.equal(t.voucher_note, undefined); assert.equal(t.timeline, undefined); assert.equal(A.isPackage(t), false);
});
test('varausikkuna: public_settings().public_treatment_horizon_days (14) ohjaa; puuttuessa vanhan kannan varaus', () => {
  assert.equal(FX.settings.public_treatment_horizon_days, 14);
  assert.equal(A.horizonDays(FX.settings), 14); assert.equal(A.horizonDays({ public_treatment_horizon_days: 21 }), 21); assert.equal(A.horizonDays({ public_treatment_horizon_days: '30' }), 30);
  assert.equal(A.horizonDays({}), A.POLICY.horizonDays); assert.equal(A.horizonDays(null), A.POLICY.horizonDays);
  const ui = rd('booking/shop/src/treatment-ui.js'); assert.match(ui, /A\.horizonDays\(state\.settings\)/);
  assert.match(rd('booking/shop/src/shop.js'), /treatmentHorizon\(state\.settings\)/);
});
test('mock: tuotteen 7 katalogirivi vastaa tuotannon riviä (timeline ilman taukoa, timeline_text(_en), voucher_note(_en), description(_en), addons_enabled, allowed_addons)', () => {
  const m = M.catalogEntries().find((x) => x.id === 7), r = row7();
  for (const k of ['timeline', 'timeline_text', 'timeline_text_en', 'voucher_note', 'voucher_note_en', 'description', 'description_en', 'name', 'name_en', 'price', 'price_type', 'duration_minutes', 'duration_text', 'min_persons', 'max_persons', 'booking_kind', 'category', 'slot_grid_minutes', 'addons_enabled', 'allowed_addons'])
    assert.deepEqual(m[k], r[k], `mock ≠ tuotanto: ${k}`);
});

// ================= lisäpalvelut: p_addons (pyyhe tuotteelle 7) =================
test('RPC-argumentit: p_addons vain kun valittu ({id, quantity}); vanha kutsu (ei p_addons) ennallaan; option + addons yhdessä', () => {
  const base = { start: '2026-10-25T14:00:00.000Z', persons: 2, name: 'A B', email: 'a@b.fi', phone: '+358401234567', marketing: false, locale: 'fi', note: '', kind: 'private', company: null };
  const p = { id: 7 };
  const none = A.args.create(p, { ...base, option: null, addons: [] });
  assert.ok(!('p_addons' in none), 'ei lisäpalveluita → ei p_addons'); assert.ok(!('p_option_code' in none));
  assert.ok(!('p_addons' in A.args.create(p, base)), 'addons-kenttä puuttuu → ennallaan');
  assert.equal(Object.keys(none).length, 11, 'vanha kutsu: sama 11 parametria kuin ennen booking_61:tä');
  const c = A.args.create(p, { ...base, addons: [{ id: 5, quantity: 2, extra: 'x' }] });
  assert.deepEqual(c.p_addons, [{ id: 5, quantity: 2 }], 'vain id + quantity'); assert.equal(c.p_product_id, 7);
  assert.deepEqual(A.args.create({ id: 10 }, { ...base, option: 'hunajahoito', addons: [{ id: 5, quantity: 1 }] }).p_option_code, 'hunajahoito');
});
test('lisäpalvelut: tuotteen addons_enabled + allowed_addons[] (katalogi) rajaa, hinta/nimi/max public_addons()-funktiosta; ei kovakoodattua tuotelistaa', async () => {
  const p7 = P7(), p10 = A.splitCatalog(FX.catalog, new Map()).treatments.find((x) => x.id === 10), p1 = FX.catalog.find((r) => r.id === 1);
  assert.equal(p7.addons_enabled, true); assert.deepEqual(p7.allowed_addons, ['pyyhe']); assert.deepEqual(A.allowedAddonCodes(p7), ['pyyhe']);
  assert.equal(A.addonsAllowed(p7), true); assert.equal(A.addonsAllowed(p10), false, 'tuote 10: addons_enabled=false'); assert.equal(A.addonsAllowed({ id: 7 }), false, 'id yksin ei riitä (ei ADDON_PRODUCT_IDS-vakiota)');
  assert.equal(A.ADDON_PRODUCT_IDS, undefined); assert.equal(p1.addons_enabled, true, 'vuorotuotteilla kaikki kolme (ei kuulu kassapolkuun)');
  assert.equal(A.addonsAllowed({ id: 7, addons_enabled: true, allowed_addons: [] }), false); assert.equal(A.addonsAllowed({ id: 7, addons_enabled: false, allowed_addons: ['pyyhe'] }), false);
  const ad = A.normAddons(FX.addons, A.allowedAddonCodes(p7));
  assert.deepEqual(ad.map((a) => [a.id, a.code, a.price, a.max_per_person]), [[5, 'pyyhe', 5, 20]], 'vain tuotteelle sallittu (allowed_addons); turvenaamio/saunavihta pois');
  assert.equal(ad[0].name, 'Pyyhe'); assert.equal(ad[0].name_en, 'Towel');
  assert.equal(A.normAddons(FX.addons.map((a) => (a.id === 5 ? { ...a, price: '7.50' } : a)), ['pyyhe'])[0].price, 7.5, 'hinta tulee palvelimelta');
  assert.deepEqual(A.normAddons([{ id: 5, code: 'pyyhe', price: 5, active: false }], ['pyyhe']), [], 'passiivinen ei näy');
  assert.deepEqual(A.normAddons(null), []); assert.deepEqual(A.normAddons([{ id: 9, code: 'pyyhe' }], ['pyyhe']), [], 'hinta puuttuu → pois');
  let calls = 0;
  SB.setRpcOverride(async (name) => { calls++; assert.equal(name, 'public_addons'); return FX.addons; });
  try {
    assert.deepEqual((await A.loadAddons(p7)).map((a) => a.code), ['pyyhe']); assert.equal(calls, 1);
    assert.deepEqual(await A.loadAddons(p10), [], 'addons_enabled=false: ei lisäpalveluita'); assert.deepEqual(await A.loadAddons({ id: 7 }), []); assert.equal(calls, 1, 'ei turhaa kutsua');
    SB.setRpcOverride(async () => { throw new SB.ApiError('x', { status: 404, code: 'PGRST202' }); });
    assert.deepEqual(await A.loadAddons(p7), [], 'RPC puuttuu / virhe → ei lisäpalveluita, kassa toimii');
  } finally { SB.setRpcOverride(null); }
});
test('lisäpalvelun määrä: enintään henkilömäärä × max/hlö, korkeintaan 99; payload ja summa', () => {
  const [towel] = A.normAddons(FX.addons, ['pyyhe']);
  assert.equal(A.addonLimit(towel, 1), 20); assert.equal(A.addonLimit(towel, 6), 99, '6 × 20 = 120 → 99'); assert.equal(A.addonLimit({ max_per_person: null }, 3), 99); assert.equal(A.addonLimit({ max_per_person: 2 }, 3), 6);
  const qty = new Map([[5, 3]]);
  assert.deepEqual(A.addonsPayload([towel], qty), [{ id: 5, quantity: 3 }]); assert.equal(A.addonsSum([towel], qty), 15);
  assert.deepEqual(A.addonsPayload([towel], new Map([[5, 0]])), []); assert.equal(A.addonsSum([towel], new Map()), 0);
});
test('virhekoodit: invalid_addons, addon_not_found, addon_inactive, addon_not_allowed, addon_quantity → ui.checkout.error_<koodi> (ei kovakoodattua viestiä)', () => {
  const codes = ['invalid_addons', 'addon_not_found', 'addon_inactive', 'addon_not_allowed', 'addon_quantity'];
  assert.deepEqual(A.ADDON_ERRORS, codes);
  for (const c of codes) { assert.equal(A.isAddonError(c), true); assert.equal(A.errorTextKey(c), `ui.checkout.error_${c}`); }
  assert.equal(A.isAddonError('option_required'), false); assert.equal(A.isAddonError('slot_unavailable'), false);
  // jokaiselle koodille FI + EN -teksti tuonnissa (§18.9/4) ja fixturessa (tuonnin jälkeinen tila)
  const t = ST.createTexts({ lang: 'fi', rows: SITE_FX.texts }), e = ST.createTexts({ lang: 'en', rows: SITE_FX.texts });
  for (const c of codes) {
    for (const lang of ['fi', 'en']) assert.ok(IMPORTED.some((x) => x.key === A.errorTextKey(c) && x.lang === lang && x.text.trim()), `tuonnissa ${c} [${lang}]`);
    assert.ok(t.tx(A.errorTextKey(c)) && e.tx(A.errorTextKey(c)) && t.tx(A.errorTextKey(c)) !== e.tx(A.errorTextKey(c)), `${c}: FI ≠ EN`);
  }
  const empty = ST.createTexts({ lang: 'fi', rows: [] });
  assert.equal(empty.tx(A.errorTextKey('addon_quantity')), null, 'avain puuttuu kannasta → null → UI käyttää palvelimen message-kenttää, ei raakaa avainta');
  // errMsg-ketju: site_text → palvelimen message → yleisviesti (treatment-ui.js)
  const ui = rd('booking/shop/src/treatment-ui.js');
  assert.match(ui, /A\.isAddonError\(r\.code\) \? tx\(A\.errorTextKey\(r\.code\)\) \|\| t\.errorGeneric/);
});
test('tuontilista content/site-texts.imported.json (tuotu tuotantoon 18.10.) noudattaa admin_texts_import-sääntöjä (booking_62) ja §18.2-nimeämistä', () => {
  assert.equal(IMPORTED.length, 10); const seen = new Set();
  for (const it of IMPORTED) {
    assert.match(it.key, /^[a-z0-9_]+(\.[a-z0-9_-]+)+$/); assert.ok(it.key.length <= 120); assert.match(it.key, /^ui\.checkout\.error_[a-z_]+$/);
    assert.ok(!/^(product|faq|policy|addon|option|giftpkg|schedule|location|hours|event|business|timeline|product_voucher)\.[0-9a-z_-]+\./.test(it.key), 'varattu prefiksi');
    assert.ok(['fi', 'en'].includes(it.lang)); assert.ok(['normal', 'protected'].includes(it.class)); assert.equal(it.class, 'normal'); assert.ok(['plain', 'lite'].includes(it.kind));
    assert.ok(it.max_len >= it.text.length && it.max_len <= 100000); assert.ok(it.text.trim() && !/<\s*\/?\s*[A-Za-z!?]|javascript:|\]\(/i.test(it.text), 'ei HTML:ää / linkkimerkintää');
    assert.deepEqual([...it.placeholders].sort(), L.tokensOf(it.text).sort(), 'placeholders vastaa tekstiä');
    assert.ok(!/\d|€|@|https?:|www\./i.test(it.text), 'ei numeroita/€/linkkejä → ei eskalaatiota (§18.7), ei käsin kirjoitettuja lukuja (§18.3)');
    assert.ok(!seen.has(`${it.key}|${it.lang}`), 'duplikaatti'); seen.add(`${it.key}|${it.lang}`);
  }
  assert.equal(new Set(IMPORTED.map((x) => x.key)).size, 5);
});
test('lisäpalveluvalitsin ja kassa: ei kovakoodattuja asiakasnäkyviä merkkijonoja (kommentit pois); tekstit kaupan olemassa olevista t.addons*-teksteistä', () => {
  const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
  const addons = strip(rd('booking/shop/src/treatment-addons.js'));
  assert.ok(!/[äöÄÖ]/.test(addons), 'treatment-addons.js: ei suomenkielisiä merkkijonoja'); assert.match(addons, /t\.addonsTitle/); assert.match(addons, /t\.addonsHint/); assert.match(addons, /t\.addonQty/);
  for (const lang of ['fi', 'en']) for (const k of ['addonsTitle', 'addonsHint', 'addonQty', 'addonsTotal']) assert.ok(T[lang][k], `t.${k} [${lang}]`);
  assert.equal(T.fi.tr.errors.addon_quantity, undefined, 'hoitopolun tr.errors ei sisällä uusia kovakoodattuja lisäpalveluviestejä');
});

// ================= mock = palvelinsopimus (booking_61) =================
const NOW = Date.parse('2026-10-18T10:00:00Z');
const SNAP = M.snapshotBookings();
const mk = (extra = {}, persons = 2) => {
  let start = null;
  for (const d of ['2026-10-25', '2026-10-24', '2026-10-31']) {
    const av = M.treatmentRpc('public_treatment_availability', { p_product_id: 7, p_from: d, p_to: d, p_persons: persons }, NOW).body;
    if (av.length) { start = av[0].starts_at; break; }
  }
  assert.ok(start, 'vapaa aika mockissa');
  return M.treatmentRpc('public_create_treatment_booking', { p_product_id: 7, p_start: start, p_persons: persons, p_name: 'Testi Testaaja', p_email: `t${Math.random()}@example.com`, p_phone: '+358401234567', p_customer_kind: 'private', ...extra }, NOW).body;
};
test('mock: p_addons pyyhe → total = hinta + lisäpalvelut, addons_total; vanha kutsu ilman p_addons ennallaan (98 €)', () => {
  M.restoreBookings(SNAP);
  const plain = mk({}); assert.equal(plain.ok, true); assert.equal(plain.total, 98); assert.equal(plain.addons_total, 0);
  const r = mk({ p_addons: [{ id: 5, quantity: 3 }] }, 2); assert.equal(r.ok, true, JSON.stringify(r)); assert.equal(r.addons_total, 15); assert.equal(r.total, 98 + 15);
  const byCode = mk({ p_addons: [{ code: 'pyyhe', quantity: 1 }] }, 1); assert.equal(byCode.ok, true); assert.equal(byCode.total, 49 + 5);
  const g = M.treatmentRpc('public_get_booking', { p_token: r.token }, NOW).body;
  assert.equal(g.total, 113); assert.deepEqual(g.addons.map((a) => [a.name, a.name_en, a.quantity, a.unit_price]), [['Pyyhe', 'Towel', 3, 5]]);
  assert.equal(mk({ p_addons: null }, 1).total, 49); assert.equal(mk({ p_addons: [] }, 1).ok, true);
});
test('mock: virhekoodit invalid_addons, addon_not_found, addon_inactive, addon_not_allowed (turvenaamio/saunavihta), addon_quantity; virhe ei luo varausta', () => {
  M.restoreBookings(SNAP);
  const code = (a, n = 2) => { const r = mk({ p_addons: a }, n); assert.equal(r.ok, false, JSON.stringify(a)); return r.code; };
  assert.equal(code('pyyhe'), 'invalid_addons'); assert.equal(code({ id: 5, quantity: 1 }), 'invalid_addons'); assert.equal(code([null]), 'invalid_addons'); assert.equal(code([{ quantity: 1 }]), 'invalid_addons');
  assert.equal(code([{ id: 12345, quantity: 1 }]), 'addon_not_found'); assert.equal(code([{ code: 'ei_ole', quantity: 1 }]), 'addon_not_found');
  assert.equal(code([{ id: 99, quantity: 1 }]), 'addon_inactive');
  assert.equal(code([{ id: 1, quantity: 1 }]), 'addon_not_allowed'); assert.equal(code([{ id: 2, quantity: 1 }]), 'addon_not_allowed');
  assert.equal(code([{ id: 5, quantity: 0 }]), 'addon_quantity'); assert.equal(code([{ id: 5, quantity: -1 }]), 'addon_quantity'); assert.equal(code([{ id: 5, quantity: 1.5 }]), 'addon_quantity'); assert.equal(code([{ id: 5, quantity: 41 }], 2), 'addon_quantity', '2 hlö × 20 = 40 enintään');
  assert.equal(mk({ p_addons: [{ id: 5, quantity: 40 }] }, 2).ok, true);
  assert.equal(M.snapshotBookings().bookings.length, 1, 'virheelliset yritykset eivät luoneet varauksia');
  for (const c of A.ADDON_ERRORS) assert.ok(IMPORTED.some((x) => x.key === A.errorTextKey(c)), `${c}: teksti tuontilistassa`);
});
test('mock: kaikkien katalogirivien addons_enabled / allowed_addons = tuotanto (tuote 7: true, [pyyhe]; 8, 10: false, [])', () => {
  for (const r of FX.catalog.filter((x) => [7, 8, 10].includes(x.id))) { const m = M.catalogEntries().find((x) => x.id === r.id); assert.equal(m.addons_enabled, r.addons_enabled, `${r.id}`); assert.deepEqual(m.allowed_addons, r.allowed_addons, `${r.id}`); }
  assert.deepEqual(row7().timeline.map((t) => t.kind), ['ritual', 'smoke_sauna'], 'tuotannon timeline[] ei sisällä taukoa (booking_64)'); assert.ok(!/tauko/i.test(row7().timeline_text + row7().duration_text));
});
test('mock: lisäpalvelut = tuotannon public_addons() (id, koodi, hinta 5 €, EN-nimi, applies_modes, max/hlö)', () => {
  const pick = (a) => ({ id: a.id, code: a.code, name: a.name, name_en: a.name_en, price: +a.price, applies_modes: a.applies_modes, max_per_person: a.max_per_person });
  assert.deepEqual(M.ADDONS.map(pick), FX.addons.map(pick));
});

// ================= CI =================
test('CI: pages.yml ajaa sivutekstitestit, välimuistittaa tekstit ja käynnistyy site-texts-changed-tapahtumasta', () => {
  const y = rd('.github/workflows/pages.yml');
  assert.match(y, /node --test booking\/tests\/sivutekstit\.test\.mjs/); assert.match(y, /site-texts-changed/); assert.match(y, /\.cache\/site-texts/);
  assert.match(y, /SITE_TEXTS_FIXTURE=1/);
});
