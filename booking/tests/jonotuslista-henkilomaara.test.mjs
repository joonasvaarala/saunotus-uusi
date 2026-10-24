// booking_134: jonotuslistan henkilömäärä 1–6 ja mahtuvuuteen perustuva jako.
// Kaupan jonolomakkeen määrävalitsin (aiemmin painikkeet eivät muuttaneet määrää → aina 1 hlö), lunastuslinkin käsittely
// kassalla, migraation ja rollbackin rakenne sekä pending-import-36-tekstit. SQL-käytös: booking/supabase/tests/waitlist/t134_waitlist_party_size.sql
// (ajetaan paikallisessa PG17:ssä migraatioiden ja fixtures/10_test_helpers.sql:n jälkeen; työnkulussa ei ole Postgresia).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createWaitlistView } from '../shop/src/waitlist-ui.js';
import { WAITLIST_TEXTS } from '../shop/src/waitlist-texts.js';

const repo = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(resolve(repo, p), 'utf8');
const MIG = 'booking/supabase/migrations/20261024070000_booking_134_waitlist_party_size.sql';
const RB = 'booking/supabase/rollbacks/20261024070000_booking_134_ROLLBACK.sql';
const sql = rd(MIG), rollback = rd(RB);

// Pieni DOM-korvike: kuuntelijat toimivat, value on merkkijono kuten selaimessa.
function makeH() {
  return (tag, attrs = {}, ...children) => {
    const listeners = {};
    const node = {
      tag, attrs, children, disabled: false, readOnly: false, _v: attrs.value == null ? '' : String(attrs.value),
      get value() { return this._v; }, set value(v) { this._v = String(v); },
      addEventListener(ev, fn) { (listeners[ev] ||= []).push(fn); },
      fire(ev) { for (const fn of listeners[ev] || []) fn({ currentTarget: node }); },
      reportValidity() { return true; }, replaceChildren(...k) { this.children = k; }, append(...k) { this.children.push(...k); },
      scrollIntoView() {}, focus() {},
    };
    return node;
  };
}
const find = (nodes, pred) => { for (const n of [nodes].flat(Infinity)) {
  if (!n || typeof n !== 'object') continue;
  if (pred(n)) return n;
  const x = find(n.children ?? [], pred); if (x) return x;
} return null; };

async function mountWaitlist(s, lang = 'fi') {
  const h = makeH(); const calls = []; let mounted;
  const p = { id: 1, slug: 'yleinen', name: 'Yleinen vuoro' };
  const { viewWaitlist } = createWaitlistView({
    h, t: { ...WAITLIST_TEXTS[lang], summary: 'Yhteenveto', pickedSlot: 'Vuoro', changeSlot: 'Vaihda', back: 'Takaisin', persons: 'Henkilömäärä',
      name: 'Nimi', email: 'Sähköposti', phone: 'Puhelin', person: 'hlö', errorGeneric: 'Virhe' },
    S: { lang }, state: { catalog: [p] }, loadMonth: async () => ({ '2026-11-02': [s] }), setHero: () => {},
    mount: (...x) => { mounted = x; }, focusTop: () => {}, errorBox: (text) => h('p', { class: 'bk-error', text }), phoneBox: () => {},
    bk: (x) => `/varaa/#${x}`, rpc: async (name, args) => { calls.push({ name, args }); return { ok: true, token: '11111111-1111-4111-8111-111111111111', persons: args.p_persons }; },
    pname: (x) => x.name, dayLong: (x) => x.slice(0, 10), hm: () => '18:00',
  });
  await viewWaitlist(String(s.rule_id), '2026-11-02', '1');
  const num = find(mounted, (n) => n.tag === 'input' && n.attrs.id === 'bk-wl-n');
  const dec = find(mounted, (n) => n.tag === 'button' && n.attrs['aria-label'] === '−');
  const inc = find(mounted, (n) => n.tag === 'button' && n.attrs['aria-label'] === '+');
  const form = find(mounted, (n) => n.tag === 'form');
  const submit = async () => {
    const prev = globalThis.FormData;
    globalThis.FormData = class { get(k) { return ({ name: 'Testi Asiakas', email: 'testi@example.org', phone: '' })[k] ?? null; } };
    try { await form.attrs.onsubmit({ preventDefault() {} }); } finally { globalThis.FormData = prev; }
  };
  return { mounted, num, dec, inc, submit, calls };
}
const full = { rule_id: 11, status: 'full', starts_at: '2026-11-02T16:00:00Z', ends_at: '2026-11-02T19:00:00Z', min_persons: 1, max_persons: 6 };

test('jonolomake: +/- muuttaa henkilömäärää 1–6 ja määrä lähtee public_join_waitlist-kutsuun', async () => {
  const v = await mountWaitlist(full);
  assert.equal(v.num.value, '1'); assert.equal(v.dec.disabled, true); assert.equal(v.inc.disabled, false);
  v.inc.fire('click'); v.inc.fire('click');
  assert.equal(v.num.value, '3');
  for (let i = 0; i < 10; i++) v.inc.fire('click');
  assert.equal(v.num.value, '6'); assert.equal(v.inc.disabled, true);
  v.dec.fire('click'); assert.equal(v.num.value, '5');
  v.dec.fire('click'); v.dec.fire('click'); v.dec.fire('click');
  await v.submit();
  assert.equal(v.calls[0].name, 'public_join_waitlist');
  assert.equal(v.calls[0].args.p_persons, 2);
});
test('jonolomake: yläraja on 6 vaikka vuoron max olisi suurempi; kenttään kirjoitettu arvo rajataan', async () => {
  const v = await mountWaitlist({ ...full, max_persons: 16 });
  assert.equal(v.num.attrs.max, 6);
  v.num.value = '9'; v.num.fire('change'); assert.equal(v.num.value, '6');
  v.num.value = '0'; v.num.fire('change'); assert.equal(v.num.value, '1');
  const small = await mountWaitlist({ ...full, max_persons: 4 });
  for (let i = 0; i < 8; i++) small.inc.fire('click');
  assert.equal(small.num.value, '4');
});
test('jonolomake: ohjeteksti henkilömäärästä FI ja EN', async () => {
  for (const lang of ['fi', 'en']) {
    const v = await mountWaitlist(full, lang);
    assert.ok(find(v.mounted, (n) => n.tag === 'small' && n.attrs.text === WAITLIST_TEXTS[lang].waitlistPersonsHint), lang);
  }
});
test('tekstit: uudet avaimet FI+EN, ei <-merkkiä; pending-import-36 vastaa oletuksia', () => {
  const rows = JSON.parse(rd('content/site-texts.pending-import-36.json'));
  const map = { waitlistPersonsHint: 'ui.shop.waitlist_persons_hint', waitlistClaimNotEnough: 'ui.shop.waitlist_claim_not_enough', waitlistClaimInvalid: 'ui.shop.waitlist_claim_invalid' };
  for (const lang of ['fi', 'en']) {
    for (const [k, key] of Object.entries(map)) {
      assert.ok(WAITLIST_TEXTS[lang][k], `${k} ${lang}`); assert.doesNotMatch(WAITLIST_TEXTS[lang][k], /[<>]/);
      assert.equal(rows.find((r) => r.key === key && r.lang === lang)?.text, WAITLIST_TEXTS[lang][k]);
    }
    assert.equal(rows.find((r) => r.key === 'ui.shop.waitlist_errors.invalid_persons' && r.lang === lang)?.text, WAITLIST_TEXTS[lang].waitlistErrors.invalid_persons);
  }
  assert.equal(rows.length, 8);
});
test('kassa: ?wl= lunastetaan public_waitlist_claim-kutsulla; liian vähän paikkoja → ei varauslomaketta; muuten määrä lukitaan', () => {
  const shop = rd('booking/shop/src/shop.js');
  assert.match(shop, /rpc\('public_waitlist_claim', \{ p_token: wl \}\)/);
  assert.match(shop, /!c\.enough[\s\S]{0,200}errorBox\(t\.waitlistClaimNotEnough\)[\s\S]{0,300}return;/);
  assert.match(shop, /n = \+c\.persons; wlLock = true;/);
  assert.match(shop, /minus\.disabled = wlLock \|\| /); assert.match(shop, /plus\.disabled = wlLock \|\| /);
  assert.match(shop, /num\.readOnly = wlLock/);
  assert.match(shop, /t\.waitlistClaimInvalid/);
});
test('mock: public_join_waitlist hylkää 0 ja 7 hlöä, public_waitlist_claim palauttaa henkilömäärän', () => {
  const mock = rd('booking/shop/src/shop-mock.js');
  assert.match(mock, /\+args\.p_persons > 6\) return \{ ok: false, code: 'invalid_persons' \}/);
  assert.match(mock, /case 'public_waitlist_claim':/);
});
test('migraatio booking_134: aikaleima > booking_133, henkilömäärä 1–6, mahtuvuusbudjetti, lunastus', () => {
  assert.ok('20261024070000' > '20261024064158');
  assert.match(sql, /p_persons is null or p_persons not between 1 and 6 then\s+return jsonb_build_object\('ok',false,'code','invalid_persons'\)/);
  assert.match(sql, /p_persons > least\(6,coalesce\(v_rule\.max_persons,6\)\)/);
  // jonon järjestys säilyy (created_at,id), liian iso ohitetaan (continue), jäljelle jäävät paikat seuraavalle mahtuvalle
  assert.match(sql, /order by created_at,id/);
  assert.match(sql, /v_left := v_s\.remaining - coalesce\(\(v_used->>v_k\)::int,0\);\s+if v_left < w\.persons then continue; end if;/);
  assert.match(sql, /v_used := v_used \|\| jsonb_build_object\(v_k, coalesce\(\(v_used->>v_k\)::int,0\) \+ w\.persons\)/);
  assert.match(sql, /create or replace function booking\.public_waitlist_claim\(p_token uuid\) returns jsonb\s+language plpgsql security definer set search_path = ''/);
  assert.match(sql, /v_enough := found and v_s\.starts_at = w\.starts_at and v_s\.status = 'available' and v_s\.remaining >= w\.persons;/);
  assert.match(sql, /if not v_enough and w\.status = 'notified' then\s+[\s\S]{0,120}update booking\.waitlist_entries set status='waiting'/);
  assert.match(sql, /'persons',w\.persons,'enough',v_enough/);
  assert.doesNotMatch(sql, /customer_email',|'customer_name'/);
  assert.match(sql, /grant execute on function booking\.public_waitlist_claim\(uuid\) to anon,authenticated,service_role;/);
  assert.match(sql, /revoke all on function booking\._notify_waitlist_for_window\(bigint,timestamptz,timestamptz\) from public,anon,authenticated;/);
  assert.doesNotMatch(sql, /\bpublic\.[a-z_]+/i, 'ei public-skeemaa');
  assert.doesNotMatch(sql, /alter table|drop table|create table/i, 'ei taulumuutoksia');
});
test('rollback booking_134: palauttaa booking_133-tilan funktiot ja poistaa lunastuksen', () => {
  assert.match(rollback, /drop function if exists booking\.public_waitlist_claim\(uuid\);/);
  assert.match(rollback, /CREATE OR REPLACE FUNCTION booking\.public_join_waitlist\(/);
  assert.match(rollback, /p_persons not between greatest\(1,v_rule\.min_persons\) and least\(50,v_rule\.max_persons\)/);
  assert.match(rollback, /CREATE OR REPLACE FUNCTION booking\._notify_waitlist_for_window\(/);
  assert.match(rollback, /v_s\.remaining < w\.persons then continue;/);
  assert.doesNotMatch(rollback, /v_used|invalid_persons/);
  assert.match(rollback, /grant execute on function booking\.public_join_waitlist\(bigint,date,integer,text,text,text,text,boolean\) to anon,authenticated,service_role;/);
  assert.doesNotMatch(rollback, /delete from|drop table/i, 'ei dataa poisteta');
});
