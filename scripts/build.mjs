// Rakentaa staattisen sivuston hakemistoon dist/. Käyttö: node scripts/build.mjs  (SITE_ENV=test → noindex + testiosoite)
import { rmSync, mkdirSync, writeFileSync, cpSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { site, SITE_URL, isTest, abs, kb } from '../src/lib.mjs';
import * as R from '../src/render.mjs';

const OUT = process.env.DIST || 'dist';
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
cpSync('public', OUT, { recursive: true });

const write = (urlPath, html) => {
  const file = urlPath.endsWith('/') ? join(OUT, urlPath, 'index.html') : join(OUT, urlPath);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, html);
};
const render = {
  home: R.home, sauna: R.sauna, treatments: R.treatments, gift: R.gift, book: R.book, info: R.info, companies: R.companies,
  terms: (l) => R.policyPage('terms', 'terms', l), privacy: (l) => R.policyPage('privacy', 'privacy', l),
};
const urls = [];
for (const [key, paths] of Object.entries(site.pages)) {
  for (const lang of ['fi', 'en']) {
    if (!paths[lang]) continue;
    write(paths[lang], render[key](lang));
    urls.push({ key, lang, path: paths[lang] });
  }
}
write('/404.html', R.notFound());

// sitemap.xml (hreflang-vaihtoehdot)
const today = new Date().toISOString().slice(0, 10);
const alt = (k) => ['fi', 'en'].filter((l) => site.pages[k][l]).map((l) => `<xhtml:link rel="alternate" hreflang="${l}" href="${abs(site.pages[k][l])}"/>`).join('') + `<xhtml:link rel="alternate" hreflang="x-default" href="${abs(site.pages[k].fi)}"/>`;
write('/sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n${urls.map((u) => `<url><loc>${abs(u.path)}</loc><lastmod>${today}</lastmod>${alt(u.key)}</url>`).join('\n')}\n</urlset>\n`);
write('/robots.txt', isTest ? 'User-agent: *\nDisallow: /\n' : `User-agent: *\nAllow: /\n\nSitemap: ${SITE_URL}/sitemap.xml\n`);
console.log(`build ok: ${urls.length + 1} sivua, ympäristö=${isTest ? 'test (noindex)' : 'prod'}, ${SITE_URL}`);
