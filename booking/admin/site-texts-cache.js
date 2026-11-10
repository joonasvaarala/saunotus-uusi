// Jaettu, yhden istunnon mittainen site_texts-lupaus. Kaikki hallinnan tekstimoduulit (*-texts.js) lukevat tekstit tästä:
// tekstit haetaan kerran istunnossa (tai otetaan päivänipusta primeSiteTexts-kutsulla), ei kerran per moduuli.
// booking_276: ensisijaisesti admin_ui_texts (vain hallinnan avaimet ui.admin.*, ui.pos.*, ui.upsell.*, admin.*; PRODissa
// 10.11 noin 0,49 MB / 3740 riviä vs. public_get_site_texts 1,35 MB / 8612 riviä). Jos funktiota ei ole (vanha kanta,
// rollback tai kokeilutila ilman mockia) tai kutsu epäonnistuu, käytetään public_get_site_texts-funktiota kuten ennen.
// Virhe tai kelvoton vastaus ({ ok: false } tms.) ei jää välimuistiin: seuraava kutsu yrittää uudelleen.
let siteTextsPromise = null;
let adminTextsUnavailable = false;   // admin_ui_texts puuttui tai epäonnistui tässä istunnossa → suoraan vanhaan funktioon
const valid = (payload) => !!(payload && payload.ok === true && Array.isArray(payload.texts));
export function primeSiteTexts(payload) {
  if (valid(payload)) siteTextsPromise = Promise.resolve(payload);
}
export function clearSiteTextsCache() { siteTextsPromise = null; adminTextsUnavailable = false; }
async function fetchTexts(rpc) {
  if (!adminTextsUnavailable) {
    try {
      const payload = await rpc('admin_ui_texts', { p_lang: null });
      if (valid(payload)) return payload;
    } catch { /* puuttuva funktio tai virhe → varapolku */ }
    adminTextsUnavailable = true;
  }
  return rpc('public_get_site_texts', { p_lang: null });
}
export function getSiteTexts(rpc) {
  if (!siteTextsPromise) {
    const request = Promise.resolve().then(() => fetchTexts(rpc));
    const tracked = request.then((payload) => {
      if (!valid(payload) && siteTextsPromise === tracked) siteTextsPromise = null;
      return payload;
    }, (e) => { if (siteTextsPromise === tracked) siteTextsPromise = null; throw e; });
    siteTextsPromise = tracked;
  }
  return siteTextsPromise;
}
