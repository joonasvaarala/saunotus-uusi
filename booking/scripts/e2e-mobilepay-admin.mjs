// E2E (Playwright + google-chrome): hallinnan hyvitysvirta verkkomaksulle (provider montonio) – vain mock-datalla, EI tuotantokantaa eikä oikeaa maksuvälittäjää.
// admin_refund luo rivin status='requested' → hallinta kutsuu POST montonio-refund {refund_id} käyttäjän JWT:llä.
// Keskeneräisen hyvityksen voi käsitellä uudelleen. Muun maksutavan hyvitys ei kutsu montonio-refundia.
//   PW_DIR=/workspace/node_modules node booking/scripts/e2e-mobilepay-admin.mjs        (ei vaadi rakennusta: hallinta ajetaan lähdekoodista)
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join, extname, resolve } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url)), ROOT = resolve(here, '../..');
const require = createRequire(import.meta.url);
const pwPath = require.resolve('playwright-core', { paths: [process.cwd(), process.env.PW_DIR || '', here].filter(Boolean) });
const pw = await import(pathToFileURL(pwPath));
const chromium = pw.chromium || pw.default.chromium;
const { createMock } = await import(pathToFileURL(join(ROOT, 'booking/admin/talous-mock.js')));
const { TEXTS } = await import(pathToFileURL(join(ROOT, 'booking/admin/talous-texts.js')));
const problems = []; let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml' };
let ORIGIN = '';
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname); let file;
  if (p === '/admin/config.js' || p === '/booking/config.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(`window.BOOKING_CONFIG=${JSON.stringify({ url: ORIGIN, anonKey: 'anon-test', rest: '/rest/v1', functions: '/functions/v1' })};`); }
  if (p === '/admin/sb.js') file = join(ROOT, 'booking/shared/sb.js');
  else if (p.startsWith('/admin/')) file = join(ROOT, 'booking/admin', p.slice(7) || 'index.html');
  else if (p === '/admin') { res.writeHead(301, { location: '/admin/' }); return res.end(); }
  else { res.writeHead(404); return res.end('Not found'); }
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' }); res.end(await readFile(file)); } catch { res.writeHead(404); res.end('Not found'); }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
ORIGIN = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const JWT = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: 'u1', email: 'manager@test.local', role: 'authenticated', exp: 4102444800 })}.${Buffer.from('x').toString('base64url')}`;
const mk = createMock({ delay: 0 });

// Yksi tilaus (mockin maksettu natiivitilaus), jonka maksu on joko verkkomaksu (montonio) tai käteinen; hyvitysrivit pidetään tässä tilassa
async function session({ lang, provider, perms, fnReplies }) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: lang === 'fi' ? 'fi-FI' : 'en-GB', timezoneId: 'Europe/Helsinki' });
  const page = await ctx.newPage();
  const st = { calls: [], fnCalls: [], refunds: [], replies: [...fnReplies] };
  page.st = st;
  page.on('pageerror', (e) => problems.push(`${lang}/${provider} pageerror: ${e.message}`));
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && !/status of (4|5)\d\d|Failed to load resource/.test(m.text())) problems.push(`${lang}/${provider} console ${m.type()}: ${m.text()}`); });
  await page.route(`${ORIGIN}/rest/v1/**`, async (route) => {
    const u = new URL(route.request().url()), json = (b, s = 200) => route.fulfill({ status: s, contentType: 'application/json', body: JSON.stringify(b) });
    if (route.request().method() !== 'POST') return json([]);
    const name = u.pathname.split('/rpc/')[1]; let a = {}; try { a = JSON.parse(route.request().postData() || '{}'); } catch { /* */ }
    st.calls.push({ name, args: a });
    if (name === 'current_staff_role') return json('manager');
    if (name === 'admin_my_permissions') return json({ role: 'manager', role_label: 'Päällikkö', permissions: perms });
    if (name === 'admin_list_products') return json([]);
    if (name === 'public_gift_card_packages') return json({ ok: true, sale_enabled: false, redeem_enabled: false, max_cards_per_order: 10, currency: 'EUR', packages: [] });
    if (name === 'admin_refund') {
      st.refunds.push({ id: 777 + st.refunds.length, amount: a.p_amount, status: provider === 'montonio' ? 'requested' : 'done', reason: a.p_reason, created_at: new Date().toISOString() });
      const r = st.refunds.at(-1); return json({ ok: true, refund_id: r.id, status: r.status, amount: r.amount });
    }
    try {
      const r = await mk.rpc(name, a);
      if (name === 'admin_get_order') { r.payments[0].provider = provider; if (provider === 'montonio') { r.payments[0].method = 'montonio'; r.payments[0].method_label = 'Maksa verkossa'; } r.payments[0].refunds = st.refunds.map((x) => ({ ...x })); }
      return json(r);
    } catch (e) { return json({ code: 'PGRST202', message: e.message }, e.status || 404); }
  });
  await ctx.route(`${ORIGIN}/functions/v1/montonio-refund`, async (route) => {
    const r = route.request(); st.fnCalls.push({ auth: r.headers().authorization || null, apikey: r.headers().apikey || null, body: JSON.parse(r.postData() || '{}'), method: r.method() });
    const reply = st.replies.shift() || { result: 'done' };
    const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*' };
    if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    if (reply.abort) return route.abort('failed');
    if (reply.status) return route.fulfill({ status: reply.status, contentType: 'application/json', headers: cors, body: JSON.stringify(reply.body) });
    const id = st.fnCalls.at(-1).body.refund_id;
    if (reply.result === 'done') { const x = st.refunds.find((q) => q.id === id); if (x) x.status = 'done'; }
    return route.fulfill({ status: 200, contentType: 'application/json', headers: cors, body: JSON.stringify({ ok: true, mode: 'test', processed: [{ refund_id: id, result: reply.result, detail: reply.detail ?? null }] }) });
  });
  await ctx.addInitScript((s) => { try { localStorage.setItem('booking.session', JSON.stringify(s)); } catch { /* */ } }, { access_token: JWT, refresh_token: 'r', expires_at: 4102444800, user: { id: 'u1', email: 'manager@test.local' } });
  await page.goto(`${ORIGIN}/admin/#/talous?lang=${lang}`);
  await page.waitForSelector('[data-testid=orders-list] > [data-testid=order]');
  await page.selectOption('[data-testid=orders-f-pay]', 'paid'); await page.waitForTimeout(250);
  await page.locator('[data-testid=orders-list] > [data-testid=order]').first().locator('.tl-head').click(); await page.waitForSelector('[data-testid=order-actions]');
  return page;
}
const toastText = async (page, kind) => { await page.waitForSelector(`#toast.show.${kind}`); return (await page.locator('#toast').innerText()).trim(); };
async function openRefund(page) { await page.locator('[data-testid=btn-refund]').first().click(); await page.waitForSelector('dialog[open] form'); }
async function submitRefund(page, reason = 'Asiakas peruutti') { await page.fill('dialog[open] [name=reason]', reason); await page.click('dialog[open] button[type=submit]'); }

for (const lang of ['fi', 'en']) {
  const T = TEXTS[lang], PERMS = ['payments.manage', 'payments.refund', 'bookings.manage', 'customers.manage', 'reports.view'];
  // 1) MobilePay-maksu: retry_later → keskeneräinen rivi + uudelleenkäsittely → done
  {
    const name = `${lang}/montonio`;
    const page = await session({ lang, provider: 'montonio', perms: PERMS, fnReplies: [{ result: 'retry_later' }, { result: 'done' }] });
    await openRefund(page);
    expect(await page.locator('dialog[open] [data-testid=refund-mo-hint]').isVisible(), `${name}: verkkomaksun vihje näkyy dialogissa`);
    expect((await page.locator('dialog[open] [data-testid=refund-mo-hint]').innerText()) === T['refund.montonio'], `${name}: vihjeen teksti`);
    await submitRefund(page);
    expect((await toastText(page, 'warn')) === T['refund.mo.retry_later'], `${name}: retry_later-ilmoitus`);
    expect(page.st.fnCalls.length === 1, `${name}: montonio-refund kutsuttu kerran (${page.st.fnCalls.length})`);
    const c = page.st.fnCalls[0];
    expect(c.method === 'POST' && JSON.stringify(c.body) === JSON.stringify({ refund_id: 777 }), `${name}: runko {refund_id: 777} ${JSON.stringify(c.body)}`);
    expect(c.auth === `Bearer ${JWT}` && c.apikey === 'anon-test', `${name}: käyttäjän JWT + apikey (${c.auth?.slice(0, 20)})`);
    expect(page.st.calls.filter((x) => x.name === 'admin_refund').length === 1 && page.st.calls.find((x) => x.name === 'admin_refund').args.p_payment_id !== undefined, `${name}: admin_refund kutsuttu ensin`);
    // tilauksen tiedot ladataan uudelleen → keskeneräinen hyvitys + uudelleenkäsittely-nappi
    await page.waitForSelector('[data-testid=open-refund][data-status=requested]');
    expect((await page.locator('[data-testid=btn-refund-retry]').count()) === 1, `${name}: uudelleenkäsittelynappi`);
    const rb = await page.locator('[data-testid=btn-refund-retry]').boundingBox(); expect(rb && rb.height >= 43.5, `${name}: nappi ≥44 px (${rb?.height})`);
    expect((await page.locator('[data-testid=btn-refund-retry]').innerText()).includes(T['refund.retry']), `${name}: napin teksti`);
    await page.click('[data-testid=btn-refund-retry]');
    expect((await toastText(page, 'ok')) === T['refund.mo.done'], `${name}: done-ilmoitus`);
    expect(page.st.fnCalls.length === 2 && page.st.fnCalls[1].body.refund_id === 777, `${name}: sama refund_id uudelleen (Idempotency-Key palvelimella)`);
    await page.waitForSelector('[data-testid=open-refund]', { state: 'detached' });
    expect((await page.locator('[data-testid=order-open-refunds]').count()) === 0, `${name}: valmis hyvitys poistuu keskeneräisistä`);
    await page.context().close();
  }
  // 2) failed / unverified / forbidden (403) / verkkovirhe / ei-JSON 502: ilmoitus oikeaa tyyppiä, mitään ei heitetä
  for (const [label, reply, key, kind] of [['failed', { result: 'failed', detail: { error: 'x' } }, 'refund.mo.failed', 'err'], ['pending', { result: 'pending' }, 'refund.mo.pending', 'warn'],
    ['forbidden', { status: 403, body: { ok: false, code: 'forbidden', message: 'forbidden' } }, 'refund.mo.forbidden', 'err'], ['verkko', { abort: true }, 'refund.mo.error', 'warn'], ['502', { status: 502, body: { message: 'Bad gateway' } }, 'refund.mo.error', 'warn'],
    ['off', { status: 200, body: { ok: true, mode: 'off', processed: [] } }, 'refund.mo.off', 'warn']]) {
    const name = `${lang}/montonio/${label}`;
    const page = await session({ lang, provider: 'montonio', perms: PERMS, fnReplies: [reply] });
    await openRefund(page); await submitRefund(page);
    expect((await toastText(page, kind)) === T[key], `${name}: ilmoitus ${key} (${await page.locator('#toast').innerText()})`);
    expect(page.st.fnCalls.length === 1, `${name}: yksi kutsu`);
    await page.waitForSelector('[data-testid=open-refund][data-status=requested]');   // rivi jää jonoon → voi yrittää uudelleen
    await page.context().close();
  }
  // 3) Muu maksutapa: ei MobilePay-vihjettä eikä mobilepay-refund-kutsua
  {
    const name = `${lang}/manual`;
    const page = await session({ lang, provider: 'manual', perms: PERMS, fnReplies: [] });
    await openRefund(page);
    expect(!(await page.locator('dialog[open] [data-testid=refund-mo-hint]').isVisible()), `${name}: ei verkkomaksun vihjettä`);
    await submitRefund(page); await page.waitForSelector('dialog[open]', { state: 'detached' }); await page.waitForTimeout(300);
    expect(page.st.fnCalls.length === 0, `${name}: montonio-refundia ei kutsuta`);
    expect(page.st.calls.some((x) => x.name === 'admin_refund'), `${name}: admin_refund kutsuttu`);
    await page.context().close();
  }
  // 4) Ei oikeutta payments.refund: hyvitysnappia ei renderöidä (palvelin tarkistaa joka tapauksessa), uudelleenkäsittelynappia ei näytetä
  {
    const name = `${lang}/ei-oikeutta`;
    const page = await session({ lang, provider: 'montonio', perms: PERMS.filter((p) => p !== 'payments.refund'), fnReplies: [] });
    expect((await page.locator('[data-testid=btn-refund]').count()) === 0, `${name}: hyvitysnappia ei näytetä ilman oikeutta`);
    expect((await page.locator('[data-testid=btn-refund-retry]').count()) === 0, `${name}: ei uudelleenkäsittelynappia`);
    await page.context().close();
  }
}
await browser.close(); server.close();
if (problems.length) { console.error(`ONGELMIA (${problems.length}/${checks}):\n` + [...new Set(problems)].join('\n')); process.exit(1); }
console.log(`ok: hallinnan verkkomaksun hyvitysvirta, ${checks} tarkistusta, 0 ongelmaa`);
