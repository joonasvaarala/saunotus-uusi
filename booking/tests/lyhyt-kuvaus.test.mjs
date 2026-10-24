// booking_156: tuotteen lyhyt kuvaus. kb.products.short_description / short_description_en (rikas teksti, sama allowlist kuin kuvauksella).
// Kauppa: täytetty lyhyt kuvaus korvaa johdetun otteen tuotekortissa (shop.js + treatment-ui.js) ja yläbannerissa; tyhjä → nykyinen ote.
// EN: short_description_en || short_description. Rikas HTML vain rich-view.js:n puhdistuksen kautta. Lisäksi korjaus: tuntemattoman tuotteen
// varasivu näyttää kuvauksen puhdistettuna (ennen raakana tekstinä). Ei verkkoa eikä tietokantaa.
// SQL-käytös: booking/supabase/tests/t156_product_short_description.sql (paikallinen PG17: rajoite, RPC:t, public_catalog, tekstit, rollback-md5).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, cpSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const MIG = 'booking/supabase/migrations/20261024280000_booking_156_product_short_description.sql';
const RB = 'booking/supabase/rollbacks/20261024280000_booking_156_ROLLBACK.sql';
const T156 = 'booking/supabase/tests/t156_product_short_description.sql';
const P56 = 'content/site-texts.pending-import-56.json';

const S = await import(pathToFileURL(join(root, 'shop/src/short-desc.js')).href);
const { sanitizeRich, isRichHtml } = await import(pathToFileURL(join(root, 'shop/src/rich-text.js')).href);
const { visibleText } = await import(pathToFileURL(join(root, 'shop/src/rich-view.js')).href);
// treatments.js tuo ./sb.js:n (kopioidaan buildissa booking/shared:sta) → väliaikainen kopio kuten kesto-en.test.mjs
const tmp = join(mkdtempSync(join(tmpdir(), 'lyhyt-kuvaus-')), 'shop');
cpSync(join(root, 'shop/src'), tmp, { recursive: true });
cpSync(join(root, 'shared/sb.js'), join(tmp, 'sb.js'));
const { splitCatalog } = await import(pathToFileURL(join(tmp, 'treatments.js')));

// kevyt h(): riittää richHostille (tag, class, text, innerHTML)
const h = (tag, attrs = {}) => ({ tag, cls: attrs.class ?? null, text: attrs.text, innerHTML: undefined });
// vanha (ennen booking_156) kortin ote ja yläbannerin ote, verrokiksi
const oldExcerpt = (raw) => { const plain = isRichHtml(raw) ? visibleText(raw).replace(/\s+/g, ' ').trim() : raw; return plain.slice(0, 170) + (plain.length > 170 ? '…' : ''); };

const LONG = 'Savusauna lämpiää koko päivän. Tule nauttimaan pehmeistä löylyistä järven rannalla, uinnista ja rauhasta. ' + 'Lisää tekstiä '.repeat(20);
const RICH_DESC = '<p>Savusauna lämpiää <strong>koko päivän</strong>. Tule nauttimaan löylyistä.</p><ul><li>uinti</li></ul>';

test('shortRaw: FI, EN → _en || fi, tyhjä editori ja välilyönnit = tyhjä', () => {
  assert.equal(S.shortRaw({ short_description: ' <p>Lyhyt</p> ' }, 'fi'), '<p>Lyhyt</p>');
  assert.equal(S.shortRaw({ short_description: 'Lyhyt', short_description_en: 'Short' }, 'en'), 'Short');
  assert.equal(S.shortRaw({ short_description: 'Lyhyt', short_description_en: 'Short' }, 'fi'), 'Lyhyt');
  assert.equal(S.shortRaw({ short_description: 'Lyhyt', short_description_en: null }, 'en'), 'Lyhyt', 'EN puuttuu → FI');
  assert.equal(S.shortRaw({ short_description: 'Lyhyt', short_description_en: '<p><br></p>' }, 'en'), 'Lyhyt', 'tyhjä EN-editori → FI');
  assert.equal(S.shortRaw({ short_description: '<p><br></p>' }, 'fi'), '');
  assert.equal(S.shortRaw({ short_description: '   ' }, 'fi'), '');
  assert.equal(S.shortRaw({}, 'en'), '');
  assert.equal(S.shortRaw(null, 'fi'), '');
});

test('kortti: tyhjä lyhyt kuvaus → sama ote kuin ennen (170 merkkiä), myös rikkaasta kuvauksesta', () => {
  for (const desc of [LONG, RICH_DESC, 'Lyhyt kuvaus.', '']) {
    const el = S.cardShort(h, { description: desc }, 'fi', desc);
    assert.equal(el.tag, 'p'); assert.equal(el.cls, 'bk-desc');
    assert.equal(el.text, oldExcerpt(desc));
  }
  assert.equal(S.cardShort(h, { description: LONG }, 'fi', LONG).text.length, 171);
  assert.equal(S.cardShort(h, {}, 'fi', RICH_DESC).text, 'Savusauna lämpiää koko päivän. Tule nauttimaan löylyistä. uinti');
});

test('kortti: lyhyt kuvaus kokonaan; rikas puhdistettuna (rich-view.js), pelkkä teksti tekstinä', () => {
  const rich = '<p>Lyhyt <strong>kuvaus</strong><script>alert(1)</script><img src=x onerror=alert(1)> <a href="javascript:alert(1)">x</a></p>';
  const el = S.cardShort(h, { short_description: rich, description: LONG }, 'fi', LONG);
  assert.equal(el.tag, 'div'); assert.equal(el.cls, 'bk-desc bk-rich');
  assert.equal(el.innerHTML, sanitizeRich(rich));
  assert.doesNotMatch(el.innerHTML, /script|onerror|<img|javascript:/i);
  assert.match(el.innerHTML, /<strong>kuvaus<\/strong>/);
  const plain = S.cardShort(h, { short_description: 'Pelkkä <3 teksti', description: LONG }, 'fi', LONG);
  assert.equal(plain.tag, 'p'); assert.equal(plain.text, 'Pelkkä <3 teksti'); assert.equal(plain.innerHTML, undefined);
  const long = 'x'.repeat(400);
  assert.equal(S.cardShort(h, { short_description: long }, 'fi', LONG).text, long, 'lyhyttä kuvausta ei leikata');
  assert.equal(S.cardShort(h, { short_description: 'Lyhyt', short_description_en: 'Short' }, 'en', LONG).text, 'Short');
  assert.equal(S.cardShort(h, { short_description: 'Lyhyt' }, 'en', LONG).text, 'Lyhyt');
});

test('yläbanneri: tyhjä → ensimmäinen virke kuten ennen; rikas → puhdistettu solmu; teksti → teksti', () => {
  assert.deepEqual(S.heroShort(h, { description: LONG }, 'fi', LONG), { node: null, text: 'Savusauna lämpiää koko päivän.' });
  assert.deepEqual(S.heroShort(h, {}, 'fi', 'Avoinna klo 16.30 alkaen. Tervetuloa saunomaan.'), { node: null, text: 'Avoinna klo 16.30 alkaen.' });
  assert.equal(S.heroShort(h, {}, 'fi', 'a'.repeat(200)).text, `${'a'.repeat(130)}…`);
  assert.deepEqual(S.heroShort(h, { short_description: 'Oma lyhyt teksti' }, 'fi', LONG), { node: null, text: 'Oma lyhyt teksti' });
  const r = S.heroShort(h, { short_description: '<p>Oma <em>lyhyt</em></p><p onclick="x()">kaksi</p>', short_description_en: '<p>Own <em>short</em></p>' }, 'en', LONG);
  assert.equal(r.text, ''); assert.equal(r.node.tag, 'div'); assert.equal(r.node.cls, 'bk-hero-short bk-rich');
  assert.equal(r.node.innerHTML, '<p>Own <em>short</em></p>');
  const fi = S.heroShort(h, { short_description: '<p>Oma <em>lyhyt</em></p><p onclick="x()">kaksi</p>' }, 'fi', LONG);
  assert.doesNotMatch(fi.node.innerHTML, /onclick/);
});

test('tuntemattoman tuotteen varasivu: kuvaus puhdistettuna (ei raakaa HTML:ää tekstinä), EN → description_en || description', () => {
  const st = { name: 'X', description: '<p>Kuvaus <strong>tässä</strong></p><script>alert(1)</script>', description_en: '<p>Description</p>' };
  const fi = S.fallbackDesc(h, st, 'fi');
  assert.equal(fi.tag, 'div'); assert.equal(fi.innerHTML, '<p>Kuvaus <strong>tässä</strong></p>');
  assert.equal(S.fallbackDesc(h, st, 'en').innerHTML, '<p>Description</p>');
  assert.equal(S.fallbackDesc(h, { description: 'Pelkkä teksti' }, 'en').text, 'Pelkkä teksti');
  assert.equal(S.fallbackDesc(h, { description: 'FI', description_en: '<p><br></p>' }, 'en').text, 'FI');
  assert.equal(S.fallbackDesc(h, {}, 'fi').text, '');
  const shop = read('booking/shop/src/shop.js');
  assert.doesNotMatch(shop, /text:\s*st\.description/, 'varasivu ei enää näytä kuvausta raakana tekstinä');
  assert.match(shop, /st \? fallbackDesc\(h, st, S\.lang\) : null/);
});

test('kauppa käyttää short-desc.js:ää: kortit (shop.js + treatment-ui.js) ja yläbanneri; splitCatalog välittää kentät', () => {
  const shop = read('booking/shop/src/shop.js'), tui = read('booking/shop/src/treatment-ui.js');
  assert.match(shop, /import \{ heroShort, cardShort, fallbackDesc \} from '\.\/short-desc\.js';/);
  assert.match(shop, /const cardExcerpt = \(p\) => cardShort\(h, p, S\.lang, pdesc\(p\)\);/);
  assert.match(shop, /heroShort\(h, p, S\.lang, pdesc\(p\)\)/);
  assert.match(shop, /el\.querySelector\('\.bk-hero-short'\)\?\.remove\(\);/, 'edellisen tuotteen lyhyt kuvaus poistetaan');
  assert.doesNotMatch(shop, /text: cardExcerpt\(p\)/);
  assert.match(tui, /cardShort\(h, p, S\.lang, pdesc\(p\)\)/);
  assert.doesNotMatch(tui, /plain\.slice\(0, 170\)/, 'treatment-ui ei enää johda otetta itse');
  assert.match(read('booking/shop/src/shop.css'), /\.hero\.page \.bk-hero-short\{/);
  assert.doesNotMatch(read('booking/shop/src/short-desc.js'), /innerHTML/, 'HTML vain richHostin kautta');
  const { treatments } = splitCatalog([{ id: 1, booking_kind: 'slots', name: 'A', short_description: '<p>L</p>', short_description_en: 'S' }, { id: 2, booking_kind: 'slots', name: 'B', short_description: null }], new Map([[2, { short_description: 'staattinen' }]]));
  assert.equal(treatments.find((t) => t.id === 1).short_description, '<p>L</p>');
  assert.equal(treatments.find((t) => t.id === 1).short_description_en, 'S');
  assert.equal(treatments.find((t) => t.id === 2).short_description, 'staattinen', 'katalogin null → static-products.json');
});

test('static-products.json ja kb.json: short_description(_en) mukana', () => {
  const b = read('booking/shop/build.mjs');
  const keys = JSON.parse(b.match(/const STATIC_KEYS = (\[[^\]]+\])/)[1].replace(/'/g, '"'));
  for (const k of ['short_description', 'short_description_en', 'description', 'description_en']) assert.ok(keys.includes(k), k);
  assert.match(b, /'short-desc\.js'/);
  const snap = read('scripts/kb-snapshot.mjs').match(/products: raw\.products[^\n]+/)[0];
  for (const k of ['short_description', 'short_description_en', 'description_en']) assert.match(snap, new RegExp(`'${k}'`));
  assert.match(read('docs/kb-export.sql'), /to_jsonb\(p\)[^\n]*kb\.products/, 'vienti ottaa kaikki sarakkeet');
});

test('hallinta: Quill-kentät FI+EN muokkaus- ja luontilomakkeessa, tallennus lähettää kentät; rich-editor.js ennallaan', () => {
  const v = read('booking/admin/views/products.js');
  for (const k of ['short_description', 'short_description_en']) {
    assert.equal((v.match(new RegExp(`inp\\('${k}', [^)]*'data-rich': '1'`, 'g')) || []).length, 2, `${k}: 2 rikasta kenttää`);
    assert.equal((v.match(new RegExp(`${k}: fd\\.get\\('${k}'\\)`, 'g')) || []).length, 2, `${k}: patch + luonti`);
  }
  assert.match(read('booking/admin/options-mock.js'), /'description_en', 'short_description', 'short_description_en', 'price'/);
});

test('tekstit pending-import-56: FI+EN, ei <, täsmää sanakirjaan, ei päällekkäin muiden tuontien kanssa', async () => {
  const rows = JSON.parse(read(P56));
  const { PRODUCT_TEXTS } = await import(pathToFileURL(join(root, 'admin/product-texts.js')).href);
  const keys = [...new Set(rows.map((r) => r.key))].sort();
  assert.deepEqual(keys, ['ui.admin.product.short_en', 'ui.admin.product.short_fi', 'ui.admin.product.short_hint']);
  for (const r of rows) {
    assert.ok(r.lang === 'fi' || r.lang === 'en');
    assert.doesNotMatch(r.text, /</);
    assert.ok(r.text.length <= r.max_len);
    assert.equal(r.text, PRODUCT_TEXTS[r.lang][r.key]);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain'); assert.deepEqual(r.placeholders, []);
  }
  assert.equal(rows.length, keys.length * 2);
  const others = readdirSync(join(repo, 'content')).filter((f) => /^site-texts\.pending-import-\d+\.json$/.test(f) && f !== 'site-texts.pending-import-56.json');
  for (const f of others) for (const r of JSON.parse(read(`content/${f}`))) assert.ok(!keys.includes(r.key), `${r.key} myös tiedostossa ${f}`);
  assert.doesNotMatch(JSON.stringify(rows), /#[0-9a-f]{3,6}\b|blue|sininen/i);
});

test('migraatio + rollback + SQL-testi: rakenne, ei public-skeemaa, md5-listat yhtenevät', () => {
  assert.deepEqual(readdirSync(join(repo, 'booking/supabase/migrations')).filter((n) => /booking_156_/.test(n)), ['20261024280000_booking_156_product_short_description.sql']);
  const sql = read(MIG), rb = read(RB), t = read(T156);
  for (const s of [sql, rb]) assert.doesNotMatch(s.replace(/--[^\n]*/g, ''), /\bpublic\./i, 'ei public-skeemaa');
  assert.match(sql, /add column if not exists short_description text/);
  assert.match(sql, /add column if not exists short_description_en text/);
  assert.match(sql, /drop constraint if exists kb_products_short_description_rich_check/);
  assert.match(sql, /booking\._rich_text_check\(/);
  assert.match(sql, /p_field = 'short_description' then v_kind := 'rich'; v_max := 1000;/);
  assert.match(rb, /drop column if exists short_description_en/);
  assert.match(rb, /drop function if exists booking\._short_description_check\(text\)/);
  // rollbackin md5:t (tuotannon pg_get_functiondef ennen booking_156:ta) = SQL-testin H1-odotus
  const PROD = { _texts_reg: '957899c59fa87e65994a9ffacb59ab8f', _texts_register_sources: '288af591eefb49d9ad48a7958c44ef14', admin_list_products: 'a78891b910ae65a7ea7583979ede71d4', admin_product_create: '0516c7f53b7eae66b04522382ed1c1fb', admin_update_product: '3cca4125054a32111235a25a5b8402de', public_catalog: 'a55b3a8bf0d3e8820f83b139b58f6057' };
  for (const [fn, md5] of Object.entries(PROD)) { assert.match(rb, new RegExp(`${fn}\\W[^\\n]*${md5}`), `rollback: ${fn}`); assert.match(t, new RegExp(`"${fn}":"${md5}"`), `t156: ${fn}`); }
  assert.match(t, /\\ir \.\.\/rollbacks\/20261024280000_booking_156_ROLLBACK\.sql/);
  assert.match(t, /\\ir \.\.\/migrations\/20261024280000_booking_156_product_short_description\.sql/);
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/lyhyt-kuvaus\.test\.mjs/);
});
