// Rakentaa varauskaupan: kopio uudesta sivustosta (src/render.mjs + src/styles.css käytössä sellaisenaan), jossa Johku-linkit
// avaavat sisäisen varauskalenterin. Ei muuta sivuston tiedostoja. Käyttö (repon juuresta):
//   node booking/shop/build.mjs            → booking/shop/dist/
// Ympäristömuuttujat:
//   SITE_URL                 julkinen osoite polkuetuliitteineen (oletus http://localhost:4180)
//   BOOKING_SUPABASE_URL     Supabase-projektin URL (oletus http://localhost:4181 = paikallinen demo)
//   BOOKING_ANON_KEY         anon/publishable-avain (EI service role!)
//   BOOKING_REST / BOOKING_AUTH  polut (oletus /rest/v1 ja /auth/v1; paikallinen PostgREST-demo käyttää tyhjää REST-polkua)
//   BOOKING_SCHEMA           oletus booking
import { readFileSync, writeFileSync, mkdirSync, cpSync, readdirSync, statSync, rmSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
process.chdir(repo);
const OUT = resolve(process.env.SHOP_DIST || join(here, 'dist'));
process.env.SITE_ENV ||= 'test';
process.env.SITE_URL ||= 'http://localhost:4180';

// 1) rakenna perussivusto omaan hakemistoonsa (alkuperäistä dist/-hakemistoa ei kosketa)
rmSync(OUT, { recursive: true, force: true });
execFileSync('node', ['scripts/build.mjs'], { env: { ...process.env, DIST: OUT }, stdio: 'inherit' });

const L = await import(resolve(repo, 'src/lib.mjs'));
const R = await import(resolve(repo, 'src/render.mjs'));
const { site, kb, BASE, e } = L;

// 2) varausohjelman tiedostot
const A = join(OUT, 'booking');
mkdirSync(A, { recursive: true });
for (const f of ['shop.js', 'i18n.js', 'shop.css']) cpSync(join(here, 'src', f), join(A, f));
cpSync(join(repo, 'booking/shared/sb.js'), join(A, 'sb.js'));
const cfg = {
  url: process.env.BOOKING_SUPABASE_URL ?? 'http://localhost:4181', anonKey: process.env.BOOKING_ANON_KEY ?? 'anon-demo-key',
  rest: process.env.BOOKING_REST ?? '/rest/v1', auth: process.env.BOOKING_AUTH ?? '/auth/v1', schema: process.env.BOOKING_SCHEMA || 'booking',
};
writeFileSync(join(A, 'config.js'), `// Muokkaa tätä tiedostoa julkaisussa (ei vaadi uudelleenrakennusta). anon-avain saa olla julkinen.\nwindow.BOOKING_CONFIG=${JSON.stringify(cfg, null, 2)};\n`);
writeFileSync(join(A, 'static-products.json'), JSON.stringify(Object.fromEntries(kb.products.map((p) => [p.slug, { name: p.name, description: p.description }]))));

// 3) varaussivut (FI/EN) + vahvistussivut: sivuston oma layout
const PATHS = { fi: { shop: site.pages.book.fi, confirm: site.pages.book.fi + 'vahvistus/' }, en: { shop: site.pages.book.en, confirm: site.pages.book.en + 'confirmation/' } };
const write = (urlPath, html) => { const f = join(OUT, urlPath, 'index.html'); mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, html); };
const T = {
  fi: { title: 'Varaa saunaelämys', text: 'Valitse kokemus, päivä ja vuoro – varaus vahvistetaan heti.', meta: 'Varaa saunavuoro verkossa | Sipoonjoen Perinnesauna', desc: 'Varaa yleinen saunavuoro tai yksityisvuoro suoraan Sipoonjoen perinnesaunalle.', noscript: 'Varauskalenteri vaatii JavaScriptin. Varaa soittamalla', ctitle: 'Varausvahvistus' },
  en: { title: 'Book a sauna experience', text: 'Choose an experience, a day and a session – your booking is confirmed instantly.', meta: 'Book a sauna session online | Sipoonjoen Perinnesauna', desc: 'Book a public or private sauna session directly at Sipoonjoen Perinnesauna.', noscript: 'The booking calendar requires JavaScript. Please book by phone', ctitle: 'Booking confirmation' },
};
for (const lang of ['fi', 'en']) {
  for (const page of ['shop', 'confirm']) {
    const t = T[lang];
    const S = {
      lang, page: page === 'shop' ? 'shop' : 'confirm', shopHref: BASE + PATHS[lang].shop, confirmHref: BASE + PATHS[lang].confirm,
      termsHref: L.pageHref('terms', lang), infoHref: L.pageHref('info', lang), phone: site.contact.phone, phoneTel: site.contact.phoneTel, email: site.contact.email,
      staticProductsUrl: `${BASE}/booking/static-products.json`,
    };
    const body = R.pageHero({ title: page === 'shop' ? t.title : t.ctitle, text: page === 'shop' ? t.text : '', img: 'ovi-kaiverrus' }, lang, 'book')
      + `<section class="section"><div class="wrap"><div id="booking-app" aria-busy="true"><noscript><p>${e(t.noscript)}: <a href="tel:${site.contact.phoneTel}">${e(site.contact.phone)}</a></p></noscript></div></div></section>`
      + `<script src="${BASE}/booking/config.js"></script><script>window.BOOKING_SHOP=${JSON.stringify(S)}</script><script type="module" src="${BASE}/booking/shop.js"></script>`;
    let html = R.layout({ lang, key: 'book', meta: { title: page === 'shop' ? t.meta : `${t.ctitle} | Sipoonjoen Perinnesauna`, description: t.desc, og: 'ovi-kaiverrus' }, body });
    html = html.replace('</head>', `<link rel="stylesheet" href="${BASE}/booking/shop.css"></head>`);
    if (page === 'confirm') html = html.replace(/<link rel="canonical"[^>]*>(<link rel="alternate"[^>]*>)*/, '').replace('<meta name="description"', '<meta name="robots" content="noindex,nofollow"><meta name="description"');
    write(PATHS[lang][page === 'shop' ? 'shop' : 'confirm'], html);
  }
}

// 4) Johku-linkit → sisäinen varauskalenteri
const slugs = new Set(kb.products.map((p) => p.slug));
const JOHKU = /<a\b([^>]*?)href="https:\/\/sipoonjoenperinnesauna\.johku\.com\/[^/"]+\/([^"]*)"([^>]*)>([\s\S]*?)<\/a>/g;
const NOTE = /<span class="sr"> \((?:avautuu uuteen välilehteen|opens in a new tab)\)<\/span>/g;
const GIFT_KEEP = /^(yleinen-lahjakorttivaraus|sarja-ja-lahjakortit|yrityksille|info\/)/;   // ei vielä toteutettu uudessa järjestelmässä → jää Johkuun
function rewrite(html, lang) {
  const shop = BASE + PATHS[lang].shop;
  return html.replace(JOHKU, (m, a, path, b, inner) => {
    if (GIFT_KEEP.test(path)) return m;
    const parts = path.split('/');
    const slug = parts[parts.length - 1];
    let target;
    if (slugs.has(slug) && parts.length > 1) target = `${shop}#/tuote/${slug}`;
    else if (parts[0] === 'yleinen-sauna') target = `${shop}#/?k=yleinen`;
    else if (parts[0] === 'yksityisvuorot') target = `${shop}#/?k=yksityinen`;
    else target = `${shop}#/`;
    const attrs = (a + b).replace(/\s*target="_blank"/g, '').replace(/\s*rel="noopener"/g, '');
    return `<a${attrs ? ' ' + attrs.trim() : ''} href="${target}">${inner.replace(NOTE, '')}</a>`;
  });
}
let changed = 0;
(function walk(dir) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) { if (n !== 'booking') walk(p); continue; }
    if (!n.endsWith('.html')) continue;
    const rel = p.slice(OUT.length);
    const lang = rel.startsWith('/en/') ? 'en' : 'fi';
    const src = readFileSync(p, 'utf8'), out = rewrite(src, lang);
    if (out !== src) { writeFileSync(p, out); changed++; }
  }
})(OUT);
console.log(`shop build ok → ${OUT} (${changed} sivun Johku-linkit korvattu)`);
