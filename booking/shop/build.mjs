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
const ST = await import(resolve(repo, 'src/site-texts.mjs'));
const R = await import(resolve(repo, 'src/render.mjs'));
const { pageDefault } = await import(resolve(here, 'src/shop-page-texts.js'));
const { site, kb, BASE, e } = L;
const JL = await import(resolve(here, 'src/johku-links.js'));

// 2) varausohjelman tiedostot
const A = join(OUT, 'booking');
mkdirSync(A, { recursive: true });
for (const f of ['shop.js', 'rich-text.js', 'rich-view.js', 'short-desc.js', 'invoice-validate.js', 'i18n.js', 'phone.js', 'shop.css', 'treatments.js', 'treatment-ui.js', 'order.js', 'order-texts.js', 'order-api.js', 'order-mock.js', 'order-gift.js', 'gift.js', 'gift-api.js', 'gift-logic.js', 'gift-mock.js', 'gift-texts.js', 'gift-ui.js', 'mobilepay-api.js', 'pay-choices.js', 'hold-texts.js', 'hold-logic.js', 'hold-ui.js', 'hold-mock.js', 'pay-choices-texts.js', 'mobilepay-logic.js', 'mobilepay-texts.js', 'mobilepay-ui.js', 'vismapay-api.js', 'vismapay-logic.js', 'vismapay-texts.js', 'vismapay-ui.js', 'options-logic.js', 'options-texts.js', 'options-ui.js', 'shop-mock.js', 'treatment-mock.js', 'treatment-addons.js', 'site-texts.js', 'site-texts-logic.js', 'text-registry.js', 'catalog-audience.js', 'waitlist-logic.js', 'waitlist-texts.js', 'waitlist-ui.js', 'availability-months.js', 'johku-links.js']) cpSync(join(here, 'src', f), join(A, f));
// Lisäksi kaikki muut src/*.js automaattisesti, ettei uusi moduuli jää julkaisusta pois (#121: waitlist-*.js puuttui → /varaa/ ei auennut).
for (const f of readdirSync(join(here, 'src'))) if (f.endsWith('.js')) cpSync(join(here, 'src', f), join(A, f));
cpSync(join(repo, 'booking/shared/sb.js'), join(A, 'sb.js'));
// Sivutekstit tietokannasta (§18, src/site-texts.mjs): kaupan avainalueet (ui.*) tiedostoon booking/site-texts.json; paikkamerkit täytetään kaupassa ajoajan datasta. Build on jo tarkistanut paikkamerkit (tuntematon → build kaatuu).
const siteTexts = await ST.loadSiteTexts();
ST.setSiteTexts(siteTexts);   // layout() hakee yläpalkin alarivin tx():llä
(await import(resolve(repo, 'src/content-texts.mjs'))).applyContentTexts(siteTexts, { log: { warn: () => {} } });   // varaus-/tilaussivujen kehys (valikko, alatunniste) käyttää samoja sivutekstejä kuin staattinen sivusto
writeFileSync(join(A, 'site-texts.json'), JSON.stringify(ST.shopPayload(siteTexts)));
const cfg = {
  url: process.env.BOOKING_SUPABASE_URL ?? 'http://localhost:4181', anonKey: process.env.BOOKING_ANON_KEY ?? 'anon-demo-key',
  rest: process.env.BOOKING_REST ?? '/rest/v1', auth: process.env.BOOKING_AUTH ?? '/auth/v1', schema: process.env.BOOKING_SCHEMA || 'booking',
  // Lahjakortin PDF-nappi tilaussivulla: päällä (edge function gift-card-pdf on tuotannossa, sopimus §13.9). BOOKING_GIFT_CARD_PDF=0 piilottaa; funktion nimi = toinen funktio. Muokattavissa julkaisussa tästä tiedostosta.
  // MobilePay (§14): testitilan tapa (public_payment_options methods[].test=true) näytetään vain kun true. Oletus: päällä vain SITE_ENV=test -julkaisussa (testisivusto); tuotannossa pois. BOOKING_MOBILEPAY_TEST_UI=1|0 ylikirjoittaa; muokattavissa julkaisussa. mobilepayOfficialButton=false → aina oma varapainike (ei ulkoista skriptiä).
  mobilepayTestUi: process.env.BOOKING_MOBILEPAY_TEST_UI ? /^(1|true)$/i.test(process.env.BOOKING_MOBILEPAY_TEST_UI) : process.env.SITE_ENV === 'test', mobilepayOfficialButton: !/^(0|false)$/i.test(process.env.BOOKING_MOBILEPAY_OFFICIAL_BUTTON || ''), siteEnv: process.env.SITE_ENV || '',
  giftCardPdf: /^(0|false)$/i.test(process.env.BOOKING_GIFT_CARD_PDF || '') ? false : (/^(1|true)?$/i.test(process.env.BOOKING_GIFT_CARD_PDF || '') ? true : process.env.BOOKING_GIFT_CARD_PDF),
};
writeFileSync(join(A, 'config.js'), `// Muokkaa tätä tiedostoa julkaisussa (ei vaadi uudelleenrakennusta). anon-avain saa olla julkinen.\nwindow.BOOKING_CONFIG=${JSON.stringify(cfg, null, 2)};\n`);
// Staattinen tuotedata: tuntemattoman tuotteen "ota yhteyttä" -sivu + hoitotuotteiden kortit (hinta, kesto, henkilömäärät; ks. treatments.js loadProducts)
const STATIC_KEYS = ['id', 'name', 'name_en', 'description', 'description_en', 'short_description', 'short_description_en', 'category', 'price', 'price_type', 'included_persons', 'extra_person_price', 'duration_minutes', 'duration_text', 'duration_text_en', 'capacity_min', 'capacity_max'];
// Johku-linkit kuvauksissa → kauppa (johku-links.js): FI-kentät FI-kauppaan, *_en EN-kauppaan
const PATHS = { fi: { shop: site.pages.book.fi, confirm: site.pages.book.fi + 'vahvistus/', order: '/tilaus/' }, en: { shop: site.pages.book.en, confirm: site.pages.book.en + 'confirmation/', order: '/en/order/' } };
const SLUGS = kb.products.map((p) => p.slug);
const LINKS = (lang) => ({ shop: BASE + PATHS[lang].shop, companies: BASE + site.pages.companies[lang], slugs: SLUGS });
const linkVal = (k, v) => (typeof v === 'string' && /^(short_)?description(_en)?$/.test(k) ? JL.rewriteHtml(v, LINKS(k.endsWith('_en') ? 'en' : 'fi')) : v);
writeFileSync(join(A, 'static-products.json'), JSON.stringify(Object.fromEntries(kb.products.map((p) => [p.slug, Object.fromEntries(STATIC_KEYS.filter((k) => p[k] != null).map((k) => [k, linkVal(k, p[k])])) ]))));

// 3) varaussivut (FI/EN) + vahvistussivut: sivuston oma layout
const write = (urlPath, html) => { const f = join(OUT, urlPath, 'index.html'); mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, html); };
// Sivutekstit (§18, osa 3): avaimet page.*/seo.* tietokannasta (tx), repon oletus shop-page-texts.js kunnes avaimet on tuotu (varatekstien käyttö lasketaan ja raportoidaan).
let pageFallbacks = 0;
const px = (key, lang) => ST.tx(key, lang, { state: siteTexts, fallback: pageDefault(key, lang), log: { warn: (m) => { if (/siirtymäajan varatekstiä/.test(m)) pageFallbacks++; else console.warn(m); } } });
const pageSet = (lang) => ({ title: px('page.book.title', lang), text: px('page.book.lead', lang), meta: px('seo.book.title', lang), desc: px('seo.book.description', lang), noscript: px('page.book.noscript', lang), ctitle: px('page.book_confirm.title', lang), cmeta: px('seo.book_confirm.title', lang) });
const T = { fi: pageSet('fi'), en: pageSet('en') };
for (const lang of ['fi', 'en']) {
  for (const page of ['shop', 'confirm']) {
    const t = T[lang];
    const S = {
      lang, page: page === 'shop' ? 'shop' : 'confirm', shopHref: BASE + PATHS[lang].shop, confirmHref: BASE + PATHS[lang].confirm,
      orderHref: { fi: BASE + PATHS.fi.order, en: BASE + PATHS.en.order },   // vuosikortin osto → tilaussivu (booking_142)
      termsHref: L.pageHref('terms', lang), infoHref: L.pageHref('info', lang), phone: L.phoneDisplay(lang), phoneTel: site.contact.phoneTel, email: site.contact.email,
      staticProductsUrl: `${BASE}/booking/static-products.json`, siteTextsUrl: `${BASE}/booking/site-texts.json`, links: LINKS(lang),
    };
    const body = R.pageHero({ title: page === 'shop' ? t.title : t.ctitle, text: page === 'shop' ? t.text : '', img: 'ovi-kaiverrus' }, lang, 'book')
      + `<section class="section"><div class="wrap"><div id="booking-app" aria-busy="true"><noscript><p>${e(t.noscript)}: <a href="tel:${site.contact.phoneTel}">${e(L.phoneDisplay(lang))}</a></p></noscript></div></div></section>`
      + `<script src="${BASE}/booking/config.js"></script><script>window.BOOKING_SHOP=${JSON.stringify(S)}</script><script type="module" src="${BASE}/booking/shop.js"></script>`;
    let html = R.layout({ lang, key: 'book', meta: { title: page === 'shop' ? t.meta : t.cmeta, description: t.desc, og: 'ovi-kaiverrus' }, body });
    html = html.replace('</head>', `<link rel="stylesheet" href="${BASE}/booking/shop.css">${page === 'shop' ? '<script>if(/^#\\/(tuote|varaa|hoito)\\//.test(location.hash))document.documentElement.classList.add("bk-hero-wait")</script>' : ''}</head>`);
    if (page === 'confirm') html = html.replace(/<link rel="canonical"[^>]*>(<link rel="alternate"[^>]*>)*/, '').replace('<meta name="description"', '<meta name="robots" content="noindex,nofollow"><meta name="description"');
    write(PATHS[lang][page === 'shop' ? 'shop' : 'confirm'], html);
  }
}

// 3b) asiakkaan tilaussivu (vaihe A: UI-runko; token vain URL-parametrina ?t=…, ei indeksointia, ei Referer-vuotoa)
const orderSet = (lang) => ({ title: px('page.order.title', lang), text: px('page.order.lead', lang), meta: px('seo.order.title', lang), noscript: px('page.order.noscript', lang) });
const OT = { fi: orderSet('fi'), en: orderSet('en') };
if (pageFallbacks) console.log(`site-texts: ${pageFallbacks} varaus-/tilaussivun tekstiä käyttää repon varatekstiä (avain ei vielä tietokannassa)`);
for (const lang of ['fi', 'en']) {
  const t = OT[lang];
  const S = { lang, page: 'order', base: BASE, links: LINKS(lang), siteTextsUrl: `${BASE}/booking/site-texts.json`, orderHref: { fi: BASE + PATHS.fi.order, en: BASE + PATHS.en.order }, shopHref: BASE + PATHS[lang].shop, phone: L.phoneDisplay(lang), phoneTel: site.contact.phoneTel, email: site.contact.email };
  const body = R.pageHero({ title: t.title, text: t.text, img: 'ovi-kaiverrus' }, lang, 'book')
    + `<section class="section"><div class="wrap"><div id="order-app" aria-busy="true"><noscript><p>${e(t.noscript)}: <a href="tel:${site.contact.phoneTel}">${e(L.phoneDisplay(lang))}</a></p></noscript></div></div></section>`
    + `<script src="${BASE}/booking/config.js"></script><script>window.BOOKING_SHOP=${JSON.stringify(S)}</script><script type="module" src="${BASE}/booking/order.js"></script>`;
  let html = R.layout({ lang, key: 'book', meta: { title: t.meta, description: t.text, og: 'ovi-kaiverrus' }, body });
  html = html.replace('</head>', `<meta name="referrer" content="no-referrer"><link rel="stylesheet" href="${BASE}/booking/shop.css"></head>`);
  html = html.replace(/<link rel="canonical"[^>]*>(<link rel="alternate"[^>]*>)*/, '').replace(/<meta name="robots" content="[^"]*">/, '').replace('<meta name="description"', '<meta name="robots" content="noindex,nofollow"><meta name="description"');
  write(PATHS[lang].order, html);   // polku = sopimus: settings.order_page_path = '/tilaus/' (linkki …/tilaus/?t=<public_token>); EN-sivu /en/order/ (tilauksen locale ohjaa oikeaan kieleen, ks. order.js)
}

// 3c) lahjakorttisivu (/lahjakortti/, /en/gift-card/): myynti- ja saldolohkot piilossa kunnes gift.js näkee sale_enabled / redeem_enabled = true (muuten sivu on ennallaan: Johku-linkit)
for (const lang of ['fi', 'en']) {
  const f = join(OUT, site.pages.gift[lang], 'index.html');
  let html = readFileSync(f, 'utf8');
  const S = { lang, page: 'gift', base: BASE, links: LINKS(lang), siteTextsUrl: `${BASE}/booking/site-texts.json`, orderHref: { fi: BASE + PATHS.fi.order, en: BASE + PATHS.en.order }, termsHref: L.pageHref('terms', lang), phone: L.phoneDisplay(lang), phoneTel: site.contact.phoneTel, email: site.contact.email };
  const sale = `<section class="section" hidden><div class="wrap"><div id="gift-app" aria-busy="true"></div></div></section>`;
  const bal = `<section class="section tint" id="saldo" hidden><div class="wrap"><div id="gift-balance" aria-busy="true"></div></div></section>`;
  const a = html.indexOf('<section class="section " id="avoin"'), b = html.indexOf('<section class="section tint" id="jatkaminen"');
  if (a < 0 || b < 0) throw new Error(`lahjakorttisivun osioita (#avoin, #jatkaminen) ei löytynyt: ${f}`);
  html = html.slice(0, a) + sale + html.slice(a, b) + bal + html.slice(b);
  html = html.replace('</head>', `<link rel="stylesheet" href="${BASE}/booking/shop.css"></head>`)
    .replace('</body>', `<script src="${BASE}/booking/config.js"></script><script>window.BOOKING_SHOP=${JSON.stringify(S)}</script><script type="module" src="${BASE}/booking/gift.js"></script></body>`);
  writeFileSync(f, html);
}

// 3d) Yrityksille: sama varauskalenteri, audience=business (vain yritysten saunavuorot). Vahvistus on yhteinen tilaussivu.
for (const lang of ['fi', 'en']) {
  const urlPath = site.pages.companies[lang];
  const f = join(OUT, urlPath, 'index.html');
  let html = readFileSync(f, 'utf8');
  if (!html.includes('id="booking-app"')) throw new Error(`yrityssivulta puuttuu #booking-app: ${f}`);
  const S = {
    lang, page: 'shop', audience: 'business', shopHref: BASE + urlPath, confirmHref: BASE + PATHS[lang].confirm,
    orderHref: { fi: BASE + PATHS.fi.order, en: BASE + PATHS.en.order },
    termsHref: L.pageHref('terms', lang), infoHref: L.pageHref('info', lang), phone: L.phoneDisplay(lang), phoneTel: site.contact.phoneTel, email: site.contact.email,
    staticProductsUrl: `${BASE}/booking/static-products.json`, siteTextsUrl: `${BASE}/booking/site-texts.json`, links: LINKS(lang),
  };
  html = html.replace('</head>', `<link rel="stylesheet" href="${BASE}/booking/shop.css"></head>`)
    .replace('</body>', `<script src="${BASE}/booking/config.js"></script><script>window.BOOKING_SHOP=${JSON.stringify(S)}</script><script type="module" src="${BASE}/booking/shop.js"></script></body>`);
  writeFileSync(f, html);
}

// 4) Johku-linkit → sisäinen varauskalenteri (johku-links.js: tuote → /varaa/#/tuote/<slug>, EN /en/book/#/tuote/<slug>; yrityksille → yrityssivu;
//    vuosikortti → #/vuosikortti; jää Johkuun vain johku-links.js:n KEEP-lista: lahjakorttivaraus, lahja-/sarjakortit, Johkun info)
const rewrite = (html, lang) => JL.rewriteHtml(html, LINKS(lang));
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
// Varmistus: jokainen kaupan distin relatiivinen import löytyy dististä (sama tarkistus kuin hallinnalla build-pages.mjs:ssä).
(function chkImports(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) continue; if (!n.endsWith('.js')) continue; for (const m of readFileSync(p, 'utf8').matchAll(/(?:from|import)\s*\(?\s*(['"])(\.{1,2}\/[^'"?]+\.js)(?:\?[^'"]*)?\1/g)) { if (!statSync(resolve(d, m[2]), { throwIfNoEntry: false })) { console.error(`shop build: VIRHE: ${p}: tuotu moduuli puuttuu dististä: ${m[2]}`); process.exit(1); } } } })(A);
console.log(`shop build ok → ${OUT} (${changed} sivun Johku-linkit korvattu)`);
