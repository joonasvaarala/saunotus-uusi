# Koulutusten tilavarausten kalenterisynkka (booking_256)

## Toiminta

- Uusi tilavaraus tehdään hallinnan **Koulutukset → jakso → Tilat** -kohdassa.
  Google-kalenterissa luotuja tapahtumia ei tuoda tilavarauksiksi, vaikka niihin
  kopioitaisiin viedyn tapahtuman otsikko tai metatiedot.
- Nykyinen `booking-calendar-sync` ja sen viiden minuutin ajastus vievät yhden
  tapahtuman kutakin aktiivisen koulutusjakson `event_resource_blocks`-riviä kohti
  (`mode=exclusive`, fyysinen Savusauna/Rauni/Lovi). Avaimena on `e:block:<id>`;
  Google-tunniste muodostuu nykyisellä `bke` + avaimen MD5 -käytännöllä.
- Ajat tulevat `_event_block_range`-funktiosta, eivät koko jakson kestosta.
  Myös yön yli jatkuvat sekä suhteelliset tilavaraukset toimivat.
- Jokaisella tilalla on **oma** `booking_calendar.settings.resource_calendars`
  -kalenteri savusauna-tilillä. Otsikossa on tilan nimi ja koulutuksen/jakson nimi.
  Koulutusten tilavarauksille ei käytetä yhteistä varakalenteria. Puuttuva,
  sulku-/työvuorokalenteriin osoittava tai toisen tilan kanssa sama kalenteritunnus
  jättää rivin ilman vientikohdetta (esikatselun *Ilman kalenteria*).
- Kaikki tulevat koulutusten tilavaraukset viedään, myös yli 180 päivän päähän.
  Menneisyyden raja on edelleen sama `window_back_days`. Muiden vientien
  aikaikkunaa, kalenteritunnisteita tai käyttäjän asetuksia ei muuteta.

## Google → hallinta

Uusi `booking_calendar_training_export_plan()` käyttää samaa suunnitelmaa,
vientikirjanpitoa (`booking_calendar_events`), lukitusleimaa ja finish-RPC:tä kuin
nykyinen vienti. Ei uutta cron-ajoa, kalenteripalvelua tai rinnakkaista outboxia.

Ennen ulospäin kirjoittamista Edge lukee vain jo vietyjen ja edelleen olemassa
olevien tilavarausten **täsmälliset Google-tunnisteet**. Ajan muutos tai poisto
sovelletaan palveluroolille rajatulla `apply_training_calendar_events`-RPC:llä
saman vientiajon lukituksen alla:

- Ajan muutos päivittää `event_resource_blocks`-rivin suhteelliset päivät ja
  paikalliset kellonajat. Nykyinen `zz_event_sync` / `_event_sync_blocks` päivittää
  saman `space_blocks`-rivin. Hallitut sulut eivät mene sulkukalenterien outboxiin.
- Google-poisto poistaa kyseisen `event_resource_blocks`-rivin. Nykyinen FK ja
  synkka poistavat materialisoidun `space_blocks`-rivin; tila vapautuu. **Kurssi,
  osallistujat ja muut tilavaraukset eivät peruunnu.** Seuraava täsmäytys ei palauta
  poistettua tilavarausta. Myös uudelleenyritykset ovat idempotentteja.
- Pelkkää Googlen 404/410-vastausta ei tulkita poistoksi: samalla kalenterilla
  onnistuneen `events.list`-kutsun täytyy vahvistaa käyttöoikeus. Kadonnut jako tai
  API-virhe ei vapauta tilaa.
- Aktiivisen tapahtuman vientimetatietojen on vastattava kirjanpitoa. Tuntematonta
  tapahtumaa ei luoda, omaksuta eikä yhdistetä kurssiin. Poistotombstonelle riittää
  kirjanpidon täsmällinen kalenteri- ja tapahtumatunniste.
- Tila ja jakso lukitaan nykyisillä resurssilukoilla. Muita varauksia, käsisulkuja
  tai muiden tapahtumien tilavarauksia ei saa yliajaa. Virhe keskeyttää inbound-
  transaktion ja koko kyseisen vientiajon **ennen Google-kirjoituksia**. Virhekoodi
  näkyy nykyisen varauskalenterin viimeisimmän ajon tilassa; korjaa Google-aika ja
  anna seuraavan ajon yrittää uudelleen.
- Samanaikaisissa kellonaikamuutoksissa hallinnan paikallinen muutos voittaa
  (vertailu viimeksi vietyihin aikoihin). Nimenomainen Google-poisto voittaa
  kellonaikamuutoksen. Googlen ETag / `If-Match` estää myöhemmän Google-muutoksen
  ylikirjoittamisen samalla ajolla. Juuri luennan jälkeen poistettua tapahtumaa
  ei luoda patch-polulta takaisin.

## Rajaukset

- Vain tilavarauksen aika ja poisto ovat kaksisuuntaisia. Otsikon/kuvauksen
  muokkaus ei muuta kurssia. Tilan vaihtaminen siirtämällä tapahtuma toiseen
  kalenteriin ei ole tuettu käyttöpolku: tee tilan vaihto hallinnassa.
- Ei kalenterista luontia, koko päivän tapahtumia, toistuvia tapahtumia eikä
  kurssin päivien tai osallistujavarausten siirtämistä.
- Nykyisen tilavarausmallin rajat säilyvät: päivän on oltava suhteessa jakson
  aloituspäivään välillä **−1…14**. Kauemmas siirto hylätään. Kesä-/talviajan
  kellonsiirron hetki hylätään, ellei sitä voi esittää nykyisillä paikallisilla
  kellonaikakentillä yksiselitteisesti.
- Jos ensimmäinen Google-luonti onnistui mutta vientikirjanpidon tallennus katkesi,
  saman tunnisteen olemassa oleva tapahtuma hyväksytään kirjanpitoon vain, jos
  alkuperä ja ajat vastaavat edelleen hallintaa. Muokattu/poistettu orpo aiheuttaa
  `training_unmapped_event_conflict`-virheen eikä sitä ylikirjoiteta: tarkista
  tapahtuma ja vientikirjanpito ylläpitotyönä.
- `off` ja `dry_run` eivät lue/sovella Google-muutoksia eivätkä kirjoita Googleen.
  Hinnoittelu, ALV, URL-osoitteet, kapasiteetti ja työvuoro-/sulkusynkat säilyvät.

## Käyttöönotto (ei ajettu tästä haarasta)

1. Bottiavustus ajaa ensin DEViin, sitten PRODiin **ennen mergeä**:
   `booking/supabase/migrations/20261106191752_booking_256_training_calendar_sync.sql`.
   Migraation MD5-vartija estää olemassa olevien vientifunktioiden huomaamattoman
   ylikirjoittamisen, jos niiden määritelmät ovat muuttuneet.
2. Migraation aikana vanha Edge saa edelleen vanhasta
   `booking_calendar_export_plan()`-RPC:stä vain yksisuuntaiset tapahtumat ja niiden
   kirjanpidon. Se ei luo, ylikirjoita eikä poista uusia `e:block:*`-tapahtumia.
   Uusi Edge käyttää eri nimistä plan-RPC:tä saman infrastruktuurin päällä.
3. Hyväksytyn mergen/julkaisun yhteydessä julkaise myös päivitetty
   **`booking-calendar-sync` Edge Function**. Pelkkä staattisen sivuston julkaisu
   ei aktivoi kaksisuuntaisuutta. Nykyiset palvelutili-/cron-salaisuudet riittävät.
4. Staattisen hallinnan mukana tulevat FI/EN-varatekstit. Haluttaessa tuo
   `content/site-texts.pending-import-128.json` tavallista sivutekstipolkua pitkin;
   uusia avaimia käytetään, joten vanhat julkaistut tekstit eivät peitä ohjetta.
5. Seuraavan live-ajon pitäisi viedä olemassa olevat rivit **11–16** sellaisinaan.
   Migraatio ei luo niistä uusia rivejä eikä keksi 4. viikonlopun varausta.
   Varmista savusaunan ja Raunin omat kalenterit sekä elo-/syyskuu 2027.
6. Tee DEVissä erillisellä testijaksolla aika- ja poistokoe. Tarkista molemmat
   taulut ja hallinta; tuotannon kuutta oikeaa tilavarausta ei käytetä poistotestiin.

Rollback: `booking/supabase/rollbacks/20261106191752_booking_256_ROLLBACK.sql`.
Pysäytä vienti tai palauta vanha Edge ennen SQL-rollbackia. Rollback palauttaa
vanhat kaksi vientifunktiota ja poistaa uudet RPC:t. Vanha vienti siivoaa
`e:block:*`-Google-tapahtumat seuraavalla ajolla. Jo hyväksyttyjä kellonaikamuutoksia
ja poistoja ei peruta eikä puuttuvia tilavarauksia luoda uudelleen.

## Testit

```sh
deno test --no-lock booking/supabase/functions/booking-calendar-sync/{core_test,training_test}.ts \
  booking/supabase/functions/_tests/booking_calendar_sync_test.ts
node --test booking/tests/koulutukset-tyokalu.test.mjs booking/tests/varauskalenteri.test.mjs
# Paikallinen fixture-Postgres, jossa migraatiot 255 ja 256 on ajettu:
psql -X -v ON_ERROR_STOP=1 -f booking/supabase/tests/calendar/t256_training_calendar_sync.sql
psql -X -v ON_ERROR_STOP=1 -f booking/supabase/tests/t255_training_workspace.sql
```

SQL-testit peruuttavat omat datansa. Migraatio ja rollback on lisäksi kokeiltu
paikallisesti. Uuden migraation testaaminen ei vaadi eikä käytä etäkantakirjoitusta.
