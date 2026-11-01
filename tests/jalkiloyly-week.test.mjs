// Vapaat jälkilöylyt viikko-ohjelmassa: mockattu public_availability + public_quiet_offers.
// Kompakti mobiilinäkymä ja koko viikko, FI ja EN, ei päällekkäisyyttä 360/390/430 px:ssä.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, existsSync, mkdirSync, cpSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromium } from 'playwright-core';

const root = resolve(new URL('..', import.meta.url).pathname);
const work = mkdtempSync(join(tmpdir(), 'jalkiloyly-'));
const dist = join(work, 'dist');
const port = 4192;
const shots = process.env.JALKIL_SHOTS || '';
const TODAY = '2026-10-28';
const NOW = Date.parse('2026-10-28T00:30:00Z');

function chromePath() {
  if (process.env.CHROME_PATH && existsSync(process.env.CHROME_PATH)) return process.env.CHROME_PATH;
  for (const p of ['/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser']) {
    if (existsSync(p)) return p;
  }
  throw new Error('Chrome puuttuu. Aseta CHROME_PATH tai asenna google-chrome.');
}
const hit = (a, b) => !(a.right <= b.left + 0.5 || a.left >= b.right - 0.5 || a.bottom <= b.top + 0.5 || a.top >= b.bottom - 0.5);
const slot = (date, status, rule, price) => ({ rule_id: rule, status, session_date: date, starts_at: `${date}T17:00:00Z`, ends_at: `${date}T19:00:00Z`, base_price: price, price_mode: 'fixed_plus_extra' });
const slots = [
  slot(TODAY, 'full', 22, 180),
  slot(TODAY, 'available', 22, 180),
  { rule_id: 90, status: 'available', session_date: TODAY, starts_at: '2026-10-28T00:00:00Z', ends_at: '2026-10-28T01:00:00Z', base_price: 180 },
  slot('2026-10-29', 'available', 22, 180),
  slot('2026-10-30', 'available', 23, 250),
  slot('2026-10-31', 'unavailable', 24, 300),
  { product_id: 25, rule_id: 9, status: 'available', session_date: TODAY, starts_at: '2026-10-28T17:00:00Z', ends_at: '2026-10-28T19:00:00Z', base_price: 100 },
];
const offers = [{ product_id: 26, rule_id: 22, session_date: TODAY, starts_at: '2026-10-28T17:00:00Z', ends_at: '2026-10-28T19:00:00Z', percent: 20, base_price: 180, discounted_price: 144 }];

let server, browser;
before(async () => {
  const r = spawnSync('node', ['scripts/build.mjs'], {
    cwd: root, encoding: 'utf8',
    env: {
      PATH: process.env.PATH, HOME: process.env.HOME, DIST: dist,
      SITE_ENV: 'test', SITE_URL: `http://127.0.0.1:${port}`,
      ARTICLES_CACHE_DIR: join(work, 'cache'), ARTICLES_STATE_FILE: join(work, 'state.json'), ARTICLES_IMAGES: '0',
    },
  });
  assert.equal(r.status, 0, `build kaatui:\n${r.stdout}\n${r.stderr}`);
  const booking = join(dist, 'booking');
  mkdirSync(booking, { recursive: true });
  cpSync(join(root, 'booking/shop/src/quiet-week.js'), join(booking, 'quiet-week.js'));
  cpSync(join(root, 'booking/shop/src/catalog-names.js'), join(booking, 'catalog-names.js'));
  cpSync(join(root, 'booking/shop/src/text-spaces.js'), join(booking, 'text-spaces.js'));
  cpSync(join(root, 'booking/shop/src/product-image.js'), join(booking, 'product-image.js'));
  cpSync(join(root, 'booking/shop/src/quiet-offers-logic.js'), join(booking, 'quiet-offers-logic.js'));
  cpSync(join(root, 'booking/shop/src/week-live.js'), join(booking, 'week-live.js'));
  cpSync(join(root, 'booking/shop/src/event-date.js'), join(booking, 'event-date.js'));
  writeFileSync(join(booking, 'sb.js'), 'export async function rpc(){ throw new Error("ei verkkoa"); }\n');
  server = spawn('node', ['scripts/serve.mjs', dist, String(port)], { cwd: root, stdio: 'ignore' });
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('palvelin ei käynnistynyt')), 8000);
    const ping = () => fetch(`http://127.0.0.1:${port}/`).then(() => { clearTimeout(t); res(); }).catch(() => setTimeout(ping, 80));
    ping();
  });
  browser = await chromium.launch({ executablePath: chromePath(), args: ['--no-sandbox', '--disable-dev-shm-usage'] });
});
after(async () => { await browser?.close(); server?.kill(); rmSync(work, { recursive: true, force: true }); });

async function open(width, path) {
  const page = await browser.newPage({ viewport: { width, height: 1000 }, deviceScaleFactor: 1 });
  await page.goto(`http://127.0.0.1:${port}${path}`, { waitUntil: 'domcontentloaded' });
  await page.evaluate(() => document.fonts.ready);
  return page;
}
async function decorate(page, lang) {
  return page.evaluate(async ({ offers, slots, today, now, lang }) => {
    const { decorateWeek } = await import('/booking/quiet-week.js');
    let n = 0;
    for (const list of document.querySelectorAll('ol.week[data-quiet-week]')) n += decorateWeek(list, offers, { lang, shopHref: '/varaa/', today, slots, now });
    return n;
  }, { offers, slots, today: TODAY, now: NOW, lang });
}
async function focusWeek(page) {
  await page.evaluate(() => {
    document.documentElement.style.scrollBehavior = 'auto';
    const head = document.querySelector('.week-head') || document.querySelector('ol.week');
    window.scrollTo({ top: head.getBoundingClientRect().top + window.scrollY - 8, behavior: 'instant' });
  });
}
async function boxes(page) {
  return page.evaluate(() => {
    const box = (el) => { const r = el.getBoundingClientRect(); return { top: r.top, right: r.right, bottom: r.bottom, left: r.left, width: r.width, height: r.height }; };
    const day = (wd) => {
      const row = document.querySelector(`ol.week > li[data-wd="${wd}"]`);
      if (!row || getComputedStyle(row).display === 'none') return null;
      const h3 = row.querySelector('h3');
      const range = document.createRange(); range.selectNodeContents(h3.firstChild);
      const badge = h3.querySelector('.today');
      const shown = badge && getComputedStyle(badge).display !== 'none';
      return {
        name: box(range),
        badge: shown ? box(badge) : null,
        sessions: [...row.querySelectorAll(':scope .sess')].map((s) => ({
          t: s.querySelector('.t')?.textContent || '',
          n: s.querySelector('.n')?.textContent || '',
          price: s.querySelector('.qp')?.textContent || '',
          href: s.querySelector('a.bk')?.getAttribute('href') || '',
          testid: s.dataset.testid || '',
          parts: [...s.querySelectorAll('.t, .n, .qp, .bk')].map(box),
        })),
      };
    };
    return {
      wed: day(3), thu: day(4), fri: day(5),
      soonVisible: [...document.querySelectorAll('ol.week.soon > li')].filter((li) => getComputedStyle(li).display !== 'none').length,
      text: document.querySelector('ol.week')?.innerText || '',
      scrollW: document.documentElement.scrollWidth,
      clientW: document.documentElement.clientWidth,
    };
  });
}

const pages = [
  { path: '/', lang: 'fi', name: 'Savusaunan jälkilöylyt', book: 'Varaa' },
  { path: '/en/', lang: 'en', name: 'After Session Sauna', book: 'Book' },
  { path: '/saunavuorot/', lang: 'fi', name: 'Savusaunan jälkilöylyt', book: 'Varaa' },
  { path: '/en/sauna/', lang: 'en', name: 'After Session Sauna', book: 'Book' },
];

test('jälkilöyly: vapaa alennettu vuoro tänään, täysi hinta huomenna, varattu ja mennyt piilossa; ei päällekkäisyyttä', async () => {
  for (const width of [360, 390, 430]) {
    for (const pg of pages) {
      const page = await open(width, pg.path);
      if (shots && width === 390 && pg.path === '/') {
        await focusWeek(page);
        mkdirSync(shots, { recursive: true });
        await page.screenshot({ path: join(shots, 'before_390.png'), fullPage: false });
      }
      const added = await decorate(page, pg.lang);
      assert.ok(added >= 3, `${pg.path} lisäsi ${added}`);
      assert.equal(await page.locator('.quiet-week-note').count(), 0, `${pg.path} ei huomiolaatikkoa`);
      assert.doesNotMatch(await page.locator('body').innerText(), /vielä vapaat yksityisvuorot|private sessions still available in the next few days/);
      await page.evaluate(() => {
        const items = [...document.querySelectorAll('ol.week.soon > li')];
        items.forEach((li, n) => {
          li.classList.toggle('is-today', li.dataset.wd === '3');
          li.classList.toggle('is-next', li.dataset.wd === '4');
        });
        document.querySelectorAll('ol.week.soon').forEach((w) => w.classList.add('is-filtered'));
        const more = document.querySelector('.week-more');
        if (more) more.open = false;
      });
      await focusWeek(page);
      if (shots && width === 390 && (pg.path === '/' || pg.path === '/saunavuorot/')) {
        mkdirSync(shots, { recursive: true });
        await page.screenshot({ path: join(shots, pg.path === '/' ? 'etusivu-viikko-mobiili.png' : 'saunavuorot-viikko-mobiili.png') });
      }
      const compact = await boxes(page);
      const home = pg.path === '/' || pg.path === '/en/';
      if (home) assert.equal(compact.soonVisible, 2, `${width} ${pg.path} kompakti`);
      assert.ok(!compact.text.includes('/varaa/24/'), 'varattu lauantai ei näy');
      const today = compact.wed.sessions.find((s) => s.testid === 'site-quiet-session');
      assert.ok(today, `${width} ${pg.path} alennettu rivi`);
      assert.match(today.n, new RegExp(pg.name));
      assert.match(today.t, /19/);
      assert.match(today.price.replace(/\s/g, ''), /180/);
      assert.match(today.price.replace(/\s/g, ''), /144/);
      assert.match(today.price, /20/);
      assert.equal(today.href, '/varaa/#/varaa/22/2026-10-28/26');
      assert.match(compact.text, new RegExp(pg.book, 'i'));
      const plain = compact.thu?.sessions.find((s) => s.testid === 'site-jalkiloyly');
      assert.ok(plain, `${width} ${pg.path} huomisen täysi hinta`);
      assert.match(plain.price.replace(/\s/g, ''), /180/);
      assert.doesNotMatch(plain.price, /144/);
      assert.equal(plain.href, '/varaa/#/varaa/22/2026-10-29/26');
      const check = (m, label) => {
        for (const day of [m.wed, m.thu, m.fri].filter(Boolean)) {
          if (day.badge && home) assert.ok(day.badge.top >= day.name.bottom - 1, `${label} merkki päivän nimen alla`);
          if (day.badge) {
            for (const s of day.sessions) for (const p of s.parts) {
              assert.ok(!hit(day.badge, p), `${label} merkki peittää ${s.t} ${s.n}`);
              assert.ok(!hit(day.name, p), `${label} päivä peittää ${s.t}`);
            }
          }
          for (let i = 0; i < day.sessions.length; i++) for (let j = i + 1; j < day.sessions.length; j++) {
            for (const a of day.sessions[i].parts) for (const b of day.sessions[j].parts) assert.ok(!hit(a, b), `${label} vuorot päällekkäin ${day.sessions[i].t}/${day.sessions[j].t}`);
          }
        }
        assert.ok(m.scrollW <= m.clientW + 1, `${label} sivuttainen ylivuoto`);
      };
      check(compact, `${width} ${pg.path} kompakti`);
      if (shots && pg.path === '/' && width === 390) {
        const clip = await page.evaluate(() => {
          const a = document.querySelector('.week-head').getBoundingClientRect();
          const y = Math.max(0, Math.floor(a.top));
          return { x: 0, y, width: window.innerWidth, height: Math.max(1, Math.min(window.innerHeight - y - 1, 640)) };
        });
        await page.screenshot({ path: join(shots, 'after_390_compact.png'), clip });
      }
      if (home) {
        await page.evaluate(() => { const more = document.querySelector('.week-more'); if (more) more.open = true; });
        await focusWeek(page);
        const full = await boxes(page);
        assert.ok(full.soonVisible >= 7, `${width} ${pg.path} koko viikko ${full.soonVisible}`);
        assert.ok(full.fri, `${width} ${pg.path} perjantai näkyy`);
        assert.match(full.fri.sessions.map((s) => s.price).join(' ').replace(/\s/g, ''), /250/);
        check(full, `${width} ${pg.path} koko viikko`);
        if (shots && pg.path === '/') {
          const clip = await page.evaluate(() => {
            const a = (document.querySelector('.week-head') || document.querySelector('ol.week')).getBoundingClientRect();
            const y = Math.max(0, Math.floor(Math.min(a.top, 4)));
            return { x: 0, y, width: window.innerWidth, height: Math.max(1, Math.min(window.innerHeight - y - 1, 920)) };
          });
          await page.screenshot({ path: join(shots, `after_${width}_${pg.lang}.png`), clip });
        }
      } else if (shots && width === 390 && pg.path === '/saunavuorot/') {
        await page.screenshot({ path: join(shots, 'after_390_saunavuorot.png'), fullPage: false });
      }
      await page.close();
    }
  }
});
