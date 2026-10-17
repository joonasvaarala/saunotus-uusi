// Etusivun hero selaimessa: screenshotit, vaakavieritys, valittu kuva, tekstin kontrasti (pahin taustapikseli tekstirivien alla) FI + EN.
//   1) npm run build:local && npm run dev   (http://localhost:4173)
//   2) PW_DIR=/polku/node_modules OUT=/polku/screenshots node scripts/hero-shots.mjs     (BASE oletus http://localhost:4173, CHROME oletus /usr/bin/google-chrome)
// Epäonnistuu (exit 1), jos kontrasti < 4,5:1 (h1, kappale, napit), sivu vierittyy vaakasuunnassa tai väärä kuva (mobiili/desktop) latautuu.
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const pw = await import(pathToFileURL(require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) })));
const sharp = (await import('sharp')).default;
const { chromium } = pw.chromium ? pw : pw.default;
const OUT = process.env.OUT || 'screenshots-hero'; mkdirSync(OUT, { recursive: true });
const BASE = (process.env.BASE || 'http://localhost:4173').replace(/\/$/, '');
const PAGES = { fi: '/', en: '/en/' }, WIDTHS = (process.env.WIDTHS || '360,390,430,768,1280,1920').split(',').map(Number);
const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
const L = (r, g, b) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
const cr = (a, b) => (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const res = [], fails = [];
for (const lang of ['fi', 'en']) for (const w of WIDTHS) {
  const page = await (await browser.newContext({ viewport: { width: w, height: 900 }, deviceScaleFactor: 1 })).newPage();
  const errs = []; page.on('console', (m) => m.type() === 'error' && errs.push(m.text())); page.on('pageerror', (e) => errs.push(e.message));
  await page.goto(BASE + PAGES[lang], { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForFunction(() => document.querySelector('.hero.home img').complete);
  const info = await page.evaluate(() => {
    const img = document.querySelector('.hero.home img'), h = document.querySelector('.hero.home').getBoundingClientRect(), r = img.getBoundingClientRect();
    return { cur: img.currentSrc.split('/').pop(), nat: img.naturalWidth + 'x' + img.naturalHeight, sw: document.documentElement.scrollWidth, iw: innerWidth, hero: [h.y + scrollY, h.width, h.height].map(Math.round), img: [r.width, r.height].map(Math.round), op: getComputedStyle(img).objectPosition };
  });
  const mobile = w <= 719;
  if (info.sw > info.iw) fails.push(`${lang} ${w}: vaakavieritys (${info.sw} > ${info.iw})`);
  if (mobile !== /mobiili/.test(info.cur)) fails.push(`${lang} ${w}: väärä kuva ${info.cur}`);
  if (errs.length) fails.push(`${lang} ${w}: konsolivirheet ${errs.join('; ')}`);
  await page.screenshot({ path: `${OUT}/${lang}-etusivu-${w}.png`, clip: { x: 0, y: 0, width: w, height: Math.min(900, info.hero[0] + info.hero[2] + 40) } });
  const lines = await page.evaluate(() => ['h1', '.in > p', '.btn.gold', '.btn.ghost'].map((s) => {
    const el = document.querySelector('.hero.home ' + s), rects = [], wk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let n; (n = wk.nextNode());) { if (!n.textContent.trim()) continue; const r = document.createRange(); r.selectNodeContents(n); for (const q of r.getClientRects()) rects.push([q.x, q.y + scrollY, q.width, q.height]); }
    return { name: s, color: getComputedStyle(el).color, rects };
  }));
  await page.addStyleTag({ content: '.hero.home h1,.hero.home .in>p,.hero.home .btn{color:transparent!important;text-shadow:none!important;transition:none!important}' });
  const { data, info: im } = await sharp(await page.screenshot({ fullPage: true })).raw().toBuffer({ resolveWithObject: true });
  for (const ln of lines) {
    const m = /rgba?\((\d+), (\d+), (\d+)/.exec(ln.color), tl = L(+m[1], +m[2], +m[3]), lums = [];
    for (const [x, y, ww, hh] of ln.rects) for (let yy = Math.max(0, Math.floor(y)); yy < Math.min(im.height, Math.ceil(y + hh)); yy += 2) for (let xx = Math.max(0, Math.floor(x)); xx < Math.min(im.width, Math.ceil(x + ww)); xx += 2) { const i = (yy * im.width + xx) * im.channels; lums.push(L(data[i], data[i + 1], data[i + 2])); }
    const worst = +cr(tl, Math.max(...lums)).toFixed(2), mean = +cr(tl, lums.reduce((a, b) => a + b, 0) / lums.length).toFixed(2);
    res.push({ lang, w, el: ln.name, mean, worst });
    if (worst < 4.5) fails.push(`${lang} ${w} ${ln.name}: kontrasti ${worst} < 4,5`);
  }
  res.push({ lang, w, ...info });
  await page.context().close();
}
writeFileSync(`${OUT}/kontrasti.json`, JSON.stringify(res, null, 1));
for (const r of res) console.log(JSON.stringify(r));
await browser.close();
if (fails.length) { console.log('VIRHEET:\n' + fails.join('\n')); process.exit(1); }
console.log('hero-selaintesti OK');
