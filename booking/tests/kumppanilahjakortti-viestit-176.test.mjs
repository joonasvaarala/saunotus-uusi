// booking_176: kumppanilahjakorttivarauksen asiakasviestit yhteen (hyväksytty malli, Joonas 25.10.2026).
// Tekstit (pending-import-71) = send-emails/texts.ts, pakollinen lause, migraatio + rollback rakenteena, SQL-testin säännöt.
// Ei verkkoa eikä tietokantaa. SQL-puoli: supabase/tests/giftcards/t176_kumppanilahjakortti_viestit.sql. Sähköpostipohjat: send-emails/templates.test.mjs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const rd = (p) => readFileSync(join(here, '..', p), 'utf8');
const MIG = 'supabase/migrations/20261025100000_booking_176_kumppanilahjakortti_viestit.sql';
const RB = 'supabase/rollbacks/20261025100000_booking_176_ROLLBACK.sql';
const PROD = { _on_payment_paid: 'de9084871640d213d10527a045157bf2', email_outbox_claim: '2db9a1233a06e6293d0877f17de1ab72', orders_confirmed_mail_trg: '85e59930421bf098d24d7fcebd50507d',
  public_submit_voucher_claim: 'de84e5ce9b1062111c4248e7c582fdb8', messages_dispatch: '11a25a5f1e02fe5e635a92d8fea3a69f', _vc_notify_problem: '85f500444e3af880009fc3b6c0e3a402',
  admin_mark_voucher_claim_redeemed: '525d1fa96fd7c37df4d7e502edf1bf71', svc_mark_voucher_claim_redeemed: 'ed28a9a7240b2ae62f5abef66885bc5d' };
const AFTER = { _on_payment_paid: '6abd248cb10998be8c97f3373dcb3504', email_outbox_claim: 'd355fb47a5c19f90bdcb28615fa54b95', orders_confirmed_mail_trg: 'de9df39ff7972a951e61684f8f2db87b',
  public_submit_voucher_claim: 'd28a31d27147f4cf7bceb12150c9e77c', messages_dispatch: '4b1f94601e23d9dc3eec34bcd5b4dc08', _vc_notify_problem: '3414022269f6db113f1085208eb6f040',
  admin_mark_voucher_claim_redeemed: 'a4e69cb26eb44b72eacce7c167342884', svc_mark_voucher_claim_redeemed: '673f26a88054b2b31dcbab872557e383', _vc_partner_order: '9221478413d1e3869021d9e20c20e567', _vc_redeem: 'f420202b18a6d05d1f3a5a0d809fd644' };

test('tekstit: pending-import-71 = send-emails/texts.ts, FI+EN, ei <, ei emojeja, ei linkkejä, avaimet uusia; pakollinen lause; puhelinmuuttuja', async () => {
  const { EMAIL_TEXTS } = await import('../supabase/functions/send-emails/texts.ts').catch(() => ({ EMAIL_TEXTS: null }));
  const rows = JSON.parse(rd('../content/site-texts.pending-import-71.json'));
  assert.equal(new Set(rows.map((r) => `${r.key}|${r.lang}`)).size, rows.length);
  const keys = [...new Set(rows.map((r) => r.key))];
  assert.equal(rows.length, keys.length * 2);
  for (const k of keys) for (const l of ['fi', 'en']) {
    const r = rows.find((x) => x.key === k && x.lang === l); assert.ok(r, `${k} ${l}`);
    assert.match(k, /^email\.voucher\.(confirm|difference)_[a-z_]+$/);
    if (EMAIL_TEXTS) assert.equal(r.text, EMAIL_TEXTS[k]?.[l], `${k} ${l}`);
    assert.deepEqual([...r.placeholders].sort(), [...new Set(r.text.match(/\{\{[^{}]+\}\}/g) || [])].sort(), k);
    assert.ok(!r.text.includes('<'), k); assert.doesNotMatch(r.text, /\p{Extended_Pictographic}|https?:\/\//u); assert.ok(r.max_len >= r.text.length);
    assert.equal(r.kind, 'plain'); assert.match(r.reason, /^booking_176/);
  }
  assert.equal(rows.find((r) => r.key === 'email.voucher.confirm_problem' && r.lang === 'fi').text, 'Olemme sinuun yhteydessä, jos lahjakortin tai varauksen kanssa ilmenee ongelmia.');
  assert.match(rows.find((r) => r.key === 'email.voucher.confirm_problem' && r.lang === 'en').text, /^We will contact you if .*problems.*gift card.*booking\.$/);
  const others = readdirSync(join(here, '../../content')).filter((f) => /^site-texts\.(pending-import|imported).*\.json$/.test(f) && f !== 'site-texts.pending-import-71.json');
  for (const f of others) { const rs = JSON.parse(rd(`../content/${f}`)); if (!Array.isArray(rs)) continue; for (const r of rs) assert.ok(!keys.includes(r?.key), `${r?.key} on jo tiedostossa ${f}`); }
  if (EMAIL_TEXTS) {
    for (const k of ['email.voucher.received_subject', 'email.voucher.received_title', 'email.voucher.received_p1', 'email.voucher.received_p2', 'email.voucher.more_received']) assert.ok(!EMAIL_TEXTS[k], `${k} poistettu`);
    assert.match(EMAIL_TEXTS['email.common.contact'].fi, /\{\{var:phone\}\}/);
  }
});

test('migraatio: vartijat (tuotanto tai booking_176), riippuvuudet, uudet funktiot sisäisiä, ei public-skeemaa eikä psql-metakomentoja', () => {
  const mig = rd(MIG);
  for (const [f, md] of Object.entries(PROD)) { assert.ok(mig.includes(md), `PROD ${f}`); assert.ok(mig.includes(AFTER[f]), `AFTER ${f}`); }
  for (const f of ['_vc_partner_order', '_vc_redeem']) assert.ok(mig.includes(AFTER[f]), f);
  for (const dep of ['ae8b663945b78d1849b0028987689c8e', '350304b26e7240c42a6cf38f604eb689', '3c24fd721b0e8bc6f1bdfb8a800c5a0e', 'bea9cd9a32eb273ee72caed0aedd1e2e', '533ac9af831c0c11e1f504e377a17827', '4796edc6ebadaf599fd78287a75d29e8', 'a941437f2ef1a380f4213813f207b766', 'a48fe50340cff5f6e9709ad46055ecb9']) assert.ok(mig.includes(dep), dep);
  assert.match(mig, /create table if not exists booking\.vc_difference_payments/i);
  assert.match(mig, /alter table booking\.vc_difference_payments enable row level security/i);
  assert.match(mig, /revoke all on function booking\._vc_partner_order\(bigint\) from public, anon, authenticated;/);
  assert.match(mig, /revoke all on function booking\._vc_redeem\(bigint, ?numeric, ?text, ?text, ?text\) from public, anon, authenticated;/);
  assert.match(mig, /if not booking\._vc_partner_order\(new\.id\) then/);
  assert.match(mig, /vc_difference_payments d where d\.payment_id = p_payment_id\) then return; end if;/);
  assert.doesNotMatch(mig, /\bpublic\.[a-z_]+\s*\(|^\s*\\/m);
  assert.doesNotMatch(mig, /^\s*(drop|truncate)\s/im);
});

test('rollback: palauttaa tuotannon md5:t, poistaa uudet funktiot ja taulun; SQL-testi noudattaa sääntöjä', () => {
  const rb = rd(RB);
  for (const [f, md] of Object.entries(PROD)) assert.ok(rb.includes(md), `PROD ${f}`);
  assert.match(rb, /drop function if exists booking\._vc_partner_order\(bigint\);/);
  assert.match(rb, /drop function if exists booking\._vc_redeem\(bigint,numeric,text,text,text\);/);
  assert.match(rb, /drop table if exists booking\.vc_difference_payments;/);
  const t = rd('supabase/tests/giftcards/t176_kumppanilahjakortti_viestit.sql');
  assert.doesNotMatch(t, /^\s*\\/m, 'ei psql-metakomentoja'); assert.match(t, /^begin;/m); assert.match(t, /^rollback;/m); assert.match(t, /returning id into/);
  assert.match(t, /TESTRESULT pass=% fail=% skip=%/); assert.match(t, /'42501'/); assert.match(t, /'BK001'/);
  assert.doesNotMatch(t, /\bwhere id = \d+|\(\s*\d{2,}\s*,\s*'(staff|bot)'/, 'ei kiinteitä id-arvoja');
});
