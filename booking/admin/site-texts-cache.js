// Jaettu, yhden istunnon mittainen site_texts-lupaus (Päivä, suodattimet, muistutukset).
let siteTextsPromise = null;
export function primeSiteTexts(payload) {
  if (payload && payload.ok === true && Array.isArray(payload.texts)) {
    siteTextsPromise = Promise.resolve(payload);
  }
}
export function clearSiteTextsCache() { siteTextsPromise = null; }
export function getSiteTexts(rpc) {
  if (!siteTextsPromise) {
    const request = Promise.resolve().then(() => rpc('public_get_site_texts', { p_lang: null }));
    const tracked = request.catch((e) => { if (siteTextsPromise === tracked) siteTextsPromise = null; throw e; });
    siteTextsPromise = tracked;
  }
  return siteTextsPromise;
}
