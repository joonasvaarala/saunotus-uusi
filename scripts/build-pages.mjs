// GitHub Pages -julkaisun koonti yhteen artifactiin (dist/):
//   /               perussivusto (FI/EN), Johku-linkit korvattu sisäisellä varauskaupalla (booking/shop/build.mjs)
//   /varaa/  /en/…  varauskauppa (kauppa-build tuottaa sivut ja /booking/-tiedostot)
//   /hallinta/      hallinta-SPA (booking/admin + booking/shared/sb.js), config.js generoidaan tässä
// Käyttö:  SITE_ENV=test SITE_URL=https://joonasvaarala.github.io/saunotus-uusi \
//          BOOKING_SUPABASE_URL=https://<ref>.supabase.co BOOKING_ANON_KEY=<publishable/anon> node scripts/build-pages.mjs
// Julkaistaan vain julkinen anon/publishable-avain. Skripti kieltäytyy service_role/sb_secret-avaimista.
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const need = (k) => { const v = (process.env[k] || '').trim(); if (!v) { console.error(`build-pages: ympäristömuuttuja ${k} puuttuu`); process.exit(2); } return v; };
const SITE_URL = need('SITE_URL').replace(/\/$/, '');
const SUPA = need('BOOKING_SUPABASE_URL').replace(/\/$/, '');
const KEY = need('BOOKING_ANON_KEY');
const OUT = resolve(process.env.DIST || 'dist');
process.env.SITE_ENV ||= 'test';
const BASE = new URL(SITE_URL).pathname.replace(/\/$/, '');

// --- avaimen turvatarkistus (ei tulosteta avainta) ---
function assertPublicKey(k) {
  if (/^sb_secret_/.test(k)) throw new Error('BOOKING_ANON_KEY on sb_secret-avain: vain julkinen avain sallitaan');
  if (k.split('.').length === 3) {
    let role; try { role = JSON.parse(Buffer.from(k.split('.')[1], 'base64url').toString()).role; } catch { throw new Error('BOOKING_ANON_KEY: JWT ei ole luettavissa'); }
    if (role !== 'anon') throw new Error(`BOOKING_ANON_KEY: JWT:n rooli on "${role}", sallittu vain "anon"`);
  } else if (!/^sb_publishable_/.test(k)) throw new Error('BOOKING_ANON_KEY: tuntematon avaintyyppi (odotetaan sb_publishable_… tai anon-JWT)');
}
assertPublicKey(KEY);
if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(SUPA) && !/^http:\/\/localhost(:\d+)?$/.test(SUPA)) throw new Error('BOOKING_SUPABASE_URL: odotetaan https://<ref>.supabase.co');

// 1) perussivusto + varauskauppa (kauppa-build rakentaa koko sivuston ja /booking/-tiedostot)
execFileSync('node', ['booking/shop/build.mjs'], { env: { ...process.env, SHOP_DIST: OUT, SITE_URL, BOOKING_SUPABASE_URL: SUPA, BOOKING_ANON_KEY: KEY }, stdio: 'inherit' });
// 2) linkki- ja resurssitarkistus ennen hallinnan lisäämistä (hallinta ei ole sivuston generaattorin sivu)
execFileSync('node', ['scripts/check.mjs'], { env: { ...process.env, DIST: OUT }, stdio: 'inherit' });

// 3) hallinta → /hallinta/
const A = join(OUT, 'hallinta');
rmSync(A, { recursive: true, force: true });
mkdirSync(A, { recursive: true });
cpSync('booking/admin', A, { recursive: true, filter: (s) => !/config\.example\.js$/.test(s) });
cpSync('booking/shared/sb.js', join(A, 'sb.js'));
const cfg = { url: SUPA, anonKey: KEY, rest: '/rest/v1', auth: '/auth/v1', functions: '/functions/v1', schema: 'booking' };
writeFileSync(join(A, 'config.js'), `// Generoitu julkaisussa (scripts/build-pages.mjs). Vain julkinen anon/publishable-avain; service_role ei koskaan tähän.\nwindow.BOOKING_CONFIG=${JSON.stringify(cfg, null, 2)};\n`);

// 4) varmistukset
const fail = (m) => { console.error('build-pages: VIRHE: ' + m); process.exit(1); };
const adminHtml = readFileSync(join(A, 'index.html'), 'utf8');
if (!/<meta name="robots" content="noindex/.test(adminHtml)) fail('hallinnan index.html:stä puuttuu noindex');
for (const f of ['admin.js', 'ui.js', 'sb.js', 'config.js', 'admin.css', 'calendar.css', 'views/users.js', 'views/calendar.js']) if (!statSync(join(A, f), { throwIfNoEntry: false })) fail(`hallinnasta puuttuu ${f}`);
if (process.env.SITE_ENV === 'test') {
  const noindex = (p) => /<meta name="robots" content="noindex/.test(readFileSync(p, 'utf8'));
  for (const p of ['index.html', 'en/index.html', 'varaa/index.html', 'hallinta/index.html']) { try { if (!noindex(join(OUT, p))) fail(`${p}: noindex puuttuu (SITE_ENV=test)`); } catch (e) { if (e.code === 'ENOENT') fail(`${p} puuttuu dististä`); else throw e; } }
  if (!/Disallow: \//.test(readFileSync(join(OUT, 'robots.txt'), 'utf8'))) fail('robots.txt ei estä indeksointia');
}
// ei salaisuuksia: service_role/sb_secret ei saa esiintyä missään julkaistavassa tiedostossa (config.js, js, html)
(function scan(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) { scan(p); continue; } if (!/\.(js|mjs|html|json|css|txt)$/.test(n)) continue; const t = readFileSync(p, 'utf8'); if (/sb_secret_|"role"\s*:\s*"service_role"/.test(t)) fail(`salaisuuden näköinen sisältö: ${p.slice(OUT.length)}`); } })(OUT);
console.log(`build-pages ok → ${OUT}  (perussivusto, ${BASE || ''}/varaa/, ${BASE || ''}/hallinta/; Supabase ${new URL(SUPA).hostname})`);
