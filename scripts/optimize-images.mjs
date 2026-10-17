// Tuottaa public/img/ -kuvat (avif + webp, useita leveyksiä) ja content/images.json (mitat).
import sharp from 'sharp';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
const manifest = JSON.parse(readFileSync('content/images.manifest.json', 'utf8'));
const SRC = 'assets-src', OUT = 'public/img';
mkdirSync(OUT, { recursive: true });
const find = (id) => readdirSync(SRC).find((f) => f.startsWith(id + '.'));
const meta = {};
for (const it of manifest.images) {
  const input = join(SRC, find(it.id));
  const base = sharp(input, { limitInputPixels: 300e6 }).rotate();
  const m = await base.metadata();
  const ratio = m.height / m.width;
  const widths = it.widths.filter((w) => w <= m.width + 1);
  if (!widths.length) widths.push(m.width);
  meta[it.id] = { w: widths[widths.length - 1], h: Math.round(widths[widths.length - 1] * ratio), widths };
  for (const w of widths) {
    const pipe = () => sharp(input, { limitInputPixels: 300e6 }).rotate().resize({ width: w, withoutEnlargement: true });
    await pipe().avif({ quality: 52, effort: 5 }).toFile(join(OUT, `${it.id}-${w}.avif`));
    await pipe().webp({ quality: 74, effort: 5 }).toFile(join(OUT, `${it.id}-${w}.webp`));
  }
  console.log('kuva', it.id, widths.join(','));
}
for (const it of manifest.icons) {
  const input = join(SRC, find(it.id));
  await sharp(input).resize(it.size, it.size, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } }).webp({ quality: 85, alphaQuality: 90 }).toFile(join(OUT, `${it.id}.webp`));
  meta[it.id] = { w: it.size, h: it.size, widths: [it.size] };
}
for (const it of manifest.svg) copyFileSync(join(SRC, find(it.id)), join(OUT, `${it.id}.svg`));
// OG-kuvat 1200x630 (jpg) – sivujen meta.og-tunnisteista (hero-ovi-uusi: npm run hero)
for (const id of ['ovi-kaiverrus', 'saunotus', 'saunotus-selka', 'palju']) {
  await sharp(join(SRC, find(id)), { limitInputPixels: 300e6 }).rotate().resize(1200, 630, { fit: 'cover', position: 'attention' }).jpeg({ quality: 80, mozjpeg: true }).toFile(join(OUT, `og-${id}.jpg`));
}
writeFileSync('content/images.json', JSON.stringify(meta, null, 1));
console.log('valmis');
