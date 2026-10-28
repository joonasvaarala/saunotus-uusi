// Alatunnisteen aukiolo viikko-ohjelman kellonajoista (kb.opening_hours). Ei keksittyjä tunteja:
// vain rivit, joilla on alku ja loppu. Peräkkäiset päivät, joilla on sama väli, yhdistetään.
import { hm } from './lib.mjs';

const bound = (hours) => {
  const by = new Map();
  for (const h of hours || []) {
    if (!h?.opens || !h?.closes || h.weekday < 1 || h.weekday > 7) continue;
    const o = hm(h.opens), c = hm(h.closes);
    if (!o || !c) continue;
    const prev = by.get(h.weekday);
    if (!prev) by.set(h.weekday, { o, c });
    else {
      if (o < prev.o) prev.o = o;
      if (c > prev.c) prev.c = c;
    }
  }
  return by;
};

/** @param {Array} hours kb.hours @param {string[]} days lyhyet viikonpäivät, indeksi 0 = maanantai */
export function openingSummary(hours, days) {
  const by = bound(hours);
  if (!by.size || !Array.isArray(days) || days.length < 7) return '';
  const parts = [];
  let i = 1;
  while (i <= 7) {
    const cur = by.get(i);
    if (!cur) { i++; continue; }
    let j = i;
    while (j < 7) {
      const n = by.get(j + 1);
      if (!n || n.o !== cur.o || n.c !== cur.c) break;
      j++;
    }
    const name = i === j ? days[i - 1] : `${days[i - 1]}–${days[j - 1]}`;
    parts.push(`${name} ${cur.o}–${cur.c}`);
    i = j + 1;
  }
  return parts.join(', ');
}
