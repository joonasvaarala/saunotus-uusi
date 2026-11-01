// Lahjakortit-valikko: haku ensin, pikajatko käyttää admin_set_gift_card_expiryä, lunastuspyynnöt käyttävät nykyistä resolve-polkua.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { giftExtendDate } from '../admin/giftcards-delivery.js';
import { legacyFinanceGiftTarget } from '../admin/admin-navigation.js';
import { NAV_TEXTS } from '../admin/nav-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');

test('pikajatko: tuleva päivä jatkuu siitä, mennyt tai tyhjä tästä päivästä, vain 1/3/6 kk', () => {
  assert.equal(giftExtendDate('2026-12-01', 1, '2026-11-01'), '2027-01-01');
  assert.equal(giftExtendDate('2026-12-01', 3, '2026-11-01'), '2027-03-01');
  assert.equal(giftExtendDate('2026-12-01', 6, '2026-11-01'), '2027-06-01');
  assert.equal(giftExtendDate('2026-01-31', 1, '2026-01-01'), '2026-02-28');
  assert.equal(giftExtendDate('2024-01-31', 1, '2024-01-01'), '2024-02-29');
  assert.equal(giftExtendDate('2020-01-01', 1, '2026-11-01'), '2026-12-01');
  assert.equal(giftExtendDate(null, 6, '2026-11-01'), '2027-05-01');
  assert.equal(giftExtendDate('2026-12-01', 2, '2026-11-01'), null);
  assert.equal(giftExtendDate('2026-12-01', 1, ''), null);
});

test('vanha Talous-osoite ohjautuu Lahjakortit-valikkoon ja säilyttää haun', () => {
  assert.equal(legacyFinanceGiftTarget('talous', new URLSearchParams('tab=giftcards&code=HHAA&lang=en')), '#/lahjakortit?tab=omat&code=HHAA&lang=en');
  assert.equal(legacyFinanceGiftTarget('talous', new URLSearchParams('tab=vouchers&lang=fi')), '#/lahjakortit?tab=lunastukset&lang=fi');
  assert.equal(legacyFinanceGiftTarget('kassa', new URLSearchParams('tab=giftcards')), null);
  assert.equal(NAV_TEXTS.en['ui.admin.nav.giftcards_claims'], 'Redemption requests');
});

test('omat kortit: haku ensin, pikajatko kutsuu setExpiryä, ei uutta kirjoitus-RPC:tä', () => {
  const view = src('admin/views/talous-giftcards.js');
  const page = src('admin/views/lahjakortit.js');
  assert.match(view, /searchFirst/);
  assert.match(view, /if \(!listed\(\)\)/);
  assert.match(view, /gift\.setExpiry\(\{ id: c\.id, validTo: date, note: t\('gc\.a\.extNote'/);
  assert.match(view, /gc-btn-ext-\$\{n\}/);
  assert.match(view, /gc-btn-expiry/);
  assert.match(page, /searchFirst: true/);
  assert.match(page, /any|giftcards/);
  assert.match(src('admin/admin.js'), /any: \['giftcards\.manage'\]/);
  assert.doesNotMatch(view, /admin_extend_gift_card|p_months/);
});

test('lunastuspyynnöt: avoimet ensin, suodattimet ja nykyinen resolve', () => {
  const view = src('admin/views/talous-vouchers.js');
  assert.match(view, /status: 'active'/);
  assert.match(view, /vcl-chip-\$\{k\}/);
  assert.match(view, /\['active', 'open'\], \['redeemed', 'redeemed'\], \['cancelled', 'rejected'\]/);
  assert.match(view, /vcl-booking/);
  assert.match(view, /vcl-created/);
  assert.match(view, /vcl-chosen-booking/);
  assert.match(view, /admin_resolve_voucher_claim/);
  assert.match(view, /_vc_redeem\(5\)/);
  assert.doesNotMatch(view, /p_value_card/);
  const mig = src('supabase/migrations/20261101220000_booking_231_voucher_claim_list_booking.sql');
  const rb = src('supabase/rollbacks/20261101220000_booking_231_ROLLBACK.sql');
  assert.match(mig, /_vc_json\(c, false\)/);
  assert.match(mig, /booking_product/);
  assert.match(mig, /revoke all on function booking\.admin_list_voucher_claims\(text, text, integer, integer, text\) from public, anon/);
  assert.match(rb, /jsonb_agg\(booking\._vc_json\(c, false\)/);
  assert.doesNotMatch(rb, /booking_product/);
  assert.match(src('supabase/tests/giftcards/t231_voucher_claim_list_booking.sql'), /TESTRESULT pass=% fail=%/);
});
