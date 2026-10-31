// IMAGE_TRANSFORMS=off: julkaistussa distissä ei saa olla yhtään muunnosrajapinnan osoitetta.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const TEXT = /\.(html|js|mjs|json|css|txt|xml|svg)$/i;
const NEEDLE = '/render/image/';

/** Palauttaa suhteelliset polut, joiden tekstissä on muunnosrajapinnan osoite. */
export function findRenderImageUrls(dir) {
  const hits = [];
  (function walk(d) {
    for (const name of readdirSync(d)) {
      const p = join(d, name);
      if (statSync(p).isDirectory()) { walk(p); continue; }
      if (!TEXT.test(name)) continue;
      let text;
      try { text = readFileSync(p, 'utf8'); } catch { continue; }
      if (text.includes(NEEDLE)) hits.push(p.slice(dir.length).replace(/\\/g, '/') || name);
    }
  })(dir);
  return hits;
}

export function assertNoRenderImageUrls(dir) {
  const hits = findRenderImageUrls(dir);
  if (!hits.length) return;
  console.error(`kuvaosoitteissa on /render/image/ vaikka IMAGE_TRANSFORMS on pois (${hits.length}):\n  ${hits.slice(0, 30).join('\n  ')}`);
  process.exit(1);
}
