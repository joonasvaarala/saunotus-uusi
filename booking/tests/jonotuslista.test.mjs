// booking_132: jonotuslistan toiminnalliset ja SQL-rakennetestit. Node >= 20.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { visibleWaitlistSlots, hasWaitlistSlots, fullyBooked } from '../shop/src/waitlist-logic.js';
import { WAITLIST_TEXTS } from '../shop/src/waitlist-texts.js';
import { createWaitlistView } from '../shop/src/waitlist-ui.js';
const HERE = dirname(fileURLToPath(import.meta.url));
const repo = resolve(HERE, '../..');
const sql = readFileSync(resolve(repo, 'booking/supabase/migrations/20261024060000_booking_132_waitlist.sql'), 'utf8');
const rollback = readFileSync(resolve(repo, 'booking/supabase/rollbacks/20261024060000_booking_132_ROLLBACK.sql'), 'utf8');

const rows = [
  { rule_id: 1, status: 'full', starts_at: '2026-11-02T16:00:00Z' },
  { rule_id: 2, status: 'unavailable', starts_at: '2026-11-02T15:00:00Z' },
  { rule_id: 3, status: 'available', starts_at: '2026-11-02T18:00:00Z' },
  { rule_id: 4, status: 'full', starts_at: '2026-11-02T14:00:00Z' },
];

test('tuotenäkymä: vapaat ensin, loppuunmyydyt lopuksi, unavailable piilossa', () => {
  assert.deepEqual(visibleWaitlistSlots(rows).map(x => x.rule_id), [3, 4, 1]);
  assert.equal(hasWaitlistSlots([{ status: 'unavailable' }]), false);
  assert.equal(fullyBooked([{ status: 'full' }, { status: 'unavailable' }]), true);
  assert.equal(fullyBooked([{ status: 'available' }, { status: 'full' }]), false);
});

test('päivänäkymä: samoja tilasääntöjä sovelletaan {r,p}-riveihin', () => {
  const wrapped = rows.map(r => ({ r, p: { id: 1 } }));
  assert.deepEqual(visibleWaitlistSlots(wrapped).map(x => x.r.rule_id), [3, 4, 1]);
  const products = [[1, wrapped.slice(0,2)], [2, wrapped.slice(2,3)], [3, wrapped.slice(3)]];
  products.sort((a,b) => Number(fullyBooked(a[1])) - Number(fullyBooked(b[1])));
  assert.equal(products[0][0], 2);
});

test('FI ja EN sisältävät loppuunmyyty- ja jonotusviestit', () => {
  assert.equal(WAITLIST_TEXTS.fi.waitlistSessionSoldOut, 'Vuoro on loppuunmyyty');
  assert.equal(WAITLIST_TEXTS.en.waitlistSessionSoldOut, 'Session sold out');
  for (const lang of ['fi','en']) for (const key of ['waitlistSoldOut','waitlistJoinShort','waitlistJoin','waitlistDone','waitlistLeave','waitlistLeft','waitlistIntro'])
    assert.equal(typeof WAITLIST_TEXTS[lang][key], 'string', `${lang}.${key}`);
});

test('julkiset liittymis- ja poistumis-RPC:t: validointi ja rivin tilat', () => {
  for (const needle of ['create or replace function booking.public_join_waitlist(', 'create or replace function booking.public_leave_waitlist(',
    "status='waiting'", "status='cancelled'", "booking._rate_limit(", 'booking._valid_email(',
    "v_s.status <> 'full'", "case when v_opt then 'both' else 'email' end",
    'on conflict (rule_id,session_date,(lower(customer_email)))', 'return jsonb_build_object(\'ok\',true,\'token\''])
    assert.ok(sql.includes(needle), needle);
});

test('sama sähköposti jonoon kerran ja automaattinen booked-konversio', () => {
  assert.match(sql, /create unique index if not exists waitlist_one_active_email_idx[\s\S]*lower\(customer_email\)/);
  assert.match(sql, /create constraint trigger waitlist_reservation_booked/);
  assert.match(sql, /converted_order_id=new\.order_id/);
  assert.match(sql, /w\.rule_id=new\.rule_id/);
});

test('vapautuminen: triggerit, ajantasainen saatavuus ja email_outbox', () => {
  for (const pattern of [/after update or delete on booking\.reservations/,
    /booking\._notify_waitlist_for_window\(old\.space_id/,
    /old\.hold_expires_at <= now\(\)/,
    /from booking\._sessions\(w\.session_date,w\.session_date,w\.product_id,true\)/,
    /v_s\.status<>'available' or v_s\.remaining < w\.persons/,
    /insert into booking\.email_outbox\(kind,locale,dedupe_key,status,payload\)/,
    /'waitlist_spot_freed'/,
    /'book_url'/, /'leave_url'/]) assert.match(sql, pattern);
});

test('migraatio: uusi viestityyppi kind-rajoitteeseen, oikea tilataulu, uudelleenajettava, rollback palauttaa booking_121:n listan', () => {
  assert.match(sql, /add constraint email_outbox_kind_check[\s\S]*'product_message', 'waitlist_spot_freed'\)\)/);
  assert.match(sql, /references booking\.resources\(id\)/);
  assert.doesNotMatch(sql, /booking\.spaces\b/);
  assert.match(sql, /create table if not exists booking\.waitlist_entries/);
  assert.doesNotMatch(sql, /^create (function|table|index|unique index) (?!if not exists)/m);
  assert.match(sql, /drop trigger if exists waitlist_reservation_freed/);
  assert.match(sql, /drop trigger if exists waitlist_reservation_booked/);
  assert.match(sql, /if to_regprocedure\('booking\.email_outbox_claim_base_132\(integer\)'\) is null then/);
  assert.match(sql, /when w\.locale='en' then '\/en\/book\/' else '\/varaa\/'/);
  assert.doesNotMatch(sql, /\bpublic\./);
  assert.match(rollback, /if to_regprocedure\('booking\.email_outbox_claim_base_132\(integer\)'\) is not null then/);
  assert.match(rollback, /delete from booking\.email_outbox where kind = 'waitlist_spot_freed'/);
  assert.match(rollback, /'invoice_pdf', 'product_message'\)\);/);
  assert.doesNotMatch(rollback, /waitlist_spot_freed'\)\)/);
});

test('WhatsApp pois oletuksena, Suomen hiljainen aika 21–08 ja välitön päiväajan ajastus', () => {
  assert.match(sql, /'waitlist_whatsapp_enabled', 'false'::jsonb/);
  assert.match(sql, /'waitlist_quiet_hours_start', '21'::jsonb/);
  assert.match(sql, /'waitlist_quiet_hours_end', '8'::jsonb/);
  assert.match(sql, /if v_wa and w\.whatsapp_opt_in and w\.customer_phone is not null then/);
  assert.match(sql, /at time zone 'Europe\/Helsinki'/);
  assert.match(sql, /else v_wa_after := now\(\); end if;/);
  assert.match(sql, /whatsapp_queued_at=null/);
});

test('email_outbox_claim rikastaa odottelijan viestit, rollback palauttaa alkuperäisen', () => {
  assert.match(sql, /rename to email_outbox_claim_base_132/);
  assert.match(sql, /z\.item \|\| jsonb_build_object\('waitlist'/);
  assert.match(rollback, /rename to email_outbox_claim;/);
  assert.match(rollback, /drop table if exists booking\.waitlist_entries/);
});

test('UI liittyminen ja poistuminen käyttävät oikeita RPC-kutsuja', async () => {
  const calls = [];
  let mounted;
  const h = (tag, attrs = {}, ...children) => ({
    tag, attrs, children, value: attrs.value ?? '', disabled: false,
    addEventListener() {}, reportValidity() { return true; },
    replaceChildren(...kids) { this.children = kids; }, append(...kids) { this.children.push(...kids); },
    scrollIntoView() {}, focus() {},
  });
  const p = { id: 1, slug: 'test', name: 'Testisauna' };
  const s = { rule_id: 11, status: 'full', starts_at: '2026-11-02T16:00:00Z', ends_at: '2026-11-02T17:30:00Z', min_persons: 1, max_persons: 8 };
  const { viewWaitlist } = createWaitlistView({
    h, t: { ...WAITLIST_TEXTS.fi, summary:'Yhteenveto', pickedSlot:'Vuoro', changeSlot:'Vaihda', back:'← Takaisin', persons:'Henkilömäärä',
      name:'Nimi',email:'Sähköposti',phone:'Puhelin',person:'hlö',errorGeneric:'Virhe' },
    S: { lang:'fi' }, state: { catalog:[p] },
    loadMonth: async () => ({ '2026-11-02': [s] }), setHero: () => {},
    mount: (...x) => { mounted=x; }, focusTop:()=>{},
    errorBox: text => h('p', { class: 'bk-error', text }), phoneBox:()=>{},
    bk: x=>`/varaa/#${x}`, rpc: async (name, args) => {
      calls.push({name,args}); return name==='public_join_waitlist' ? { ok:true, token:'11111111-1111-4111-8111-111111111111', persons:args.p_persons } : { ok:true,cancelled:true };
    },
    pname: x=>x.name,dayLong: x=>x.slice(0,10), hm:()=> '18:00',
  });
  await viewWaitlist('11','2026-11-02','1','day');
  const find = (nodes, tag, predicate=()=>true) => { for (const n of nodes.flat()) {
    if (!n || typeof n !== 'object') continue;
    if (n.tag===tag && predicate(n)) return n;
    const next = find(n.children ?? [],tag,predicate); if(next) return next;
  } return null; };
  const form = find(mounted,'form'); assert.ok(form);
  const previous = globalThis.FormData;
  globalThis.FormData = class { get(k) { return ({ name:'Testi Asiakas', email:'test@example.org', phone:'' })[k] ?? null; } };
  try { await form.attrs.onsubmit({ preventDefault(){} }); } finally { globalThis.FormData=previous; }
  assert.equal(calls[0].name,'public_join_waitlist');
  assert.equal(calls[0].args.p_rule_id, 11);
  assert.equal(calls[0].args.p_whatsapp_opt_in, false);
  const leave = find(mounted,'button', x=>x.attrs.text===WAITLIST_TEXTS.fi.waitlistLeave);
  assert.ok(leave); await leave.attrs.onclick({ currentTarget:leave });
  assert.equal(calls[1].name,'public_leave_waitlist');
  assert.equal(calls[1].args.p_token,'11111111-1111-4111-8111-111111111111');
});

test('sovitetussa repossa lopulliset shop.js/index.ts sisältävät jonotusreitit ja sähköpostirenderöinnin', () => {
  const shopPath = resolve(repo,'booking/shop/src/shop.js');
  const edgePath = resolve(repo,'booking/supabase/functions/send-emails/index.ts');
  // Paketti voidaan ajaa irrallaan checkout-reposta; siellä sovellus tehdään apply-to-repo.py:llä.
  if (!existsSync(shopPath) || !existsSync(edgePath)) {
    const installer = readFileSync(resolve(repo,'apply-to-repo.py'),'utf8');
    assert.match(installer, /waitlistSessionSoldOut/);
    assert.match(installer, /waitlist_spot_freed/);
    return;
  }
  const js = readFileSync(shopPath,'utf8'), index = readFileSync(edgePath,'utf8');
  assert.match(js, /visibleWaitlistSlots\(byDay\[sel\] \|\| \[\]\)/);
  assert.match(js, /createWaitlistView/);
  assert.match(js, /class: 'btn sm light bk-waitlist-link'/);
  assert.match(js, /await wv\.viewWaitlist/);
  assert.match(index, /render\(r\.kind as Kind, r, r\.locale, t\)/);
  assert.doesNotMatch(index, /renderWaitlist/);
  // Poistumislinkki käsitellään sivutekstien latauksen jälkeen ja parametri poistetaan osoitteesta.
  assert.ok(js.indexOf("sp.get('poistu_jonosta')") > js.indexOf('await loadBase();'));
  assert.match(js, /sp\.delete\('poistu_jonosta'\)/);
});

test('sähköposti: waitlist_spot_freed renderöidään templates.ts:n yhteisillä osilla ja email.waitlist.*-teksteillä', async (t) => {
  let TPL;
  try { TPL = await import(new URL('../supabase/functions/send-emails/templates.ts', import.meta.url).href); }
  catch { t.skip('TypeScript-tuonti ei käytössä tässä Nodessa'); return; }
  const d = { locale: 'fi', to_name: 'Aada Testi', waitlist: { product_name: 'Yleinen vuoro', starts_at: '2026-11-02T14:00:00Z', ends_at: '2026-11-02T17:00:00Z', persons: 2,
    book_url: 'https://example.test/varaa/#/varaa/1/2026-11-02/2?n=2&wl=x', leave_url: 'https://example.test/varaa/?poistu_jonosta=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c' } };
  const fi = TPL.render('waitlist_spot_freed', d, 'fi');
  assert.equal(fi.subject, 'Paikka vapautui jonottamallesi vuorolle – Sipoonjoen Perinnesauna');
  assert.ok(fi.text.includes('Hei Aada,') && fi.text.includes('Yleinen vuoro') && fi.text.includes('2 hlö'));
  assert.ok(fi.text.includes('Tämä ilmoitus ei varaa paikkaa.'));
  assert.ok(fi.html.includes('href="https://example.test/varaa/#/varaa/1/2026-11-02/2?n=2&amp;wl=x"'));
  assert.ok(fi.html.includes('poistu_jonosta=3f2b8c1e'));
  assert.ok(fi.html.includes('#1f3d2b') && !/#(00f|0000ff|1e90ff|2563eb|3b82f6)/i.test(fi.html));
  const en = TPL.render('waitlist_spot_freed', { ...d, locale: 'en' }, 'en');
  assert.match(en.subject, /^A place is available/);
  assert.ok(en.text.includes('2 guests') && !/Hei|Tilaus/.test(en.text));
  const bad = TPL.render('waitlist_spot_freed', { ...d, waitlist: { ...d.waitlist, book_url: 'javascript:alert(1)', product_name: '<b>x</b>' } }, 'fi');
  assert.ok(!bad.html.includes('javascript:') && !bad.html.includes('<b>x</b>'));
});
