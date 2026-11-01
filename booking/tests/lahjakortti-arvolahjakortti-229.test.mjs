// booking_229: erotuksen maksulinkkiin toinen intro, kun botti merkitsee yli vuoden vanhan kumppanikortin arvolahjakortiksi.
// Yleinen voucher_intro jää lisäpalvelun ja hinnan erotukselle. Ei verkkoa eikä tietokantaa.
// SQL: supabase/tests/giftcards/t229_voucher_value_card.sql
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const rd = (p) => readFileSync(join(here, '..', p), 'utf8');
const MIG = 'supabase/migrations/20261101200000_booking_229_voucher_value_card_variant.sql';
const RB = 'supabase/rollbacks/20261101200000_booking_229_ROLLBACK.sql';
const FI = 'Lahjakortti on voimassa suoraan palveluun yhden vuoden ajan, jonka jälkeen se muuttuu arvolahjakortiksi. Lahjakorttisi arvo on {{var:voucher}}, joten maksettavaa jää vielä {{var:difference}}. Voit maksaa sen alla olevasta linkistä.';
const EN = 'The gift card is valid directly for the service for one year, after which it turns into a value gift card. Your gift card is worth {{var:voucher}}, so {{var:difference}} remains to be paid. You can pay it using the link below.';
const GENERIC_FI = 'Lahjakorttisi arvo on {{var:voucher}}, joten maksettavaa jää vielä {{var:difference}}. Voit maksaa sen alla olevasta linkistä.';
const GENERIC_EN = 'Your gift card is worth {{var:voucher}}, so {{var:difference}} remains to be paid. You can pay it using the link below.';

test('tekstit: pending-import-117 on uusi avain FI+EN, paikkamerkit täsmälleen voucher ja difference; yleinen intro on v2', async () => {
  const { EMAIL_TEXTS } = await import('../supabase/functions/send-emails/texts.ts');
  const rows = JSON.parse(rd('../content/site-texts.pending-import-117.json'));
  assert.equal(rows.length, 2);
  assert.equal(new Set(rows.map((r) => `${r.key}|${r.lang}`)).size, 2);
  for (const l of ['fi', 'en']) {
    const r = rows.find((x) => x.lang === l);
    assert.equal(r.key, 'email.payment_link.voucher_intro_value_card');
    assert.equal(r.text, l === 'fi' ? FI : EN);
    assert.equal(r.text, EMAIL_TEXTS[r.key][l]);
    assert.deepEqual(r.placeholders, ['{{var:voucher}}', '{{var:difference}}']);
    assert.deepEqual([...r.placeholders].sort(), [...new Set(r.text.match(/\{\{[^{}]+\}\}/g) || [])].sort());
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.ok(r.max_len >= r.text.length);
    assert.ok(!r.text.includes('<'));
    assert.doesNotMatch(r.text, /\p{Extended_Pictographic}|https?:\/\//u);
    assert.ok(!r.text.includes('{{var:total}}'));
  }
  assert.equal(EMAIL_TEXTS['email.payment_link.voucher_intro'].fi, GENERIC_FI);
  assert.equal(EMAIL_TEXTS['email.payment_link.voucher_intro'].en, GENERIC_EN);
  const old = JSON.parse(rd('../content/site-texts.pending-import-69.json'));
  assert.equal(old.find((r) => r.key === 'email.payment_link.voucher_intro' && r.lang === 'fi').text, GENERIC_FI);
  assert.equal(old.find((r) => r.key === 'email.payment_link.voucher_intro' && r.lang === 'en').text, GENERIC_EN);
  const others = readdirSync(join(here, '../../content')).filter((f) => /^site-texts\.(pending-import|imported).*\.json$/.test(f) && f !== 'site-texts.pending-import-117.json');
  for (const f of others) {
    const rs = JSON.parse(rd(`../content/${f}`));
    if (!Array.isArray(rs)) continue;
    for (const r of rs) assert.notEqual(r?.key, 'email.payment_link.voucher_intro_value_card', f);
  }
});

test('pohja: value_card true käyttää arvolahjakortin introa, muuten yleistä', async () => {
  const T = await import('../supabase/functions/send-emails/templates.ts');
  const pay = 'https://example.test/maksa/?p=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c';
  const data = (locale, value_card) => ({
    locale, to_name: 'Aada',
    order: { order_no: 42, order_url: 'https://example.test/tilaus/?t=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c' },
    payment: { amount: 30, link_url: pay },
    voucher_difference: { total: 80, voucher_value: 50, difference: 30, ...(value_card === undefined ? {} : { value_card }) },
  });
  const flat = (m) => m.text.replaceAll('\u00a0', ' ');
  const fiCard = flat(T.render('payment_link', data('fi', true), 'fi'));
  const enCard = flat(T.render('payment_link', data('en', true), 'en'));
  assert.match(fiCard, /arvolahjakortiksi\. Lahjakorttisi arvo on 50,00 €, joten maksettavaa jää vielä 30,00 €/);
  assert.match(enCard, /value gift card\. Your gift card is worth 50\.00 €, so 30\.00 € remains to be paid/);
  for (const flag of [false, undefined]) {
    assert.doesNotMatch(flat(T.render('payment_link', data('fi', flag), 'fi')), /arvolahjakortiksi/);
    assert.match(flat(T.render('payment_link', data('fi', flag), 'fi')), /Lahjakorttisi arvo on 50,00 €, joten maksettavaa jää vielä 30,00 €/);
    assert.doesNotMatch(flat(T.render('payment_link', data('en', flag), 'en')), /value gift card/i);
  }
});

test('migraatio + rollback: parametri, payload, sarake, jonon value_card; vanha kutsu säilyy oletuksella', () => {
  const mig = rd(MIG);
  const rb = rd(RB);
  assert.match(mig, /add column if not exists value_card boolean not null default false/);
  assert.match(mig, /drop function if exists booking\.svc_mark_voucher_claim_redeemed\(bigint, numeric, text, text\)/);
  assert.match(mig, /p_value_card boolean default false/);
  assert.match(mig, /return booking\._vc_redeem\(p_id, p_amount, p_partner_ref, p_note, 'bot', coalesce\(p_value_card, false\)\)/);
  assert.match(mig, /'value_card', v_card/);
  assert.match(mig, /set value_card = v_card where id = p_id/);
  assert.match(mig, /'value_card', coalesce\(\(e\.payload ->> 'value_card'\)::boolean, false\)/);
  assert.match(mig, /revoke all on function booking\.svc_mark_voucher_claim_redeemed\(bigint, numeric, text, text, boolean\) from public, anon, authenticated/);
  assert.match(mig, /grant execute on function booking\.svc_mark_voucher_claim_redeemed\(bigint, numeric, text, text, boolean\) to service_role/);
  assert.match(mig, /revoke all on function booking\._vc_redeem\(bigint, numeric, text, text, text, boolean\) from public, anon, authenticated, service_role/);
  assert.match(mig, /email_outbox_claim_base_215/);
  assert.doesNotMatch(mig, /function booking\._vc_redeem\(p_id bigint, p_amount numeric, p_partner_ref text, p_note text, p_by text\)/);
  assert.doesNotMatch(mig, /^\s*\\/m);
  assert.match(rb, /drop function if exists booking\.svc_mark_voucher_claim_redeemed\(bigint, numeric, text, text, boolean\)/);
  assert.match(rb, /drop function if exists booking\._vc_redeem\(bigint, numeric, text, text, text, boolean\)/);
  assert.match(rb, /drop column if exists value_card/);
  assert.match(rb, /return booking\._vc_redeem\(p_id, p_amount, p_partner_ref, p_note, 'bot'\)/);
  assert.match(rb, /grant execute on function booking\.svc_mark_voucher_claim_redeemed\(bigint, numeric, text, text\) to service_role/);
  const t = rd('supabase/tests/giftcards/t229_voucher_value_card.sql');
  assert.doesNotMatch(t, /^\s*\\/m);
  assert.match(t, /^begin;/m);
  assert.match(t, /^rollback;/m);
  assert.match(t, /returning id into/);
  assert.match(t, /svc_mark_voucher_claim_redeemed\(c\.id, 50, 'T229-GEN', null\)/);
  assert.match(t, /svc_mark_voucher_claim_redeemed\(p_id := c\.id, p_amount := 40, p_value_card := true\)/);
  assert.match(t, /p_value_card := true/);
  assert.match(t, /value_card/);
});
