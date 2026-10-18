// Sisältöosion selaintarkistus + screenshotit (Playwright/Chrome): ei vaakavieritystä 360/390/430/1280, kosketuskohteet ≥44 px,
// tekstin kontrasti ≥4,5:1 (suuri teksti ≥3:1), otsikkojärjestys, yksi h1, kuvat latautuvat (srcset/avif/webp), width/height/alt.
//   1) rakenna esim.:  ARTICLES_FIXTURE=1 SITE_ENV=test SITE_URL=http://localhost:4180 DIST=/tmp/d node scripts/build.mjs && node scripts/serve.mjs /tmp/d 4180
//   2) PW_DIR=/polku/node_modules OUT=/workspace/screenshots-saunatietoa BASE=http://localhost:4180 node scripts/articles-shots.mjs
// Env: PAGES = pilkuilla erotetut polut (oletus: listaus, artikkeli, EN-listaus, EN-artikkeli, tagisivu), WIDTHS, TAG (tiedostonimen etuliite), CHROME.
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const pw = await import(pathToFileURL(require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) })));
const { chromium } = pw.chromium ? pw : pw.default;
const OUT = process.env.OUT || 'screenshots-saunatietoa'; mkdirSync(OUT, { recursive: true });
const BASE = (process.env.BASE || 'http://localhost:4180').replace(/\/$/, '');
const PATHS = (process.env.PAGES || '/saunatietoa/,/saunatietoa/miten-saunotaan-oikein/,/saunatietoa/savusauna-lampiaminen/,/saunatietoa/tagi/sauna/,/en/sauna-knowledge/,/en/sauna-knowledge/how-to-sauna/').split(',');
const WIDTHS = (process.env.WIDTHS || '360,390,430,768,1024,1280').split(',').map(Number);
const PREFIX = process.env.TAG || '';
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const fails = [], rows = [];
for (const path of PATHS) for (const w of WIDTHS) {
  const ctx = await browser.newContext({ viewport: { width: w, height: 900 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const errs = []; page.on('console', (m) => m.type() === 'error' && errs.push(m.text())); page.on('pageerror', (e) => errs.push(e.message));
  // sama polku ilman BASE-etuliitettä; ohjaussivuja (meta refresh) ei avata tässä
  await page.goto(BASE + path, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  // vieritä läpi, jotta lazy-kuvat latautuvat
  await page.evaluate(async () => { for (let y = 0; y < document.body.scrollHeight; y += 300) { scrollTo(0, y); await new Promise((r) => setTimeout(r, 150)); } scrollTo(0, 0); });
  await page.waitForFunction(() => [...document.querySelectorAll('main img')].every((i) => i.complete && i.naturalWidth > 0), null, { timeout: 8000 }).catch(() => {});
  const r = await page.evaluate(() => {
    const out = { sw: document.documentElement.scrollWidth, iw: innerWidth, small: [], contrast: [], headings: [], imgs: [], h1: document.querySelectorAll('h1').length };
    const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
    const lum = ([r, g, b]) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
    const rgba = (s) => { const m = /rgba?\(([^)]+)\)/.exec(s); if (!m) return null; const p = m[1].split(/[ ,\/]+/).filter(Boolean).map(Number); return [p[0], p[1], p[2], p[3] ?? 1]; };
    const bgOf = (el) => { // tehokas taustaväri; null jos taustakuva/gradientti
      let acc = null; for (let n = el; n; n = n.parentElement) { const cs = getComputedStyle(n); if (cs.backgroundImage !== 'none') return null; const c = rgba(cs.backgroundColor); if (c && c[3] > 0) { if (c[3] >= 1) return acc ? acc : c.slice(0, 3); acc ??= c.slice(0, 3); } } return acc || [255, 255, 255];
    };
    const sel = '.art-band, .art-wrap, .art-list, .art-related, .article-cta, .crumbs, .art-foot, .art-empty';
    const roots = [...document.querySelectorAll(sel)];
    for (const root of roots) for (const el of root.querySelectorAll('*')) {
      const own = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
      if (!own || el.closest('.sr') || getComputedStyle(el).visibility === 'hidden') continue;
      const cs = getComputedStyle(el); const bg = bgOf(el); if (!bg) continue;
      const fg = rgba(cs.color); if (!fg) continue;
      const L1 = lum(fg.slice(0, 3)), L2 = lum(bg), ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
      const size = parseFloat(cs.fontSize), bold = parseInt(cs.fontWeight) >= 700, big = size >= 24 || (size >= 18.66 && bold);
      if (ratio < (big ? 3 : 4.5)) out.contrast.push(`${el.tagName.toLowerCase()}.${el.className} "${el.textContent.trim().slice(0, 30)}" ${ratio.toFixed(2)}`);
    }
    // kosketuskohteet: painikkeet, chipit, sivutus, murupolku, CTA, kortit (kortin peittolinkki)
    for (const el of document.querySelectorAll('.tagbar a, .pager a, .crumbs a, .article-cta .btn, .art-empty .btn, .art-band .kicker a, .art-card h2 a, .nav-mob summary, .lang a')) {
      let r = el.getBoundingClientRect(); if (el.matches('.art-card h2 a')) r = el.closest('.card').getBoundingClientRect();
      if (r.width && (r.height < 43.5 || r.width < 43.5)) out.small.push(`${el.className || el.tagName} "${el.textContent.trim().slice(0, 24)}" ${Math.round(r.width)}x${Math.round(r.height)}`);
    }
    let prev = 0;
    for (const h of document.querySelectorAll('main h1,main h2,main h3,main h4')) { const l = +h.tagName[1]; if (prev && l > prev + 1) out.headings.push(`hyppy H${prev}→H${l}: ${h.textContent.trim().slice(0, 30)}`); prev = l; }
    for (const im of document.querySelectorAll('main img')) out.imgs.push({ ok: im.complete && im.naturalWidth > 0, cur: (im.currentSrc || im.src).split('/').pop(), w: im.getAttribute('width'), h: im.getAttribute('height'), alt: im.hasAttribute('alt'), lazy: im.loading });
    return out;
  });
  const name = `${PREFIX}${path.replace(/^\/|\/$/g, '').replace(/\//g, '_') || 'etusivu'}-${w}.png`;
  await page.screenshot({ path: `${OUT}/${name}`, fullPage: true });
  const bad = [];
  if (r.sw > r.iw) bad.push(`vaakavieritys ${r.sw}>${r.iw}`);
  if (r.h1 !== 1) bad.push(`h1 x${r.h1}`);
  if (r.small.length) bad.push('kosketuskohde <44px: ' + [...new Set(r.small)].join('; '));
  if (r.contrast.length) bad.push('kontrasti: ' + [...new Set(r.contrast)].join('; '));
  if (r.headings.length) bad.push(...r.headings);
  for (const im of r.imgs) { if (!im.ok) bad.push('kuva ei latautunut ' + im.cur); if (!im.w || !im.h || !im.alt) bad.push('img ilman width/height/alt ' + im.cur); }
  if (errs.length) bad.push('konsolivirheet: ' + errs.join(' | '));
  rows.push({ path, w, ok: !bad.length, imgs: r.imgs.map((i) => i.cur), bad });
  if (bad.length) fails.push(`${path} @${w}: ${bad.join(' / ')}`);
  await ctx.close();
}
await browser.close();
writeFileSync(`${OUT}/${PREFIX}raportti.json`, JSON.stringify(rows, null, 1));
console.log(`articles-shots: ${rows.length} sivua/leveyttä, virheitä ${fails.length}; kuvat → ${OUT}`);
if (fails.length) { console.log(fails.join('\n')); process.exit(1); }
