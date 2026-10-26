# Varausdialogi 04 – muutospaketti, tarkistettava ennen yhdistämistä

**Pohja:** `joonasvaarala/saunotus-uusi` `main` @ `f19cb1d601ec29a95e988c4183f10816f2b67715` (26.10.2026 klo 10 Suomen aikaa). Hallinnan alkuperäiset 143 tiedostoa palautettiin täsmälleen tämän SHA:n GitHub Actions Pages -artifaktista (vain importtien build-vaiheen `?v=`-tunniste poistettiin), ja vanhat blob-SHA:t `shared.js` ja `order-reservation-bridge.js` tarkistettiin. Ei muutoksia tuotantoon eikä pysyviä muutoksia Tapio-deviin.

**PR:n pakollinen otsikko migraation vuoksi:** `ÄLÄ YHDISTÄ ennen kuin Bottiavustus on ajanut migraation tuotantoon – Varausdialogi 04`.

## Käyttäjälle näkyvät muutokset

- Varausdialogin otsikkona palvelu; yhteenveto, asiakas ja soitto-/sähköpostilinkit ensin.
- Päätoiminnot järjestetty: Vahvista → Lisäosto → Luo maksulinkki → Merkitse saapuneeksi → Muuta varausta. Peru varaus siirtyi Muut toiminnot -riville; saapuminen ja Ei saapunut näkyvät vasta Helsingin varauspäivästä alkaen, jälkimmäinen vahvistetaan.
- Tilaus ja maksu, hoito ja lisäpalvelut, muistiinpano (Tallenna vain muututtua), Lisätiedot (suljettu) ja Siirrä toiseen tilaan (suljettu, viimeisenä). Puuttuvat/toimimattomat napit jätetään pois. Natiivien DOM `append`/`replaceChildren`-metodien `null`-tekstisolmut poistettu listasuodatuksella.
- Lisäosto ja maksulinkki saataville kaikissa varausdialogin avauspaikoissa; maksulinkki näkyy vain maksamattomalle omalle tilaukselle. Flow-kytkimen ollessa pois Lisäosto ei näy, mutta maksulinkki voi näkyä.
- Henkilökunnan maksulinkki on oletuksena **ilman takarajaa**; valintaruudulla voi määrittää takarajan 1–60 päivää. Asetukset on huomioitu myös Visma- ja MobilePay-käsittelyssä, vanhan tilauksen lisäämispolussa ja kumppanilahjakortin erotuksessa.

## Toimituksen sisältö

`changed/` sisältää **18 kokonaisen tiedoston** uudet/muutetut versiot: adminin `views/shared.js`, `views/order-reservation-bridge.js`, `views/order-add.js`, `views/talous-orders.js`, uuden `views/payment-link-04.js`-moduulin, `reservation-dialog-logic.js`, `payment-link-logic.js`, kaksikielisen varatekstimoduulin `reservation-texts-04.js`, `admin.css`, `orders-texts.js`, kolme mock-tiedostoa, `content/site-texts.pending-import-78.json` (26 avainta × kaksi kieltä), SQL-migraation, SQL-rollbackin, t184-testin ja uuden `varausdialogi-04.test.mjs`-testin. `patch/varausdialogi-uudistus.diff` sisältää näiden muutokset pohjaan verrattuna sekä kolme täydentävää korjaushunkkia `t174`-, `pages.yml`- ja `order-detail-layout.test.mjs`-tiedostoille.

**Toimitusrajoitus:** alkuperäiset `t174`, `pages.yml` ja `order-detail-layout.test.mjs` eivät sisälly `changed/`-kansioon kokonaisina; näihin on vain `patch/`-hunkit. e2e-skriptien odotuksia ei päivitetty. Lisäksi `order-add.js`:n alkuperäinen toteutus on säilytetty muita dialogeja varten, mutta maksulinkkidialogi on siirretty uuteen `payment-link-04.js`-moduuliin. `admin.css` sisältää kaikki uudet `rd-*`/`pl-*`-tyylit. **Paketille ei saa antaa tuotantovalmiin hyväksyntää ennen puuttuvien testitiedostojen ja e2e-korjausten täydentämistä sekä koko repon CI-ajoa.**

## Dialogin näkyvyysehdot

| Toiminto | Ehto |
|---|---|
| Vahvista (ylhäällä) | pending + `bookings.manage` |
| Lisäosto | flow päällä, omalla tilauksella `staff_can_add`, `bookings.manage`, status pending/confirmed/completed |
| Luo maksulinkki | `payments.manage`, oma tilaus, `balance.unpaid > 0` |
| Merkitse saapuneeksi | confirmed, `bookings.manage`, Helsingin varauspäivä alkanut |
| Muuta varausta | pending/confirmed, `bookings.manage` |
| Kirjaa maksu | Maksukortin suljettu osio: `payments.manage`, oma tilaus ja maksamatonta |
| Avaa tilaus | `payments.manage` |
| Muokkaa lisäpalveluita | pending/confirmed + `bookings.manage`; jos Lisäosto näkyy, lisäksi olemassa olevia muutettavia lisäpalveluita |
| Muistiinpano | `bookings.manage` → muokattava; ilman sitä vain luku, jos sisältöä |
| Ei saapunut | sama saapumispäiväehto kuin Merkitse saapuneeksi, vahvistusdialogilla |
| Vahvista uudelleen | cancelled/expired + `bookings.manage` |
| Peru varaus | pending/confirmed + `bookings.manage`, Muut toiminnot -rivin viimeinen |
| Siirrä tilaan | confirmed + `bookings.manage`, toinen tila; Lovi ei yli 1 hlölle |

## Joonaksen päätökset D1–D6

- **D1:** Muuta varausta on päätoiminto.
- **D2:** Saapuminen/Ei saapunut näkyvät vain Helsingin päivärajasta; Ei saapunut saa vahvistuksen.
- **D3:** Lisäosto käyttää kerran haetun `admin_get_order`-tilauksen normalisoitua muotoa ja virtauksen asetuskytkintä myös kalenterissa ja päivänäkymässä. Maksulinkki ei riipu kytkimestä.
- **D4:** Peru varaus on näkyvä mutta päätoiminnoista erotettu.
- **D5:** Muokkaa lisäpalveluita -dialogi pysyy erillisenä ja vähennyslukot tarkistaa `reservationAddonLocks`; lisäys ensisijaisesti Lisäosto-polulla.
- **D6:** Takaraja valinnainen 1–60 päivää. Palvelinmuutos koskee kuutta funktiota.

## Tietokanta: booking_184

Migraatio: `booking/supabase/migrations/20261026120000_booking_184_paylink_no_deadline.sql`.
Rollback: `booking/supabase/rollbacks/20261026120000_booking_184_ROLLBACK.sql`.
SQL-testi: `booking/supabase/tests/checkout/t184_paylink_no_deadline.sql`.

| Funktio | Vanha md5 | Uusi md5 |
|---|---|---|
| `_create_link_payment` | `533ac9af831c0c11e1f504e377a17827` | `6cde7509c5bcf83ff12c40ab5c6f241f` |
| `admin_create_payment_link` | `fef2fe9aa3acf79b233086c133809918` | `80004933a80f77a10fcf625f493a20ef` |
| `admin_add_to_order` | `f615f168c9af7a2f721ab2e9a7f59559` | `245597cfe3ffa2db3d44cc8f0954e5f7` |
| `_vc_redeem` | `6f52789346960d95370169446a61451b` | `04a27c3bbf7ae4b5c8e05d6aa5535d49` |
| `vismapay_payment_apply` | `03fbbd2486b2c22dfa02d7ec84da626f` | `fd0a86e9291a66b043e7a9da6b4d6dee` |
| `mobilepay_payment_prepare` | `779fa5276d12e3a671a7ac394310fe97` | `a63e996709b88f91713418e8700dc8df` |

Tapio-devissä luotiin kaikkien kuuden funktion uudet määritelmät `BEGIN … ROLLBACK`-kehyksessä, tarkistettiin md5:t ja oikeusluettelot (muuttumattomat), palautettiin entiset rungot ja verrattiin palautettuja md5-arvoja. Tämän lisäksi ajettiin vastaava A–E osajoukkotesti: **`TESTRESULT pass=8 fail=0 errors=`**. Täysin samaan transaktioon ajettua tiedoston `t184_paylink_no_deadline.sql` omaa tulostetta ei saatu tallennettua; F/G/H sekä t174/t176/t177/t178 ovat **AJAMATTA**. SQL-testitiedostoa ei saa esittää läpäistyksi. Käytännön osajoukkotesti kattoi oletusarvon, saman linkin käyttämisen uudelleen tunnisteella, 7 pv korvauksen, arvot 0 ja 61, cronin, saldon sekä julkisen linkkitiedon. Ei lähetetty sähköposteja eikä oikeita maksuja.

**Poikkeama migraatio-ohjeesta:** uuden SQL:n kuusi alkuperäistä `CREATE OR REPLACE FUNCTION`-runkoa haetaan `pg_get_functiondef`-toiminnolla md5-vartijoiden takaa ja korvataan täsmällisin tekstimuutoksin yhden DO-lohkon sisällä. Tämä on toiminnallisesti testattu, mutta ohje vaatii jokaisen funktion **literalisen täydellisen määrittelyn**. Bottiavustuksen/Koodarin pitää vaihtaa tämä vaadittuun formaattiin ennen lopullista migraatio-PR:ää.

**Rollbackin sivuvaikutus:** jo syntyneet takarajattomat linkit jäävät `link_expires_at = null` -tilaan; vanha Visma-paluu käsittelisi perutun yrityksen virheellisesti. Älä ota palautusta tuotantoon ilman linkkien käsittelysuunnitelmaa.

## Tekstit

`content/site-texts.pending-import-78.json` sisältää 52 tietuetta, kaikki tehtävän 26 `ui.admin.res.*`- ja `ui.admin.orders.link_*`-avainta FI/EN-teksteinä ja `{{var:...}}`-paikkamerkkeineen. Oletustekstit on lisätty kokonaisena `orders-texts.js`-tiedostoon. Lisäksi `reservation-texts-04.js` käyttää `orderText`-lataajan live-tekstejä ja omaa varatekstiä.

## Testit ja tarkistukset

- **AJETTU** `node --check` kaikille 18 muuttuneiden tiedostojen `.js`/`.mjs`-tiedostoille – ei syntaksivirheitä.
- **AJETTU** `node --test booking/tests/varausdialogi-04.test.mjs` testirepossa, jossa alkuperäiset hallinnan riippuvuudet palautettiin julkaisuartifaktista: **12 pass / 0 fail** (ks. test-output.txt). Tätä ei testattu tyhjiä riippuvuuksia vastaavilla stub-moduuleilla.
- **AJETTU** Tapio-devissä yllä kuvattu 6 funktion transaktiotesti ja 8 tarkistuksen osajoukkotesti, **8 pass / 0 fail**, pelkästään `BEGIN … ROLLBACK`.
- **AJAMATTA** täysi repositoryn Node-testisarja, `node scripts/build-pages.mjs` (koko lähderepoa ei ollut paikallisesti), t174/t176/t177/t178 ja t184 tiedostona, Playwrightin 390/1280 px e2e-testi: Chromiumin navigointi paikallisosoitteeseen ja file-osoitteeseen palautti molemmilla `net::ERR_BLOCKED_BY_ADMINISTRATOR`.
- **AJAMATTA** CI-muutos kokonaisena tiedostona (vain `.diff`-hunkki) ja e2e-skriptien odotusten päivitys. `order-detail-layout.test.mjs` vanha blob-SHA-testi vanhenee tarkoituksella; korvaava rakennetesti on `.diff`-hunkissa.

## Käyttöönottojärjestys – ei vielä suoritettavaksi

1. Täydennä yllä luetellut puuttuvat kokonaiset tiedostot, muuta migraatio literalisiksi CREATE OR REPLACE -määrittelyiksi ja testaa `git apply --check`.
2. Bottiavustus ajaa migraation ja `t184` sekä t174/t176/t177/t178 Tapio-devissä (vain transaktio ja rollback).
3. Bottiavustus ajaa migraation tuotantoon erillisellä hyväksytyllä toimenpiteellä.
4. Tuo pending-import-78 FI/EN-avainparit.
5. Vasta onnistuneiden koko repon CI:n ja mobiili/desktop e2e-testien jälkeen yhdistä PR.

## Avoimet kysymykset ja rajoitteet

GitHubissa ei ollut kirjoitusoikeutta (`403 Resource not accessible by integration`), joten haaraa/PR:ää ei voitu luoda. Tämä ZIP ei muuta tuotantokantaa eikä julkaise mitään. Kuvakaappauksen alkuperäisissä tiedoissa on henkilötietoja, joten sitä ei pakattu jakeluun. Uudet 390 ja 1280 px kuvakaappaukset jäivät selaimen navigointieston vuoksi ottamatta. MobilePay-yrityksen mahdollinen linkin `provider`-kentän muuttuminen arvoon `mobilepay` jää erilliseksi jatkotehtäväksi, kuten alkuperäinen ohje rajaa.
