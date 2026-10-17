// Lahjakortit (hallinta, sopimus §13) – yksikkötestit (node --test): datakerroksen parametrit, normalisointi, mock-palvelimen säännöt, tekstit FI/EN, ikonit.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const imp = (p) => import(pathToFileURL(join(root, p)));
const G = await imp('admin/giftcards-api.js');
const { createGiftMock, MOCK_PACKAGES } = await imp('admin/giftcards-mock.js');
const { TEXTS } = await imp('admin/talous-texts.js');
const { ICONS } = await imp('admin/icons.js');
const TODAY = '2026-10-17';
const mk = () => createGiftMock({ today: TODAY });
const fail = async (p, code) => { await assert.rejects(p, (e) => { assert.equal(e.code, code); return true; }); };

test('Koodin normalisointi ja muotoilu (isot kirjaimet, viivat ja välilyönnit pois)', () => {
  assert.equal(G.normalizeGiftCode('hh4a-bcde-fghj'), 'HH4ABCDEFGHJ');
  assert.equal(G.normalizeGiftCode('  hh4a bcde  fghj '), 'HH4ABCDEFGHJ');
  assert.equal(G.normalizeGiftCode('HH4A_BCDE.FGHJ'), 'HH4ABCDEFGHJ');
  assert.equal(G.normalizeGiftCode(null), '');
  assert.equal(G.formatGiftCode('hh4abcdefghj'), 'HH4A-BCDE-FGHJ');
  assert.equal(G.formatGiftCode('HH4A'), 'HH4A', 'liian lyhyt koodi ei muotoudu');
});

test('Datakerros: RPC-nimet ja p_-parametrit sopimuksen mukaan (vain asetetut)', async () => {
  const calls = [];
  const be = G.rpcBackend(async (name, args) => { calls.push({ name, args }); return { ok: true }; });
  await be.list({ search: 'abc', status: 'active', sort: 'balance_desc', limit: 500, offset: 25, unverified: true, expiringDays: 30, hasBalance: false });
  assert.deepEqual(calls.at(-1), { name: 'admin_list_gift_cards', args: { p_search: 'abc', p_status: 'active', p_unverified: true, p_expiring_days: 30, p_has_balance: false, p_sort: 'balance_desc', p_limit: 200, p_offset: 25 } });
  await be.list({});
  assert.deepEqual(calls.at(-1).args, { p_sort: 'created_desc', p_limit: 50, p_offset: 0 });
  await be.get({ code: 'hh4a bcde fghj' }); assert.deepEqual(calls.at(-1), { name: 'admin_get_gift_card', args: { p_code: 'HH4ABCDEFGHJ' } });
  await be.get({ id: 7 }); assert.deepEqual(calls.at(-1), { name: 'admin_get_gift_card', args: { p_id: 7 } });
  await be.create({ package: 'open', amount: 75, note: 'syy', recipientName: 'A', greeting: 'Hei' });
  assert.deepEqual(calls.at(-1), { name: 'admin_create_gift_card', args: { p_package: 'open', p_amount: 75, p_quantity: 1, p_recipient_name: 'A', p_greeting: 'Hei', p_locale: 'fi', p_note: 'syy', p_channel: 'admin', p_delivery_to: 'buyer' } });
  await be.create({ package: 'entry_2', quantity: 2, buyer: { name: 'B', email: 'b@example.invalid', phone: '' }, paymentMethod: 'cash', vatTreatment: 'at_redemption', validMonths: 12, channel: 'phone' });
  assert.deepEqual(calls.at(-1).args, { p_package: 'entry_2', p_quantity: 2, p_buyer: { name: 'B', email: 'b@example.invalid' }, p_payment_method: 'cash', p_vat_treatment: 'at_redemption', p_valid_months: 12, p_locale: 'fi', p_channel: 'phone', p_delivery_to: 'buyer' });
  await be.setExpiry({ id: 3, validTo: '2027-01-31', note: 'x' }); assert.deepEqual(calls.at(-1), { name: 'admin_set_gift_card_expiry', args: { p_id: 3, p_valid_to: '2027-01-31', p_note: 'x' } });
  await be.adjust({ id: 3, delta: -5, reason: 'korjaus', markVerified: true }); assert.deepEqual(calls.at(-1), { name: 'admin_adjust_gift_card', args: { p_id: 3, p_delta: -5, p_reason: 'korjaus', p_mark_verified: true } });
  await be.adjust({ id: 3, delta: 5, reason: 'korjaus' }); assert.ok(!('p_mark_verified' in calls.at(-1).args));
  await be.deactivate({ id: 3, reason: 'syy' }); assert.deepEqual(calls.at(-1), { name: 'admin_deactivate_gift_card', args: { p_id: 3, p_reason: 'syy' } });
  await be.reactivate({ id: 3, reason: 'syy' }); assert.deepEqual(calls.at(-1), { name: 'admin_reactivate_gift_card', args: { p_id: 3, p_reason: 'syy' } });
  await be.redeem({ orderId: 9, code: 'hh4a-bcde-fghj', amount: 12.5, note: 'n' }); assert.deepEqual(calls.at(-1), { name: 'admin_redeem_gift_card', args: { p_order_id: 9, p_code: 'HH4ABCDEFGHJ', p_amount: 12.5, p_note: 'n' } });
  await be.redeem({ orderId: 9, code: 'HH4ABCDEFGHJ' }); assert.deepEqual(calls.at(-1).args, { p_order_id: 9, p_code: 'HH4ABCDEFGHJ' }, 'tyhjä summa → ei p_amount (palvelin: pienempi saldosta ja maksamattomasta)');
  await be.packages(); assert.equal(calls.at(-1).name, 'admin_list_gift_card_packages');
});

test('Datakerros: {ok:false} → RpcError; puuttuva RPC → FeatureNotReady; kirjoitus ei putoa mockiin oikeassa tilassa', async () => {
  const bad = G.createGiftApi({ rpc: async () => ({ ok: false, code: 'gift_card_not_found', message: 'Lahjakorttia ei löydy' }), mock: false });
  await fail(bad.get({ id: 1 }), 'gift_card_not_found');
  const calls = [];
  const gone = G.createGiftApi({ rpc: async (n) => { calls.push(n); throw Object.assign(new Error('Could not find the function booking.x'), { status: 404, code: 'PGRST202' }); }, mock: false });
  for (const f of [() => gone.list({}), () => gone.create({ package: 'open', amount: 50, note: 'abc' }), () => gone.redeem({ orderId: 1, code: 'HH4ABCDEFGHJ' })]) await assert.rejects(f(), (e) => e.name === 'FeatureNotReady');
  assert.equal(calls.length, 3, 'jokainen kutsu meni palvelimelle, ei mockiin');
  assert.equal(gone.mode, 'real'); assert.equal(await gone.settings(), null, 'asetukset: virhe → null (ei estä)');
  const m = G.createGiftApi({ rpc: async () => { throw new Error('ei saa kutsua'); }, mock: true });
  assert.equal(m.mode, 'mock'); assert.equal(m.reason, 'param'); assert.ok((await m.list({})).total > 0);
});

test('Datakerros: normalisointi (luvut, tilat, varmistus)', () => {
  const l = G.normList({ total: '3', sum_balance: '12.5', rows: [{ id: 1, code: 'HH', initial_amount: '50', balance: '25.5', status: 'active', balance_verified: null }] });
  assert.equal(l.total, 3); assert.equal(l.rows[0].balance, 25.5); assert.equal(l.rows[0].effective_status, 'active'); assert.equal(l.rows[0].balance_verified, true);
  const p = G.normPackages({ settings: { sale_enabled: false, redeem_enabled: true }, packages: [{ code: 'open', price: null, min_amount: '29', max_amount: '500' }, { code: 'entry_2', price: '58' }] });
  assert.deepEqual(p.settings, { sale_enabled: false, redeem_enabled: true, johku_cards_redeemable: false });
  assert.equal(p.packages[0].price, null); assert.equal(p.packages[0].min_amount, 29); assert.equal(p.packages[1].price, 58);
});

test('Mock: lista, haku (koodin osa/nimi/tilausnumero), suodattimet, lajittelu, sivutus', async () => {
  const m = mk(), R = (n, a) => m.rpc(n, a);
  const all = await R('admin_list_gift_cards', {});
  assert.equal(all.total, 32); assert.equal(all.rows.length, 32 > 50 ? 50 : 32);
  const p1 = await R('admin_list_gift_cards', { p_limit: 25 }), p2 = await R('admin_list_gift_cards', { p_limit: 25, p_offset: 25 });
  assert.equal(p1.rows.length + p2.rows.length, 32); assert.equal(new Set([...p1.rows, ...p2.rows].map((r) => r.id)).size, 32);
  const c = all.rows[5];
  assert.ok((await R('admin_list_gift_cards', { p_search: c.code.toLowerCase().replace(/-/g, ' ').slice(0, 9) })).rows.some((r) => r.id === c.id), 'koodin osa pienillä kirjaimilla ja välilyönnillä');
  assert.equal((await R('admin_list_gift_cards', { p_search: 'zzzz-ei-löydy' })).total, 0);
  assert.ok((await R('admin_list_gift_cards', { p_search: 'ostaja1@example' })).total >= 1);
  const ex = await R('admin_list_gift_cards', { p_status: 'expired' }); assert.ok(ex.total >= 1 && ex.rows.every((r) => r.effective_status === 'expired'), 'vanhentunut huomioi päivän (status active + valid_to < tänään)');
  assert.equal((await R('admin_list_gift_cards', { p_source: 'johku' })).total, 18);
  const un = await R('admin_list_gift_cards', { p_unverified: true }); assert.ok(un.total > 0 && un.rows.every((r) => r.balance_verified === false));
  const soon = await R('admin_list_gift_cards', { p_expiring_days: 30 }); assert.ok(soon.rows.every((r) => r.valid_to >= TODAY && r.valid_to <= '2026-11-16'));
  const bal = (await R('admin_list_gift_cards', { p_sort: 'balance_desc' })).rows.map((r) => r.balance); assert.deepEqual(bal, [...bal].sort((a, b) => b - a));
  await fail(R('admin_list_gift_cards', { p_sort: 'mitä_tahansa' }), 'invalid_sort');
  assert.equal(all.sum_balance_redeemable <= all.sum_balance, true);
});

test('Mock: luonti – paketit, summat, tervehdys, maksuton myöntö vs. myynti', async () => {
  const m = mk(), R = (n, a) => m.rpc(n, a);
  await fail(R('admin_create_gift_card', { p_package: 'ei_ole', p_note: 'abc' }), 'invalid_package');
  await fail(R('admin_create_gift_card', { p_package: 'open', p_amount: 28.99, p_note: 'abc' }), 'invalid_amount');
  await fail(R('admin_create_gift_card', { p_package: 'open', p_amount: 500.01, p_note: 'abc' }), 'invalid_amount');
  await fail(R('admin_create_gift_card', { p_package: 'open', p_amount: 50.555, p_note: 'abc' }), 'invalid_amount');
  await fail(R('admin_create_gift_card', { p_package: 'entry_2', p_amount: 57, p_note: 'abc' }), 'invalid_amount');
  await fail(R('admin_create_gift_card', { p_package: 'open', p_amount: 50 }), 'invalid_param');
  await fail(R('admin_create_gift_card', { p_package: 'open', p_amount: 50, p_note: 'ab' }), 'invalid_param');
  await fail(R('admin_create_gift_card', { p_package: 'open', p_amount: 50, p_note: 'abc', p_greeting: 'x'.repeat(301) }), 'invalid_greeting');
  await fail(R('admin_create_gift_card', { p_package: 'open', p_amount: 50, p_note: 'abc', p_quantity: 11 }), 'invalid_quantity');
  const free = await R('admin_create_gift_card', { p_package: 'open', p_amount: 29, p_note: 'Hyvitys', p_greeting: 'x'.repeat(300) });
  assert.equal(free.complimentary, true); assert.equal(free.order_id, null); assert.equal(free.cards[0].status, 'active'); assert.match(free.cards[0].code, /^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/); assert.equal(free.cards[0].balance, 29);
  const cash = await R('admin_create_gift_card', { p_package: 'entry_2', p_quantity: 2, p_payment_method: 'cash', p_buyer: { name: 'A', email: 'a@example.invalid' } });
  assert.equal(cash.paid, true); assert.equal(cash.total, 116); assert.equal(cash.cards.length, 2); assert.ok(cash.cards.every((c) => c.status === 'active' && c.balance === 58 && c.order_no === cash.order_no));
  const inv = await R('admin_create_gift_card', { p_package: 'saunotus_2', p_payment_method: 'invoice', p_buyer: { name: 'A', email: 'a@example.invalid' } });
  assert.equal(inv.paid, false); assert.equal(inv.cards[0].status, 'pending_payment'); assert.equal(inv.cards[0].balance, 0);
  const codes = new Set(m.state.cards.map((c) => c.code)); assert.equal(codes.size, m.state.cards.length, 'koodit uniikkeja');
});

test('Mock: voimassaolo, korjaus, mitätöinti, aktivointi, historia ja saldojohdonmukaisuus', async () => {
  const m = mk(), R = (n, a) => m.rpc(n, a);
  const c = (await R('admin_create_gift_card', { p_package: 'open', p_amount: 100, p_note: 'testi' })).cards[0];
  await fail(R('admin_set_gift_card_expiry', { p_id: c.id, p_valid_to: 'huomenna' }), 'invalid_date');
  let r = await R('admin_set_gift_card_expiry', { p_id: c.id, p_valid_to: '2020-01-01', p_note: 'x' }); assert.equal(r.card.effective_status, 'expired');
  r = await R('admin_set_gift_card_expiry', { p_id: c.id, p_valid_to: '2027-05-05' }); assert.equal(r.card.effective_status, 'active');
  await fail(R('admin_adjust_gift_card', { p_id: c.id, p_delta: -100.01, p_reason: 'korjaus' }), 'balance_below_zero');
  await fail(R('admin_adjust_gift_card', { p_id: c.id, p_delta: 5, p_reason: 'ab' }), 'invalid_param');
  await fail(R('admin_adjust_gift_card', { p_id: c.id, p_delta: 0, p_reason: 'korjaus' }), 'invalid_amount');
  await R('admin_adjust_gift_card', { p_id: c.id, p_delta: -100, p_reason: 'nollaus' }); assert.equal((await R('admin_get_gift_card', { p_id: c.id })).card.status, 'used');
  await R('admin_adjust_gift_card', { p_id: c.id, p_delta: 10, p_reason: 'lisäys' }); assert.equal((await R('admin_get_gift_card', { p_id: c.id })).card.status, 'active');
  await R('admin_deactivate_gift_card', { p_id: c.id, p_reason: 'virhe' }); assert.equal((await R('admin_get_gift_card', { p_id: c.id })).card.status, 'cancelled');
  await fail(R('admin_redeem_gift_card', { p_order_id: 1, p_code: c.code }), 'gift_card_inactive');
  await R('admin_reactivate_gift_card', { p_id: c.id, p_reason: 'palautus' });
  const d = await R('admin_get_gift_card', { p_code: c.code.toLowerCase() });
  assert.equal(d.card.status, 'active'); assert.equal(d.ledger_consistent, true);
  assert.deepEqual(d.ledger.map((x) => x.reason), ['manual_issue', 'expiry_change', 'expiry_change', 'adjust', 'adjust', 'cancel', 'reactivate']);
  assert.equal(d.expiry_log.length, 2);
  const pend = m.state.cards.find((x) => x.status === 'pending_payment');
  await fail(R('admin_reactivate_gift_card', { p_id: pend.id, p_reason: 'yritys' }), 'gift_card_not_paid');
  await fail(R('admin_get_gift_card', { p_id: 99999 }), 'gift_card_not_found');
  for (const x of m.state.cards) assert.equal((await R('admin_get_gift_card', { p_id: x.id })).ledger_consistent, true, `kortin ${x.id} saldo = tapahtumien summa`);
});

test('Mock: lunastus – osittainen, virheet (vanhentunut, tyhjä, Johku suljettu, kytkin pois), accounted-lippu', async () => {
  const m = mk(), R = (n, a) => m.rpc(n, a);
  const c = (await R('admin_create_gift_card', { p_package: 'open', p_amount: 80, p_note: 'testi', p_vat_treatment: 'at_redemption' })).cards[0];
  const a = await R('admin_redeem_gift_card', { p_order_id: 5, p_code: c.code.toLowerCase().replace(/-/g, ' '), p_amount: 30 });
  assert.equal(a.amount, 30); assert.equal(a.gift_card.balance, 50); assert.equal(a.accounted, true); assert.ok(a.receipt_no);
  const b = await R('admin_redeem_gift_card', { p_order_id: 5, p_code: c.code });
  assert.equal(b.amount, 50, 'tyhjä summa = koko jäljellä oleva saldo'); assert.equal(b.gift_card.status, 'used');
  await fail(R('admin_redeem_gift_card', { p_order_id: 5, p_code: c.code }), 'gift_card_empty');
  await fail(R('admin_redeem_gift_card', { p_order_id: 5, p_code: 'HHZZ-ZZZZ-ZZZZ' }), 'gift_card_not_found');
  const pkg = (await R('admin_create_gift_card', { p_package: 'entry_2', p_note: 'testi' })).cards[0];
  await fail(R('admin_redeem_gift_card', { p_order_id: 5, p_code: pkg.code, p_amount: 59 }), 'insufficient_balance');
  const r = await R('admin_redeem_gift_card', { p_order_id: 5, p_code: pkg.code, p_amount: 20 }); assert.equal(r.accounted, false); assert.equal(r.receipt_no, null, 'at_sale: ei uutta kuittia');
  const old = m.state.cards.find((x) => x.valid_to < TODAY && x.status === 'active');
  await fail(R('admin_redeem_gift_card', { p_order_id: 5, p_code: old.code }), 'gift_card_expired');
  const johku = m.state.cards.find((x) => x.source === 'johku' && x.status === 'active' && x.balance > 0);
  await fail(R('admin_redeem_gift_card', { p_order_id: 5, p_code: johku.code }), 'johku_cards_closed');
  const off = createGiftMock({ today: TODAY, settings: { redeem_enabled: false } });
  await fail(off.rpc('admin_redeem_gift_card', { p_order_id: 1, p_code: pkg.code }), 'redeem_disabled');
  assert.equal((await off.rpc('admin_list_gift_card_packages')).settings.redeem_enabled, false);
});

test('Mock: pakettien hinnat ja nimet vastaavat tuotannon public_gift_card_packages-vastausta', () => {
  assert.deepEqual(MOCK_PACKAGES.map((p) => [p.code, p.price]), [['open', null], ['entry_2', 58], ['peat_mask_2', 88], ['sauna_treatment_2', 192], ['saunotus_2', 328]]);
  const o = MOCK_PACKAGES[0]; assert.equal(o.min_amount, 29); assert.equal(o.max_amount, 500);
  assert.equal(MOCK_PACKAGES[1].name, 'Sisäänpääsy kahdelle');
});

test('Tekstit: lahjakorttiavaimet FI = EN, muuttujat samat, kaikki dynaamiset avaimet määritelty, ei vaihe-/stubitekstejä', () => {
  const keys = Object.keys(TEXTS.fi).filter((k) => /^(gc|gcst|gcsrc|gcsort)\.|^tab\.giftcards$/.test(k));
  assert.ok(keys.length > 150);
  for (const k of keys) {
    assert.ok(TEXTS.en[k], `EN puuttuu: ${k}`);
    assert.deepEqual([...TEXTS.fi[k].matchAll(/\{(\w+)\}/g)].map((x) => x[1]).sort(), [...TEXTS.en[k].matchAll(/\{(\w+)\}/g)].map((x) => x[1]).sort(), `muuttujat ${k}`);
    assert.ok(!/tulee (käyttöön|myöhemmin)|will (be available|come) (in|later)|vaiheessa [A-D]\b/i.test(TEXTS.fi[k] + TEXTS.en[k]), `stubiteksti: ${k}`);
  }
  const need = [...G.GC_STATUSES.map((s) => `gcst.${s}`), ...['native', 'johku'].map((s) => `gcsrc.${s}`), ...G.GC_SORTS.map((s) => `gcsort.${s}`), ...['value', 'product'].map((s) => `gc.kind.${s}`), ...['at_sale', 'at_redemption'].map((s) => `gc.vat.${s}`),
    ...['admin', 'phone', 'email', 'walk_in', 'other'].map((s) => `gc.n.ch.${s}`), ...['sale', 'redeem', 'johku'].map((s) => `gc.set.${s}`),
    ...['purchase', 'manual_issue', 'redemption', 'refund', 'adjust', 'expiry_change', 'cancel', 'reactivate', 'cancel_refund', 'single_order_forfeit', 'johku_purchase', 'johku_usage', 'johku_adjust', 'johku_sync', 'opening_balance'].map((s) => `gc.led.${s}`),
    ...G.GC_PAY_METHODS.map((s) => `method.${s}`), 'method.gift_card',
    ...['redeem_disabled', 'sale_disabled', 'johku_cards_closed', 'gift_card_not_found', 'gift_card_inactive', 'gift_card_expired', 'gift_card_empty', 'insufficient_balance', 'amount_exceeds_unpaid', 'nothing_to_pay', 'invalid_amount', 'order_not_editable', 'gift_card_not_allowed', 'not_found', 'forbidden',
      'invalid_package', 'invalid_quantity', 'too_many_cards', 'invalid_date', 'balance_below_zero', 'gift_card_not_paid', 'gift_card_required', 'invalid_payment_method', 'invalid_greeting', 'ledger_append_only'].map((c) => `err.${c}`)];
  for (const k of need) assert.ok(TEXTS.fi[k] && TEXTS.en[k], `avain puuttuu: ${k}`);
  assert.notEqual(TEXTS.fi['err.gift_card_expired'], TEXTS.en['err.gift_card_expired']);
});

test('Ikonit ja käyttöliittymä: gift-ikoni, lahjakorttinäkymän ikonit ja oikeudet', () => {
  const src = readFileSync(join(root, 'admin/views/talous-giftcards.js'), 'utf8');
  for (const m of src.matchAll(/icon\('([a-z]+)'/g)) assert.ok(ICONS[m[1]], `ikoni ${m[1]}`);
  assert.ok(ICONS.gift);
  assert.match(src, /giftcards\.admin/); assert.match(src, /payments\.manage/);
  assert.match(readFileSync(join(root, 'admin/views/talous.js'), 'utf8'), /giftcards\.manage/);
  assert.match(readFileSync(join(root, 'admin/admin.js'), 'utf8'), /any: \['payments\.manage', 'giftcards\.manage'\]/);
  assert.doesNotMatch(readFileSync(join(root, 'admin/views/talous-orders.js'), 'utf8'), /recordPayment\([^)]*gift_card/, 'gift_card ei saa mennä admin_record_payment:iin');
  const css = readFileSync(join(root, 'admin/admin.css'), 'utf8');
  assert.ok(!/#(?:00[0-9a-f]{2}ff|0[0-9a-f]{2}[0-9a-f]{2}ee)\b/i.test(css.slice(css.indexOf('/* Lahjakortit'))), 'ei sinistä');
});

test('Datakerros: pdfUrl = gift-card-pdf?t=<public_token>&lang=fi|en (functionUrl kuten receipt-pdf); ei tokenia/functionUrlia → tyhjä', () => {
  const fu = (n, q) => `https://x.supabase.co/functions/v1/${n}?${new URLSearchParams(q)}`;
  const a = G.createGiftApi({ rpc: async () => ({}), io: { functionUrl: fu }, mock: false });
  assert.equal(a.pdfUrl('0654361d-a2b1-43f4-a25c-8c7223907dd0', 'fi'), 'https://x.supabase.co/functions/v1/gift-card-pdf?t=0654361d-a2b1-43f4-a25c-8c7223907dd0&lang=fi');
  assert.ok(a.pdfUrl('t', 'en').endsWith('&lang=en')); assert.ok(a.pdfUrl('t', 'sv').endsWith('&lang=fi'));
  assert.equal(a.pdfUrl('', 'fi'), ''); assert.equal(a.pdfUrl(null, 'fi'), '');
  assert.equal(G.createGiftApi({ rpc: async () => ({}), mock: false }).pdfUrl('t', 'fi'), '');
  assert.equal(G.normDetail({ card: { id: 1, public_token: 'abc' } }).card.public_token, 'abc', 'normDetail säilyttää public_tokenin');
});

// ---------- Toimitusvalinta (sopimus §13.11, migraatio booking_46) ----------
const D = await imp('admin/giftcards-delivery.js');
const SG = await imp('shop/src/gift-logic.js');
test('Toimitusvalinta: p_-parametrit – buyer ei lähetä saajan kenttiä; recipient + ajankohta; kellonaika vain päivän kanssa', async () => {
  const calls = [];
  const be = G.rpcBackend(async (name, args) => { calls.push({ name, args }); return { ok: true }; });
  await be.create({ package: 'open', amount: 50, note: 'syy', deliveryTo: 'buyer', recipientEmail: 'x@y.fi', coverMessage: 'saate', deliverOn: '2027-01-01', deliverTime: '10:00' });
  assert.deepEqual(calls.at(-1).args, { p_package: 'open', p_amount: 50, p_quantity: 1, p_recipient_email: 'x@y.fi', p_locale: 'fi', p_note: 'syy', p_channel: 'admin', p_delivery_to: 'buyer' }, 'buyer: ei saatetta eikä ajankohtaa');
  await be.create({ package: 'open', amount: 50, note: 'syy', deliveryTo: 'recipient', recipientEmail: 'x@y.fi', coverMessage: 'saate', deliverOn: '2027-01-01', deliverTime: '10:00' });
  assert.deepEqual(calls.at(-1).args, { p_package: 'open', p_amount: 50, p_quantity: 1, p_recipient_email: 'x@y.fi', p_locale: 'fi', p_note: 'syy', p_channel: 'admin', p_delivery_to: 'recipient', p_cover_message: 'saate', p_deliver_on: '2027-01-01', p_deliver_time: '10:00' });
  await be.create({ package: 'open', amount: 50, note: 'syy', deliveryTo: 'recipient', recipientEmail: 'x@y.fi', deliverTime: '10:00' });
  assert.ok(!('p_deliver_time' in calls.at(-1).args) && !('p_deliver_on' in calls.at(-1).args), 'heti: ei ajankohtaa; kellonaika ilman päivää ei lähde');
});
test('Toimitusvalinta: normCard antaa kentät (oletus buyer) ja mock-data sisältää toimitettu/ajastettu-kortit', async () => {
  assert.deepEqual([G.normCard({ id: 1 }).delivery_to, G.normCard({ id: 1 }).cover_message, G.normCard({ id: 1 }).deliver_on, G.normCard({ id: 1 }).delivered_at], ['buyer', '', null, null]);
  const m = mk(), { rows } = await m.rpc('admin_list_gift_cards', { p_limit: 200 });
  assert.ok(rows.every((c) => ['buyer', 'recipient'].includes(c.delivery_to) && 'cover_message' in c && 'deliver_on' in c && 'deliver_time' in c && 'delivered_at' in c));
  assert.equal(rows.filter((c) => c.delivery_to === 'recipient' && c.delivered_at).length, 1); assert.equal(rows.filter((c) => c.delivery_to === 'recipient' && c.deliver_on && !c.delivered_at).length, 1);
});
test('Mock: admin_create_gift_card – kaikki toimitusvirhekoodit (BK001-poikkeus, koodi = detail) ja kentät kortilla', async () => {
  const m = mk(), now = D.helsinkiNow().date, R = (a) => m.rpc('admin_create_gift_card', { p_package: 'entry_2', p_note: 'syy', ...a });
  await fail(R({ p_delivery_to: 'x' }), 'invalid_delivery_to');
  await fail(R({ p_delivery_to: 'recipient' }), 'recipient_email_required');
  await fail(R({ p_recipient_email: 'ei' }), 'invalid_email');
  await fail(R({ p_greeting: 'x'.repeat(301) }), 'invalid_greeting');
  await fail(R({ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_cover_message: 'x'.repeat(1001) }), 'invalid_cover_message');
  await fail(R({ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_deliver_on: '2020-01-01' }), 'deliver_on_past');
  await fail(R({ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_deliver_on: D.addMonths(now, 7) }), 'deliver_on_too_far');
  await fail(R({ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_deliver_on: 'huomenna' }), 'invalid_deliver_on');
  await fail(R({ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_deliver_time: '10:00' }), 'invalid_deliver_on');
  await fail(R({ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_deliver_on: D.addMonths(now, 1), p_deliver_time: '25:00' }), 'invalid_deliver_time');
  const fut = D.addMonths(now, 1), r = await R({ p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_cover_message: 'Terve', p_deliver_on: fut, p_deliver_time: '18:30' });
  assert.deepEqual([r.cards[0].delivery_to, r.cards[0].cover_message, r.cards[0].deliver_on, r.cards[0].deliver_time, r.cards[0].delivered_at], ['recipient', 'Terve', fut, '18:30', null]);
  const b = await R({ p_delivery_to: 'buyer', p_cover_message: 'x', p_deliver_on: 'roskaa' }); assert.deepEqual([b.cards[0].delivery_to, b.cards[0].cover_message, b.cards[0].deliver_on], ['buyer', null, null]);
  assert.equal((await R({ p_recipient_email: 'a@b.fi' })).cards[0].delivery_to, 'recipient', 'delivery_to puuttuu + saajan sähköposti → recipient');
});
test('Toimitusvalinta: hallinnan tarkistus = kaupan tarkistus (sama taulukko, samat koodit) ja kenttäkohtaiset virheet', () => {
  const now = new Date('2026-10-17T12:00:00Z');
  const table = [{}, { to: 'recipient' }, { to: 'recipient', recipientEmail: 'a@b.fi' }, { to: 'recipient', recipientEmail: 'a@b.fi', on: '2026-10-16' }, { to: 'recipient', recipientEmail: 'a@b.fi', on: '2026-10-17', time: '14:00' }, { to: 'recipient', recipientEmail: 'a@b.fi', on: '2026-10-17' },
    { to: 'recipient', recipientEmail: 'a@b.fi', on: '2027-04-17' }, { to: 'recipient', recipientEmail: 'a@b.fi', on: '2027-04-18' }, { to: 'recipient', recipientEmail: 'a@b.fi', on: '2026-12-24T18:30' }, { to: 'recipient', recipientEmail: 'a@b.fi', on: '2026-12-24', time: '24:00' },
    { to: 'recipient', recipientEmail: 'a@b.fi', time: '10:00' }, { to: 'recipient', recipientEmail: 'a@b.fi', on: '2026-02-30' }, { to: 'recipient', recipientEmail: 'a@b.fi', cover: 'x'.repeat(1001) }, { to: 'recipient', recipientEmail: 'a@b.fi', cover: ' Hei\r\n\u0000 ' }, { to: 'buyer', cover: 'x', on: 'roskaa' }, { to: 'muu' },
    { to: 'recipient', recipientEmail: 'a@b.fi', on: '2028-10-17', months: 36 }, { to: 'recipient', recipientEmail: 'a@b.fi', on: '2027-01-18', months: 3 }];
  for (const row of table) assert.deepEqual(D.resolveDelivery({ ...row, now }), SG.resolveDelivery({ ...row, now }), JSON.stringify(row));
  assert.deepEqual(D.deliveryErrors({ to: 'buyer', recipientEmail: '', now }), {});
  assert.deepEqual(D.deliveryErrors({ to: 'recipient', recipientEmail: '', now }), { recipientEmail: 'recipient_email_required' });
  assert.deepEqual(D.deliveryErrors({ to: 'recipient', recipientEmail: 'ei', cover: 'x'.repeat(1001), now }), { recipientEmail: 'invalid_email', cover: 'invalid_cover_message' });
  const e = (o) => D.deliveryErrors({ to: 'recipient', recipientEmail: 'a@b.fi', later: true, now, ...o });
  assert.deepEqual(e({ on: '' }), { deliverOn: 'invalid_deliver_on' }); assert.deepEqual(e({ on: '2026-10-16' }), { deliverOn: 'deliver_on_past' }); assert.deepEqual(e({ on: '2027-05-01' }), { deliverOn: 'deliver_on_too_far' });
  assert.deepEqual(e({ on: '2026-12-01', time: '99:00' }), { deliverTime: 'invalid_deliver_time' }); assert.deepEqual(e({ on: '2026-12-01', time: '18:30' }), {});
  assert.deepEqual(Object.keys(D.SERVER_FIELD).sort(), [...SG.DELIVERY_ERROR_CODES, 'invalid_delivery_to'].sort());
});
test('Toimitusvalinta: tekstit FI/EN jokaiselle virhekoodille ja toimitustiloille', () => {
  for (const c of ['recipient_email_required', 'invalid_email', 'invalid_cover_message', 'invalid_greeting', 'invalid_deliver_on', 'invalid_deliver_time', 'deliver_on_past', 'deliver_on_too_far', 'invalid_delivery_to']) for (const l of ['fi', 'en']) assert.ok(TEXTS[l][`err.${c}`] && TEXTS[l][`err.${c}`].length > 10, `${l} err.${c}`);
  for (const k of ['gc.d.delivered', 'gc.d.scheduled', 'gc.d.dlvWaiting', 'gc.row.delivered', 'gc.row.scheduled', 'gc.d.cover', 'gc.d.delivery', 'gc.n.dlv', 'gc.n.cover', 'gc.n.greetingCard']) assert.ok(TEXTS.fi[k] && TEXTS.en[k], k);
  assert.match(TEXTS.fi['gc.n.cover'], /ei näy kortissa/); assert.match(TEXTS.fi['gc.n.greetingCard'], /näkyy kortissa/);
});
