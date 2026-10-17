// Kaupan asiakasnäkymä näyttää VAIN vapaat vuorot (ei täynnä olevia): päivänäkymän tuotekortti, tuotesivun vuorolista ja tilauksen ajanmuutosnäkymä.
// Ei tarvitse tietokantaa eikä kehityspalvelinta: kaupan build (staattiset tiedostot) tarjoillaan tässä, ja RPC-kutsut (public_*) vastataan mock-datalla,
// jossa on sekä vapaita että täynnä / ei varattavissa olevia vuoroja (selainpuolella route-sieppaus, ei verkkoa).
// Käyttö (repon juuresta):
//   SHOP_DIST=/tmp/shop-dist node booking/shop/build.mjs
//   SHOP_DIST=/tmp/shop-dist PW_DIR=/polku/node_modules node booking/scripts/e2e-shop-vain-vapaat.mjs
// Ympäristö: SHOP_DIST (oletus booking/shop/dist), OUT = kuvakaappauskansio (oletus: ei kuvia), CHROME (oletus /usr/bin/google-chrome).
// Epäonnistuu (exit 1), jos jokin tarkistus ei täyty tai selaimessa tulee sivuvirhe.
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { mkdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, resolve, join, extname, normalize } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const DIST = resolve(process.env.SHOP_DIST || join(here, '../shop/dist'));
const OUT = process.env.OUT ? resolve(process.env.OUT) : null;
if (OUT) mkdirSync(OUT, { recursive: true });
const cfg = JSON.parse(readFileSync(join(DIST, 'booking/config.js'), 'utf8').replace(/^[\s\S]*?window\.BOOKING_CONFIG\s*=\s*/, '').replace(/;\s*$/, ''));
const rpcPart = `${cfg.rest ?? '/rest/v1'}/rpc/`;

// ---- mock-data: päivät suhteessa tähän päivään (Helsinki) ----
const TZ = 'Europe/Helsinki';
const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const today = new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
const D1 = addDays(today, 5), D2 = addDays(today, 6), SOON = addDays(today, 1);
// Suomen aika → ISO (kesä-/talviaika riittävän tarkasti: haetaan offset Intl:llä)
const iso = (ds, hm) => {
  const guess = new Date(`${ds}T${hm}:00Z`);
  const off = (new Date(guess.toLocaleString('en-US', { timeZone: TZ })) - new Date(guess.toLocaleString('en-US', { timeZone: 'UTC' }))) / 6e4;
  return new Date(guess.getTime() - off * 6e4).toISOString();
};
const slot = (rule_id, ds, from, to, status, remaining, extra = {}) => ({ rule_id, label: '', mode: 'public', session_date: ds, starts_at: iso(ds, from), ends_at: iso(ds, to), status, remaining, min_persons: 1, max_persons: 8,
  price_mode: 'per_person', unit_price: 15, base_price: 0, included_persons: 0, extra_person_price: 0, ...extra });
const CATALOG = [
  { id: 9001, slug: 'testi-yleinen', name: 'Testi yleinen sauna', name_en: 'Test public sauna', description: 'Keksitty testituote.', description_en: 'Made-up.', category: 'sauna', sale_kind: 'public_shift', price: 15, price_type: 'per_person', duration_text: '1,5 h', min_persons: 1, max_persons: 8 },
  { id: 9002, slug: 'testi-taynna', name: 'Testi aina täynnä', name_en: 'Test always full', description: 'Kaikki vuorot täynnä.', description_en: 'All full.', category: 'sauna', sale_kind: 'public_shift', price: 15, price_type: 'per_person', duration_text: '1,5 h', min_persons: 1, max_persons: 8 },
  { id: 9003, slug: 'testi-yksityinen', name: 'Testi yksityinen', name_en: 'Test private', description: 'Yksityisvuoro.', description_en: 'Private.', category: 'sauna', sale_kind: 'private_shift', price: 120, price_type: 'fixed', duration_text: '2 h', min_persons: 1, max_persons: 8 },
];
const AVAIL = {
  9001: [slot(1, D1, '10:00', '11:30', 'available', 5), slot(2, D1, '12:00', '13:30', 'full', 0), slot(3, D1, '14:00', '15:30', 'available', 2), slot(4, D1, '16:00', '17:30', 'full', 0),
    slot(2, D2, '12:00', '13:30', 'full', 0), slot(4, D2, '16:00', '17:30', 'full', 0),
    slot(1, SOON, '07:00', '08:30', 'available', 5), slot(2, SOON, '09:00', '10:30', 'full', 0)],
  9002: [slot(5, D1, '10:00', '11:30', 'full', 0), slot(6, D1, '12:00', '13:30', 'full', 0), slot(5, D2, '10:00', '11:30', 'full', 0)],
  9003: [slot(7, D1, '18:00', '20:00', 'available', 8, { price_mode: 'fixed', base_price: 120 }), slot(8, D1, '20:30', '22:30', 'unavailable', 0, { price_mode: 'fixed', base_price: 120 })],
};
const TOKEN = '11111111-2222-4333-8444-555555555555';
const booking = { ok: true, status: 'confirmed', payment_status: 'unpaid', can_change: true, change_hours_before: 48, customer_change_hours_before: 48, order_no: 'T-1', total: 15, currency: 'EUR', customer_kind: 'private',
  first_name: 'Testi', change_deadline: iso(addDays(D1, -2), '10:00'), payment_methods: [], addons: [],
  items: [{ product_id: 9001, product_name: 'Testi yleinen sauna', rule_id: 1, mode: 'public', starts_at: iso(D1, '10:00'), ends_at: iso(D1, '11:30'), persons: 1, unit_price: 15, line_total: 15 }] };
const calls = [];
const handle = (fn, args) => {
  calls.push({ fn, args });
  switch (fn) {
    case 'public_catalog': return CATALOG;
    case 'public_settings': return { public_booking_enabled: true, booking_horizon_days: 120 };
    case 'public_product_images': return [];
    case 'public_addons': return [];
    case 'public_availability': return (AVAIL[args.p_product_id] || []).filter((r) => r.session_date >= args.p_from && r.session_date <= args.p_to)
      // oma varaus täyttää 10:00-vuoron (täynnä, mutta nykyinen valinta pitää näkyä muutosnäkymässä)
      .map((r) => (r.rule_id === 1 && r.session_date === D1 && args.p_product_id === 9001 && args.__cur ? { ...r, status: 'full', remaining: 0 } : r));
    case 'public_get_booking': return booking;
    case 'public_change_booking': return { ok: true };
    default: return null;
  }
};

// ---- staattinen palvelin ----
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2', '.xml': 'application/xml', '.txt': 'text/plain; charset=utf-8' };
const server = createServer((req, res) => {
  let p = normalize(decodeURIComponent(req.url.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
  let f = join(DIST, p);
  if (existsSync(f) && statSync(f).isDirectory()) f = join(f, 'index.html');
  if (!existsSync(f)) { res.writeHead(404); res.end('ei löytynyt'); return; }
  res.writeHead(200, { 'content-type': types[extname(f)] || 'application/octet-stream' }); res.end(readFileSync(f));
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const BASE = `http://127.0.0.1:${server.address().port}`;

const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const problems = [];
let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };

async function newPage(lang, width = 390) {
  const mobile = width < 600;
  const ctx = await browser.newContext({ viewport: { width, height: 844 }, isMobile: mobile, hasTouch: mobile, locale: lang === 'en' ? 'en-GB' : 'fi-FI', timezoneId: TZ });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => problems.push(`${lang}/${width} pageerror: ${e.message}`));
  await page.route('**/*', async (route) => {
    const u = new URL(route.request().url());
    if (u.pathname.startsWith(rpcPart)) {
      const fn = u.pathname.slice(rpcPart.length), args = JSON.parse(route.request().postData() || '{}');
      if (fn === 'public_availability' && page.__changeView) args.__cur = true;
      return route.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify(handle(fn, args)) });
    }
    if (u.origin === BASE) return route.continue();
    if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' } });
    return route.abort();   // muut ulkoiset pyynnöt (fontit, kuvat) estetään
  });
  return { ctx, page };
}
const shot = async (page, name) => { if (!OUT) return; await page.evaluate(() => window.scrollTo(0, 0)); await page.screenshot({ path: join(OUT, name), fullPage: true }); };
const starts = (arr) => arr.map((x) => x.split('–')[0].replace(/:00$/, ''));   // '10–11:30' → '10'
const visibleTimes = (page, sel) => page.locator(`${sel} .bk-time`).allInnerTexts();

for (const lang of ['fi', 'en']) {
  const path = lang === 'en' ? '/en/book/' : '/varaa/';
  const T = lang === 'fi' ? { full: /täynnä/i, noSlots: 'Ei vapaita vuoroja valitulle päivälle.', choose: 'Valitse', current: 'Nykyinen vuoro' } : { full: /\bfull\b/i, noSlots: 'No available sessions for the selected day.', choose: 'Select', current: 'Current' };
  const { ctx, page } = await newPage(lang);
  const tag = `${lang}/390`;

  // 1) päivänäkymä: tuotekortin vuorolistassa vain vapaat; vain täynnä oleva tuote ei näy lainkaan
  await page.goto(`${BASE}${path}#/paiva/${D1}`);
  await page.waitForSelector('.bk-pc');
  expect((await page.locator('.bk-pc').count()) === 2, `${tag} päivänäkymä: kortteja pitäisi olla 2 (yleinen + yksityinen), nyt ${await page.locator('.bk-pc').count()}`);
  expect((await page.locator('.bk-pc[data-slug="testi-taynna"]').count()) === 0, `${tag} päivänäkymä: aina täynnä oleva tuote ei saa näkyä`);
  await page.locator('.bk-pc[data-slug="testi-yleinen"] .bk-pc-head').click();
  const dayTimes = await visibleTimes(page, '.bk-pc[data-slug="testi-yleinen"] .bk-pc-panel');
  expect(starts(dayTimes).join() === '10,14', `${tag} päivänäkymä: tuotekortissa vain 10:00 ja 14:00, nyt ${JSON.stringify(dayTimes)}`);
  expect((await page.locator('.bk-pc .bk-slot.full, .bk-pc .bk-slot.unavailable').count()) === 0, `${tag} päivänäkymä: .bk-slot.full/.unavailable ei saa olla kortissa`);
  expect(!T.full.test(await page.locator('.bk-dayresults').innerText()), `${tag} päivänäkymä: teksti "täynnä" ei saa näkyä tuloksissa`);
  expect((await page.locator('.bk-pc[data-slug="testi-yleinen"] .bk-slot a.btn').count()) === 2, `${tag} päivänäkymä: kaksi Valitse-painiketta`);
  await page.locator('.bk-pc[data-slug="testi-yksityinen"] .bk-pc-head').click();
  const privTimes = await visibleTimes(page, '.bk-pc[data-slug="testi-yksityinen"] .bk-pc-panel');
  expect(starts(privTimes).join() === '18', `${tag} päivänäkymä: yksityisvuoro: vain 18:00 (ei-varattava 20:30 piiloon), nyt ${JSON.stringify(privTimes)}`);
  await shot(page, `vapaat-${lang}-1-paivanakyma-390.png`);
  await page.locator('.bk-pc[data-slug="testi-yleinen"] .bk-pc-head').click();
  await page.locator('.bk-pc[data-slug="testi-yleinen"] .bk-slot a.btn').nth(1).click();   // 14:00
  await page.waitForSelector('form.bk-form');
  expect(/14(:00)?–15:30/.test(await page.locator('.bk-sum').innerText()), `${tag} päivänäkymä: Valitse (14:00) vie lomakkeelle, yhteenvedossa 14:00`);

  // 1b) päivä jolla kaikki täynnä: järkevä tyhjä-teksti (ei tyhjää listaa)
  await page.goto(`${BASE}${path}#/paiva/${D2}`);
  await page.reload();
  await page.waitForSelector('.bk-dayresults');
  expect((await page.locator('.bk-dayresults .bk-notice').innerText()).includes(lang === 'fi' ? 'Ei vapaita vuoroja valitulle päivälle.' : 'No available sessions for the selected date.'), `${tag} päivänäkymä: kaikki täynnä → noSlotsDay-viesti`);
  expect((await page.locator('.bk-dayresults .bk-slot, .bk-dayresults ul.bk-slotlist').count()) === 0, `${tag} päivänäkymä (kaikki täynnä): vuoroja/tyhjää listaa ei saa olla`);
  await shot(page, `vapaat-${lang}-2-paiva-kaikki-taynna-390.png`);

  // 2) tuotesivu: vain vapaat; kokonaan täynnä oleva päivä on klikattavissa → t.noSlots
  await page.goto(`${BASE}${path}#/tuote/testi-yleinen/${D1}`);
  await page.reload();
  await page.waitForSelector('.bk-prod .bk-slots .bk-slotlist');
  const prodTimes = await visibleTimes(page, '.bk-prod .bk-slots');
  expect(starts(prodTimes).join() === '10,14', `${tag} tuotesivu: vain 10:00 ja 14:00, nyt ${JSON.stringify(prodTimes)}`);
  expect((await page.locator('.bk-prod .bk-slot.full').count()) === 0 && !T.full.test(await page.locator('.bk-prod .bk-slots').innerText()), `${tag} tuotesivu: täynnä-vuoroja ei saa näkyä`);
  await shot(page, `vapaat-${lang}-3-tuotesivu-390.png`);
  const fullCell = page.locator('.bk-grid button.bk-cell.full');
  expect((await fullCell.count()) >= 1, `${tag} tuotesivu: kalenterissa pitäisi olla täynnä-päivä (esim. ${D2})`);
  await page.locator('.bk-grid button.bk-cell.full').first().click();   // kalenterin täynnä-päivä on klikattava
  await page.waitForSelector('.bk-prod .bk-slots p', { timeout: 3000 }).catch(() => {});
  expect((await page.locator('.bk-prod .bk-slots').innerText()).includes(T.noSlots), `${tag} tuotesivu: täynnä-päivä → "${T.noSlots}"`);
  expect((await page.locator('.bk-prod .bk-slots .bk-slotlist').count()) === 0, `${tag} tuotesivu: täynnä-päivällä ei saa olla tyhjää listaa`);
  await shot(page, `vapaat-${lang}-4-tuotesivu-taynna-paiva-390.png`);
  // Valitse toimii tuotesivulla
  await page.goto(`${BASE}${path}#/tuote/testi-yleinen/${D1}`); await page.reload();
  await page.waitForSelector('.bk-prod .bk-slot a.btn');
  await page.locator('.bk-prod .bk-slot a.btn').first().click();
  await page.waitForSelector('form.bk-form');
  expect(/10(:00)?–11:30/.test(await page.locator('.bk-sum').innerText()), `${tag} tuotesivu: Valitse (10:00) vie lomakkeelle`);

  // 3) ajanmuutosnäkymä: ei täynnä olevia, ei myöhästyneitä; nykyinen valinta (täynnä, oma) säilyy; vapaa 14:00 valittavissa
  page.__changeView = true;
  await page.goto(`${BASE}${lang === 'en' ? '/en/book/confirmation/' : '/varaa/vahvistus/'}#${TOKEN}/muuta`);
  await page.reload();
  await page.waitForSelector('.bk-slots .bk-slotlist');
  const chRows = await page.locator('.bk-slots .bk-slot').evaluateAll((els) => els.map((e) => ({ time: e.querySelector('.bk-time').textContent, cls: e.className, dis: e.querySelector('[role=radio]').disabled, txt: e.querySelector('[role=radio]').textContent })));
  expect(starts(chRows.map((r) => r.time)).join() === '10,14', `${tag} muutos: vain nykyinen 10:00 ja vapaa 14:00, nyt ${JSON.stringify(chRows)}`);
  expect(chRows[0]?.txt.includes(T.current) && chRows[1]?.dis === false, `${tag} muutos: nykyinen merkitty, 14:00 valittavissa`);
  expect(!T.full.test(await page.locator('.bk-slots').innerText()), `${tag} muutos: "täynnä" ei saa näkyä`);
  await shot(page, `vapaat-${lang}-5-muutos-390.png`);
  const submit = page.locator('form.bk-form button[type=submit]');
  expect(await submit.isDisabled(), `${tag} muutos: tallennus pois käytöstä ennen valintaa`);
  await page.locator('.bk-slots .bk-slot').nth(1).locator('[role=radio]').click({ timeout: 3000 }).catch(() => {});
  expect((await page.locator('.bk-slots .bk-slot').nth(1).locator('[role=radio]').getAttribute('aria-checked')) === 'true' && !(await submit.isDisabled()), `${tag} muutos: Valitse (14:00) valitsee vuoron ja sallii tallennuksen`);
  const before = calls.length;
  if (!(await submit.isDisabled())) await submit.click();
  await page.waitForFunction(() => !location.hash.includes('muuta'), null, { timeout: 5000 }).catch(() => {});
  const ch = calls.slice(before).find((c) => c.fn === 'public_change_booking');
  expect(ch && ch.args.p_rule_id === 3 && ch.args.p_date === D1, `${tag} muutos: public_change_booking kutsuttu valitulla vuorolla (rule 3, ${D1}), nyt ${JSON.stringify(ch?.args)}`);
  // pelkkä myöhästynyt vapaa vuoro (alle 48 h) ja täynnä → ei rivejä, t.noSlots
  await page.goto(`${BASE}${lang === 'en' ? '/en/book/confirmation/' : '/varaa/vahvistus/'}#${TOKEN}/muuta`); await page.reload();
  await page.waitForSelector('#bk-date');
  await page.fill('#bk-date', SOON); await page.dispatchEvent('#bk-date', 'change');
  await page.waitForFunction((s) => document.querySelector('.bk-slots')?.innerText.includes(s), T.noSlots, { timeout: 5000 }).catch(() => {});
  expect((await page.locator('.bk-slots').innerText()).includes(T.noSlots) && (await page.locator('.bk-slots .bk-slot').count()) === 0, `${tag} muutos: päivä jolla vain myöhästynyt + täynnä → "${T.noSlots}", ei rivejä`);
  await shot(page, `vapaat-${lang}-6-muutos-ei-vapaita-390.png`);
  await ctx.close();
}

// 4) leveä näkymä (1280): sama päivänäkymä, ei vuorolistan täynnä-rivejä
{
  const { ctx, page } = await newPage('fi', 1280);
  await page.goto(`${BASE}/varaa/#/paiva/${D1}`);
  await page.waitForSelector('.bk-pc');
  await page.locator('.bk-pc[data-slug="testi-yleinen"] .bk-pc-head').click();
  expect((await page.locator('.bk-pc[data-slug="testi-yleinen"] .bk-slot').count()) === 2, 'fi/1280 päivänäkymä: yleisellä tuotteella vain 2 vapaata vuoroa');
  expect((await page.locator('.bk-pc .bk-slot.full').count()) === 0, 'fi/1280 päivänäkymä: ei .bk-slot.full');
  await ctx.close();
}

await browser.close(); server.close();
console.log(`${checks} tarkistusta, ${problems.length} ongelmaa`);
if (problems.length) { for (const p of problems) console.error(' ✗', p); process.exit(1); }
console.log('OK: asiakasnäkymässä vain vapaat vuorot');
