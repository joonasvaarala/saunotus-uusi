// Rakentaa staattisen sivuston hakemistoon dist/. Käyttö: node scripts/build.mjs  (SITE_ENV=test → noindex + testiosoite)
import { rmSync, mkdirSync, writeFileSync, cpSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { site, SITE_URL, isTest, abs, kb } from '../src/lib.mjs';
import * as R from '../src/render.mjs';
import { loadForBuild, renderForBuild, renderHomePreview } from '../src/articles/index.mjs';
import { loadSiteTexts, setSiteTexts } from '../src/site-texts.mjs';
import { refreshLiveCatalog } from '../src/catalog-live.mjs';
import { refreshProductImages } from '../src/product-images.mjs';
import { applyContentTexts } from '../src/content-texts.mjs';
import { validLegacyRedirects, redirectHtml } from '../src/seo-enhance.mjs';

const OUT = process.env.DIST || 'dist';
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
cpSync('public', OUT, { recursive: true });

// Sisältöosio (Saunatietoa): artikkelit haetaan ennen sivujen renderöintiä (navigaatiolinkki riippuu siitä, onko artikkeleita). RPC-vika ei kaada rakennusta.
const articleData = await loadForBuild();
// Sivutekstit tietokannasta (§18): public_get_site_texts → välimuisti → repon varateksti; tuntematon paikkamerkki kaataa rakennuksen (src/site-texts.mjs). Sivut hakevat tekstit tx():llä.
const siteTexts = await loadSiteTexts();
setSiteTexts(siteTexts);
// Staattisten sivujen tekstit (osa 3 PR 2): tietokannan tekstit peittävät repon JSON-oletukset (site/pages/cards/alts/articles); puuttuva avain → repon oletus
const ct = applyContentTexts(siteTexts);
console.log(`site-texts: staattiset sivut: ${ct.used} tekstiä tietokannasta, ${ct.fallback} repon oletuksella (avain ei vielä tietokannassa)${ct.failed ? `, ${ct.failed} ohitettu virheen vuoksi` : ''}`);

const write = (urlPath, html) => {
  const file = urlPath.endsWith('/') ? join(OUT, urlPath, 'index.html') : join(OUT, urlPath);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, html);
};
const render = {
  home: R.home, sauna: R.sauna, treatments: R.treatments, gift: R.gift, book: R.book, info: R.info, companies: R.companies,
  terms: (l) => R.policyPage('terms', 'terms', l), privacy: (l) => R.policyPage('privacy', 'privacy', l),
};
// Artikkelisivut ennen perussivuja (navigaatiolinkki). Etusivun tuotekortit: public_catalog + public_product_images, epäonnistuminen → kb-snapshot.
const articles = await renderForBuild(articleData, OUT, { write });
await refreshLiveCatalog();
await refreshProductImages();
const urls = [];
for (const [key, paths] of Object.entries(site.pages)) {
  for (const lang of ['fi', 'en']) {
    if (!paths[lang]) continue;
    write(paths[lang], render[key](lang));
    urls.push({ key, lang, path: paths[lang] });
  }
}
write('/404.html', R.notFound());
// Paketti 11: vanhat WordPress-polut HTML-ohjauksina (aina noindex, eivät sitemap.xml:ään). Nykyiset polut ohitetaan (validLegacyRedirects).
// Jos sisältöosio (artikkelit) on jo kirjoittanut saman polun, olemassa olevaa sivua ei koskaan korvata ohjauksella.
const legacy = validLegacyRedirects().filter(([oldPath]) => !existsSync(join(OUT, oldPath, 'index.html')));
for (const [oldPath, newPath] of legacy) write(oldPath, redirectHtml(newPath));
// Etusivun osion esikatselu (vain SITE_ENV=test): feikkiartikkelit, noindex, ei sitemapissa
await renderHomePreview(OUT, { write, cacheDir: articleData.cacheDir });

// sitemap.xml (hreflang-vaihtoehdot)
const today = new Date().toISOString().slice(0, 10);
const alt = (k) => ['fi', 'en'].filter((l) => site.pages[k][l]).map((l) => `<xhtml:link rel="alternate" hreflang="${l}" href="${abs(site.pages[k][l])}"/>`).join('') + `<xhtml:link rel="alternate" hreflang="x-default" href="${abs(site.pages[k].fi)}"/>`;
const xe = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
const articleUrls = articles.sitemap.map((u) => `<url><loc>${xe(u.loc)}</loc><lastmod>${u.lastmod}</lastmod>${u.alternates.map((a) => `<xhtml:link rel="alternate" hreflang="${xe(a.hreflang)}" href="${xe(a.href)}"/>`).join('')}</url>`);
write('/sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n${[...urls.map((u) => `<url><loc>${abs(u.path)}</loc><lastmod>${today}</lastmod>${alt(u.key)}</url>`), ...articleUrls].join('\n')}\n</urlset>\n`);
write('/robots.txt', isTest ? 'User-agent: *\nDisallow: /\n' : `User-agent: *\nAllow: /\n\nSitemap: ${SITE_URL}/sitemap.xml\n`);
console.log(`build ok: ${urls.length + 1 + articles.pages.length} sivua (sisältöosio ${articles.pages.length}, vanhojen osoitteiden ohjaussivuja ${legacy.length}), ympäristö=${isTest ? 'test (noindex)' : 'prod'}, ${SITE_URL}`);
