// Kopioi kuvankäsittelijän v3-toimitus public/img/mv-mainos-{desktop,mobiili}[@2x].{jpg,webp}.
// Lähde: /workspace/kuvat/musta-viikko/mainoskuva-v3/musta-viikko-v3-{desktop,mobiili}[@2x].{jpg,webp}.
// Desktop/mobiili 1x jpg pakataan alle 250 kt tarvittaessa (laatu 89).
import { copyFileSync, existsSync, mkdirSync, unlinkSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const OUT = 'public/img';
const SRC = '/workspace/kuvat/musta-viikko/mainoskuva-v3';
const KIND = ['desktop', 'mobiili'];
const SCALE = ['', '@2x'];
const EXT = ['jpg', 'webp'];

mkdirSync(OUT, { recursive: true });
for (const kind of KIND) for (const scale of SCALE) for (const ext of EXT) {
  const src = join(SRC, `musta-viikko-v3-${kind}${scale}.${ext}`);
  if (!existsSync(src)) throw new Error(`puuttuva lähdekuva: ${src}`);
  copyFileSync(src, join(OUT, `mv-mainos-${kind}${scale}.${ext}`));
}
// 1x jpg alle 250 kt
const pack = `
from pathlib import Path
from PIL import Image
MAX = 250_000
for name, size in [('mv-mainos-desktop.jpg', (1600, 700)), ('mv-mainos-mobiili.jpg', (900, 1100))]:
    path = Path('public/img') / name
    im = Image.open(path)
    assert im.size == size, (name, im.size)
    if path.stat().st_size <= MAX:
        continue
    icc = im.info.get('icc_profile')
    if im.mode != 'RGB':
        im = im.convert('RGB')
    for q in range(89, 69, -1):
        kw = dict(format='JPEG', quality=q, optimize=True, progressive=True, subsampling=0)
        if icc:
            kw['icc_profile'] = icc
        im.save(path, **kw)
        if path.stat().st_size <= MAX:
            break
    else:
        raise SystemExit(f'ei mennyt alle 250 kt: {name} {path.stat().st_size}')
`
r = spawnSync('python3', ['-c', pack], { encoding: 'utf8' });
if (r.status !== 0) {
  console.error(r.stdout, r.stderr);
  throw new Error('jpg-pakkaus epäonnistui');
}
for (const w of [800, 1200]) for (const ext of EXT) {
  const stale = join(OUT, `mv-mainos-${w}.${ext}`);
  if (existsSync(stale)) unlinkSync(stale);
}
const desk = statSync(join(OUT, 'mv-mainos-desktop.jpg')).size;
console.log('mv-mainos v3', SRC, 'desktop 1600x700 + @2x, mobiili 900x1100 + @2x; desktop 1x jpg', desk, 'tavua');
