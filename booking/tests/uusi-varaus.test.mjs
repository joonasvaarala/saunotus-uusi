// Uusi varaus -lomakkeen ja stepperin testit (node --test): stepperin arvon rajat, +/−, kenttäsyöte ja summa; laskun viite vain yritykselle;
// lisäpalvelun kuvauksen siivous; tekstien FI/EN-täsmäävyys. DOM-käyttäytyminen (napit, aria, tallennus) ajetaan scripts/e2e-uusi-varaus.mjs:ssä.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const imp = (p) => import(pathToFileURL(join(root, p)));
const { parseQty, clampQty, nextQty } = await imp('admin/stepper.js');
const L = await imp('admin/nb-logic.js');
const { NB, descRedundant, cleanDesc, nbt } = await imp('admin/nb-texts.js');
const { addonLimit } = L;

test('Stepper: parseQty – numerot, tyhjä, roskat, desimaalit, negatiiviset', () => {
  assert.equal(parseQty('3'), 3); assert.equal(parseQty(' 07 '), 7); assert.equal(parseQty(''), 0); assert.equal(parseQty('abc'), 0);
  assert.equal(parseQty('2,7'), 2); assert.equal(parseQty('2.9'), 2); assert.equal(parseQty('-4'), -4); assert.equal(parseQty('', 1), 1); assert.equal(parseQty(null), 0);
});
test('Stepper: clampQty – kokonaisluku 0..max', () => {
  assert.equal(clampQty(5, 0, 3), 3); assert.equal(clampQty(-2, 0, 3), 0); assert.equal(clampQty('2', 0, 3), 2); assert.equal(clampQty('x', 0, 3), 0);
  assert.equal(clampQty(2.8, 0, 3), 2); assert.equal(clampQty(0, 1, 5), 1);   // min 1 (henkilömäärä)
  assert.equal(clampQty(4, 0, 0), 0);                                          // max 0 → aina 0
  assert.equal(clampQty(4, 2, 1), 2);                                          // max < min → min
  assert.equal(clampQty(500), 99);                                             // oletusmax 99
});
test('Stepper: nextQty – plus/miinus rajojen sisällä', () => {
  assert.equal(nextQty(0, 1, 0, 3), 1); assert.equal(nextQty(3, 1, 0, 3), 3); assert.equal(nextQty(0, -1, 0, 3), 0); assert.equal(nextQty(2, -1, 0, 3), 1);
  assert.equal(nextQty(1, -1, 1, 8), 1); assert.equal(nextQty('', 1, 0, 3), 1); assert.equal(nextQty(9, -1, 0, 3), 2);   // yli maksimin → ensin rajaus, sitten askel
  let v = 0; for (let i = 0; i < 10; i++) v = nextQty(v, 1, 0, 4); assert.equal(v, 4);
  for (let i = 0; i < 10; i++) v = nextQty(v, -1, 0, 4); assert.equal(v, 0);
});
test('Lisäpalvelun enimmäismäärä = henkilömäärä × max/hlö, enintään 99; summa = määrä × hinta', () => {
  const towel = { max_per_person: 1, price: 5 };
  assert.equal(addonLimit(towel, 3), 3); assert.equal(addonLimit(towel, 0), 0); assert.equal(addonLimit({ max_per_person: 20 }, 16), 99); assert.equal(addonLimit({}, 2), 99);
  const qty = clampQty(7, 0, addonLimit(towel, 3));
  assert.equal(qty * towel.price, 15);
});

test('Hinta: vuoro (per henkilö / kiinteä / perus + lisähenkilöt) ja oma hinta', () => {
  const pp = { price_mode: 'per_person', unit_price: 18 }, fx = { price_mode: 'fixed', base_price: 120 }, bp = { price_mode: 'base_plus_extra', base_price: 150, included_persons: 6, extra_person_price: 15 };
  assert.equal(L.priceFor(pp, 3), 54); assert.equal(L.priceFor(fx, 9), 120); assert.equal(L.priceFor(bp, 4), 150); assert.equal(L.priceFor(bp, 8), 180);
  assert.deepEqual(L.parsePrice(''), { ok: true, value: null }); assert.deepEqual(L.parsePrice('40,5'), { ok: true, value: 40.5 }); assert.deepEqual(L.parsePrice('0'), { ok: true, value: 0 });
  for (const bad of ['x', '-1', '1.234', '1,2,3', '€5']) assert.equal(L.parsePrice(bad).ok, false, bad);
});
test('Yhteenveto: vuoro + lisäpalvelut = yhteensä; oma hinta korvaa vuoron hinnan; vuosikortti 0', () => {
  const s = { price_mode: 'per_person', unit_price: 18 };
  assert.deepEqual(L.summary({ session: s, persons: 2, addons: 10 }), { slot: 36, addons: 10, total: 46, overridden: false });
  assert.deepEqual(L.summary({ session: s, persons: 2, addons: 10, override: { ok: true, value: 30 } }), { slot: 30, addons: 10, total: 40, overridden: true });
  assert.equal(L.summary({ session: s, persons: 2, addons: 10, override: { ok: false, value: null } }).total, 46);
  assert.equal(L.summary({ session: s, persons: 2, addons: 10, annualCard: true }).total, 0);
  assert.equal(L.summary({ session: s, persons: 1, addons: 0.1 + 0.2 }).total, 18.3);
});
test('Henkilömäärän rajat: min_persons .. min(max_persons, vapaat)', () => {
  assert.deepEqual(L.personsRange({ min_persons: 1, max_persons: 16, remaining: 12 }), { min: 1, max: 12 });
  assert.deepEqual(L.personsRange({ min_persons: 2, max_persons: null, remaining: 80 }), { min: 2, max: 50 });
  assert.deepEqual(L.personsRange({ min_persons: 0, max_persons: 10, remaining: 1 }), { min: 1, max: 1 });
});
test('Laskun viite: vain yritysasiakkaalle, yksityiselle aina null', () => {
  assert.equal(L.invoiceRefFor('company', ' PO-123 '), 'PO-123'); assert.equal(L.invoiceRefFor('company', '  '), null); assert.equal(L.invoiceRefFor('company', undefined), null);
  assert.equal(L.invoiceRefFor('private', 'PO-123'), null); assert.equal(L.invoiceRefFor('private', ''), null);
  // asiakastyyppi: valittu olemassa oleva asiakas ensin, muuten lomakkeen valinta
  assert.equal(L.effectiveKind(null, 'company'), 'company'); assert.equal(L.effectiveKind(null, 'private'), 'private');
  assert.equal(L.effectiveKind({ customer_kind: 'company' }, 'private'), 'company'); assert.equal(L.effectiveKind({ customer_kind: 'private' }, 'company'), 'private');
  assert.equal(L.effectiveKind({}, 'company'), 'private');
  assert.equal(L.invoiceRefFor(L.effectiveKind({ customer_kind: 'private' }, 'company'), 'PO-1'), null);
});
test('Maksutapa → maksettu-oletus', () => {
  for (const c of ['cash', 'card_terminal', 'mobilepay']) assert.equal(L.paidDefault(c), true, c);
  for (const c of ['pay_later', 'invoice', 'bank_transfer', 'other']) assert.equal(L.paidDefault(c), false, c);
});
test('Lisäpalvelun kuvaus: pelkkä nimen toisto piilotetaan, lisätieto säilyy', () => {
  assert.equal(descRedundant('Pyyhe', 'Lisäpalvelu varaukseen: pyyhe.'), true);
  assert.equal(descRedundant('Turvenaamio ja jalkakylpy', 'Lisäpalvelu varaukseen: turvenaamio ja jalkakylpy.'), true);
  assert.equal(descRedundant('Towel', 'Add-on for your booking: towel.'), true);
  assert.equal(descRedundant('Pyyhe', 'Iso froteepyyhe, pestään jokaisen käytön jälkeen'), false);
  assert.equal(descRedundant('Pyyhe', ''), true); assert.equal(descRedundant('Pyyhe', null), true);
  assert.equal(cleanDesc('Lisäpalvelu varaukseen: saunavihta (tuore).'), 'Saunavihta (tuore).');
});
test('Tekstit: FI ja EN sisältävät samat avaimet, ei tyhjiä', () => {
  const fi = Object.keys(NB.fi).sort(), en = Object.keys(NB.en).sort();
  assert.deepEqual(en, fi);
  for (const k of fi) { assert.ok(NB.fi[k].trim(), `fi ${k}`); assert.ok(NB.en[k].trim(), `en ${k}`); }
  assert.equal(nbt('step.inc', { name: 'Pyyhe' }), 'Lisää: Pyyhe'); assert.equal(nbt('step.dec', { name: 'Pyyhe' }), 'Vähennä: Pyyhe'); assert.equal(nbt('step.qty', { name: 'Pyyhe' }), 'Pyyhe, määrä');
  assert.match(NB.en['step.inc'], /Increase: \{name\}/);
});
test('Tekstit: näkymissä käytetyt nbt-avaimet löytyvät', () => {
  for (const f of ['admin/views/newbooking.js', 'admin/views/customerform.js', 'admin/views/addons.js', 'admin/views/shared.js', 'admin/stepper.js']) {
    const src = readFileSync(join(root, f), 'utf8');
    for (const m of src.matchAll(/\b(?:T|nbt)\('([\w.]+)'/g)) assert.ok(NB.fi[m[1]] != null, `${f}: avain ${m[1]} puuttuu`);
    for (const m of src.matchAll(/nbt\(`([\w.]+)\.\$\{/g)) assert.ok(Object.keys(NB.fi).some((k) => k.startsWith(`${m[1]}.`)), `${f}: avainryhmä ${m[1]}`);
  }
});
test('Ikonit: stepperin ikonit on määritelty', async () => {
  const { ICONS } = await imp('admin/icons.js');
  for (const k of ['minus', 'add', 'pgprev', 'pgnext', 'check']) assert.ok(ICONS[k], k);
});
test('Tyylit: ei sinistä focus-rengasta, nav-järjestys: Talous heti Varaukset-kohdan jälkeen', () => {
  const css = readFileSync(join(root, 'admin/admin.css'), 'utf8');
  assert.ok(!/1d6fd8/i.test(css), 'sininen #1d6fd8 pois');
  assert.match(css, /:focus-visible\{outline:3px solid var\(--gold\)/);
  const js = readFileSync(join(root, 'admin/admin.js'), 'utf8');
  const order = [...js.matchAll(/\{ path: '([^']*)', label:/g)].map((m) => m[1]);
  assert.equal(order[order.indexOf('varaukset') + 1], 'talous');
  assert.deepEqual(order.slice(0, 9), ['', 'varaukset', 'talous', 'pikakassa', 'laskut', 'kalenteri', 'tarkista', 'uusi', 'asiakkaat']);
});
