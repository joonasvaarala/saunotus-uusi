// booking_236: usea kumppanilahjakortti samaan tilaukseen, yksi erotuksen maksulinkki.
// Ei verkkoa eikä tietokantaa. SQL: booking/supabase/tests/giftcards/t236_voucher_claims_multi.sql
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const rd = (p) => readFileSync(join(root, p), 'utf8');
const MIG = 'supabase/migrations/20261102120000_booking_236_voucher_claims_multi.sql';
const RB = 'supabase/rollbacks/20261102120000_booking_236_ROLLBACK.sql';
const SQL = 'supabase/tests/giftcards/t236_voucher_claims_multi.sql';
const FI = 'Lahjakortti on voimassa suoraan palveluun yhden vuoden ajan, jonka jälkeen se muuttuu arvolahjakortiksi. Lahjakorttisi arvo on {{var:voucher}}, joten maksettavaa jää vielä {{var:difference}}. Voit maksaa sen alla olevasta linkistä.';
const EN = 'The gift card is valid directly for the service for one year, after which it turns into a value gift card. Your gift card is worth {{var:voucher}}, so {{var:difference}} remains to be paid. You can pay it using the link below.';

test('booking_236: yksi migraatio ja rollback, yhden kortin funktiota ei kirjoiteta uudelleen', () => {
  const migs = readdirSync(join(root, 'supabase/migrations')).filter((f) => /booking_236/.test(f));
  const rbs = readdirSync(join(root, 'supabase/rollbacks')).filter((f) => /booking_236/.test(f));
  assert.deepEqual(migs, ['20261102120000_booking_236_voucher_claims_multi.sql']);
  assert.deepEqual(rbs, ['20261102120000_booking_236_ROLLBACK.sql']);
  const mig = rd(MIG);
  const rb = rd(RB);
  assert.match(mig, /create or replace function booking\.svc_mark_voucher_claims_redeemed\(\s*p_claim_ids bigint\[\]/);
  assert.match(mig, /p_amounts numeric\[\] default null/);
  assert.match(mig, /p_amount numeric,/);
  assert.match(mig, /p_value_card boolean default false/);
  assert.match(mig, /booking\._vc_mark_redeemed\(rec\.id, rec\.amt, p_partner_ref, p_note, p_by\)/);
  assert.match(mig, /order by id\s+for update/);
  assert.match(mig, /booking\._order_invoice_locked\(o\.id\)/);
  assert.match(mig, /'order_invoiced'/);
  assert.match(mig, /booking\._create_link_payment\(o\.id, null::integer/);
  assert.match(mig, /'value_card', v_card/);
  assert.match(mig, /status in \('open', 'processing'\)/);
  assert.match(mig, /duplicate_claim/);
  assert.match(mig, /different_orders/);
  assert.match(mig, /security definer/);
  assert.match(mig, /set search_path to ''/);
  assert.match(mig, /revoke all on function booking\.svc_mark_voucher_claims_redeemed\(bigint\[\], numeric\[\], text, text, boolean\) from public, anon, authenticated/);
  assert.match(mig, /grant execute on function booking\.svc_mark_voucher_claims_redeemed\(bigint\[\], numeric\[\], text, text, boolean\) to service_role/);
  assert.match(mig, /revoke all on function booking\.svc_mark_voucher_claims_redeemed\(bigint\[\], numeric, text, text, boolean\) from public, anon, authenticated/);
  assert.match(mig, /grant execute on function booking\.svc_mark_voucher_claims_redeemed\(bigint\[\], numeric, text, text, boolean\) to service_role/);
  assert.match(mig, /revoke all on function booking\._vc_redeem_many\(bigint\[\], numeric\[\], text, text, text, boolean\) from public, anon, authenticated, service_role/);
  assert.doesNotMatch(mig, /create or replace function booking\.svc_mark_voucher_claim_redeemed\(/);
  assert.doesNotMatch(mig, /create or replace function booking\._vc_redeem\(/);
  assert.doesNotMatch(mig, /create or replace function booking\._vc_mark_redeemed\(/);
  assert.doesNotMatch(mig, /^\s*\\/m);
  assert.match(rb, /drop function if exists booking\.svc_mark_voucher_claims_redeemed\(bigint\[\], numeric, text, text, boolean\)/);
  assert.match(rb, /drop function if exists booking\.svc_mark_voucher_claims_redeemed\(bigint\[\], numeric\[\], text, text, boolean\)/);
  assert.match(rb, /drop function if exists booking\._vc_redeem_many\(bigint\[\], numeric\[\], text, text, text, boolean\)/);
  assert.doesNotMatch(rb, /create or replace function/i);
});

test('SQL-testi kattaa yhden 8 € linkin, täyden katteen, eri tilaukset, uusinnan, laskun ja arvolahjakortin', () => {
  const t = rd(SQL);
  assert.doesNotMatch(t, /^\s*\\/m);
  assert.match(t, /^begin;/m);
  assert.match(t, /^rollback;/m);
  assert.match(t, /returning id into/);
  assert.match(t, /svc_mark_voucher_claims_redeemed\(array\[c2, c1\], 25, 'T236-B', null, true\)/);
  assert.match(t, /p_amounts := array\[30, 20\]/);
  assert.match(t, /p_value_card := false/);
  assert.match(t, /difference/);
  assert.match(t, /order_invoiced/);
  assert.match(t, /different_orders/);
  assert.match(t, /duplicate_claim/);
  assert.match(t, /invalid_state/);
  assert.match(t, /voucher_exceeds_total/);
  assert.match(t, /value_card/);
  assert.match(t, /admin_record_payment/);
  assert.match(t, /svc_mark_voucher_claim_redeemed\(c4, 50/);
});

test('p_value_card true käyttää olemassa olevaa FI+EN-arvolahjakorttitekstiä, uutta tekstiä ei tarvita', () => {
  const texts = rd('supabase/functions/send-emails/texts.ts');
  const tpl = rd('supabase/functions/send-emails/templates.ts');
  assert.match(texts, new RegExp(FI.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(texts, new RegExp(EN.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.equal(FI.includes('<'), false);
  assert.equal(EN.includes('<'), false);
  assert.match(tpl, /value_card === true \? "email\.payment_link\.voucher_intro_value_card" : "email\.payment_link\.voucher_intro"/);
  const rows = JSON.parse(rd('../content/site-texts.pending-import-117.json'));
  assert.equal(rows.find((r) => r.key === 'email.payment_link.voucher_intro_value_card' && r.lang === 'fi').text, FI);
  assert.equal(rows.find((r) => r.key === 'email.payment_link.voucher_intro_value_card' && r.lang === 'en').text, EN);
  const mig = rd(MIG);
  assert.match(mig, /'value_card', v_card/);
  assert.doesNotMatch(mig, /voucher_intro_value_card/);
});
