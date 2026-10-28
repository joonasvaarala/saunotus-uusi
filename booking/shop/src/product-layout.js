// Vahvistussivun uima-asuohje tuotteen mukaan. (Tuotesivun ingressi: short-desc.js leadShort, Joonas 28.10.2026.)
const PUBLIC = new Set(['yleinensauna', 'turvetorstai', 'tunnin-vuoro']);
const OPTIONAL = new Set(['miestensauna-2', 'naistensauna', 'hiljainen-sauna']);

/** Vahvistuksen uima-asuohje tuotteen mukaan. null = ei erillistä virkettä (esim. hoito). */
export function swimwearKey(slug) {
  if (PUBLIC.has(slug)) return 'swimPublic';
  if (OPTIONAL.has(slug)) return 'swimOptional';
  return null;
}
