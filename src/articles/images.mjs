// Artikkelikuvien responsiiviset variantit rakennuksessa (sopimus §16.5.5: Storage-transformaatioita ei oleteta).
// Lataa alkuperäiset (Storage julkinen URL tai testifixture https://fixture.example/…), tekee avif+webp leveyksille ≤ alkuperäinen → <outDir>/img/articles/<tunnus>-<leveys>.<ext>.
// Epäonnistuessaan (ei sharpia, lataus ei onnistu) kuva jää pois kartasta → sivupohja käyttää alkuperäistä URL:ia (width/height/alt silti mukana).
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

export const FIXTURE_HOST = 'https://fixture.example/';
export const imgId = (url) => createHash('sha1').update(url).digest('hex').slice(0, 12);

export function makeFetchImage({ fixtureDir } = {}) {
  return async (url) => {
    if (url.startsWith(FIXTURE_HOST)) {
      if (!fixtureDir) throw new Error('fixture-kuvakansio puuttuu');
      return readFileSync(join(fixtureDir, url.split('/').pop()));
    }
    const res = await fetch(url, { signal: AbortSignal.timeout(20000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    if (!/^image\//.test(res.headers.get('content-type') || '')) throw new Error('ei kuva (content-type ' + res.headers.get('content-type') + ')');
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length > 15 * 1024 * 1024) throw new Error('kuva liian suuri');
    return buf;
  };
}

/** @returns {Promise<Map<string,{id:string,widths:number[]}>>} */
export async function prepareImages({ images, outDir, cacheDir, widths, fetchImage, log = console, loadSharp = async () => (await import('sharp')).default }) {
  const result = new Map();
  let sharp;
  try { sharp = await loadSharp(); } catch (err) { log.warn?.(`articles: VAROITUS: sharp ei käytettävissä (${err.message}); kuvat käyttävät alkuperäisiä Storage-osoitteita ilman srcset-versioita`); return result; }
  const dir = join(outDir, 'img', 'articles');
  mkdirSync(dir, { recursive: true });
  const uniq = new Map(images.filter((i) => i?.url).map((i) => [i.url, i]));
  for (const [url, im] of uniq) {
    const id = imgId(url);
    try {
      const raw = join(cacheDir || '', 'img', id + '.bin');
      let buf;
      if (cacheDir && existsSync(raw)) buf = readFileSync(raw);
      else { buf = await fetchImage(url); if (cacheDir) { mkdirSync(join(cacheDir, 'img'), { recursive: true }); writeFileSync(raw, buf); } }
      const meta = await sharp(buf, { limitInputPixels: 100e6 }).metadata();
      const srcW = Math.min(meta.width || im.width || Infinity, im.width || Infinity);
      let ws = widths.filter((w) => w <= srcW);
      if (!ws.length) ws = [srcW];
      for (const w of ws) {
        const pipe = () => sharp(buf, { limitInputPixels: 100e6 }).rotate().resize({ width: w, withoutEnlargement: true });
        writeFileSync(join(dir, `${id}-${w}.webp`), await pipe().webp({ quality: 78 }).toBuffer());
        writeFileSync(join(dir, `${id}-${w}.avif`), await pipe().avif({ quality: 55, effort: 3 }).toBuffer());
      }
      result.set(url, { id, widths: ws });
    } catch (err) { log.warn?.(`articles: VAROITUS: kuvaa ei voitu käsitellä (${url}): ${err.message}; käytetään alkuperäistä osoitetta`); }
  }
  return result;
}
