# Procountor-liitäntä

API-selvitys, lähteet ja varmat tiedot erotettuna oletuksista ovat tiedostossa [docs/procountor-integraatio.md](../../docs/procountor-integraatio.md). Se on kirjoitettu OpenAPI-skeemasta `https://pts-api.procountor.com/api/openapi.json` (Procountor API 26.10, luettu 18.10.2026). Tätä tiedostoa ei pidä lukea toisena, ristiriitaisena API-kuvauksena.

## Mitä on jo mainissa

- Päivän myyntikirjaus rakentuu `booking._report_json`-kassaraportista tauluun `booking.accounting_exports` (booking_77–79). Johku jää raportin ulkopuolelle (`booking._acct_excluded`). Sitä ei kirjata uudelleen.
- Verkkolaskun välitys on sopimus `buildProcountorInvoice` + `send_invoice`. Omaa laskun PDF-hakua ei ole: `GET /invoices/{id}/image` on PNG/JPG.
- Oletus on edelleen `mode = off` ja `daily_enabled = false`. Ajastus ei lähetä mitään ennen kuin nämä kytketään. Salaisuudet ovat vain Edge-salaisuuksia.

## booking_103

Hallinnan Asetukset-sivulla voi tallentaa tilan, ympäristön, tilikartan (ALV 25,5 % / 13,5 % / 0 % ja historialliset 14 / 24 / 10), maksutapojen tilit, ALV-tilan numeron ja verkkolaskun IBAN-tilin. `live` vaatii hyväksyjän nimen ja päivän (`approval_required`) sekä ALV-tilan ja vähintään yhden myyntitilin ja yhden maksutavan tilin (`live_incomplete`). Esikatselu ei lähetä. Migraatio ei vaihda olemassa olevaa tilaa eikä koske tuotantoon. Numerot 80–83 on varattu pikakassalle.

## Mitä Joonakselta ja kirjanpitäjältä tarvitaan

Lista on selvityksen kohdassa 8. Lyhyesti: testi- ja tuotantoavaimet (`client_id`, `client_secret`, `redirect_uri`, API-avain), teknisen käyttäjän oikeudet, tilinumerot, `vat_status` hausta `GET /vats/default`, IBAN, verkkolaskuosoite ja operaattori, sekä `approved_by`, ALV-tila ja vähintään yksi myyntitili ja maksutavan tili ennen `live`-tilaa.
