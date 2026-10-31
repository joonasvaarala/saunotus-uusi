// booking_216: maksuvälittäjän provisioraportti. Ei verkkoa eikä tietokantaa.
// SQL: booking/supabase/tests/talous/t216_payment_provider_fees.sql (paikallinen PG, ei CI).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EURO_KEYS, CENT_KEYS, NEST_KEYS, extractProviderFee, lineFee, quoteFee, settledNet, feesToCsv, parseFeeAmount, FEE_CSV_HEADER } from '../admin/fee-report-logic.js';
import { FEE_TEXTS } from '../admin/fee-report-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const src = (p) => readFileSync(join(root, p), 'utf8');
const quoted = (file, name) => {
  const m = src(file).match(new RegExp(`export const ${name} = \\[([\\s\\S]*?)\\]`));
  assert.ok(m, name);
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
};

test('provisio poimitaan samassa järjestyksessä kuin SQL ja edge', () => {
  const sql = src('supabase/migrations/20261030111928_booking_216_payment_provider_fees.sql');
  assert.deepEqual(quoted('supabase/functions/_shared/provider_fee.ts', 'EURO_KEYS'), EURO_KEYS);
  assert.deepEqual(quoted('supabase/functions/_shared/provider_fee.ts', 'CENT_KEYS'), CENT_KEYS);
  assert.deepEqual(quoted('supabase/functions/_shared/provider_fee.ts', 'NEST_KEYS'), NEST_KEYS);
  for (const k of [...EURO_KEYS, ...CENT_KEYS, ...NEST_KEYS, 'amount_cents', 'amountCents']) assert.match(sql, new RegExp(k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.equal(extractProviderFee({ merchantFee: 1.25, grandTotal: 100 }), 1.25);
  assert.equal(extractProviderFee({ feeCents: 150, amount: 40 }), 1.5);
  assert.equal(extractProviderFee({ fees: { amount: '0.35' } }), 0.35);
  assert.equal(extractProviderFee({ settlement: { feeAmount: 0.9 } }), 0.9);
  assert.equal(extractProviderFee({ commission: 0 }), 0);
  assert.equal(extractProviderFee({ amount: 40, grandTotal: 40 }), null);
  assert.equal(extractProviderFee({ fee: '1,10' }), 1.1);
  assert.equal(extractProviderFee(null), null);
});

test('toteutunut voittaa säännön, tarkempi tapa voittaa tähden, hyvitys erikseen', () => {
  const rules = [
    { id: 1, provider: 'montonio', method: '*', fixed_eur: 0, percent: 2, active: true },
    { id: 2, provider: 'montonio', method: 'montonio', fixed_eur: 0.25, percent: 1, active: true },
    { id: 3, provider: 'visma_pay', method: 'visma_pay', fixed_eur: 0.5, percent: 1, active: true },
  ];
  assert.deepEqual(lineFee({ provider: 'montonio', method: 'montonio', gross: 100, provider_fee: 1.25, raw: {} }, rules), { basis: 'actual', fee: 1.25 });
  assert.deepEqual(lineFee({ provider: 'montonio', method: 'montonio', gross: 10, provider_fee: null, raw: {} }, rules), { basis: 'estimated', fee: quoteFee(10, rules[1]) });
  assert.equal(quoteFee(10, rules[1]), 0.35);
  assert.equal(quoteFee(40, rules[2]), 0.9);
  assert.deepEqual(lineFee({ provider: 'manual', method: 'card_terminal', gross: 20, raw: {} }, rules), { basis: 'missing', fee: null });
  assert.equal(settledNet('sale', 108, 1.33), 106.67);
  assert.equal(settledNet('refund', 20, 0.2), -20.2);
  assert.equal(settledNet('sale', 20, null), null);
  assert.equal(parseFeeAmount('0,25', 1000), 0.25);
  assert.equal(parseFeeAmount('-1', 1000), null);
  assert.equal(parseFeeAmount('101', 100), null);
});

test('CSV on puolipiste, suomalainen desimaali ja BOM', () => {
  const csv = feesToCsv({ rows: [
    { provider_label: 'Montonio', method_label: 'Maksa verkossa', direction: 'sale', basis: 'actual', count: 2, gross: 108, fee: 1.33, net: 106.67 },
    { provider_label: 'Visma Pay', method_label: 'Visma Pay', direction: 'refund', basis: 'estimated', count: 1, gross: 20, fee: 0.2, net: -20.2 },
    { provider_label: 'Käsin', method_label: 'Korttipääte', direction: 'sale', basis: 'missing', count: 1, gross: 20, fee: null, net: null },
  ] });
  assert.equal(csv.charCodeAt(0), 0xFEFF);
  assert.ok(csv.includes(FEE_CSV_HEADER));
  assert.match(csv, /Montonio;Maksa verkossa;maksu;toteutunut;2;108,00;1,33;106,67/);
  assert.match(csv, /hyvitys;arvio;1;20,00;0,20;-20,20/);
  assert.match(csv, /puuttuu;1;20,00;;/);
  assert.equal(csv.includes('\n') && !csv.includes('\r'), false);
});

test('pending-import-103 vastaa sanakirjaa, FI+EN, ei Montonio-nimeä eikä päällekkäisyyttä', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-103.json'), 'utf8'));
  const taken = new Set();
  for (const f of readdirSync(join(repo, 'content'))) {
    if (!/^site-texts\.pending-import-(?!103\.)/.test(f) || !f.endsWith('.json')) continue;
    const j = JSON.parse(readFileSync(join(repo, 'content', f), 'utf8'));
    for (const r of Array.isArray(j) ? j : (j.texts || [])) taken.add(`${r.key}|${r.lang}`);
  }
  const seen = new Set();
  assert.equal(rows.length, Object.keys(FEE_TEXTS.fi).length * 2);
  for (const r of rows) {
    assert.equal(seen.has(`${r.key}|${r.lang}`), false, r.key);
    seen.add(`${r.key}|${r.lang}`);
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, r.key);
    assert.equal(FEE_TEXTS[r.lang][r.key], r.text);
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.deepEqual(r.placeholders, []);
    assert.ok(r.max_len >= r.text.length);
    assert.equal(/montonio|https?:|<|>/i.test(r.text), false, r.key);
    assert.equal(r.text.trim(), r.text);
  }
  for (const lang of ['fi', 'en']) {
    for (const key of Object.keys(FEE_TEXTS.fi)) assert.equal(typeof FEE_TEXTS[lang][key], 'string', `${key} ${lang}`);
  }
  const pdf = src('supabase/functions/report-pdf/texts.ts');
  for (const key of ['ui.admin.reports.fee_title', 'ui.admin.reports.fee_sales', 'ui.admin.reports.fee_refunds', 'ui.admin.reports.fee_basis_actual', 'ui.admin.reports.fee_basis_estimated', 'ui.admin.reports.fee_missing_note', 'ui.admin.reports.fee_net_note']) {
    assert.match(pdf, new RegExp(key.replace(/\./g, '\\.')));
    assert.match(pdf, new RegExp(FEE_TEXTS.fi[key].replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});

test('migraatio booking_216, rollback, SQL-testi ja hallinnan kytkentä', () => {
  const mig = src('supabase/migrations/20261030111928_booking_216_payment_provider_fees.sql');
  const rb = src('supabase/rollbacks/20261030111928_booking_216_ROLLBACK.sql');
  assert.match(mig, /admin_report_provider_fees/);
  assert.match(mig, /payment_fee_rules/);
  assert.match(mig, /provider_fee/);
  assert.match(mig, /reports\.view/);
  assert.match(mig, /settings\.edit/);
  assert.match(mig, /Europe\/Helsinki/);
  assert.match(mig, /chr\(65279\)/);
  assert.equal(/\bcommit\s*;/i.test(mig), false);
  assert.doesNotMatch(mig, /create or replace function booking\.public_/);
  assert.match(rb, /drop function if exists booking\.admin_report_provider_fees/);
  assert.match(rb, /drop column if exists provider_fee/);
  assert.match(src('supabase/tests/talous/t216_payment_provider_fees.sql'), /TESTRESULT/);
  assert.match(src('supabase/migrations/20261031120000_booking_222_report_structure.sql'), /p\.method is distinct from 'gift_card'/);
  assert.match(src('admin/talous-mock.js'), /method !== 'gift_card'|gift_card/);
  assert.match(src('admin/views/talous-reports.js'), /reportProviderFees/);
  assert.match(src('admin/views/talous-reports.js'), /data-testid': 'r-fees'/);
  assert.match(src('admin/views/settings.js'), /feeRulesCard/);
  assert.match(src('supabase/functions/report-pdf/index.ts'), /kind === "fees"/);
  assert.match(src('supabase/functions/_shared/montonio_flow.ts'), /feeSlice/);
  assert.match(src('supabase/functions/_shared/vismapay_flow.ts'), /feeSlice/);
  assert.match(src('supabase/functions/_shared/mobilepay_flow.ts'), /feeSlice\(vp\)/);
  assert.equal(src('supabase/functions/_shared/mobilepay_flow.ts').includes('p_raw: null'), false);
  const shop = readdirSync(join(root, 'shop/src')).filter((f) => f.endsWith('.js'));
  for (const f of shop) assert.equal(src(`shop/src/${f}`).includes('fee-report-logic'), false, f);
  assert.match(readFileSync(join(repo, '.github/workflows/pages.yml'), 'utf8'), /booking\/tests\/provisio-raportti\.test\.mjs/);
  assert.match(readFileSync(join(repo, '.github/workflows/pages.yml'), 'utf8'), /t216_payment_provider_fees\.sql/);
});
