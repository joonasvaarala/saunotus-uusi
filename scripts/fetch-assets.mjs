// Lataa lähdekuvat live-sivulta (uusi.saunotus.com) ja Johku-CDN:stä kansioon assets-src/.
import { readFileSync, mkdirSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const manifest = JSON.parse(readFileSync('content/images.manifest.json', 'utf8'));
const OUT = 'assets-src';
mkdirSync(OUT, { recursive: true });
const urlFor = (src) => {
  const [kind, rest] = src.split(':');
  if (kind === 'uusi') return `https://uusi.saunotus.com/wp-content/uploads/${rest}`;
  if (kind === 'johku') return `https://cdn.johku.com/sipoonjoenperinnesauna/largefiles/${rest}.jpg`;
  throw new Error('tuntematon lähde ' + src);
};
const all = [...manifest.images, ...manifest.icons, ...manifest.svg];
for (const it of all) {
  const ext = it.src.split('.').pop();
  const file = join(OUT, `${it.id}.${ext}`);
  if (existsSync(file)) continue;
  const res = await fetch(urlFor(it.src), { headers: { 'User-Agent': 'Mozilla/5.0 (Koodari asset fetch)' } });
  if (!res.ok) { console.error('VIRHE', res.status, it.src); process.exitCode = 1; continue; }
  writeFileSync(file, Buffer.from(await res.arrayBuffer()));
  console.log('ok', file);
}
