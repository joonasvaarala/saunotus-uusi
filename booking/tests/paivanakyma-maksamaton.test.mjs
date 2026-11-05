// Päivänäkymä: maksamattoman varauksen vaaleanpunainen korostus (booking_243).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const { isDayUnpaidHighlight } = await import(pathToFileURL(join(root, 'admin/day-logic.js')));

test('isDayUnpaidHighlight: unpaid/pending/failed/partially_paid aktiivisilla', () => {
  for (const ps of ['unpaid', 'pending', 'failed', 'partially_paid']) {
    assert.equal(isDayUnpaidHighlight({ status: 'confirmed', payment_status: ps }), true, ps);
  }
  for (const ps of ['paid', 'invoiced', 'refunded', 'partially_refunded']) {
    assert.equal(isDayUnpaidHighlight({ status: 'confirmed', payment_status: ps }), false, ps);
  }
  assert.equal(isDayUnpaidHighlight({ status: 'cancelled', payment_status: 'unpaid' }), false);
  assert.equal(isDayUnpaidHighlight({ status: 'confirmed', payment_status: 'unpaid' }), true);
  assert.equal(isDayUnpaidHighlight(null), false);
});

test('Päivänäkymä: unpaid-pay-tyyli vain day-viewissä, pale pink var(--unpaidbg)=#F6E0E3, ei sinistä', () => {
  const css = readFileSync(join(root, 'admin/admin.css'), 'utf8');
  assert.match(css, /--unpaidbg:\s*#F6E0E3/); assert.match(css, /\.day-view\s+\.resrow\.unpaid-pay\s*\{[^}]*background:\s*var\(--unpaidbg\)/);
  assert.ok(!/1d6fd8/i.test(css));
  const js = readFileSync(join(root, 'admin/views/day.js'), 'utf8');
  assert.match(js, /isDayUnpaidHighlight/);
  assert.match(js, /unpaid-pay/);
});

test('kumppanilunastus: hyväksymätön (unpaid/pending) pinkki, hyväksytty (paid) ei; maksulinkki ennallaan', () => {
  // Prod: open claim → order.payment_status unpaid kunnes admin_mark_voucher_claim_redeemed;
  // hyväksynnän jälkeen partner_voucher_* / paid ja payment_status paid. Päivänäkymällä ei claim-kenttää.
  for (const ps of ['unpaid', 'pending']) {
    assert.equal(isDayUnpaidHighlight({ status: 'confirmed', payment_status: ps }), true, 'hyväksymätön ' + ps);
  }
  assert.equal(isDayUnpaidHighlight({ status: 'confirmed', payment_status: 'paid' }), false, 'hyväksytty paid');
  // Osittain maksettu (kumppani lunastettu + loppuosuus auki) pysyy pinkkinä maksamattoman loppuosan takia.
  assert.equal(isDayUnpaidHighlight({ status: 'confirmed', payment_status: 'partially_paid' }), true);
  // Maksulinkki ilman eräpäivää: pending/unpaid → pinkki (booking_243).
  assert.equal(isDayUnpaidHighlight({ status: 'confirmed', payment_status: 'pending' }), true);
  assert.equal(isDayUnpaidHighlight({ status: 'pending', payment_status: 'unpaid' }), true);
});
