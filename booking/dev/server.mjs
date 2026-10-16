// Paikallinen kehityspalvelin: staattiset tiedostot (kauppa + hallinta) + PostgREST-proxy + MOCK-kirjautuminen (korvaa Supabase Authin demossa).
//   node booking/dev/server.mjs            → http://localhost:4180/  (kauppa),  /admin/  (hallinta)
// EI tuotantoon: mock-auth hyväksyy kovakoodatut demo-tunnukset ja allekirjoittaa JWT:n demon salaisuudella.
import { createServer, request as httpRequest } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { createHmac } from 'node:crypto';
import { join, extname, normalize, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const booking = resolve(here, '..');
const PORT = +(process.env.PORT || 4180), PGRST = +(process.env.PGRST_PORT || 3300);
const SECRET = process.env.JWT_SECRET || 'demo-secret-demo-secret-demo-secret-0123456789';
const SHOP = resolve(process.env.SHOP_DIST || join(booking, 'shop/dist'));
const USERS = { 'admin@demo.local': '00000000-0000-4000-8000-0000000000a1', 'staff@demo.local': '00000000-0000-4000-8000-0000000000b2', 'manager@demo.local': '00000000-0000-4000-8000-0000000000c3' };
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.avif': 'image/avif', '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2', '.xml': 'application/xml', '.txt': 'text/plain; charset=utf-8' };

const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
function jwt(sub, email) {
  const head = b64({ alg: 'HS256', typ: 'JWT' }), body = b64({ sub, email, role: 'authenticated', aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 });
  return `${head}.${body}.${createHmac('sha256', SECRET).update(`${head}.${body}`).digest('base64url')}`;
}
const json = (res, code, o) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
const readBody = (req) => new Promise((ok) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => ok(Buffer.concat(c).toString())); });

// URL → tiedosto. /admin/* → booking/admin, /booking/sb.js ja /admin/sb.js → shared/sb.js, muuten kaupan dist.
function resolveFile(p) {
  if (p === '/admin') return null;
  if (p === '/admin/sb.js' || p === '/booking/sb.js') return join(booking, 'shared/sb.js');
  if (p === '/admin/config.js') return join(SHOP, 'booking/config.js');
  if (p.startsWith('/admin/')) return join(booking, 'admin', p.slice(7) || 'index.html');
  return join(SHOP, p);
}
createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const path = url.pathname;
  if (path === '/admin') { res.writeHead(301, { location: '/admin/' }); return res.end(); }
  if (path === '/auth/v1/token' && req.method === 'POST') {
    const body = JSON.parse((await readBody(req)) || '{}'); const g = url.searchParams.get('grant_type');
    let email = body.email;
    if (g === 'refresh_token') email = Object.keys(USERS).find((e) => USERS[e] === body.refresh_token);
    if (!USERS[email] || (g === 'password' && body.password !== 'demo')) return json(res, 400, { error: 'invalid_grant', error_description: 'Väärä sähköposti tai salasana (demo: salasana "demo")' });
    return json(res, 200, { access_token: jwt(USERS[email], email), refresh_token: USERS[email], expires_in: 3600, user: { id: USERS[email], email } });
  }
  if (path.startsWith('/rest/v1/')) {            // → PostgREST (poistetaan /rest/v1-etuliite, lisätään x-forwarded-for)
    const headers = { ...req.headers, host: `127.0.0.1:${PGRST}`, 'x-forwarded-for': req.socket.remoteAddress };
    if (req.headers['x-test-ip']) headers['x-forwarded-for'] = req.headers['x-test-ip'];
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
