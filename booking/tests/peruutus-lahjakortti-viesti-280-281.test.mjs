// booking_280 (lahjakortti-/kumppanikoodivarauksen peruutus) + booking_281 (yhdistetty reservation_cancelled-viesti).
// Ei verkkoa eikä tietokantaa. SQL-testi: booking/supabase/tests/talous/t280_281_cancel_gift_mail.sql (paikallinen Postgres).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const mig = (re) => readdirSync(join(root, 'supabase/migrations')).filter((n) => re.test(n));
const M280 = read('booking/supabase/migrations/20261111235902_booking_280_gift_card_voucher_cancel.sql');
const R280 = read('booking/supabase/rollbacks/20261111235902_booking_280_ROLLBACK.sql');
const M281 = read('booking/supabase/migrations/20261111235903_booking_281_reservation_cancelled_mail.sql');
const R281 = read('booking/supabase/rollbacks/20261111235903_booking_281_ROLLBACK.sql');
const RC = await import(pathToFileURL(join(root, 'admin/views/refund-cancel.js')));
const T = await import(pathToFileURL(join(root, 'admin/refund-cancel-texts.js')));
const { createMock } = await import(pathToFileURL(join(root, 'admin/talous-mock.js')));
const { createAdminMock } = await import(pathToFileURL(join(root, 'admin/options-mock.js')));

test('migraatiot: yksi 280 ja yksi 281, rollbackit, ei public-skeemaa, ei live-kytkimiä', () => {
  assert.equal(mig(/_booking_280_/).length, 1);
  assert.equal(mig(/_booking_281_/).length, 1);
  for (const sql of [M280, M281, R280, R281]) {
    assert.doesNotMatch(sql, /\bpublic\.[a-z_]+\s*\(/, 'ei public-skeeman funktioita');
    assert.doesNotMatch(sql, /update booking\.integration_config|update booking\.settings/i, 'ei kytkimiä eikä asetusmuutoksia');
    assert.doesNotMatch(sql, /resend_mode|email_mode/i, 'ei sähköpostitilan muutosta');
  }
});

test('280: md5-vartijat ennen muutoksia (PROD-lähtötila), rollback vartioi ja palauttaa', () => {
  for (const h of ['709d5fd54d877846682571b60c5d21bd', 'aed4b0d7e19f7c13d1ac91c28cc0b642', 'e627951cee8875cbab0b8ad8b02d8de1', 'a22952905fc68f119427f7fd4e6025fa', 'f1958557dbf3ed5ab36d728e2582088a', 'b77f3c4116f6f1ef64267ce4ebde20a1'])
    assert.ok(M280.includes(h), `280 odottaa ${h}`);
  assert.ok(M280.indexOf('end $pre$') < M280.indexOf('create table'), 'vartija ennen DDL:ää');
  assert.match(M280, /gift_card_keep_required/); assert.match(M280, /gift_card_expired/);
  assert.match(M280, /gift_card_requires_keep_choice/); assert.match(M280, /voucher_not_refundable/);
  assert.match(M280, /_require_permission\('bookings\.manage'\)/);
  for (const h of ['21cdc941bb061856bd368130a08a5704', '9a63771574d6a03f665078c5895010d5', '5664a3cde7b36666711c023e8ce9ba5f']) assert.ok(R280.includes(h), `rollback vartioi ${h}`);
  assert.match(R280, /gift_card_forfeits/);
});

test('281 (Joonas 11.11.2026 18.12–18.15): viesti heti, ei pankkipäiväodotusta; valmiin hyvityksen kuitti liitteenä ja erillinen ohitetaan', () => {
  assert.doesNotMatch(M281, /bank_days|pankkipäiv[äi]\w*\(|_add_bank_days|refund_mail_links|next_attempt_at\s*=/, 'ei odotusta, ei vakiota, ei linkkitaulua');
  for (const h of ['e46ae5ebd9fb813a087b7f05c40949b8', '5664a3cde7b36666711c023e8ce9ba5f', '37e35b13045a53822f2da9ded36263e1']) assert.ok(M281.includes(h), `281 odottaa ${h}`);
  assert.doesNotMatch(M281, /create or replace function booking\._on_refund_done/i, 'kuittipolku (_on_refund_done) ennallaan');
  assert.match(M281, /'reservation_cancelled'/);
  assert.match(M281, /rr\.kind = 'refund_receipt' and rr\.receipt_id = rc\.id/, 'claim ohittaa saman kuitin erillisen viestin');
  assert.match(M281, /f\.status = 'done' and rc\.id is not null and not rc_sent\.sent/, 'kuitti liitteeksi vain valmiille, ei jo lähetetylle');
  assert.match(M281, /if p_notify then/);
  assert.match(R281, /reservation_cancelled-viestejä on jo/);
  const TPL = read('booking/supabase/functions/send-emails/templates.ts');
  assert.match(TPL, /case "reservation_cancelled"/);
  assert.match(read('booking/supabase/functions/send-emails/index.ts'), /r\.kind === "reservation_cancelled"[\s\S]{0,600}receipt-pdf/);
});

test('UI: peruutusdialogi hakee valinnat, lahjakortti- ja viestikysymys pakollisia ilman oletusta', () => {
  const src = read('booking/admin/views/refund-cancel.js');
  // ei hyvitystä (ei rahaa eikä lahjakorttipalautusta) → vihje ilman hyvitysmainintaa; teksti tuonnissa 138 FI+EN
  assert.match(src, /total > 0 \|\| \+opts\.gift_card_total > 0 \? 'ui\.admin\.refund_cancel\.notify_hint' : 'ui\.admin\.refund_cancel\.notify_hint_no_refund'/);
  { const rows = JSON.parse(read('content/site-texts.pending-import-138.json')).filter((r) => r.key === 'ui.admin.refund_cancel.notify_hint_no_refund');
    assert.deepEqual(rows.map((r) => r.lang).sort(), ['en', 'fi']);
    for (const r of rows) assert.doesNotMatch(r.text.replace(/ei mainita hyvitystä|does not mention a refund|ei tehdä hyvitystä|No refund is made/g, ''), /hyvit|käsittelyssä|kuitti|refund|receipt/i); }
  // Node.append(null) kirjoittaisi tekstin "null": puuttuvat kysymykset suodatetaan pois
  assert.match(src, /choice\?\.node, reasonFld, gcChoice\?\.node, notifyChoice\?\.node, missingMsg,[\s\S]{0,80}\]\.filter\(Boolean\)\)/);
  assert.match(src, /admin_reservation_cancel_options/);
  assert.match(src, /p_gift_card_keep/); assert.match(src, /p_notify/);
  assert.match(src, /requiredYesNo\(\{ name: 'gift_card_keep'/);
  assert.match(src, /requiredYesNo\(\{ name: 'notify'/);
  // pakollinen valinta: ei checked-oletusta
  const fn = src.slice(src.indexOf('export function requiredYesNo'), src.indexOf('const MP_KINDS'));
  assert.doesNotMatch(fn, /checked:/, 'ei oletusvalintaa');
  // vanha kanta (ei valinnat-RPC:tä): uusia parametreja ei lähetetä
  assert.match(src, /if \(opts\) \{ args\.p_gift_card_keep/);
});

test('UI: onnistumisteksti kertoo hyvityksen, lahjakortin, tilauksen ja viestin', () => {
  assert.equal(RC.doneText({ refunded_total: 0 }), T.rcText('ui.admin.refund_cancel.done_cancelled', null, 'fi'));
  const s = RC.doneText({ refunded_total: 10, gift_card: [{ action: 'returned', amount: 5 }, { action: 'forfeited', amount: 3 }], order_kept: true, notified: true });
  assert.match(s, /hyvitetty 10,00/); assert.match(s, /palautettiin 5,00/); assert.match(s, /arvo 3,00\s€ menetettiin/); assert.match(s, /Tilaus jää voimaan/); assert.match(s, /Peruutusviesti/);
});

test('tekstit: uudet refund_cancel-avaimet FI+EN pending-import-138:ssa, sama teksti kuin sanakirjassa', () => {
  const rows = JSON.parse(read('content/site-texts.pending-import-138.json'));
  const keys = ['gift_card_question', 'gift_card_keep', 'gift_card_forfeit', 'gift_card_expired', 'partner_share', 'partner_order_stays', 'notify_question', 'notify_yes', 'notify_no', 'notify_no_email', 'choose_required'];
  for (const lang of ['fi', 'en']) for (const k of keys) {
    const key = `ui.admin.refund_cancel.${k}`;
    const r = rows.find((x) => x.key === key && x.lang === lang);
    assert.ok(r, `${key} [${lang}]`);
    assert.equal(r.text, T.REFUND_CANCEL_TEXTS[lang][key]);
  }
  const emails = rows.filter((r) => r.key.startsWith('email.reservation_cancelled.'));
  assert.equal(emails.length, 28, '14 sähköpostiavainta × FI+EN');
  for (const r of emails) assert.doesNotMatch(r.text, /montonio|visma|mobilepay/i, 'asiakasviestissä ei maksuvälittäjän nimeä');
});

test('talous-mock: lahjakorttivaraus vaatii valinnan, kumppanimaksua ei hyvitetä, viesti vain pyydettäessä', async () => {
  const mock = createMock({ n: 400, seed: 280 });
  const list = await mock.rpc('admin_list_orders', { p_limit: 200 });
  let tried = 0;
  for (const row of list.rows) {
    const o = await mock.rpc('admin_get_order', { p_order_id: row.order_id });
    const r = (o.reservations || []).find((x) => ['confirmed', 'pending', undefined].includes(x.status));
    if (!r) continue;
    const id = r.reservation_id ?? r.id;
    const opt = await mock.rpc('admin_reservation_cancel_options', { p_reservation_id: id });
    assert.equal(opt.ok, true);
    if (opt.gift_card_choice_required) {
      await assert.rejects(() => mock.rpc('admin_cancel_reservation', { p_reservation_id: id, p_refund: true }), (e) => e.code === 'gift_card_keep_required');
      if (opt.gift_cards.every((g) => g.keep_allowed)) {
        const res = await mock.rpc('admin_cancel_reservation', { p_reservation_id: id, p_refund: true, p_gift_card_keep: true, p_notify: false });
        assert.ok(res.gift_card.every((g) => g.action === 'returned')); assert.equal(res.notified, false);
        tried++;
      }
    }
    if (tried >= 1) break;
  }
  assert.ok(tried >= 1, 'mockissa on lahjakortilla maksettu varaus');
});

test('kokeilutila (options-mock): lahjakortti- ja kumppanivaraus, viesti', async () => {
  const mgr = createAdminMock({ role: 'manager' });
  const paid = mgr.state.reservations.filter((r) => r.status === 'confirmed' && r.payment_status === 'paid');
  const gc = mgr.state.reservations.filter((r) => r.payment_status === 'paid').at(-1), pv = paid.find((r) => r.reservation_id % 3 === 0);
  if (gc) {
    const o = await mgr.rpc('admin_reservation_cancel_options', { p_reservation_id: gc.reservation_id });
    assert.equal(o.gift_card_choice_required, true);
    await assert.rejects(() => mgr.rpc('admin_cancel_reservation', { p_reservation_id: gc.reservation_id, p_refund: true }), (e) => e.code === 'gift_card_keep_required');
    const res = await mgr.rpc('admin_cancel_reservation', { p_reservation_id: gc.reservation_id, p_refund: true, p_gift_card_keep: false, p_notify: true });
    assert.equal(res.refunded_total, 0); assert.equal(res.gift_card[0].action, 'forfeited'); assert.equal(res.notified, true);
  }
  if (pv) {
    const o = await mgr.rpc('admin_reservation_cancel_options', { p_reservation_id: pv.reservation_id });
    assert.equal(o.voucher_redeemed, true); assert.equal(o.order_stays, true); assert.equal(o.money_share, 0);
    const res = await mgr.rpc('admin_cancel_reservation', { p_reservation_id: pv.reservation_id, p_refund: true, p_notify: false });
    assert.equal(res.refunded_total, 0); assert.equal(res.order_kept, true); assert.equal(res.notified, false);
  }
  assert.ok(gc && pv, 'kokeilutilassa on lahjakortti- ja kumppanivaraus');
});

test('PR 1 -tilausnäkymän peruutusdialogi (order-cancel-flow) käyttää 280/281-valintoja: lahjakortti pakollinen, viesti yhdelle varaukselle', async () => {
  const L = await import(pathToFileURL(join(root, 'admin/order-view-logic.js')));
  const gc = { reservation_id: 1, gift_card_choice_required: true, gift_cards: [{ amount: 85, code_last4: '4821', valid_to: '2027-06-30', keep_allowed: true }], gift_card_total: 85, partner_share: 0, money_share: 0, customer_email: true };
  // kanta ilman 280:tä → ei mitään uutta, ei uusia parametreja
  const old = L.cancelFlowExtras({ scope: 'one', options: null });
  assert.equal(old.active, false); assert.deepEqual(old.argsFor(1), {}); assert.deepEqual(old.missing, []); assert.equal(old.notify.show, false); assert.equal(old.notify.reason, null);
  assert.deepEqual(L.cancelFlowExtras({ scope: 'one', options: [null] }).argsFor(1), {}, 'haku epäonnistui → vanha toiminta');
  // lahjakortti: pakollinen, ei oletusta
  let x = L.cancelFlowExtras({ scope: 'one', options: [gc] });
  assert.equal(x.gift.show, true); assert.equal(x.gift.total, 85); assert.deepEqual(x.missing, ['gift', 'notify']);
  assert.equal(x.notify.hintKey, 'notify_hint_no_refund', 'ei valintaa → ei hyvitysmainintaa');
  x = L.cancelFlowExtras({ scope: 'one', options: [gc], gift: 'keep', notify: 'yes' });
  assert.deepEqual(x.missing, []); assert.deepEqual(x.argsFor(1), { p_gift_card_keep: true, p_notify: true }); assert.equal(x.notify.hintKey, 'notify_hint', 'arvo palautuu kortille = hyvitys');
  x = L.cancelFlowExtras({ scope: 'one', options: [gc], gift: 'forfeit', notify: 'no' });
  assert.deepEqual(x.argsFor(1), { p_gift_card_keep: false, p_notify: false }); assert.equal(x.notify.hintKey, 'notify_hint_no_refund');
  // vanhentunut kortti: "keep" ei kelpaa
  const exp = { ...gc, gift_cards: [{ ...gc.gift_cards[0], keep_allowed: false }] };
  assert.deepEqual(L.cancelFlowExtras({ scope: 'one', options: [exp], gift: 'keep', notify: 'no' }).missing, ['gift']);
  // laskulukittu: ei lahjakorttikysymystä
  assert.equal(L.cancelFlowExtras({ scope: 'one', locked: true, options: [gc] }).gift.show, false);
  // rahahyvitys: osuus = money_share; vihje hyvityksen mukaan
  const money = { reservation_id: 2, gift_card_choice_required: false, gift_cards: [], gift_card_total: 0, partner_share: 0, money_share: 60, customer_email: true };
  assert.equal(L.cancelFlowExtras({ scope: 'one', options: [money] }).moneyShare, 60);
  assert.equal(L.cancelFlowExtras({ scope: 'one', options: [money], refunding: true }).notify.hintKey, 'notify_hint');
  assert.equal(L.cancelFlowExtras({ scope: 'one', options: [money], refunding: false }).notify.hintKey, 'notify_hint_no_refund');
  // ei sähköpostia → ei kysymystä, p_notify false
  const noMail = L.cancelFlowExtras({ scope: 'one', options: [{ ...money, customer_email: false }] });
  assert.equal(noMail.notify.show, false); assert.equal(noMail.notify.reason, 'notify_no_email'); assert.deepEqual(noMail.argsFor(2), { p_gift_card_keep: null, p_notify: false });
  // kumppanikoodi
  const pv = L.cancelFlowExtras({ scope: 'one', options: [{ ...money, money_share: 0, partner_share: 64, voucher_redeemed: true, order_stays: true }] });
  assert.deepEqual(pv.partnerNotes, [{ key: 'partner_share', vars: { amount: 64 } }, { key: 'partner_order_stays' }]);
  // koko tilaus: lahjakortti kysytään kerran, viestiä ei lähetetä (p_notify false jokaiselle)
  const all = L.cancelFlowExtras({ scope: 'all', options: [gc, money], gift: 'forfeit' });
  assert.equal(all.notify.show, false); assert.equal(all.notify.reason, 'notify_all_unavailable'); assert.deepEqual(all.missing, []);
  assert.deepEqual(all.argsFor(1), { p_gift_card_keep: false, p_notify: false }); assert.deepEqual(all.argsFor(2), { p_gift_card_keep: null, p_notify: false });
  // näkymä: valinnat-RPC, parametrit kutsuihin, pakollisuusviesti, tekstiavaimet tuonnissa 138
  const flow = read('booking/admin/views/order-cancel-flow.js');
  assert.match(flow, /rpc\('admin_reservation_cancel_options', \{ p_reservation_id: id \}\)/);
  assert.equal((flow.match(/\.\.\.ex\.argsFor\(/g) || []).length, 2, 'molemmat admin_cancel_reservation-kutsut');
  assert.match(flow, /plan\.scope === 'all' && ex\.gift\.show && plan\.refund\.show\) plan\.refund = \{ show: false/, 'koko tilaus + lahjakortti: ei admin_refund_order-hyvitystä');
  assert.match(flow, /ex\.missing\.length\) \{ err\.textContent = rcText\('ui\.admin\.refund_cancel\.choose_required'\)/);
  const keys = new Set(JSON.parse(read('content/site-texts.pending-import-138.json')).map((r) => `${r.key}|${r.lang}`));
  for (const k of ['gift_card_question', 'gift_card_share', 'gift_card_keep', 'gift_card_forfeit', 'gift_card_expired', 'partner_share', 'partner_order_stays', 'notify_question', 'notify_hint', 'notify_hint_no_refund', 'notify_yes', 'notify_no', 'notify_no_email', 'notify_all_unavailable', 'all_gift_refund_separately', 'choose_required'])
    for (const lang of ['fi', 'en']) assert.ok(keys.has(`ui.admin.refund_cancel.${k}|${lang}`), `${k} ${lang}`);
});
