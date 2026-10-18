// Kaupan sivutekstit tietokannasta (sopimus §18): build kirjoittaa avainalueen ui.* tekstit tiedostoon booking/site-texts.json (public_get_site_texts, FI + EN),
// kauppa lataa sen käynnistyessä ja täyttää paikkamerkit ({{price:7}}, {{duration:7}}, {{setting:<avain>}}) AJOAJAN katalogista ja asetuksista – hinta/kesto pysyvät
// oikein vaikka sivu olisi välimuistissa; build on jo varmistanut että kaikki paikkamerkit ovat täytettävissä (tuntematon paikkamerkki kaataa buildin).
// tx(key) → teksti (en puuttuu → fi) tai null kun avainta ei ole / paikkamerkin arvoa ei löydy. Kutsuja päättää varatekstin (esim. palvelimen message), EI koskaan raakaa avainta.
import { indexTexts, textFor, makeContext, fmtMinutes, fmtPrice } from './site-texts-logic.js';
import { applySiteTexts } from './text-registry.js';

/** Hakee build-aikaisen tekstitiedoston. Virhe / puuttuva tiedosto → [] (kauppa toimii ilman: kutsujien varatekstit). */
export async function loadShopTexts(url, fetchImpl = globalThis.fetch) {
  if (!url) return [];
  try { const r = await fetchImpl(url); if (!r.ok) return []; const j = await r.json(); return Array.isArray(j?.texts) ? j.texts : []; } catch { return []; }
}

/**
 * Peittää kaupan sanakirjat (i18n.js, order-texts.js, gift-texts.js, …) tietokannan teksteillä (osa 3, §18): DB-teksti kun saatavilla, muuten repon oletus (ulkoasu ei muutu).
 * rows annetaan jos ne on jo ladattu; muuten ladataan S.siteTextsUrl. Virhe/puuttuva tiedosto = ei muutoksia. {{var:phone}}/{{var:email}} täytetään sivuston yhteystiedoista (S.phone, S.email).
 * data = { catalog, settings, format } {{price:ID}}/{{duration:ID}}/{{setting:avain}}-paikkamerkeille (puuttuessa teksti jää oletukseksi).
 */
export async function applyShopTexts(S, { rows = null, data = {}, fetchImpl } = {}) {
  const r = rows ?? await loadShopTexts(S?.siteTextsUrl, fetchImpl);
  if (!r.length) return { rows: r, applied: [], skipped: [] };
  return { rows: r, ...applySiteTexts(r, { vars: { phone: S?.phone, email: S?.email }, data, log: (m) => console.warn?.(m) }) };
}

/**
 * @param {{lang:string, rows?:object[], format?:{price?:Function, duration?:Function}}} o
 * @returns {{ tx:(key:string)=>string|null, setData:(d:{catalog?:object[], settings?:object})=>void, setRows:(rows:object[])=>void, has:(key:string)=>boolean }}
 */
export function createTexts({ lang, rows = [], format = {} }) {
  let idx = indexTexts(rows), data = { catalog: [], settings: {} }, ctx = makeContext({ ...data, format: { price: format.price || fmtPrice, duration: format.duration || fmtMinutes } });
  const L = lang === 'en' ? 'en' : 'fi';
  const mk = () => { ctx = makeContext({ ...data, format: { price: format.price || ((n) => fmtPrice(n, L)), duration: format.duration || ((m) => fmtMinutes(m)) } }); };
  mk();
  return {
    tx: (key) => textFor(idx, key, L, ctx, { strict: false })?.text ?? null,
    has: (key) => !!idx.get(key),
    setRows: (r) => { idx = indexTexts(r); },
    setData: (d) => { data = { catalog: d.catalog ?? data.catalog, settings: d.settings ?? data.settings }; mk(); },
  };
}
