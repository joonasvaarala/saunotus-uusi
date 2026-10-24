// Yksikkö / monikko kaupan teksteissä (Joonas 24.10.2026: "1 guests", "1 henkilöä"). Julkaistuja site_texts-tekstejä ei muuteta:
// monikkomuoto on edelleen perusavain (esim. ui.shop.ritual_summary), ja yksikkö haetaan valinnaisesta rinnakkaisavaimesta
// <avain>One / <avain>_one (esim. ritualSummaryOne → ui.shop.ritual_summary_one). Jos sitä ei ole, käytetään perusavainta (ennallaan).
// Lukumäärä valitaan muuttujista n / m / h / hours / minutes / months (ensimmäinen annettu). Säännöt: Intl.PluralRules; varalla n === 1.
const RULES = new Map();
export const COUNT_VARS = Object.freeze(['n', 'm', 'h', 'hours', 'minutes', 'months']);
export function isOne(lang, n) {
  const v = Number(n);
  if (n == null || n === '' || !Number.isFinite(v)) return false;
  try {
    const loc = lang === 'en' ? 'en-GB' : 'fi-FI';
    if (!RULES.has(loc)) RULES.set(loc, new Intl.PluralRules(loc));
    return RULES.get(loc).select(v) === 'one';
  } catch { return v === 1; }
}
/** Lukumäärä muuttujista (ensimmäinen COUNT_VARS-muuttuja, jolla on arvo) tai null. */
export const countOf = (vars) => { if (!vars || typeof vars !== 'object') return null; for (const k of COUNT_VARS) if (vars[k] != null && vars[k] !== '') return vars[k]; return null; };
/** Avain, jota käytetään: yksikössä <key>One / <key>_one, jos sellainen on sanakirjassa (dicts: kieli, sitten varakieli); muuten key. */
export function oneKey(key, lang, vars, ...dicts) {
  const c = countOf(vars);
  if (c == null || !isOne(lang, c)) return key;
  for (const k of [`${key}One`, `${key}_one`]) if (dicts.some((d) => d && d[k] != null)) return k;
  return key;
}
/** Valitsee yksikkö- tai monikkomuodon suoraan (koodin omat funktiotekstit). */
export const pl = (lang, n, one, other) => (isOne(lang, n) ? one : other);
