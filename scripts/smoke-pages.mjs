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

async function newPage(name, { allowFail = null } = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1100, height: 800 }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  // allowFail: tarkoituksella epäonnistutetut moduulipyynnöt (retry-testit) eivät ole ongelmia; muut konsolivirheet ovat
  const expected = (t) => allowFail && allowFail.test(t);
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !expected(m.text()) && !(allowFail && /Näkymän .* lataus epäonnistui|Failed to load resource|Failed to fetch dynamically imported module/.test(m.text()))) problems.push(`${name} console.${m.type()}: ${m.text()}`); });
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
    if (u.pathname.endsWith('/rpc/admin_my_permissions')) return json({ role: 'staff', role_label: 'Peruskäyttäjä', permissions: ['bookings.manage', 'shifts.view', 'customers.manage', 'catalog.edit'] });
    if (u.pathname.endsWith('/rpc/admin_upcoming_shifts')) {   // tuotannon kaltaiset englanninkieliset koodit; hallinnan pitää näyttää suomeksi
      const ds = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
      const row = (id, from, to, role, cal, st, who) => ({ shift_id: id, starts_at: `${ds}T${from}:00Z`, ends_at: `${ds}T${to}:00Z`, role_type: role, calendar_name: cal, staffing_status: st, staff_name: who });
      return json([row('s1', '06:00', '11:00', 'heater', 'Lämmitykset', 'assigned', 'Otto'), row('s2', '11:00', '16:00', 'reception', 'Vastaanotto', 'assigned', 'Otto'), row('s3', '11:00', '17:00', 'therapist', 'Hoitaja', 'assigned', 'Joonas'), row('s4', '12:00', '15:00', 'sauna_x', 'Hoitaja', 'unassigned', null), row('s5', '16:00', '18:00', 'therapist', 'Hoitaja', 'partial', 'Matti')]);
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
await browser.close();
if (problems.length) { console.error('ONGELMIA:\n' + [...new Set(problems)].join('\n')); process.exit(1); }
console.log(`ok: Pages-kooste toimii alipolulla ${BASE} (sivut, kauppa, hallinta, kutsun hyväksyntä); Supabase-kutsuja mockattu ${calls.length} kpl`);
