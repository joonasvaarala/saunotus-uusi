// Kaupan kovakoodatut tekstisanakirjat (i18n.js, order-texts.js, gift-texts.js, hold-texts.js, pay-choices-texts.js, mobilepay-texts.js, options-texts.js)
// sivutekstien avaimiksi (sopimus §18, osa 3). Yksi lähde kahteen tarkoitukseen:
//   1) collectDefaults() → avain + kieli + repon oletusteksti (tuontitiedoston generointi: scripts/site-texts-extract-shop.mjs; testit)
//   2) applySiteTexts(rows, …) → peittää sanakirjat tietokannan teksteillä (public_get_site_texts → booking/site-texts.json). Rivi puuttuu / paikkamerkki ei täyty → repon oletusteksti
//      (ulkoasu ei muutu; osa 5 poistaa oletukset kun avaimet on vahvistettu tuotannossa). Vain SAMAN kielen rivi kelpaa (ei fi→en-ristiin: en-oletus säilyy).
// Avainnimeäminen (§18.2): ui.<alue>.<nimi>; camelCase → snake_case; pisteet säilyvät (hold-texts: err.order_expired → ui.hold.err.order_expired).
//   i18n.js: ylätaso → ui.shop.*; tr.* → ui.treatment.*; tr.errors.<koodi> → ui.checkout.error_<koodi>; errors.<koodi> → ui.shop.error_<koodi>.
// Paikkamerkit: {n} → {{var:n}} (kutsuparametri); puhelinnumero → {{var:phone}} (sivuston yhteystiedoista, S.phone).
import { T } from './i18n.js';
import { isOne } from './plural.js';
import { PHONE_DISPLAY_FI } from './phone.js';
import { OT } from './order-texts.js';
import { GT } from './gift-texts.js';
import { HT } from './hold-texts.js';
import { PT } from './pay-choices-texts.js';
import { MT } from './mobilepay-texts.js';
import { VT } from './vismapay-texts.js';
import { OPT } from './options-texts.js';
import { PLT } from './pay-link-texts.js';
import { makeContext, fillPlaceholders, indexTexts, PlaceholderError, LANGS } from './site-texts-logic.js';

export const PHONE_LITERAL = PHONE_DISPLAY_FI;   // fi-oletuksen numero → {{var:phone}} (en-oletuksessa kansainvälinen muoto jää kirjoitettuna, kuten tietokannassa)
const DICTS = [
  { id: 'T', area: 'shop', dict: T }, { id: 'OT', area: 'order', dict: OT }, { id: 'GT', area: 'gift', dict: GT }, { id: 'HT', area: 'hold', dict: HT },
  { id: 'PT', area: 'paychoice', dict: PT }, { id: 'MT', area: 'mobilepay', dict: MT }, { id: 'VT', area: 'vismapay', dict: VT }, { id: 'OPT', area: 'option', dict: OPT }, { id: 'PLT', area: 'paylink', dict: PLT },
];
// Ei tuoda: tekninen URL-polku (ei asiakasnäkyvä teksti). gift-logic.js SOURCE_LABELS on vain varaetiketti: nimet tulevat palvelimelta (public_resolve/_vc_sources: source_label, label_en) – jää koodiin.
export const EXCLUDED = new Set(['T:directionsUrl']);
// Funktiolehdet → mallipohjat (monikko: .one / .other). one: { arg, fi, en } = valinnainen yksikkömalli avaimella <avain>_one (kun arg on 1;
// Intl.PluralRules, plural.js); julkaistu perusavain pysyy monikkona. Tietokannasta puuttuva _one → tämä oletus. Paikkamerkit {{var:<argumentti>}}; vastaavuus alkuperäisiin funktioihin testataan.
export const FN_SPECS = {
  'T:daySessions': { args: ['n'], plural: true, fi: { one: '1 vapaa vuoro', other: '{{var:n}} vapaata vuoroa' }, en: { one: '1 session available', other: '{{var:n}} sessions available' } },
  'T:timesFree': { args: ['n'], plural: true, fi: { one: '1 aika vapaana', other: '{{var:n}} aikaa vapaana' }, en: { one: '1 time available', other: '{{var:n}} times available' } },
  'T:freeSpots': { args: ['n'], fi: '{{var:n}} vapaana', en: '{{var:n}} left' },
  'T:payHold': { args: ['m'], one: { arg: 'm', fi: 'Paikkaa pidetään {{var:m}} minuutin ajan maksun odottaessa.', en: 'Your spot is held for {{var:m}} minute while payment is pending.' }, fi: 'Paikkaa pidetään {{var:m}} minuuttia maksun odottaessa.', en: 'Your spot is held for {{var:m}} minutes while payment is pending.' },
  'T:included': { args: ['n'], plural: true, fi: { one: 'sis. {{var:n}} hlö', other: 'sis. {{var:n}} hlö' }, en: { one: 'incl. {{var:n}} guest', other: 'incl. {{var:n}} guests' } },
  'T:extra': { args: ['p'], fi: 'lisähenkilö +{{var:p}}', en: 'extra guest +{{var:p}}' },
  'T:changeInfo': { args: ['h', 'dl'],
    one: { arg: 'h', fi: 'Voit siirtää varauksen toiselle vapaalle vuorolle tai muuttaa henkilömäärää viimeistään {{var:h}} tunti ennen vuoron alkua (nyt viimeistään {{var:dl}}). Varauksen peruutus: ota yhteyttä sähköpostilla, niin henkilökunta peruu varauksen.',
      en: 'You can move your booking to another available session or change the number of guests up to {{var:h}} hour before the session starts (currently by {{var:dl}} at the latest). To cancel, please email us and our staff will cancel the booking.' },
    fi: 'Voit siirtää varauksen toiselle vapaalle vuorolle tai muuttaa henkilömäärää viimeistään {{var:h}} tuntia ennen vuoron alkua (nyt viimeistään {{var:dl}}). Varauksen peruutus: ota yhteyttä sähköpostilla, niin henkilökunta peruu varauksen.',
    en: 'You can move your booking to another available session or change the number of guests up to {{var:h}} hours before the session starts (currently by {{var:dl}} at the latest). To cancel, please email us and our staff will cancel the booking.' },
  'T:changeLocked': { args: ['h'], fi: 'Varausta ei voi enää muuttaa verkossa (muutos vähintään {{var:h}} h ennen vuoron alkua). Peruutukset ja muutokset: ota yhteyttä sähköpostilla',
    en: 'This booking can no longer be changed online (changes up to {{var:h}} h before the start). For cancellations and changes please email us at' },
  'T:tooLate': { args: ['h'], fi: 'Alkaa alle {{var:h}} h päästä', en: 'Starts in under {{var:h}} h' },
  'T:tr.maxPersons': { args: ['n'], one: { arg: 'n', fi: 'Enintään {{var:n}} henkilö.', en: 'Up to {{var:n}} guest.' }, fi: 'Enintään {{var:n}} henkilöä.', en: 'Up to {{var:n}} guests.' },
  'T:tr.selected': { args: ['when', 'n', 'price'], one: { arg: 'n', fi: 'Valittu: {{var:when}} · {{var:n}} hlö · {{var:price}}', en: 'Selected: {{var:when}} · {{var:n}} guest · {{var:price}}' }, fi: 'Valittu: {{var:when}} · {{var:n}} hlö · {{var:price}}', en: 'Selected: {{var:when}} · {{var:n}} guests · {{var:price}}' },
};

const snake = (s) => s.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
const flat = (o, p = []) => Object.entries(o).flatMap(([k, v]) => (v && typeof v === 'object' && !Array.isArray(v) ? flat(v, [...p, k]) : [[[...p, k], v]]));
const dictKey = (d, parts) => {
  const seg = parts.map(snake);
  if (d.id === 'T') {
    if (parts[0] === 'tr' && parts[1] === 'errors' && parts.length === 3) return `ui.checkout.error_${seg[2]}`;
    if (parts[0] === 'errors' && parts.length === 2) return `ui.shop.error_${seg[1]}`;
    if (parts[0] === 'tr') return `ui.treatment.${seg.slice(1).join('.')}`;
  }
  return `ui.${d.area}.${seg.join('.')}`;
};

/** Alkuperäiset oletukset heti moduulin latauksessa (ennen peittoa). Rivi: {key, lang, id, path, value (merkkijono|funktio), alias?} */
function snapshot() {
  const rows = [];
  for (const d of DICTS) for (const lang of LANGS) {
    if (!d.dict[lang]) continue;
    for (const [parts, value] of flat(d.dict[lang])) {
      const path = parts.join('.');
      if (EXCLUDED.has(`${d.id}:${path}`)) continue;
      rows.push({ key: dictKey(d, parts), lang, id: d.id, area: d.area, path, parts, value, dict: d.dict });
    }
  }
  // Aliakset: GT/MT-merkkijono = HT:n merkkijono samalla polulla → ei omaa avainta; seuraa pitotekstin avainta
  const ht = new Map(rows.filter((r) => r.id === 'HT').map((r) => [`${r.lang}|${r.path}`, r]));
  for (const r of rows) {
    if (r.id !== 'GT' && r.id !== 'MT') continue;
    const h = ht.get(`${r.lang}|${r.path}`);
    if (h && typeof r.value === 'string' && r.value === h.value) r.alias = h.key;
  }
  return rows;
}
const ENTRIES = snapshot();

const toVarTokens = (s) => s.replace(/\{(\w+)\}/g, '{{var:$1}}').split(PHONE_LITERAL).join('{{var:phone}}');
const tokensIn = (s) => [...new Set(s.match(/\{\{[^{}]*\}\}/g) || [])];

/** Tuontimuotoiset oletusrivit (ilman luokkaa): [{key, lang, text, path, id, fn?}]; funktiolehdet laajennettuna malleiksi, aliakset pois (oma avain pitotekstissä). */
export function collectDefaults() {
  const out = [];
  for (const r of ENTRIES) {
    if (r.alias) continue;
    const fid = `${r.id}:${r.path}`;
    if (typeof r.value === 'function') {
      const spec = FN_SPECS[fid];
      if (!spec) throw new Error(`funktiolehdelle ${fid} ei ole mallia (FN_SPECS)`);
      const t = spec[r.lang];
      if (spec.plural) for (const form of ['one', 'other']) out.push({ key: `${r.key}.${form}`, lang: r.lang, text: t[form], path: r.path, id: r.id, fn: true, form });
      else out.push({ key: r.key, lang: r.lang, text: t, path: r.path, id: r.id, fn: true });
      if (spec.one) out.push({ key: `${r.key}_one`, lang: r.lang, text: spec.one[r.lang], path: r.path, id: r.id, fn: true, form: 'one' });
    } else out.push({ key: r.key, lang: r.lang, text: toVarTokens(r.value), path: r.path, id: r.id });
  }
  return out;
}
export const allKeys = () => [...new Set(collectDefaults().map((r) => r.key))];

// ---- peitto ----
const ORIGINAL = new Map(ENTRIES.map((r) => [r, r.value]));
const fillVars = (tpl, names, args) => tpl.replace(/\{(\w+)\}/g, (m, k) => { const i = names.indexOf(k); return i >= 0 && args[i] != null ? String(args[i]) : m; });
const setLeaf = (r, value) => { let o = r.dict[r.lang]; for (const p of r.parts.slice(0, -1)) o = o[p]; o[r.parts[r.parts.length - 1]] = value; };

/**
 * Peittää sanakirjat tietokannan teksteillä. rows = public_get_site_texts-rivit ({key, lang, text}). Idempotentti: jokainen kutsu alkaa oletuksista.
 * vars: staattiset {{var:…}}-arvot (esim. { phone, email }); muut var-merkinnät jäävät muotoon {nimi} ja täytetään kutsuhetkellä (kuten ennenkin).
 * data: { catalog, settings, format } {{price:ID}}/{{duration:ID}}/{{setting:avain}}-paikkamerkeille. Palauttaa { applied, skipped:[{key,lang,why}] }.
 */
export function applySiteTexts(rows, { vars = {}, data = {}, log = null } = {}) {
  const idx = indexTexts(rows);
  const ctx = makeContext({ catalog: data.catalog || [], settings: data.settings || {}, format: data.format || {}, vars: (n) => (vars[n] != null ? String(vars[n]) : `{${n}}`) });
  const applied = [], skipped = [];
  const resolve = (key, lang) => {
    const row = idx.get(key)?.[lang]; if (!row) return null;
    try { return fillPlaceholders(row.text, ctx, lang, { key }); }
    catch (err) { if (!(err instanceof PlaceholderError)) throw err; skipped.push({ key, lang, why: err.message }); log?.(`site-texts: ${key} [${lang}] ohitettu (${err.message}); käytetään oletusta`); return null; }
  };
  const byKey = new Map();
  for (const r of ENTRIES) {
    const orig = ORIGINAL.get(r);
    if (r.alias) continue;
    if (typeof orig === 'function') {
      const spec = FN_SPECS[`${r.id}:${r.path}`];
      const tpl = {};
      for (const form of spec.plural ? ['one', 'other'] : ['']) { const t = resolve(spec.plural ? `${r.key}.${form}` : r.key, r.lang); if (t != null) { tpl[form] = t; applied.push(`${r.key}${form ? '.' + form : ''}`); } }
      // Yksikkö (spec.one): tietokannan <avain>_one; puuttuu → koodin yksikkömalli, mutta vain jos perusavain tuli tietokannasta (muuten alkuperäinen funktio hoitaa yksikön)
      const oneT = spec.one ? resolve(`${r.key}_one`, r.lang) : null; if (oneT != null) applied.push(`${r.key}_one`);
      const oneIdx = spec.one ? spec.args.indexOf(spec.one.arg) : -1, lang = r.lang;
      setLeaf(r, Object.keys(tpl).length || oneT != null ? (...args) => {
        if (oneIdx >= 0 && isOne(lang, args[oneIdx])) { if (oneT != null) return fillVars(oneT, spec.args, args); if (tpl[''] != null) return fillVars(spec.one[lang].replace(/\{\{var:(\w+)\}\}/g, '{$1}'), spec.args, args); return orig(...args); }
        const t = tpl[spec.plural ? (isOne(lang, args[0]) ? 'one' : 'other') : '']; return t != null ? fillVars(t, spec.args, args) : orig(...args);
      } : orig);
    } else {
      const t = resolve(r.key, r.lang);
      setLeaf(r, t != null ? t : orig); if (t != null) { applied.push(r.key); byKey.set(`${r.lang}|${r.key}`, t); }
    }
  }
  for (const r of ENTRIES) { if (!r.alias) continue; const t = byKey.get(`${r.lang}|${r.alias}`); setLeaf(r, t != null ? t : ORIGINAL.get(r)); }
  return { applied, skipped };
}
/** Palauttaa kaikki sanakirjat repon oletuksiin (testit). */
export const resetSiteTexts = () => applySiteTexts([]);

/**
 * Luokka (§18.6) avaimen ja FI-tekstin perusteella: protected = ehdot/oikeudelliset, suostumukset, yhteystiedot (puh./sähköposti), kellonajat/aukiolo,
 * peruutus-/muutosehdot, lahjakortin voimassaolo, turvallisuus-/terveysväitteet. Muut normal. (Hinnat/ALV/URL = locked: ei tässä, ne tulevat lähdetaulusta.)
 */
export function classFor(key, fiText = '') {
  const t = String(fiText);
  if (/\{\{var:(phone|email)\}\}|@|https?:\/\/|www\./i.test(t)) return 'protected';                              // yhteystieto
  if (/(^|[._])(consent|marketing|terms|terms_link|privacy|gdpr|accept_terms|accept_terms_err|change_info|change_locked|change_note|cancel_lead|cancel_fail)$/i.test(key)) return 'protected';   // suostumus, ehdot, peruutus-/muutosehdot
  if (/ostoehto|käyttöehto|tietosuoja|peruutusehto|hyvitys/i.test(t)) return 'protected';
  if (/\{\{var:months\}\}/.test(t)) return 'protected';                                                          // lahjakortin voimassaolo
  if (/\d{1,2}[.:]\d{2}/.test(t)) return 'protected';                                                            // kiinteä kellonaika
  if (/terveys|raskau|allergi|sairau|turvallis|lääke/i.test(t)) return 'protected';                              // turvallisuus-/terveysväite
  return 'normal';
}
