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
const MIG = 'supabase/migrations/20261025093156_booking_176_kumppanilahjakortti_viestit.sql';
const RB = 'supabase/rollbacks/20261025093156_booking_176_ROLLBACK.sql';
const PROD = { _on_payment_paid: 'de9084871640d213d10527a045157bf2', email_outbox_claim: '2db9a1233a06e6293d0877f17de1ab72', orders_confirmed_mail_trg: '85e59930421bf098d24d7fcebd50507d',
  public_submit_voucher_claim: 'de84e5ce9b1062111c4248e7c582fdb8', messages_dispatch: '11a25a5f1e02fe5e635a92d8fea3a69f', _vc_notify_problem: '85f500444e3af880009fc3b6c0e3a402',
  admin_mark_voucher_claim_redeemed: '525d1fa96fd7c37df4d7e502edf1bf71', svc_mark_voucher_claim_redeemed: 'ed28a9a7240b2ae62f5abef66885bc5d',
  admin_resolve_voucher_claim: 'b7d61783b74032374626c25ea60397b0', svc_resolve_voucher_claim: '96bf311a66fb5292f141bcc86621254f' };
const AFTER = { _on_payment_paid: 'af7f99e87ba7e00e0d5e3d5b6cbf2400', email_outbox_claim: '70602f6500703e8750e1539ae8809d38', orders_confirmed_mail_trg: 'de9df39ff7972a951e61684f8f2db87b',
  public_submit_voucher_claim: 'd28a31d27147f4cf7bceb12150c9e77c', messages_dispatch: '4b1f94601e23d9dc3eec34bcd5b4dc08', _vc_notify_problem: '3414022269f6db113f1085208eb6f040',
  admin_mark_voucher_claim_redeemed: 'a4e69cb26eb44b72eacce7c167342884', svc_mark_voucher_claim_redeemed: '673f26a88054b2b31dcbab872557e383',
  admin_resolve_voucher_claim: '41a4f3cc89e802f18e5131f849394188', svc_resolve_voucher_claim: 'cc67ebd8ce012211eb603b7f2b1c3ef4', _vc_partner_order: '9221478413d1e3869021d9e20c20e567', _vc_redeem: '6f52789346960d95370169446a61451b' };

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
  for (const dep of ['ae8b663945b78d1849b0028987689c8e', '350304b26e7240c42a6cf38f604eb689', '3c24fd721b0e8bc6f1bdfb8a800c5a0e', 'bea9cd9a32eb273ee72caed0aedd1e2e', '533ac9af831c0c11e1f504e377a17827', '4796edc6ebadaf599fd78287a75d29e8', 'a941437f2ef1a380f4213813f207b766', 'a48fe50340cff5f6e9709ad46055ecb9', 'fbd7286dba538f3c223ffd0d1eb1c4b4', '9e612ee37728ef0971d428765ab47e1a']) assert.ok(mig.includes(dep), dep);
  assert.match(mig, /create table if not exists booking\.vc_difference_payments/i);
  assert.match(mig, /alter table booking\.vc_difference_payments enable row level security/i);
  assert.match(mig, /revoke all on function booking\._vc_partner_order\(bigint\) from public, anon, authenticated;/);
  assert.match(mig, /revoke all on function booking\._vc_redeem\(bigint, ?numeric, ?text, ?text, ?text\) from public, anon, authenticated;/);
  assert.match(mig, /if not booking\._vc_partner_order\(new\.id\) then/);
  // Q3: erotuksen maksun seuranta tilauksen/pyynnön mukaan (korvaava linkki = uusi payments.id)
  assert.match(mig, /where d\.payment_id = p_payment_id\s+or \(d\.order_id = v_order\s+and d\.created_at <= \(select pp\.created_at from booking\.payments pp where pp\.id = p_payment_id\)/);
  assert.match(mig, /order_id bigint not null references booking\.orders\(id\) on delete cascade/);
  assert.match(mig, /payment_id bigint unique references booking\.payments\(id\) on delete set null/);
  // Q5: vanha polku (resolve 'redeemed') → _vc_redeem
  assert.match(mig, /CREATE OR REPLACE FUNCTION booking\.admin_resolve_voucher_claim[\s\S]*?if p_status = 'redeemed' and exists[\s\S]*?return booking\._vc_redeem\(p_id, p_amount, p_partner_ref, p_note, 'staff'\);/);
  assert.match(mig, /CREATE OR REPLACE FUNCTION booking\.svc_resolve_voucher_claim[\s\S]*?if p_status = 'redeemed' and exists[\s\S]*?return booking\._vc_redeem\(p_id, p_amount, p_partner_ref, p_note, 'bot'\);/);
  // Q6: peruttu/vanhentunut pyyntö → voimassa oleva pyyntö samalta tilaukselta
  assert.match(mig, /coalesce\(z\.item #>> '\{voucher_claim,status\}', 'cancelled'\) in \('cancelled', 'expired'\)\s+and vc\.status in \('open', 'processing', 'problem', 'redeemed'\)/);
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

test('tilaussivu: #ord-g vieritetään näkyviin renderöinnin jälkeen kerran (revealHashOnce), kielen vaihto säilyttää ankkurin', async () => {
  const { revealHashOnce } = await import('../shop/src/gift-ui.js');
  const calls = [];
  const mkEl = (id) => ({ id, attrs: {}, matches: () => false, setAttribute(k, v) { this.attrs[k] = v; }, focus(o) { calls.push(['focus', id, o?.preventScroll]); },
    closest: () => ({ scrollIntoView: (o) => calls.push(['scroll', 'section', o.block, o.behavior]) }) });
  const els = {};
  const doc = { getElementById: (id) => els[id] || null };
  const win = (hash, reduce = false) => ({ location: { hash }, matchMedia: () => ({ matches: reduce }) });
  // ennen renderöintiä: elementtiä ei ole → ei vieritystä, odotetaan
  const st = { done: false };
  assert.equal(revealHashOnce(doc, st, win('#ord-g')), false); assert.equal(st.done, false); assert.equal(calls.length, 0);
  // renderöinnin jälkeen: vieritys osion alkuun + fokus otsikkoon (ilman toista vieritystä), kerran
  els['ord-g'] = mkEl('ord-g');
  assert.equal(revealHashOnce(doc, st, win('#ord-g')), true); assert.equal(st.done, true);
  assert.deepEqual(calls, [['scroll', 'section', 'start', 'smooth'], ['focus', 'ord-g', true]]); assert.equal(els['ord-g'].attrs.tabindex, '-1');
  assert.equal(revealHashOnce(doc, st, win('#ord-g')), false, 'uusi renderöinti ei vieritä uudelleen'); assert.equal(calls.length, 2);
  // reduced motion → ei animaatiota
  calls.length = 0; assert.equal(revealHashOnce(doc, { done: false }, win('#ord-g', true)), true); assert.equal(calls[0][3], 'auto');
  // muu tai vaarallinen hash → ei mitään
  for (const h of ['', '#', '#top', '#ord-g,body', '#ord-"x"', '#' + 'ord-'.padEnd(60, 'a')]) { const s2 = { done: false }; calls.length = 0; assert.equal(revealHashOnce(doc, s2, win(h)), false, h); assert.equal(calls.length, 0, h); assert.equal(s2.done, true, h); }
  const ord = rd('shop/src/order.js');
  assert.match(ord, /import \{[^}]*revealHashOnce[^}]*\} from '\.\/gift-ui\.js'/);
  assert.ok(ord.includes("root.setAttribute('aria-busy', 'false'); revealHashOnce(document, hashState); if (root.querySelector('[data-testid=order-page]')) hashState.done = true; };"), 'mount → revealHashOnce');
  assert.ok(ord.includes("location.replace(`${S.orderHref[want]}${location.search}${/^#ord-[a-z0-9-]{1,40}$/i.test(location.hash) ? location.hash : ''}`)"), 'kielen vaihto säilyttää #ord-*');
  assert.match(ord, /h\('h3', \{ id: 'ord-g'/);
  assert.match(rd('supabase/functions/send-emails/templates.ts'), /\$\{c\.orderUrl\}#ord-g/);
  assert.match(rd('shop/src/shop.css'), /\.ord-card\[aria-labelledby=ord-g\]\{scroll-margin-top:\d+px\}/);
});
