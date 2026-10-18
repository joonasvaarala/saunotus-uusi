// Etusivun artikkeliosion (Saunatietoa) selaintarkistus + screenshotit (Playwright/Chrome).
// Tarkistaa: ei vaakavieritystä, kortteja odotettu määrä (0 = osio kokonaan piilossa, ei tyhjää laatikkoa), kosketuskohteet ≥44 px, kontrasti ≥4,5:1,
// otsikkojärjestys, kuvat latautuvat + width/height/alt/loading=lazy + object-fit cover, summary rajattu ≤3 riviin, koko kortti klikattava (yksi linkki).
//   1) rakenna:  ARTICLES_FIXTURE=1 SITE_ENV=test SITE_URL=http://localhost:4180 DIST=/tmp/d node scripts/build.mjs && node scripts/serve.mjs /tmp/d 4180
//   2) PW_DIR=/polku/node_modules OUT=/workspace/screenshots-etusivu-artikkelit BASE=http://localhost:4180 \
//      PAGES=/esikatselu/etusivu-artikkelit/:3,/en/preview/home-articles/:3 TAG=fi-en- node scripts/home-articles-shots.mjs
// Env: PAGES = polku:odotettu_korttimäärä, pilkuilla (oletus: esikatselusivut + etusivut), WIDTHS, TAG (tiedostonimen etuliite), CHROME.
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const pw = await import(pathToFileURL(require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) })));
const { chromium } = pw.chromium ? pw : pw.default;
const OUT = process.env.OUT || 'screenshots-etusivu-artikkelit'; mkdirSync(OUT, { recursive: true });
const BASE = (process.env.BASE || 'http://localhost:4180').replace(/\/$/, '');
const SPECS = (process.env.PAGES || '/esikatselu/etusivu-artikkelit/:3,/en/preview/home-articles/:3').split(',').map((s) => { const i = s.lastIndexOf(':'); return { path: s.slice(0, i), expect: +s.slice(i + 1) }; });
const WIDTHS = (process.env.WIDTHS || '360,390,430,768,1280').split(',').map(Number);
const PREFIX = process.env.TAG || '';
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const fails = [], rows = [];
for (const { path, expect } of SPECS) for (const w of WIDTHS) {
  const ctx = await browser.newContext({ viewport: { width: w, height: 900 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const errs = []; page.on('console', (m) => m.type() === 'error' && errs.push(m.text())); page.on('pageerror', (e) => errs.push(e.message));
  await page.goto(BASE + path, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  await page.evaluate(async () => { for (let y = 0; y < document.body.scrollHeight; y += 300) { scrollTo(0, y); await new Promise((r) => setTimeout(r, 120)); } });
  await page.waitForFunction(() => [...document.querySelectorAll('.home-art img')].every((i) => i.complete && i.naturalWidth > 0), null, { timeout: 8000 }).catch(() => {});
  const r = await page.evaluate(() => {
    const out = { sw: document.documentElement.scrollWidth, iw: innerWidth, cards: document.querySelectorAll('.home-art .hart').length, section: !!document.querySelector('.home-art'), small: [], contrast: [], headings: [], imgs: [], clamp: [], links: [], h1: document.querySelectorAll('h1').length, fit: [], cols: 0, emptyBox: !!document.querySelector('.home-art:empty, .home-art .art-empty') };
    const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
    const lum = ([r, g, b]) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
    const rgba = (s) => { const m = /rgba?\(([^)]+)\)/.exec(s); if (!m) return null; const p = m[1].split(/[ ,\/]+/).filter(Boolean).map(Number); return [p[0], p[1], p[2], p[3] ?? 1]; };
    const bgOf = (el) => { let acc = null; for (let n = el; n; n = n.parentElement) { const cs = getComputedStyle(n); if (cs.backgroundImage !== 'none') return null; const c = rgba(cs.backgroundColor); if (c && c[3] > 0) { if (c[3] >= 1) return acc ? acc : c.slice(0, 3); acc ??= c.slice(0, 3); } } return acc || [255, 255, 255]; };
    const root = document.querySelector('.home-art');
    if (!root) return out;
    for (const el of root.querySelectorAll('*')) {
      const own = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
      if (!own || el.closest('.sr')) continue;
      const cs = getComputedStyle(el); const bg = bgOf(el); const fg = rgba(cs.color); if (!bg || !fg) continue;
      const L1 = lum(fg.slice(0, 3)), L2 = lum(bg), ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
      const size = parseFloat(cs.fontSize), bold = parseInt(cs.fontWeight) >= 700, big = size >= 24 || (size >= 18.66 && bold);
      if (ratio < (big ? 3 : 4.5)) out.contrast.push(`${el.tagName.toLowerCase()}.${el.className} "${el.textContent.trim().slice(0, 30)}" ${ratio.toFixed(2)}`);
    }
    for (const el of root.querySelectorAll('.more-all, .hart h3 a')) {
      let r = el.getBoundingClientRect(); if (el.matches('.hart h3 a')) r = el.closest('.hart').getBoundingClientRect();
      if (r.height < 43.5 || r.width < 43.5) out.small.push(`${el.className || el.tagName} ${Math.round(r.width)}x${Math.round(r.height)}`);
    }
    for (const c of root.querySelectorAll('.hart')) {
      const a = c.querySelectorAll('a'); out.links.push(a.length);
      const h = a[0]?.getBoundingClientRect(), cr = c.getBoundingClientRect();
      const ov = getComputedStyle(a[0], '::after'); if (ov.position !== 'absolute' || ov.content === 'none') out.clamp.push('kortin peittolinkki puuttuu');
      const p = c.querySelector('.bd p'); if (p) { const lh = parseFloat(getComputedStyle(p).lineHeight); const lines = Math.round(p.getBoundingClientRect().height / lh); if (lines > 3) out.clamp.push(`summary ${lines} riviä`); }
    }
    out.cols = new Set([...root.querySelectorAll('.hart')].map((c) => Math.round(c.getBoundingClientRect().left))).size;
    let prev = 0;
    for (const h of document.querySelectorAll('main h1,main h2,main h3')) { const l = +h.tagName[1]; if (prev && l > prev + 1) out.headings.push(`hyppy H${prev}→H${l}: ${h.textContent.trim().slice(0, 30)}`); prev = l; }
    for (const im of root.querySelectorAll('img')) out.imgs.push({ ok: im.complete && im.naturalWidth > 0, cur: (im.currentSrc || im.src).split('/').pop(), nw: im.naturalWidth, w: im.getAttribute('width'), h: im.getAttribute('height'), alt: im.hasAttribute('alt'), lazy: im.loading, fit: getComputedStyle(im).objectFit, box: Math.round(im.getBoundingClientRect().width) + 'x' + Math.round(im.getBoundingClientRect().height) });
    return out;
  });
  const slug = path.replace(/^\/|\/$/g, '').replace(/\//g, '_') || 'etusivu';
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: `${OUT}/${PREFIX}${slug}-${w}.png`, fullPage: true });
  if (r.section) { await page.locator('.home-art').screenshot({ path: `${OUT}/${PREFIX}${slug}-${w}-osio.png` }); }
  const bad = [];
  if (r.sw > r.iw) bad.push(`vaakavieritys ${r.sw}>${r.iw}`);
  if (r.h1 !== 1) bad.push(`h1 x${r.h1}`);
  if (r.cards !== expect) bad.push(`kortteja ${r.cards}, odotettu ${expect}`);
  if (expect === 0 && (r.section || r.emptyBox)) bad.push('tyhjä osio näkyy');
  if (r.small.length) bad.push('kosketuskohde <44px: ' + [...new Set(r.small)].join('; '));
  if (r.contrast.length) bad.push('kontrasti: ' + [...new Set(r.contrast)].join('; '));
  if (r.clamp.length) bad.push(...new Set(r.clamp));
  if (r.links.some((n) => n !== 1)) bad.push('kortissa ei täsmälleen yhtä linkkiä: ' + r.links);
  if (expect === 3) { const wantCols = w >= 760 ? 3 : 1; if (r.cols !== wantCols) bad.push(`sarakkeita ${r.cols}, odotettu ${wantCols}`); }
  bad.push(...r.headings);
  for (const im of r.imgs) { if (!im.ok) bad.push('kuva ei latautunut ' + im.cur); if (!im.w || !im.h || !im.alt || im.lazy !== 'lazy' || im.fit !== 'cover') bad.push('img: width/height/alt/lazy/cover puuttuu ' + im.cur); }
  if (errs.length) bad.push('konsolivirheet: ' + errs.join(' | '));
  rows.push({ path, w, ok: !bad.length, cards: r.cards, cols: r.cols, imgs: r.imgs, bad });
  if (bad.length) fails.push(`${path} @${w}: ${bad.join(' / ')}`);
  await ctx.close();
}
await browser.close();
writeFileSync(`${OUT}/${PREFIX}raportti.json`, JSON.stringify(rows, null, 1));
console.log(`home-articles-shots: ${rows.length} sivua/leveyttä, virheitä ${fails.length}; kuvat → ${OUT}`);
if (fails.length) { console.log(fails.join('\n')); process.exit(1); }
