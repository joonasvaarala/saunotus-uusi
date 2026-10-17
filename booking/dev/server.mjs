// Paikallinen kehityspalvelin: staattiset tiedostot (kauppa + hallinta) + PostgREST-proxy + MOCK-kirjautuminen (korvaa Supabase Authin demossa).
//   node booking/dev/server.mjs            → http://localhost:4180/  (kauppa),  /admin/  (hallinta)
// EI tuotantoon: mock-auth hyväksyy kovakoodatut demo-tunnukset ja allekirjoittaa JWT:n demon salaisuudella.
import { createServer, request as httpRequest } from 'node:http';
import { readFile, stat, writeFile, mkdir, unlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createHmac, timingSafeEqual } from 'node:crypto';
import { execFile } from 'node:child_process';
import { treatmentRpc, catalogEntries, IMAGES as TREATMENT_IMAGES } from './treatment-mock.mjs';
import { validateRequest, mapDbError } from '../supabase/functions/admin-users/logic.js';
import { join, extname, normalize, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const booking = resolve(here, '..');
const PORT = +(process.env.PORT || 4180), PGRST = +(process.env.PGRST_PORT || 3300);
const SECRET = process.env.JWT_SECRET || 'demo-secret-demo-secret-demo-secret-0123456789';
const SHOP = resolve(process.env.SHOP_DIST || join(booking, 'shop/dist'));
const USERS = { 'admin@demo.local': '00000000-0000-4000-8000-0000000000a1', 'staff@demo.local': '00000000-0000-4000-8000-0000000000b2', 'manager@demo.local': '00000000-0000-4000-8000-0000000000c3' };
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2', '.xml': 'application/xml', '.txt': 'text/plain; charset=utf-8' };

const PASSWORDS = {}, BANNED = new Set();   // kutsutut/esteyt demokäyttäjät (muistissa); oletussalasana 'demo'
const DEMO_DB = process.env.DEMO_DB || 'booking_demo';

const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
function jwt(sub, email, role = 'authenticated') {
  const head = b64({ alg: 'HS256', typ: 'JWT' }), body = b64({ sub, email, role, aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 });
  return `${head}.${body}.${createHmac('sha256', SECRET).update(`${head}.${body}`).digest('base64url')}`;
}
function verifyJwt(auth) {
  const m = /^Bearer (([\w-]+)\.([\w-]+)\.([\w-]+))$/.exec(auth || ''); if (!m) return null;
  const want = createHmac('sha256', SECRET).update(`${m[2]}.${m[3]}`).digest();
  const got = Buffer.from(m[4], 'base64url');
  if (got.length !== want.length || !timingSafeEqual(got, want)) return null;
  try { const c = JSON.parse(Buffer.from(m[3], 'base64url').toString()); return c.exp > Date.now() / 1000 ? c : null; } catch { return null; }
}
// PostgREST-kutsu (booking-skeema) annetulla Authorization-tokenilla; palauttaa { data, error }
async function pgrst(fnName, args, token) {
  const r = await fetch(`http://127.0.0.1:${PGRST}/rpc/${fnName}`, { method: 'POST', headers: { 'content-type': 'application/json', 'content-profile': 'booking', 'accept-profile': 'booking', authorization: `Bearer ${token}` }, body: JSON.stringify(args) });
  const t = await r.text(); const j = t ? JSON.parse(t) : null;
  return r.ok ? { data: j, error: null } : { data: null, error: j || { message: r.statusText } };
}
// MOCK: Auth Adminin inviteUserByEmail → rivi auth.users-tauluun (vain demossa)
const mockInviteUser = (email) => new Promise((ok, no) => {
  const p = execFile('psql', ['-X', '-At', '-v', 'ON_ERROR_STOP=1', '-v', `email=${email}`, '-h', process.env.PGHOST || '127.0.0.1', '-p', process.env.PGPORT || '54329', '-U', process.env.PGUSER || 'postgres', '-d', DEMO_DB], (e, out) => (e ? no(e) : ok(out.trim().split('\n')[0])));
  p.stdin.end("insert into auth.users (email) values (:'email') returning id;\n");
});
// MOCK Edge Function admin-users: sama validointi (logic.js) ja samat DB-funktiot kuin oikeassa funktiossa (supabase/functions/admin-users/index.ts)
async function mockAdminUsers(req, res, origin) {
  if (req.method !== 'POST') return json(res, 405, { ok: false, code: 'method_not_allowed', message: 'Vain POST' });
  const claims = verifyJwt(req.headers.authorization);
  if (!claims || claims.role !== 'authenticated') return json(res, 401, { ok: false, code: 'unauthorized', message: 'Istunto ei kelpaa' });
  const caller = req.headers.authorization.slice(7);
  const adm = await pgrst('is_admin', {}, caller);
  if (adm.error) return json(res, 500, { ok: false, code: 'internal', message: 'Palvelinvirhe' });
  if (adm.data !== true) return json(res, 403, { ok: false, code: 'forbidden', message: 'Vain admin voi hallita käyttäjiä' });
  let raw = null; try { raw = JSON.parse((await readBody(req)) || 'null'); } catch {}
  const v = validateRequest(raw);
  if (!v.ok) return json(res, v.status, { ok: false, code: v.code, message: v.message });
  const svc = jwt('00000000-0000-4000-8000-000000000000', null, 'service_role');
  const fail = (e) => { const m = mapDbError(e); return json(res, m.status, { ok: false, code: m.code, message: m.message }); };
  if (v.action === 'invite') {
    const f = await pgrst('svc_find_auth_user', { p_email: v.email }, svc); if (f.error) return fail(f.error);
    let id = f.data, created = false;
    if (!id) { id = await mockInviteUser(v.email); created = true; }
    const u = await pgrst('svc_staff_upsert', { p_actor: claims.sub, p_user_id: id, p_name: v.name, p_role: v.role }, svc); if (u.error) return fail(u.error);
    USERS[v.email] = id;
    const body = { ok: true, user_id: id, invited: created, existing_user: !created };
    if (created) body.dev_invite_link = `${origin}/admin/#access_token=${jwt(id, v.email)}&refresh_token=${id}&expires_in=3600&type=invite`;
    return json(res, 200, body);
  }
  const active = v.action === 'reactivate';
  const r = await pgrst('svc_staff_set_active', { p_actor: claims.sub, p_user_id: v.user_id, p_active: active }, svc); if (r.error) return fail(r.error);
  if (active) BANNED.delete(v.user_id); else BANNED.add(v.user_id);
  return json(res, 200, { ok: true, user_id: v.user_id, active });
}
const json = (res, code, o) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
const readBuf = (req, max) => new Promise((ok, no) => { const c = []; let n = 0; req.on('data', (d) => { n += d.length; if (n > max) { no(Object.assign(new Error('too large'), { status: 413 })); req.destroy(); } else c.push(d); }); req.on('end', () => ok(Buffer.concat(c))); req.on('error', no); });
const readBody = (req) => new Promise((ok) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => ok(Buffer.concat(c).toString())); });

// URL → tiedosto. /admin/* → booking/admin, /booking/sb.js ja /admin/sb.js → shared/sb.js, muuten kaupan dist.
function resolveFile(p) {
  if (p === '/admin') return null;
  if (p === '/admin/sb.js' || p === '/booking/sb.js') return join(booking, 'shared/sb.js');
  if (p === '/admin/config.js') return join(SHOP, 'booking/config.js');
  if (p.startsWith('/admin/')) return join(booking, 'admin', p.slice(7) || 'index.html');
  return join(SHOP, p);
}
// MOCK Supabase Storage (vain demossa): bucket product-images. Lataukset ~/tmp/booking-demo-storage, demokuvat booking/dev/demo-images.
// Sama sääntö kuin migraatiossa 14: kirjoitus vaatii oikeuden catalog.edit, polku products/<id>-<tunnus>.<jpg|png|webp>, max 2 MB, vain jpeg/png/webp.
const STORE = join(tmpdir(), 'booking-demo-storage'), DEMO_IMG = join(booking, 'dev/demo-images');
const IMG_RE = /^products\/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$/, IMG_MIME = { jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp' };
async function mockStorage(req, res, path) {
  const pub = path.startsWith('/storage/v1/object/public/product-images/');
  const obj = decodeURIComponent(path.replace(/^\/storage\/v1\/object\/(public\/)?product-images\//, ''));
  if (!IMG_RE.test(obj)) return json(res, 400, { message: 'invalid path' });
  const ext = obj.split('.').pop();
  if (pub && (req.method === 'GET' || req.method === 'HEAD')) {
    for (const dir of [STORE, DEMO_IMG]) {
      try { const buf = await readFile(join(dir, obj)); res.writeHead(200, { 'content-type': IMG_MIME[ext], 'cache-control': 'no-store' }); return res.end(buf); } catch {}
    }
    return json(res, 404, { message: 'Object not found' });
  }
  if (pub || !['POST', 'PUT', 'DELETE'].includes(req.method)) return json(res, 405, { message: 'method not allowed' });
  const claims = verifyJwt(req.headers.authorization);
  if (!claims || claims.role !== 'authenticated') return json(res, 401, { message: 'Unauthorized' });
  const perm = await pgrst('has_permission', { p_permission: 'catalog.edit' }, req.headers.authorization.slice(7));
  if (perm.error || perm.data !== true) return json(res, 403, { message: 'new row violates row-level security policy' });
  if (req.method === 'DELETE') { await unlink(join(STORE, obj)).catch(() => {}); return json(res, 200, { message: 'Successfully deleted' }); }
  const type = (req.headers['content-type'] || '').split(';')[0];
  if (!Object.values(IMG_MIME).includes(type)) return json(res, 415, { message: 'mime type not supported' });
  let buf; try { buf = await readBuf(req, 2 * 1048576); } catch (e) { return json(res, e.status || 400, { message: 'The object exceeded the maximum allowed size' }); }
  const f = join(STORE, obj);
  if (req.method === 'POST' && await stat(f).then(() => true, () => false)) return json(res, 409, { message: 'The resource already exists' });
  await mkdir(dirname(f), { recursive: true }); await writeFile(f, buf);
  return json(res, 200, { Key: `product-images/${obj}`, Id: obj });
}
createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const path = url.pathname;
  if (path.startsWith('/storage/v1/object/')) return mockStorage(req, res, path).catch((e) => { console.error('mock storage', e.message); json(res, 500, { message: 'Palvelinvirhe' }); });
  if (path === '/admin') { res.writeHead(301, { location: '/admin/' }); return res.end(); }
  if (path === '/auth/v1/token' && req.method === 'POST') {
    const body = JSON.parse((await readBody(req)) || '{}'); const g = url.searchParams.get('grant_type');
    let email = body.email;
    if (g === 'refresh_token') email = Object.keys(USERS).find((e) => USERS[e] === body.refresh_token);
    if (!USERS[email] || BANNED.has(USERS[email]) || (g === 'password' && body.password !== (PASSWORDS[email] || 'demo'))) return json(res, 400, { error: 'invalid_grant', error_description: 'Väärä sähköposti tai salasana (demo: salasana "demo")' });
    return json(res, 200, { access_token: jwt(USERS[email], email), refresh_token: USERS[email], expires_in: 3600, user: { id: USERS[email], email } });
  }
  if (path === '/auth/v1/user' && req.method === 'PUT') {    // kutsun hyväksyntä: salasanan asetus
    const c = verifyJwt(req.headers.authorization); if (!c) return json(res, 401, { msg: 'Istunto ei kelpaa' });
    const pw = JSON.parse((await readBody(req)) || '{}').password;
    if (typeof pw !== 'string' || pw.length < 8) return json(res, 422, { msg: 'Salasanan pitää olla vähintään 8 merkkiä' });
    PASSWORDS[c.email] = pw; return json(res, 200, { id: c.sub, email: c.email });
  }
  if (path === '/functions/v1/admin-users') {
    const origin = `http://${req.headers.host}`;
    if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
    return mockAdminUsers(req, res, origin).catch((e) => { console.error('mock admin-users', e.message); json(res, 500, { ok: false, code: 'internal', message: 'Palvelinvirhe' }); });
  }
  if (path.startsWith('/rest/v1/')) {            // → PostgREST (poistetaan /rest/v1-etuliite, lisätään x-forwarded-for)
    const headers = { ...req.headers, host: `127.0.0.1:${PGRST}`, 'x-forwarded-for': req.socket.remoteAddress };
    if (req.headers['x-test-ip']) headers['x-forwarded-for'] = req.headers['x-test-ip'];
    const rpcName = req.method === 'POST' && /^\/rest\/v1\/rpc\/([a-z_]+)$/.exec(path)?.[1];
    // MOCK hoito- ja rituaalivaraukset (ks. treatment-mock.mjs): vain demossa, pois päältä TREATMENT_MOCK=0. Ei mockattu → oikea PostgREST samalla pyynnön rungolla.
    if (rpcName && process.env.TREATMENT_MOCK !== '0' && (rpcName.includes('treatment') || ['public_get_booking', 'public_product_images', 'public_catalog'].includes(rpcName))) {
      const raw = await readBody(req); let args = {}; try { args = JSON.parse(raw || '{}'); } catch {}
      const m = ['public_product_images', 'public_catalog'].includes(rpcName) ? null : treatmentRpc(rpcName, args);
      if (m) return json(res, m.status, m.body);
      delete headers['content-length'];
      const up = httpRequest({ host: '127.0.0.1', port: PGRST, path: req.url.replace('/rest/v1', ''), method: 'POST', headers: { ...headers, 'content-length': Buffer.byteLength(raw) } }, async (r) => {
        if (!['public_product_images', 'public_catalog'].includes(rpcName)) { res.writeHead(r.statusCode, r.headers); return r.pipe(res); }
        const c = []; for await (const d of r) c.push(d);
        let rows = []; try { rows = JSON.parse(Buffer.concat(c).toString() || '[]'); } catch {}
        if (rpcName === 'public_catalog') return json(res, 200, [...(Array.isArray(rows) ? rows : []), ...catalogEntries()]);   // MOCK: hoitotuotteet "verkossa" (liput päällä)
        const have = new Set(rows.map((x) => +x.product_id));
        for (const [id, path] of TREATMENT_IMAGES) if (!have.has(id)) rows.push({ product_id: id, slug: `treatment-${id}`, path, alt: '' });
        json(res, 200, rows);
      });
      up.on('error', () => json(res, 502, { message: 'PostgREST ei vastaa' }));
      return up.end(raw);
    }
    const up = httpRequest({ host: '127.0.0.1', port: PGRST, path: req.url.replace('/rest/v1', '') || '/', method: req.method, headers }, (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
    up.on('error', () => json(res, 502, { message: 'PostgREST ei vastaa' }));
    return req.pipe(up);
  }
  let file = resolveFile(normalize(decodeURIComponent(path)).replace(/^(\.\.[/\\])+/, ''));
  try { if ((await stat(file)).isDirectory()) file = join(file, 'index.html'); } catch {}
  try {
    const buf = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(buf);
  } catch {
    res.writeHead(404, { 'content-type': 'text/html; charset=utf-8' }); res.end('Not found');
  }
}).listen(PORT, () => console.log(`kehityspalvelin http://localhost:${PORT}/  (hallinta /admin/, PostgREST :${PGRST})`));
