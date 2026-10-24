// Hallinnan uusi päänavigaatio, varauslistan järjestys, mobiilipalkki ja pikahaku.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { resolveAdminPath, initialOrdersTab, compactIdentity, toggleMobileNav } from '../admin/admin-navigation.js';
import { parseAdminHash, reservationSortParam, reservationsHref, stateFromQuery, UNASSIGNED_HREF } from '../admin/reservation-query.js';
import { cleanSearch, findQuickResults, resultHref, giftSearchTerm } from '../admin/quick-search.js';
import { NAV_TEXTS, navText, primeNavTexts, clearNavTextCache } from '../admin/nav-texts.js';
import { ICONS } from '../admin/icons.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');

test('päänavigaatio: Tilaukset heti Päivän jälkeen, Varaukset vain välilehtenä', () => {
  const js = src('admin/admin.js');
  assert.match(js, /path: '', label: 'Päivä'[\s\S]{0,100}path: 'tilaukset', label: 'Tilaukset', labelFn: \(\) => navText\('ui\.admin\.nav\.orders'\)/);
  assert.doesNotMatch(js, /path: 'varaukset', label:/);
  assert.match(src('admin/views/orders.js'), /\['reservations', 'ui\.admin\.nav\.reservations'\]/);
  assert.equal(NAV_TEXTS.fi['ui.admin.nav.reservations'], 'Varaukset');
  assert.match(src('admin/views/orders.js'), /orders-tab-\$\{key\}/);
  assert.match(src('admin/views/orders.js'), /createOrdersTab/);
  assert.equal(initialOrdersTab(), 'orders');
  assert.equal(initialOrdersTab({ query: new URLSearchParams('tab=reservations') }), 'reservations');
  assert.equal(initialOrdersTab({ legacyReservations: true }), 'reservations');
  assert.equal(initialOrdersTab({ canOrders: false }), 'reservations');
});

test('vanhat varauslinkit ja niiden parametrit ohjautuvat Varaukset-välilehteen', () => {
  for (const hash of ['#/varaukset', '#/varaukset?id=33', '#/varaukset?q=Virtanen&period=all', UNASSIGNED_HREF]) {
    const parsed = parseAdminHash(hash), resolved = resolveAdminPath(parsed.path);
    assert.deepEqual(resolved, { path: 'tilaukset', legacyReservations: true });
    assert.equal(initialOrdersTab({ legacyReservations: resolved.legacyReservations, query: parsed.query }), 'reservations');
  }
  assert.equal(stateFromQuery(parseAdminHash('#/varaukset?id=33&period=past&sort=newest').query).id, '33');
  assert.equal(reservationsHref({ id:'33', sort:'oldest', period:'past' }), '#/varaukset?period=past&sort=oldest&id=33');
  assert.equal(reservationsHref({ period:'upcoming', sort:'soon' }, 'tilaukset'), '#/tilaukset?period=upcoming&tab=reservations');
  // Tilaukset-reitin oletus on 'upcoming', joten Kaikki ajat näkyy osoitteessa; vanha #/varaukset ennallaan
  assert.equal(reservationsHref({ period:'all', sort:'soon' }, 'tilaukset'), '#/tilaukset?period=all&tab=reservations');
  assert.equal(reservationsHref({ period:'all', sort:'soon' }), '#/varaukset');
  assert.match(src('admin/views/talous.js'), /query\.get\('order'\)/);
});

test('varauslista näyttää tulevat lähin ensin ja tarjoaa palvelinpuoliset järjestykset', () => {
  assert.equal(reservationSortParam('soon'), 'start_asc');
  assert.equal(reservationSortParam('soon', 'upcoming'), 'start_asc');
  assert.equal(reservationSortParam('soon', 'custom'), 'start_asc');
  // Kaikki ajat ja menneet: ennallaan (null = palvelimen vanha järjestys, parametri jätetään pois)
  assert.equal(reservationSortParam('soon', 'all'), null);
  assert.equal(reservationSortParam('soon', 'past'), null);
  assert.equal(reservationSortParam('newest', 'all'), 'created_desc');
  assert.equal(reservationSortParam('newest'), 'created_desc');
  assert.equal(reservationSortParam('oldest'), 'created_asc');
  assert.equal(stateFromQuery(new URLSearchParams('sort=newest')).sort, 'newest');
  assert.equal(stateFromQuery(new URLSearchParams('sort=oldest')).sort, 'oldest');
  assert.equal(stateFromQuery(new URLSearchParams('sort=invalid')).sort, 'soon');
  const view = src('admin/views/reservations.js');
  assert.match(view, /const defaultPeriod = routePath === 'tilaukset' \? 'upcoming' : 'all'/);
  assert.match(view, /initialPeriod[\s\S]{0,170}defaultPeriod/);
  assert.match(view, /sortSet = seg\(navText\('ui\.admin\.nav\.sort_legend'\)/);
  assert.match(view, /if \(sortParam\) args\.p_sort = sortParam/);
  assert.doesNotMatch(view, /p_sort: reservationSortParam/);
  assert.match(view, /periodSet = seg\('Ajanjakso'/);
  assert.match(view, /p_reservation_id/);
  assert.match(src('supabase/migrations/20261024110000_booking_138_reservations_nav.sql'), /case when p_sort = 'start_asc' then r.starts_at end asc/);
  assert.match(src('supabase/migrations/20261024110000_booking_138_reservations_nav.sql'), /limit least\(greatest\(p_limit, 1\), 500\) offset/);
});

test('mobiilipalkin nuoli laajentaa, pienentää ja päivittää aria-expanded-tilan', () => {
  const names = new Set();
  const shell = { classList: { toggle(name,on) { if(on) names.add(name); else names.delete(name); } } };
  const attrs = new Map([['aria-expanded','false']]);
  const btn = { getAttribute:k=>attrs.get(k), setAttribute:(k,v)=>attrs.set(k,v) };
  assert.equal(toggleMobileNav(shell,btn),true);
  assert.equal(attrs.get('aria-expanded'),'true');
  assert.equal(names.has('nav-expanded'),true);
  assert.equal(toggleMobileNav(shell,btn),false);
  assert.equal(attrs.get('aria-expanded'),'false');
  assert.equal(names.has('nav-expanded'),false);
  const html = src('admin/index.html'), css = src('admin/admin.css');
  assert.match(html, /id="nav-toggle"[^>]*aria-expanded="false"/);
  assert.match(css, /@media\(max-width:899px\)/);
  assert.match(css, /#shell \.nav \.lbl\{display:none\}/);
  assert.match(css, /#shell\.nav-expanded \.nav \.lbl\{display:inline\}/);
  assert.match(css, /#shell \.nav\{position:fixed;top:56px;left:0;right:auto;bottom:0/);
});

test('pikahaku löytää asiakkaita, varauksia, tilauksia, lahjakortteja ja luo suorat linkit', async () => {
  const calls=[];
  const fake = async (fn,args) => {
    calls.push({ fn,args });
    if(fn==='admin_list_customers') return [{ id:42, name:'Mäkelä', email:'ma@example.fi' }];
    if(fn==='admin_list_reservations') return [{ reservation_id:12,order_no:13025,customer_name:'Mäkelä',product_name:'Sauna' }];
    if(fn==='admin_list_orders') return { rows:[{order_no:13025,customer_name:'Mäkelä'}] };
    if(fn==='admin_list_gift_cards') return { rows:[{code:'ABCD-1234-EFGH',recipient_name:'Maija'}] };
    throw Error('Odottamaton RPC');
  };
  const found=await findQuickResults(fake,{can:()=>true},'#13025');
  assert.equal(cleanSearch(' #13025 '),'13025');
  assert.deepEqual(new Set(found.map(x=>x.href)),new Set([
    '#/asiakkaat?id=42','#/varaukset?id=12&q=13025&period=all',
    '#/tilaukset?order=13025','#/talous?tab=giftcards&code=ABCD-1234-EFGH',
  ]));
  assert.ok(calls.some(c=>c.fn==='admin_list_orders'&&c.args.p_payment_filter==='all'));
  assert.equal(resultHref('unknown',{}),'#/');
  assert.equal((await findQuickResults(fake,{can:()=>true},'a')).length,0);
});

test('pikahaku noudattaa oikeuksia ja yhden RPC:n virhe ei estä muita', async () => {
  const called=[];
  const found=await findQuickResults(async (fn)=>{
    called.push(fn);
    if(fn==='admin_list_reservations') throw new Error('Yhteysvirhe');
    return [{id:7,name:'Virtanen'}];
  },{can:()=>false},'Virtanen');
  assert.deepEqual(called,['admin_list_customers','admin_list_reservations']);
  assert.equal(found[0].href,'#/asiakkaat?id=7');
});

test('yläpalkin pikatoiminnot, käyttäjävalikko, kokeilutila ja uloskirjautuminen', () => {
  const html=src('admin/index.html'), js=src('admin/admin.js'), css=src('admin/admin.css');
  for(const id of ['quick-search-input','quick-search-results','quick-new','quick-review','user-menu-toggle','user-dropdown','user-email','user-role-full','who','logout']) {
    assert.match(html,new RegExp(`id="${id}"`));
  }
  assert.match(html,/id="quick-new"[^>]*href="#\/uusi"/);
  assert.match(html,/id="quick-review"[^>]*href="#\/tarkista"/);
  assert.match(html,/href="\.\.\/varaa\/"/);
  assert.match(js,/setupQuickSearch\(/);
  assert.match(js,/\$\('logout'\)\.addEventListener\('click'/);
  assert.match(js,/MOCK \? 'Kokeilutila: esimerkkidata, mikään ei tallennu'/);
  assert.match(css,/\.user-dropdown/);
  const label=compactIdentity('joonas.vaarala@example.fi','Ylläpitäjä');
  assert.deepEqual(label,{name:'Joonas',initial:'J',role:'Ylläpitäjä'});
});

test('tekstit: ui.admin.nav.* FI+EN sanakirjassa ja pending-import-38:ssa, ei päällekkäin muiden tuontien kanssa', async () => {
  const { readdirSync } = await import('node:fs');
  const rows = JSON.parse(readFileSync(join(root, '../content/site-texts.pending-import-38.json'), 'utf8'));
  assert.deepEqual(Object.keys(NAV_TEXTS.fi).sort(), Object.keys(NAV_TEXTS.en).sort());
  assert.equal(rows.length, Object.keys(NAV_TEXTS.fi).length * 2);
  for (const r of rows) {
    assert.ok(r.key.startsWith('ui.admin.nav.'), r.key);
    assert.equal(r.text, NAV_TEXTS[r.lang][r.key], r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.ok(r.max_len >= r.text.length && r.max_len >= 80, r.key);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((m) => m[0]), r.key);
  }
  const taken = new Set();
  for (const f of readdirSync(join(root, '../content'))) {
    if (!/^site-texts\.(pending-import-(?!38\.)|imported|fallback)/.test(f) || !f.endsWith('.json')) continue;
    const j = JSON.parse(readFileSync(join(root, '../content', f), 'utf8'));
    for (const r of Array.isArray(j) ? j : j.texts || []) taken.add(`${r.key}|${r.lang}`);
  }
  for (const r of rows) assert.equal(taken.has(`${r.key}|${r.lang}`), false, `${r.key} on jo toisessa tuonnissa`);
  // tietokannan rivi peittää oletuksen; puuttuva paikkamerkki → oletus
  primeNavTexts([{ key: 'ui.admin.nav.orders', lang: 'fi', text: 'Tilaukset (kanta)' }, { key: 'ui.admin.nav.role', lang: 'fi', text: 'Rooli {{var:x}}' }]);
  assert.equal(navText('ui.admin.nav.orders', null, 'fi'), 'Tilaukset (kanta)');
  assert.equal(navText('ui.admin.nav.role', { role: 'Esimies' }, 'fi'), 'Rooli: Esimies');
  clearNavTextCache();
  assert.equal(navText('ui.admin.nav.orders', null, 'en'), 'Orders');
  for (const f of ['admin/quick-search.js', 'admin/views/orders.js', 'admin/admin-navigation.js']) {
    assert.doesNotMatch(src(f), /'(Haetaan…|Ei hakutuloksia\.|Ladataan…|Pienennä valikko|Laajenna valikko|Tilaukset ja varaukset)'/, f);
  }
  assert.match(src('../scripts/build-pages.mjs'), /'nav-texts\.js', 'admin-navigation\.js', 'quick-search\.js', 'views\/orders\.js'/);
});

test('ulkoasu: uusi yläpalkki/sivupalkki käyttää vain teeman värejä ja SVG-ikoneita, ei glyfejä eikä emojeja', () => {
  const css = src('admin/admin.css');
  const block = css.slice(css.indexOf('/* Hallinnan navigaatio ja yläpalkki (paketti 05)'));
  assert.ok(block.length > 1000);
  const hex = [...block.matchAll(/#[0-9a-fA-F]{3,8}\b/g)].map((m) => m[0].toUpperCase());
  for (const c of hex) assert.ok(['#FFF', '#2B3A30', '#F4EFE7', '#7A5530', '#EDE3D0'].includes(c), `vieras väri ${c}`);
  assert.doesNotMatch(block, /blue|#00f|rgb\(0, ?0, ?255\)/i);
  assert.match(block, /--navh:0px/);
  const html = src('admin/index.html');
  const header = html.slice(html.indexOf('<header class="top">'), html.indexOf('<main id="view"'));
  assert.doesNotMatch(header, /[⌕✓›⌄↗]|\p{Extended_Pictographic}/u);
  for (const name of [...header.matchAll(/data-icon="([a-z]+)"/g)].map((m) => m[1])) assert.ok(ICONS[name], name);
  assert.ok(ICONS.search && ICONS.external);
  assert.match(src('admin/admin.js'), /querySelectorAll\('#shell \[data-icon\]'\)/);
});

test('pikahaku: lahjakorttikoodi normalisoidaan, nimihaku ei', () => {
  assert.equal(giftSearchTerm('abcd-1234-efgh'), 'ABCD1234EFGH');
  assert.equal(giftSearchTerm('Maija Mäkelä'), 'Maija Mäkelä');
  assert.equal(giftSearchTerm('Virtanen'), 'Virtanen');
});

test('PG-testi ja rollback booking_138: tiedostot olemassa, rollback palauttaa booking_72-version', () => {
  const mig = src('supabase/migrations/20261024110000_booking_138_reservations_nav.sql');
  const rb = src('supabase/rollbacks/20261024110000_booking_138_ROLLBACK.sql');
  assert.match(mig, /p_sort text default null,\s+p_reservation_id bigint default null/);
  assert.match(mig, /revoke all on function booking\.admin_list_reservations[\s\S]{0,200}from public, anon/);
  assert.doesNotMatch(mig, /(insert into|update|delete from|alter table|create table) public\./i);
  assert.match(rb, /drop function if exists booking\.admin_list_reservations\(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean, text, bigint\)/);
  assert.match(rb, /p_option_missing boolean default null\)/);
  assert.match(src('supabase/tests/hallinta/t138_reservations_nav.sql'), /TESTRESULT pass=% fail=%/);
});
