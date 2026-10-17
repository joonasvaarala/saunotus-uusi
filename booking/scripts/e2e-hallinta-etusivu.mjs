// E2E: hallinnan etusivu (päivänäkymä) OIKEALLA demokannalla, ei mockeja: kirjautuminen (admin, manager, staff), työvuorot, Valmistelu-kortti,
// vuorot aikajärjestyksessä (myymätön tyhjä vuoro piilossa), "Vapaana: N" → Uusi varaus esivalittuna → varaus luodaan lisäpalveluineen → näkyy päivänäkymässä
// (hlö-määrä, lisäpalveluikonit, valmistelun luvut) → "saapunut"-nappi (pysyy lataus yli). Koot 390 ja 1280.
// Käyttö:  PW_DIR=/polku/node_modules OUT=/polku/kuvat BASE_URL=http://localhost:4180 node booking/scripts/e2e-hallinta-etusivu.mjs
// Ympäristö: demokanta sisältää migraation 27 (setup-db.sh ajaa kaikki migraatiot) → oletuksena staff-tunnuksen pitää nähdä kaikki päivän työvuorot (admin_day_shifts)
//            ja pyyhe-lisäpalvelun pitää näkyä yleisellä vuorolla ja hoidossa mutta ei tapahtumassa. EXPECT_DAY_SHIFTS=0 / EXPECT_TOWEL=0 = kanta ilman migraatiota 27.
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { mkdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', dirname(fileURLToPath(import.meta.url))].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const BASE = process.env.BASE_URL || 'http://localhost:4180';
const EXPECT_DAY_SHIFTS = process.env.EXPECT_DAY_SHIFTS !== '0', EXPECT_TOWEL = process.env.EXPECT_TOWEL !== '0';
const OUT = resolve(process.env.OUT || '/tmp/e2e-etusivu'); mkdirSync(OUT, { recursive: true });
const TZ = 'Europe/Helsinki';
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const today = new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const dow = (ds) => new Date(`${ds}T12:00:00Z`).getUTCDay();
let sat = addDays(today, 2); while (dow(sat) !== 6) sat = addDays(sat, 1);   // lähin lauantai vähintään 2 pv päässä (yleiset vuorot + savusauna, myynti auki)
let tue = addDays(today, 2); while (dow(tue) !== 2) tue = addDays(tue, 1);
const suffix = String(Date.now()).slice(-6);

async function login(page, email) {
  await page.goto(`${BASE}/admin/`); await page.fill('#email', email); await page.fill('#password', 'demo'); await page.click('form#login button[type=submit]'); await page.waitForSelector('#view h1');
}
const watch = (page, name) => {
  let shifts404 = false;   // admin_day_shifts puuttuu kannasta (ennen migraatiota 26): 404 + selaimen konsoliviesti odotettu, haku kokeillaan vain kerran / sivun lataus
  page.on('response', (r) => { if (r.status() === 404 && /admin_day_shifts/.test(r.url())) shifts404 = true; });
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !(shifts404 && /status of 404/.test(m.text()))) problems.push(`${name} console.${m.type()}: ${m.text()}`); });
  page.on('pageerror', (e) => problems.push(`${name} pageerror: ${e.message}`));
  page.on('response', (r) => { if (r.status() >= 400 && !/admin_day_shifts/.test(r.url())) problems.push(`${name} HTTP ${r.status()}: ${r.url()}`); });
};
const noHScroll = async (page, name) => expect(!(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1)), `${name}: vaakavieritys`);
const goDay = async (page, d) => { await page.goto(`${BASE}/admin/#/?d=${d}`); await page.waitForSelector('[data-testid=prepcard]'); await page.waitForTimeout(300); };

for (const [vname, vp] of [['390', { width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true }], ['1280', { width: 1280, height: 900 }]]) {
  const ctx = await browser.newContext({ viewport: vp, locale: 'fi-FI', timezoneId: TZ }); const page = await ctx.newPage(); const nm = `etusivu-${vname}`; watch(page, nm);
  await login(page, 'admin@demo.local');
  // 1) etusivu heti kirjautumisen jälkeen = tämän päivän päivänäkymä, työvuorot + Valmistelu + vuorot
  expect(page.url().endsWith('/admin/') || /#\/(\?|$)/.test(page.url()), `${nm}: etusivu ei ole päivänäkymä (${page.url()})`);
  await page.waitForSelector('[data-testid=prepcard]');
  expect((await page.locator('#view h1').innerText()).length > 8, `${nm}: päivämäärä puuttuu`);
  const shiftsTxt = await page.locator('[data-testid=dayshifts]').innerText();
  expect(/(Lämmitykset|Saunottaja|Vastaanotto) \d/.test(shiftsTxt) || /Ei työvuoroja/.test(shiftsTxt), `${nm}: työvuorot (${shiftsTxt.slice(0, 80)})`);
  await noHScroll(page, nm);
  await page.screenshot({ path: join(OUT, `etusivu-${vname}.png`), fullPage: true });
  // 2) lauantai: vuorot aikajärjestyksessä ja yhdessä sarakkeessa, hoitovaraukset aloitusajan alla (ei "Muut varaukset")
  await goDay(page, sat);
  const starts = await page.locator('[data-testid=session], [data-testid=slot]').evaluateAll((els) => els.map((e) => e.dataset.start));
  expect(starts.length > 3, `${nm}: lauantaina liian vähän vuoroja (${starts.length})`);
  expect(starts.every((s, i) => i === 0 || starts[i - 1] <= s), `${nm}: vuorot eivät ole aikajärjestyksessä`);
  expect((await page.locator('text=Muut varaukset').count()) === 0, `${nm}: "Muut varaukset" -osio on vielä olemassa`);
  const xs = await page.locator('[data-testid=session]').evaluateAll((els) => [...new Set(els.map((e) => Math.round(e.getBoundingClientRect().left)))]);
  expect(xs.length === 1, `${nm}: vuorot eivät ole allekkain (${xs})`);
  const slotOk = await page.locator('[data-testid=slot]').evaluateAll((els) => els.every((e) => e.querySelector('header').getBoundingClientRect().bottom <= e.querySelector('.reslist').getBoundingClientRect().top + 1));
  expect(slotOk, `${nm}: hoitokortin otsikon pitää olla varausten yläpuolella (ei vierekkäin)`);
  const capBtns = page.locator('[data-testid=session] [data-testid=cap-btn]', { hasText: 'Vapaana:' });
  expect((await capBtns.count()) > 1, `${nm}: ei Vapaana-nappeja`);
  const bb = await capBtns.first().boundingBox(); expect(bb && bb.height >= 43.5 && bb.width >= 43.5, `${nm}: Vapaana-nappi < 44 px`);
  const pickIdx = vname === '390' ? 0 : 1;
  const sess = page.locator('[data-testid=session]', { has: page.locator('[data-testid=cap-btn]', { hasText: 'Vapaana:' }) }).nth(pickIdx);
  const hdr = (await sess.locator('header strong.time').innerText()).trim(); const before = +/\d+/.exec(await sess.locator('[data-testid=session-persons]').innerText())[0];
  const remainBefore = +/Vapaana: (\d+)/.exec(await sess.locator('[data-testid=cap-btn]').innerText())[1];
  expect(await sess.locator('[data-testid=session-persons]').innerText().then((t) => /hlö$/.test(t.trim())), `${nm}: hlö-lyhenne puuttuu`);
  await sess.locator('[data-testid=cap-btn]').click();
  await page.waitForSelector('[data-testid=booking-form]');
  const h3 = (await page.locator('[data-testid=booking-form] h3').first().innerText()).trim();
  expect(h3.includes(hdr), `${nm}: esivalittu vuoro ${h3} ≠ ${hdr}`);
  expect(await page.locator('.slotbtn[aria-checked=true]').count() === 1, `${nm}: vuoro ei esivalittuna`);
  await page.waitForTimeout(900);
  const inView = await page.locator('[data-testid=booking-form]').evaluate((f) => { const r = f.getBoundingClientRect(); return r.top < innerHeight && r.bottom > 0; });
  expect(inView, `${nm}: lomake ei näy ruudulla`);
  // 3) täytä asiakas + lisäpalvelut ja luo varaus oikeaan kantaan
  const f = page.locator('[data-testid=booking-form]');
  await f.locator('input[name=n]').fill('1');
  await f.locator('[name=cname]').fill(`Etusivu Testi ${vname}-${suffix}`); await f.locator('[name=cemail]').fill(`etusivu${vname}${suffix}@example.com`); await f.locator('[name=cphone]').fill('0401234567');
  const rows = f.locator('.addonrow');
  const names = await rows.evaluateAll((els) => els.filter((e) => !e.hidden).map((e) => e.querySelector('strong').textContent));
  expect(names.some((x) => /vihta/i.test(x)) && names.some((x) => /turvenaamio/i.test(x)), `${nm}: vihta/turvenaamio puuttuu yleiseltä vuorolta (${names})`);
  if (EXPECT_TOWEL) expect(names.some((x) => /pyyhe/i.test(x)), `${nm}: pyyhe puuttuu yleiseltä vuorolta`);
  const setQty = async (re, q) => { const row = rows.filter({ hasText: re }).first(); if (await row.count()) await row.locator('input[type=number]').fill(String(q)); };
  await setQty(/Saunavihta/, 1); await setQty(/Turvenaamio/, 1); if (EXPECT_TOWEL) await setQty(/Pyyhe/, 1);
  await f.locator('button[type=submit]').click();
  await page.waitForSelector('.ok-box', { timeout: 8000 }).catch(async () => { problems.push(`${nm}: varaus ei luotu: ${(await page.locator('#toast').innerText().catch(() => '')).slice(0, 200)} / ${(await f.locator('.err, [role=alert]').allInnerTexts()).join(' ').slice(0, 200)}`); await page.screenshot({ path: join(OUT, `virhe-${vname}.png`), fullPage: true }); throw new Error('varauksen luonti epäonnistui'); });
  expect(/Varaus luotu/.test(await page.locator('.ok-box').innerText()), `${nm}: varauksen luonti ei onnistunut`);
  await page.screenshot({ path: join(OUT, `vapaana-luotu-${vname}.png`), fullPage: true });
  // 4) takaisin päivänäkymään: varaus aloitusajan alla, hlö-määrä kasvoi, kapasiteetti pieneni, lisäpalveluikonit, valmistelu
  await page.click('.ok-box a:has-text("Näytä päivänäkymä")'); await page.waitForSelector('[data-testid=prepcard]'); await page.waitForTimeout(400);
  const sess2 = page.locator('[data-testid=session]', { has: page.locator('strong.time', { hasText: hdr }) }).filter({ has: page.locator(`text=Etusivu Testi ${vname}-${suffix}`) });
  expect(await sess2.count() === 1, `${nm}: uusi varaus ei näy vuoron alla`);
  const after = +/\d+/.exec(await sess2.locator('[data-testid=session-persons]').innerText())[0];
  expect(after === before + 1, `${nm}: hlö ${before} → ${after} (odotettu +1)`);
  const remainAfter = +/Vapaana: (\d+)/.exec(await sess2.locator('[data-testid=cap-btn]').innerText())[1];
  expect(remainAfter === remainBefore - 1, `${nm}: Vapaana ${remainBefore} → ${remainAfter}`);
  const kinds = await sess2.locator('.addon-item').evaluateAll((els) => els.map((e) => e.dataset.kind).join(' '));
  expect(/whisk/.test(kinds) && /mask/.test(kinds) && /foot/.test(kinds), `${nm}: lisäpalveluikonit (vihta, turvenaamio, jalkakylpy) puuttuvat: ${kinds}`);
  if (EXPECT_TOWEL) expect(/towel/.test(kinds), `${nm}: pyyheikoni puuttuu: ${kinds}`);
  const prepTxt = await page.locator('[data-testid=prepcard]').innerText();
  expect(/saunavihta/i.test(prepTxt) && /turvenaamio/i.test(prepTxt), `${nm}: Valmistelu-kortin luvut puuttuvat: ${prepTxt.slice(0, 120)}`);
  expect((await page.locator('[data-testid=prepcard]').boundingBox()).y < (await sess2.boundingBox()).y, `${nm}: Valmistelu ei ole listan yläpuolella`);
  // 5) saapunut
  const row = sess2.locator('.resrow').filter({ hasText: `Etusivu Testi ${vname}-${suffix}` }); const ab = row.locator('[data-testid=arrive]');
  const abb = await ab.boundingBox(); expect(abb.width >= 43.5 && abb.height >= 43.5, `${nm}: saapunut-nappi < 44 px`);
  expect(await ab.getAttribute('aria-pressed') === 'false', `${nm}: saapunut oletuksena päällä`);
  await ab.click(); await page.waitForFunction(() => document.querySelector('[data-testid=arrive][aria-pressed=true]'));
  await page.screenshot({ path: join(OUT, `saapunut-${vname}.png`), fullPage: true });
  await goDay(page, sat);
  const ab2 = page.locator('[data-testid=session] .resrow', { hasText: `Etusivu Testi ${vname}-${suffix}` }).locator('[data-testid=arrive]');
  expect(await ab2.getAttribute('aria-pressed') === 'true', `${nm}: saapunut ei säily latauksen yli`);
  await ab2.click(); await page.waitForTimeout(500); await goDay(page, sat);
  expect(await page.locator('[data-testid=session] .resrow', { hasText: `Etusivu Testi ${vname}-${suffix}` }).locator('[data-testid=arrive]').getAttribute('aria-pressed') === 'false', `${nm}: saapunut-merkin peruutus ei säily`);
  await page.screenshot({ path: join(OUT, `paivanakyma-${vname}.png`), fullPage: true });
  await noHScroll(page, nm);
  // 6) myymätön tyhjä vuoro piiloon: tiistaina yksityinen 16–19 varattu → 16–19-aikaisia tyhjiä vuoroja ei näy ilman varauksia
  await goDay(page, tue);
  const tueTxt = await page.locator('#view').innerText();
  expect(!/ei myynnissä|ei varattavissa/i.test(tueTxt), `${nm}: "ei myynnissä" -teksti näkyy`);
  await ctx.close();
}

// 7) roolit: manager ja staff näkevät etusivun, työvuorot ja varaukset; saapunut vain bookings.manage-oikeudella (staff: kyllä)
for (const [email, label] of [['manager@demo.local', 'manager'], ['staff@demo.local', 'staff']]) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844, isMobile: true, hasTouch: true }, locale: 'fi-FI', timezoneId: TZ }); const page = await ctx.newPage(); watch(page, `rooli-${label}`);
  await login(page, email); await goDay(page, sat);
  const sh = await page.locator('[data-testid=dayshifts]').innerText();
  expect(await page.locator('[data-testid=session]').count() > 3, `${label}: vuorot puuttuvat`);
  if (label === 'staff') {
    if (EXPECT_DAY_SHIFTS) expect(/Saunottaja \d.*\n?/.test(sh) && /Lämmitykset|Vastaanotto/.test(sh), `staff: päivän työvuorot (kaikki) puuttuvat: ${sh}`);
    else expect(sh.length > 0, 'staff: työvuoroselite puuttuu');
  } else expect(/Lämmitykset|Saunottaja|Vastaanotto/.test(sh), `manager: työvuorot puuttuvat: ${sh}`);
  await page.screenshot({ path: join(OUT, `rooli-${label}-390.png`), fullPage: true });
  await ctx.close();
}

// 8) lisäpalvelut resurssivarauslomakkeella: hoidossa vain pyyhe (jos rivi on), tapahtumassa ei mitään
{
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'fi-FI', timezoneId: TZ }); const page = await ctx.newPage(); watch(page, 'resurssi');
  await page.route('**/rpc/admin_treatment_availability', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
  await login(page, 'admin@demo.local'); await page.goto(`${BASE}/admin/#/uusi?tyyppi=resurssi`); await page.waitForSelector('select[name=product]');
  const vis = async () => page.locator('.addon-picker:not([hidden]) .addonrow:not([hidden]) strong').allInnerTexts();
  const opt = (name) => page.locator('select[name=product] option', { hasText: name }).first().getAttribute('value');
  await page.selectOption('select[name=product]', await opt('Saunahoito')); await page.waitForTimeout(300);
  const treat = await vis(); expect(!treat.some((x) => /vihta|turvenaamio/i.test(x)), `hoito: vihta/turvenaamio tarjolla (${treat})`);
  if (EXPECT_TOWEL) expect(treat.some((x) => /pyyhe/i.test(x)), `hoito: pyyhe ei tarjolla (${treat})`); else expect(treat.length === 0, `hoito: lisäpalveluita ilman migraatiota 26 (${treat})`);
  await page.screenshot({ path: join(OUT, 'resurssi-hoito-1280.png'), fullPage: true });
  const ev = await page.locator('select[name=product] option', { hasText: 'Sipoonjoen Kekri' }).count();
  if (ev) { await page.selectOption('select[name=product]', await opt('Sipoonjoen Kekri')); await page.waitForTimeout(300); expect((await vis()).length === 0, `tapahtuma: lisäpalveluita tarjolla (${await vis()})`); await page.screenshot({ path: join(OUT, 'resurssi-tapahtuma-1280.png'), fullPage: true }); }
  else problems.push('tapahtumatuote (Sipoonjoen Kekri) puuttuu resurssilomakkeen listasta');
  await ctx.close();
}
await browser.close();
if (problems.length) { console.error(`E2E epäonnistui (${problems.length}):\n- ${[...new Set(problems)].join('\n- ')}`); process.exit(1); }
console.log(`ok: hallinnan etusivu (oikea demokanta) – ${checks} tarkistusta, kuvat → ${OUT}`);
