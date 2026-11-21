// Suora lahjakorttilinkki ?paketti= (listed=false), rajausteksti, kassan gift_cover / gift_covers, pääsyjen saldo.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
  packageQuery, restrictionNote, giftCoverSummary, giftCoverAmount, itemsGiftCover,
  remainingEntries, mergeFeaturedPackages, payableTotal, showOfferEnded, saleIsOpen,
} from '../shop/src/gift-logic.js';
import { createGiftApi, GRPC, normPackages, normPackageResponse } from '../shop/src/gift-api.js';
import { createGiftMock, DIRECT_GIFT_PACKAGES, MOCK_PACKAGES } from '../shop/src/gift-mock.js';
import { PUBLISHED_GIFT_PACKAGES } from '../shop/src/gift-offers.js';
import { GT, gtText } from '../shop/src/gift-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');

test('packageQuery lukee ?paketti= ja siivoaa tyhjän', () => {
  assert.equal(packageQuery({ search: '?paketti=bf_jalkiloylyt_mato' }), 'bf_jalkiloylyt_mato');
  assert.equal(packageQuery({ search: '?paketti=mv_yleiset_mato&mock=1' }), 'mv_yleiset_mato');
  assert.equal(packageQuery({ search: '' }), '');
  assert.equal(packageQuery({ search: '?foo=1' }), '');
});

test('julkaistu valikoima, JSON-LD ja esirenderöinti eivät sisällä kampanjapaketteja', () => {
  const codes = PUBLISHED_GIFT_PACKAGES.map((p) => p.code);
  assert.ok(!codes.includes('bf_jalkiloylyt_mato'));
  assert.ok(!codes.includes('mv_yleiset_mato'));
  const offers = readFileSync(join(root, 'booking/shop/src/gift-offers.js'), 'utf8');
  assert.doesNotMatch(offers, /bf_jalkiloylyt_mato|mv_yleiset_mato/);
});

test('mock: listasta puuttuvat unlisted-paketit; package() palauttaa ne', async () => {
  const api = createGiftApi({ mock: true, mockFactory: () => createGiftMock({ delay: 0 }) });
  const list = await api.packages();
  assert.equal(list.ok, true);
  assert.ok(list.packages.every((p) => p.code !== 'bf_jalkiloylyt_mato' && p.code !== 'mv_yleiset_mato'));
  const bf = await api.package('bf_jalkiloylyt_mato');
  assert.equal(bf.ok, true);
  assert.equal(bf.package.code, 'bf_jalkiloylyt_mato');
  assert.equal(bf.package.listed, false);
  assert.equal(bf.package.name, 'Jälkilöylylahjakortti');
  assert.equal(bf.package.price, 130);
  assert.equal(restrictionNote(bf.package, 'fi'), 'Voimassa 6 kk, ma–to. Ei voimassa 24.–30.12.');
  const yl = await api.package('mv_yleiset_mato');
  assert.equal(yl.ok, true);
  assert.equal(yl.package.listed, false);
  assert.equal(yl.package.name, 'Yleisten vuorojen lahjakortti 2 hengelle');
  assert.equal(yl.package.price, 50);
  assert.equal(yl.package.restrictions.unit_value, 25);
  assert.equal(restrictionNote(yl.package, 'fi'), 'Voimassa 6 kk, ma–to. 2 henkeä, voi käyttää kahdessa osassa. Ei voimassa 24.–30.12. Turvetorstaina maksetaan erotus.');
  const missing = await api.package('ei_ole');
  assert.equal(missing.ok, false);
  assert.equal(missing.code, 'package_inactive');
});

test('mergeFeaturedPackages: unlisted näyttää vain sen paketin; listed ei tuplaa', () => {
  const list = { ok: true, sale_enabled: true, redeem_enabled: true, max_cards: 10, currency: 'EUR', packages: [{ code: 'open', listed: true }, { code: 'entry_2', listed: true }] };
  const unlisted = { code: 'bf_jalkiloylyt_mato', listed: false, price: 130 };
  const only = mergeFeaturedPackages(list, unlisted, { sale_enabled: true });
  assert.deepEqual(only.packages.map((p) => p.code), ['bf_jalkiloylyt_mato']);
  const listed = { code: 'entry_2', listed: true };
  const mixed = mergeFeaturedPackages(list, listed, { sale_enabled: true });
  assert.deepEqual(mixed.packages.map((p) => p.code), ['entry_2', 'open']);
});

test('restrictionNote käyttää note_en englanniksi, muuten note', () => {
  const p = { restrictions: { note: 'Voimassa 6 kk, ma–to.', note_en: 'Valid 6 months, Mon–Thu.' } };
  assert.equal(restrictionNote(p, 'fi'), 'Voimassa 6 kk, ma–to.');
  assert.equal(restrictionNote(p, 'en'), 'Valid 6 months, Mon–Thu.');
  assert.equal(restrictionNote({ restrictions: { note: 'Vain ma–to.' } }, 'en'), 'Vain ma–to.');
  assert.equal(restrictionNote({}, 'fi'), '');
});

test('gift_cover ja gift_covers[]: summa ja uses', () => {
  assert.equal(giftCoverAmount({ price_breakdown: { gift_cover: { amount: 50 } } }), 50);
  const multi = { price_breakdown: { gift_covers: [{ amount: 4, uses: 1 }, { amount: 4, uses: 1 }] } };
  assert.deepEqual(giftCoverSummary(multi), { amount: 8, uses: 2 });
  assert.deepEqual(giftCoverSummary({ price_breakdown: { gift_covers: [{ amount: 0, uses: 2, unit_value: 25 }] } }), { amount: 0, uses: 2 });
  const items = [{ price_breakdown: { gift_cover: { amount: 50 } } }, { price_breakdown: { gift_covers: [{ amount: 4, uses: 1 }] } }];
  assert.deepEqual(itemsGiftCover(items), { amount: 54, uses: 1 });
  assert.equal(giftCoverAmount({}), 0);
});

test('payableTotal käyttää balance.total kun se on annettu', () => {
  assert.equal(payableTotal({ total: 180, balance: { total: 130 } }), 130);
  assert.equal(payableTotal({ total: 180 }), 180);
  assert.equal(payableTotal({}), 0);
});

test('remainingEntries: floor(saldo/unit_value), esim. 1/2', () => {
  const r = remainingEntries({ balance: 25, initial_amount: 50, restrictions: { unit_value: 25 } });
  assert.deepEqual(r, { left: 1, total: 2, unit: 25 });
  assert.equal(gtText('fi', 'entriesLeft', { left: r.left, total: r.total }), '1/2 pääsyä jäljellä');
  assert.equal(gtText('en', 'entriesLeft', { left: r.left, total: r.total }), '1/2 entries left');
  assert.equal(remainingEntries({ balance: 50, restrictions: {} }), null);
  assert.equal(remainingEntries({ balance: 0, initial_amount: 50, restrictions: { unit_value: 25 } }).left, 0);
});

test('virheet gift_card_not_applicable ja gift_card_empty FI+EN, ei Black Friday -sanaa', () => {
  assert.equal(GT.fi['err.gift_card_not_applicable'], 'Tämä lahjakortti ei käy tähän varaukseen.');
  assert.equal(GT.en['err.gift_card_not_applicable'], 'This gift card cannot be used for this booking.');
  assert.ok(GT.fi['err.gift_card_empty'].trim());
  assert.ok(GT.en['err.gift_card_empty'].trim());
  const blob = JSON.stringify(GT) + DIRECT_GIFT_PACKAGES.map((p) => p.name + p.description + (p.restrictions?.note || '')).join();
  assert.doesNotMatch(blob, /black\s*friday/i);
});

test('mock-osto hyväksyy suoran paketin koodin', async () => {
  const api = createGiftApi({ mock: true, mockFactory: () => createGiftMock({ delay: 0 }) });
  const r = await api.buy({ p_name: 'Olli Ostaja', p_email: 'o@x.fi', p_phone: '0401234567', p_locale: 'fi', p_items: [{ package: 'mv_yleiset_mato', quantity: 1 }] });
  assert.equal(r.ok, true);
  assert.equal(r.total, 50);
  assert.equal(r.cards[0].package_code, 'mv_yleiset_mato');
});

test('saldotarkistus palauttaa restrictions ja jäljellä olevat pääsyt', async () => {
  const api = createGiftApi({ mock: true, mockFactory: () => createGiftMock({ delay: 0 }) });
  const r = await api.check('HHMV-YLEI-1234');
  assert.equal(r.ok, true);
  assert.equal(r.balance, 25);
  assert.equal(r.initial_amount, 50);
  assert.equal(r.restrictions.unit_value, 25);
  const e = remainingEntries(r);
  assert.equal(e.left, 1);
  assert.equal(e.total, 2);
});

test('normPackages ei vuoda unlisted-pakettia listasta; normPackageResponse säilyttää listed=false', () => {
  const list = normPackages({ ok: true, sale_enabled: true, redeem_enabled: true, max_cards_per_order: 10, currency: 'EUR', packages: MOCK_PACKAGES });
  assert.ok(list.packages.every((p) => p.listed !== false || p.code !== 'bf_jalkiloylyt_mato'));
  const one = normPackageResponse({ ok: true, sale_enabled: true, package: DIRECT_GIFT_PACKAGES[0] });
  assert.equal(one.package.listed, false);
  assert.equal(GRPC.package, 'public_gift_card_package');
});

test('?paketti= myynnin päätyttyä: package_inactive, showOfferEnded, ei tyhjää näkymää', async () => {
  const before = Date.parse('2026-11-30T09:59:59+02:00');
  const at = Date.parse('2026-11-30T10:00:00+02:00');
  const open = createGiftApi({ mock: true, mockFactory: () => createGiftMock({ delay: 0, now: before }) });
  const closed = createGiftApi({ mock: true, mockFactory: () => createGiftMock({ delay: 0, now: at }) });
  const ok = await open.package('bf_jalkiloylyt_mato');
  assert.equal(ok.ok, true);
  assert.equal(saleIsOpen(ok.package, before), true);
  assert.equal(saleIsOpen(ok.package, at), false);
  const ended = await closed.package('mv_yleiset_mato');
  assert.equal(ended.ok, false);
  assert.equal(ended.code, 'package_inactive');
  assert.equal(showOfferEnded('mv_yleiset_mato', ended), true);
  assert.equal(showOfferEnded('mv_yleiset_mato', ok), false);
  assert.equal(showOfferEnded('', ended), false);
  assert.equal(showOfferEnded('mv_yleiset_mato', null), false);
  assert.equal(GT.fi.offerEnded, 'Tarjous on päättynyt');
  assert.equal(GT.en.offerEnded, 'This offer has ended');
  const buy = await closed.buy({ p_name: 'Olli Ostaja', p_email: 'o@x.fi', p_phone: '0401234567', p_locale: 'fi', p_items: [{ package: 'bf_jalkiloylyt_mato', quantity: 1 }] });
  assert.equal(buy.ok, false);
  assert.equal(buy.code, 'sale_ended');
  assert.equal(GT.fi['err.sale_ended'], 'Tarjouksen myynti on päättynyt.');
  assert.equal(GT.en['err.sale_ended'], 'This offer has ended.');
});
