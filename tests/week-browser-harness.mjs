// Selaintestien yhteinen runko viikko-ohjelmalle: rakentaa sivuston väliaikaiseen hakemistoon, kopioi kaupan moduulit /booking/-polkuun
// ja korvaa sb.js:n mockilla (window.__MOCK → public_*-vastaukset). Ei verkkoa, ei kantaa. Kello kiinnitetään page.clock-asetuksella.
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, existsSync, mkdirSync, cpSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromium } from 'playwright-core';

export const root = resolve(new URL('..', import.meta.url).pathname);
export const hit = (a, b) => !(a.right <= b.left + 0.5 || a.left >= b.right - 0.5 || a.bottom <= b.top + 0.5 || a.top >= b.bottom - 0.5);
export const NOW_ISO = '2026-11-16T08:00:00+02:00';   // maanantai, viikko 47
export const TODAY = '2026-11-16';

function chromePath() {
  if (process.env.CHROME_PATH && existsSync(process.env.CHROME_PATH)) return process.env.CHROME_PATH;
  for (const p of ['/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser']) if (existsSync(p)) return p;
  throw new Error('Chrome puuttuu. Aseta CHROME_PATH tai asenna google-chrome.');
}

const MOCK_SB = `export async function rpc(name, a = {}) {
  const m = globalThis.__MOCK || {};
  (globalThis.__RPC ||= []).push({ name, args: a });
  if (m.fail && m.fail.includes(name)) throw new Error('mock-virhe ' + name);
  if (name === 'public_availability_all') return (m.rows || []).filter((r) => r.session_date >= a.p_from && r.session_date <= a.p_to);
  if (name === 'public_quiet_offers') return m.offers || [];
  if (name === 'public_events') return m.events || [];
  if (name === 'public_settings') return m.settings || { public_treatment_horizon_days: 90 };
  if (name === 'public_catalog') return m.catalog || [];
  if (name === 'public_treatment_availability') return (m.treat || []).filter((r) => r.product_id === a.p_product_id && r.session_date >= a.p_from && r.session_date <= a.p_to);
  throw new Error('tuntematon rpc ' + name);
}
`;

export async function startSite({ port, tag }) {
  const work = mkdtempSync(join(tmpdir(), `${tag}-`));
  const dist = join(work, 'dist');
  const r = spawnSync('node', ['scripts/build.mjs'], {
    cwd: root, encoding: 'utf8',
    env: { PATH: process.env.PATH, HOME: process.env.HOME, DIST: dist, SITE_ENV: 'test', SITE_URL: `http://127.0.0.1:${port}`,
      ARTICLES_CACHE_DIR: join(work, 'cache'), ARTICLES_STATE_FILE: join(work, 'state.json'), ARTICLES_IMAGES: '0',
      // Sivutekstit: tyhjä välimuisti → repon varateksti (ei CI:n edellisen ajon kannasta tallentamaa snapshotia), jotta testi ei riipu DEVin tekstien tilasta
      SITE_TEXTS_CACHE_DIR: join(work, 'site-texts') },
  });
  if (r.status !== 0) throw new Error(`build kaatui:\n${r.stdout}\n${r.stderr}`);
  const booking = join(dist, 'booking');
  mkdirSync(booking, { recursive: true });
  const src = join(root, 'booking/shop/src');
  for (const f of readdirSync(src)) if (f.endsWith('.js')) cpSync(join(src, f), join(booking, f));
  writeFileSync(join(booking, 'sb.js'), MOCK_SB);
  const server = spawn('node', ['scripts/serve.mjs', dist, String(port)], { cwd: root, stdio: 'ignore' });
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('palvelin ei käynnistynyt')), 8000);
    const ping = () => fetch(`http://127.0.0.1:${port}/`).then(() => { clearTimeout(t); res(); }).catch(() => setTimeout(ping, 80));
    ping();
  });
  const browser = await chromium.launch({ executablePath: chromePath(), args: ['--no-sandbox', '--disable-dev-shm-usage'] });
  return {
    browser, port,
    async stop() { await browser?.close(); server?.kill(); rmSync(work, { recursive: true, force: true }); },
    /** Avaa sivu kiinnitetyllä kellolla ja mock-datalla; käynnistää viikko-ohjelman (quiet-week.js) ja odottaa live-piirron. */
    async open(width, path, mock, { height = 1000, live = true, now = NOW_ISO } = {}) {
      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
      await page.clock.install({ time: new Date(now) });
      const lang = path.startsWith('/en/') ? 'en' : 'fi';
      await page.addInitScript(({ mock, lang }) => { globalThis.__MOCK = mock; window.BOOKING_QUIET = { lang, shopHref: '/varaa/' }; window.BOOKING_CONFIG = { url: 'http://mock' }; }, { mock, lang });
      await page.goto(`http://127.0.0.1:${port}${path}`, { waitUntil: 'domcontentloaded' });
      await page.evaluate(() => document.fonts.ready);
      if (live) {
        await page.addScriptTag({ type: 'module', url: '/booking/quiet-week.js' });
        await page.waitForSelector('.vk[data-vk-live] .vk-day', { timeout: 8000 });
      }
      return page;
    },
  };
}

// ---- mock-data: viikko 47 (16.–22.11.2026), marraskuu = UTC+2 ----
export const ut = (d, hhmm) => { const [hh, mm] = hhmm.split(':').map(Number); return new Date(Date.parse(`${d}T00:00:00Z`) + ((hh - 2) * 60 + mm) * 6e4).toISOString(); };
let rule = 1;
export const row = (slug, category, product_id, date, s, e, extra = {}) => ({ slug, category, product_id, rule_id: rule++, session_date: date, starts_at: ut(date, s), ends_at: ut(date, e), status: 'available', remaining: 10, unit_price: null, base_price: null, ...extra });
export const CATALOG = [
  { id: 1, slug: 'yleinensauna', name: 'Yleinen vuoro', name_en: 'Public Sauna Session', category: 'public_sauna', booking_kind: 'rules' },
  { id: 2, slug: 'miestensauna-2', name: 'Miesten sauna', name_en: "Men's Sauna", category: 'public_sauna', booking_kind: 'rules' },
  { id: 5, slug: 'turvetorstai', name: 'Turvetorstai', name_en: 'Peat Thursday', category: 'public_sauna', booking_kind: 'rules' },
  { id: 6, slug: 'tunnin-vuoro', name: 'Tunnin vuoro', category: 'public_sauna', booking_kind: 'rules' },
  { id: 25, slug: 'oma-saunavuoro', name: 'Oma savusaunavuoro', category: 'private_sauna', booking_kind: 'rules' },
  { id: 26, slug: 'jalkiloylyt', name: 'Savusaunan jälkilöylyt', name_en: 'After Session Sauna', category: 'private_sauna', booking_kind: 'rules' },
  { id: 10, slug: 'saunahoito-2', name: 'Saunahoito', name_en: 'Sauna Treatment', category: 'treatment', booking_kind: 'slots', price: 99, price_type: 'fixed', duration_minutes: 60, min_persons: 1, max_persons: 2 },
  { id: 8, slug: 'saunotusrituaali', name: 'Saunotusrituaali', category: 'ritual', booking_kind: 'slots', price: 20, price_type: 'per_person', duration_minutes: 20, min_persons: 1, max_persons: 6 },
  { id: 7, slug: 'saunarituaali-ja-savusaunavuoro', name: 'Saunarituaali ja savusaunavuoro (la & su)', name_en: 'Sauna ritual and smoke sauna', category: 'ritual', booking_kind: 'slots', price: 49, price_type: 'per_person', duration_minutes: 120, min_persons: 1, max_persons: 6 },
];
export function weekMock({ example = false } = {}) {
  const D = (n) => `2026-11-${String(n).padStart(2, '0')}`;
  const rows = [
    row('miestensauna-2', 'public_sauna', 2, D(16), '16:00', '19:00', { unit_price: 29 }),
    row('turvetorstai', 'public_sauna', 5, D(19), '16:00', '19:00', { unit_price: 35 }),
    row('yleinensauna', 'public_sauna', 1, D(19), '17:00', '19:00', { unit_price: 29 }),
    row('yleinensauna', 'public_sauna', 1, D(21), '14:00', '16:00', { unit_price: 29 }),
    row('yleinensauna', 'public_sauna', 1, D(21), '15:00', '17:00', { unit_price: 29, remaining: 2 }),
    row('yleinensauna', 'public_sauna', 1, D(21), '16:00', '18:00', { unit_price: 29, status: 'full', remaining: 0 }),
    row('tunnin-vuoro', 'public_sauna', 6, D(21), '14:00', '15:00', { unit_price: 18 }),
    ...[16, 17, 18, 19, 21, 22].map((d) => row('oma-saunavuoro', 'private_sauna', 25, D(d), '13:00', '15:00', { base_price: 250 })),
    row('oma-saunavuoro', 'private_sauna', 25, D(20), '17:00', '19:00', { base_price: 300 }),
    row('turvesauna', 'private_sauna', 31, D(21), '13:00', '15:00', { base_price: 400 }),
    row('saunavuoro-yrityksille', 'corporate', 48, D(21), '13:00', '15:00', { base_price: 350 }),
    row('jalkiloylyt', 'private_sauna', 26, D(16), '19:00', '21:00', { base_price: 180, rule_id: 22 }),
    row('jalkiloylyt', 'private_sauna', 26, D(17), '19:00', '21:00', { base_price: 180, rule_id: 22 }),
    row('jalkiloylyt', 'private_sauna', 26, D(18), '19:00', '21:00', { base_price: 180, rule_id: 22, status: 'full' }),
    row('jalkiloylyt', 'private_sauna', 26, D(21), '19:00', '22:00', { base_price: 300, rule_id: 24, status: 'full' }),
    row('oma-saunavuoro', 'private_sauna', 25, D(23), '13:00', '15:00', { base_price: 250 }),
    row('yleinensauna', 'public_sauna', 1, D(26), '16:00', '19:00', { unit_price: 29 }),
  ];
  const offers = [{ product_id: 26, rule_id: 22, session_date: D(16), starts_at: ut(D(16), '19:00'), ends_at: ut(D(16), '21:00'), percent: 20, base_price: 180, discounted_price: 144 }];
  const t = (id, d, s) => ({ product_id: id, session_date: D(d), starts_at: ut(D(d), s), ends_at: ut(D(d), '17:00'), status: 'available', total: 50 });
  const treat = [t(10, 17, '16:00'), t(10, 22, '13:00'), t(8, 21, '16:00'), t(7, 21, '16:00'), t(7, 22, '16:30')];
  const events = example
    ? [{ category: 'event', slug: 'perinnesaunotusilta', name: 'Perinnesaunotusilta', product_id: 9, price: 59, occurrences: [
        { rule_id: 69, status: 'available', starts_at: ut(D(20), '17:00'), ends_at: ut(D(20), '18:30') }, { rule_id: 70, status: 'available', starts_at: ut(D(20), '19:00'), ends_at: ut(D(20), '20:30') }] }]
    : [{ category: 'event', slug: 'perinnesaunotusilta', name: 'Perinnesaunotusilta', product_id: 9, price: 59, occurrences: [{ rule_id: 69, status: 'full', starts_at: ut('2026-12-04', '17:00'), ends_at: ut('2026-12-04', '18:30') }] },
      { category: 'event', slug: 'sipoonjoen-joulusauna', name: 'Sipoonjoen joulusauna', product_id: 113, price: 79, occurrences: [{ rule_id: 80, status: 'available', starts_at: ut('2026-12-19', '14:00'), ends_at: ut('2026-12-19', '16:00') }] }];
  return { rows, offers, treat, events, catalog: CATALOG };
}
