// Sivutekstit osa 3 / PR 2 (sopimus §18): staattisten sivujen tekstit avaimiksi + tuontitiedosto + DB-peitto repon oletuksilla.
//  * content/site-texts.imported-pr64.json noudattaa admin_texts_import-sääntöjä (booking_62) ja §18.2-nimeämistä; ei päällekkäisiä avaimia PR 1:n (#61) eikä tuotannon kanssa; generoitu koodista
//  * peitto (applyContentTexts): DB-teksti kun saman kielen rivi on, muuten repon oletus; paikkamerkit {{price:ID}}, {{duration:ID}}, {{var:n}}; **lihavointi** → <strong>
//  * kierros: tuontitiedosto peittona → sivusto tavu tavulta sama kuin ilman peittoa (HTML ei muutu); muutettu teksti näkyy sivulla
//  * ui.shop.error_generic: palvelimen raaka message ei enää asiakkaalle kaupassa
// Ei verkkoa eikä tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdtempSync, rmSync, writeFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(join(root, p), 'utf8');
const J = (p) => JSON.parse(rd(p));
const imp = (p) => import(pathToFileURL(join(root, p)));
const work = mkdtempSync(join(tmpdir(), 'sivutekstit-sivut-'));
test.after(() => rmSync(work, { recursive: true, force: true }));

const L = await imp('booking/shop/src/site-texts-logic.js');
const CT = await imp('src/content-texts.mjs');
const B = await imp('src/site-texts.mjs');
const { site } = await imp('src/lib.mjs');
const { cfg: ART } = await imp('src/articles/config.mjs');

const PENDING = J('content/site-texts.imported-pr64.json');
const PR61 = J('content/site-texts.imported-pr61.json');
const IMPORTED = J('content/site-texts.imported.json');
const FALLBACK = J('tests/fixtures/site-texts/fallback-pre-pr64.json');      // tuotannon julkaistut tekstit ENNEN PR 2:n tuontia (varateksti ennen synkkaa; nykyinen fallback sisältää tuodut rivit)
const AREAS = /^(page\.[a-z0-9_]+|seo\.[a-z0-9_]+|nav\.(main|info)|ui\.(site|footer|reviews|training_banner|articles|card|alt|session))\./;
const quiet = { warn: () => {}, log: () => {} };

const snap = () => JSON.stringify([site.ui, site.sessionLabels, ART.ui, CT.cards, CT.alts, ...readdirSync(join(root, 'content/pages')).map((f) => CT.pageDoc(f.slice(0, -5)))]);
const BASE = snap();
const stateWith = async (rows, extra = {}) => {
  const f = join(work, `fx-${Math.random().toString(36).slice(2)}.json`);
  writeFileSync(f, JSON.stringify({ ...FALLBACK, texts: [...FALLBACK.texts, ...rows.map((r) => ({ key: r.key, lang: r.lang, text: r.text, version: 1, placeholders: r.placeholders ?? L.tokensOf(r.text) }))] }));
  return { file: f, state: await B.loadSiteTexts({ env: { SITE_TEXTS_FIXTURE: f }, log: quiet, cacheDir: join(work, 'cache') }) };
};

test('tuontitiedosto noudattaa admin_texts_import-sääntöjä ja §18.2-nimeämistä', () => {
  assert.ok(Array.isArray(PENDING) && PENDING.length > 500, `rivejä ${PENDING.length}`);
  const seen = new Set();
  for (const r of PENDING) {
    const w = `${r.key} [${r.lang}]`;
    assert.match(r.key, /^[a-z0-9_]+(\.[a-z0-9_-]+)+$/, w); assert.ok(r.key.length <= 120, w);
    assert.match(r.key, AREAS, `${w}: avainalue`);                       // ei varattuja lähdetaulun alueita (product./faq./policy./…)
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.ok(['normal', 'protected'].includes(r.class), `${w}: class`);
    assert.ok(['plain', 'lite'].includes(r.kind), w);
    assert.ok(r.text && r.text === r.text.trim(), `${w}: tyhjä tai reunavälit`);
    assert.ok(r.max_len >= r.text.length && r.max_len <= 4000, `${w}: max_len`);
    assert.doesNotMatch(r.text, /<\s*\/?\s*[A-Za-z!?]|javascript:|\bon[a-z]+\s*=\s*["']/i, `${w}: raaka HTML ei sallittu (booking_60)`);
    assert.doesNotMatch(r.text, /\]\(/, `${w}: linkkimerkintä`);
    assert.doesNotMatch(r.text, /[\x01-\x08\x0B\x0C\x0E-\x1F]/, w);
    assert.deepEqual([...r.placeholders].sort(), [...new Set(L.tokensOf(r.text))].sort(), `${w}: placeholders ≠ tekstin merkinnät`);
    for (const tok of L.tokensOf(r.text)) { assert.match(tok, L.TOKEN_RE, `${w}: ${tok}`); assert.ok(L.KINDS.includes(tok.slice(2, -2).split(':')[0]), `${w}: tuntematon lajike ${tok}`); }
    assert.doesNotMatch(r.text.replace(/\{\{[^{}]*\}\}/g, ''), /[{}]/, `${w}: yksittäinen aaltosulku (käytä {{var:nimi}})`);
    assert.ok(r.reason && r.reason.length <= 300, `${w}: perustelu`);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), `${w}: kaksoiskappale`); seen.add(`${r.key}|${r.lang}`);
  }
  // FI+EN molemmat; ainoa poikkeus: tietosuoja (repossa vain suomenkielinen sivu)
  for (const k of new Set(PENDING.map((r) => r.key))) { if (/^(page|seo)\.privacy\./.test(k)) continue; assert.ok(seen.has(`${k}|fi`) && seen.has(`${k}|en`), `${k}: FI+EN molemmat (§18.9 kohta 2)`); }
  assert.ok(PENDING.filter((r) => /^(page|seo)\.privacy\./.test(r.key)).every((r) => r.lang === 'fi' && r.class === 'protected'));
});
test('tuontitiedosto: ei päällekkäisiä avaimia PR 1:n (#61), aiemman tuonnin eikä tuotannon (varateksti) kanssa; ≤ 3 erää', () => {
  const have = new Set([...PR61, ...IMPORTED, ...FALLBACK.texts].map((r) => `${r.key}|${r.lang}`));
  assert.deepEqual(PENDING.filter((r) => have.has(`${r.key}|${r.lang}`)).map((r) => `${r.key} [${r.lang}]`), []);
  assert.ok(Math.ceil(PENDING.length / 500) <= 3, `${PENDING.length} riviä`);
});
const PAGE_EXTRA = J('content/site-texts.imported-pr75.json').filter((r) => !r.key.startsWith('email.'));
test('tuontitiedosto on generoitu koodista: vanhat avaimet = imported-pr64, Yrityksille-lisäys = imported-pr75 (sivut)', () => {
  const prod = join(work, 'prod.json'), out = join(work, 'out.json');
  writeFileSync(prod, JSON.stringify({ ok: true, texts: FALLBACK.texts }));
  const r = spawnSync('node', [join(root, 'scripts/site-texts-extract-pages.mjs'), '--prod', prod, '--out', out], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const rows = JSON.parse(readFileSync(out, 'utf8'));
  const oldIds = new Set(PENDING.map((x) => `${x.key}|${x.lang}`));
  assert.deepEqual(rows.filter((x) => oldIds.has(`${x.key}|${x.lang}`)), PENDING);
  assert.deepEqual(rows.filter((x) => !oldIds.has(`${x.key}|${x.lang}`)), PAGE_EXTRA);
});
test('generaattori ei lisää riviä jos avain on jo tuotannossa (vain uudet avaimet) eikä kosketa tuotannon tekstiä', () => {
  const have = PENDING.filter((r) => r.key.startsWith('seo.') || r.key === 'ui.site.book');
  const prod = join(work, 'prod2.json'), out = join(work, 'out2.json');
  writeFileSync(prod, JSON.stringify({ ok: true, texts: [...FALLBACK.texts, ...have.map((r) => ({ key: r.key, lang: r.lang, text: 'tuotannon teksti', version: 1, placeholders: [] }))] }));
  const r = spawnSync('node', [join(root, 'scripts/site-texts-extract-pages.mjs'), '--prod', prod, '--out', out], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const rows = JSON.parse(readFileSync(out, 'utf8'));
  assert.equal(rows.length, PENDING.length - have.length + PAGE_EXTRA.length);
  assert.ok(!rows.some((x) => x.key.startsWith('seo.') || x.key === 'ui.site.book'));
  for (const x of PAGE_EXTRA) assert.ok(rows.some((r) => r.key === x.key && r.lang === x.lang), x.key);
  assert.notEqual(spawnSync('node', [join(root, 'scripts/site-texts-extract-pages.mjs'), '--prod', join(work, 'ei-ole.json')], { encoding: 'utf8' }).status, 0);
});
test('avainkartta: kuolleet ja tekniset kentät pois, nimeäminen §18.2, PR 1:n kaupan avaimet eivät törmää', () => {
  const keys = new Set(PENDING.map((r) => r.key));
  for (const k of ['ui.site.rights', 'ui.site.brand_kicker', 'ui.site.external_note', 'ui.site.terms_title', 'ui.articles.page_title', 'ui.articles.read_article_about', 'page.front.hero.img', 'seo.front.og', 'page.front.tiles.1.icon']) assert.ok(!keys.has(k), `${k} ei kuulu tuontiin`);
  for (const k of ['seo.front.title', 'page.front.hero.title', 'nav.main.sauna', 'nav.info.pysakointi', 'ui.footer.contact', 'ui.site.directions', 'ui.site.business_id', 'ui.site.open_in_maps', 'ui.site.extra_guest', 'ui.site.approx', 'ui.reviews.title', 'ui.articles.read_more', 'ui.card.sauna.yleinen.title', 'ui.alt.ovi_kaiverrus', 'ui.session.men', 'page.booking_info.hero.title']) assert.ok(keys.has(k), `${k} puuttuu`);
  const shop = new Set([...FALLBACK.texts.map((r) => r.key), ...PR61.map((r) => r.key)]);
  for (const k of keys) assert.ok(!shop.has(k), `${k} törmää olemassa olevaan`);
  assert.ok(!keys.has('page.book.title') && !keys.has('seo.book.title'), 'staattinen varaa-sivu ei käytä kaupan page.book.*-avaimia');
});
test('luokat: ehdot/tietosuoja, euromäärät, kellonajat, peruutus/voimassaolo, osoite → protected; tavallinen markkinointiteksti normal', () => {
  const cls = new Map(PENDING.map((r) => [r.key, r.class]));
  for (const k of ['page.terms.hero.title', 'seo.privacy.title', 'page.terms.note', 'seo.companies.description', 'page.info.cancel_text', 'ui.card.corporate.vuoro.list.1', 'seo.info.description']) assert.equal(cls.get(k), 'protected', k);
  for (const k of ['page.front.hero.title', 'ui.site.today', 'nav.main.sauna', 'ui.alt.ovi_kaiverrus', 'ui.articles.read_more']) assert.equal(cls.get(k), 'normal', k);
  const n = new Set(PENDING.filter((r) => r.class === 'protected').map((r) => r.key)).size;
  assert.ok(n >= 30 && n < new Set(PENDING.map((r) => r.key)).size / 2, `protected ${n}`);
});
test('hinta- ja kestoviitteet: sidotut kohdat käyttävät {{price:ID}}/{{duration:ID}}; muut summat jäävät tekstiin (ei arvailua)', () => {
  const t = (k, l) => PENDING.find((r) => r.key === k && r.lang === l).text;
  assert.match(t('seo.companies.description', 'fi'), /alk\. \{\{price:48\}\}.*alk\. \{\{price:49\}\}/);
  assert.match(t('seo.companies.description', 'en'), /from \{\{price:48\}\}.*from \{\{price:49\}\}/);
  assert.equal(t('ui.card.corporate.vuoro.list.1', 'fi'), 'Ma–to klo 14–16 (2 h): {{price:48}}');
  assert.equal(t('ui.card.corporate.jalkiloylyt.list.1', 'en'), 'Mon–Thu 7–9 pm (2 h): {{price:49}}');
  assert.match(t('seo.treatments.description', 'fi'), /^Saunahoito \{\{duration:10\}\}, saunotus \{\{duration:11\}\} ja syväsaunotus \{\{duration:12\}\} /);
  assert.match(t('page.info.cancel_text', 'fi'), /^Yleisen vuoron voi perua maksutta vähintään \{\{setting:customer_change_hours_before\}\} tuntia ennen alkua\./);
  assert.match(t('page.info.cancel_text', 'en'), /free of charge at least \{\{setting:customer_change_hours_before\}\} hours before/);
  assert.deepEqual(PENDING.find((r) => r.key === 'page.info.cancel_text' && r.lang === 'fi').placeholders, ['{{setting:customer_change_hours_before}}']);
  assert.equal(FALLBACK.context.settings.customer_change_hours_before, 48);
  for (const k of ['faq.10', 'faq.23', 'policy.3', 'policy.18']) assert.ok(!PENDING.some((r) => r.key.startsWith(k + '.')), `${k} ei kuulu tuontiin`);
  for (const id of [10, 11, 12, 48, 49]) assert.ok(FALLBACK.context.catalog.some((p) => p.id === id), `katalogissa ${id}`);
  // {n}-muuttujat → {{var:n}}
  assert.equal(t('ui.reviews.stars', 'fi'), '{{var:n}} tähteä viidestä');
  assert.ok(PENDING.every((r) => !/\{[a-z_]+\}/.test(r.text.replace(/\{\{[^{}]*\}\}/g, ''))));
});
test('HTML: kantaan ei mene <strong> vaan **lihavointi** (kind lite); muunnos on molempiin suuntiin tarkka', () => {
  const lite = PENDING.filter((r) => r.text.includes('**'));
  assert.equal(lite.length, 6); assert.ok(lite.every((r) => r.kind === 'lite' && r.key.startsWith('page.info.')));
  assert.ok(PENDING.filter((r) => r.kind === 'lite').length === 6);
  assert.equal(CT.htmlToLite('<strong>Saavu</strong> ajoissa.'), '**Saavu** ajoissa.');
  assert.equal(CT.liteToHtml('**Saavu** <b>x</b> & ajoissa.'), '<strong>Saavu</strong> &lt;b&gt;x&lt;/b&gt; & ajoissa.');
  assert.equal(CT.liteToHtml(CT.htmlToLite('<strong>A</strong> b <strong>C</strong>')), '<strong>A</strong> b <strong>C</strong>');
});
test('peitto: kierros – tuontitiedosto peittona → kaikki oliot täsmälleen ennallaan; resetContentTexts palauttaa oletukset', async () => {
  const { state } = await stateWith(PENDING);
  const res = CT.applyContentTexts(state, { log: quiet });
  assert.equal(res.used, PENDING.length); assert.equal(res.fallback, PAGE_EXTRA.length); assert.equal(res.failed, 0);
  assert.equal(snap(), BASE, 'tuonnin jälkeen oliot poikkeavat oletuksista');
  const none = CT.applyContentTexts(await B.loadSiteTexts({ env: { SITE_TEXTS_FIXTURE: join(work, 'ei-ole.json') }, log: quiet, cacheDir: join(work, 'c2'), fallbackFile: join(work, 'ei-ole-varatekstia.json') }).catch(() => null), { log: quiet });
  assert.equal(none.used, 0); assert.equal(snap(), BASE);
});
test('peitto: DB-teksti vaihtaa tekstin (FI/EN erikseen), puuttuva kieli → oletus ei fi→en-ristiin, paikkamerkit täytetään, **lihavointi** → <strong>', async () => {
  const rows = [
    { key: 'ui.site.book', lang: 'fi', text: 'Varaa nyt' },
    { key: 'nav.main.sauna', lang: 'en', text: 'Sauna sessions!' },
    { key: 'ui.card.sauna.miehet.title', lang: 'fi', text: 'Vain suomeksi' },
    { key: 'ui.reviews.stars', lang: 'en', text: '{{var:n}} stars of five' },
    { key: 'page.info.sections.2.blocks.3.p', lang: 'fi', text: '**Tule ajoissa** & rauhassa <script>' },
    { key: 'seo.companies.description', lang: 'fi', text: 'Savusauna alk. {{price:48}} / {{price:49}}.' },
  ];
  const { state } = await stateWith(rows);
  try {
    const res = CT.applyContentTexts(state, { log: quiet });
    assert.equal(res.used, rows.length);
    assert.equal(site.ui.fi.book, 'Varaa nyt'); assert.equal(site.ui.en.book, 'Book');
    assert.equal(site.ui.en.nav[0][1], 'Sauna sessions!'); assert.equal(site.ui.fi.nav[0][1], 'Saunavuorot');
    assert.equal(CT.cards.sauna.miehet.fi.title, 'Vain suomeksi'); assert.notEqual(CT.cards.sauna.miehet.en.title, 'Vain suomeksi');
    assert.equal(site.ui.en.reviews.stars, '{n} stars of five');                           // {{var:n}} → {n}: sivupohja täyttää luvun
    assert.equal(CT.pageDoc('info').fi.sections[1].blocks[2].p, '<strong>Tule ajoissa</strong> & rauhassa &lt;script&gt;');
    assert.equal(CT.pageDoc('companies').fi.meta.description, 'Savusauna alk. 350 € / 250 €.');
  } finally { CT.resetContentTexts(); }
  assert.equal(snap(), BASE);
});
test('peitto: tuntematon paikkamerkki ei pääse sivulle (build kaatuu tai teksti ohitetaan, oletus säilyy)', async () => {
  const bad = join(work, 'bad.json');
  writeFileSync(bad, JSON.stringify({ ...FALLBACK, texts: [...FALLBACK.texts, { key: 'ui.site.book', lang: 'fi', text: 'Varaa {{price:9999}}', version: 1, placeholders: ['{{price:9999}}'] }] }));
  await assert.rejects(B.loadSiteTexts({ env: { SITE_TEXTS_FIXTURE: bad }, log: quiet, cacheDir: join(work, 'c3') }), /PAIKKAMERKKIVIRHE/);
});

// ---- koko build: HTML tavu tavulta sama ----
const files = (d, p = '') => readdirSync(join(d, p)).flatMap((n) => (statSync(join(d, p, n)).isDirectory() ? files(d, `${p}${n}/`) : [`${p}${n}`]));
function build(name, fixture) {
  const out = join(work, name);
  const r = spawnSync('node', [join(root, 'scripts/build.mjs')], { cwd: root, encoding: 'utf8', env: { ...process.env, DIST: out, SITE_URL: 'http://localhost:4180', ARTICLES_IMAGES: '0', ARTICLES_STATE_FILE: join(work, `state-${name}.json`), SITE_TEXTS_FIXTURE: fixture, SITE_TEXTS_CACHE_DIR: join(work, `cache-${name}`), BOOKING_SUPABASE_URL: '', BOOKING_ANON_KEY: '' } });
  assert.equal(r.status, 0, r.stderr + r.stdout);
  return { out, log: r.stdout };
}
test('build: tuontitiedosto "tietokannassa" → koko sivusto (kaikki HTML) tavu tavulta sama kuin ilman; muutettu teksti näkyy sivulla', async () => {
  const base = build('base', (await stateWith([])).file);
  assert.match(base.log, /staattiset sivut: 0 tekstiä tietokannasta, \d+ repon oletuksella/);
  const all = build('all', (await stateWith(PENDING)).file);
  assert.match(all.log, new RegExp(`staattiset sivut: ${PENDING.length} tekstiä tietokannasta, ${PAGE_EXTRA.length} repon oletuksella`));
  const fa = files(base.out), fb = files(all.out);
  assert.deepEqual(fb, fa); assert.ok(fa.length > 15);
  for (const f of fa) if (/\.(html|xml|txt|json)$/.test(f)) assert.equal(readFileSync(join(all.out, f), 'utf8'), readFileSync(join(base.out, f), 'utf8'), `${f} muuttui`);
  const chg = build('chg', (await stateWith([
    { key: 'page.front.hero.title', lang: 'fi', text: 'Uusi pääotsikko' }, { key: 'nav.main.gift', lang: 'en', text: 'Gift cards!' }, { key: 'ui.footer.contact', lang: 'fi', text: 'Löydät meidät' },
    { key: 'ui.site.directions', lang: 'en', text: 'How to find us' }, { key: 'seo.sauna.title', lang: 'fi', text: 'Uusi otsikko | Sipoonjoen Perinnesauna' }, { key: 'page.companies.hero.title', lang: 'fi', text: 'Yrityksille uusi otsikko' },
    { key: 'ui.articles.read_more', lang: 'fi', text: 'Jatka lukemaan' },
    { key: 'page.info.cancel_text', lang: 'en', text: 'Cancel free of charge {{setting:customer_change_hours_before}} hours ahead.' }])).file);
  const h = (d, f) => readFileSync(join(d, f), 'utf8');
  assert.match(h(chg.out, 'index.html'), /Uusi pääotsikko/); assert.doesNotMatch(h(base.out, 'index.html'), /Uusi pääotsikko/);
  assert.match(h(chg.out, 'index.html'), /Löydät meidät/);
  assert.match(h(chg.out, 'en/index.html'), />Gift cards!</); assert.match(h(chg.out, 'en/info/index.html'), /How to find us/);
  assert.match(h(chg.out, 'saunavuorot/index.html'), /<title>Uusi otsikko \| Sipoonjoen Perinnesauna<\/title>/);
  assert.match(h(chg.out, 'yritykset/index.html'), /Yrityksille uusi otsikko/);
  assert.doesNotMatch(h(base.out, 'yritykset/index.html'), /Yrityksille uusi otsikko/);
  assert.match(h(chg.out, 'en/info/index.html'), /Cancel free of charge 48 hours ahead\./);
});
test('kaupan datakuorma (booking/site-texts.json) sisältää vain kaupan avainalueet, ei staattisen sivuston tekstejä', async () => {
  const { state } = await stateWith(PENDING);
  const p = B.shopPayload(state);
  assert.ok(p.texts.length > 1300 && p.texts.every((r) => r.key.startsWith('ui.') && !B.SHOP_EXCLUDE.some((x) => r.key.startsWith(x))));
  assert.ok(!p.texts.some((r) => AREAS.test(r.key)));
  assert.ok(p.texts.some((r) => r.key === 'ui.shop.error_generic'));
  // kaikki kaupan alueet (tuotannon ui.*) tulevat mukaan: yksikään tuotannon kaupan avain ei jää pois
  const shopKeys = new Set(FALLBACK.texts.filter((r) => r.key.startsWith('ui.')).map((r) => r.key));
  assert.deepEqual([...shopKeys].filter((k) => !p.texts.some((r) => r.key === k)), []);
});

// ---- ui.shop.error_generic ----
test('kauppa: palvelimen raaka message ei enää asiakkaalle; yleinen virhe = ui.shop.error_generic (sama teksti kuin tuotannossa)', async () => {
  const { T } = await imp('booking/shop/src/i18n.js');
  const prod = new Map(FALLBACK.texts.map((r) => [`${r.key}|${r.lang}`, r.text]));
  for (const l of ['fi', 'en']) { assert.equal(T[l].errorGeneric, prod.get(`ui.shop.error_generic|${l}`)); assert.doesNotMatch(T[l].errorGeneric, /\d{3}/); }
  const R = await imp('booking/shop/src/text-registry.js');
  assert.ok(R.collectDefaults().some((r) => r.key === 'ui.shop.error_generic' && r.lang === 'fi'));
  for (const f of ['shop.js', 'order.js', 'mobilepay-ui.js', 'treatment-ui.js']) {
    const s = rd(`booking/shop/src/${f}`);
    assert.doesNotMatch(s, /\br\??\.message\b(?!\s*\|\|\s*\(?undefined)/, `${f}: r.message näytetään asiakkaalle`);
  }
  assert.match(rd('booking/shop/src/shop.js'), /e\.mapped \? e\.message : t\.errorGeneric/);
});
