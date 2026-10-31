// Hallinnan PWA-kuvakkeet sivuston logosta (public/img/favicon.svg) hallinnan tummanvihreällä taustalla.
// Ajo: node scripts/hallinta-pwa-icons.mjs
// Tulokset: booking/admin/icon-192.png, icon-512.png, icon-maskable-512.png, apple-touch-icon.png
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const svg = readFileSync(join(root, 'public/img/favicon.svg'));
const bg = { r: 0x2b, g: 0x3a, b: 0x30, alpha: 1 };
const outDir = join(root, 'booking/admin');

// pad: tyhjä reuna (0.12 = 12 % molemmin puolin). Maskable-kuvakkeessa tärkeä sisältö pysyy keskimmäisessä 80 %:ssa.
const icons = [
  ['icon-192.png', 192, 0.12],
  ['icon-512.png', 512, 0.12],
  ['icon-maskable-512.png', 512, 0.22],
  ['apple-touch-icon.png', 180, 0.12],
];

for (const [name, size, pad] of icons) {
  const inner = Math.round(size * (1 - pad * 2));
  const logo = await sharp(svg, { density: 400 })
    .resize(inner, inner, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();
  const file = join(outDir, name);
  await sharp({ create: { width: size, height: size, channels: 4, background: bg } })
    .composite([{ input: logo, gravity: 'centre' }])
    .flatten({ background: bg })
    .removeAlpha()
    .png({ compressionLevel: 9 })
    .toFile(file);
  const meta = await sharp(file).metadata();
  if (meta.width !== size || meta.height !== size || meta.hasAlpha) throw new Error(`${name}: ${meta.width}x${meta.height} alpha=${meta.hasAlpha}`);
  console.log(`${name} ${meta.width}x${meta.height}`);
}
