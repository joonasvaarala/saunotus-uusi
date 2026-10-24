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
// options-mock.js (admin.js tuo sen staattisesti) tuo '../shop/src/invoice-validate.js' → /shop/src/invoice-validate.js; ilman tätä koko hallinta-SPA:n moduulipuu kaatuu 404:ään (tyhjä sivu).
mkdirSync(join(OUT, 'shop', 'src'), { recursive: true });
cpSync('booking/shop/src/invoice-validate.js', join(OUT, 'shop', 'src', 'invoice-validate.js'));
cpSync('booking/shop/src/phone.js', join(OUT, 'shop', 'src', 'phone.js'));
const cfg = { url: SUPA, anonKey: KEY, rest: '/rest/v1', auth: '/auth/v1', functions: '/functions/v1', schema: 'booking' };
writeFileSync(join(A, 'config.js'), `// Generoitu julkaisussa (scripts/build-pages.mjs). Vain julkinen anon/publishable-avain; service_role ei koskaan tähän.\nwindow.BOOKING_CONFIG=${JSON.stringify(cfg, null, 2)};\n`);

// 3b) versiotunnus kaikkiin hallinnan moduuleihin ja resursseihin (välimuistin sekoittumisen esto; GitHub Pages välimuistittaa tiedostoja ~10 min)
//     Kaikki importit saavat SAMAN tunnuksen, jotta jokaisesta moduulista (esim. sb.js: istunto) on vain yksi instanssi.
const VER = '?v=' + ((process.env.GITHUB_SHA || '').slice(0, 10) || Date.now().toString(36));
let nImports = 0;
(function ver(d) {
  for (const n of readdirSync(d)) {
    const p = join(d, n);
    if (statSync(p).isDirectory()) { ver(p); continue; }
    if (!n.endsWith('.js') || n === 'config.js') continue;
    let t = readFileSync(p, 'utf8');
    t = t.replace(/(\b(?:from|import)\s*)(['"])(\.{1,2}\/[^'"?]+\.js)\2/g, (_, a, q, u) => { nImports++; return `${a}${q}${u}${VER}${q}`; });
    if (n === 'admin.js') { if (!t.includes("const ASSET_VER = '';")) { console.error('build-pages: VIRHE: admin.js:stä puuttuu ASSET_VER-rivi'); process.exit(1); } t = t.replace("const ASSET_VER = '';", `const ASSET_VER = '${VER}';`); }
    writeFileSync(p, t);
  }
})(A);
{
  const hp = join(A, 'index.html');
  let t = readFileSync(hp, 'utf8');
  t = t.replace(/((?:href|src)=")(admin\.css|calendar\.css|config\.js|admin\.js)(")/g, `$1$2${VER}$3`);
  writeFileSync(hp, t);
}

// 3c) kylmälaite-sivu → /juomat/ ja /en/drinks/ (polut ovat koodissa, eivät site.jsonissa)
const DRINK_JS = ['drinks.js', 'drinks-texts.js', 'drinks-logic.js', 'drinks-mock.js', 'phone-fi.js', 'qrsvg.js'];
function publishDrinks(srcName, destRel) {
  const dir = join(OUT, destRel);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  for (const f of [...DRINK_JS, 'drinks.css', 'qrcode-generator.js']) cpSync(join('booking/drinks', f), join(dir, f));
  for (const f of DRINK_JS) {
    const p = join(dir, f);
    let t = readFileSync(p, 'utf8');
    t = t.replace(/(\b(?:from|import)\s*)(['"])(\.{1,2}\/[^'"?]+\.js)\2/g, (_, a, q, u) => `${a}${q}${u}${VER}${q}`);
    writeFileSync(p, t);
  }
  let html = readFileSync(join('booking/drinks', srcName), 'utf8');
  if (BASE) html = html.replace(/href="(\/(?:juomat|en\/drinks)\/)"/g, `href="${BASE}$1"`);
  html = html.replace(/(href|src)="(\.\/[^"?]+\.(?:css|js))"/g, `$1="$2${VER}"`);
  if (process.env.SITE_ENV === 'test' && !/noindex/.test(html)) html = html.replace('<head>', '<head>\n<meta name="robots" content="noindex, nofollow">');
  writeFileSync(join(dir, 'index.html'), html);
  writeFileSync(join(dir, 'config.js'), `// Generoitu julkaisussa (scripts/build-pages.mjs). Vain julkinen anon/publishable-avain; service_role ei koskaan tähän.\nwindow.BOOKING_CONFIG=${JSON.stringify(cfg, null, 2)};\n`);
}
publishDrinks('index.html', 'juomat');
publishDrinks('index.en.html', 'en/drinks');

// 3d) vuorotarjouksen vastaussivu → /vuoro/ (poletti on kyselyssä; ei sivustogeneraattorin linkkiä)
const V = join(OUT, 'vuoro');
rmSync(V, { recursive: true, force: true });
mkdirSync(V, { recursive: true });
for (const f of ['index.html', 'vuoro.css', 'vuoro.js']) cpSync(join('booking/vuoro', f), join(V, f));

// 4) varmistukset
const fail = (m) => { console.error('build-pages: VIRHE: ' + m); process.exit(1); };
const adminHtml = readFileSync(join(A, 'index.html'), 'utf8');
if (!/<meta name="robots" content="noindex/.test(adminHtml)) fail('hallinnan index.html:stä puuttuu noindex');
if (!nImports || (adminHtml.match(/\?v=/g) || []).length !== 4) fail('hallinnan versiotunnus ei tullut kaikkiin resursseihin');
(function chk(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) { chk(p); continue; } if (n.endsWith('.js') && /(?:from|import)\s*['"]\.{1,2}\/[^'"?]+\.js['"]/.test(readFileSync(p, 'utf8'))) fail(`${p}: versioimaton relatiivinen import`); } })(A);
for (const f of ['admin.js', 'ui.js', 'icons.js', 'sb.js', 'config.js', 'admin.css', 'calendar.css', 'views/users.js', 'views/calendar.js', 'views/customerform.js', 'views/addons.js', 'views/productimage.js', 'views/talous.js', 'views/talous-orders.js', 'views/talous-payments.js', 'views/talous-reports.js', 'views/talous-ui.js', 'views/talous-receipts.js', 'views/talous-giftcards.js', 'views/pos.js', 'pos-screen.js', 'pos-logic.js', 'pos-texts.js', 'phone-fi.js', 'qrsvg.js', 'qrcode-generator.js', 'settings-tabs.js', 'settings-texts.js', 'qr-print.js', 'qr-panel.js', 'options.js', 'options-logic.js', 'options-mock.js', 'talous-api.js', 'talous-mock.js', 'giftcards-api.js', 'giftcards-mock.js', 'giftcards-texts.js', 'talous-i18n.js', 'talous-texts.js', 'csv.js', 'day-texts.js', 'filter-texts.js', 'nav-texts.js', 'admin-navigation.js', 'quick-search.js', 'views/orders.js', 'day-bundle-cache.js', 'site-texts-cache.js', 'views/day.js', 'logo-haalea.svg']) if (!statSync(join(A, f), { throwIfNoEntry: false })) fail(`hallinnasta puuttuu ${f}`);
(function chkImports(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) { chkImports(p); continue; } if (!n.endsWith('.js')) continue; for (const m of readFileSync(p, 'utf8').matchAll(/(?:from|import)\s*\(?\s*(['"])(\.{1,2}\/[^'"?]+\.js)(?:\?[^'"]*)?\1/g)) { if (!statSync(resolve(d, m[2]), { throwIfNoEntry: false })) fail(`${p}: tuotu moduuli puuttuu dististä: ${m[2]}`); } } })(A);
if (process.env.SITE_ENV === 'test') {
  const noindex = (p) => /<meta name="robots" content="noindex/.test(readFileSync(p, 'utf8'));
  for (const p of ['index.html', 'en/index.html', 'varaa/index.html', 'tilaus/index.html', 'en/order/index.html', 'hallinta/index.html', 'juomat/index.html', 'en/drinks/index.html', 'vuoro/index.html']) { try { if (!noindex(join(OUT, p))) fail(`${p}: noindex puuttuu (SITE_ENV=test)`); } catch (e) { if (e.code === 'ENOENT') fail(`${p} puuttuu dististä`); else throw e; } }
  if (!/Disallow: \//.test(readFileSync(join(OUT, 'robots.txt'), 'utf8'))) fail('robots.txt ei estä indeksointia');
}
// ei salaisuuksia: service_role/sb_secret ei saa esiintyä missään julkaistavassa tiedostossa (config.js, js, html)
(function scan(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) { scan(p); continue; } if (!/\.(js|mjs|html|json|css|txt)$/.test(n)) continue; const t = readFileSync(p, 'utf8'); if (/sb_secret_|"role"\s*:\s*"service_role"/.test(t)) fail(`salaisuuden näköinen sisältö: ${p.slice(OUT.length)}`); } })(OUT);
if (!statSync(join(OUT, 'img', 'ovi-kaiverrus-1024.webp'), { throwIfNoEntry: false })) fail('oven kuva puuttuu: img/ovi-kaiverrus-1024.webp');
const vuoroHtml = readFileSync(join(OUT, 'vuoro', 'index.html'), 'utf8');
if (!/src="\.\.\/img\/ovi-kaiverrus-1024\.webp"/.test(vuoroHtml)) fail('vuoro-sivun oven kuvan polku ei ole suhteellinen');
console.log(`build-pages ok → ${OUT}  (perussivusto, ${BASE || ''}/varaa/, ${BASE || ''}/hallinta/, ${BASE || ''}/juomat/, ${BASE || ''}/vuoro/; Supabase ${new URL(SUPA).hostname})`);
