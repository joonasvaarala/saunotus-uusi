// Jaettu, yhden istunnon mittainen site_texts-lupaus. Kaikki hallinnan tekstimoduulit (*-texts.js) lukevat tekstit tästä:
// public_get_site_texts haetaan kerran istunnossa (tai otetaan päivänipusta primeSiteTexts-kutsulla), ei kerran per moduuli.
// Virhe tai kelvoton vastaus ({ ok: false } tms.) ei jää välimuistiin: seuraava kutsu yrittää uudelleen.
let siteTextsPromise = null;
const valid = (payload) => !!(payload && payload.ok === true && Array.isArray(payload.texts));
export function primeSiteTexts(payload) {
  if (valid(payload)) siteTextsPromise = Promise.resolve(payload);
}
export function clearSiteTextsCache() { siteTextsPromise = null; }
export function getSiteTexts(rpc) {
  if (!siteTextsPromise) {
    const request = Promise.resolve().then(() => rpc('public_get_site_texts', { p_lang: null }));
    const tracked = request.then((payload) => {
      if (!valid(payload) && siteTextsPromise === tracked) siteTextsPromise = null;
      return payload;
    }, (e) => { if (siteTextsPromise === tracked) siteTextsPromise = null; throw e; });
    siteTextsPromise = tracked;
  }
  return siteTextsPromise;
}
