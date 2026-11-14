// HALL-ASIAKKAAT-01: asiakasnäkymä muokattavaksi paikallaan (ei vanhaa modaalia). Logiikka, tekstit, lähdetarkistukset ja kokeilutilan mock.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { contactValues, contactProblems, contactPatch, notePatch, consentPatch, revokeArgs, customerHref, newBookingHref } from '../admin/customer-edit-logic.js';
import { CUSTOMER_EDIT_TEXTS } from '../admin/customer-edit-texts.js';
import { viewsMockHandlers } from '../admin/views-mock.js';
import { resultHref } from '../admin/quick-search.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (f) => readFileSync(join(root, f), 'utf8');
const priv = { id: 5, name: 'Testi Asiakas', email: 'testi@example.com', phone: '040 123 4567', customer_kind: 'private', language: 'fi', notes: '', address: null, zip: null, city: null };
const comp = { ...priv, customer_kind: 'company', company: 'Esimerkki Oy', business_id: '1000000-4', address: 'Koivukuja 2', zip: '01300', city: 'Vantaa' };

test('patch: vain muuttuneet kentät, tyhjä → null, ei muutoksia → tyhjä patch', () => {
  assert.deepEqual(contactPatch(priv, contactValues(priv)), {});
  assert.deepEqual(contactPatch(priv, { ...contactValues(priv), language: 'en', city: ' Espoo ', zip: '02100', address: 'Katu 1' }), { language: 'en', city: 'Espoo', zip: '02100', address: 'Katu 1' });
  assert.deepEqual(contactPatch(priv, { ...contactValues(priv), email: '' }), { email: null });
  assert.deepEqual(contactPatch(comp, { ...contactValues(comp), business_id: '10000004', einvoice_address: '', einvoice_operator: '' }), {}, 'y-tunnus normalisoidaan ennen vertailua');
});

test('tyypin vaihto: yksityinen → yritys vie yritystiedot mukaan, yritys → yksityinen ei lähetä y-tunnusta', () => {
  const toCompany = contactPatch(priv, { ...contactValues(priv), kind: 'company', company: 'Uusi Oy', business_id: '1000000-4', address: 'Katu 1', zip: '00100', city: 'Helsinki' });
  assert.deepEqual(toCompany, { customer_kind: 'company', company: 'Uusi Oy', business_id: '1000000-4', address: 'Katu 1', zip: '00100', city: 'Helsinki' });
  const toPrivate = contactPatch(comp, { ...contactValues(comp), kind: 'private', business_id: '' });
  assert.deepEqual(toPrivate, { customer_kind: 'private' });
});

test('validointi: nimi, sähköposti, puhelin, yritys, y-tunnus, postinumero, verkkolaskupari', () => {
  assert.deepEqual(contactProblems(contactValues(priv)), []);
  assert.deepEqual(contactProblems(contactValues(comp)), []);
  const keys = (v) => contactProblems(v).map((p) => p.key);
  assert.deepEqual(keys({ ...contactValues(priv), name: ' ' }), ['err_name']);
  assert.deepEqual(keys({ ...contactValues(priv), email: 'ei-sahkoposti' }), ['err_email']);
  assert.deepEqual(keys({ ...contactValues(priv), phone: 'abc' }), ['err_phone']);
  assert.deepEqual(keys({ ...contactValues(priv), zip: '123' }), ['err_zip']);
  assert.deepEqual(keys({ ...contactValues(comp), company: '', business_id: '1234567-9', address: '', city: '' }), ['err_company', 'err_bid', 'err_street', 'err_city']);
  assert.deepEqual(contactProblems({ ...contactValues(comp), einvoice_address: '003710000004' }).map((p) => p.field), ['einvoice_operator']);
  assert.deepEqual(contactProblems({ ...contactValues(priv), kind: 'company' }).map((p) => p.key), ['err_company', 'err_bid', 'err_street', 'err_city']);
});

test('muistiinpano, lupa, vuosikortin peruutus ja linkit', () => {
  assert.equal(notePatch('vanha', ' vanha '), null);
  assert.deepEqual(notePatch('', 'Uusi muistiinpano'), { notes: 'Uusi muistiinpano' });
  assert.deepEqual(notePatch('vanha', '  '), { notes: null }, 'tyhjennys tallentuu nulliksi');
  assert.deepEqual(consentPatch(true), { marketing_consent: true });
  assert.deepEqual(revokeArgs(3, undefined), { p_id: 3, p_cancel_future: false });
  assert.deepEqual(revokeArgs(3, true), { p_id: 3, p_cancel_future: true });
  assert.equal(customerHref(42), '#/asiakkaat/42');
  assert.equal(newBookingHref(42), '#/uusi?c=42');
  assert.equal(resultHref('customer', { id: 42 }), '#/asiakkaat/42', 'pikahaku vie asiakasnäkymään');
});

test('tekstit: FI = EN, paikkamerkit täsmäävät, pending-import-161 täsmää tekstimoduuliin', () => {
  assert.deepEqual(Object.keys(CUSTOMER_EDIT_TEXTS.fi).sort(), Object.keys(CUSTOMER_EDIT_TEXTS.en).sort());
  const rows = JSON.parse(read('content/site-texts.pending-import-161.json'));
  assert.equal(rows.length, Object.keys(CUSTOMER_EDIT_TEXTS.fi).length * 2);
  for (const r of rows) {
    assert.equal(r.text, CUSTOMER_EDIT_TEXTS[r.lang][r.key], r.key);
    assert.match(r.key, /^ui\.admin\.customer_view\./);
    assert.ok(r.text.length <= r.max_len, r.key); assert.doesNotMatch(r.text, /<|>|https?:/, r.key);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((x) => x[0]), r.key);
  }
});

test('lähde: kortit paikallaan, ei vanhaa modaalia, confirmDialog, ei confirm()-kutsuja, pikahaku ja Uusi varaus -esitäyttö', () => {
  const view = read('booking/admin/views/customer-view.js'), cards = read('booking/admin/views/customer-cards.js'), list = read('booking/admin/views/customers.js');
  assert.doesNotMatch(view + list, /onEdit|async function card\(|function cardsBox/, 'vanha asiakasmodaali poistettu');
  assert.doesNotMatch(cards, /\bdialog\(|window\.confirm|[^.\w]confirm\(/, 'korteissa ei modaalia eikä selaimen confirm()');
  for (const f of ['contactCard', 'consentCard', 'notesCard', 'annualCard']) assert.match(view, new RegExp(`${f}\\(`), f);
  assert.match(cards, /role: 'switch'/, 'markkinointilupa kytkimenä');
  assert.match(cards, /admin_update_customer/); assert.match(cards, /admin_revoke_annual_card/); assert.match(cards, /admin_create_annual_card/);
  assert.match(view, /href: newBookingHref\(m\.id\)/);
  assert.match(read('booking/admin/views/newbooking.js'), /query\.get\('c'\)[\s\S]{0,200}admin_get_customer/);
  assert.match(list, /location\.replace\(`#\/asiakkaat\/\$\{directId\}`\)/, 'vanha ?id= -osoite ohjataan');
  assert.doesNotMatch(read('booking/admin/quick-search.js'), /asiakkaat\?id=/);
});

test('kokeilutila: admin_update_customer muuttaa kieltä, tyyppiä, osoitetta, lupaa ja muistiinpanoa; säännöt kuten palvelimella', async () => {
  const st = { customers: [{ id: 1, name: 'Aino Testaaja', email: 'aino@example.com', phone: '+358401110001' }], reservations: [], annualCards: [{ id: 9, code: 'KOKEILU1', customer_id: 1, valid_from: '2026-01-01', valid_to: '2026-12-31', active: true }] };
  const err = (code, message) => Object.assign(new Error(message), { code });
  const h = viewsMockHandlers({ st, need: () => {}, err, now: new Date('2026-11-14T10:00:00Z') });
  const get = () => h.admin_get_customer({ p_id: 1 });
  const before = get();
  assert.equal(before.marketing_consent, true); assert.equal(before.annual_cards[0].id, 9);
  h.admin_update_customer({ p_id: 1, p_patch: { language: 'en', address: 'Katu 1', zip: '00100', city: 'Helsinki', notes: 'Muistiinpano', marketing_consent: false } });
  const after = get();
  assert.deepEqual([after.language, after.address, after.zip, after.city, after.notes, after.marketing_consent], ['en', 'Katu 1', '00100', 'Helsinki', 'Muistiinpano', false]);
  assert.throws(() => h.admin_update_customer({ p_id: 1, p_patch: { customer_kind: 'company' } }), /y-tunnus/);
  assert.throws(() => h.admin_update_customer({ p_id: 1, p_patch: { foo: 1 } }), /ei saa muokata/);
  h.admin_update_customer({ p_id: 1, p_patch: { customer_kind: 'company', company: 'Kokeilu Oy', business_id: '1000000-4' } });
  assert.equal(get().customer_kind, 'company');
  h.admin_update_customer({ p_id: 1, p_patch: { marketing_consent: true } });
  assert.equal(get().marketing_consent_source, 'admin');
});
