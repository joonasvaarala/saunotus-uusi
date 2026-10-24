// booking_150: tietosuojaselosteen kohta evästeettömästä kävijämittauksesta (GDPR art. 13). Vain kohdat, jotka art. 13 vaatii.
// Tekstit sivuteksteistä (content/site-texts.pending-import-50.json, FI+EN); varateksti = sama kuin tuontitiedostossa.
// Teksti vastaa toteutusta: ei evästeitä, IP vain hetkellisesti rate limitissä (päiväkohtainen tiiviste ≤ 2 vrk, booking.rate_limit_hits),
// säilytys = booking.settings analytics_retention_months (13) / pg_cron booking_analytics_cleanup. Ei kytke mittausta päälle.
import { tx } from './site-texts.mjs';

export const PRIVACY_ANALYTICS_TEXTS = Object.freeze({
  'ui.site.privacy_analytics_title': { fi: "Evästeetön kävijämittaus", en: "Cookieless visitor analytics" },
  'ui.site.privacy_analytics_text': {
    fi: "Kun sivuston kävijämittaus on käytössä, se toimii ilman evästeitä: selaimeen ei tallenneta mitään. Rekisterinpitäjä ja yhteystiedot kuten yllä.\nTiedot: avatut sivut (osoite ilman URL-parametreja), tuote- ja kassasivujen avaukset, viittaavan sivuston verkkotunnus, kampanjatunnisteet (utm), laitetyyppi ja kieli sekä satunnainen istuntotunniste, joka on voimassa vain yhden sivunlatauksen ajan. Kun tilaus on maksettu, käynti linkitetään tilaukseen (tilaus ja sen summa).\nTarkoitus ja oikeusperuste: palvelun kehittäminen ja markkinoinnin seuranta; oikeusperuste on rekisterinpitäjän oikeutettu etu.\nIP-osoite: IP-osoitetta ei tallenneta. Sitä käytetään hetkellisesti väärinkäytön rajoittamiseen (pyyntöjen määrä); tätä varten säilytetään enintään kaksi vuorokautta päiväkohtainen tiiviste, ei itse osoitetta.\nSäilytys: 13 kuukautta, minkä jälkeen tiedot poistetaan automaattisesti. Tiedot tallennetaan varausjärjestelmään EU-alueella (käsittelijä Supabase), eikä niitä luovuteta eteenpäin.\nOikeudet: voit vastustaa mittausta; selaimen Do Not Track- tai Global Privacy Control -asetus estää sen kokonaan. Voit tehdä valituksen tietosuojavaltuutetulle.",
    en: "When the website's visitor analytics is enabled, it works without cookies: nothing is stored in your browser. Controller and contact details as above.\nData: pages opened (address without URL parameters), product and checkout page views, the referring website's domain, campaign tags (utm), device type and language, and a random session identifier that is valid for a single page load only. When an order has been paid, the visit is linked to the order (the order and its total).\nPurpose and legal basis: developing the service and measuring marketing; the legal basis is the controller's legitimate interest.\nIP address: IP addresses are not stored. The IP address is used momentarily to limit abuse (number of requests); for this, a daily hash, not the address itself, is kept for at most two days.\nRetention: 13 months, after which the data is deleted automatically. The data is stored in the booking system within the EU (processor Supabase) and is not disclosed to third parties.\nYour rights: you may object to the analytics; the Do Not Track or Global Privacy Control setting of your browser blocks it completely. You may lodge a complaint with the Data Protection Ombudsman.",
  },
});
const quiet = { warn: () => {} };
/** Selosteen kohta HTML:nä samalla rakenteella kuin muut kohdat (h2 + kappaleet). para = sivupohjan kappalefunktio. */
export function privacyAnalyticsHtml(lang, esc, para) {
  const t = (k) => tx(k, lang, { fallback: PRIVACY_ANALYTICS_TEXTS[k][lang] ?? PRIVACY_ANALYTICS_TEXTS[k].fi, log: quiet });
  return `<h2>${esc(t('ui.site.privacy_analytics_title'))}</h2>${para(t('ui.site.privacy_analytics_text'))}`;
}
