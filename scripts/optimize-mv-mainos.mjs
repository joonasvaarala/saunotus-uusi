// Paikkamerkki tai kuvankäsittelijän kuva → public/img/mv-mainos-{w}.webp/jpg.
// Lähde: ensimmäinen kuva kansiossa /workspace/kuvat/musta-viikko/mainoskuva/ jos niitä on,
// muuten sivuston tumma yleinen-saunakuva (public/img/yleinen-1200.webp).
import sharp from 'sharp';
import { readdirSync, mkdirSync } from 'node:fs';
import { join, extname } from 'node:path';

const OUT = 'public/img';
const WIDTHS = [800, 1200];
const CUSTOM = '/workspace/kuvat/musta-viikko/mainoskuva';
const FALLBACK = 'public/img/yleinen-1200.webp';
const ok = new Set(['.jpg', '.jpeg', '.png', '.webp', '.avif', '.tif', '.tiff']);

function pick() {
  try {
    const files = readdirSync(CUSTOM).filter((f) => ok.has(extname(f).toLowerCase()) && !f.startsWith('.'));
    if (files.length) return join(CUSTOM, files.sort()[0]);
  } catch { /* kansiota ei vielä ole */ }
  return FALLBACK;
}

const input = pick();
mkdirSync(OUT, { recursive: true });
const meta = await sharp(input, { limitInputPixels: 300e6 }).rotate().metadata();
const ratio = meta.height / meta.width;
for (const w of WIDTHS.filter((x) => x <= meta.width + 1)) {
  const pipe = () => sharp(input, { limitInputPixels: 300e6 }).rotate().resize({ width: w, withoutEnlargement: true });
  await pipe().jpeg({ quality: 80, mozjpeg: true }).toFile(join(OUT, `mv-mainos-${w}.jpg`));
  await pipe().webp({ quality: 74, effort: 5 }).toFile(join(OUT, `mv-mainos-${w}.webp`));
}
console.log('mv-mainos', input, WIDTHS.join(','), `${meta.width}x${meta.height}`, 'ratio', ratio.toFixed(3));
