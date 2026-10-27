// Sisältöosion rakennustarkistus dist/-kansiolle (CI): JSON-LD, canonical, hreflang, sitemap, robots, kuvat, ohjaussivut, navigaatio.
// Käyttö: node scripts/check-articles.mjs   (DIST, SITE_ENV, SITE_URL kuten rakennuksessa). Exit 1 jos virheitä.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const attr = (tag, n) => new RegExp(`\\s${n}="([^"]*)"`).exec(tag)?.[1];
const dec = (s) => String(s ?? '').replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');

/** Poimii sivun tarkistettavat tiedot HTML:stä. */
export function parsePage(html) {
  const head = html.split('</head>')[0];
  const metas = [...head.matchAll(/<meta\b[^>]*>/g)].map((m) => m[0]);
  const links = [...head.matchAll(/<link\b[^>]*>/g)].map((m) => m[0]);
  const meta = (k, v) => metas.filter((m) => attr(m, k) === v).map((m) => dec(attr(m, 'content')));
  return {
    lang: /<html lang="([^"]+)"/.exec(html)?.[1],
    title: dec(/<title>([^<]*)/.exec(head)?.[1]),
    description: meta('name', 'description')[0],
    robots: meta('name', 'robots'),
    canonicals: links.filter((l) => attr(l, 'rel') === 'canonical').map((l) => dec(attr(l, 'href'))),
    hreflangs: links.filter((l) => attr(l, 'rel') === 'alternate' && attr(l, 'hreflang')).map((l) => ({ hreflang: attr(l, 'hreflang'), href: dec(attr(l, 'href')) })),
    og: Object.fromEntries(metas.filter((m) => attr(m, 'property')?.startsWith('og:')).map((m) => [attr(m, 'property'), dec(attr(m, 'content'))])),
    ogMulti: metas.filter((m) => attr(m, 'property')?.startsWith('article:')).map((m) => [attr(m, 'property'), dec(attr(m, 'content'))]),
    twitterCard: meta('name', 'twitter:card')[0],
    refresh: metas.filter((m) => attr(m, 'http-equiv') === 'refresh').map((m) => attr(m, 'content')),
    ld: [...head.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => m[1]),
    h1: (html.match(/<h1[ >]/g) || []).length,
    imgs: [...html.matchAll(/<img\b[^>]*>/g)].map((m) => m[0]),
    body: html.slice(head.length),
  };
}
const ISO = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$/;

export function parseSitemap(xml) {
  const errs = [];
  if (!/^<\?xml[^>]*\?>\s*<urlset\b[^>]*xmlns="http:\/\/www\.sitemaps\.org\/schemas\/sitemap\/0\.9"/.test(xml)) errs.push('sitemap.xml: virheellinen alku (xml-esittely/urlset)');
  if (!/<\/urlset>\s*$/.test(xml)) errs.push('sitemap.xml: urlset ei sulkeudu');
  const urls = [...xml.matchAll(/<url>([\s\S]*?)<\/url>/g)].map((m) => ({
    loc: dec(/<loc>([^<]*)<\/loc>/.exec(m[1])?.[1]), lastmod: /<lastmod>([^<]*)<\/lastmod>/.exec(m[1])?.[1],
    alternates: [...m[1].matchAll(/<xhtml:link\b[^>]*>/g)].map((x) => ({ hreflang: attr(x[0], 'hreflang'), href: dec(attr(x[0], 'href')) })),
  }));
  return { urls, errs };
}

/** @returns {{errors:string[], warnings:string[], stats:object}} */
export function checkDist({ dist, siteUrl, isTest, sections, legacy = {} }) {
  const errors = [], warnings = [];
  const err = (m) => errors.push(m), warn = (m) => warnings.push(m);
  const base = new URL(siteUrl).pathname.replace(/\/$/, '');
  const toFile = (url) => {
    if (!url.startsWith(siteUrl)) return null;
    let p = url.slice(siteUrl.length).split('#')[0].split('?')[0];
    const f = join(dist, p);
    return existsSync(f) && statSync(f).isDirectory() ? join(f, 'index.html') : f;
  };
  const pathOf = (url) => url.slice(siteUrl.length);
  const legacyOf = (path) => Object.entries(legacy).find(([, ps]) => ps.some((p) => path.startsWith(p)))?.[0];   // vanhat osion polut: pitää olla pelkkiä ohjaussivuja
  const secOf = (path) => Object.entries(sections).find(([, p]) => path.startsWith(p))?.[0] || legacyOf(path);

  // kaikki sisältöosion sivut
  const pages = [];
  (function walk(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) walk(p); else if (n === 'index.html') pages.push(p); } })(dist);
  const secPages = [];
  for (const f of pages) {
    const rel = '/' + f.slice(dist.length + 1).replace(/index\.html$/, '');
    const lang = secOf(rel);
    if (lang) secPages.push({ file: f, rel, lang, url: siteUrl + rel, ...parsePage(readFileSync(f, 'utf8')) });
  }
  const byUrl = new Map(secPages.map((p) => [p.url, p]));
  const isArticle = (p) => p.og['og:type'] === 'article' || p.ld.some((j) => /"@type"\s*:\s*"Article"/.test(j));   // rikkinäinen JSON-LD ei saa piilottaa artikkelisivua tarkistukselta
  const isRedirect = (p) => p.refresh.length > 0;
  const kind = (p) => (isRedirect(p) ? 'redirect' : isArticle(p) ? 'article' : 'list');
  const listPathOf = (lang) => sections[lang];

  const stats = { pages: secPages.length, articles: 0, redirects: 0, lists: 0 };
  const sm = existsSync(join(dist, 'sitemap.xml')) ? parseSitemap(readFileSync(join(dist, 'sitemap.xml'), 'utf8')) : { urls: [], errs: ['sitemap.xml puuttuu'] };
  sm.errs.forEach(err);
  const smByLoc = new Map(sm.urls.map((u) => [u.loc, u]));
  if (smByLoc.size !== sm.urls.length) err('sitemap.xml: päällekkäisiä <loc>-arvoja');

  for (const p of secPages) {
    const k = kind(p), w = p.rel;
    stats[k === 'article' ? 'articles' : k === 'redirect' ? 'redirects' : 'lists']++;
    if (legacyOf(p.rel) && k !== 'redirect') err(`${p.rel}: vanha osion polku (legacyPaths) pitää olla ohjaussivu, ei ${k}`);
    // perusasiat
    if (p.canonicals.length !== 1) { err(`${w}: canonical-linkkejä ${p.canonicals.length} (pitää olla 1)`); continue; }
    const canon = p.canonicals[0];
    if (!/^https?:\/\//.test(canon)) err(`${w}: canonical ei ole absoluuttinen: ${canon}`);
    if (!p.title) err(`${w}: title puuttuu`); else if (p.title.length > 90) warn(`${w}: title pitkä (${p.title.length})`);
    if (!p.description) err(`${w}: description puuttuu`); else if (p.description.length > 175) warn(`${w}: description pitkä (${p.description.length})`);
    if (p.h1 !== 1) err(`${w}: h1-otsikoita ${p.h1} (pitää olla 1)`);
    if (p.lang !== p.rel.startsWith(listPathOf('en')) ? 'fi' : 'en') { /* ks. alla */ }
    const expLang = secOf(p.rel); if (p.lang !== expLang) err(`${w}: html lang="${p.lang}" ≠ ${expLang}`);
    // robots
    const rb = p.robots.join(',');
    if (isTest) { if (!/noindex/.test(rb)) err(`${w}: testiympäristössä sivulla pitää olla noindex (SITE_ENV=test)`); }
    else if (k !== 'redirect' && !p.robots.length) err(`${w}: robots-meta puuttuu`);
    // kuvat
    p.imgs.forEach((im, i) => {
      if (!/\salt="/.test(im)) err(`${w}: img ilman alt: ${im.slice(0, 90)}`);
      const wd = attr(im, 'width'), ht = attr(im, 'height');
      if (!/^\d+$/.test(wd || '') || !/^\d+$/.test(ht || '')) { if (!/favicon|ikoni/.test(im)) err(`${w}: img ilman width/height: ${im.slice(0, 90)}`); }
    });
    for (const m of p.body.matchAll(/(?:srcset)="([^"]*)"/g)) for (const part of m[1].split(',')) { const u = part.trim().split(/\s+/)[0]; if (u && !/^https?:/.test(u) && !existsSync(join(dist, u.startsWith(base + '/') ? u.slice(base.length) : u))) err(`${w}: srcset rikki ${u}`); }

    if (k === 'redirect') {
      const m = /url=(.+)$/.exec(p.refresh[0]);
      const target = m && (m[1].startsWith('http') ? m[1] : siteUrl.replace(base, '') + m[1]);
      const tf = target && toFile(target);
      if (!tf || !existsSync(tf)) err(`${w}: ohjauksen kohdetta ei löydy (${m?.[1]})`);
      else if (canon !== (target.startsWith(siteUrl) ? target : canon)) err(`${w}: ohjaussivun canonical (${canon}) ≠ kohde (${target})`);
      if (!/^0(;|$)/.test(p.refresh[0])) err(`${w}: meta refresh ei ole välitön (0 s)`);
      if (smByLoc.has(p.url)) err(`${w}: ohjaussivu ei saa olla sitemapissa`);
      continue;
    }

    if (k === 'article') {
      // JSON-LD
      const lds = p.ld.map((j) => { try { return JSON.parse(j); } catch (er) { err(`${w}: JSON-LD ei ole kelvollista JSONia (${er.message})`); return null; } }).filter(Boolean);
      const a = lds.find((x) => x['@type'] === 'Article'), bc = lds.find((x) => x['@type'] === 'BreadcrumbList');
      if (a) {
        if (a['@context'] !== 'https://schema.org') err(`${w}: Article @context väärin`);
        for (const f of ['headline', 'description', 'datePublished', 'dateModified', 'inLanguage']) if (!a[f]) err(`${w}: Article.${f} puuttuu`);
        if (a.headline && a.headline.length > 120) err(`${w}: Article.headline > 120 merkkiä`);
        for (const f of ['datePublished', 'dateModified']) if (a[f] && (!ISO.test(a[f]) || Number.isNaN(Date.parse(a[f])))) err(`${w}: Article.${f} ei ole ISO 8601 (${a[f]})`);
        if (a.datePublished && a.dateModified && Date.parse(a.dateModified) < Date.parse(a.datePublished)) err(`${w}: dateModified < datePublished`);
        if (!Array.isArray(a.image) || !a.image.length || a.image.some((x) => !/^https?:\/\//.test(x))) err(`${w}: Article.image pitää olla taulukko absoluuttisia osoitteita`);
        if (!a.author?.name || !/^(Person|Organization)$/.test(a.author['@type'])) err(`${w}: Article.author (Person/Organization + name) puuttuu`);
        if (!a.publisher?.name || a.publisher['@type'] !== 'Organization') err(`${w}: Article.publisher (Organization + name) puuttuu`);
        if (a.mainEntityOfPage?.['@id'] !== canon) err(`${w}: Article.mainEntityOfPage.@id (${a.mainEntityOfPage?.['@id']}) ≠ canonical (${canon})`);
        if (a.inLanguage && a.inLanguage !== p.lang) err(`${w}: Article.inLanguage ≠ html lang`);
        if (a.headline && !p.body.includes(`<h1`)) err(`${w}: h1 puuttuu`);
      }
      if (!bc) err(`${w}: BreadcrumbList puuttuu`);
      else {
        const it = bc.itemListElement || [];
        if (it.length !== 3 || it.some((x, i) => x.position !== i + 1 || !x.name || !x.item)) err(`${w}: BreadcrumbList rakenne väärin (3 kohtaa, position 1..3, name, item)`);
        else if (it[2].item !== canon) err(`${w}: BreadcrumbList viimeinen item ≠ canonical`);
        else if (it[1].item !== siteUrl + listPathOf(p.lang)) err(`${w}: BreadcrumbList toinen item ≠ listaussivu`);
      }
      // Open Graph / Twitter
      if (p.og['og:type'] !== 'article') err(`${w}: og:type ≠ article`);
      if (p.og['og:url'] !== canon) err(`${w}: og:url ≠ canonical`);
      for (const f of ['og:title', 'og:description', 'og:image', 'og:image:width', 'og:image:height']) if (!p.og[f]) err(`${w}: ${f} puuttuu`);
      if (p.og['og:image'] && !/^https?:\/\//.test(p.og['og:image'])) err(`${w}: og:image ei ole absoluuttinen`);
      if (!p.ogMulti.some(([n]) => n === 'article:published_time') || !p.ogMulti.some(([n]) => n === 'article:modified_time')) err(`${w}: article:published_time/modified_time puuttuu`);
      if (p.twitterCard !== 'summary_large_image') err(`${w}: twitter:card ≠ summary_large_image`);
      // pääkuva: eager + fetchpriority, muut lazy
      const heroImg = p.imgs.find((im) => /fetchpriority="high"/.test(im));
      if (!heroImg) warn(`${w}: pääkuvaa (fetchpriority=high) ei löydy`);
      for (const im of p.imgs) if (!/fetchpriority="high"|loading="lazy"/.test(im) && !/favicon/.test(im)) err(`${w}: img ilman lazy/eager-merkintää: ${im.slice(0, 80)}`);
      if (!/<nav class="crumbs"/.test(p.body)) err(`${w}: murupolku puuttuu`);
      if (!/class="article-cta"/.test(p.body)) err(`${w}: CTA-lohko puuttuu`);
    }

    // hreflang
    if (p.hreflangs.length) {
      const set = new Map(p.hreflangs.map((x) => [x.hreflang, x.href]));
      if (set.size !== p.hreflangs.length) err(`${w}: päällekkäisiä hreflang-arvoja`);
      for (const x of p.hreflangs) if (!/^(fi|en|x-default)$/.test(x.hreflang)) err(`${w}: tuntematon hreflang ${x.hreflang}`);
      if (!set.has('fi') || !set.has('en') || !set.has('x-default')) err(`${w}: hreflang-joukossa pitää olla fi, en ja x-default`);
      if (set.get('x-default') !== set.get('fi')) err(`${w}: x-default ≠ fi`);
      if (set.get(p.lang) !== canon) err(`${w}: hreflang ${p.lang} ei viittaa itseen (canonical ${canon})`);
      for (const x of p.hreflangs) {
        const t = byUrl.get(x.href);
        if (!t) { if (x.href.startsWith(siteUrl)) err(`${w}: hreflang ${x.hreflang} → ${x.href} ei löydy dististä`); continue; }
        const back = new Map(t.hreflangs.map((y) => [y.hreflang, y.href]));
        if (back.get(p.lang) !== canon) err(`${w}: hreflang ei ole molemminpuolinen (${x.href} ei viittaa takaisin ${canon})`);
        if (t.canonicals[0] !== x.href) err(`${w}: hreflang-kohteen canonical ei ole se itse (${x.href})`);
      }
    }
  }

  // sitemap vs. sivut
  const sectionLocs = sm.urls.filter((u) => secOf(u.loc.startsWith(siteUrl) ? pathOf(u.loc) : ''));
  for (const u of sectionLocs) {
    const p = byUrl.get(u.loc);
    if (!p) { err(`sitemap: ${u.loc} ei vastaa dististä sivua`); continue; }
    if (p.canonicals[0] !== u.loc) err(`sitemap: ${u.loc} ≠ sivun canonical (${p.canonicals[0]})`);
    if (kind(p) === 'redirect') err(`sitemap: ${u.loc} on ohjaussivu`);
    if (!isTest && /noindex/.test(p.robots.join(','))) err(`sitemap: ${u.loc} on noindex`);
    if (u.lastmod && !ISO.test(u.lastmod)) err(`sitemap: ${u.loc} lastmod virheellinen (${u.lastmod})`);
    if (!u.lastmod) err(`sitemap: ${u.loc} lastmod puuttuu`);
    const alts = new Map(u.alternates.map((x) => [x.hreflang, x.href]));
    const pageAlts = new Map(p.hreflangs.map((x) => [x.hreflang, x.href]));
    if (JSON.stringify([...alts].sort()) !== JSON.stringify([...pageAlts].sort())) err(`sitemap: ${u.loc} hreflang-vaihtoehdot eivät täsmää sivun hreflangeihin`);
    for (const x of u.alternates) if (!smByLoc.has(x.href)) err(`sitemap: ${u.loc} vaihtoehto ${x.href} ei ole itse sitemapissa`);
  }
  if (!isTest) {
    // indeksoitavat artikkelit ja listaus (sivu 1, ei tagit) pitää olla sitemapissa
    for (const p of secPages) {
      const k = kind(p), isTag = p.rel.includes('/tagi/') || p.rel.includes('/tag/'), isPage = /\/(sivu|page)\/\d+\/$/.test(p.rel);
      const idx = !/noindex/.test(p.robots.join(',')) && p.canonicals[0] === p.url && k !== 'redirect';
      if (k === 'article' && idx && !smByLoc.has(p.url)) err(`${p.rel}: indeksoitava artikkeli puuttuu sitemapista`);
      if (k === 'list' && idx && !isTag && !isPage && !smByLoc.has(p.url)) err(`${p.rel}: indeksoitava listaus puuttuu sitemapista`);
      if ((isTag || isPage) && smByLoc.has(p.url)) err(`${p.rel}: tagi-/sivutussivu ei kuulu sitemapiin`);
      if (isTag && !/noindex/.test(p.robots.join(','))) err(`${p.rel}: tagisivun pitää olla noindex`);
    }
    if (!/Sitemap: /.test(readFileSync(join(dist, 'robots.txt'), 'utf8'))) err('robots.txt: Sitemap-rivi puuttuu (tuotanto)');
    if (/Disallow: \/\s*$/m.test(readFileSync(join(dist, 'robots.txt'), 'utf8'))) err('robots.txt: tuotannossa ei saa estää koko sivustoa');
  } else {
    if (!/Disallow: \//.test(readFileSync(join(dist, 'robots.txt'), 'utf8'))) err('robots.txt: testiympäristössä pitää estää indeksointi');
  }

  // listaussivut: jokaiselle kielelle on listaus; tyhjä listaus noindex + ei sitemapissa + ei navigaatiolinkkiä; muuten kaikki artikkelit linkitetty listauksista
  for (const lang of Object.keys(sections)) {
    const first = byUrl.get(siteUrl + sections[lang]);
    if (!first) { err(`listaus ${sections[lang]} puuttuu`); continue; }
    const arts = secPages.filter((p) => kind(p) === 'article' && p.lang === lang);
    const home = join(dist, lang === 'fi' ? 'index.html' : 'en/index.html');
    const homeHtml = existsSync(home) ? readFileSync(home, 'utf8') : '';
    // navigaatiolinkki: etusivun Saunatietoa-nauha ja vanha korttiosio eivät ole valikon linkkejä
    const cutMarker = (html, marker) => {
      const at = html.indexOf(marker);
      if (at < 0) return html;
      const start = html.lastIndexOf('<section', at);
      const end = html.indexOf('</section>', at);
      if (start < 0 || end < 0) return html;
      return html.slice(0, start) + html.slice(end + 10);
    };
    const homeNoSec = cutMarker(cutMarker(homeHtml, 'id="saunatietoa"'), 'class="section home-art"');
    const navLinked = homeNoSec.includes(`href="${base}${sections[lang]}"`);
    const hs = homeHtml.indexOf('class="section home-art"');
    const stripAt = homeHtml.indexOf('id="saunatietoa"');
    const stripSec = stripAt < 0 ? '' : homeHtml.slice(homeHtml.lastIndexOf('<section', stripAt), homeHtml.indexOf('</section>', stripAt));
    const stripOk = stripSec.includes(`href="${base}${sections[lang]}"`);
    // Etusivu: kompakti nauha (id=saunatietoa) linkittää listaukseen. Vanhaa korttiosiota (home-art) ei enää upoteta;
    // jos se silti on sivulla, kortit tarkistetaan kuten ennen. Tyhjällä osiolla korttiosiota ei saa olla.
    if (!arts.length) { if (hs >= 0) err(`etusivun (${lang}) artikkeliosio näkyy vaikka artikkeleita ei ole`); }
    else if (hs >= 0) {
      const sec = homeHtml.slice(hs, homeHtml.indexOf('</section>', hs));
      const cards = sec.split('<li class="card hart').slice(1);
      if (cards.length < 1 || cards.length > 3) err(`etusivun (${lang}) artikkeliosiossa ${cards.length} korttia (sallittu 1–3)`);
      if (!sec.includes(`href="${base}${sections[lang]}"`)) err(`etusivun (${lang}) artikkeliosiosta puuttuu linkki listaukseen`);
      for (const c of cards) {
        const links = [...c.matchAll(/<a [^>]*href="([^"]+)"/g)].map((m) => m[1]);
        if (links.length !== 1) err(`etusivun (${lang}) artikkelikortissa ${links.length} linkkiä (pitää olla 1)`);
        else if (!arts.some((a) => `${base}${a.rel}` === links[0])) err(`etusivun (${lang}) artikkelikortin linkki ${links[0]} ei osoita artikkelisivuun`);
        for (const im of c.match(/<img [^>]*>/g) || []) if (!/ width="\d+"/.test(im) || !/ height="\d+"/.test(im) || !/ alt="/.test(im) || !/loading="lazy"/.test(im)) err(`etusivun (${lang}) artikkelikortin kuvasta puuttuu width/height/alt/lazy: ${im.slice(0, 80)}`);
      }
    } else if (!stripOk) err(`etusivun (${lang}) Saunatietoa-nauhasta puuttuu linkki listaukseen`);
    if (!arts.length) {
      if (!/noindex/.test(first.robots.join(','))) err(`${first.rel}: tyhjän listauksen pitää olla noindex`);
      if (smByLoc.has(first.url)) err(`${first.rel}: tyhjä listaus ei kuulu sitemapiin`);
      if (navLinked) err(`etusivun (${lang}) navigaatiossa on linkki tyhjään osioon`);
      if (!/class="art-empty"/.test(first.body)) err(`${first.rel}: tyhjä tila (art-empty) puuttuu`);
    } else {
      if (!navLinked) err(`etusivun (${lang}) navigaatiosta puuttuu linkki osioon`);
      const listBodies = secPages.filter((p) => kind(p) === 'list' && p.lang === lang && !/\/(tagi|tag)\//.test(p.rel)).map((p) => p.body).join('\n');
      for (const a of arts) if (!listBodies.includes(`href="${base}${a.rel}"`)) err(`${a.rel}: artikkelia ei ole linkitetty listaussivulta`);
    }
  }
  return { errors, warnings, stats };
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  const { SITE_URL, isTest } = await import('../src/lib.mjs');
  const { cfg } = await import('../src/articles/config.mjs');
  const dist = process.env.DIST || 'dist';
  const r = checkDist({ dist, siteUrl: SITE_URL, isTest, sections: cfg.path, legacy: cfg.legacyPaths });
  console.log(`check-articles: sisältöosion sivuja ${r.stats.pages} (artikkeleita ${r.stats.articles}, listauksia ${r.stats.lists}, ohjaussivuja ${r.stats.redirects}), ympäristö=${isTest ? 'test' : 'prod'}`);
  if (r.warnings.length) console.log('VAROITUKSET:\n' + [...new Set(r.warnings)].join('\n'));
  if (r.errors.length) { console.log('VIRHEET:\n' + [...new Set(r.errors)].join('\n')); process.exit(1); }
  console.log('check-articles OK');
}
