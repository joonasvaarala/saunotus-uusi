// Etusivun herokuvan staattinen tarkistus dist/-hakemistolle (FI + EN). Käyttö: node scripts/check-hero.mjs   (DIST=dist oletus)
// Tarkistaa: <picture>-rakenne (mobiili ≤719 px: avif/webp/jpg media-ehdolla, desktop: avif/webp, img = jpg-varakuva), source/img width+height = tiedoston
// todelliset mitat, kaikki srcset-tiedostot olemassa ja kevyitä, preloadit (mobiili + desktop, komplementaariset media-ehdot, sama srcset kuin <source>),
// LCP-kuva ilman loading=lazy ja fetchpriority=high, alt-tekstit FI/EN = content/alts.json, OG-kuva 1200x630, kultanapin kontrasti ≥4,5:1.
import { readFileSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
const DIST = process.env.DIST || 'dist';
const errs = [];
const bad = (m) => errs.push(m);
const alts = JSON.parse(readFileSync('content/alts.json', 'utf8'))['hero-ovi-uusi'];
const heroMeta = JSON.parse(readFileSync('content/hero.json', 'utf8'));

// --- kuvan mitat tiedoston otsakkeesta (ei riippuvuuksia) ---
function dims(file) {
  const b = readFileSync(file);
  if (b[0] === 0xff && b[1] === 0xd8) {   // JPEG: SOFn
    for (let i = 2; i < b.length;) {
      if (b[i] !== 0xff) { i++; continue; }
      const m = b[i + 1];
      if (m >= 0xc0 && m <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(m)) return [b.readUInt16BE(i + 7), b.readUInt16BE(i + 5)];
      i += 2 + b.readUInt16BE(i + 2);
    }
  }
  if (b.toString('latin1', 0, 4) === 'RIFF' && b.toString('latin1', 8, 12) === 'WEBP') {
    const t = b.toString('latin1', 12, 16);
    if (t === 'VP8 ') return [b.readUInt16LE(26) & 0x3fff, b.readUInt16LE(28) & 0x3fff];
    if (t === 'VP8L') { const v = b.readUInt32LE(21); return [(v & 0x3fff) + 1, ((v >> 14) & 0x3fff) + 1]; }
    if (t === 'VP8X') return [b.readUIntLE(24, 3) + 1, b.readUIntLE(27, 3) + 1];
  }
  const k = b.indexOf('ispe');   // AVIF: ispe-laatikko (versio+liput 4 t, leveys 4 t, korkeus 4 t)
  if (k > 0 && b.toString('latin1', 4, 8) === 'ftyp') return [b.readUInt32BE(k + 8), b.readUInt32BE(k + 12)];
  return null;
}
const fileOf = (u) => { const m = /\/img\/[^/?#]+$/.exec(u.split(' ')[0]); return m ? join(DIST, m[0]) : null; };
const KB_MAX = { avif: { 'hero-ovi-uusi': 300, 'hero-ovi-uusi-mobiili': 200 }, webp: { 'hero-ovi-uusi': 320, 'hero-ovi-uusi-mobiili': 150 }, jpg: { 'hero-ovi-uusi': 320, 'hero-ovi-uusi-mobiili': 150 } };

// --- WCAG-kontrasti ---
const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
const lum = (h) => { const n = parseInt(h.slice(1), 16); return 0.2126 * lin(n >> 16) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255); };
const cr = (a, b) => (Math.max(lum(a), lum(b)) + 0.05) / (Math.min(lum(a), lum(b)) + 0.05);

for (const [lang, path] of [['fi', 'index.html'], ['en', 'en/index.html']]) {
  const f = join(DIST, path);
  if (!existsSync(f)) { bad(`${lang}: ${path} puuttuu`); continue; }
  const h = readFileSync(f, 'utf8');
  const sec = /<section class="hero home">(<picture>.*?<\/picture>)/.exec(h);
  if (!sec) { bad(`${lang}: hero-<picture> puuttuu`); continue; }
  const pic = sec[1];
  const sources = [...pic.matchAll(/<source\b([^>]*)>/g)].map((m) => Object.fromEntries([...m[1].matchAll(/([\w-]+)="([^"]*)"/g)].map((a) => [a[1], a[2]])));
  const img = Object.fromEntries([...(/<img\b([^>]*)>/.exec(pic)?.[1] || '').matchAll(/([\w-]+)="([^"]*)"/g)].map((a) => [a[1], a[2]]));
  const MQ = '(max-width:719px)';
  const want = [['image/avif', MQ, 'hero-ovi-uusi-mobiili'], ['image/webp', MQ, 'hero-ovi-uusi-mobiili'], ['image/jpeg', MQ, 'hero-ovi-uusi-mobiili'], ['image/avif', undefined, 'hero-ovi-uusi'], ['image/webp', undefined, 'hero-ovi-uusi']];
  if (sources.length !== want.length) bad(`${lang}: <source>-elementtejä ${sources.length}, odotettiin ${want.length}`);
  want.forEach(([type, media, id], i) => {
    const s = sources[i]; if (!s) return;
    if (s.type !== type) bad(`${lang}: source ${i} type ${s.type} ≠ ${type}`);
    if (s.media !== media) bad(`${lang}: source ${i} media ${s.media} ≠ ${media}`);
    if (!new RegExp(`/img/${id}-\\d+\\.`).test(s.srcset || '')) bad(`${lang}: source ${i} srcset ei viittaa kuvaan ${id}`);
    if (+s.width !== heroMeta[id].w || +s.height !== heroMeta[id].h) bad(`${lang}: source ${i} width/height ${s.width}x${s.height} ≠ ${heroMeta[id].w}x${heroMeta[id].h}`);
    for (const part of (s.srcset || '').split(',')) {
      const [u, w] = part.trim().split(/\s+/), file = fileOf(u), ext = type === 'image/jpeg' ? 'jpg' : type.slice(6);
      if (!file || !existsSync(file)) { bad(`${lang}: srcset-tiedosto puuttuu ${u}`); continue; }
      const d = dims(file), kb = statSync(file).size / 1024;
      if (!d) bad(`${lang}: mittoja ei luettu ${u}`);
      else {
        if (d[0] !== parseInt(w) || Math.abs(d[1] - Math.round(parseInt(w) * heroMeta[id].h / heroMeta[id].w)) > 1) bad(`${lang}: ${u} mitat ${d.join('x')} eivät vastaa ${w}:ta (suhde ${heroMeta[id].w}:${heroMeta[id].h})`);
      }
      if (kb > KB_MAX[ext][id]) bad(`${lang}: ${u} ${kb.toFixed(0)} kt > ${KB_MAX[ext][id]} kt`);
    }
  });
  // img = JPEG-varakuva desktop-kuvasta; LCP: ei lazy, fetchpriority=high
  if (!/\/img\/hero-ovi-uusi-\d+\.jpg$/.test(img.src || '')) bad(`${lang}: img src ei ole desktop-JPEG (${img.src})`);
  if (+img.width !== heroMeta['hero-ovi-uusi'].w || +img.height !== heroMeta['hero-ovi-uusi'].h) bad(`${lang}: img width/height ${img.width}x${img.height}`);
  if (img.loading) bad(`${lang}: LCP-kuvalla ei saa olla loading=${img.loading}`);
  if (img.fetchpriority !== 'high') bad(`${lang}: LCP-kuvalta puuttuu fetchpriority=high`);
  if (img.alt !== alts[lang]) bad(`${lang}: alt "${img.alt}" ≠ alts.json`);
  if (!alts.fi || !alts.en || alts.fi === alts.en) bad('alts.json: hero-ovi-uusi FI/EN puuttuu tai on sama');
  // preloadit: mobiili + desktop, komplementaariset ehdot, sama srcset kuin avif-sourcessa
  const pre = [...h.matchAll(/<link rel="preload" as="image"([^>]*)>/g)].map((m) => Object.fromEntries([...m[1].matchAll(/([\w-]+)="([^"]*)"/g)].map((a) => [a[1], a[2]])));
  if (pre.length !== 2) bad(`${lang}: kuvapreloadeja ${pre.length}, odotettiin 2`);
  else {
    const [pm, pd] = pre;
    if (pm.media !== MQ || pd.media !== '(min-width:720px)') bad(`${lang}: preload media ${pm.media} / ${pd.media}`);
    if (pm.imagesrcset !== sources[0]?.srcset) bad(`${lang}: mobiilipreload srcset ≠ mobiili-avif-source`);
    if (pd.imagesrcset !== sources[3]?.srcset) bad(`${lang}: desktop-preload srcset ≠ desktop-avif-source`);
    for (const p of pre) if (p.type !== 'image/avif' || p.fetchpriority !== 'high' || p.imagesizes !== '100vw') bad(`${lang}: preload-attribuutit (${p.type}, ${p.fetchpriority}, ${p.imagesizes})`);
  }
  // OG
  const og = /<meta property="og:image" content="([^"]+)"/.exec(h)?.[1];
  const twitter = /<meta name="twitter:image" content="([^"]+)"/.exec(h)?.[1];
  for (const [n, u] of [['og:image', og], ['twitter:image', twitter]]) if (u && !/\/img\/og-hero-ovi-uusi\.jpg$/.test(u)) bad(`${lang}: ${n} ${u}`);
  if (!og) bad(`${lang}: og:image puuttuu`);
}
const ogf = join(DIST, 'img/og-hero-ovi-uusi.jpg');
if (!existsSync(ogf)) bad('og-hero-ovi-uusi.jpg puuttuu');
else { const d = dims(ogf); if (!d || d[0] !== 1200 || d[1] !== 630) bad(`OG-kuvan mitat ${d?.join('x')} ≠ 1200x630`); if (statSync(ogf).size > 200 * 1024) bad('OG-kuva > 200 kt'); }

// --- kultanapin kontrasti (tyylitiedostosta): teksti vs. gradientin molemmat päät ---
const css = readFileSync('src/styles.css', 'utf8');
const rule = (sel) => [...css.matchAll(new RegExp(`${sel.replace(/[.:]/g, '\\$&')}\\{([^}]*)\\}`, 'g'))].map((m) => m[1]).join(';');
for (const [name, sel] of [['.btn.gold', '.btn.gold'], ['.btn.gold:hover', '.btn.gold:hover']]) {
  const body = rule(sel), col = /(?:^|;)color:(#[0-9a-f]{6})/i.exec(body)?.[1], ends = /linear-gradient\(180deg,(#[0-9a-f]{6}),(#[0-9a-f]{6})\)/i.exec(body || rule('.btn.gold'));
  if (!col || !ends) { bad(`${name}: väri/gradientti ei luettavissa`); continue; }
  for (const bg of [ends[1], ends[2]]) { const c = cr(col, bg); if (c < 4.5) bad(`${name}: ${col} / ${bg} kontrasti ${c.toFixed(2)} < 4,5`); else console.log(`${name} ${col} / ${bg}: ${c.toFixed(2)}:1`); }
}

if (errs.length) { console.log('HERO-VIRHEET:\n' + [...new Set(errs)].join('\n')); process.exit(1); }
console.log('hero-tarkistus OK (FI + EN)');
