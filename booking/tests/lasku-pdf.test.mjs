import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  buildEpcQrPayload,
  buildVirtualBarcode,
  code128CChecksum,
  isValidFinnishReference,
  isValidIban,
  isValidRfReference,
} from '../supabase/functions/_shared/payment-codes.ts';
import { INVOICE_PDF_TEXTS } from '../supabase/functions/invoice-pdf/texts.ts';

const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');

test('Finanssialan version 4 testilasku 2 ja Code 128 -tarkiste', () => {
  const barcode = buildVirtualBarcode({
    iban: 'FI58 1017 1000 0001 22',
    amount: 482.99,
    reference: '55958 22432 94671',
    dueDate: '2012-01-31',
  });
  assert.deepEqual(barcode, {
    version: '4',
    value: '458101710000001220004829900000000559582243294671120131',
  });
  assert.equal(code128CChecksum(barcode.value), 55);
  assert.equal(isValidFinnishReference('55958 22432 94671'), true);
});

test('Finanssialan version 5 testilasku 1 ja Code 128 -tarkiste', () => {
  const barcode = buildVirtualBarcode({
    iban: 'FI79 4405 2020 0360 82',
    amount: 4883.15,
    reference: 'RF09 8685 1625 9619 897',
    dueDate: '2010-06-12',
  });
  assert.deepEqual(barcode, {
    version: '5',
    value: '579440520200360820048831509000000868516259619897100612',
  });
  assert.equal(code128CChecksum(barcode.value), 74);
  assert.equal(isValidRfReference('RF09 8685 1625 9619 897'), true);
});

test('maksukoodit jäävät pois virheellisillä tai puuttuvilla tiedoilla', () => {
  const base = { amount: 10, reference: '559582243294671', dueDate: '2026-11-08' };
  assert.equal(buildVirtualBarcode({ ...base, iban: '' }), null);
  assert.equal(buildVirtualBarcode({ ...base, iban: 'FI00 0000 0000 0000 00' }), null);
  assert.equal(buildVirtualBarcode({ ...base, iban: 'FI21 1234 5600 0007 85', reference: '1234' }), null);
  assert.equal(buildVirtualBarcode({ ...base, iban: 'FI21 1234 5600 0007 85', amount: -10 }), null);
  assert.equal(buildVirtualBarcode({ ...base, iban: 'FI21 1234 5600 0007 85', dueDate: '2026-02-30' }), null);
  assert.equal(isValidIban('FI21 1234 5600 0007 85'), true);
});

test('EPC SCT QR sisältää laskun maksutiedot eikä synny ilman IBANia tai BICiä', () => {
  const payload = buildEpcQrPayload({
    bic: 'TESTFIHH',
    beneficiary: 'Höyry & Löyly Oy',
    iban: 'FI21 1234 5600 0007 85',
    amount: 550,
    reference: '55958 22432 94671',
    fallbackRemittance: 'L000123',
  });
  assert.equal(payload, [
    'BCD', '002', '1', 'SCT', 'TESTFIHH', 'Höyry & Löyly Oy', 'FI2112345600000785',
    'EUR550.00', '', '', '559582243294671',
  ].join('\n'));
  assert.equal(buildEpcQrPayload({ bic: '', beneficiary: 'Havuhattu Oy', iban: 'FI21 1234 5600 0007 85', amount: 10 }), null);
  assert.equal(buildEpcQrPayload({ bic: 'TESTFIHH', beneficiary: 'Havuhattu Oy', iban: '', amount: 10 }), null);
});

test('lasku-PDF:n uudet tekstit ovat FI+EN-tuonnissa ilman HTML:ää', () => {
  const rows = JSON.parse(read('../../content/site-texts.pending-import-67.json'));
  const keys = new Set(rows.map((row) => row.key));
  assert.equal(rows.length, keys.size * 2);
  for (const key of [
    'email.invoice_pdf.payment_term',
    'email.invoice_pdf.payment_term_value',
    'email.invoice_pdf.einvoice',
    'email.invoice_pdf.payable',
    'email.invoice_pdf.payment_details',
    'email.invoice_pdf.quick_payment',
    'email.invoice_pdf.virtual_barcode',
    'email.invoice_pdf.scan_to_pay',
    'email.invoice_pdf.late_interest',
  ]) assert.ok(keys.has(key), key);
  for (const row of rows) {
    assert.ok(row.lang === 'fi' || row.lang === 'en');
    assert.equal(row.class, 'protected');
    assert.equal(row.kind, 'plain');
    assert.equal(row.text.includes('<'), false);
    assert.equal(INVOICE_PDF_TEXTS[row.key][row.lang], row.text);
  }
});

test('laskupohja käyttää brändipalettia ja piilottaa puuttuvat pankkitiedot', () => {
  const render = read('../supabase/functions/invoice-pdf/render.ts');
  const shared = read('../supabase/functions/_shared/pdf-layout.ts');
  assert.match(shared, /#2B3A30/);
  assert.match(shared, /#F4EFE7/);
  assert.match(shared, /#7A5530/);
  assert.match(render, /isValidIban\(seller\.iban\) && isValidBic\(seller\.bic\)/);
  assert.doesNotMatch(render, /seller\.(iban|bic|bank_name) \|\| ["']—/);
  assert.match(render, /qrcode\.stringToBytes = qrcode\.stringToBytesFuncs\["UTF-8"\]/);
  assert.match(render, /wrapPdfText\(inv\.notes, font, 8, 285\)/);
  assert.match(render, /if \(y < 62\) \{\s*addContinuationPage\(\)/s);
  assert.equal((render.match(/TX\("email\.invoice_pdf\.payable"\)/g) || []).length, 1);
  const paymentFields = render.slice(render.indexOf('const paymentFields'), render.indexOf('const hasAccount'));
  assert.doesNotMatch(paymentFields, /invoice_pdf\.(reference|due|payable)|total_gross/);
  assert.match(render, /wrapPdfText\(buyer\.company_name \|\| buyer\.name, bold, 11\.5, 245\)/);
  assert.match(render, /wrapPdfText\(value, font, 8\.2, PAGE_W - M - 325\)/);
  assert.match(render, /buildVirtualBarcode/);
  assert.match(render, /buildEpcQrPayload/);
});
