// Tuotesivun lyhyt "mitä hintaan kuuluu" ja uima-asuvirke erilleen pitkästä kuvauksesta.
import { visibleText } from './rich-view.js';

const sentences = (html) => visibleText(String(html || '')).replace(/\s+/g, ' ').trim().split(/(?<=[.!?])\s+/).filter(Boolean);

export function includedPlain(html) {
  const hit = sentences(html).find((s) => /sisältää|includes access|includes the|session includes|the session includes/i.test(s));
  if (!hit) return '';
  return hit.length > 420 ? `${hit.slice(0, 400).replace(/\s+\S*$/, '')}…` : hit;
}

export function swimwearPlain(html) {
  return sentences(html).filter((s) => /uima-asu|swimwear|swimsuit/i.test(s)).join(' ');
}

const PUBLIC = new Set(['yleinensauna', 'turvetorstai', 'tunnin-vuoro']);
const OPTIONAL = new Set(['miestensauna-2', 'naistensauna', 'hiljainen-sauna']);

/** Vahvistuksen uima-asuohje tuotteen mukaan. null = ei erillistä virkettä (esim. hoito). */
export function swimwearKey(slug) {
  if (PUBLIC.has(slug)) return 'swimPublic';
  if (OPTIONAL.has(slug)) return 'swimOptional';
  return null;
}
