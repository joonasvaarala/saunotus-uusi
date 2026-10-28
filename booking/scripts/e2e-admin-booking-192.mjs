// Playwright: lahjakorttikenttä, välitön ylibuukkausvaroitus ja vahvistus. Vain mock, ei tietokantaa.
//   PW_DIR=/workspace/node_modules node booking/scripts/e2e-admin-booking-192.mjs
import { startServer, launch, newPage, ORIGIN, DAY } from './nb-mock-harness.mjs';

const problems = [];
const expect = (ok, msg) => { if (!ok) problems.push(msg); };
const server = await startServer();
const browser = await launch();

async function fillCustomer(page) {
  await page.locator('input[name=cname]').fill('Matti Testi');
  await page.locator('input[name=cemail]').fill('matti192@example.test');
}

for (const vp of [390, 1280]) {
  const st = { calls: [] };
  const page = await newPage(browser, { vp, st, onProblem: (m) => problems.push(`${vp} ${m}`) });
  await page.setViewportSize({ width: vp, height: vp >= 900 ? 900 : 844 });
  await page.goto(`${ORIGIN}/admin/#/uusi?d=${DAY}`);
  await page.waitForSelector('.slotbtn');
  const giftHidden = await page.locator('[data-testid=gift-card-field]').count();
  expect(giftHidden === 0 || await page.locator('[data-testid=gift-card-field]').isHidden(), `${vp}: lahjakorttikenttä piilossa ennen valintaa`);
  await page.locator('.slotbtn').nth(1).click();
  await page.waitForSelector('[data-testid=booking-form]');
  await page.waitForTimeout(400);
  const warn = (await page.locator('[data-testid=booking-warning]').innerText()).replace(/\s+/g, ' ');
  expect(/12\/10/.test(warn), `${vp}: varoitus heti 12/10, oli "${warn}"`);
  await page.locator('select[name=method]').selectOption('gift_card');
  expect(await page.locator('[data-testid=gift-card-field]').isVisible(), `${vp}: lahjakorttikenttä näkyy`);
  await page.locator('[data-testid=gift-code]').fill('TESTCARD0001');
  await page.locator('[data-testid=gift-check]').click();
  await page.waitForTimeout(200);
  expect(/Saldo/.test(await page.locator('[data-testid=gift-status]').innerText()), `${vp}: Tarkista näyttää saldon`);
  expect(await page.locator('[data-testid=gift-remainder]').isVisible(), `${vp}: loppusumman tapa`);
  await page.locator('[data-testid=discount-code]').fill('KIITOSKAUPPA');
  await page.locator('[data-testid=discount-apply]').click();
  await page.waitForTimeout(300);
  expect(/KIITOSKAUPPA/.test(await page.locator('[data-testid=discount-status]').innerText()), `${vp}: alennuskoodi`);
  expect(/Alennus/.test(await page.locator('[data-testid=price-summary]').innerText()), `${vp}: alennusrivi yhteensä`);
  await page.locator('[data-testid=discount-remove]').click();
  expect(!(await page.locator('[data-testid=price-summary]').innerText()).includes('KIITOSKAUPPA'), `${vp}: koodi poistuu`);
  await fillCustomer(page);
  await page.locator('[data-testid=save-booking]').click();
  await page.waitForSelector('[data-testid=confirm-dialog]');
  const ask = await page.locator('[data-testid=confirm-dialog]').innerText();
  expect(/Haluatko varmasti ylibuukata/.test(ask), `${vp}: vahvistusdialogi`);
  await page.locator('[data-testid=confirm-no]').click();
  expect(st.calls.filter((c) => c.name === 'admin_create_booking').length === 0, `${vp}: peruutus ei tallenna`);
  await page.locator('[data-testid=save-booking]').click();
  await page.locator('[data-testid=confirm-yes]').click();
  await page.waitForTimeout(400);
  const saved = st.calls.filter((c) => c.name === 'admin_create_booking').at(-1);
  expect(saved?.args?.p_allow_overbook === true, `${vp}: tallennus lähettää ylibuukkauslipun`);
  expect(saved?.args?.p_gift_card_code === 'TESTCARD0001', `${vp}: lahjakortin koodi mukana`);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
  expect(!overflow, `${vp}: ei vaakavieritystä`);
  await page.close();
}

await browser.close();
server.close();
if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
console.log('e2e-admin-booking-192 ok');
