// Edge-funktioiden asiakasnäkyvät tekstit (sopimus §18, osa 3 PR 3): kerää repon oletukset (booking/supabase/functions/*/texts.ts) tuontiriveiksi.
// HUOM: taulukot ovat TypeScriptiä (vain tyyppisyntaksia) → tämä moduuli vaatii Noden tyyppien poiston (22.18+); staattisen sivuston build (Node 20) ei tuo tätä.
import { EMAIL_TEXTS } from '../booking/supabase/functions/send-emails/texts.ts';
import { GIFT_CARD_PDF_TEXTS } from '../booking/supabase/functions/gift-card-pdf/texts.ts';
import { RECEIPT_PDF_TEXTS } from '../booking/supabase/functions/receipt-pdf/texts.ts';
import { MOBILEPAY_START_TEXTS } from '../booking/supabase/functions/mobilepay-start/texts.ts';

/** [lähdetiedosto, taulukko, avainprefiksi(t), mistä funktio hakee] */
export const FUNCTION_TABLES = [
  ['send-emails/texts.ts', EMAIL_TEXTS, 'email.'],
  ['gift-card-pdf/texts.ts', GIFT_CARD_PDF_TEXTS, 'email.gift_card_pdf.'],
  ['receipt-pdf/texts.ts', RECEIPT_PDF_TEXTS, 'email.receipt_pdf.'],
  ['mobilepay-start/texts.ts', MOBILEPAY_START_TEXTS, 'ui.mobilepay.'],
];
export const tokensOf = (text) => [...new Set([...String(text).matchAll(/\{\{[^{}]*\}\}/g)].map((m) => m[0]))];
export const maxLenFor = (fi, en = '') => Math.max(200, Math.ceil((Math.max(fi.length, en.length) * 2.5) / 50) * 50);

/** @returns {{key:string, lang:'fi'|'en', text:string, class:'normal'|'protected', src:string}[]} FI ennen EN avaimittain, avainjärjestys = taulukon järjestys */
export function collectFunctionDefaults() {
  const out = [], seen = new Set();
  for (const [src, table] of FUNCTION_TABLES) {
    for (const [key, def] of Object.entries(table)) {
      if (seen.has(key)) throw new Error(`kaksoisavain ${key} (${src})`);
      seen.add(key);
      for (const lang of ['fi', 'en']) out.push({ key, lang, text: def[lang], class: def.cls === 'protected' ? 'protected' : 'normal', src, max: def.max });
    }
  }
  return out;
}
