// Hallinnan "Uusi varaus" -näkymän, lisäpalveluvalitsimen ja asiakaslomakkeen tekstit (FI/EN). Kieli samasta valinnasta kuin Talous-näkymillä
// (talous-i18n.js: ?lang=en | localStorage). Puhdas moduuli (ei DOMia) → node --test tarkistaa, että FI ja EN sisältävät samat avaimet.
import { getLang } from './talous-i18n.js';

export const NB = {
  fi: {
    // stepper
    'step.dec': 'Vähennä: {name}', 'step.inc': 'Lisää: {name}', 'step.qty': '{name}, määrä',
    // lisäpalvelut
    'addons.title': 'Lisäpalvelut', 'addons.perPiece': '{price} / kpl', 'addons.total': 'Lisäpalvelut yhteensä', 'addons.max': 'enintään {n}',
    // sivu
    'nb.title': 'Uusi varaus', 'nb.lang': 'Kieli',
    'nb.s1': 'Vuoro ja päivä', 'nb.s2': 'Henkilömäärä', 'nb.s3': 'Asiakas', 'nb.s4': 'Lisäpalvelut', 'nb.s5': 'Maksu ja hinta', 'nb.s6': 'Muistiinpano',
    'nb.optional': 'valinnainen', 'nb.ownPrice': 'oma hinta', 'nb.day': 'Päivä', 'nb.prevDay': 'Edellinen päivä', 'nb.nextDay': 'Seuraava päivä', 'nb.slots': 'Vuoro', 'nb.loading': 'Ladataan…', 'nb.noSlots': 'Ei vuoroja tälle päivälle.', 'nb.pickSlot': 'Valitse vuoro, niin varauksen muut tiedot avautuvat.',
    'nb.free': '{n} vapaana', 'nb.hold': 'jonopito {n} hlö klo {time} asti', 'nb.holdHint': 'Jonotuslistan pito: {n} hlö klo {time} asti. Paikat eivät ole julkisessa myynnissä; henkilökunnan varaus voi viedä ne.', 'nb.privFree': 'yksityisvuoro vapaa', 'nb.holdPriv': 'jonopito klo {time} asti', 'nb.holdHintPriv': 'Jonotuslistan pito klo {time} asti. Yksityisvuoro ei ole julkisessa myynnissä; henkilökunnan varaus voi viedä sen.', 'nb.full': 'täynnä', 'nb.na': 'ei varattavissa',
    'nb.picked': 'Vuoro: {name}, {time}', 'nb.pickedDay': '{day}',
    'nb.persons': 'Henkilöä', 'nb.personsHint': 'Vapaana {free}, vähintään {min}.', 'nb.personsHintMin': 'Vähintään {min}, enintään {max}.',
    'nb.method': 'Maksutapa', 'nb.paid': 'Maksettu jo', 'nb.paidHint': 'Merkitse, jos asiakas on jo maksanut tämän varauksen.',
    'nb.priceOpen': 'Muuta vuoron hintaa', 'nb.price': 'Vuoron hinta €', 'nb.priceHint': 'Jätä tyhjäksi, niin hinta lasketaan automaattisesti ({auto}).', 'nb.priceAuto': 'Automaattinen',
    'nb.invref': 'Laskun viite / tilausnumero', 'nb.invrefHint': 'Tulee laskulle (yritysasiakas), esim. ostotilauksen numero.',
    'nb.note': 'Sisäinen huomio', 'nb.noteHint': 'Näkyy vain henkilökunnalle, ei asiakkaalle.',
    'nb.card': 'Vuosikorttivaraus', 'nb.cardHint': 'Ilmainen, 1 henkilö; yksi tuleva varaus kerrallaan.',
    'nb.sumSlot': 'Vuoro', 'nb.sumAddons': 'Lisäpalvelut', 'nb.sumTotal': 'Yhteensä', 'nb.sumCard': 'Vuosikortti: ilmainen',
    'nb.save': 'Tallenna varaus', 'nb.saving': 'Tallennetaan…',
    'nb.errSummary': 'Tarkista lomake: {n} kohtaa vaatii huomiota.', 'nb.errPersons': 'Anna henkilömäärä väliltä {min}–{max}.', 'nb.errPrice': 'Anna hinta euroina (0 tai suurempi) tai jätä kenttä tyhjäksi.', 'nb.errSlot': 'Valitse ensin vuoro.',
    'nb.errServer': 'Varausta ei tallennettu: {msg}',
    'nb.created': 'Varaus luotu – tilaus #{no}', 'nb.createdLine': '{product}, {day} {time} · {total}',
    'nb.openBooking': 'Avaa varaus', 'nb.openOrder': 'Avaa tilaus ja maksut', 'nb.orderLink': 'Tilaus {no} / Maksut', 'nb.another': 'Luo toinen varaus', 'nb.dayView': 'Näytä päivänäkymä',
    'nb.toast': 'Varaus luotu (tilaus #{no})', 'nb.warnMissing': 'Varaus tehty, mutta saunottaja puuttuu työvuorosta',
    // asiakas
    'cu.search': 'Hae olemassa olevaa asiakasta', 'cu.searchPh': 'Nimi, sähköposti tai puhelin', 'cu.searchAria': 'Hae asiakas', 'cu.searchBtn': 'Hae',
    'cu.or': 'Tai syötä uuden asiakkaan tiedot:', 'cu.selected': 'Valittu asiakas', 'cu.selectedNote': 'Tietoja voi muuttaa Asiakkaat-näkymässä.', 'cu.new': 'Uusi asiakas', 'cu.contact': 'yhteyshenkilö', 'cu.fromOrders': 'aiempi tilaus', 'cu.fromOrdersNote': 'Yrityksen tiedot aiemmalta tilaukselta. Tarkista ja täydennä tarvittaessa alla; yritys tallentuu asiakasrekisteriin varauksen mukana.',
    'cu.notFound': 'Ei löytynyt – luo uusi asiakas', 'cu.prefilled': 'Hakusana siirrettiin kenttään: {what}.', 'cu.notOverwritten': 'Kenttä "{what}" oli jo täytetty, sitä ei ylikirjoitettu.',
    'cu.notFoundKept': 'Ei löytynyt. Valittu asiakas säilyy – paina "Uusi asiakas" luodaksesi uuden.',
    'cu.what.email': 'sähköposti', 'cu.what.phone': 'puhelin', 'cu.what.name': 'nimi', 'cu.what.company': 'yrityksen nimi',
    'cu.kind': 'Asiakastyyppi', 'cu.private': 'Yksityisasiakas', 'cu.company': 'Yritysasiakas',
    'cu.name': 'Nimi', 'cu.contactName': 'Yhteyshenkilön nimi', 'cu.email': 'Sähköposti', 'cu.phone': 'Puhelin', 'cu.reachHint': 'Anna sähköposti tai puhelinnumero (toinen riittää).',
    'cu.cInfo': 'Yrityksen tiedot', 'cu.cName': 'Yrityksen nimi', 'cu.bid': 'Y-tunnus', 'cu.bidHint': 'Muoto 1234567-8. Tarkistenumero tarkistetaan.', 'cu.street': 'Katuosoite', 'cu.zip': 'Postinumero', 'cu.city': 'Postitoimipaikka',
    'cu.einv': 'Verkkolaskutus (valinnainen)', 'cu.ovt': 'Verkkolaskuosoite (OVT-tunnus)', 'cu.ovtPh': 'esim. 003712345678', 'cu.op': 'Verkkolaskuoperaattori (välittäjätunnus)', 'cu.opPh': 'esim. 003723327487 tai BAWCFI22', 'cu.opHint': 'Anna osoite ja välittäjä yhdessä tai jätä molemmat tyhjiksi.',
    'cu.ref': 'Viite / tilausnumero (valinnainen)',
    'cu.eName': 'Anna nimi', 'cu.eContactName': 'Anna yhteyshenkilön nimi', 'cu.eReach': 'Anna sähköposti tai puhelinnumero.', 'cu.eEmail': 'Tarkista sähköpostiosoite.',
    'cu.eCompany': 'Anna yrityksen nimi.', 'cu.eBid': 'Tarkista y-tunnus (muoto 1234567-8, tarkistenumero ei täsmää).', 'cu.eStreet': 'Anna katuosoite.', 'cu.eZip': 'Anna 5-numeroinen postinumero.', 'cu.eCity': 'Anna postitoimipaikka.',
    'cu.eEinv': 'Anna verkkolaskuosoite ja välittäjätunnus yhdessä tai jätä molemmat tyhjiksi.',
  },
  en: {
    'step.dec': 'Decrease: {name}', 'step.inc': 'Increase: {name}', 'step.qty': '{name}, quantity',
    'addons.title': 'Add-ons', 'addons.perPiece': '{price} each', 'addons.total': 'Add-ons total', 'addons.max': 'up to {n}',
    'nb.title': 'New booking', 'nb.lang': 'Language',
    'nb.s1': 'Session and day', 'nb.s2': 'Guests', 'nb.s3': 'Customer', 'nb.s4': 'Add-ons', 'nb.s5': 'Payment and price', 'nb.s6': 'Note',
    'nb.optional': 'optional', 'nb.ownPrice': 'custom price', 'nb.day': 'Day', 'nb.prevDay': 'Previous day', 'nb.nextDay': 'Next day', 'nb.slots': 'Session', 'nb.loading': 'Loading…', 'nb.noSlots': 'No sessions on this day.', 'nb.pickSlot': 'Pick a session and the rest of the booking details will open.',
    'nb.free': '{n} free', 'nb.hold': 'waiting-list hold {n} until {time}', 'nb.holdHint': 'Waiting-list hold: {n} until {time}. These places are not on public sale; a staff booking can take them.', 'nb.privFree': 'private session free', 'nb.holdPriv': 'waiting-list hold until {time}', 'nb.holdHintPriv': 'Waiting-list hold until {time}. The private session is not on public sale; a staff booking can take it.', 'nb.full': 'full', 'nb.na': 'not available',
    'nb.picked': 'Session: {name}, {time}', 'nb.pickedDay': '{day}',
    'nb.persons': 'Guests', 'nb.personsHint': '{free} free, minimum {min}.', 'nb.personsHintMin': 'Minimum {min}, maximum {max}.',
    'nb.method': 'Payment method', 'nb.paid': 'Already paid', 'nb.paidHint': 'Tick if the customer has already paid for this booking.',
    'nb.priceOpen': 'Change the session price', 'nb.price': 'Session price €', 'nb.priceHint': 'Leave empty to use the automatic price ({auto}).', 'nb.priceAuto': 'Automatic',
    'nb.invref': 'Invoice reference / order number', 'nb.invrefHint': 'Printed on the invoice (company customers), e.g. a purchase order number.',
    'nb.note': 'Internal note', 'nb.noteHint': 'Visible to staff only, not to the customer.',
    'nb.card': 'Annual card booking', 'nb.cardHint': 'Free, 1 guest; one upcoming booking at a time.',
    'nb.sumSlot': 'Session', 'nb.sumAddons': 'Add-ons', 'nb.sumTotal': 'Total', 'nb.sumCard': 'Annual card: free',
    'nb.save': 'Save booking', 'nb.saving': 'Saving…',
    'nb.errSummary': 'Please check the form: {n} item(s) need attention.', 'nb.errPersons': 'Enter a number of guests from {min} to {max}.', 'nb.errPrice': 'Enter a price in euros (0 or more) or leave the field empty.', 'nb.errSlot': 'Pick a session first.',
    'nb.errServer': 'The booking was not saved: {msg}',
    'nb.created': 'Booking created – order #{no}', 'nb.createdLine': '{product}, {day} {time} · {total}',
    'nb.openBooking': 'Open booking', 'nb.openOrder': 'Open order and payments', 'nb.orderLink': 'Order {no} / Payments', 'nb.another': 'Create another booking', 'nb.dayView': 'Show day view',
    'nb.toast': 'Booking created (order #{no})', 'nb.warnMissing': 'Booking made, but no therapist is on shift',
    'cu.search': 'Find an existing customer', 'cu.searchPh': 'Name, email or phone', 'cu.searchAria': 'Find customer', 'cu.searchBtn': 'Search',
    'cu.or': 'Or enter the new customer’s details:', 'cu.selected': 'Selected customer', 'cu.selectedNote': 'Details can be edited in the Customers view.', 'cu.new': 'New customer', 'cu.contact': 'contact', 'cu.fromOrders': 'earlier order', 'cu.fromOrdersNote': 'Company details from an earlier order. Check and complete them below if needed; the company is saved to the customer register with the booking.',
    'cu.notFound': 'Not found – create a new customer', 'cu.prefilled': 'The search term was moved to: {what}.', 'cu.notOverwritten': 'The "{what}" field was already filled, so it was not overwritten.',
    'cu.notFoundKept': 'Not found. The selected customer stays – press "New customer" to create one.',
    'cu.what.email': 'email', 'cu.what.phone': 'phone', 'cu.what.name': 'name', 'cu.what.company': 'company name',
    'cu.kind': 'Customer type', 'cu.private': 'Private customer', 'cu.company': 'Company',
    'cu.name': 'Name', 'cu.contactName': 'Contact person', 'cu.email': 'Email', 'cu.phone': 'Phone', 'cu.reachHint': 'Enter an email or a phone number (one is enough).',
    'cu.cInfo': 'Company details', 'cu.cName': 'Company name', 'cu.bid': 'Business ID (Y-tunnus)', 'cu.bidHint': 'Format 1234567-8. The check digit is verified.', 'cu.street': 'Street address', 'cu.zip': 'Postcode', 'cu.city': 'City',
    'cu.einv': 'E-invoicing (optional)', 'cu.ovt': 'E-invoice address (OVT)', 'cu.ovtPh': 'e.g. 003712345678', 'cu.op': 'E-invoice operator (intermediary ID)', 'cu.opPh': 'e.g. 003723327487 or BAWCFI22', 'cu.opHint': 'Enter the address and the intermediary together, or leave both empty.',
    'cu.ref': 'Reference / order number (optional)',
    'cu.eName': 'Enter a name.', 'cu.eContactName': 'Enter the contact person’s name.', 'cu.eReach': 'Enter an email or a phone number.', 'cu.eEmail': 'Check the email address.',
    'cu.eCompany': 'Enter the company name.', 'cu.eBid': 'Check the business ID (format 1234567-8, the check digit does not match).', 'cu.eStreet': 'Enter the street address.', 'cu.eZip': 'Enter a 5-digit postcode.', 'cu.eCity': 'Enter the city.',
    'cu.eEinv': 'Enter the e-invoice address and the intermediary together, or leave both empty.',
  },
};
export const nbLang = () => { const l = getLang(); return NB[l] ? l : 'fi'; };
export function nbt(key, vars) {
  const v = NB[nbLang()][key] ?? NB.fi[key];
  if (v == null) return key;
  return vars ? v.replace(/\{(\w+)\}/g, (_, k) => (vars[k] == null ? '' : vars[k])) : v;
}
// Lisäpalvelun kuvaus on turha, jos se vain toistaa nimen ("Lisäpalvelu varaukseen: pyyhe." / "Add-on for your booking: towel.")
const GENERIC = new Set(['lisäpalvelu', 'lisäpalvelut', 'varaukseen', 'varaus', 'varauksen', 'tilaukseen', 'add', 'on', 'addon', 'for', 'your', 'booking', 'order', 'to', 'the', 'a', 'ja', 'and']);
const words = (s) => String(s || '').toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, ' ').split(/\s+/).filter(Boolean);
export function descRedundant(name, desc) {
  const d = words(desc); if (!d.length) return true;
  const n = words(name);
  const near = (w) => n.some((x) => x === w || (x.length > 3 && w.length > 3 && (w.startsWith(x.slice(0, 4)) || x.startsWith(w.slice(0, 4)))));
  return d.every((w) => GENERIC.has(w) || near(w));
}
// Näytettävä kuvaus: yleinen alkuliite ("Lisäpalvelu varaukseen: ", "Add-on for your booking: ") pois, ja isolla alkukirjaimella
export function cleanDesc(desc) {
  const t = String(desc || '').replace(/^\s*(lisäpalvelu varaukseen|add-on for your booking)\s*:\s*/i, '').trim();
  return t ? t.charAt(0).toUpperCase() + t.slice(1) : t;
}
