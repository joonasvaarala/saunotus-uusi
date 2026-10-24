// Uusi lasku › "Tallenna luonnos" ei jää hiljaiseksi: kenttätarkistus, palvelinvirheen kohdekenttä, ilmoitus modaalin päällä,
// tallennuksen tila ja tekstit FI+EN (pending-import-65). Ei tietokantaa eikä selainta (selain: scripts/e2e-lasku-luonnos.mjs).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateInvoiceHeader, serverErrorField, HEADER_ORDER } from '../admin/invoice-header-validate.js';
import { INVOICE_TEXTS } from '../admin/invoices-texts.js';
import { createAdminMock } from '../admin/options-mock.js';
import { lineToPayload } from '../admin/invoice-lines.js';

const root = dirname(fileURLToPath(import.meta.url));
const repo = join(root, '../..');
const read = (p) => readFileSync(join(root, '..', p), 'utf8');
const ok = { company_name: 'Testi Oy', invoice_date: '2026-10-25', due_date: '2026-11-08' };
const keys = (v) => validateInvoiceHeader(v).map((e) => `${e.key}:${e.code}`);

test('Joonaksen lasku (yritys täytetty, Lisätiedot tyhjä) läpäisee tarkistuksen', () => {
  assert.deepEqual(validateInvoiceHeader({ ...ok, notes: '' }), []);
  assert.deepEqual(validateInvoiceHeader({ ...ok, business_id: '0112038-9', einvoice_address: '003701120389', einvoice_operator: 'E204503', email: 'lasku@testi.fi' }), []);
});

test('yrityksen nimi puuttuu → ensimmäinen virhe on Yritys (kenttä on vieritetty pois näkyvistä)', () => {
  assert.deepEqual(keys({ invoice_date: '2026-10-25', due_date: '2026-11-08' }), ['company_name:need_company']);
  assert.deepEqual(keys({ ...ok, company_name: ' x ' }), ['company_name:need_company']);
  assert.deepEqual(keys({ ...ok, company_name: 'a'.repeat(201) }), ['company_name:need_company']);
});

test('kenttävirheet lomakkeen järjestyksessä ja samat säännöt kuin palvelimella', () => {
  assert.deepEqual(keys({ ...ok, company_name: '', email: 'testi@', einvoice_address: '003701120389' }), [
    'company_name:need_company', 'email:err_email', 'einvoice_operator:err_operator_missing',
  ]);
  assert.deepEqual(keys({ ...ok, business_id: '1234567-8' }), ['business_id:err_business_id']);
  assert.deepEqual(keys({ ...ok, einvoice_operator: 'E204503' }), ['einvoice_address:err_ovt_missing']);
  assert.deepEqual(keys({ ...ok, business_id: '0112038-9', einvoice_address: '003799999999', einvoice_operator: 'E204503' }), ['einvoice_address:err_ovt']);
  assert.deepEqual(keys({ ...ok, einvoice_address: '003701120389', einvoice_operator: 'x' }), ['einvoice_operator:err_operator']);
  assert.deepEqual(keys({ ...ok, due_date: '2026-10-24' }), ['due_date:err_due']);
  assert.deepEqual(keys({ ...ok, notes: 'x'.repeat(2001) }), ['notes:err_notes']);
  assert.deepEqual(keys({ ...ok, buyer_reference: 'x'.repeat(101) }), ['buyer_reference:err_reference']);
  for (const e of validateInvoiceHeader({ email: 'x', due_date: '2026-01-01', invoice_date: '2026-02-01', notes: 'x'.repeat(2001) })) assert.ok(HEADER_ORDER.includes(e.key));
});

test('palvelimen virhekoodi osoittaa kenttään (booking._invoice_customer_clean ja admin_save_invoice)', () => {
  assert.equal(serverErrorField('invalid_company_name'), 'company_name');
  assert.equal(serverErrorField('invalid_email'), 'email');
  assert.equal(serverErrorField('einvoice_incomplete'), 'einvoice_address');
  assert.equal(serverErrorField('invalid_due'), 'due_date');
  assert.equal(serverErrorField('invalid_lines'), 'lines');
  assert.equal(serverErrorField('invalid_vat'), 'lines');
  assert.equal(serverErrorField('forbidden'), null);
  assert.equal(serverErrorField(undefined), null);
  const sql = readFileSync(join(root, '../supabase/migrations/20261019090000_booking_112_invoice_customer_lookup.sql'), 'utf8');
  for (const code of ['invalid_company_name', 'invalid_business_id', 'invalid_email', 'einvoice_incomplete', 'invalid_einvoice_address', 'invalid_einvoice_operator', 'invalid_reference', 'invalid_customer', 'invalid_due', 'invalid_notes']) {
    assert.match(sql, new RegExp(`'${code}'`), code);
  }
});

test('Joonaksen rivit (3,984 / 5,00 ja 199,20 / 250,00, ALV 25,5) tallentuvat mockissa: 258,96 + 66,04 = 325,00 €', async () => {
  const m = createAdminMock({ role: 'admin' });
  const c = await m.rpc('admin_save_invoice_customer', { p_id: null, p: { company_name: 'Testi Oy' } });
  const lines = [
    { description: 'Pyyhe vuokralle', quantity: '15', unit: 'kpl', price_net: '3,984', price_gross: '5,00', basis: 'gross', vat_rate: '25.5' },
    { description: 'Oma savusauna', quantity: '1', unit: 'kpl', price_net: '199,20', price_gross: '250,00', basis: 'gross', vat_rate: '25.5' },
  ].map(lineToPayload);
  const inv = await m.rpc('admin_save_invoice', { p_id: null, p: { customer_id: c.id, snapshot_mode: 'registry', invoice_date: '2026-10-25', due_date: '2026-11-08', notes: null, lines } });
  assert.equal(inv.status, 'draft');
  assert.equal(inv.total_net, 258.96);
  assert.equal(inv.total_vat, 66.04);
  assert.equal(inv.total_gross, 325);
});

test('ilmoitus menee avoimen modaalin sisään (selaimen ylin taso), muuten bodyyn', async () => {
  const { toastHost } = await import('../admin/ui.js');
  const body = { tag: 'body' };
  const d1 = { matches: (s) => s === ':modal' }, d2 = { matches: (s) => s === ':modal' };
  const nonModal = { matches: () => false };
  const doc = (list) => ({ body, querySelectorAll: () => list });
  assert.equal(toastHost(doc([])), body);
  assert.equal(toastHost(doc([d1])), d1);
  assert.equal(toastHost(doc([d1, d2])), d2);
  assert.equal(toastHost(doc([nonModal])), body);
  const throws = { matches: () => { throw new Error(':modal ei tuettu'); } };
  assert.equal(toastHost(doc([throws])), throws);
  const ui = read('admin/ui.js');
  assert.match(ui, /toastHost\(document\)/);
});

test('lomake: ei hiljaista paluuta, tallennuksen tila, näkyvä virhe napin yläpuolella, onnistuminen sulkee modaalin', () => {
  const js = read('admin/views/invoices.js');
  assert.match(js, /validateInvoiceHeader\(/);
  assert.match(js, /validateAndPayload\(\{ focus: false \}\)/);
  assert.match(js, /data-testid': 'invoice-save-error'/);
  assert.match(js, /aria-busy/);
  assert.match(js, /ui\.admin\.invoices\.saving/);
  assert.match(js, /serverErrorField\(e\?\.code\)/);
  assert.match(js, /dlg\.close\(\);\s*toast\(tx\('ui\.admin\.invoices\.saved'\)\)/);
  assert.doesNotMatch(js, /toast\(tx\('ui\.admin\.invoices\.need_company'\)\)/);
  assert.doesNotMatch(js, /catch \(e\) \{ toast\(e\.message \|\| String\(e\)\); \}\n    \};\n  \}\n\}/);
  const form = read('admin/invoice-line-form.js');
  assert.match(form, /focusFirstError\(\)/);
  assert.match(form, /setServerError\(msg\)/);
  const css = read('admin/admin.css');
  assert.match(css, /\.inv-save-err\{/);
  assert.match(css, /\.spinner\{/);
  assert.match(css, /prefers-reduced-motion:reduce\)\{\.spinner/);
});

test('pending-import-65: uudet tekstit FI+EN, samat kuin koodin varatekstit, avaimet eivät ole muissa tuontitiedostoissa', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-65.json'), 'utf8'));
  const keySet = new Set(rows.map((r) => r.key));
  assert.equal(keySet.size, 13);
  for (const lang of ['fi', 'en']) assert.equal(rows.filter((r) => r.lang === lang).length, keySet.size);
  for (const r of rows) {
    assert.ok(r.key.startsWith('ui.admin.invoices.'), r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain'); assert.deepEqual(r.placeholders, []);
    assert.equal(INVOICE_TEXTS[r.lang][r.key], r.text, `${r.key} ${r.lang}`);
    assert.ok(r.text.length <= r.max_len);
  }
  const used = new Set([...validateInvoiceHeader({ email: 'x', business_id: '1', einvoice_address: '1', einvoice_operator: '1', buyer_reference: 'x'.repeat(101), invoice_date: 'x', due_date: 'y', notes: 'x'.repeat(2001) }).map((e) => e.code),
    'need_company', 'err_ovt_missing', 'err_operator_missing', 'err_due', 'saving', 'check_fields', 'save_failed']);
  for (const code of used) assert.ok(INVOICE_TEXTS.fi[`ui.admin.invoices.${code}`] && INVOICE_TEXTS.en[`ui.admin.invoices.${code}`], code);
  for (const f of readdirSync(join(repo, 'content'))) {
    if (!/^site-texts\.(pending-import(?!-65)|imported)/.test(f) || !f.endsWith('.json')) continue;
    for (const r of JSON.parse(readFileSync(join(repo, 'content', f), 'utf8'))) {
      if (r.key === 'ui.admin.invoices.need_company') continue;
      assert.equal(keySet.has(r.key), false, `${r.key} ${f}`);
    }
  }
});
