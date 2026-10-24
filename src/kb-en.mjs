// booking_151 / Kääntäjän en_sources: englanninkieliset kb-tekstit suomenkielisen rivin _en-sarakkeista.
// Sivujen listat (content/pages/*.json) viittaavat AINA suomenkielisiin kb-id:ihin; kieliversio valitaan tässä:
//   1) suomenkielisen rivin _en-kentät (molemmat: kysymys+vastaus / otsikko+teksti), muuten
//   2) vanha erillinen englanninkielinen rivi (LEGACY_*: FAQ 19–23, ehdot 16–24, 26), kunnes _en-kentät on täytetty, muuten
//   3) suomenkielinen rivi (lang: 'fi', jotta sivu voi merkitä sen lang="fi"-attribuutilla).
// Vanhoja englanninkielisiä rivejä ei listata sivuilla erikseen, joten sama asia ei voi näkyä kahdesti.
import { kb } from './lib.mjs';

/** Suomenkielinen kb.faq-id → vanha erillinen englanninkielinen rivi (sama kysymys). */
export const LEGACY_FAQ_EN = Object.freeze({ 1: 19, 8: 20, 9: 21, 11: 22, 10: 23 });
/** Suomenkielinen kb.policies-id → vanha erillinen englanninkielinen rivi (sama ehtokohta). */
export const LEGACY_POLICY_EN = Object.freeze({ 1: 16, 2: 17, 3: 18, 5: 19, 6: 20, 8: 21, 10: 22, 11: 23, 12: 24, 25: 26 });

const has = (s) => typeof s === 'string' && s.trim() !== '';

/** UKK-kohta kielellä lang: { id, question, answer, lang } tai null. */
export function faqFor(id, lang, data = kb) {
  const fi = data.faq.find((x) => x.id === id);
  if (!fi) return null;
  if (lang !== 'en') return { id, question: fi.question, answer: fi.answer, lang: fi.language || 'fi' };
  if (has(fi.question_en) && has(fi.answer_en)) return { id, question: fi.question_en, answer: fi.answer_en, lang: 'en' };
  const old = data.faq.find((x) => x.id === LEGACY_FAQ_EN[id] && x.language === 'en');
  if (old) return { id, question: old.question, answer: old.answer, lang: 'en' };
  return { id, question: fi.question, answer: fi.answer, lang: fi.language || 'fi' };
}

/** Ehtokohta kielellä lang: { id, title, body, lang } tai null (myös sisäiset). */
export function policyFor(id, lang, data = kb) {
  const fi = data.policies.find((x) => x.id === id);
  if (!fi || fi.internal) return null;
  if (lang !== 'en') return { id, title: fi.title, body: fi.body, lang: fi.language || 'fi' };
  if (has(fi.title_en) && has(fi.body_en)) return { id, title: fi.title_en, body: fi.body_en, lang: 'en' };
  const old = data.policies.find((x) => x.id === LEGACY_POLICY_EN[id] && x.language === 'en' && !x.internal);
  if (old) return { id, title: old.title, body: old.body, lang: 'en' };
  return { id, title: fi.title, body: fi.body, lang: fi.language || 'fi' };
}

/** Tapahtumapäivän aikateksti: EN suosii time_text_en:ää, muuten suomenkielinen teksti koneellisella enTime-muunnoksella. */
export function eventTimeFor(d, lang, enTime) {
  if (lang === 'en') return has(d.time_text_en) ? d.time_text_en : (has(d.time_text) ? enTime(d.time_text) : '');
  return has(d.time_text) ? d.time_text : '';
}
