// E2E (Playwright + google-chrome): hallinnan "Uusi varaus" -vuo, stepper, hallinnan alapalkki ja tilauslinkit – vain mock-datalla, EI tuotantokantaa.
//   PW_DIR=/workspace/node_modules SHOT_DIR=/workspace/screenshots-uusi-varaus node booking/scripts/e2e-uusi-varaus.mjs
// Ympäristö: SHOT_DIR (oletus /workspace/screenshots-uusi-varaus), CHROME, SHOTS=0 (ei kuvia), VPS=360,390,430,768,1280
import { mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { startServer, launch, newPage, ORIGIN, DAY } from './nb-mock-harness.mjs';
const SHOT = resolve(process.env.SHOT_DIR || '/workspace/screenshots-uusi-varaus'); mkdirSync(SHOT, { recursive: true });
const SHOTS = process.env.SHOTS !== '0';
const VPS = (process.env.VPS || '360,390,430,768,1280').split(',').map(Number);
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const server = await startServer(); const browser = await launch();
const shot = async (page, name, o = {}) => { if (SHOTS) await page.screenshot({ path: join(SHOT, `${name}.png`), ...o }); };

async function layoutChecks(page, label, scope = '.nb') {
  const r = await page.evaluate((scope) => {
    const out = { overflow: [], small: [], contrast: [] };
    const vw = innerWidth, root = document.querySelector(scope) || document.body;
    if (document.documentElement.scrollWidth > vw + 0.5) out.overflow.push(`document ${document.documentElement.scrollWidth} > ${vw}`);
    for (const el of root.querySelectorAll('*')) { const b = el.getBoundingClientRect(); if (b.width && b.right > vw + 1 && getComputedStyle(el).position !== 'fixed' && !el.closest('[hidden]')) out.overflow.push(`${el.tagName}.${el.className?.baseVal ?? el.className} right=${Math.round(b.right)}`); }
    const vis = (el) => { const b = el.getBoundingClientRect(), cs = getComputedStyle(el); return b.width > 0 && b.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
    for (const el of root.querySelectorAll('button,a[href],select,input:not([type=hidden]):not([type=checkbox]):not([type=radio]),textarea,summary')) { if (!vis(el)) continue; const b = el.getBoundingClientRect(); if (b.height < 43.5 || b.width < 43.5) out.small.push(`${el.tagName}.${el.className} ${Math.round(b.width)}x${Math.round(b.height)}`); }
    for (const el of root.querySelectorAll('label.check, .kindopt')) { if (!vis(el)) continue; const b = el.getBoundingClientRect(); if (b.height < 43.5) out.small.push(`label ${Math.round(b.height)}`); }
    const lum = ([r, g, b]) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
    const parse = (c) => { const m = /rgba?\(([\d.]+)[, ]+([\d.]+)[, ]+([\d.]+)(?:[,/ ]+([\d.]+))?/.exec(c); return m ? [+m[1], +m[2], +m[3], m[4] == null ? 1 : +m[4]] : [0, 0, 0, 0]; };
    const bgOf = (el) => { const stack = []; for (let e = el; e; e = e.parentElement) { const c = parse(getComputedStyle(e).backgroundColor); if (c[3] > 0) { stack.push(c); if (c[3] >= 0.99) break; } } let base = [255, 255, 255]; for (const c of stack.reverse()) base = base.map((v, i) => c[i] * c[3] + v * (1 - c[3])); return base; };
    for (const el of root.querySelectorAll('*')) {
      if (!vis(el) || el.disabled || el.closest('button:disabled')) continue;
      if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) continue;
      if (el.closest('.slotbtn.full, .slotbtn.unavailable')) continue;
      const fg = parse(getComputedStyle(el).color), bg = bgOf(el);
      const f = [0, 1, 2].map((i) => fg[i] * fg[3] + bg[i] * (1 - fg[3]));
      const L1 = lum(f), L2 = lum(bg), ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
      if (ratio < 4.5) out.contrast.push(`${el.tagName}.${el.className} "${el.textContent.trim().slice(0, 24)}" ${ratio.toFixed(2)}`);
    }
    return out;
  }, scope);
  expect(!r.overflow.length, `${label}: vaakavieritys/ylivuoto: ${r.overflow.slice(0, 4).join(' | ')}`);
  expect(!r.small.length, `${label}: alle 44 px kosketuskohteet: ${[...new Set(r.small)].slice(0, 6).join(' | ')}`);
  expect(!r.contrast.length, `${label}: kontrasti <4,5: ${[...new Set(r.contrast)].slice(0, 5).join(' | ')}`);
}
const T0 = 8000;
const calls = (st, name) => st.calls.filter((c) => c.name === name);
const open = async (page, hash = `#/uusi?d=${DAY}`) => { await page.goto(`${ORIGIN}/admin/${hash}`); await page.waitForSelector('.slotbtn, #view h1'); };
const pickSlot = async (page, n = 0) => { await page.locator('.slotbtn:not([disabled])').nth(n).click(); await page.waitForSelector('[data-testid=booking-form]'); await page.waitForTimeout(700); };
const clickBtn = (scope, name) => scope.getByRole('button', { name, exact: true });

// ---------- 1) FI: vuo, stepper, validointi, laskun viite, tallennus ----------
for (const vp of VPS) {
  const name = `fi-${vp}`, st = { calls: [] };
  const page = await newPage(browser, { vp, st, onProblem: (m) => problems.push(`${name} ${m}`) });
  await open(page);
  expect(await page.locator('#view h1').innerText() === 'Uusi varaus', `${name}: otsikko`);
  expect(await page.locator('.nb-sec .nb-h').first().innerText() === 'Vuoro ja päivä', `${name}: osio 1`);
  await shot(page, `jalkeen-1-vuorot-${vp}`, { fullPage: true });
  await pickSlot(page);
  const form = page.locator('[data-testid=booking-form]');
  const heads = await form.locator('.nb-h, .addon-picker > legend').evaluateAll((els) => els.map((e) => ({ t: e.textContent.trim(), n: getComputedStyle(e, '::before').counterIncrement })));
  expect(heads.map((x) => x.t).join('|') === 'Henkilömäärä|Asiakas|Lisäpalvelut|Maksu ja hinta|Muistiinpano', `${name}: osiot (${heads.map((x) => x.t)})`);
  expect(heads.every((x) => /nbs/.test(x.n)), `${name}: osioiden numerointi (${heads.map((x) => x.n)})`);
  expect((await form.locator('h3').first().innerText()).includes('16:00–17:30'), `${name}: valittu vuoro ensimmäisenä`);
  // lisäpalvelurivi: nimi + hinta + tiivis kuvaus; turha toisto piilossa
  const towel = form.locator('.addonrow[data-addon=pyyhe]');
  expect(await towel.locator('strong').allInnerTexts().then((a) => a.join() === 'Pyyhe'), `${name}: rivin strong = nimi`);
  expect(/5,00\s€ \/ kpl/.test((await towel.locator('.addon-price').innerText()).replace(/\u00a0/g, ' ')), `${name}: hinta / kpl`);
  expect(await form.locator('.addon-desc').count() === 0, `${name}: kuvaus joka vain toistaa nimen piilotetaan`);
  // stepper
  const dec = clickBtn(towel, 'Vähennä: Pyyhe'), inc = clickBtn(towel, 'Lisää: Pyyhe'), qty = towel.getByLabel('Pyyhe, määrä');
  expect(await qty.getAttribute('inputmode') === 'numeric' && await qty.inputValue() === '0', `${name}: määräkenttä numeric, 0`);
  expect(await dec.isDisabled() && await inc.isEnabled(), `${name}: − pois käytöstä kun 0`);
  const bb = await Promise.all([dec.boundingBox(), inc.boundingBox(), qty.boundingBox()]);
  expect(bb.slice(0, 2).every((b) => b.width >= 43.5 && b.height >= 43.5) && bb[2].width < 70 && bb[2].width >= 40, `${name}: stepper-mitat (${bb.map((b) => `${Math.round(b.width)}x${Math.round(b.height)}`)})`);
  expect(await qty.evaluate((e) => getComputedStyle(e).textAlign) === 'center', `${name}: numero keskitetty`);
  await inc.click();
  expect(await qty.inputValue() === '1' && await inc.isDisabled() && await dec.isEnabled(), `${name}: 1 hlö → pyyhe enintään 1 (+ pois käytöstä)`);
  await clickBtn(form, 'Lisää: Henkilöä').click(); await clickBtn(form, 'Lisää: Henkilöä').click();
  expect(await form.locator('input[name=n]').inputValue() === '3' && await inc.isEnabled(), `${name}: henkilömäärä 3 → pyyhe enintään 3`);
  await inc.click(); await inc.click();
  expect(await qty.inputValue() === '3' && await inc.isDisabled(), `${name}: plus kunnioittaa maksimia (${await qty.inputValue()})`);
  await qty.fill('9'); expect(await qty.inputValue() === '3', `${name}: kenttä rajaa maksimiin`);
  await qty.fill('1a2'); expect(await qty.inputValue() === '12' || await qty.inputValue() === '3', `${name}: ei-numerot pois`);
  await qty.fill('2'); await qty.blur(); expect(await qty.inputValue() === '2', `${name}: suora kirjoitus`);
  await qty.fill(''); await qty.blur(); expect(await qty.inputValue() === '0', `${name}: tyhjä → 0`);
  await qty.fill('2'); await qty.blur();
  expect(/10,00\s€/.test((await form.locator('.addon-total').innerText()).replace(/\u00a0/g, ' ')), `${name}: lisäpalvelut yhteensä`);
  await clickBtn(form, 'Vähennä: Henkilöä').click();   // 3 → 2: raja 2, määrä pysyy 2
  await clickBtn(form, 'Vähennä: Henkilöä').click();   // 2 → 1: pyyhe rajautuu 1
  expect(await qty.inputValue() === '1', `${name}: henkilömäärän lasku rajaa lisäpalvelun (${await qty.inputValue()})`);
  await clickBtn(form, 'Lisää: Henkilöä').click();     // 2 hlö
  await inc.click();                                   // pyyhe 2
  expect(await form.locator('input[name=n]').inputValue() === '2', `${name}: 2 hlö`);
  // hintayhteenveto: vuoro 2 × 18 + lisäpalvelut 10 = 46
  const sum = (await form.locator('[data-testid=price-summary]').innerText()).replace(/\u00a0/g, ' ');
  expect(/Vuoro 36,00 € \+ lisäpalvelut 10,00 €/.test(sum) && /Yhteensä\s+46,00 €/.test(sum), `${name}: yhteenveto "${sum.replace(/\n/g, ' ')}"`);
  // Tallenna-painike: iso, näkyvissä, ei alapalkin alla (mobiili)
  const save = form.locator('[data-testid=save-booking]'); await save.scrollIntoViewIfNeeded();
  const sb = await save.boundingBox(); expect(sb.height >= 52, `${name}: Tallenna-painike iso (${Math.round(sb.height)})`);
  if (vp < 900) {
    await page.evaluate(() => { const f = document.querySelector('[data-testid=booking-form]'); scrollTo(0, f.getBoundingClientRect().top + scrollY - 70); }); await page.waitForTimeout(200);   // lomake näkyvissä (sticky toimii vain kun lomake on ruudulla)
    const r = await page.evaluate(() => { const b = document.querySelector('[data-testid=save-booking]').getBoundingClientRect(), n = document.querySelector('#nav').getBoundingClientRect(); return { sb: b.bottom, nt: n.top, vis: b.top >= 0 && b.bottom <= innerHeight }; });
    expect(r.vis && r.sb <= r.nt + 0.5, `${name}: sticky Tallenna ei jää alapalkin alle (${r.sb} / ${r.nt})`);
  }
  await layoutChecks(page, `${name} lomake`);
  await shot(page, `jalkeen-2-lomake-viewport-${vp}`);
  // validointi: tyhjä asiakas → virheet kenttien vieressä, ei RPC-kutsua, fokus ensimmäiseen
  await save.click(); await page.waitForTimeout(150);
  expect(await form.locator('.fld-err:not([hidden])').count() >= 2 && await form.locator('[aria-invalid=true]').count() >= 2, `${name}: virheet kentissä`);
  expect(await page.evaluate(() => document.activeElement?.name) === 'cname', `${name}: fokus nimikenttään`);
  expect(/Anna nimi/.test(await form.locator('input[name=cname]').locator('xpath=ancestor::label').locator('.fld-err').innerText()) && /sähköposti tai puhelinnumero/.test(await form.locator('input[name=cemail]').locator('xpath=ancestor::label').locator('.fld-err').innerText()), `${name}: virheteksti kentän vieressä`);
  expect(await form.locator('[data-testid=form-error]').isVisible() && calls(st, 'admin_create_booking').length === 0, `${name}: yhteenvetoilmoitus, ei kutsua`);
  await shot(page, `jalkeen-3-virheet-${vp}`);
  // tyypit/attribuutit
  const at = await form.evaluate((f) => { const g = (n) => f.querySelector(`[name=${n}]`); return { e: g('cemail').type + '/' + g('cemail').inputMode, p: g('cphone').type + '/' + g('cphone').inputMode, req: g('cname').required, eReq: g('cemail').required, pReq: g('cphone').required }; });
  expect(at.e === 'email/email' && at.p === 'tel/tel' && at.req && !at.eReq && !at.pReq, `${name}: kenttätyypit ${JSON.stringify(at)}`);
  // laskun viite: vain yritykselle
  const inv = form.locator('[data-testid=invref-field]');
  expect(await inv.isHidden(), `${name}: laskun viite piilossa yksityisasiakkaalla`);
  await form.locator('input[value=company]').check({ force: true });
  expect(await inv.isVisible() && await form.locator('select[name=method]').inputValue() === 'invoice' && !(await form.locator('input[name=paid]').isChecked()), `${name}: yritys → viite näkyy, maksutapa lasku, maksettu pois`);
  await form.locator('input[name=invref]').fill('PO-123');
  await form.locator('input[value=private]').check({ force: true });
  expect(await inv.isHidden() && await form.locator('input[name=invref]').inputValue() === '', `${name}: yksityiseksi → viite piiloon ja tyhjäksi`);
  await form.locator('input[value=company]').check({ force: true });
  expect(await form.locator('input[name=invref]').inputValue() === '', `${name}: viite ei palaa takaisin`);
  await shot(page, `jalkeen-4-yritys-${vp}`, { fullPage: true });
  await layoutChecks(page, `${name} yritys`);
  // yritysvaraus tallennetaan viitteellä
  await form.locator('input[name=invref]').fill('PO-123');
  await form.locator('input[name=cname]').fill('Liisa Laine'); await form.locator('input[name=cemail]').fill('liisa@nordic.example');
  await form.locator('input[name=company_name]').fill('Nordic Oy'); await form.locator('input[name=business_id]').fill('0112038-9');
  await form.locator('input[name=street]').fill('Sauna 1'); await form.locator('input[name=zip]').fill('04130'); await form.locator('input[name=city]').fill('Sipoo');
  await save.click(); await page.waitForSelector('[data-testid=booking-created]');
  let c = calls(st, 'admin_create_booking').at(-1)?.args;
  expect(c && c.p_invoice_reference === 'PO-123' && c.p_customer.kind === 'company' && c.p_customer.company_details.reference === null && c.p_persons === 2 && c.p_payment_method === 'invoice' && c.p_paid === false && c.p_price === null
    && JSON.stringify(c.p_addons) === JSON.stringify([{ id: 3, quantity: 2 }]), `${name}: yritysvarauksen parametrit ${JSON.stringify(c)}`);
  const done = page.locator('[data-testid=booking-created]');
  expect(/tilaus #4711/.test(await done.innerText()) && /46,00/.test((await done.innerText()).replace(/\u00a0/g, ' ')), `${name}: onnistumisviesti (tilausnumero + summa)`);
  expect(await page.locator('[data-testid=open-order]').getAttribute('href') === '#/talous?tab=orders&order=4711' && /Avaa tilaus ja maksut/.test(await page.locator('[data-testid=open-order]').innerText()), `${name}: Avaa tilaus ja maksut -linkki`);
  expect(await done.locator('a:has-text("Näytä päivänäkymä")').count() === 1 && await page.locator('.ok-box').count() === 1, `${name}: päivänäkymä-linkki ja .ok-box`);
  await layoutChecks(page, `${name} onnistui`);
  await shot(page, `jalkeen-5-onnistui-${vp}`);
  await page.click('[data-testid=another-booking]'); expect(await page.locator('[data-testid=booking-created]').count() === 0, `${name}: Luo toinen varaus tyhjentää viestin`);
  // toinen varaus: yksityinen, laskun viitettä ei lähetetä; maksutapa käteinen → maksettu oletuksena
  await pickSlot(page, 2);
  const f2 = page.locator('[data-testid=booking-form]');
  await f2.locator('select[name=method]').selectOption('cash'); expect(await f2.locator('input[name=paid]').isChecked(), `${name}: käteinen → maksettu oletuksena`);
  await f2.locator('select[name=method]').selectOption('pay_later'); expect(!(await f2.locator('input[name=paid]').isChecked()), `${name}: maksu myöhemmin → ei maksettu`);
  await f2.locator('input[name=cname]').fill('Matti Meikäläinen'); await f2.locator('input[name=cphone]').fill('0401234567');
  await f2.locator('details.nb-price summary').click(); await f2.locator('input[name=price]').fill('x');
  await f2.locator('[data-testid=save-booking]').click(); await page.waitForTimeout(120);
  expect(await f2.locator('input[name=price]').getAttribute('aria-invalid') === 'true' && calls(st, 'admin_create_booking').length === 1, `${name}: virheellinen hinta estää tallennuksen`);
  await f2.locator('input[name=price]').fill('40,5');
  expect(/Vuoro \(oma hinta\) 40,50/.test((await f2.locator('[data-testid=price-summary]').innerText()).replace(/\u00a0/g, ' ')), `${name}: oma hinta yhteenvedossa`);
  st.createFail = { code: 'capacity_exceeded', message: 'x' };
  await f2.locator('[data-testid=save-booking]').click(); await page.waitForSelector('[data-testid=form-error]:not([hidden])');
  expect(/Ei tarpeeksi vapaita paikkoja/.test(await f2.locator('[data-testid=form-error]').innerText()) && await f2.locator('[data-testid=save-booking]').isEnabled() && await page.locator('[data-testid=booking-form]').count() === 1, `${name}: palvelinvirhe näytetään lomakkeella`);
  st.createFail = null;
  await f2.locator('[data-testid=save-booking]').click(); await page.waitForSelector('[data-testid=booking-created]');
  c = calls(st, 'admin_create_booking').at(-1)?.args;
  expect(c.p_invoice_reference === null && c.p_customer.kind === 'private' && c.p_price === 40.5 && c.p_customer.email === '' && c.p_customer.phone === '0401234567', `${name}: yksityisvarauksen parametrit ${JSON.stringify(c)}`);
  await page.close();
}

// ---------- 2) EN ----------
for (const vp of [390, 1280]) {
  const name = `en-${vp}`, st = { calls: [] };
  const page = await newPage(browser, { vp, lang: 'en', st, onProblem: (m) => problems.push(`${name} ${m}`) });
  await open(page); await pickSlot(page);
  const form = page.locator('[data-testid=booking-form]');
  expect(await page.locator('#view h1').innerText() === 'New booking' && /Session: Yleinen vuoro/.test(await form.locator('h3').first().innerText()), `${name}: otsikot englanniksi`);
  const towel = form.locator('.addonrow[data-addon=pyyhe]');
  expect(await towel.locator('strong').innerText() === 'Towel' && await clickBtn(towel, 'Increase: Towel').count() === 1 && await clickBtn(towel, 'Decrease: Towel').count() === 1 && await towel.getByLabel('Towel, quantity').count() === 1, `${name}: stepperin aria-labelit EN`);
  expect(await form.locator('.addon-desc').count() === 0, `${name}: EN-kuvaus piilossa kun toistaa nimen`);
  expect(await form.locator('.nb-bar [data-testid=save-booking]').innerText() === 'Save booking', `${name}: Save booking`);
  await form.locator('[data-testid=save-booking]').click(); await page.waitForTimeout(100);
  expect(/Enter a name/.test(await form.locator('.fld-err:not([hidden])').first().innerText()), `${name}: virheteksti EN`);
  await layoutChecks(page, `${name} lomake`);
  await shot(page, `jalkeen-en-${vp}`, { fullPage: true });
  await page.close();
}

// ---------- 3) vuosikortti + olemassa oleva asiakas ----------
{
  const name = 'asiakashaku', st = { calls: [] };
  const page = await newPage(browser, { vp: 390, st, onProblem: (m) => problems.push(`${name} ${m}`) });
  await open(page); await pickSlot(page);
  const form = page.locator('[data-testid=booking-form]');
  await page.getByLabel('Hae asiakas').fill('Liisa'); await page.waitForSelector('.found .listrow'); await page.locator('.found .listrow').first().click();
  expect(await form.locator('[data-testid=customer-picked]').isVisible() && await form.locator('[data-testid=invref-field]').isVisible() && await form.locator('input[name=cname]').isHidden(), `${name}: valittu yritysasiakas → viite näkyy, syöttökentät piilossa`);
  await shot(page, 'jalkeen-6-valittu-asiakas-390');
  await form.locator('[data-testid=customer-picked] button').click();
  expect(await form.locator('input[name=cname]').isVisible(), `${name}: Uusi asiakas palauttaa kentät`);
  await page.close();
}

// ---------- 4) hallinnan navigaatio (alapalkki/sivupalkki) + tilauslinkit ----------
for (const vp of [360, 390, 430, 1280]) {
  const name = `nav-${vp}`, st = { calls: [] };
  const page = await newPage(browser, { vp, st, onProblem: (m) => problems.push(`${name} ${m}`) });
  await open(page, '#/');
  await page.waitForSelector('#nav a');
  const labels = await page.locator('#nav a .lbl').allInnerTexts();
  expect(labels.slice(0, 7).join('|') === 'Päivä|Varaukset|Talous|Kalenteri|Tarkista|Uusi varaus|Asiakkaat', `${name}: järjestys (${labels})`);
  if (vp < 900) {
    const info = await page.evaluate(() => { const n = document.querySelector('#nav'), links = [...n.querySelectorAll('a')], r = n.getBoundingClientRect(); const cut = links.find((a) => { const b = a.getBoundingClientRect(); return b.left < r.right - 1 && b.right > r.right + 1; }); return { sw: n.scrollWidth, cw: n.clientWidth, cut: !!cut, bg: getComputedStyle(n).backgroundImage.includes('gradient') }; });
    expect(info.sw > info.cw && info.cut && info.bg, `${name}: palkki vierittyy, reunassa pilkistävä kohta + reunagradientti (${JSON.stringify(info)})`);
    await shot(page, `jalkeen-nav-paiva-${vp}`, { clip: { x: 0, y: 844 - 70, width: vp, height: 70 } }).catch(() => {});
    await page.goto(`${ORIGIN}/admin/#/uusi?d=${DAY}`); await page.waitForSelector('.slotbtn'); await page.waitForTimeout(150);
    const act = await page.evaluate(() => { const n = document.querySelector('#nav'), a = n.querySelector('[aria-current]'), r = n.getBoundingClientRect(), b = a.getBoundingClientRect(); return { inView: b.left >= r.left - 0.5 && b.right <= r.right + 0.5, scroll: n.scrollLeft, label: a.textContent.trim() }; });
    expect(act.inView && act.scroll > 0, `${name}: aktiivinen välilehti (${act.label}) vieritetty näkyviin (${JSON.stringify(act)})`);
    await page.goto(`${ORIGIN}/admin/#/asetukset`).catch(() => {});
    await page.goto(`${ORIGIN}/admin/#/resurssit`); await page.waitForTimeout(300);
    const act2 = await page.evaluate(() => { const n = document.querySelector('#nav'), a = n.querySelector('[aria-current]'), r = n.getBoundingClientRect(), b = a.getBoundingClientRect(); return b.left >= r.left - 0.5 && b.right <= r.right + 0.5; });
    expect(act2, `${name}: viimeinen kohta (Resurssit) näkyviin`);
    await shot(page, `jalkeen-nav-resurssit-${vp}`);
  } else await shot(page, `jalkeen-nav-sivupalkki-${vp}`);
  await page.close();
}
{
  // Varaukset-lista → varauksen tiedot → "Tilaus N / Maksut" → Talous / Tilaukset, tilaus auki (syvälinkki)
  const st = { calls: [] }, name = 'tilauslinkki';
  const page = await newPage(browser, { vp: 390, st, onProblem: (m) => problems.push(`${name} ${m}`) });
  await open(page, '#/varaukset'); await page.waitForSelector('.listrow.rescard');
  await page.locator('.listrow.rescard').first().click(); await page.waitForSelector('dialog[open] [data-testid=order-link]');
  const lnk = page.locator('dialog[open] [data-testid=order-link]');
  expect(/^Tilaus 15005 \/ Maksut$/.test(await lnk.innerText()) && await lnk.getAttribute('href') === '#/talous?tab=orders&order=15005', `${name}: linkki varauksen tiedoissa`);
  expect((await lnk.boundingBox()).height >= 43.5, `${name}: linkki ≥ 44 px`);
  await shot(page, 'jalkeen-7-varaus-tilauslinkki-390');
  await lnk.click(); await page.waitForSelector('[data-testid=talous] [data-testid=order-actions]', { timeout: 8000 }).catch(() => problems.push(`${name}: tilaus ei auennut Talous-näkymässä (${page.url()})`));
  expect(await page.locator('[data-testid=orders-list] > [data-testid=order]').count() === 1 && /#15005/.test(await page.locator('[data-testid=orders-list] [data-testid=order]').first().innerText()), `${name}: Talous → Tilaukset näyttää tilauksen 15005 auki`);
  expect(await page.locator('[data-testid=orders-search]').inputValue() === '15005', `${name}: haku esitäytetty`);
  await shot(page, 'jalkeen-8-talous-tilaus-auki-390');
  await page.close();
}
await browser.close(); server.close();
console.log(`e2e-uusi-varaus: ${checks} tarkistusta, ${problems.length} ongelmaa`);
for (const p of problems) console.log(' -', p);
process.exit(problems.length ? 1 : 0);
