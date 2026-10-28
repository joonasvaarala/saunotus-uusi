// Tiivis viikko-ohjelma (mobiili ≤719px): Tänään-merkki ei saa peittää kellonaikaa eikä vuoron nimeä.
// Desktopin 7 saraketta säilyy. Näytä koko viikko on nappi, ja sen alla ei ole isoa tyhjää väliä.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, existsSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromium } from 'playwright-core';

const root = resolve(new URL('..', import.meta.url).pathname);
const work = mkdtempSync(join(tmpdir(), 'week-compact-'));
const dist = join(work, 'dist');
const port = 4188;
const shots = process.env.WEEK_SHOTS || '';

function chromePath() {
  if (process.env.CHROME_PATH && existsSync(process.env.CHROME_PATH)) return process.env.CHROME_PATH;
  for (const p of ['/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser']) {
    if (existsSync(p)) return p;
  }
  throw new Error('Chrome puuttuu. Aseta CHROME_PATH tai asenna google-chrome.');
}

const hit = (a, b) => !(a.right <= b.left + 0.5 || a.left >= b.right - 0.5 || a.bottom <= b.top + 0.5 || a.top >= b.bottom - 0.5);

let server, browser;
before(async () => {
  const r = spawnSync('node', ['scripts/build.mjs'], {
    cwd: root, encoding: 'utf8',
    env: {
      PATH: process.env.PATH, HOME: process.env.HOME,
      DIST: dist, SITE_ENV: 'test', SITE_URL: `http://127.0.0.1:${port}`,
      ARTICLES_CACHE_DIR: join(work, 'cache'), ARTICLES_STATE_FILE: join(work, 'state.json'), ARTICLES_IMAGES: '0',
    },
  });
  assert.equal(r.status, 0, `build kaatui:\n${r.stdout}\n${r.stderr}`);
  server = spawn('node', ['scripts/serve.mjs', dist, String(port)], { cwd: root, stdio: 'ignore' });
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('palvelin ei käynnistynyt')), 8000);
    const ping = () => fetch(`http://127.0.0.1:${port}/`).then((x) => { clearTimeout(t); res(x); }).catch(() => setTimeout(ping, 80));
    ping();
  });
  browser = await chromium.launch({ executablePath: chromePath(), args: ['--no-sandbox', '--disable-dev-shm-usage'] });
});
after(async () => {
  await browser?.close();
  server?.kill();
  rmSync(work, { recursive: true, force: true });
});

async function open(width, path) {
  const page = await browser.newPage({ viewport: { width, height: 900 }, deviceScaleFactor: 1 });
  await page.goto(`http://127.0.0.1:${port}${path}`, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  return page;
}

async function setDay(page, index) {
  await page.evaluate((i) => {
    const items = [...document.querySelectorAll('.week.soon > li')];
    items.forEach((li, n) => {
      const today = n === i, next = n === (i + 1) % items.length;
      li.classList.toggle('is-today', today);
      li.classList.toggle('is-next', next);
      if (today) li.setAttribute('aria-current', 'date');
      else li.removeAttribute('aria-current');
    });
    document.querySelector('.week.soon')?.classList.add('is-filtered');
  }, index);
}

async function layout(page) {
  return page.evaluate(() => {
    const row = document.querySelector('.week.soon > li.is-today');
    const h3 = row.querySelector('h3');
    const badgeEl = h3.querySelector('.today');
    const range = document.createRange();
    range.selectNodeContents(h3.firstChild);
    const box = (el) => {
      const r = el.getBoundingClientRect();
      return { x: r.x, y: r.y, top: r.top, right: r.right, bottom: r.bottom, left: r.left, width: r.width, height: r.height };
    };
    const summary = document.querySelector('.week-more summary');
    const kicker = document.querySelector('.tradition .kicker');
    const ss = getComputedStyle(summary);
    const week = document.querySelector('.week.soon');
    return {
      sessions: row.querySelectorAll('.sess').length,
      name: box(range),
      badge: box(badgeEl),
      targets: [...row.querySelectorAll('.sess .t, .sess .n, .sess .bk')].map((el) => ({ text: el.textContent.trim().slice(0, 48), box: box(el) })),
      slLeft: box(row.querySelector('.sl')).left,
      gap: kicker.getBoundingClientRect().top - summary.getBoundingClientRect().bottom,
      summary: {
        h: summary.getBoundingClientRect().height,
        border: parseFloat(ss.borderTopWidth),
        radius: parseFloat(ss.borderTopLeftRadius),
        cursor: ss.cursor,
        bg: ss.backgroundColor,
        display: getComputedStyle(document.querySelector('.week-more')).display,
      },
      scrollW: document.documentElement.scrollWidth,
      clientW: document.documentElement.clientWidth,
      cols: getComputedStyle(week).gridTemplateColumns.split(' ').filter(Boolean).length,
      visible: [...document.querySelectorAll('.week.soon > li')].filter((li) => getComputedStyle(li).display !== 'none').length,
    };
  });
}

const cases = [
  { lang: 'fi', path: '/', day: 2, sessions: 1, label: 'keskiviikko-1' },
  { lang: 'fi', path: '/', day: 3, sessions: 2, label: 'torstai-2' },
  { lang: 'en', path: '/en/', day: 2, sessions: 1, label: 'wednesday-1' },
  { lang: 'en', path: '/en/', day: 3, sessions: 2, label: 'thursday-2' },
];

test('mobiili 360/390/430: Tänään-merkki nimen alla, ei päällekkäisyyttä, nappi ja tiivis väli; desktop 7 saraketta', async () => {
  for (const width of [360, 390, 430]) {
    for (const c of cases) {
      const page = await open(width, c.path);
      await setDay(page, c.day);
      const m = await layout(page);
      assert.equal(m.sessions, c.sessions, `${width} ${c.label} vuoroja`);
      assert.ok(m.badge.width > 8 && m.badge.height > 8, `${width} ${c.label} merkki näkyy`);
      assert.ok(m.badge.top >= m.name.bottom - 1, `${width} ${c.label}: merkki ei ole päivän nimen alla (${m.badge.top} < ${m.name.bottom})`);
      assert.ok(!hit(m.badge, m.name), `${width} ${c.label}: merkki peittää päivän nimen`);
      assert.ok(m.badge.right <= m.slLeft + 1, `${width} ${c.label}: merkki karkaa vuorosarakkeeseen`);
      assert.ok(m.name.right <= m.slLeft + 1, `${width} ${c.label}: päivän nimi karkaa vuorosarakkeeseen`);
      for (const t of m.targets) {
        assert.ok(!hit(m.badge, t.box), `${width} ${c.label}: merkki peittää «${t.text}»`);
        assert.ok(!hit(m.name, t.box), `${width} ${c.label}: päivän nimi peittää «${t.text}»`);
      }
      assert.ok(m.gap >= 8 && m.gap <= 36, `${width} ${c.label}: väli nappiin ${m.gap}px`);
      assert.ok(m.summary.h >= 44, `napin korkeus ${m.summary.h}`);
      assert.ok(m.summary.border >= 1, 'napilla on reunus');
      assert.ok(m.summary.radius >= 8, 'nappi on pyöristetty');
      assert.equal(m.summary.cursor, 'pointer');
      assert.equal(m.summary.display, 'block');
      assert.equal(m.visible, 2, 'vain tänään ja huomenna');
      assert.ok(m.scrollW <= m.clientW + 1, `sivuttainen ylivuoto ${m.scrollW}>${m.clientW}`);
      if (shots && c.lang === 'fi') {
        mkdirSync(shots, { recursive: true });
        await page.evaluate(() => {
          const head = document.querySelector('.week-head');
          document.documentElement.style.scrollBehavior = 'auto';
          window.scrollTo({ top: head.getBoundingClientRect().top + window.scrollY - 8, behavior: 'instant' });
        });
        const clip = await page.evaluate(() => {
          const head = document.querySelector('.week-head');
          const kick = document.querySelector('.tradition .sec-title');
          const a = head.getBoundingClientRect();
          const b = kick.getBoundingClientRect();
          const y = Math.max(0, Math.floor(Math.min(a.top, window.innerHeight - 2)));
          const height = Math.max(1, Math.floor(Math.min(window.innerHeight - y - 1, b.bottom - y + 12)));
          return { x: 0, y, width: window.innerWidth, height };
        });
        await page.screenshot({ path: join(shots, `after_${width}_${c.label}.png`), clip });
      }
      await page.close();
    }
  }
  const desk = await open(1440, '/');
  await setDay(desk, 2);
  const d = await layout(desk);
  assert.equal(d.cols, 7, `desktop sarakkeita ${d.cols}`);
  assert.equal(d.summary.display, 'none', 'desktop ei näytä tiivistyksen nappia');
  assert.equal(d.visible, 7);
  await desk.close();
});
