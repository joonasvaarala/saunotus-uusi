// ES-moduulien suhteelliset importit julkaisua varten (scripts/build-pages.mjs ja testit).
// Kattaa muodot  import x from './a.js'  ·  import './a.js'  ·  export { x } from './a.js'  ·  import('./a.js').
// HALL-TILAUS-02: aiempi regex ei osunut dynaamiseen import('./a.js'):iin, joten hallinta latasi saman moduulin
// kahdesti (versioituna ja ilman) ja order-open.js:n paluutila katosi ("← Takaisin" palasi aina Tilauksiin).
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';

const REL = /(\b(?:from|import)\s*\(?\s*)(['"])(\.{1,2}\/[^'"?]+\.js)\2/g;
const ANY_REL = /(?:\bfrom|\bimport)\s*\(?\s*(['"])(\.{1,2}\/[^'"?]+\.js)(\?[^'"]*)?\1/g;

/** Lisää versiotunnuksen (esim. '?v=abc') jokaiseen versioimattomaan suhteelliseen .js-importtiin. */
export function versionImports(text, ver) {
  let n = 0;
  const out = text.replace(REL, (_, a, q, u) => { n++; return `${a}${q}${u}${ver}${q}`; });
  return { text: out, count: n };
}

/** Suhteelliset .js-importit: [{ spec, query }] (query = '?v=…' tai ''). */
export function relativeImports(text) {
  return [...text.matchAll(ANY_REL)].map((m) => ({ spec: m[2], query: m[3] || '' }));
}

/** Versioimattomat suhteelliset .js-importit (build epäonnistuu, jos näitä jää distiin). */
export function unversionedImports(text) {
  return relativeImports(text).filter((x) => !x.query).map((x) => x.spec);
}

/** Kansion .js-tiedostojen importit, jotka osoittavat puuttuvaan tiedostoon: ['tiedosto: spec', …]. */
export function missingImportTargets(dir, { recursive = true } = {}) {
  const out = [];
  (function walk(d) {
    for (const n of readdirSync(d)) {
      const p = join(d, n);
      if (statSync(p).isDirectory()) { if (recursive) walk(p); continue; }
      if (!n.endsWith('.js')) continue;
      for (const { spec } of relativeImports(readFileSync(p, 'utf8'))) {
        if (!statSync(resolve(d, spec), { throwIfNoEntry: false })) out.push(`${relative(dir, p)}: ${spec}`);
      }
    }
  })(dir);
  return out;
}

/** Moduulipuu lähdekoodissa entry-tiedostosta alkaen: suhteelliset polut repon juuresta (Set). */
export function moduleGraph(root, entry) {
  const seen = new Set();
  (function visit(rel) {
    if (seen.has(rel)) return;
    seen.add(rel);
    const abs = join(root, rel);
    for (const { spec } of relativeImports(readFileSync(abs, 'utf8'))) visit(relative(root, resolve(dirname(abs), spec)));
  })(entry);
  return seen;
}
