# Terassin hälytysnappi – Shelly BLU Gateway Gen3 -asennus

Skripti: `call-button-gateway.js` (booking_340–342, sopimus KOODARI.md). Laitteet: 2 × Shelly BLU Button Tough ZB
(Mökki, Yläterassi) ja 2 × Shelly BLU Gateway Gen3 (vastaanottimet). **Molemmat napit paritetaan molempiin
vastaanottimiin**: sama painallus voi tulla kahdesti, ja kanta deduppaa sen (MAC + BTHome pid, 15 s).

## 1. Napit
- Napit lähettävät BTHome v2 -mainoksia. **Älä ota nappien BTHome-salausta käyttöön** (skripti ei pura salattuja paketteja).
- Pariuta nappi kummankin vastaanottimen web-käyttöliittymässä (Components → Add BLU device), jotta molemmat näkevät sen.
- Skripti ei vaadi paritusta toimiakseen (se kuuntelee mainoksia suoraan), mutta paritus pitää laitteet näkyvissä sovelluksessa.

## 2. Skripti kumpaankin vastaanottimeen
1. Vastaanottimen web-käyttöliittymä → **Scripts** → **Create script** → nimi `call-button`.
2. Liitä `call-button-gateway.js`:n sisältö, tallenna.
3. Aseta KVS-avaimet (Settings → KVS tai RPC). Arvoja ei kirjoiteta skriptiin eikä repoon:

| KVS-avain    | Arvo                                                                   |
|--------------|------------------------------------------------------------------------|
| `cb_url`     | `https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/call-button-press` (PROD) |
| `cb_secret`  | `CALL_BUTTON_WEBHOOK_SECRET` (sama arvo kuin Supabasen salaisuus)      |
| `cb_gateway` | `gw-mokki` (mökin vastaanotin) tai `gw-ylaterassi` (yläterassin vastaanotin) |

   RPC-esimerkki (paikallisverkosta, arvo syötetään käsin, ei tallenneta mihinkään):
   `http://<gateway-ip>/rpc/KVS.Set?key="cb_gateway"&value="gw-mokki"`
4. Käynnistä skripti ja laita **Run on startup** päälle.
5. Lokissa näkyy `call-button: käynnissä, gateway=gw-mokki, url ok, salaisuus ok`. Salaisuutta ei tulosteta.

## 3. Toiminta
- Vain BTHome v2 -paketit, joissa on button-objekti 0x3A. Muut BLE-laitteet jätetään huomiotta.
- Tapahtumat: 1 `single_push`, 2 `double_push`, 3 `triple_push`, 4 `long_push`, 5 `long_double_push`,
  6 `long_triple_push`, 0x80 `hold`; muu nollasta poikkeava arvo → `press`. Arvo 0 (none) ohitetaan.
- POST `cb_url`: `{"mac","pid","event","gateway","rssi","battery"}` + otsake `x-call-button-secret`.
- Epäonnistunut POST (verkkovirhe, 429, 5xx) uusitaan 2 kertaa: 1 s ja 3 s. Uusinta on turvallinen, koska kanta deduppaa saman pid:n.
- Sama mainos toistuu radiossa useasti; skripti välittää saman napin saman pid:n vain kerran.

## 4. MACin rekisteröinti
Tuntemattoman napin painallus kirjataan `booking.call_button_presses`-tauluun tilalla `unknown_device`.
Ensimmäisen testipainalluksen jälkeen MAC luetaan sieltä ja Bottiavustus lisää sen `booking.call_button_devices`-tauluun.
Lippu `call_button_enabled` pysyy pois päältä, kunnes Joonas avaa sen; siihen asti painallukset kirjautuvat tilalla `disabled`.
