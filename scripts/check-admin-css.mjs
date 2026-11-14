// YHT-02: hallinnan tyylitarkistus. Laskee admin.css:n heksavärit (paitsi :root-muuttujat) ja fonttikoot asteikon ulkopuolelta.
// Uudet värit ja koot kuuluvat muuttujiin (booking/shared/tokens.css). Määrä saa vain pienentyä: kasvu → virhe; kun määrä pienenee, laske BASELINE.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
export const BASELINE = { hex: 218, size: 21 };   // 14.11.2026
const SCALE = new Set([12, 13, 14, 15, 16, 18, 19, 20, 22, 24, 28, 32]);
export function checkAdminCss(text) {
  const body = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/:root\{[^}]*\}/g, '');
  const hex = body.match(/#[0-9a-fA-F]{3,8}\b/g) || [];
  const sizes = [...body.matchAll(/font(?:-size)?:[^;}]*?(\d+(?:\.\d+)?)px/g)].map((m) => Number(m[1])).filter((n) => !SCALE.has(n));
  return { hex: hex.length, size: sizes.length };
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const r = checkAdminCss(readFileSync(new URL('../booking/admin/admin.css', import.meta.url), 'utf8'));
  const over = Object.keys(BASELINE).filter((k) => r[k] > BASELINE[k]);
  console.log(`admin.css: heksavärejä ${r.hex}/${BASELINE.hex}, asteikon ulkopuolisia fonttikokoja ${r.size}/${BASELINE.size}`);
  if (over.length) { console.error(`Uusia ${over.join(', ')}: käytä tokens.css-muuttujia (--c-*, --fs-*).`); process.exit(1); }
}
