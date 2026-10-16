// Paikallinen savutesti Pages-koosteelle alipolulla (ei kosketa oikeaan Supabaseen: kaikki *.supabase.co-pyynnöt vastataan mockilla).
//   1) SITE_ENV=test SITE_URL=https://joonasvaarala.github.io/saunotus-uusi BOOKING_SUPABASE_URL=https://<ref>.supabase.co BOOKING_ANON_KEY=… DIST=/tmp/dist node scripts/build-pages.mjs
//   2) mkdir /tmp/site && ln -s /tmp/dist /tmp/site/saunotus-uusi && (cd /tmp/site && python3 -m http.server 4190 --bind 127.0.0.1 &)
//   3) PW_DIR=/polku/node_modules node scripts/smoke-pages.mjs        (BASE_URL oletus http://127.0.0.1:4190/saunotus-uusi, CHROME oletus /usr/bin/google-chrome)
// Tarkistaa: sivut/skriptit/tyylit/importit latautuvat alipolulta (ei 404, ei konsolivirheitä), noindex, hallinnan kirjautumisnäkymä,
// kutsulinkin (#access_token…&type=invite) hyväksyntä ja salasanan asetus polussa /hallinta/, versiotunnus moduuleissa sekä näkymämoduulin latauksen uusinta (retry) ja virhenäkymä.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', dirname(fileURLToPath(import.meta.url))].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const BASE = (process.env.BASE_URL || 'http://127.0.0.1:4190/saunotus-uusi').replace(/\/$/, '');
const problems = [];
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const fakeJwt = (claims) => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64(claims)}.${Buffer.from('x').toString('base64url')}`;
const calls = [];
const periodArgs = [];   // admin_list_reservations: [p_from, p_to] kutsuittain
const resArgs = [];   // admin_create_resource_booking / admin_create_old_booking: [rpc, args]
let expect400 = false;   // resurssivarauksen BK001-virhetesti: selaimen 400-konsoliviesti on odotettu
let dropPerms = [];   // oikeudet jotka poistetaan admin_my_permissions-mockista (oikeuspiilotustesti)
const ovrArgs = [];   // admin_set_closure_override-kutsut
let extraPerms = [];   // lisäoikeudet admin_my_permissions-mockiin (bookings.override-testi)
const srcArgs = [];   // admin_list_reservations: p_source-arvot kutsuittain

async function newPage(name, { allowFail = null, viewport = { width: 1100, height: 800 }, mobile = false } = {}) {
  const ctx = await browser.newContext({ viewport, isMobile: mobile, hasTouch: mobile, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  // allowFail: tarkoituksella epäonnistutetut moduulipyynnöt (retry-testit) eivät ole ongelmia; muut konsolivirheet ovat
  const expected = (t) => allowFail && allowFail.test(t);
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !expected(m.text()) && !(expect400 && /status of 400/.test(m.text())) && !(allowFail && /Näkymän .* lataus epäonnistui|Failed to load resource|Failed to fetch dynamically imported module/.test(m.text()))) problems.push(`${name} console.${m.type()}: ${m.text()}`); });
  page.on('requestfailed', (r) => { if (!expected(r.url())) problems.push(`${name} requestfailed: ${r.url()} ${r.failure()?.errorText}`); });
  page.on('response', (r) => { if (r.status() >= 400 && r.url().startsWith(BASE.split('/').slice(0, 3).join('/'))) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  // Supabase-mock: ei yhteyttä oikeaan projektiin
  await page.route(/\.supabase\.co\//, (route) => {
    const u = new URL(route.request().url()), m = route.request().method();
    calls.push(`${m} ${u.pathname}`);
    const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' }, body: JSON.stringify(body) });
    if (m === 'OPTIONS') return json({});
    if (u.pathname === '/auth/v1/user' && m === 'PUT') return json({ id: 'u1', email: 'kutsuttu@example.com' });
    if (u.pathname.endsWith('/rpc/current_staff_role')) return json('staff');
    if (u.pathname.endsWith('/rpc/admin_my_permissions')) return json({ role: 'staff', role_label: 'Peruskäyttäjä', permissions: ['bookings.manage', 'blocks.manage', 'shifts.view', 'customers.manage', 'catalog.edit', ...extraPerms].filter((x) => !dropPerms.includes(x)) });
    if (u.pathname.endsWith('/rpc/admin_upcoming_shifts')) {   // tuotannon kaltaiset englanninkieliset koodit; hallinnan pitää näyttää suomeksi
      const ds = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
      const row = (id, from, to, role, cal, st, who) => ({ shift_id: id, starts_at: `${ds}T${from}:00Z`, ends_at: `${ds}T${to}:00Z`, role_type: role, calendar_name: cal, staffing_status: st, staff_name: who });
      return json([row('s1', '06:00', '11:00', 'heater', 'Lämmitykset', 'assigned', 'Otto'), row('s2', '11:00', '16:00', 'reception', 'Vastaanotto', 'assigned', 'Otto'), row('s3', '11:00', '17:00', 'therapist', 'Hoitaja', 'assigned', 'Joonas'), row('s4', '12:00', '15:00', 'sauna_x', 'Hoitaja', 'unassigned', null), row('s5', '16:00', '18:00', 'therapist', 'Hoitaja', 'partial', 'Matti')]);
    }
    if (u.pathname.endsWith('/rpc/public_product_images')) return json([{ product_id: 1, slug: 'yleinen', path: 'products/1-smoke01.png', alt: null }]);   // migraatio 19: vain tuotteella 1 on kuva
    if (u.pathname.startsWith('/storage/v1/object/public/product-images/')) return route.fulfill({ status: 200, contentType: 'image/png', headers: { 'access-control-allow-origin': '*' }, body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64') });
    if (u.pathname.endsWith('/rpc/public_catalog')) return json([
      { id: 1, slug: 'yleinen', name: 'Yleinen vuoro', name_en: 'Public session', description: 'x', description_en: 'x', category: 'sauna', sale_kind: 'public_shift', price: 29, price_type: 'per_person', min_persons: 1, max_persons: 10 },
      { id: 3, slug: 'taynna', name: 'Täysi tuote', name_en: 'Fully booked product', description: 'x', description_en: 'x', category: 'sauna', sale_kind: 'public_shift', price: 40, price_type: 'per_person', min_persons: 1, max_persons: 10 },
      { id: 2, slug: 'oma', name: 'Oma saunavuoro', name_en: 'Private sauna', description: 'x', description_en: 'x', category: 'sauna', sale_kind: 'private_shift', price: 250, price_type: 'from', min_persons: 1, max_persons: 20 }]);
    if (u.pathname.endsWith('/rpc/public_availability')) {   // parittomina kuukauden päivinä vuoroja, parillisina ei yhtään (tyhjä päivä)
      const a = route.request().postDataJSON() || {}, rows = [];
      for (let d = new Date(`${a.p_from}T12:00:00Z`); d <= new Date(`${a.p_to}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + 1)) {
        const ds = d.toISOString().slice(0, 10); if (+ds.slice(8) % 2 === 0) continue;
        const mk = (rule, hh, mm, label, mode, status) => ({ rule_id: rule, label, mode, session_date: ds, starts_at: `${ds}T${String(hh - 3).padStart(2, '0')}:${mm}:00Z`, ends_at: `${ds}T${String(hh - 2).padStart(2, '0')}:${mm}:00Z`, status, remaining: status === 'available' ? 6 : 0, min_persons: 1, max_persons: 10, price_mode: a.p_product_id === 1 ? 'per_person' : 'base_plus_extra', unit_price: 29, base_price: 250, included_persons: 4, extra_person_price: 20 });
        if (a.p_product_id === 1) rows.push(mk(11, 18, '00', 'Yleinen vuoro', 'public', 'available'), mk(10, 14, '00', 'Yleinen vuoro', 'public', 'available'), mk(12, 16, '00', 'Yleinen vuoro', 'public', 'full'));
        else if (a.p_product_id === 3) rows.push(mk(31, 15, '00', 'Täysi', 'public', 'full'));
        else rows.push(mk(21, 13, '00', 'Oma saunavuoro', 'private', 'unavailable'), mk(22, 20, '00', 'Oma saunavuoro', 'private', 'available'));
      }
      return json(rows);
    }
    if (u.pathname.endsWith('/rpc/admin_list_reservations')) {   // migraatio 12: source/external_id + p_source-suodatin (null = kaikki, 'johku' | 'native')
      const a = route.request().postDataJSON() || {}; srcArgs.push(a.p_source ?? null); periodArgs.push([a.p_from ?? null, a.p_to ?? null]);
      const ds = new Date(Date.now() + 2 * 864e5).toISOString().slice(0, 10);
      const mk = (id, name, src, ext) => ({ reservation_id: id, order_id: id, order_no: 9000 + id, status: 'confirmed', order_status: 'confirmed', payment_status: 'paid', product_id: 1, product_name: 'Yleinen vuoro', mode: 'public', starts_at: `${ds}T14:00:00Z`, ends_at: `${ds}T16:00:00Z`, persons: 2, total_gross: 58, customer_id: id, customer_name: name, customer_email: `${id}@example.com`, customer_phone: '0401234567', source_channel: src === 'johku' ? 'johku_import' : 'web', created_at: `${ds}T08:00:00Z`, hold_expires_at: null, notes: null, annual_card_id: null, total_count: 2, source: src, external_id: ext });
      return json([mk(1, 'Uusi Asiakas', 'native', null), mk(2, 'Johku Asiakas', 'johku', 'J-48213')].map((r) => (r.reservation_id === 2 ? { ...r, space_code: 'rauni', lifecycle: 'old' } : r)).filter((r) => !a.p_source || r.source === a.p_source));
    }
    if (u.pathname.endsWith('/rpc/admin_review_list')) {   // migraatio 17c: neljä osiota
      const ds = new Date(Date.now() + 3 * 864e5).toISOString().slice(0, 10);
      return json({ therapist_conflicts: [{ reservation_id: 51, starts_at: `${ds}T12:00:00Z`, ends_at: `${ds}T13:00:00Z`, skill: 'yleinen' }], block_conflicts: [], overrides: [{ reservation_id: 52, starts_at: `${ds}T13:00:00Z`, reason: 'Sovittu asiakkaan kanssa' }], orphan_addons: [] });
    }
    if (u.pathname.endsWith('/rpc/admin_list_products')) {   // resurssituotteet (migraatiot 14–15): hoito (nykyinen) ja vanha hoito
      const cfg = (o) => ({ resource_class: 'resourced', min_persons: 1, max_persons: 2, duration_minutes: 60, ...o });
      return json([{ id: 41, name: 'Hoito (nykyinen)', category: 'hoito', active: true, price: 90, config: cfg({ lifecycle: 'current', sale_kind: 'other' }) },
        { id: 42, name: 'Vanha hoito', category: 'hoito', active: true, price: 80, config: cfg({ lifecycle: 'old', sale_kind: 'other' }) }]);
    }
    if (u.pathname.endsWith('/rest/v1/product_space_rules')) return json([{ product_id: 41, leg_no: 1, priority: 1, space_id: 1, mode: 'exclusive', min_persons: 1, max_persons: 2, selection: 'auto', active: true }, { product_id: 42, leg_no: 1, priority: 1, space_id: 1, mode: 'exclusive', min_persons: 1, max_persons: 2, selection: 'auto', active: true }]);
    if (u.pathname.endsWith('/rest/v1/resources')) return json([{ id: 1, code: 'rauni', name: 'Hoitosauna Rauni' }, { id: 2, code: 'lovi', name: 'Hoitosauna Lovi' }]);
    if (u.pathname.endsWith('/rest/v1/payment_methods')) return json([{ code: 'pay_later', label: 'Maksetaan paikalla', is_manual: true, active: true }]);
    if (/\/rpc\/admin_create_(resource|old)_booking$/.test(u.pathname)) {   // BK001: koodi DETAIL-kentässä (PostgREST: details)
      resArgs.push([u.pathname.split('/').pop(), route.request().postDataJSON()]);
      return json({ code: 'BK001', message: 'Tila varattu (palvelimen viesti)', details: 'space_busy', hint: null }, 400);
    }
    if (u.pathname.endsWith('/rpc/admin_closure_overview')) {   // migraatio 18b: kalenterit, tapahtumat, konfliktit, ajot
      const ds = (n) => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);
      return json({ calendars: [{ code: 'hoidot', name: '1 hoidot kiinni', resource_code: 'saunottaja', active: true, configured: true, last_success_at: `${ds(0)}T08:00:00Z`, last_attempt_at: `${ds(0)}T08:00:00Z`, last_error: null, consecutive_failures: 0, last_stats: { events_seen: 4, candidates: 2 } },
          { code: 'rauni', name: '1 Rauni kiinni', resource_code: 'rauni', active: false, configured: false, last_success_at: null, last_attempt_at: null, last_error: null, consecutive_failures: 0, last_stats: null }],
        events: [{ id: 71, calendar_code: 'hoidot', class: 'closure', reason: 'Hoidot kiinni', all_day: false, starts_at: `${ds(3)}T09:00:00Z`, ends_at: `${ds(3)}T12:00:00Z`, override: null, override_note: null, effective_block: true },
          { id: 72, calendar_code: 'hoidot', class: 'rough', reason: 'Pitkä jakso', all_day: false, starts_at: `${ds(5)}T09:00:00Z`, ends_at: `${ds(9)}T12:00:00Z`, override: null, override_note: null, effective_block: false }],
        conflicts: [{ reservation_id: 5, leg_id: 1, resource_id: 1, block_id: 3, starts_at: `${ds(3)}T10:00:00Z` }],
        runs: [{ calendar_code: 'hoidot', started_at: `${ds(0)}T08:00:00Z`, outcome: 'ok', error: null, stats: { events_seen: 4, candidates: 2 } }, { calendar_code: 'hoidot', started_at: `${ds(-1)}T08:00:00Z`, outcome: 'error', error: 'API 503', stats: null }] });
    }
    if (u.pathname.endsWith('/rpc/admin_set_closure_override')) { ovrArgs.push(route.request().postDataJSON()); return json({ ok: true, blocks_inserted: 0, blocks_updated: 0, blocks_deleted: 1 }); }
    if (u.pathname.endsWith('/rpc/admin_day_view')) {   // Uusi varaus -näkymän vuorolista: 8 vapaata vuoroa, jotta varauslomake jää aluksi ruudun alapuolelle
      const a = route.request().postDataJSON() || {}, ds = a.p_date;
      return json({ date: ds, blocks: [], reservations: [], sessions: [10, 11, 12, 13, 14, 15, 16, 17].map((h) => ({ rule_id: h, product_id: 1, label: 'Yleinen vuoro', mode: 'public', status: 'available', remaining: 6, min_persons: 1, max_persons: 10, price_mode: 'per_person', unit_price: 29, starts_at: `${ds}T${String(h - 3).padStart(2, '0')}:00:00Z`, ends_at: `${ds}T${String(h - 2).padStart(2, '0')}:00:00Z` })) });
    }
    if (u.pathname.includes('/rpc/public_settings')) return json({ public_booking_enabled: true });
    if (u.pathname.includes('/rpc/')) return json([]);
    return json([]);
  });
  return page;
}

// 1) perussivu, kauppa (FI + EN)
for (const p of ['/', '/en/', '/varaa/', '/en/book/']) {
  const page = await newPage(`sivu ${p}`);
  const r = await page.goto(`${BASE}${p}`);
  if (r.status() !== 200) problems.push(`${p}: HTTP ${r.status()}`);
  if ((await page.locator('meta[name=robots][content*=noindex]').count()) < 1) problems.push(`${p}: noindex puuttuu`);
  if (p.includes('varaa') || p.includes('book')) { await page.waitForSelector('#booking-app', { state: 'attached' }); await page.waitForTimeout(800); if ((await page.evaluate(() => window.BOOKING_CONFIG?.url || '')).length < 10) problems.push(`${p}: BOOKING_CONFIG.url puuttuu`); }
  await page.context().close();
}
// 2) hallinta: kirjautumisnäkymä
{
  const page = await newPage('hallinta');
  const reqs = []; page.on('request', (r) => reqs.push(r.url()));
  await page.goto(`${BASE}/hallinta/`);
  await page.waitForSelector('form#login:visible');
  const mods = reqs.filter((u) => /\/hallinta\/[^?]*\.js(\?|$)/.test(u) && !u.includes('config.js'));
  if (!mods.length || mods.some((u) => !/\?v=/.test(u))) problems.push(`hallinta: moduulit ilman versiotunnusta: ${mods.filter((u) => !/\?v=/.test(u)).join(', ')}`);
  if (!mods.some((u) => /\/hallinta\/icons\.js\?v=/.test(u))) problems.push('hallinta: icons.js ei latautunut versioituna');
  if (reqs.filter((u) => /\/hallinta\/sb\.js/.test(u)).length !== 1) problems.push('hallinta: sb.js ladattu useammin kuin kerran (moduuli-instanssit eroavat)');
  if ((await page.locator('meta[name=robots][content*=noindex]').count()) < 1) problems.push('hallinta: noindex puuttuu');
  if (!(await page.evaluate(() => window.BOOKING_CONFIG?.url?.endsWith('.supabase.co')))) problems.push('hallinta: config.js ei osoita Supabaseen');
  await page.context().close();
}
// 2b) kauppa: Selaa päivän mukaan (#/paiva/<pvm>) – versio 13
for (const [base, L] of [['/varaa/', { cat: 'Selaa kategorioittain', day: 'Selaa päivän mukaan', empty: 'Ei vapaita vuoroja valitulle päivälle', y: 'Yleiset vuorot', o: 'Yksityisvuorot' }], ['/en/book/', { cat: 'Browse by category', day: 'Browse by date', empty: 'No available sessions for the selected date', y: 'Public sessions', o: 'Private sessions' }]]) {
  const page = await newPage(`päivänäkymä ${base}`);
  const dates = []; for (let i = 1; dates.length < 2 && i < 12; i++) { const d = new Date(Date.now() + i * 864e5).toISOString().slice(0, 10); const odd = +d.slice(8) % 2 === 1; if (odd === (dates.length === 0)) dates.push(d); }
  const [oddDay, evenDay] = dates;
  const avail = []; page.on('request', (r) => { if (r.url().includes('public_availability')) avail.push(r.postDataJSON()); });
  await page.goto(`${BASE}${base}`);
  await page.waitForSelector('.bk-cards');
  if (!(await page.locator('.bk-modes a[aria-current]').innerText()).toLowerCase().includes(L.cat.toLowerCase())) problems.push(`${base}: oletustilan pitää olla "${L.cat}"`);
  await page.goto(`${BASE}${base}#/paiva/${oddDay}`);
  await page.waitForSelector('.bk-strip');
  await page.waitForSelector('.bk-dayresults .bk-pc');
  const txt = (await page.locator('.bk-dayresults').innerText()).replace(/\n/g, ' ');
  const tl = txt.toLowerCase();
  if (!tl.includes(L.y.toLowerCase()) || !tl.includes(L.o.toLowerCase())) problems.push(`${base}: päivänäkymän ryhmät puuttuvat: ${txt.slice(0, 120)}`);
  // v14: vain saatavilla olevat tuotteet (täysi tuote pois), kortit suljettuina, ajat vasta avattaessa
  if ((await page.locator('.bk-dayresults .bk-pc').count()) !== 2) problems.push(`${base}: päivällä pitäisi olla 2 tuotekorttia (täysi tuote pois), nyt ${await page.locator('.bk-dayresults .bk-pc').count()}`);
  if (/Täysi tuote|Fully booked product/.test(txt)) problems.push(`${base}: täyttä tuotetta ei saa näyttää`);
  if ((await page.locator('.bk-dayresults .bk-slot:visible').count()) !== 0 || (await page.locator('.bk-pc-head[aria-expanded=true]').count()) !== 0) problems.push(`${base}: kortit pitää olla oletuksena suljettuina eikä vuoroja näkyvissä`);
  if (/\[object/.test(txt) || !/\d+ (aikaa|aika|times?) (vapaana|available)/.test(txt)) problems.push(`${base}: tuotekortin tiivistelmä puuttuu: ${txt.slice(0, 200)}`);
  if (avail.length < 3 || new Set(avail.map((a) => a.p_product_id)).size !== 3) problems.push(`${base}: kaikille tuotteille pitäisi kutsua public_availability (${avail.length} kutsua)`);
  const n0 = avail.length;
  await page.locator('.bk-pc[data-slug=yleinen] .bk-pc-head').click();
  await page.waitForSelector('.bk-pc.open .bk-slot:visible');
  const times = await page.locator('.bk-pc.open .bk-time').allInnerTexts();
  const openTxt = await page.locator('.bk-pc.open').innerText();
  if (times.length !== 3 || !/täynnä|full/i.test(openTxt)) problems.push(`${base}: avatussa kortissa pitäisi olla 3 vuoroa (täynnä mukana), nyt ${times.length}`);
  if (!page.url().endsWith('?tuote=yleinen')) problems.push(`${base}: avattu tuote ei näy URL:ssa: ${page.url()}`);
  await page.goto(`${BASE}${base}#/paiva/${oddDay}?tuote=oma`);   // syväosoite: oikea kortti auki
  await page.waitForSelector('.bk-pc[data-slug=oma].open .bk-slot:visible');
  if ((await page.locator('.bk-pc.open').count()) !== 1 || !/ei varattavissa|not available/i.test(await page.locator('.bk-pc.open').innerText())) problems.push(`${base}: ?tuote=oma pitää avata vain oma-kortti (ei varattavissa -tila mukana)`);
  const href = await page.locator('.bk-pc.open .bk-slot.available a.btn').first().getAttribute('href');
  if (!/#\/varaa\/\d+\/\d{4}-\d\d-\d\d\/\d+\?via=day$/.test(href)) problems.push(`${base}: Valitse-linkki väärä: ${href}`);
  await page.locator('.bk-pc.open .bk-slot.available a.btn').first().click();
  await page.waitForSelector('form.bk-form');
  const back = await page.locator('#booking-app .bk-pick a.bk-pick-change').getAttribute('href');
  if (!back.endsWith(`#/paiva/${oddDay}?tuote=oma`)) problems.push(`${base}: "Vaihda päivää tai aikaa" -linkin pitää palata päivään ja tuotteeseen: ${back}`);
  {   // v16: yhteenveto otsikon alla: tuotteen nimi, päivä, kellonaika; ei erillistä Takaisin-linkkiä
    const pk = await page.evaluate(() => ({ name: document.querySelector('.bk-pick-name')?.textContent, when: document.querySelector('.bk-pick-when')?.textContent, next: document.querySelector('#booking-app h2')?.nextElementSibling?.className, links: document.querySelectorAll('#booking-app > p a, #booking-app .bk-pick a').length }));
    if (!pk.name || !(base.includes('/en/') ? /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun),? \d{1,2} [A-Z][a-z]{2} \d{4} · \d{2}:\d{2}–\d{2}:\d{2}$/ : /^(ma|ti|ke|to|pe|la|su) \d{1,2}\.\d{1,2}\.\d{4}, klo \d{2}:\d{2}–\d{2}:\d{2}$/).test(pk.when || '') || pk.next !== 'bk-pick' || pk.links !== 1) problems.push(`${base}: varauslomakkeen yhteenveto (tuote, päivä, aika) puuttuu tai väärä: ${JSON.stringify(pk)}`);
  }
  await page.click('#booking-app .bk-pick a.bk-pick-change'); await page.waitForSelector('.bk-pc[data-slug=oma].open');
  await page.goto(`${BASE}${base}#/paiva/${evenDay}`);
  await page.waitForSelector('.bk-dayresults .bk-notice');
  const e = await page.locator('.bk-dayresults .bk-notice').innerText();
  if (!e.toLowerCase().includes(L.empty.toLowerCase()) || (await page.locator('.bk-dayresults .bk-notice a').count()) !== 1) problems.push(`${base}: tyhjän päivän ilmoitus/ehdotus puuttuu: ${e}`);
  if (avail.length !== n0) problems.push(`${base}: päivänvaihto samassa kuussa ei saa kutsua palvelinta uudelleen (${avail.length - n0} uutta kutsua)`);
  await page.click('.bk-dayresults .bk-notice a'); await page.waitForSelector('.bk-dayresults .bk-pc');
  // olemassa olevat reitit toimivat: tuotelista ja #/tuote/<slug>/<pvm>
  await page.goto(`${BASE}${base}#/tuote/yleinen/${oddDay}`);
  await page.waitForSelector('.bk-grid');
  await page.goto(`${BASE}${base}#/`); await page.waitForSelector('.bk-cards');
  {   // v15: tuotekuvat – listakortti vain kuvalliselle tuotteelle, hero = tuotteen kuva + nimi + tiivis kuvaus (kuvaton: oletushero), kuvan virhe → oletushero
    if ((await page.locator('.bk-card .card-img img').count()) !== 1) problems.push(`${base}: tuotelistassa pitäisi olla tasan yksi kuvakortti`);
    const heroOf = () => page.evaluate(() => { const el = document.querySelector('main .hero.page'); return { cls: el.className, h1: el.querySelector('h1').textContent, sub: el.querySelector('.in p')?.textContent || '', src: el.querySelector('picture img').getAttribute('src'), h1n: document.querySelectorAll('h1').length }; });
    const def = await heroOf();
    await page.goto(`${BASE}${base}#/tuote/yleinen`); await page.waitForSelector('.bk-prod');
    await page.waitForSelector('main .hero.page.has-prod');
    const h1 = await heroOf();
    if (!/product-images\/products\/1-smoke01\.png$/.test(h1.src) || !/^(Yleinen vuoro|Public session)$/.test(h1.h1) || h1.h1n !== 1 || h1.sub !== 'x') problems.push(`${base}: tuotesivun hero väärin: ${JSON.stringify(h1)}`);
    await page.goto(`${BASE}${base}#/tuote/oma`); await page.waitForSelector('.bk-prod');
    await page.waitForFunction(() => !document.querySelector('main .hero.page.has-prod'));
    const h2 = await heroOf();
    if (h2.src !== def.src || !/^(Oma saunavuoro|Private sauna)$/.test(h2.h1)) problems.push(`${base}: kuvattoman tuotteen hero väärin: ${JSON.stringify(h2)}`);
    await page.goto(`${BASE}${base}#/`); await page.waitForFunction(() => document.querySelector('main .hero.page h1').textContent !== 'Oma saunavuoro' && document.querySelector('main .hero.page h1').textContent !== 'Private sauna');
    const h3 = await heroOf();
    if (h3.h1 !== def.h1 || h3.cls.includes('has-prod')) problems.push(`${base}: listanäkymän hero ei palautunut oletukseksi: ${JSON.stringify(h3)}`);
  }
  await page.context().close();
}
async function loginViaInvite(page) {
  const jwt = fakeJwt({ sub: '00000000-0000-4000-8000-0000000000e9', email: 'kutsuttu@example.com', role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 });
  await page.goto(`${BASE}/hallinta/#access_token=${jwt}&refresh_token=r&expires_in=3600&token_type=bearer&type=invite`);
  await page.waitForSelector('#setpw-screen:not([hidden])');
  await page.fill('#pw1', 'pitkasalasana1'); await page.fill('#pw2', 'pitkasalasana1'); await page.click('#setpw button[type=submit]');
  await page.waitForSelector('#shell:not([hidden]) #nav a');
}
// 3) kutsulinkki alipolulla: istunto otetaan käyttöön, tokenit siivotaan osoiteriviltä, salasana asetetaan, siirrytään hallintaan
{
  const page = await newPage('kutsu');
  const jwt = fakeJwt({ sub: '00000000-0000-4000-8000-0000000000e9', email: 'kutsuttu@example.com', role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 });
  await page.goto(`${BASE}/hallinta/#access_token=${jwt}&refresh_token=r&expires_in=3600&token_type=bearer&type=invite`);
  await page.waitForSelector('#setpw-screen:not([hidden])');
  if (page.url().includes('access_token')) problems.push('kutsu: tokenit jäivät osoiteriville');
  if (!page.url().includes('/saunotus-uusi/hallinta/')) problems.push(`kutsu: polku muuttui: ${page.url()}`);
  await page.fill('#pw1', 'lyhyt'); await page.fill('#pw2', 'lyhyt'); await page.click('#setpw button[type=submit]');
  await page.waitForSelector('#setpw-err:not([hidden])');
  await page.fill('#pw1', 'pitkasalasana1'); await page.fill('#pw2', 'pitkasalasana1'); await page.click('#setpw button[type=submit]');
  await page.waitForSelector('#shell:not([hidden]) #nav a');
  if (!calls.some((c) => c === 'PUT /auth/v1/user')) problems.push('kutsu: salasanan asetuskutsua (PUT /auth/v1/user) ei tehty');
  for (const r of ['kalenteri', 'varaukset']) { await page.evaluate((x) => { location.hash = `#/${x}`; }, r); await page.waitForTimeout(500); }
  {   // Johku-tunniste + lähdesuodatin (Kaikki / Uudet / Johku → p_source) varauslistassa ja varauksen tiedoissa
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .listrow');
    const grp = page.getByRole('group', { name: 'Lähde' });
    if ((await grp.getByRole('radio').count()) !== 3) problems.push('varaukset: lähdesuodattimessa pitää olla 3 vaihtoehtoa (Kaikki/Uudet/Johku)');
    if ((await page.locator('#view .listrow .badge.src-johku').count()) !== 1 || (await page.locator('#view .listrow').count()) !== 2) problems.push('varaukset: Kaikki-listalla pitää olla 2 varausta, joista yhdellä Johku-tunniste');
    if (srcArgs.at(-1) !== null) problems.push(`varaukset: Kaikki ei saa lähettää p_source-arvoa: ${srcArgs.at(-1)}`);
    for (const [label, want, n, johku] of [['Johku', 'johku', 1, 1], ['Uudet', 'native', 1, 0], ['Kaikki', null, 2, 1]]) {
      await Promise.all([page.waitForResponse((r) => r.url().includes('admin_list_reservations')), grp.getByRole('radio', { name: label }).check()]);
      await page.waitForTimeout(200);
      if (srcArgs.at(-1) !== want) problems.push(`varaukset: ${label} → p_source ${JSON.stringify(want)} odotettiin, lähti ${JSON.stringify(srcArgs.at(-1))}`);
      if ((await page.locator('#view .listrow').count()) !== n || (await page.locator('#view .listrow .badge.src-johku').count()) !== johku) problems.push(`varaukset: suodatin ${label}: rivejä ${n} (Johku-tunnisteita ${johku}) odotettiin`);
    }
    {   // Ajanjakso-pikavalinta: oletus Kaikki ajat (p_from/p_to null), Alkaen/Päättyen vain Oma ajanjakso -valinnalla; kortissa tilausnumero ja hinta omilla paikoillaan
      const per = page.getByRole('group', { name: 'Ajanjakso' });
      if ((await per.getByRole('radio').count()) !== 5 || !(await per.getByRole('radio', { name: 'Kaikki ajat' }).isChecked())) problems.push('varaukset: Ajanjakso-valinnassa pitää olla 5 vaihtoehtoa ja oletuksena Kaikki ajat');
      if (periodArgs.at(-1).some((x) => x !== null)) problems.push(`varaukset: Kaikki ajat → p_from/p_to null odotettiin: ${JSON.stringify(periodArgs.at(-1))}`);
      if (await page.locator('.perdates').isVisible()) problems.push('varaukset: Alkaen/Päättyen ei saa näkyä ennen Oma ajanjakso -valintaa');
      if (!/^\d+ \/ \d+ varausta · Kaikki ajat$/.test(await page.locator('#view > p.muted').first().innerText())) problems.push('varaukset: tulosrivin pitää näyttää ajanjakso');
      await Promise.all([page.waitForResponse((r) => r.url().includes('admin_list_reservations')), per.getByRole('radio', { name: 'Tulevat' }).check()]);
      if (!periodArgs.at(-1)[0] || periodArgs.at(-1)[1] !== null) problems.push(`varaukset: Tulevat → p_from asetettu, p_to null: ${JSON.stringify(periodArgs.at(-1))}`);
      await Promise.all([page.waitForResponse((r) => r.url().includes('admin_list_reservations')), per.getByRole('radio', { name: 'Oma ajanjakso' }).check()]);
      if (!(await page.locator('.perdates').isVisible())) problems.push('varaukset: Oma ajanjakso → Alkaen/Päättyen pitää näkyä');
      await Promise.all([page.waitForResponse((r) => r.url().includes('admin_list_reservations')), per.getByRole('radio', { name: 'Kaikki ajat' }).check()]);
      await page.waitForTimeout(150);
      const k = await page.evaluate(() => { const c = document.querySelector('#view .rescard'), b = (s) => c.querySelector(s).getBoundingClientRect(), cb = c.getBoundingClientRect(); return { noRight: Math.round(cb.right - b('.rc-no').right), priceRight: Math.round(cb.right - b('.rc-price').right), noTop: b('.rc-no').top - cb.top, priceBottom: cb.bottom - b('.rc-price').bottom, no: c.querySelector('.rc-no').textContent }; });
      if (!/^#\d+$/.test(k.no) || k.noRight > 20 || k.priceRight > 20 || k.noTop > 24 || k.priceBottom > 24) problems.push(`varaukset: kortin asettelu (tilausnumero oikea yläkulma, hinta oikea alakulma) väärä: ${JSON.stringify(k)}`);
    }
    await page.locator('#view .listrow:has(.badge.src-johku)').click();
    await page.waitForSelector('dialog[open] .kv');
    if (!/Johku-tunnus\s*J-48213/.test(await page.locator('dialog[open]').innerText())) problems.push('varauksen tiedot: Johku-tunnus (J-48213) puuttuu');
    await page.keyboard.press('Escape');
    await page.locator('#view .listrow:not(:has(.badge.src-johku))').click();
    await page.waitForSelector('dialog[open] .kv');
    if (/Johku/.test(await page.locator('dialog[open]').innerText())) problems.push('varauksen tiedot: uudella varauksella ei saa olla Johku-tietoja');
    await page.keyboard.press('Escape');
    const ov = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    if (ov > 0) problems.push(`varaukset: vaakavieritys ${ov}px`);
  }
  {   // migraatio 17: resurssivaraukset – pikapainikkeet, tila-/Vanha tuote -merkit, Tarkista-lista, varaustyyppi, BK001-virheet suomeksi, ylitys vain oikeudella
    await page.evaluate(() => { location.hash = '#/varaukset'; });
    await page.waitForSelector('#view .listrow');
    if ((await page.locator('#view .pageactions a:has-text("Vanha varaus")').count()) !== 1 || (await page.locator('#view .pageactions a:has-text("Tarkista")').count()) !== 1) problems.push('varaukset: Vanha varaus- ja Tarkista-painikkeet puuttuvat');
    if ((await page.locator('#view .listrow .badge.space:has-text("Rauni")').count()) !== 1 || (await page.locator('#view .listrow .badge.lc-old').count()) !== 1) problems.push('varaukset: Rauni-tilamerkki ja Vanha tuote -merkki pitää näkyä (vain tilalla/vanhalla tuotteella)');
    if ((await page.locator('#nav a[href="#/tarkista"]').count()) !== 1) problems.push('hallinta: Tarkista puuttuu valikosta');
    await page.evaluate(() => { location.hash = '#/tarkista'; });
    await page.waitForSelector('[data-testid=review-overrides]');
    const secs = await page.evaluate(() => Object.fromEntries([...document.querySelectorAll('.review-sec')].map((e) => [e.dataset.testid, e.querySelectorAll('li.resrow').length])));
    if (JSON.stringify(secs) !== JSON.stringify({ 'review-therapist_conflicts': 1, 'review-block_conflicts': 0, 'review-overrides': 1, 'review-orphan_addons': 0 })) problems.push(`tarkista: osiot/rivit väärin: ${JSON.stringify(secs)}`);
    if (!/Syy: Sovittu asiakkaan kanssa/.test(await page.locator('[data-testid=review-overrides]').innerText()) || !/Yleinen/i.test(await page.locator('[data-testid=review-therapist_conflicts]').innerText())) problems.push('tarkista: ylityksen syy tai taidon suomennos puuttuu');
    // varaustyyppi: radiogroup, Resurssivaraus → lomake, BK001 space_busy suomeksi, ei ylitysvaihtoehtoa ilman oikeutta
    await page.evaluate(() => { location.hash = '#/uusi'; });
    await page.waitForSelector('[data-testid=booking-type]');
    const bt = page.getByRole('group', { name: 'Varaustyyppi' });
    if ((await bt.getByRole('radio').count()) !== 3 || !(await bt.getByRole('radio', { name: 'Vuoro' }).isChecked())) problems.push('uusi varaus: Varaustyyppi pitää olla 3 vaihtoehtoa, oletuksena Vuoro');
    await bt.getByRole('radio', { name: 'Resurssivaraus' }).check();
    await page.waitForSelector('[data-testid=resource-booking-form]');
    if (!page.url().includes('tyyppi=resurssi')) problems.push(`uusi varaus: tyyppi ei tallennu osoitteeseen: ${page.url()}`);
    const opts = await page.locator('[data-testid=resource-booking-form] select[name=product] option').allInnerTexts();
    if (opts.length !== 1 || !/Hoito \(nykyinen\)/.test(opts[0])) problems.push(`resurssivaraus: vain nykyiset tuotteet pitää listata: ${opts}`);
    if ((await page.locator('[data-testid=override-box]').count()) !== 0) problems.push('resurssivaraus: ylitysvaihtoehto näkyy ilman oikeutta bookings.override');
    await page.fill('[data-testid=resource-booking-form] [name=cname]', 'Testi Testaaja');
    await page.fill('[data-testid=resource-booking-form] [name=cemail]', 'testi@example.com');
    expect400 = true;
    await page.click('[data-testid=resource-booking-form] button[type=submit]');
    await page.waitForSelector('[data-testid=resource-booking-form] .err:not([hidden])');
    expect400 = false;
    const emsg = await page.locator('[data-testid=resource-booking-form] .err').innerText();
    if (!/Tila on jo varattu/.test(emsg) || /space_busy|palvelimen viesti/.test(emsg)) problems.push(`resurssivaraus: BK001 space_busy pitää näkyä suomeksi: ${emsg}`);
    const [rpcName, ra] = resArgs.at(-1) || [];
    if (rpcName !== 'admin_create_resource_booking' || ra.p_product_id !== 41 || ra.p_override !== false || ra.p_override_reason !== null || !ra.p_customer || !/^\d{4}-\d\d-\d\dT/.test(ra.p_start)) problems.push(`resurssivaraus: RPC-argumentit väärin: ${JSON.stringify(resArgs.at(-1))}`);
    // Vanha varaus: vain lifecycle='old' -tuotteet, oma RPC
    await page.evaluate(() => { location.hash = '#/uusi?tyyppi=vanha'; });
    await page.waitForSelector('[data-testid=old-booking-form]');
    const oopts = await page.locator('[data-testid=old-booking-form] select[name=product] option').allInnerTexts();
    if (oopts.length !== 1 || !/Vanha hoito/.test(oopts[0])) problems.push(`vanha varaus: vain vanhat tuotteet pitää listata: ${oopts}`);
    await page.fill('[data-testid=old-booking-form] [name=cname]', 'Vanha Asiakas');
    await page.fill('[data-testid=old-booking-form] [name=cemail]', 'testi@example.com');
    expect400 = true;
    await page.click('[data-testid=old-booking-form] button[type=submit]');
    await page.waitForSelector('[data-testid=old-booking-form] .err:not([hidden])');
    expect400 = false;
    if (resArgs.at(-1)?.[0] !== 'admin_create_old_booking') problems.push('vanha varaus: pitää kutsua admin_create_old_booking');
    // ylitys: näkyy vain oikeudella bookings.override, perustelu pakollinen ja lähtee RPC:lle
    extraPerms = ['bookings.override'];
    await page.reload();
    await page.waitForSelector('[data-testid=old-booking-form]');
    if ((await page.locator('[data-testid=override-box]').count()) !== 1) problems.push('vanha varaus: ylitysvaihtoehdon pitää näkyä oikeudella bookings.override');
    await page.fill('[data-testid=old-booking-form] [name=cname]', 'Vanha Asiakas');
    await page.fill('[data-testid=old-booking-form] [name=cemail]', 'testi@example.com');
    await page.check('[data-testid=override-box] input[name=override]');
    await page.click('[data-testid=old-booking-form] button[type=submit]');
    await page.waitForSelector('[data-testid=old-booking-form] .err:not([hidden])');
    if (!/Ylitys vaatii perustelun/.test(await page.locator('[data-testid=old-booking-form] .err').innerText())) problems.push('ylitys: perustelun puute pitää estää ennen RPC-kutsua');
    const nOvr = resArgs.length;
    await page.fill('[data-testid=override-box] [name=override_reason]', 'Sovittu erikseen');
    expect400 = true;
    await page.click('[data-testid=old-booking-form] button[type=submit]');
    await page.waitForTimeout(400);
    expect400 = false;
    if (resArgs.length !== nOvr + 1 || resArgs.at(-1)[1].p_override !== true || resArgs.at(-1)[1].p_override_reason !== 'Sovittu erikseen') problems.push(`ylitys: p_override/p_override_reason eivät lähteneet: ${JSON.stringify(resArgs.at(-1))}`);
    extraPerms = [];
    // BK001-koodit: kaikilla pitää olla suomenkielinen teksti (errMsg ui.js:stä)
    const uiUrl = (await page.evaluate(() => performance.getEntriesByType('resource').map((e) => e.name))).find((u) => /\/hallinta\/ui\.js/.test(u));
    const codes = ['space_busy', 'no_therapist', 'therapist_closed', 'parent_required', 'override_reason_required', 'wrong_lifecycle', 'space_not_allowed', 'no_space', 'no_pool_for_start', 'no_primary_leg', 'bad_rule', 'skill_unknown', 'not_resourced', 'capacity_exceeded', 'space_closed', 'private_booked', 'public_shift_booked', 'bad_pool', 'has_reservations', 'forbidden', 'closure_managed', 'bad_override', 'not_found', 'calendar_not_found'];
    const msgs = await page.evaluate(async ([url, cs]) => { const m = await import(url); return cs.map((c) => m.errMsg({ code: c, message: `EN ${c}` })); }, [uiUrl, codes]);
    msgs.forEach((t, i) => { if (/^EN |_/.test(t) || !/[äöå ]/.test(t)) problems.push(`virhekoodi ${codes[i]}: ei suomenkielistä viestiä: ${t}`); });
    await page.evaluate(() => { location.hash = '#/varaukset'; });
  }
  {   // migraatio 18: Kalenterisulut-näkymä (kalenterit, konflikti, tapahtumat, ajot), ohitus (Ohita / Estä / Palauta automaattinen + muistiinpano), oikeuspiilotus, closure_managed suomeksi
    if ((await page.locator('#nav a[href="#/sulkukalenterit"]').count()) !== 1) problems.push('hallinta: Kalenterisulut puuttuu valikosta (blocks.manage)');
    await page.evaluate(() => { location.hash = '#/sulkukalenterit'; });
    await page.waitForSelector('[data-testid=closure-event]');
    const cal = await page.locator('[data-testid=closure-calendar]').allInnerTexts();
    if (cal.length !== 2 || !/Käytössä/.test(cal[0]) || /Ei käytössä/.test(cal[0]) || !/Ei käytössä/.test(cal[1])) problems.push(`kalenterisulut: kalenterikortit väärin: ${JSON.stringify(cal)}`);
    if ((await page.locator('[data-testid=sync-off]').count()) !== 0) problems.push('kalenterisulut: synkka-ei-käynnissä-ilmoitus ei saa näkyä kun kalenteri on käytössä');
    if ((await page.locator('[data-testid=closure-conflicts] li.resrow').count()) !== 1 || (await page.locator('[data-testid=closure-runs] li.resrow').count()) !== 2) problems.push('kalenterisulut: 1 konflikti ja 2 ajoa odotettiin');
    const evs = await page.locator('[data-testid=closure-event]').allInnerTexts();
    if (!/Sulkee/.test(evs[0]) || !/Ei sulje/.test(evs[1]) || !/Karkea jakso/.test(evs[1])) problems.push(`kalenterisulut: tapahtumien merkit väärin: ${JSON.stringify(evs)}`);
    if ((await page.locator('[data-testid=closure-event]').nth(0).locator('button[data-act=ignore]').count()) !== 1 || (await page.locator('[data-testid=closure-event]').nth(1).locator('button[data-act=block]').count()) !== 1) problems.push('kalenterisulut: Ohita (sulkeva) ja Estä (ei-sulkeva) -napit puuttuvat');
    await page.locator('[data-testid=closure-event]').nth(0).locator('button[data-act=ignore]').click();
    await page.waitForSelector('dialog[open] textarea[name=note]');
    await page.fill('dialog[open] textarea[name=note]', 'sovittu');
    await page.click('dialog[open] button[type=submit]');
    await page.waitForSelector('dialog[open]', { state: 'detached' });
    if (JSON.stringify(ovrArgs.at(-1)) !== JSON.stringify({ p_event_id: 71, p_override: 'ignore', p_note: 'sovittu' })) problems.push(`kalenterisulut: Ohita-kutsun argumentit väärin: ${JSON.stringify(ovrArgs.at(-1))}`);
    await page.waitForSelector('[data-testid=closure-event]');
    await page.locator('[data-testid=closure-event]').nth(1).locator('button[data-act=block]').click();
    await page.waitForSelector('dialog[open] textarea[name=note]');
    await page.click('dialog[open] button[type=submit]');
    await page.waitForSelector('dialog[open]', { state: 'detached' });
    if (JSON.stringify(ovrArgs.at(-1)) !== JSON.stringify({ p_event_id: 72, p_override: 'block', p_note: null })) problems.push(`kalenterisulut: Estä-kutsun argumentit väärin: ${JSON.stringify(ovrArgs.at(-1))}`);
    const per = page.getByRole('group', { name: 'Näytä tapahtumat' });
    if ((await per.getByRole('radio').count()) !== 4) problems.push('kalenterisulut: jaksovalinnassa pitää olla 4 vaihtoehtoa');
    // oikeuspiilotus: ilman blocks.manage ei valikkokohtaa eikä ohitusnappeja (funktio vaatii oikeuden; hallinta piilottaa)
    dropPerms = ['blocks.manage'];
    await page.reload();
    await page.waitForSelector('#shell:not([hidden]) #nav a');
    if ((await page.locator('#nav a[href="#/sulkukalenterit"]').count()) !== 0) problems.push('kalenterisulut: valikkokohta ei saa näkyä ilman oikeutta blocks.manage');
    await page.waitForFunction(() => document.querySelector('#view h1') && document.querySelector('#view h1').textContent !== 'Ladataan…', null, { timeout: 8000 }).catch(() => {});
    if ((await page.locator('[data-testid=closure-event]').count()) !== 0 || (await page.locator('#view h1').first().innerText().catch(() => '')) === 'Kalenterisulut') problems.push('kalenterisulut: suora osoite ei saa avata näkymää ilman oikeutta blocks.manage (reitti putoaa oletusnäkymään)');
    dropPerms = [];
    await page.reload();
    await page.waitForSelector('#shell:not([hidden]) #nav a');
    await page.evaluate(() => { location.hash = '#/varaukset'; });
  }
  {   // työvuorojen rooli ja miehitys suomeksi (v10): heater/reception/therapist/assigned eivät saa näkyä, Hoitaja → Saunottaja
    await page.evaluate(() => { location.hash = '#/kalenteri'; });
    await page.waitForSelector('.cal-detail .cal-item.shift', { timeout: 5000 }).catch(() => problems.push('kalenteri: työvuoroja ei näkynyt'));
    const txt = (await page.locator('.cal-detail .cal-item.shift').allInnerTexts()).join(' | ');
    for (const w of ['Lämmitykset', 'Vastaanotto', 'Saunottaja', 'Ei nimettyä tekijää']) if (!txt.includes(w)) problems.push(`kalenteri: työvuorosta puuttuu "${w}": ${txt}`);
    const cls = await page.locator('.cal-detail .cal-item.shift').evaluateAll((els) => els.map((e) => e.className));
    for (const c of ['shift-heater', 'shift-reception', 'shift-therapist']) if (!cls.some((x) => x.includes(c))) problems.push(`kalenteri: työvuorokortilta puuttuu väriluokka ${c}: ${cls.join(' | ')}`);
    const bgs = await page.locator('.cal-detail .cal-item.shift').evaluateAll((els) => els.map((e) => getComputedStyle(e).backgroundColor));
    if (new Set(bgs.slice(0, 3)).size !== 3) problems.push(`kalenteri: roolien taustavärien pitää erota: ${bgs}`);
    const badges = await page.locator('.cal-detail .cal-item.shift').evaluateAll((els) => els.map((e) => ({ named: !!e.querySelector('.cal-txt > span'), badge: e.querySelector('.badge')?.textContent ?? null })));
    if (badges.length !== 5 || badges.filter((b) => b.badge).length !== 1 || badges.some((b) => b.named === !!b.badge || (b.badge && b.badge !== 'Ei nimettyä tekijää'))) problems.push(`kalenteri: merkki vain nimeämättömällä vuorolla: ${JSON.stringify(badges)}`);
    if (/miehitetty|osittain|\bavoin\b/i.test(txt)) problems.push(`kalenteri: Miehitetty/Osittain/Avoin ei saa näkyä: ${txt}`);
    if (/heater|reception|therapist|assigned|sauna_x|hoitaja|\bopen\b/i.test(txt)) problems.push(`kalenteri: työvuoroissa näkyy koodi tai "Hoitaja": ${txt}`);
  }
  if ((await page.locator('#nav a[href="#/kayttajat"]').count()) !== 0) problems.push('kutsu: staff ei saa nähdä Käyttäjät-valikkoa');
  // valikon ikonit: yksivärisiä SVG:itä tummanvihreällä (#2B3A30), ei emojeita
  const nav = await page.evaluate(() => ({ links: document.querySelectorAll('#nav a').length, svgs: document.querySelectorAll('#nav a .ico svg').length, colors: [...document.querySelectorAll('#nav a .ico svg')].map((s) => getComputedStyle(s).color), size: [...document.querySelectorAll('#nav a .ico svg')].map((s) => s.getBoundingClientRect().width), text: document.getElementById('nav').textContent }));
  if (!nav.links || nav.svgs !== nav.links) problems.push(`ikonit: ${nav.svgs} SVG / ${nav.links} linkkiä`);
  if (nav.colors.some((c) => c !== 'rgb(43, 58, 48)')) problems.push(`ikonit: väri ei ole tummanvihreä: ${[...new Set(nav.colors)]}`);
  if (nav.size.some((w) => w < 22 || w > 24)) problems.push(`ikonit: koko ${[...new Set(nav.size)]}`);
  if (/[\u2190-\u27bf\u2b00-\u2bff\u{1F000}-\u{1FAFF}\uFE0F]/u.test(nav.text)) problems.push('ikonit: emoji-merkkejä valikossa');
  // migraatio 11: uudet näkymämoduulit (customerform.js, addons.js) latautuvat versioituina; Lisää asiakas -lomake + y-tunnuksen tarkistus selaimessa
  {
    for (const r of ['asiakkaat', 'uusi', 'tuotteet']) { await page.evaluate((x) => { location.hash = `#/${x}`; }, r); await page.waitForTimeout(600); }
    const mreqs = await page.evaluate(() => performance.getEntriesByType('resource').map((e) => e.name));   // moduuli voi olla ladattu jo aiemmin (shared.js tuo addons.js:n)
    const need = ['customerform.js', 'addons.js'];
    for (const f of need) if (!mreqs.some((u) => u.includes(`/hallinta/views/${f}?v=`))) problems.push(`hallinta: views/${f} ei latautunut versioituna`);
    await page.evaluate(() => { location.hash = '#/asiakkaat'; });
    await page.waitForSelector('button:has-text("Lisää asiakas")');
    await page.click('button:has-text("Lisää asiakas")');
    await page.waitForSelector('dialog[open] .kindset');
    await page.check('dialog input[value=company]');
    if ((await page.locator('dialog .company-box').isVisible()) !== true) problems.push('asiakaslomake: yritystiedot eivät tulleet näkyviin');
    await page.fill('dialog [name=business_id]', '0112038-8');
    if (!(await page.locator('dialog [name=business_id]').evaluate((e) => e.validationMessage))) problems.push('asiakaslomake: virheellinen y-tunnus ei anna virhettä selaimessa');
    await page.fill('dialog [name=business_id]', '0112038-9');
    if (await page.locator('dialog [name=business_id]').evaluate((e) => e.validationMessage)) problems.push('asiakaslomake: kelvollinen y-tunnus hylättiin');
    await page.keyboard.press('Escape');
  }
  await page.context().close();
}
// 4) näkymämoduulin lataus: ensimmäinen import epäonnistuu → uusinta cache-bust-parametrilla onnistuu
{
  const page = await newPage('retry', { allowFail: /views\/newbooking\.js/ });
  let hits = [];
  await page.route(/\/hallinta\/views\/newbooking\.js/, (route) => { hits.push(route.request().url()); return hits.length === 1 ? route.abort('failed') : route.continue(); });
  await loginViaInvite(page);
  await page.evaluate(() => { location.hash = '#/uusi'; });
  await page.waitForFunction(() => document.title.startsWith('Uusi varaus'), null, { timeout: 8000 }).catch(() => problems.push('retry: näkymä ei latautunut uusinnan jälkeen'));
  if (hits.length !== 2 || !/[?&]r=\d+/.test(hits[1] || '')) problems.push(`retry: odotettiin 2 pyyntöä (toinen r=…), saatiin ${JSON.stringify(hits.map((u) => u.split('/').pop()))}`);
  if ((await page.locator('#view', { hasText: 'Näkymän lataus epäonnistui' }).count()) !== 0) problems.push('retry: virhe näkyy vaikka uusinta onnistui');
  await page.context().close();
}
// 5) molemmat yritykset epäonnistuvat → suomenkielinen virhe + "Lataa uudelleen"; painike lataa sivun uudelleen ja näkymä toimii kun verkko palaa
{
  const page = await newPage('retry-fail', { allowFail: /views\/newbooking\.js/ });
  let hits = 0;
  const abort = (route) => { hits++; return route.abort('failed'); };
  await page.route(/\/hallinta\/views\/newbooking\.js/, abort);
  await loginViaInvite(page);
  await page.evaluate(() => { location.hash = '#/uusi'; });
  await page.waitForSelector('#view [role=alert]', { timeout: 8000 });
  const txt = await page.locator('#view').innerText();
  if (!txt.includes('Näkymän lataus epäonnistui')) problems.push(`retry-fail: virheviesti puuttuu: ${txt.slice(0, 120)}`);
  const btn = page.locator('#view button', { hasText: 'Lataa uudelleen' });
  if ((await btn.count()) !== 1) problems.push('retry-fail: "Lataa uudelleen" -painike puuttuu');
  if (hits !== 2) problems.push(`retry-fail: odotettiin 2 yritystä, saatiin ${hits}`);
  await page.unroute(/\/hallinta\/views\/newbooking\.js/, abort);
  await Promise.all([page.waitForNavigation({ waitUntil: 'load' }).catch(() => {}), btn.click()]);
  await page.waitForSelector('#shell:not([hidden]) #nav a', { timeout: 8000 });
  await page.waitForFunction(() => document.title.startsWith('Uusi varaus'), null, { timeout: 8000 }).catch(() => problems.push('retry-fail: näkymä ei latautunut uudelleenlatauksen jälkeen'));
  await page.context().close();
}
// 6) Uusi varaus: vuoron valinta (myös vaihto) vierittää varauslomakkeeseen ja siirtää fokuksen otsikkoon (mobiili 390 + desktop)
for (const [label, viewport, mobile] of [['mobiili', { width: 390, height: 700 }, true], ['desktop', { width: 1100, height: 560 }, false]]) {
  const page = await newPage(`uusivaraus-${label}`, { viewport, mobile });
  await loginViaInvite(page);
  await page.evaluate(() => { location.hash = '#/uusi?d=2026-12-05'; });
  await page.waitForSelector('.slotbtn:not([disabled])');
  const view = () => page.evaluate(() => { const t = document.querySelector('[data-testid=booking-form] h3'), r = t?.getBoundingClientRect(), a = document.activeElement; return { title: t?.textContent || '', top: r?.top, bottom: r?.bottom, header: document.querySelector('.top').getBoundingClientRect().bottom, vh: innerHeight, focusOk: a === t, kbd: ['INPUT', 'TEXTAREA', 'SELECT'].includes(a?.tagName), y: scrollY }; });
  const still = () => page.waitForFunction(() => { const y = scrollY, k = window.__y === y ? (window.__n = (window.__n || 0) + 1) : (window.__n = 0); window.__y = y; return window.__n > 12; }, null, { polling: 'raf' });
  for (const idx of [0, 6, 1]) {
    await page.evaluate(() => scrollTo({ top: 0, behavior: 'instant' }));
    await page.locator('.slotbtn:not([disabled])').nth(idx).click(); await still();
    const v = await view();
    if (!/^Vuoro: /.test(v.title) || !(v.top >= v.header - 1 && v.bottom <= v.vh)) problems.push(`uusivaraus-${label}: lomakkeen otsikko pitää näkyä valinnan (${idx}) jälkeen: ${JSON.stringify(v)}`);
    if (!v.focusOk || v.kbd) problems.push(`uusivaraus-${label}: fokus pitää olla lomakkeen otsikossa (ei kentässä): ${JSON.stringify(v)}`);
    if (mobile && v.y < 100) problems.push(`uusivaraus-${label}: näkymä ei vieritetty lomakkeeseen (scrollY ${v.y})`);
    if (!/\d\d:\d\d–\d\d:\d\d/.test(v.title)) problems.push(`uusivaraus-${label}: otsikossa pitää olla valitun vuoron aika: ${v.title}`);
  }
  // asiakashaku ilman osumia (mock palauttaa []): nimi → Nimi, sähköposti → Sähköposti, täytettyä ei ylikirjoiteta; Enter ei lähetä varausta
  const sIn = page.getByLabel('Hae asiakas'), fv = (n) => page.locator(`[data-testid=booking-form] [name=${n}]`).inputValue();
  await sIn.fill('Maija Meikäläinen'); await sIn.press('Enter'); await page.waitForSelector('[data-testid=customer-notfound]');
  if ((await fv('cname')) !== 'Maija Meikäläinen' || !/Ei löytynyt – luo uusi asiakas/.test(await page.locator('[data-testid=customer-notfound]').innerText())) problems.push(`uusivaraus-${label}: nimen esitäyttö hakusanasta puuttuu`);
  await sIn.fill('  maija@example.com '); await sIn.press('Enter'); await page.waitForFunction(() => document.querySelector('[name=cemail]')?.value);
  if ((await fv('cemail')) !== 'maija@example.com' || (await fv('cname')) !== 'Maija Meikäläinen') problems.push(`uusivaraus-${label}: sähköpostin esitäyttö (trimmattu) puuttuu tai nimi ylikirjoitettiin`);
  if ((await page.evaluate(() => document.activeElement?.name)) !== 'cphone') problems.push(`uusivaraus-${label}: fokuksen pitää siirtyä seuraavaan tyhjään kenttään (puhelin)`);
  for (const [kind, tid] of [['resurssi', 'resource-booking-form'], ['vanha', 'old-booking-form']]) {   // sama asiakashaku + esitäyttö resurssi- ja vanha varaus -lomakkeilla
    await page.evaluate((k) => { location.hash = `#/uusi?tyyppi=${k}`; }, kind);
    const rf = page.locator(`[data-testid=${tid}]`); await rf.waitFor();
    await rf.getByLabel('Hae asiakas').fill('Reijo Resurssi'); await rf.getByLabel('Hae asiakas').press('Enter'); await page.waitForSelector('[data-testid=customer-notfound]');
    await rf.getByLabel('Hae asiakas').fill('reijo@example.com'); await rf.getByLabel('Hae asiakas').press('Enter'); await page.waitForFunction(() => document.querySelector('[name=cemail]')?.value);
    if ((await rf.locator('[name=cname]').inputValue()) !== 'Reijo Resurssi' || (await rf.locator('[name=cemail]').inputValue()) !== 'reijo@example.com') problems.push(`uusivaraus-${label}/${kind}: asiakashaun esitäyttö puuttuu`);
  }
  await page.context().close();
}
await browser.close();
if (problems.length) { console.error('ONGELMIA:\n' + [...new Set(problems)].join('\n')); process.exit(1); }
console.log(`ok: Pages-kooste toimii alipolulla ${BASE} (sivut, kauppa, hallinta, kutsun hyväksyntä); Supabase-kutsuja mockattu ${calls.length} kpl`);
