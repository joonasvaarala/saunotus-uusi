// Kopioi kuvankäsittelijän tumma toimitus public/img/mv-mainos-{desktop,mobiili}[@2x].{jpg,webp}.
// Lähde: /workspace/kuvat/musta-viikko/mainoskuva/musta-viikko-{desktop,mobiili}[@2x].{jpg,webp}.
// Tiedostot on jo optimoitu (desktop 1x jpg ~38 kt, alle 250 kt); ei uudelleenpakata.
import { copyFileSync, existsSync, mkdirSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';

const OUT = 'public/img';
const SRC = '/workspace/kuvat/musta-viikko/mainoskuva';
const KIND = ['desktop', 'mobiili'];
const SCALE = ['', '@2x'];
const EXT = ['jpg', 'webp'];

mkdirSync(OUT, { recursive: true });
for (const kind of KIND) for (const scale of SCALE) for (const ext of EXT) {
  const src = join(SRC, `musta-viikko-${kind}${scale}.${ext}`);
  if (!existsSync(src)) throw new Error(`puuttuva lähdekuva: ${src}`);
  copyFileSync(src, join(OUT, `mv-mainos-${kind}${scale}.${ext}`));
}
// Poista vanha paikkamerkki (leveyspohjaiset tiedostot).
for (const w of [800, 1200]) for (const ext of EXT) {
  const stale = join(OUT, `mv-mainos-${w}.${ext}`);
  if (existsSync(stale)) unlinkSync(stale);
}
console.log('mv-mainos', SRC, 'desktop 1600x700 + @2x, mobiili 900x1100 + @2x');
