// HALL-TUOTTEET-01: tuote-editorin logiikka (diff, tallennussuunnitelma, hintatekstin automatiikka, osittainen epäonnistuminen),
// poistumisvahti, mock-RPC:t ja lähdekooditarkistukset. Ei verkkoa eikä tietokantaa.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const href = (rel) => new URL(rel, import.meta.url);
const read = (rel) => readFileSync(href(rel), 'utf8');
const L = await import(href('../admin/product-editor-logic.js'));

const product = (over = {}) => ({
  id: 7, name: 'Pyyhevuokra', name_en: 'Towel rental', description: '<p>Kuvaus</p>', description_en: '', short_description: '', short_description_en: '',
  price: 5, price_text: '5,00 €', vat_rate: 25.5, active: true, category: 'product_rental',
  config: { bookable: true, shop_visible: true, audience: 'consumer', sort_order: 10, min_persons: 1, max_persons: null, pos_enabled: false, pos_sort: 100, fridge_sale: false, age_restricted: false, image_path: null, image_alt: null },
  variants: [{ id: 11, label: 'Talvi', price: 5 }, { id: 12, label: 'Kesä', price: 4 }],
  ...over,
});
const labels = { product: 'Perustiedot ja hinta', training: 'Koulutus', config: 'Myynti ja näkyvyys', image: 'Kuva', suggestions: 'Lisämyynti', variant: (id) => `Variantti ${id}` };
const clone = (o) => JSON.parse(JSON.stringify(o));
const plan = (base, cur, training = false) => L.buildSavePlan({ productId: 7, training, base, cur, labels });

test('hintateksti: automaattinen muoto vastaa palvelinta, käsin kirjoitettu tunnistetaan', () => {
  assert.equal(L.autoPriceText(3.5), '3,50 €');
  assert.equal(L.autoPriceText('49'), '49,00 €');
  assert.equal(L.autoPriceText(''), '');
  assert.equal(L.autoPriceText(-1), '');
  assert.equal(L.priceTextIsAuto('', 5), true);
  assert.equal(L.priceTextIsAuto('5,00 €', 5), true);
  assert.equal(L.priceTextIsAuto('5,00 €', 6), false);   // hinta vaihtui, teksti ei: ei enää "hinnasta johdettu"
  assert.equal(L.priceTextIsAuto('alk. 5 € / hlö', 5), false);
  assert.equal(L.numOrNull('3,5'), 3.5);
  assert.equal(L.numOrNull(' '), null);
  assert.ok(Number.isNaN(L.numOrNull('abc')));
});

test('muokkaamaton lomake ei ole muuttunut; hinta ja näkyvyys ovat yksi tallennus', () => {
  const p = product();
  const base = L.baselineFromProduct(p);
  assert.equal(L.isDirty(L.diffSnapshots(base, clone(base))), false);
  assert.deepEqual(plan(base, clone(base)), []);

  const cur = clone(base);
  cur.product.price = 6;
  cur.product.price_text = '6,00 €';   // näkymä päivittää tekstin, kun se on automaattinen
  cur.config.shop_visible = false;
  cur.variants[11] = 7;
  const d = L.diffSnapshots(base, cur);
  assert.equal(L.isDirty(d), true);
  assert.deepEqual(L.dirtyTabs(d), ['hinnat', 'myynti']);
  const steps = plan(base, cur);
  assert.deepEqual(steps.map((s) => s.key), ['product', 'config', 'variant:11']);
  assert.deepEqual(steps[0].calls[0], { fn: 'admin_update_product', args: { p_product_id: 7, p_patch: { price: 6, price_text: '6,00 €' } } });
  assert.deepEqual(steps[1].calls[0].args.p_patch, { shop_visible: false });   // vain muuttunut kenttä
  assert.deepEqual(steps[2].calls[0], { fn: 'admin_update_price_variant', args: { p_variant_id: 11, p_patch: { price: 7 } } });
});

test('tyhjennetty hintateksti täytetään hinnasta samoin kuin luonnissa; muut kentät ennallaan', () => {
  const base = L.baselineFromProduct(product({ price_text: 'alk. 5 € / hlö' }));
  const cur = clone(base);
  cur.product.price_text = '';
  cur.product.price = 8;
  assert.equal(plan(base, cur)[0].calls[0].args.p_patch.price_text, '8,00 €');
  const cur2 = clone(base);
  cur2.product.name_en = 'Towels';
  assert.deepEqual(plan(base, cur2)[0].calls[0].args.p_patch, { name_en: 'Towels' });
  assert.deepEqual(L.dirtyTabs(L.diffSnapshots(base, cur2)), ['perustiedot']);
});

test('koulutus: hinta päivittää myös varausmaksun, lisävalinnat lähtevät omana kutsunaan', () => {
  const p = product({ category: 'training', price: 390, config: { ...product().config, deposit_amount: 100, course_price: 390 } });
  const base = L.baselineFromProduct(p, { offers: [{ code: 'single_room', price: 200, active: true }] });
  assert.equal(base.product.price, 100);   // lomake näyttää varausmaksun (kuten ennen)
  assert.equal(base.training.addon_single, true);
  const cur = clone(base);
  cur.product.price = 120;
  cur.training.course_price = 400;
  cur.training.addon_intern = true;
  const steps = plan(base, cur, true);
  assert.deepEqual(steps.map((s) => s.key), ['product', 'training']);
  assert.deepEqual(steps[1].calls.map((c) => c.fn), ['admin_update_product_config', 'admin_training_addons_set']);
  assert.deepEqual(steps[1].calls[0].args.p_patch, { deposit_amount: 120, course_price: 400 });
  assert.deepEqual(steps[1].calls[1].args.p_offers, [{ code: 'single_room', price: 200, active: true }, { code: 'internship', price: 500, active: true }]);
});

test('alkoholituote: kylmämyynti suljetaan kannasta, kun asetuksia tallennetaan (kuten ennen)', () => {
  const p = product({ config: { ...product().config, fridge_sale: true } });
  const base = L.baselineFromProduct(p, { alcohol: true });
  assert.equal(base.config.fridge_sale, false);   // lomake näyttää sen pois päältä
  assert.equal(L.isDirty(L.diffSnapshots(base, clone(base))), false);
  const cur = clone(base); cur.config.sort_order = 20;
  assert.deepEqual(plan(base, cur)[0].calls[0].args.p_patch, { sort_order: 20, fridge_sale: false });
});

test('tarkistus: tyhjä nimi, virheellinen hinta ja luvut estävät tallennuksen', () => {
  const base = L.baselineFromProduct(product());
  assert.deepEqual(L.validateSnapshot(clone(base)), []);
  const cur = clone(base);
  cur.product.name = '  '; cur.product.price = NaN; cur.config.min_persons = null; cur.variants[12] = -1;
  const errs = L.validateSnapshot(cur, base);
  assert.deepEqual(errs.map((e) => e.field).sort(), ['min_persons', 'name', 'price', 'variant:12']);
  assert.equal(errs.find((e) => e.field === 'name').tab, 'perustiedot');
  // puuttuva (null) luku ei ole virhe, jos sitä ei ollut ennenkään (vanha product_config-rivi)
  const sparse = clone(base); sparse.config.min_persons = null;
  assert.deepEqual(L.validateSnapshot(clone(sparse), sparse), []);
});

test('tallennus: yksi virhe ei estä muita; tulosviesti kertoo epäonnistuneen osan; onnistuneet kuitataan', async () => {
  const base = L.baselineFromProduct(product());
  const cur = clone(base);
  cur.product.name = 'Uusi nimi'; cur.config.shop_visible = false; cur.variants[11] = 9;
  const steps = plan(base, cur);
  const seen = [];
  const res = await L.runPlan(steps, async (s) => { seen.push(s.key); if (s.key === 'config') throw Object.assign(new Error('Ei oikeutta'), { code: 'forbidden' }); });
  assert.deepEqual(seen, ['product', 'config', 'variant:11']);
  assert.deepEqual(res.done, ['product', 'variant:11']);
  assert.equal(res.failed[0].key, 'config');
  const T = (k) => ({ saved_all: 'Kaikki tallennettu', saved_part: 'Osa tallentui ({{var:count}}). Ei tallentunut: {{var:failed}}', saved_none: 'Ei tallentunut. {{var:failed}}' })[k];
  const sum = L.saveSummary(res, T, (e) => e.message);
  assert.equal(sum.kind, 'warn');
  assert.equal(sum.text, 'Osa tallentui (2). Ei tallentunut: Myynti ja näkyvyys: Ei oikeutta');
  assert.equal(L.saveSummary({ done: ['a'], failed: [] }, T).kind, 'ok');
  assert.equal(L.saveSummary({ done: [], failed: res.failed }, T, (e) => e.message).kind, 'err');
  // uusi lähtökuva: onnistuneet osat ovat tallessa, epäonnistunut jää muutokseksi
  const next = L.rebase(base, cur, res.done);
  const d = L.diffSnapshots(next, cur);
  assert.deepEqual(d.product, []);
  assert.deepEqual(d.variants, []);
  assert.deepEqual(d.config, ['shop_visible']);
});

test('kuva ja lisämyynti ovat omia askeleitaan; alt-teksti ilman kuvaa ei ole muutos', () => {
  const base = L.baselineFromProduct(product());
  base.suggestions = '[]';
  const cur = clone(base);
  cur.image.alt = 'Pyyhe';
  assert.equal(L.diffSnapshots(base, cur).image, false);
  cur.image.file = true;
  cur.suggestions = '[[1,null,true]]';
  const steps = plan(base, cur);
  assert.deepEqual(steps.map((s) => [s.key, !!s.custom]), [['image', true], ['suggestions', true]]);
  assert.deepEqual(L.dirtyTabs(L.diffSnapshots(base, cur)), ['kuva', 'lisamyynti']);
  assert.equal(L.imageAction({ alt: '', file: false, remove: true }, base.image), 'remove');
  assert.equal(L.imageAction({ alt: '', file: true, remove: false }, base.image), 'replace');
  assert.equal(L.imageAction({ alt: 'x', file: false, remove: false }, { alt: '', hasImage: true }), 'alt');
});

test('osoite: #/tuotteet/<id>', () => {
  assert.equal(L.productIdFromRest('12'), 12);
  assert.equal(L.productIdFromRest(''), null);
  assert.equal(L.productIdFromRest('12/x'), null);
  assert.equal(L.productHash(12, 'haku=pyyhe'), '#/tuotteet/12?haku=pyyhe');
  assert.equal(L.productHash(null, ''), '#/tuotteet');
});

test('poistumisvahti: ilman muutoksia saa poistua, muutosten kanssa kysytään', async () => {
  const ui = await import(href('../admin/ui.js'));
  assert.equal(await ui.leaveAllowed('#/asiakkaat'), true);
  let asked = 0, answer = false, dirty = true;
  ui.setLeaveGuard({ dirty: () => dirty, ask: async (next) => { asked += 1; assert.equal(next, '#/asiakkaat'); return answer; } });
  assert.equal(await ui.leaveAllowed('#/asiakkaat'), false);
  answer = true;
  assert.equal(await ui.leaveAllowed('#/asiakkaat'), true);
  dirty = false;
  assert.equal(await ui.leaveAllowed('#/asiakkaat'), true);
  assert.equal(asked, 2);
  ui.setLeaveGuard(null);
});

test('mock: admin_update_product, hintavariantti ja kuva toimivat, virheet palautuvat', async () => {
  const { createAdminMock } = await import(href('../admin/options-mock.js'));
  const mock = createAdminMock({ role: 'manager', delay: 0 });
  await mock.rpc('admin_update_product', { p_product_id: 3, p_patch: { price: 19, active: false } });
  const p = (await mock.rpc('admin_list_products')).find((x) => x.id === 3);
  assert.equal(p.price, 19);
  assert.equal(p.active, false);
  await assert.rejects(() => mock.rpc('admin_update_product', { p_product_id: 3, p_patch: { slug: 'x' } }), (e) => e.code === 'unknown_field');
  await assert.rejects(() => mock.rpc('admin_update_product', { p_product_id: 3, p_patch: { name: ' ' } }), (e) => e.code === 'invalid_name');
  await mock.rpc('admin_update_price_variant', { p_variant_id: 901, p_patch: { price: 20 } });
  assert.equal((await mock.rpc('admin_list_products')).find((x) => x.id === 3).variants[0].price, 20);
  const r = await mock.rpc('admin_set_product_image', { p_product_id: 3, p_image_path: 'products/x.webp', p_image_alt: 'Alt' });
  assert.equal(r.previous_path, null);
  const staff = createAdminMock({ role: 'staff', perms: ['bookings.manage'] });
  await assert.rejects(() => staff.rpc('admin_update_product', { p_product_id: 3, p_patch: { price: 1 } }), (e) => e.code === 'forbidden');
});

test('lähde: editori käyttää yhteisiä komponentteja, vahtia ja yhtä tallennuspalkkia; reititys ja build-lista ajan tasalla', () => {
  const ed = read('../admin/views/product-editor.js');
  const prod = read('../admin/views/products.js');
  assert.match(ed, /tabs\(\{/);
  assert.match(ed, /setLeaveGuard\(guard\)/);
  assert.match(ed, /data-testid': 'product-save-all'/);
  assert.match(ed, /buildSavePlan\(/);
  assert.match(ed, /runPlan\(/);
  assert.equal((ed.match(/location\.reload|\.close\(\)/g) || []).length, 0, 'tallennus ei sulje eikä lataa näkymää uudelleen');
  assert.doesNotMatch(ed, /Tallenna tuote|Tallenna asetukset|Tallenna kuva/);
  assert.match(prod, /productIdFromRest\(rest\)/);
  assert.match(prod, /q0\.get\('muokkaa'\)/);   // vanha osoite ohjataan uuteen
  assert.doesNotMatch(prod, /edit\(/);
  const admin = read('../admin/admin.js');
  assert.match(admin, /leaveAllowed\(location\.hash\)/);
  const build = read('../../scripts/build-pages.mjs');
  for (const f of ['views/product-editor.js', 'product-editor-logic.js']) assert.ok(build.includes(`'${f}'`), f);
  const pages = read('../../.github/workflows/pages.yml');
  assert.match(pages, /tuote-editori-hall-tuotteet-01\.test\.mjs/);
});

test('tekstit: pending-import-165 FI+EN, sama sanakirjan kanssa, ei hintoja eikä <-merkkejä', async () => {
  const { PRODUCT_TEXTS } = await import(href('../admin/product-texts.js'));
  const rows = JSON.parse(read('../../content/site-texts.pending-import-165.json'));
  assert.deepEqual(Object.keys(PRODUCT_TEXTS.fi).sort(), Object.keys(PRODUCT_TEXTS.en).sort());
  for (const r of rows) {
    assert.equal(r.text, PRODUCT_TEXTS[r.lang][r.key], r.key);
    assert.doesNotMatch(r.text, /[<>]|\p{Extended_Pictographic}/u, r.key);
    assert.doesNotMatch(r.text, /\d|€/, r.key);
  }
  const fi = new Set(rows.filter((r) => r.lang === 'fi').map((r) => r.key));
  const en = new Set(rows.filter((r) => r.lang === 'en').map((r) => r.key));
  assert.deepEqual([...fi].sort(), [...en].sort());
  assert.equal(rows.length, fi.size * 2);
});
