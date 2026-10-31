// Julkaistavan sivuston koonti yhteen artifactiin (dist/):
//   /               perussivusto (FI/EN), Johku-linkit korvattu sisäisellä varauskaupalla (booking/shop/build.mjs)
//   /varaa/  /en/…  varauskauppa (kauppa-build tuottaa sivut ja /booking/-tiedostot)
//   /hallinta/      hallinta-SPA (booking/admin + booking/shared/sb.js), config.js generoidaan tässä
//   /vuoro/         vuorotarjouksen vastaussivu; config.js saa Supabase-osoitteen tästä buildista
// Käyttö:  npm run build:test    (config/env/test.env, GitHub Pages, Supabase DEV)
//          npm run build:prod    (config/env/prod.env, https://saunotus.fi, Supabase PROD)
// Julkaistaan vain julkinen anon/publishable-avain. Skripti kieltäytyy service_role/sb_secret-avaimista.
// SITE_ENV=prod vaatii tuotantoprojektin ja saunotus.fi:n. SITE_ENV=test kieltäytyy molemmista.
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { assertBuildTarget } from '../src/site-target.mjs';
import { imageTransformsOn } from '../booking/shop/src/product-image.js';
import { assertNoRenderImageUrls } from './check-image-urls.mjs';

const need = (k) => { const v = (process.env[k] || '').trim(); if (!v) { console.error(`build-pages: ympäristömuuttuja ${k} puuttuu`); process.exit(2); } return v; };
const SITE_URL = need('SITE_URL').replace(/\/$/, '');
const SUPA = need('BOOKING_SUPABASE_URL').replace(/\/$/, '');
const KEY = need('BOOKING_ANON_KEY');
const OUT = resolve(process.env.DIST || 'dist');
process.env.SITE_ENV ||= 'test';
try { assertBuildTarget({ siteEnv: process.env.SITE_ENV, siteUrl: SITE_URL, supabaseUrl: SUPA }); }
catch (err) { console.error('build-pages: ' + err.message); process.exit(2); }
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
cpSync('booking/shop/src/discount-code-logic.js', join(OUT, 'shop', 'src', 'discount-code-logic.js')); // booking_142: hallinnan alennuskoodit, asiakaskortti ja options-mock tuovat tämän
cpSync('booking/shop/src/discount-texts.js', join(OUT, 'shop', 'src', 'discount-texts.js')); // discount-code-logic.js tuo tämän
const cfg = { url: SUPA, anonKey: KEY, rest: '/rest/v1', auth: '/auth/v1', functions: '/functions/v1', schema: 'booking', payMarks: `${BASE}/img/pay/` };
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
    if (n === 'pwa.js') { if (!t.includes("const SW_VER = '';")) { console.error('build-pages: VIRHE: pwa.js:stä puuttuu SW_VER-rivi'); process.exit(1); } t = t.replace("const SW_VER = '';", `const SW_VER = '${VER}';`); }
    if (n === 'sw.js') { if (!t.includes("const CACHE = 'hallinta-__VER__';")) { console.error('build-pages: VIRHE: sw.js:stä puuttuu välimuistin versio'); process.exit(1); } t = t.replaceAll('hallinta-__VER__', 'hallinta-' + VER.slice(3)); }
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
// Juomasivu käyttää kaupan maksutapariviä. Kopioidaan moduuligraafi sivun viereen (dist/juomat ei näe booking/shop/src:tä).
const DRINK_PAY_UI = ['online-pay-ui.js', 'online-pay-logic.js', 'pay-choices-texts.js', 'gift-ui.js', 'gift-texts.js'];
function publishDrinks(srcName, destRel) {
  const dir = join(OUT, destRel);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  for (const f of [...DRINK_JS, 'drinks.css', 'qrcode-generator.js']) cpSync(join('booking/drinks', f), join(dir, f));
  for (const f of DRINK_PAY_UI) cpSync(join('booking/shop/src', f), join(dir, f));
  for (const f of [...DRINK_JS, ...DRINK_PAY_UI]) {
    const p = join(dir, f);
    let t = readFileSync(p, 'utf8');
    t = t.replace(/(\b(?:from|import)\s*)(['"])\.\.\/shop\/src\/([^'"?]+\.js)\2/g, (_, a, q, u) => `${a}${q}./${u}${q}`);
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
// booking_153: henkilökunnan oma sivu → /vuoro/oma/ (pysyvä henkilökohtainen linkki ?token=, noindex)
mkdirSync(join(V, 'oma'), { recursive: true });
for (const f of ['index.html', 'oma.css', 'oma.js']) cpSync(join('booking/vuoro/oma', f), join(V, 'oma', f));
const vuoroCfg = `// Generoitu julkaisussa (scripts/build-pages.mjs). Vuorosivu käyttää tämän buildin Supabase-osoitetta.\nwindow.BOOKING_CONFIG=${JSON.stringify({ url: SUPA })};\n`;
writeFileSync(join(V, 'config.js'), vuoroCfg);
writeFileSync(join(V, 'oma', 'config.js'), vuoroCfg);

// 3e) Paketti 11 / booking_144: evästeetön kävijämittaus. OLETUKSENA POIS.
//     Skripti lisätään sivuille VAIN, kun SITE_ANALYTICS=on JA SITE_ENV != test. Testisivulla (GitHub Pages, SITE_ENV=test) ei koskaan.
//     Ei mittaus-ID:itä eikä uusia avaimia: käyttää samaa julkista anon/publishable-avainta kuin kauppa. Ei hallintaan, /vuoro/-linkkeihin,
//     kylmälaitesivuille eikä vanhojen osoitteiden ohjaussivuille. Ennen päälle kytkemistä: tietosuojaseloste + suostumus-/oikeusperustepäätös.
const ANALYTICS_ON = process.env.SITE_ANALYTICS === 'on' && process.env.SITE_ENV !== 'test';
let nAnalytics = 0;
if (ANALYTICS_ON) {
  (function inject(d) {
    for (const n of readdirSync(d)) {
      const p = join(d, n);
      if (statSync(p).isDirectory()) { if (!['hallinta', 'vuoro', 'juomat', 'drinks', 'booking'].includes(n)) inject(p); continue; }
      if (n !== 'index.html') continue;
      const content = readFileSync(p, 'utf8');
      if (!content.includes('</head>') || content.includes('SAUNA_ANALYTICS_CONFIG') || /data-redirect="legacy"/.test(content)) continue;
      const setup = '<script>window.SAUNA_ANALYTICS_CONFIG=' + JSON.stringify({ enabled: true, url: SUPA, anonKey: KEY }) + '</script>'
        + '<script type="module" src="' + BASE + '/js/analytics.js' + VER + '"></script>';
      writeFileSync(p, content.replace('</head>', setup + '</head>'));
      nAnalytics++;
    }
  })(OUT);
}

// 4) varmistukset
const fail = (m) => { console.error('build-pages: VIRHE: ' + m); process.exit(1); };
const adminHtml = readFileSync(join(A, 'index.html'), 'utf8');
if (!/<meta name="robots" content="noindex/.test(adminHtml)) fail('hallinnan index.html:stä puuttuu noindex');
if (!nImports || (adminHtml.match(/\?v=/g) || []).length !== 4) fail('hallinnan versiotunnus ei tullut kaikkiin resursseihin');
if (!/rel="manifest" href="manifest\.json"/.test(adminHtml)) fail('hallinnan index.html:stä puuttuu manifesti');
if (!/name="apple-mobile-web-app-capable" content="yes"/.test(adminHtml)) fail('hallinnan index.html:stä puuttuu apple-mobile-web-app-capable');
if (!/name="apple-mobile-web-app-status-bar-style"/.test(adminHtml)) fail('hallinnan index.html:stä puuttuu apple-mobile-web-app-status-bar-style');
if (!/name="apple-mobile-web-app-title" content="Hallinta"/.test(adminHtml)) fail('hallinnan index.html:stä puuttuu apple-mobile-web-app-title');
if (!/rel="apple-touch-icon" href="apple-touch-icon\.png"/.test(adminHtml)) fail('hallinnan index.html:stä puuttuu apple-touch-icon');
{
  const swBuilt = readFileSync(join(A, 'sw.js'), 'utf8');
  if (swBuilt.includes('__VER__') || !swBuilt.includes(`const CACHE = 'hallinta-${VER.slice(3)}';`)) fail('sw.js välimuistin versio');
  const pwaBuilt = readFileSync(join(A, 'pwa.js'), 'utf8');
  if (!pwaBuilt.includes(`const SW_VER = '${VER}';`)) fail('pwa.js SW_VER');
  let manifest; try { manifest = JSON.parse(readFileSync(join(A, 'manifest.json'), 'utf8')); } catch { fail('manifest.json ei ole JSON'); }
  if (!manifest || manifest.scope !== './' || manifest.start_url !== './' || manifest.display !== 'standalone' || manifest.lang !== 'fi') fail('manifestin scope, start_url, display tai kieli');
  if (manifest.name !== 'Saunotus hallinta' || manifest.short_name !== 'Hallinta') fail('manifestin nimi');
}
(function chk(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) { chk(p); continue; } if (n.endsWith('.js') && /(?:from|import)\s*['"]\.{1,2}\/[^'"?]+\.js['"]/.test(readFileSync(p, 'utf8'))) fail(`${p}: versioimaton relatiivinen import`); } })(A);
for (const f of ['admin.js', 'ui.js', 'icons.js', 'sb.js', 'config.js', 'admin.css', 'calendar.css', 'views/users.js', 'views/calendar.js', 'views/customerform.js', 'views/addons.js', 'views/productimage.js', 'views/talous.js', 'views/talous-orders.js', 'voucher-redeem-logic.js', 'voucher-redeem-texts.js', 'voucher-redeem-mock.js', 'views/voucher-redeem.js', 'views/talous-payments.js', 'views/talous-reports.js', 'views/talous-analytics.js', 'analytics-mock.js', 'views/talous-ui.js', 'views/talous-receipts.js', 'views/talous-giftcards.js', 'views/pos.js', 'pos-screen.js', 'pos-logic.js', 'pos-texts.js', 'phone-fi.js', 'qrsvg.js', 'qrcode-generator.js', 'settings-tabs.js', 'settings-texts.js', 'qr-print.js', 'qr-panel.js', 'options.js', 'options-logic.js', 'options-mock.js', 'talous-api.js', 'talous-mock.js', 'giftcards-api.js', 'giftcards-mock.js', 'giftcards-texts.js', 'talous-i18n.js', 'talous-texts.js', 'csv.js', 'day-texts.js', 'refund-cancel-texts.js', 'views/refund-cancel.js', 'annual-card-texts.js', 'annual-card-logic.js', 'views/annual-card-panel.js', 'annual-manage-texts.js', 'filter-texts.js', 'nav-texts.js', 'admin-navigation.js', 'quick-search.js', 'views/orders.js', 'views/nav-group.js', 'day-bundle-cache.js', 'site-texts-cache.js', 'views/day.js', 'day-memos-texts.js', 'day-memos-logic.js', 'views/day-memos.js', 'views/events.js', 'events-logic.js', 'events-texts.js', 'events-mock.js', 'logo-haalea.svg', 'manifest.json', 'sw.js', 'offline.html', 'pwa.js', 'icon-192.png', 'icon-512.png', 'icon-maskable-512.png', 'apple-touch-icon.png', 'rich-editor.js', 'vendor/quill/quill.js', 'vendor/quill/quill.snow.css', 'vendor/quill/LICENSE']) if (!statSync(join(A, f), { throwIfNoEntry: false })) fail(`hallinnasta puuttuu ${f}`);
(function chkImports(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) { chkImports(p); continue; } if (!n.endsWith('.js')) continue; for (const m of readFileSync(p, 'utf8').matchAll(/(?:from|import)\s*\(?\s*(['"])(\.{1,2}\/[^'"?]+\.js)(?:\?[^'"]*)?\1/g)) { if (!statSync(resolve(d, m[2]), { throwIfNoEntry: false })) fail(`${p}: tuotu moduuli puuttuu dististä: ${m[2]}`); } } })(A);
if (process.env.SITE_ENV === 'test') {
  const noindex = (p) => /<meta name="robots" content="noindex/.test(readFileSync(p, 'utf8'));
  for (const p of ['index.html', 'en/index.html', 'varaa/index.html', 'tilaus/index.html', 'en/order/index.html', 'hallinta/index.html', 'juomat/index.html', 'en/drinks/index.html', 'vuoro/index.html']) { try { if (!noindex(join(OUT, p))) fail(`${p}: noindex puuttuu (SITE_ENV=test)`); } catch (e) { if (e.code === 'ENOENT') fail(`${p} puuttuu dististä`); else throw e; } }
  if (!/Disallow: \//.test(readFileSync(join(OUT, 'robots.txt'), 'utf8'))) fail('robots.txt ei estä indeksointia');
}
// Paketti 11: seuranta ei saa olla millään sivulla, ellei sitä ole erikseen kytketty päälle (SITE_ANALYTICS=on, ei testissä).
if (!ANALYTICS_ON) (function noTracking(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) { noTracking(p); continue; } if (n.endsWith('.html') && /SAUNA_ANALYTICS_CONFIG|js\/analytics\.js/.test(readFileSync(p, 'utf8'))) fail(`${p.slice(OUT.length)}: kävijämittaus mukana, vaikka se on pois päältä`); } })(OUT);
// ei salaisuuksia: service_role/sb_secret ei saa esiintyä missään julkaistavassa tiedostossa (config.js, js, html)
(function scan(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) { scan(p); continue; } if (!/\.(js|mjs|html|json|css|txt)$/.test(n)) continue; const t = readFileSync(p, 'utf8'); if (/sb_secret_|"role"\s*:\s*"service_role"/.test(t)) fail(`salaisuuden näköinen sisältö: ${p.slice(OUT.length)}`); } })(OUT);
if (!statSync(join(OUT, 'img', 'ovi-kaiverrus-1024.webp'), { throwIfNoEntry: false })) fail('oven kuva puuttuu: img/ovi-kaiverrus-1024.webp');
const vuoroHtml = readFileSync(join(OUT, 'vuoro', 'index.html'), 'utf8');
if (!/src="\.\.\/img\/ovi-kaiverrus-1024\.webp"/.test(vuoroHtml)) fail('vuoro-sivun oven kuvan polku ei ole suhteellinen');
if (!vuoroHtml.includes('src="./config.js"') || !readFileSync(join(OUT, 'vuoro', 'oma', 'index.html'), 'utf8').includes('src="./config.js"')) fail('vuoro-sivulta puuttuu config.js');
{
  const otherRef = process.env.SITE_ENV === 'prod' ? 'aoejjmfzulhkhxbehphs' : 'sxbofnuisemspgquoxyv';
  for (const rel of ['vuoro/config.js', 'vuoro/oma/config.js', 'vuoro/vuoro.js', 'vuoro/oma/oma.js', 'hallinta/config.js', 'index.html']) {
    const t = readFileSync(join(OUT, rel), 'utf8');
    if (t.includes(otherRef)) fail(`${rel} viittaa väärän ympäristön Supabase-projektiin`);
    if (rel.endsWith('config.js') && !t.includes(SUPA)) fail(`${rel} ei käytä julkaisun Supabase-osoitetta`);
  }
}
if (!imageTransformsOn()) assertNoRenderImageUrls(OUT);
console.log(`build-pages ok → ${OUT}  (kävijämittaus ${ANALYTICS_ON ? `PÄÄLLÄ ${nAnalytics} sivulla` : 'pois'}; perussivusto, ${BASE || ''}/varaa/, ${BASE || ''}/hallinta/, ${BASE || ''}/juomat/, ${BASE || ''}/vuoro/; Supabase ${new URL(SUPA).hostname})`);
