// Paikallinen savutesti Pages-koosteelle alipolulla (ei kosketa oikeaan Supabaseen: kaikki *.supabase.co-pyynnöt vastataan mockilla).
//   1) SITE_ENV=test SITE_URL=https://joonasvaarala.github.io/saunotus-uusi BOOKING_SUPABASE_URL=https://<ref>.supabase.co BOOKING_ANON_KEY=… DIST=/tmp/dist node scripts/build-pages.mjs
//   2) mkdir /tmp/site && ln -s /tmp/dist /tmp/site/saunotus-uusi && (cd /tmp/site && python3 -m http.server 4190 --bind 127.0.0.1 &)
//   3) PW_DIR=/polku/node_modules node scripts/smoke-pages.mjs        (BASE_URL oletus http://127.0.0.1:4190/saunotus-uusi, CHROME oletus /usr/bin/google-chrome)
// Tarkistaa: sivut/skriptit/tyylit/importit latautuvat alipolulta (ei 404, ei konsolivirheitä), noindex, hallinnan kirjautumisnäkymä,
// kutsulinkin (#access_token…&type=invite) hyväksyntä ja salasanan asetus polussa /hallinta/.
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

async function newPage(name) {
  const ctx = await browser.newContext({ viewport: { width: 1100, height: 800 }, locale: 'fi-FI', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.push(`${name} console.${m.type()}: ${m.text()}`); });
  page.on('requestfailed', (r) => problems.push(`${name} requestfailed: ${r.url()} ${r.failure()?.errorText}`));
  page.on('response', (r) => { if (r.status() >= 400 && r.url().startsWith(BASE.split('/').slice(0, 3).join('/'))) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
  // Supabase-mock: ei yhteyttä oikeaan projektiin
  await page.route(/\.supabase\.co\//, (route) => {
    const u = new URL(route.request().url()), m = route.request().method();
    calls.push(`${m} ${u.pathname}`);
    const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' }, body: JSON.stringify(body) });
    if (m === 'OPTIONS') return json({});
    if (u.pathname === '/auth/v1/user' && m === 'PUT') return json({ id: 'u1', email: 'kutsuttu@example.com' });
    if (u.pathname.endsWith('/rpc/current_staff_role')) return json('staff');
    if (u.pathname.endsWith('/rpc/admin_my_permissions')) return json({ role: 'staff', role_label: 'Peruskäyttäjä', permissions: ['bookings.manage', 'shifts.view'] });
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
  await page.goto(`${BASE}/hallinta/`);
  await page.waitForSelector('form#login:visible');
  if ((await page.locator('meta[name=robots][content*=noindex]').count()) < 1) problems.push('hallinta: noindex puuttuu');
  if (!(await page.evaluate(() => window.BOOKING_CONFIG?.url?.endsWith('.supabase.co')))) problems.push('hallinta: config.js ei osoita Supabaseen');
  await page.context().close();
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
  if ((await page.locator('#nav a[href="#/kayttajat"]').count()) !== 0) problems.push('kutsu: staff ei saa nähdä Käyttäjät-valikkoa');
  await page.context().close();
}
await browser.close();
if (problems.length) { console.error('ONGELMIA:\n' + [...new Set(problems)].join('\n')); process.exit(1); }
console.log(`ok: Pages-kooste toimii alipolulla ${BASE} (sivut, kauppa, hallinta, kutsun hyväksyntä); Supabase-kutsuja mockattu ${calls.length} kpl`);
