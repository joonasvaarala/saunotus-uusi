// Linkki- ja resurssitarkistus dist/-hakemistolle. Käyttö: node scripts/check.mjs [--external]
// Tarkistaa: sisäiset linkit/kuvat/srcset/fontit olemassa, #ankkurit, img alt, yksilölliset title/description,
// hreflang-vastaavuus. --external tarkistaa myös ulkoiset linkit (HEAD/GET).
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';
const DIST = process.env.DIST || 'dist';
const ext = process.argv.includes('--external');
const files = [];
(function walk(d) { for (const f of readdirSync(d)) { const p = join(d, f); statSync(p).isDirectory() ? walk(p) : p.endsWith('.html') && files.push(p); } })(DIST);
const errs = [], warns = [], externals = new Map();
const titles = new Map(), descs = new Map();
const base = (() => { const m = /<link rel="canonical" href="(https?:\/\/[^/]+)(\/[^/"]*)?/.exec(readFileSync(join(DIST, 'index.html'), 'utf8')); return m ? (m[2] || '') : ''; })();
const exists = (u) => {
  let p = u.split('#')[0].split('?')[0];
  if (base && p.startsWith(base + '/')) p = p.slice(base.length);
  else if (base && p === base) p = '/';
  const f = join(DIST, p);
  return existsSync(f) && (statSync(f).isFile() || existsSync(join(f, 'index.html')));
};
const ids = new Map();
const htmlOf = new Map();
for (const f of files) { const h = readFileSync(f, 'utf8'); htmlOf.set(f, h); ids.set(f, new Set([...h.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]))); }
const fileOf = (u) => { let p = u.split('#')[0]; if (base && p.startsWith(base)) p = p.slice(base.length) || '/'; const f = join(DIST, p); return statSync(f, { throwIfNoEntry: false })?.isDirectory() ? join(f, 'index.html') : f; };
let nLinks = 0, nImgs = 0;
for (const f of files) {
  const h = htmlOf.get(f);
  const where = f.replace(DIST + '/', '');
  const t = /<title>([^<]*)/.exec(h)?.[1], d = /<meta name="description" content="([^"]*)"/.exec(h)?.[1];
  if (f !== join(DIST, '404.html')) {
    if (!t) errs.push(`${where}: title puuttuu`); else if (titles.has(t)) warns.push(`${where}: sama title kuin ${titles.get(t)}`); else titles.set(t, where);
    if (!d) errs.push(`${where}: description puuttuu`); else if (d.length > 175) warns.push(`${where}: description pitkä (${d.length})`);
    if (!/<h1[ >]/.test(h)) errs.push(`${where}: h1 puuttuu`);
    if ((h.match(/<h1[ >]/g) || []).length > 1) errs.push(`${where}: useita h1`);
  }
  for (const m of h.matchAll(/<img\b[^>]*>/g)) { nImgs++; if (!/\balt="/.test(m[0])) errs.push(`${where}: img ilman alt: ${m[0].slice(0, 80)}`); if (!/\bwidth="/.test(m[0])) warns.push(`${where}: img ilman width`); }
  for (const m of h.matchAll(/\s(?:href|src)="([^"]*)"/g)) {
    const u = m[1]; nLinks++;
    if (/^(mailto:|tel:|data:)/.test(u) || u === '') continue;
    if (/^https?:/.test(u)) { if (!u.startsWith('http://localhost') && !/\/\/(uusi\.saunotus\.com|joonasvaarala\.github\.io)/.test(u)) externals.set(u, where); else if (/\/\/(uusi\.saunotus\.com|joonasvaarala\.github\.io)/.test(u) && /<link/.test(m.input.slice(m.index - 30, m.index))) {} continue; }
    if (u.startsWith('#')) { if (u.length > 1 && !/^#[/?]/.test(u) && !ids.get(f).has(u.slice(1))) errs.push(`${where}: ankkuri ${u} puuttuu`); continue; }
    if (!exists(u)) { errs.push(`${where}: rikki ${u}`); continue; }
    const hash = u.split('#')[1];
    // varauskaupan SPA-reitit (#/tuote/…, #/?k=…) ja SPA-sivun omat ankkurit eivät ole dokumenttiankkureita
    if (hash && !/^[/?]/.test(hash)) { const tf = fileOf(u); if (ids.get(tf) && !ids.get(tf).has(hash) && !htmlOf.get(tf)?.includes('id="booking-app"')) errs.push(`${where}: ankkuri #${hash} puuttuu sivulta ${u}`); }
  }
  for (const m of h.matchAll(/(?:srcset|imagesrcset)="([^"]*)"/g)) for (const part of m[1].split(',')) { const u = part.trim().split(/\s+/)[0]; if (u && !exists(u)) errs.push(`${where}: srcset rikki ${u}`); }
  for (const m of h.matchAll(/url\((\/[^)]+)\)/g)) if (!exists(m[1])) errs.push(`${where}: css url rikki ${m[1]}`);
  // hreflang-vastaavuus
  for (const m of h.matchAll(/hreflang="(\w[\w-]*)" href="([^"]+)"/g)) { const u = m[2].replace(/^https?:\/\/[^/]+/, ''); if (!exists(u)) warns.push(`${where}: hreflang ${m[1]} -> ${u} ei löydy dististä (normaalia jos kanoninen osoite eri)`); }
}
console.log(`sivuja ${files.length}, linkki/resurssi-viitteitä ${nLinks}, kuvia ${nImgs}, ulkoisia linkkejä ${externals.size}`);
if (ext) {
  const bad = [];
  await Promise.all([...externals.keys()].map(async (u) => {
    try { let r = await fetch(u, { method: 'HEAD', redirect: 'follow', signal: AbortSignal.timeout(15000), headers: { 'user-agent': 'Mozilla/5.0 linkcheck' } }); if (r.status >= 400) r = await fetch(u, { redirect: 'follow', signal: AbortSignal.timeout(15000), headers: { 'user-agent': 'Mozilla/5.0 linkcheck' } }); if (r.status >= 400) bad.push(`${r.status} ${u}`); } catch (er) { bad.push(`ERR ${u} (${er.message})`); }
  }));
  console.log(bad.length ? 'ULKOISET ONGELMAT:\n' + bad.join('\n') : 'ulkoiset linkit OK');
}
if (warns.length) console.log('VAROITUKSET:\n' + [...new Set(warns)].join('\n'));
if (errs.length) { console.log('VIRHEET:\n' + [...new Set(errs)].join('\n')); process.exit(1); }
console.log('check OK');
