// Hoitovalitsin (migraatio booking_50, sopimus KOODARI_talous_A_D_fi.md §15): kaupan ja hallinnan puhdas logiikka, FI/EN-tekstipariteetti, mockit vs. sopimus
// (pakollisuus, invalid_option, pelkkä hoidon vaihto, valitsematta vanhoilla), tiedostojen yhteensopivuus. Ei verkkoa, ei tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { normOptions, needsOption, hasOptions, findOption, validCode, optLabel, optionOk, withOption, reservationItem, optionMissingOnOrder, optionChanged, optName, isOptionError } from '../shop/src/options-logic.js';
import { OPT, optText } from '../shop/src/options-texts.js';
import { treatmentRpc, resetBookings } from '../shop/src/treatment-mock.js';
import { OPT_TEXTS, optNameFor, optionOfFor, otFor } from '../admin/options-logic.js';
import { createAdminMock, helIso } from '../admin/options-mock.js';

const ROW = { option_required: true, option_label: 'Valitse hoito', option_label_en: 'Choose your treatment', options: [
  { id: 2, code: 'vihtahoito', name: 'Vihtahoito', name_en: 'Birch whisk treatment', sort_order: 20, active: true },
  { id: 1, code: 'hunajahoito', name: 'Hunajahoito', name_en: 'Honey treatment', sort_order: 10, active: true },
  { id: 9, code: 'vanha', name: 'Vanha', sort_order: 5, active: false }] };

test('normOptions: vain aktiiviset, sort_order-järjestys, pakollisuus vaatii aktiivisen vaihtoehdon', () => {
  const n = normOptions(ROW);
  assert.deepEqual(n.options.map((o) => o.code), ['hunajahoito', 'vihtahoito']);
  assert.equal(n.required, true); assert.equal(n.label, 'Valitse hoito'); assert.equal(n.label_en, 'Choose your treatment');
  assert.equal(normOptions({ ...ROW, options: [] }).required, false, 'ei aktiivisia → ei pakollinen (ei lukitse varausta)');
  assert.equal(normOptions({ ...ROW, options: [{ code: 'x', name: 'X', active: false }] }).required, false);
  assert.equal(normOptions({ option_required: false, options: ROW.options }).required, false);
  assert.deepEqual(normOptions(null).options, []); assert.deepEqual(normOptions({ options: 'x' }).options, []);
});
test('needsOption / hasOptions / validCode / optionOk: koodi käsitellään kuten palvelimella (trim + pienet kirjaimet)', () => {
  const p = { option_required: true, options: normOptions(ROW).options };
  assert.equal(needsOption(p), true); assert.equal(hasOptions(p), true);
  assert.equal(needsOption({ option_required: true, options: [] }), false);
  assert.equal(needsOption({ option_required: false, options: p.options }), false);
  assert.equal(validCode(p, ' Hunajahoito '), 'hunajahoito'); assert.equal(validCode(p, 'vanha'), null); assert.equal(validCode(p, ''), null); assert.equal(validCode(p, null), null);
  assert.equal(optionOk(p, ''), false, 'pakollinen: ilman valintaa ei jatketa'); assert.equal(optionOk(p, 'vihtahoito'), true); assert.equal(optionOk(p, 'tuntematon'), false);
  assert.equal(optionOk({ option_required: false, options: p.options }, ''), true, 'valinnainen: jatko sallittu');
  assert.equal(findOption(p, 'vihtahoito').name, 'Vihtahoito');
});
test('nimet ja otsikko kielen mukaan (EN puuttuu → suomi)', () => {
  assert.equal(optName({ name: 'Hunajahoito', name_en: 'Honey treatment' }, 'en'), 'Honey treatment');
  assert.equal(optName({ name: 'Hunajahoito', name_en: 'Honey treatment' }, 'fi'), 'Hunajahoito');
  assert.equal(optName({ name: 'Vanha' }, 'en'), 'Vanha');
  const p = { option_label: 'Valitse hoito', option_label_en: null };
  assert.equal(optLabel(p, 'fi', 'x'), 'Valitse hoito'); assert.equal(optLabel(p, 'en', 'Choose'), 'Valitse hoito'); assert.equal(optLabel({}, 'en', 'Choose'), 'Choose');
});
test('RPC-argumentit: p_option_code / option_code vain kun koodi annettu (vanha kutsu ennallaan)', () => {
  assert.deepEqual(withOption({ p_persons: 1 }, ''), { p_persons: 1 }); assert.deepEqual(withOption({ p_persons: 1 }, 'vihtahoito'), { p_persons: 1, p_option_code: 'vihtahoito' });
  assert.deepEqual(reservationItem({ productId: '10', persons: '2', start: '2026-10-20T13:00:00Z', optionCode: 'suolahoito' }), { type: 'reservation', product_id: 10, persons: 2, start: '2026-10-20T13:00:00Z', option_code: 'suolahoito' });
  assert.equal('option_code' in reservationItem({ productId: 10, persons: 1, start: 'x' }), false);
});
test('tilaussivu: valitsematta vain jos vaihtoehtoja on; muutos vain eri koodiin', () => {
  const r = { option: null, option_choices: [{ code: 'a' }] };
  assert.equal(optionMissingOnOrder(r), true); assert.equal(optionMissingOnOrder({ option: null, option_choices: [] }), false); assert.equal(optionMissingOnOrder({ option: { code: 'a' }, option_choices: [{ code: 'a' }] }), false);
  assert.equal(optionChanged({ option: { code: 'a' } }, 'a'), false); assert.equal(optionChanged({ option: { code: 'a' } }, 'b'), true); assert.equal(optionChanged({ option: null }, 'b'), true); assert.equal(optionChanged({ option: null }, ''), false);
  assert.ok(isOptionError('option_required') && isOptionError('invalid_option') && !isOptionError('slot_unavailable'));
});
test('tekstit: FI ja EN samat avaimet, ei tyhjiä; molemmat kielet kaupassa ja hallinnassa', () => {
  assert.deepEqual(Object.keys(OPT.fi).sort(), Object.keys(OPT.en).sort());
  for (const l of ['fi', 'en']) for (const [k, v] of Object.entries(OPT[l])) assert.ok(String(v).trim(), `OPT.${l}.${k} tyhjä`);
  assert.equal(optText('en', 'notChosen'), 'not chosen'); assert.equal(optText('xx', 'notChosen'), 'valitsematta');
  assert.equal(OPT.fi.notChosen, 'valitsematta');
  assert.deepEqual(Object.keys(OPT_TEXTS.fi).sort(), Object.keys(OPT_TEXTS.en).sort());
  for (const l of ['fi', 'en']) for (const [k, v] of Object.entries(OPT_TEXTS[l])) assert.ok(String(v).trim(), `OPT_TEXTS.${l}.${k} tyhjä`);
  assert.equal(OPT_TEXTS.fi.notChosen, 'valitsematta'); assert.equal(otFor('en', 'save'), 'Save treatment');
  for (const code of ['option_required', 'invalid_option']) { assert.ok(OPT_TEXTS.fi[`err_${code}`] && OPT_TEXTS.en[`err_${code}`]); assert.ok(OPT[ 'fi' ][`err.${code}`] && OPT.en[`err.${code}`]); }
});
test('hallinta: varauksen valinta eri RPC-muodoista; valitsematta vain kun option_missing', () => {
  assert.deepEqual(optionOfFor({ option_name: 'Hunajahoito', option_name_en: 'Honey treatment', option_missing: false }, 'fi'), { name: 'Hunajahoito', missing: false });
  assert.deepEqual(optionOfFor({ option_name: 'Hunajahoito', option_name_en: 'Honey treatment' }, 'en'), { name: 'Honey treatment', missing: false });
  assert.deepEqual(optionOfFor({ option: { code: 'x', name: 'Vihtahoito', name_en: 'Birch whisk treatment' }, option_missing: false }, 'en'), { name: 'Birch whisk treatment', missing: false });
  assert.deepEqual(optionOfFor({ option: null, option_missing: true }, 'fi'), { name: '', missing: true });
  assert.deepEqual(optionOfFor({ option_name: null, option_missing: false }, 'fi'), { name: '', missing: false }, 'tuote ilman valintaa: ei merkkiä');
  assert.deepEqual(optionOfFor({ legs: [] }, 'fi'), { name: '', missing: false }); assert.deepEqual(optionOfFor(null, 'fi'), { name: '', missing: false });
  assert.equal(optNameFor({ name: 'A', name_en: 'B' }, 'en'), 'B'); assert.equal(optNameFor({ code: 'c' }, 'fi'), 'c');
});

// ---- kaupan mock (sama kuin kaupan ?mock=1): sopimus §15 ----
const FUTURE = Date.parse('2026-10-17T10:00:00Z');
const book = (extra = {}) => treatmentRpc('public_create_treatment_booking', { p_product_id: 10, p_start: null, ...extra }, FUTURE);
test('kaupan mock: katalogin options + option_required; varaus ilman/väärällä koodilla hylätään, oikea koodi palauttaa option', () => {
  resetBookings();
  const av = treatmentRpc('public_treatment_availability', { p_product_id: 10, p_from: '2026-10-22', p_to: '2026-10-24', p_persons: 1 }, FUTURE)?.body;
  const first = (Array.isArray(av) ? av : av?.slots || av?.rows || []).find?.((x) => x.status === 'available' || x.status == null);
  assert.ok(first, 'saatavuutta löytyy');
  const args = { p_product_id: 10, p_start: first.starts_at, p_persons: 1, p_name: 'Testi Asiakas', p_email: 'testi@example.com', p_phone: '+358401234567', p_marketing_consent: false, p_locale: 'fi', p_note: null, p_customer_kind: 'private', p_company: null };
  const no = treatmentRpc('public_create_treatment_booking', args, FUTURE)?.body;
  assert.deepEqual([no.ok, no.code], [false, 'option_required']);
  const bad = treatmentRpc('public_create_treatment_booking', { ...args, p_option_code: 'ei-ole' }, FUTURE)?.body;
  assert.deepEqual([bad.ok, bad.code], [false, 'invalid_option']);
  assert.equal(treatmentRpc('public_get_booking', { p_token: 'x' }, FUTURE)?.body?.ok ?? false, false, 'virheellä ei luotu varausta (ei sivuvaikutuksia)');
  const ok = treatmentRpc('public_create_treatment_booking', { ...args, p_option_code: ' VIHTAHOITO ' }, FUTURE)?.body;
  assert.equal(ok.ok, true, JSON.stringify(ok)); assert.equal(ok.option.code, 'vihtahoito'); assert.ok(ok.option.name && ok.option.name_en);
  resetBookings();
});

// ---- hallinnan mock: sopimus §15 ----
const ctx = () => createAdminMock({ now: new Date('2026-10-17T10:00:00Z') });
const code = async (p) => { try { await p; return null; } catch (e) { return e.code; } };
test('hallinnan mock: listat näyttävät option_missing vain vanhoilla hoitovarauksilla, ei rituaalilla', async () => {
  const m = ctx();
  const rows = await m.rpc('admin_list_reservations', { p_limit: 50 });
  const by = (name) => rows.filter((r) => r.product_name === name);
  assert.ok(by('Saunahoito').some((r) => r.option_missing === true && r.option_name === null), 'vanha hoitovaraus: valitsematta');
  assert.ok(by('Saunahoito').some((r) => r.option_name === 'Hunajahoito' && r.option_missing === false));
  assert.ok(by('Rituaali 90 min').every((r) => r.option_missing === false && r.option_id === null), 'rituaali: ei valintaa, ei puuttuvaa');
  const day = await m.rpc('admin_day_view', { p_date: m.today });
  assert.ok(day.reservations.some((r) => r.option?.code === 'hunajahoito') && day.reservations.some((r) => r.option === null && r.option_missing === true));
});
test('hallinnan mock: admin_set_reservation_option (vaihto, tyhjennys pakollisella estetty, väärä koodi, oikeus)', async () => {
  const m = ctx();
  const miss = (await m.rpc('admin_list_reservations', {})).find((r) => r.option_missing);
  const o = await m.rpc('admin_get_order', { p_order_id: miss.order_id });
  assert.equal(o.reservations[0].option_choices.length, 4); assert.equal(o.reservations[0].option_missing, true);
  assert.equal(await code(m.rpc('admin_set_reservation_option', { p_reservation_id: miss.reservation_id, p_option_code: '' })), 'option_required');
  assert.equal(await code(m.rpc('admin_set_reservation_option', { p_reservation_id: miss.reservation_id, p_option_code: 'ei-ole' })), 'invalid_option');
  const r = await m.rpc('admin_set_reservation_option', { p_reservation_id: miss.reservation_id, p_option_code: ' Turvehoito ', p_notify: true });
  assert.equal(r.ok, true); assert.equal(r.option.code, 'turvehoito'); assert.equal(r.previous, null); assert.equal(r.email_queued, true);
  assert.equal((await m.rpc('admin_list_reservations', {})).filter((x) => x.option_missing).length, 1, 'vanhoja valitsematta oli 2 (hoito + tuleva); yksi korjattu');
  const m2 = createAdminMock({ perms: ['catalog.edit'] });
  assert.equal(await code(m2.rpc('admin_set_reservation_option', { p_reservation_id: 901, p_option_code: 'hunajahoito' })), 'forbidden');
});
test('hallinnan mock: uusi varaus vaatii valinnan, virhe ennen sivuvaikutuksia; passivointi poistaa pakollisuuden', async () => {
  const m = ctx(); const before = (await m.rpc('admin_list_reservations', {})).length;
  const a = { p_product_id: 10, p_start: helIso('2026-10-20', '17:00'), p_persons: 1, p_customer: { name: 'Testi' } };
  assert.equal(await code(m.rpc('admin_create_resource_booking', a)), 'option_required');
  assert.equal(await code(m.rpc('admin_create_resource_booking', { ...a, p_option_code: 'x' })), 'invalid_option');
  assert.equal((await m.rpc('admin_list_reservations', {})).length, before, 'ei sivuvaikutuksia virheessä');
  const ok = await m.rpc('admin_create_resource_booking', { ...a, p_option_code: 'suolahoito' });
  assert.equal(ok.option.code, 'suolahoito');
  assert.equal((await m.rpc('admin_create_resource_booking', { p_product_id: 8, p_start: helIso('2026-10-20', '17:00'), p_persons: 1, p_customer: { name: 'T' } })).option, null, 'rituaali ilman valintaa');
  for (const c of ['hunajahoito', 'vihtahoito', 'suolahoito', 'turvehoito']) await m.rpc('admin_upsert_product_option', { p_product_id: 10, p_code: c, p_name: c, p_active: false });
  assert.ok((await m.rpc('admin_create_resource_booking', a)).ok, 'ei aktiivisia vaihtoehtoja → ei pakollinen');
});
test('hallinnan mock: vaihtoehtojen hallinta (upsert, asetukset, no_options, oikeus, koodin muoto)', async () => {
  const m = ctx();
  const l = (await m.rpc('admin_list_product_options', {}))[0];
  assert.equal(l.product_id, 10); assert.equal(l.option_required, true); assert.equal(l.options.length, 4); assert.equal(l.reservations_without_option, 2);
  const u = await m.rpc('admin_upsert_product_option', { p_product_id: 10, p_code: 'KIVIHOITO', p_name: 'Kivihoito', p_name_en: 'Stone treatment', p_sort_order: 50 });
  assert.equal(u.option.code, 'kivihoito');
  assert.equal(await code(m.rpc('admin_upsert_product_option', { p_product_id: 10, p_code: 'Ä ö', p_name: 'x' })), 'invalid_param');
  assert.equal(await code(m.rpc('admin_upsert_product_option', { p_product_id: 99, p_code: 'x', p_name: 'x' })), 'product_not_found');
  await m.rpc('admin_set_product_option_settings', { p_product_id: 10, p_required: false, p_label: 'Valitse', p_label_en: 'Choose' });
  assert.equal((await m.rpc('admin_list_product_options', { p_product_id: 10 }))[0].option_required, false);
  for (const o of (await m.rpc('admin_list_product_options', {}))[0].options) await m.rpc('admin_upsert_product_option', { p_product_id: 10, p_code: o.code, p_name: o.name, p_active: false });
  assert.equal(await code(m.rpc('admin_set_product_option_settings', { p_product_id: 10, p_required: true })), 'no_options');
  assert.equal(await code(createAdminMock({ perms: ['bookings.manage'] }).rpc('admin_upsert_product_option', { p_product_id: 10, p_code: 'x', p_name: 'x' })), 'forbidden');
  assert.equal(await code(m.rpc('admin_tuntematon', {})), 'mock_unsupported', 'tuntematon RPC ei koskaan mene verkkoon');
});
test('helIso: Helsingin aika → UTC (kesä-/talviaika)', () => {
  assert.equal(helIso('2026-10-17', '16:00'), '2026-10-17T13:00:00.000Z'); assert.equal(helIso('2026-12-17', '16:00'), '2026-12-17T14:00:00.000Z'); assert.equal(helIso('2026-07-01', '00:00'), '2026-06-30T21:00:00.000Z');
});

// ---- rakenne: tiedostot ja sopimus ----
const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
test('rakenne: migraatio booking_50 sisältää sopimuksen funktiot; ei begin/commit-kääreitä; rollback ja pgTAP mukana', () => {
  const dir = new URL('../supabase/migrations/', import.meta.url);
  const mig = readFileSync(new URL('20261017202122_booking_50_product_options.sql', dir), 'utf8');
  for (const f of ['admin_set_reservation_option', 'admin_list_product_options', 'admin_upsert_product_option', 'admin_set_product_option_settings', 'p_option_code', 'option_required', 'invalid_option', 'no_options', 'option_missing']) assert.ok(mig.includes(f), `migraatiosta puuttuu ${f}`);
  assert.ok(!/^\s*(begin|commit)\s*;/im.test(mig), 'ei begin/commit-käärettä');
  assert.ok(read('supabase/rollbacks/20261017202122_booking_50_ROLLBACK.sql').includes('product_options'));
  assert.ok(read('supabase/tests/product_options/t50_product_options.sql').includes('option_required'));
});
test('rakenne: kauppa lähettää valinnan (create, add_to_order, change) ja admin lähettää p_option_code / admin_set_reservation_option', () => {
  assert.match(read('shop/src/treatments.js'), /p_option_code/); assert.match(read('shop/src/order-api.js'), /p_option_code/); assert.match(read('shop/src/order-api.js'), /option_code/);
  assert.match(read('admin/views/resbooking.js'), /p_option_code/); assert.match(read('admin/views/shared.js'), /admin_set_reservation_option/);
});
