# Koulutukset ja Matkat – hallinnan työtila (booking_255)

Lähde: hyväksytty **Hallinnan Koulutukset – uudistussuunnitelma**:
https://cursor.com/canvas/store-7b3bca7e-e6e8-4cc1-936c-22d4666c6717/b3122fe1-997e-4a9c-8a0c-b6ae4882f4ce

## Käyttö

- `#/koulutukset`: ajankohtaiset jaksokortit. Matkat omalla välilehdellä.
- Tuotteen luokittelu on `category=training`. Journey 121 on Matka; kopio perii ryhmän.
- Jakson yhteenveto ja valmiuslista, neljä osiota aina samassa järjestyksessä:
  Osallistujat, Viestit, Maksut, Tilat.
- **Muut tiedot → Tekstit** säilyttää #309:n FI/EN-sisältöeditorin.
- Osallistujan tiedot: ruokavalio, majoitus, saapumisaika ja kieli. Läsnäolorasti.
  Puolipiste-CSV avautuu Excelissä (UTF-8 BOM, kaavainjektiosuojaus); myös tulostus.
- Käsin lisättävä osallistuja on yksi henkilö/tilaus ja käyttää nykyistä varausmaksua.
  Osakertojen kapasiteetti kulutetaan nykyisillä koulutusapureilla.
- Odottajat on **käsin hoidettava FIFO-lista**. Seuraavan tarjous merkitään vasta oman
  yhteydenoton jälkeen. Ei viestiä eikä paikan automaattista lukitusta. Ilmoittautuminen
  tehdään erikseen, minkä jälkeen odottaja merkitään ilmoittautuneeksi.
- Tilat: Savusauna, Rauni, Lovi; yksi päivä sekä alku- ja loppuaika.
  Kurssin ensisijainen resurssi voi edelleen olla Ei resurssia.
- Viestit: saapumisohje, maksumuistutus tai oma viesti, molemmat kielet muokattavissa.
  Saapumisohjeen luonnos on täydennettävä. Tallenna pohja ei lähetä mitään.
  Esikatselu jäädyttää aiheen, tekstin, tapahtuman nimen, päivät ja vastaanottajat 30 minuutiksi.
  Muutos mitätöi UI-esikatselun. Lähetys vaatii vielä erillisen rastin ja painalluksen.
  Vastaanottajamuutos palvelimella estää vanhan esikatselun lähettämisen.
- Maksut näyttävät oikeat kirjautuneet maksut, eivät `deposit_paid`-kentän nimellissummaa.
  Loppumaksun lisääminen käyttää nykyistä tilauksen lisäosto-RPC:tä ja tallennettuja
  hintoja/verokantaa. Maksulinkit tarkistetaan ennen lähetystä. Valittujen lähetys on
  atominen: yksikin virhe peruu koko ryhmän. Nykyisen maksulinkin muistutusketju pysäytetään.
- Laskupainike avaa nykyisen laskutuspolun; sen yrityslaskutuksen rajoitukset säilyvät.
- Kopiointi: uusi aloituspäivä määrittää päiväsiirron. Valittu jakso, sen osakerrat,
  tilavaraukset ja viestipohjat kopioituvat; uudet omat kapasiteetit.
  Osallistujia, maksuja, odottajia tai lähetyshistoriaa EI kopioida. Uusi tuote piilotetaan.

## Tietokantamuutos – EI mergeä ennen käyttöönottoa

Tässä työssä ei ajeta migraatioita yhteenkään pilvikantaan.
Bottiavustus ajaa täsmälleen yhden uuden migraation ensin DEV:iin
`aoejjmfzulhkhxbehphs`, tarkistaa toiminnan, sitten tuotantoon `sxbofnuisemspgquoxyv`:

`booking/supabase/migrations/20261106180719_booking_255_training_workspace.sql`

Lisää vain booking-skeemaan viisi RLS-suojattua työtilataulua ja rajatut RPC:t.
Koulutuksen sulut käyttävät nykyistä `event_resource_blocks → space_blocks`-mekanismia,
samoja resurssilukkoja ja samaa päivänäkymän dataa kuin nykyiset käsisulut.
Kalenteriin lisätään vain sulkujen näkyminen. Muuta kalenteria ei korvata.

Migraatio ei korvaa nykyisiä koulutuksen kapasiteetti-/checkout-funktioita eikä muuta
olemassa olevia kapasiteettikytkentöjä (booking_254), tuotehintoja, ALV:a tai julkisia URL:eja.
Palvelimen RPC:t tarkistavat henkilökunnan/oikeuden ja käyttävät tyhjää search_pathia.
Arkaluonteisia käytännön tietoja ei kirjata audit-lokiin; asiakasanonymisointi siivoaa ne.
Vanhenneet viestiesikatselut siivotaan seuraavan esikatselun yhteydessä (ei uutta cron-tehtävää).

Palautusohje: `booking/supabase/rollbacks/20261106180719_booking_255_ROLLBACK.sql`.
Palautus poistaa uuden työtilarakenteen, ei jo luotuja tuotteita, tilauksia tai sulkuja
nykyisistä tauluista eikä peruuta lähetettyjä viestejä. Lue palautustiedoston varoitukset.

Sivutekstit: `content/site-texts.pending-import-127.json` (FI/EN, ei kulmasulkeita).
Tuo olemassa olevalla sivutekstien tuontimenettelyllä; identtiset UI-fallbackit toimivat ennen tuontia.
Tekstien tuontia ei ole tehty tässä työssä.

## Tarkistukset

- `node --test booking/tests/*.test.mjs`: 1313 testiä, 1312 hyväksyttyä; ainoa
  epäonnistuminen on ennestään sallittu `uusi-varaus.test.mjs` / ”yhdeksän kohtaa”.
- Uusi `koulutukset-tyokalu.test.mjs`: 12/12; aiempi `koulutukset-hallinta.test.mjs`: 6/6.
- `npm run build:prod`: onnistuu, ei julkaise.
- Paikallinen PostgreSQL 17, `booking/supabase/tests/t255_training_workspace.sql`: 40
  tarkistusta, transaktio päättyy rollbackiin. Kattaa sulut ja varauskonfliktit,
  nykyisen käsisulun säilymisen, päivän/kalenterin, molemminpuolisen Full–Retreat-kapasiteetin,
  oikeat maksut ja atomisen maksulinkkiryhmän, manuaalisen jonon, esikatseluportin,
  kielivalinnan, kaksoislähetyssuojan, kopioinnin ja oikeudet.
- Uusi migraatio sekä palautus ajettiin paikallisesti muuttamattomina ja virheeseen pysähtyen.
  Historiallisen testikannan alustuksessa jouduttiin ohittamaan puuttuvista integraatioista
  riippuvia vanhoja migraatioita ja niiden tuotantohash-vahteja; tämä ei ole koko
  historiallisen migraatioketjun tai tuotantodumpin toistotesti. Uutta migraatiota ei lievennetty.
- Ei oikeassa selaimessa tehtyä käyttötestiä tai live-sähköpostilähetystä.

## Tietoiset rajaukset ja oletukset

- Vanhaa automaattista julkista tapahtumajonoa ei muuteta eikä tuoda tähän uuteen
  manuaaliseen koulutusjonoon. Mahdolliset vanhat yhteydenotot siirretään käsin.
- Viestit käyttävät nykyistä sähköpostiputkea ja lähettäjää. Nykyinen tapahtumaviesti
  ei lisää automaattista allekirjoitusta (booking_213); henkilökunta kirjoittaa sen itse.
  Lähetetty-valmiusrasti tarkoittaa lähetysjonoon lisättyä viestiä, ei toimituskuittausta.
- Tilat varattu tarkoittaa vähintään yhtä tilariviä, ei arvausta kaikkien päivien tarpeesta.
  Ei yön yli jatkuvaa tilariviä lomakkeessa: jaa varaus päivittäisiin riveihin.
- Tämän työkalun manuaalinen lisäys on yksi osallistuja kerrallaan; olemassa olevat
  usean paikan varaukset näytetään paikkamäärineen.
- Kopio pitää saman päiväsiirron kaikissa osakerroissa; yksittäiset päivät voi muuttaa
  myöhemmin aiemmasta Kerrat-näkymästä. Kopion FI/EN-nimi alkaa annetusta nimestä.
- Ei osallistujaportaalia, todistusautomaatiota, automaattiviestejä, ajastuksia,
  markkinointiuudistusta, hinnoittelumoottoria tai vuorotarjousmoottoria.
- Ei WordPress-, saunahealer.com-, saunakoulutus.fi- tai SFTP-muutoksia.
