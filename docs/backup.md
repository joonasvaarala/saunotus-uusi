# Varmuuskopio (Tapio-havuhattu)

Projekti `sxbofnuisemspgquoxyv` (Postgres 17, alue eu-west-3, ilmainen paketti). Kannassa on yrityksen data: skeemat `kb`, `booking`, `auth`, `storage` ja muut. Tämä varmuuskopio on Supabasen ulkopuolella.

Työnkulku on `.github/workflows/db-backup.yml`. Se ei käynnisty pull requestissa eikä julkaise sivuja. Ajastus toimii vasta, kun tiedosto on `main`-haarassa. Käsin ajo onnistuu Actions-välilehdeltä haarasta, jossa tiedosto on.

## Mitä kopioidaan

Joka yö syntyy yksi tiedosto `tapio-havuhattu_YYYY-MM-DD_HHMM.dump.tar.age` (kellonaika UTC). Se on age-salattu tar-paketti, jossa on:

- `database.dump` — `pg_dump -Fc` (custom-muoto) koko kannasta, johon rooli pääsee. Mukana ovat vähintään `public`, `kb`, `booking`, `auth`, `storage` ja `supabase_migrations`. `cron` tulee mukaan, jos se on luettavissa.
- `manifest.json` — rivimäärät tauluista `booking.orders`, `booking.payments`, `booking.gift_cards`, `booking.reservations`, `kb.products` ja `booking.bookings` jos se on olemassa. Taulua `booking.bookings` ei ole: varaukset ovat `booking.reservations`.
- `roles.sql` — rooliluettelo **ilman salasanoja**. Katso alla, miksi `pg_dumpall` ei yleensä onnistu.
- `storage/` — bucketien tiedostot ja `storage/manifest.json` (polku, tavumäärä, sha256).
- `dump.log` — pg_dumpin loki, josta mahdolliset yhteysosoitteet on poistettu.

Ei mukana:

- Edge Function -lähteet (ne ovat tässä repossa).
- Roolien salasanat, GitHub-salaisuudet, age-yksityinen avain.
- Vaultin selväkieliset salaisuudet. Dumppi sisältää vault-salaisuudet vain salatussa muodossa (`vault.secrets`). Näkymän `vault.decrypted_secrets` rivejä ei kirjoiteta dumppiin.
- Large objectit, jos roolilla ei ole niihin oikeutta. `pg_read_all_data` ei kata niitä. Skripti yrittää silloin uudelleen `--no-large-objects`. Tämän projektin tiedostot ovat Storagessa, ei large objecteina.

Työkalu on `pg_dump` pääversiolla 17, sama kuin kanta. Yhteys on secretissä `SUPABASE_BACKUP_DB_URL`: **session pooler tai suora yhteys, portti 5432**. Portti 6543 on transaktiopooleri, ja skripti kieltäytyy siitä (`pg_dump` ei toimi siinä).

Suora yhteys `db.sxbofnuisemspgquoxyv.supabase.co` on ilmaisella paketilla usein vain IPv6. GitHubin ajurit ovat IPv4. Käytä session pooleria.

## Supabasen omat kopiot

Ilmaisella paketilla Supabase ei säilytä päivittäisiä varmuuskopioita. Supabase suosittelee viemään datan itse.

Pro-, Team- ja Enterprise-paketeissa Supabase ottaa päivätason kopiot (Pro: 7 päivää, Team: 14, Enterprise: 30). Ne eivät korvaa tätä kopiota:

- Ne eivät sisällä Storagen tiedostoja, vain tiedostojen metatiedot kannassa.
- Ne eivät sisällä itse luotujen roolien salasanoja. Palautuksen jälkeen salasanat pitää asettaa uudelleen.
- Projektin poisto hävittää myös Supabasen omat kopiot.

Point-in-Time Recovery on Pro-lisäosa, ei tämän ilmaisen projektin käytössä.

## Roolit (`pg_dumpall`)

Skripti ajaa `pg_dumpall --roles-only --no-role-passwords`. Postgres 17:ssä tämä voi onnistua ilman superuseria, ja salasanoja ei silloin tule mukaan. Supabasessa komento epäonnistuu silti usein, koska `postgres` ei saa lukea `pg_authid`-katalogia. Silloin `roles.sql` on luettelo (`pg_roles` ja jäsenyydet) ilman salasanoja, eikä sitä ajeta palautuksessa. Molemmissa tapauksissa objektien oikeudet ovat `database.dump`-tiedostossa, ja roolien salasanat pitää asettaa palautuksen jälkeen käsin.

## Storage

Service role -avainta ei käytetä. Se ohittaisi RLS:n ja antaisi kirjoitusoikeuden.

Tiedostolista luetaan `storage.objects`-taulusta `backup_reader`-yhteydellä. S3-avaimia ei käytetä.

- Julkiset bucketit `article-images` ja `product-images`: lataus ilman avainta osoitteesta `/storage/v1/object/public/<bucket>/<polku>`.
- Yksityiset `receipts` ja `invoices` (kuitit ja laskut, laskut säilytetään kirjanpitolain mukaan): erillinen Auth-käyttäjä, jolla on vain luku näihin bucketeihin. Tunnistus on `app_metadata.backup_role = storage_reader`, ei sähköposti. Lataus on `/storage/v1/object/authenticated/<bucket>/<polku>` käyttäjän omalla istunnolla ja julkisella anon-avaimella.
- Jos yksityisiä tiedostoja ei saada, ajo jatkuu, merkintä jää `manifest.json`-tiedostoon ja tietokantadumppi tehdään silti.
- Muut bucketit jätetään lataamatta ja nimetään manifestissa.

Käyttäjällä ei ole `booking.staff`-riviä eikä henkilöstöroolia. `kb`- ja `booking`-taulujen RLS vaatii `is_staff()` tai `has_permission()`, joten pelkkä kirjautuminen ei näytä muuta dataa. Politiikka on vain `SELECT` bucketeihin `receipts` ja `invoices`.

## Salaus

Arkisto salataan ennen lähetystä [age](https://github.com/FiloSottile/age)-työkalulla. GitHubissa on vain julkinen avain (`BACKUP_AGE_PUBLIC_KEY`). Yksityinen avain jää Joonakselle salasananhallintaan. Sillä puretaan kopio hätätilanteessa. Ilman sitä Drive-tiedostoa ei voi lukea, eikä Actions pysty purkamaan tuotantokopiota.

## Säilytys

Vain backup-kansiossa, vain nimillä `tapio-havuhattu_YYYY-MM-DD_HHMM.dump.tar.age`:

- Muut tiedostot jätetään.
- Alle 30 päivää vanhat päiväkopiot pidetään.
- Kuukauden 1. päivän kopio pidetään 12 kuukautta (tiedostonimen päivä on 01).
- Vanhemmat kuvion mukaiset tiedostot poistetaan `rclone deletefile`-komennolla, yksi kerrallaan.
- Kuivaharjoitus on oletus skriptissä. Työnkulku poistaa vain onnistuneen lähetyksen jälkeen.
- Jos poisto veisi viimeisen kuvion mukaisen kopion, mitään ei poisteta.
- Yli 400 tiedoston poistolista keskeyttää ajon (raja `BACKUP_RETENTION_MAX_DELETE`).
- Nimet, joissa on polku, katkaisevat ajon.

Kellonaika cronissa on **00:15 UTC**. Se on talvella 02:15 Suomen aikaa (EET) ja kesällä 03:15 (EEST). Yksi cron-rivi ei vaihda kesäaikaan. 00:15 UTC on yöllä molempina vuodenaikoina, ja 1. päivän ajo osuu Suomessa samalle kalenteripäivälle, joten kuukausikopio syntyy.

Kuukauden 1. päivän ajastettu ajo tekee lisäksi palautustestin. Jos 1. päivän ajo epäonnistuu, kuukausikopiota ei synny jälkikäteen toisena päivänä ajetusta korvaavasta ajosta.

## Palautustesti

`scripts/backup/restore-test.sh` palauttaa dumpin tietokantaan `backup_restore_test` ja vertaa rivimääriä manifestiin.

Kohde sallitaan vain koneille `127.0.0.1`, `localhost`, `::1` ja `postgres` (Actionsin kontti). Osoite, jossa on `supabase` tai projektiviite, hylätään. Tuotantoon ei kirjoiteta.

Ajastettu ajo kuukauden 1. päivänä (Helsingin päivä) ja käsin valittu `restore_test` käynnistävät Actionsissa `postgres:17`-kontin ja palauttavat **juuri otetun salaamattoman dumpin** siihen ennen kuin ajuri tuhotaan. Yksityistä avainta ei tarvita tähän, eikä dumppia ladata artefaktina.

Tuotannon age-tiedoston purku Drivesta testataan omalla koneella, jossa yksityinen avain on:

```bash
RESTORE_TARGET_URL='postgresql://postgres:SALASANA@127.0.0.1:5432/postgres' \
  scripts/backup/restore-test.sh \
  --archive tapio-havuhattu_YYYY-MM-DD_HHMM.dump.tar.age \
  --identity /polku/tapio-havuhattu-backup.key
```

`RESTORE_TARGET_URL` on paikallisen Postgresin ylläpitokanta `postgres`. Skripti luo ja tarvittaessa tuhoaa vain kannan `backup_restore_test`.

Vanilla `postgres:17` ei ole Supabase. Täysi tuotantodumppi voi tarvita Supabase-laajennuksia (`pg_net`, `pg_cron`, vault). Skripti yrittää ensin `pg_restore --exit-on-error` ja sen epäonnistuessa uudelleen ilman sitä. Ajo on punainen, jos manifestin rivimäärät eivät täsmää.

## Joonaksen kertaluonteiset askeleet

Omalla koneella. Älä liitä avaimia, tokeneita, salasanoja tai osoitteita repoon, chattiin tai issueen. Ilman secretiä yöajo on vihreä ja Actionsissa näkyy ilmoitus puuttuvista nimistä (`docs/backup.md`).

1. **age.** `age-keygen -o tapio-havuhattu-backup.key`. Vain julkinen avain (`age1...`) → secret `BACKUP_AGE_PUBLIC_KEY`. Yksityinen avain (`AGE-SECRET-KEY-1...`) vain salasananhallintaan.
2. **Drive.** Tilillä `sipoonjoenperinnesauna@gmail.com` kansio, esimerkiksi `tapio-havuhattu-varmuuskopiot`. Kansion ID osoitteesta → secret `BACKUP_DRIVE_FOLDER_ID`.
3. **rclone.** Komennot yksi kerrallaan: `rclone version`, sitten `rclone authorize "drive"` (oletusscope `drive`, ei `drive.file`: selaimessa luotu kansio jäisi näkymättä). Palvelutili ei toimi tavallisella Gmaililla. Kirjaudu samalle tilille ja kopioi koko JSON → secret `RCLONE_DRIVE_TOKEN`.
4. **Rooli.** Aja `booking/supabase/migrations/20261019140000_ops_001_backup_reader.sql`. Sitten vain SQL-editorissa `alter role backup_reader password 'pitkä-satunnainen-salasana';`. Salasana on yhtä arvokas kuin koko kanta (`vault.decrypted_secrets` ja `net`-jonot). Secret `SUPABASE_BACKUP_DB_URL`: Connect → Session pooler, portti 5432, käyttäjä `backup_reader.sxbofnuisemspgquoxyv`, isäntä Connect-valikosta (`aws-0` tai `aws-1`). Erikoismerkit prosenttikoodauksella.
5. **Storage-käyttäjä.** Dashboard → Authentication → Add user. Sähköposti esim. `backup@saunotus.fi`, auto-confirm, salasana salasananhallintaan. App metadataan avain `backup_role` = `storage_reader` (älä tyhjennä muita avaimia; ei User metadata). Älä lisää `booking.staff`-riviä äläkä booking-roolia, jotta hallinta ei aukea. Aja `booking/supabase/migrations/20261019140100_ops_002_backup_storage_read.sql`. Secretit `BACKUP_STORAGE_EMAIL` ja `BACKUP_STORAGE_PASSWORD`. Muuttujat (eivät ole salaisuuksia): `SUPABASE_URL` = `https://sxbofnuisemspgquoxyv.supabase.co` ja `SUPABASE_ANON_KEY` = julkinen anon- tai publishable-avain. Ilman näitä tietokantadumppi syntyy, mutta yksityiset kuitit ja laskut jäävät manifestin merkintään.
6. **GitHub** (Settings → Secrets and variables → Actions). Secretit: `SUPABASE_BACKUP_DB_URL`, `BACKUP_AGE_PUBLIC_KEY`, `RCLONE_DRIVE_TOKEN`, `BACKUP_DRIVE_FOLDER_ID`, `BACKUP_STORAGE_EMAIL`, `BACKUP_STORAGE_PASSWORD`. Muuttujat: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, valinnainen `BACKUP_MIN_DUMP_BYTES` (oletus 1048576).
7. **Sähköposti.** Workflow ei lähetä omaa viestiä. Punainen ajo tulee, kun Notifications → Actions ja repon Watch → Custom → Actions ovat päällä.
8. **Ensimmäinen ajo** vasta `main`-haarassa. Actions → Varmuuskopio (Tapio-havuhattu). Ensin vain `retention_dry_run` (ei dumppia, ei poistoa; riittää rclone-secretit). Sitten ajo ilman rastia. Tarkista tiedosto `tapio-havuhattu_....dump.tar.age`. Älä commitoi salaisuuksia. Rollback: `20261019140100_ops_002_ROLLBACK.sql` ja `20261019140000_ops_001_ROLLBACK.sql`.

## Jos lukurooli ei riitä

Migraatio epäonnistuu, jos `postgres`-rooli ei saa luoda `BYPASSRLS`-roolia. Silloin dumppia ei pidä ajaa vajaalla roolilla.

Jos rooli syntyy mutta `pg_dump` kaatuu skeemaan, johon `pg_read_all_data` ei yllä (harvinaista `auth`- tai sisäisissä skeemoissa), väliaikainen vaihtoehto on laittaa `SUPABASE_BACKUP_DB_URL`:iin **postgres-roolin** session pooler -osoite (käyttäjä `postgres.sxbofnuisemspgquoxyv`, portti 5432). Sillä on laajemmat oikeudet. Manifestiin jää merkintä `using_postgres_role`. Vaihda takaisin `backup_reader`-osoitteeseen, kun puute on korjattu. `postgres`-salasana on projektin tietokantasalasana, ei `backup_reader`-salasana.

`pg_dump` ei ota event triggereitä ilman superuseria. Ne ovat Supabasen sisäisiä. Custom-roolien salasanat eivät ole dumpissa.

Rooli voi itse ajaa `set default_transaction_read_only = off`, koska asetus on oletus, ei pakko. `pg_read_all_data` on pelkkä luku, mutta Supabase antaa `PUBLIC`-oikeuden `net`-skeeman jonotauluihin, joten rooli voi kirjoittaa niihin (esimerkiksi `net.http_request_queue`). Se voi myös lukea `vault.decrypted_secrets` selväkielisenä. Salasana on siksi yhtä arvokas kuin koko kannan data. Yhteysraja on 8. `vault` ei ole migraation eksplisiittisessä skeemalistassa: dumpin kattaa `pg_read_all_data`.

## Palautus hätätilanteessa

Actionsin palautustesti ei palauta tuotantoa. Tuotannon palautus tehdään käsin, ensin erilliseen kantaan.

### Purku

```bash
age -d -i tapio-havuhattu-backup.key -o kopio.tar tapio-havuhattu_YYYY-MM-DD_HHMM.dump.tar.age
tar -xf kopio.tar
pg_restore --list database.dump | less
```

### Koko kanta uuteen Postgresiin

Älä osoita tätä tuotannon yhteysmerkkijonoon.

```bash
createdb palautus
pg_restore --no-owner --no-acl --dbname=palautus database.dump
```

Supabase-projektiin palautettaessa luo **uusi** projekti, käytä sen session pooleria ja `postgres`-käyttäjää. Osa laajennuksista ja sisäisistä skeemoista voi antaa virheitä vanilla-Postgresissa. Tarkista `manifest.json`-rivimäärät:

```sql
select count(*) from booking.orders;
select count(*) from booking.payments;
select count(*) from booking.gift_cards;
select count(*) from booking.reservations;
select count(*) from kb.products;
```

Storage-tiedostot ovat hakemistossa `storage/files/<bucket>/`. Ne ladataan uuteen projektiin erikseen (dashboard tai Storage API). Kannan palautus ei palauta tiedostoja.

### Yksittäinen taulu

Listaa ensin, että taulu on dumpissa (`pg_restore --list`). Palauta se **paikalliseen tai uuteen** kantaan, ei suoraan tuotantoon:

```bash
pg_restore --data-only --disable-triggers --schema=booking --table=orders --dbname=palautus database.dump
```

`--disable-triggers` vaatii superuserin ja ohittaa viiteavaimet latauksen ajaksi. Vertaa rivimäärää manifestiin. Jos tuotannon taulu on korruptoitunut, ota uusi kopio ennen kuin tuotantoon kosketaan, pysäytä kirjoitukset ja siirrä tarkistetut rivit tuotantoon vasta sen jälkeen. Tätä ei ole automatisoitu.

### Tuotantoprojektin palautus

Supabasen oman kopion palautus (jos projekti on joskus Pro ja kopioita on) tehdään dashboardista Database → Backups. Se katkaisee projektin palautuksen ajaksi eikä palauta Storage-tiedostoja.

Tämän Drive-kopion palautus olemassa olevaan tuotantoprojektiin on viimeinen keino: se korvaa dataa, eikä `restore-test.sh` suostu siihen. Käytä uutta projektiä tai paikallista kantaa, tarkista rivimäärät, ja vasta sitten päätä tuotannosta erikseen.

## Ajastuksen viive

GitHub voi myöhästyttää ajastettua ajoa ruuhkassa. Punainen tai puuttuva ajo näkyy Actions-välilehdellä. Kuivaharjoituksen ja oikean ajon voi käynnistää käsin (`workflow_dispatch`).
