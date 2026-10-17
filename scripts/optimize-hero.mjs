// Etusivun herokuva (ovi): tuottaa public/img/hero-ovi-uusi*.avif/webp/jpg (jpg = varakuva vanhoille selaimille), og-hero-ovi-uusi.jpg ja content/hero.json (mitat).
// Lähteet (ei repossa, koska ovat isoja): desktop 2560x1200 ja mobiili 1200x1500 (4:5).
//   HERO_DESKTOP=/polku/hero-ovi-uusi.jpg HERO_MOBILE=/polku/hero-ovi-uusi-mobiili.jpg npm run hero
// Oletuspolut: assets-src/hero-ovi-uusi.jpg ja assets-src/hero-ovi-uusi-mobiili.jpg. Tuotos on sitoutettu repoon.
// Tavoitekoot: desktop ≲300 kt (avif 1920 ≈243 kt, 2560 ≈266 kt, webp 1920 ≈284 kt, jpg 1920 ≈277 kt), mobiili ≲200 kt (avif 1200 ≈172 kt, jpg 720 ≈113 kt).
import sharp from 'sharp';
import { writeFileSync, mkdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
const OUT = 'public/img';
mkdirSync(OUT, { recursive: true });
const SRC = {
  desktop: process.env.HERO_DESKTOP || 'assets-src/hero-ovi-uusi.jpg',
  mobile: process.env.HERO_MOBILE || 'assets-src/hero-ovi-uusi-mobiili.jpg',
};
// laatu leveyksittäin (kuva on yksityiskohtaista puuta → tiedostokoot pidetään kurissa laadulla)
const SPEC = {
  'hero-ovi-uusi': { src: SRC.desktop, avif: { 1280: 46, 1920: 44, 2560: 35 }, webp: { 1280: 66, 1920: 55 }, jpg: { 1280: 68, 1920: 66 } },
  'hero-ovi-uusi-mobiili': { src: SRC.mobile, avif: { 480: 46, 720: 46, 1200: 36 }, webp: { 480: 66, 720: 66 }, jpg: { 480: 70, 720: 68 } },
};
const meta = {};
for (const [id, s] of Object.entries(SPEC)) {
  const m = await sharp(s.src).metadata();
  const aw = Object.keys(s.avif).map(Number), ww = Object.keys(s.webp).map(Number), jw = Object.keys(s.jpg).map(Number);
  const top = Math.max(...aw);
  if (m.width !== top) throw new Error(`${id}: lähteen leveys ${m.width}, odotettiin ${top}`);
  meta[id] = { w: top, h: m.height, avif: aw, webp: ww, jpg: jw };
  for (const [ext, q] of [['avif', s.avif], ['webp', s.webp], ['jpg', s.jpg]]) {
    for (const [w, quality] of Object.entries(q)) {
      const pipe = sharp(s.src).resize({ width: +w, withoutEnlargement: true });
      const file = join(OUT, `${id}-${w}.${ext}`);
      await (ext === 'avif' ? pipe.avif({ quality, effort: 6 }) : ext === 'webp' ? pipe.webp({ quality, effort: 6 }) : pipe.jpeg({ quality, mozjpeg: true })).toFile(file);
      console.log(file, (statSync(file).size / 1024).toFixed(0), 'kt');
    }
  }
}
// OG 1200x630: rajaus desktop-kuvasta niin, että ovi (x ≈ 20–73 %) pysyy keskellä
const dm = await sharp(SRC.desktop).metadata();
const cw = Math.round(dm.height * 1200 / 630), left = Math.max(0, Math.min(dm.width - cw, Math.round(0.465 * dm.width - cw / 2)));
await sharp(SRC.desktop).extract({ left, top: 0, width: cw, height: dm.height }).resize(1200, 630).jpeg({ quality: 76, mozjpeg: true }).toFile(join(OUT, 'og-hero-ovi-uusi.jpg'));
console.log('og-hero-ovi-uusi.jpg', (statSync(join(OUT, 'og-hero-ovi-uusi.jpg')).size / 1024).toFixed(0), 'kt');
writeFileSync('content/hero.json', JSON.stringify(meta, null, 1) + '\n');
console.log('valmis');
