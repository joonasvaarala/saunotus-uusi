// Hallinnan "Uusi varaus" -näkymän selainharness: staattinen palvelin (booking/admin) + Supabase-RPC:t mockattuna page.route:lla.
// EI tuotantoa eikä oikeaa kantaa. Käyttö: e2e-uusi-varaus.mjs ja kuvakaappausajot. Playwright: PW_DIR=/workspace/node_modules
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url)), ROOT = resolve(here, '../..');
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
export const chromium = pw.chromium || pw.default.chromium;
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png' };
export let ORIGIN = '';
export const TZ = 'Europe/Helsinki';
export const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
export const today = new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
export const DAY = addDays(today, 3);

export async function startServer(adminDir = join(ROOT, 'booking/admin')) {
  const server = createServer(async (req, res) => {
    const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (p === '/admin/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: ORIGIN, anonKey: 'anon-test', rest: '/rest/v1', auth: '/auth/v1', functions: '/functions/v1', schema: 'booking' })};`); }
    let file;
    if (p === '/admin/sb.js') file = join(ROOT, 'booking/shared/sb.js');
    else if (p.startsWith('/shop/')) file = join(ROOT, 'booking/shop', p.slice(6));
    else if (p.startsWith('/admin/')) file = join(adminDir, p.slice(7) || 'index.html');
    else { res.writeHead(p === '/admin' ? 301 : 404, p === '/admin' ? { location: '/admin/' } : {}); return res.end(); }
    try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); const buf = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(buf); }
    catch { res.writeHead(404); res.end('Not found'); }
  });
  await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
  ORIGIN = `http://127.0.0.1:${server.address().port}`;
  return server;
}

const slot = (id, hh, mm, endH, endM, over = {}) => ({ rule_id: id, product_id: over.product_id || 1, label: over.label || 'Yleinen vuoro', mode: 'shared', status: 'available', remaining: 12, min_persons: 1, max_persons: 16,
  price_mode: 'per_person', unit_price: 18, base_price: 0, included_persons: 0, extra_person_price: 0,
  starts_at: new Date(`${DAY}T${String(hh).padStart(2, '0')}:${String(mm).padStart(2, '0')}:00+03:00`).toISOString(), ends_at: new Date(`${DAY}T${String(endH).padStart(2, '0')}:${String(endM).padStart(2, '0')}:00+03:00`).toISOString(), ...over });
export const SESSIONS = [
  slot(1, 16, 0, 17, 30, { pool_capacity: 16, pool_peak: 4 }), slot(2, 17, 30, 19, 0, { remaining: 0, status: 'full', pool_capacity: 10, pool_peak: 11 }),
  slot(3, 19, 0, 20, 30, { remaining: 5, pool_capacity: 10, pool_peak: 5 }),
  slot(4, 14, 0, 17, 0, { product_id: 2, label: 'Yksityisvuoro', mode: 'exclusive', remaining: 1, min_persons: 1, max_persons: 10, price_mode: 'base_plus_extra', unit_price: 0, base_price: 150, included_persons: 6, extra_person_price: 15 }),
];
export const ADDONS = [
  { id: 1, code: 'turvenaamio_jalkakylpy', name: 'Turvenaamio ja jalkakylpy', name_en: 'Peat mask and foot bath', description: 'Lisäpalvelu varaukseen: turvenaamio ja jalkakylpy.', description_en: 'Add-on for your booking: peat mask and foot bath.', price: 15, max_per_person: 1, applies_modes: ['shared', 'exclusive'], active: true },
  { id: 2, code: 'saunavihta', name: 'Saunavihta', name_en: 'Sauna whisk', description: 'Lisäpalvelu varaukseen: saunavihta.', description_en: 'Add-on for your booking: sauna whisk.', price: 13, max_per_person: 1, applies_modes: ['shared', 'exclusive'], active: true },
  { id: 3, code: 'pyyhe', name: 'Pyyhe', name_en: 'Towel', description: 'Lisäpalvelu varaukseen: pyyhe.', description_en: 'Add-on for your booking: towel.', price: 5, max_per_person: 1, applies_modes: ['shared', 'exclusive', 'resource'], active: true },
];
const CUSTOMERS = [
  { id: 11, name: 'Matti Meikäläinen', email: 'matti@example.com', phone: '+358401234567', customer_kind: 'private' },
  { id: 12, name: 'Liisa Laine', email: 'liisa@nordic.example', phone: '', customer_kind: 'company', company: 'Nordic Oy', business_id: '0112038-9' },
];
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const fakeJwt = () => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: 'u1', email: 'owner@test.local', role: 'authenticated', exp: 4102444800 })}.${Buffer.from('x').toString('base64url')}`;
export const PERMS = ['payments.manage', 'bookings.manage', 'customers.manage', 'catalog.edit'];

// st = { calls: [{name,args}], createFail?: {code,message} }
export function rpcMock(st, name, a) {
  st.calls.push({ name, args: a });
  switch (name) {
    case 'current_staff_role': return 'owner';
    case 'admin_my_permissions': return { role: 'owner', role_label: 'Omistaja', permissions: PERMS };
    case 'admin_list_products': return [{ id: 1, name: 'Yleinen vuoro', category: 'public', active: true, config: {} }, { id: 2, name: 'Yksityisvuoro', category: 'private', active: true, config: {} }];
    case 'admin_list_addons': return ADDONS;
    case 'admin_day_view': return { date: a.p_date, sessions: SESSIONS, reservations: [] };
    case 'admin_list_customers': { const q = String(a.p_search || '').toLowerCase(); return CUSTOMERS.filter((c) => [c.name, c.email, c.phone, c.company].join(' ').toLowerCase().includes(q)); }
    case 'admin_create_booking': {
      if (st.createFail) throw Object.assign(new Error(st.createFail.message), { status: 400, code: st.createFail.code });
      const s = SESSIONS.find((x) => x.rule_id === a.p_rule_id);
      const base = a.p_price ?? (s.price_mode === 'per_person' ? s.unit_price * a.p_persons : s.base_price + Math.max(0, a.p_persons - s.included_persons) * s.extra_person_price);
      const add = (a.p_addons || []).reduce((t, x) => t + ADDONS.find((d) => d.id === x.id).price * x.quantity, 0);
      return { order_id: 900, order_no: 4711, reservation_id: 500, product_name: s.label, starts_at: s.starts_at, ends_at: s.ends_at, total: base + add };
    }
    case 'admin_create_annual_card_booking': return { order_id: 901, order_no: 4712, reservation_id: 501, product_name: 'Yleinen vuoro', starts_at: SESSIONS[0].starts_at, ends_at: SESSIONS[0].ends_at, total: 0 };
    case 'admin_list_reservations': return [{ reservation_id: 500, order_id: 900, order_no: 15005, status: 'confirmed', order_status: 'confirmed', payment_status: 'unpaid', product_id: 1, product_name: 'Yleinen vuoro', mode: 'shared', starts_at: SESSIONS[0].starts_at, ends_at: SESSIONS[0].ends_at,
      persons: 2, total_gross: 36, customer_id: 11, customer_name: 'Matti Meikäläinen', customer_email: 'matti@example.com', customer_phone: '+358401234567', source_channel: 'admin', created_at: new Date().toISOString(), hold_expires_at: null, notes: null, annual_card_id: null, total_count: 1 }];
    case 'admin_create_payment_link': return { message: 'Maksulinkki tulossa' };
    case 'public_get_site_texts': return { ok: true, texts: [] };
    case 'admin_check_gift_card': {
      const code = String(a.p_code || '').replace(/[^a-z0-9]/gi, '').toUpperCase();
      if (code === 'TESTCARD0001') return { ok: true, code: 'TEST-CARD-0001', balance: 10, valid_to: '2027-12-31', redeemable: true, status: 'active', source: 'native' };
      if (code === 'JOHKUTEST001') return { ok: true, code: 'JOHKU-TEST-001', balance: 40, valid_to: '2027-06-01', redeemable: true, status: 'active', source: 'johku' };
      return { ok: false, code: 'invalid_code', message: 'Koodia ei löydy tai se ei ole käytettävissä' };
    }
    case 'admin_preview_discount_code': {
      const code = String(a.p_code || '').toUpperCase();
      if (code !== 'KIITOSKAUPPA') return { ok: false, code: 'invalid_code', message: 'Koodia ei löytynyt' };
      const persons = a.p_persons || 1;
      const sub = (a.p_price ?? 18 * persons);
      const discount = Math.round(sub * 0.1 * 100) / 100;
      return { ok: true, type: 'discount', code, kind: 'percent', value: 10, subtotal: sub, discount, total: sub - discount };
    }
    case 'admin_preview_booking_limits': {
      const s = SESSIONS.find((x) => x.rule_id === a.p_rule_id) || SESSIONS[0];
      const n = a.p_persons || 1;
      const over = []; const off = [];
      if (s.pool_capacity != null && (s.pool_peak || 0) + n > s.pool_capacity) over.push({ code: 'capacity_exceeded', used: (s.pool_peak || 0) + n, capacity: s.pool_capacity });
      if (s.status === 'unavailable') off.push({ code: 'closure' });
      if (a.p_start && s.status !== 'off_schedule') off.push({ code: 'outside_hours' });
      return { ok: true, overbook: over, off_schedule: off, overbooked: over.length > 0, off: off.length > 0 };
    }
    case 'admin_change_booking': return { ok: true };
    default: { const e = new Error(`Could not find the function booking.${name}`); e.status = 404; e.code = 'PGRST202'; e.pgrst = true; throw e; }
  }
}

export async function newPage(browser, { vp = 390, lang = 'fi', st, onProblem = () => {} } = {}) {
  const ctx = await browser.newContext({ viewport: { width: vp, height: vp >= 900 ? 900 : 844 }, deviceScaleFactor: 1, isMobile: vp < 700, hasTouch: vp < 700, locale: lang === 'fi' ? 'fi-FI' : 'en-GB', timezoneId: TZ });
  const page = await ctx.newPage(); page.setDefaultTimeout(8000);
  page.on('pageerror', (e) => onProblem(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !/status of 4\d\d/.test(m.text())) onProblem(`console ${m.type()}: ${m.text()}`); });
  await page.route(`${ORIGIN}/rest/v1/**`, async (route) => {
    const u = new URL(route.request().url()), json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (route.request().method() !== 'POST') {
      if (u.pathname.endsWith('/payment_methods')) return json([{ code: 'pay_later', label: 'Maksetaan paikan päällä', is_manual: true, active: true }, { code: 'cash', label: 'Käteinen', is_manual: true, active: true }, { code: 'card_terminal', label: 'Korttipääte', is_manual: true, active: true }, { code: 'mobilepay', label: 'MobilePay', is_manual: true, active: true }, { code: 'invoice', label: 'Lasku (yritykset)', is_manual: true, active: true }, { code: 'gift_card', label: 'Lahjakortti', is_manual: false, active: true }]);
      if (u.pathname.includes('/schedule_rules')) return json([{ id: 9, product_id: 1, label: 'Arki-iltavuoro', mode: 'shared', start_time: '16:00:00', duration_minutes: 90, min_persons: 1, max_persons: 16, weekdays: [1], space_id: 1 }]);
      return json([]);
    }
    let a = {}; try { a = JSON.parse(route.request().postData() || '{}'); } catch { /* tyhjä */ }
    try { return json(rpcMock(st, u.pathname.split('/rpc/')[1], a)); } catch (e) { return json(e.pgrst ? { code: 'PGRST202', message: e.message } : { code: 'BK001', details: e.code, message: e.message }, e.status || 400); }
  });
  await ctx.addInitScript(([s, l]) => { try { localStorage.setItem('booking.session', JSON.stringify(s)); localStorage.setItem('booking.admin.lang', l); } catch { /* */ } }, [{ access_token: fakeJwt(), refresh_token: 'r', expires_at: 4102444800, user: { id: 'u1', email: 'owner@test.local' } }, lang]);
  return page;
}
export const launch = () => chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
