# Varauskalenteri (vienti Googleen)

Yksisuuntainen vienti: vahvistetut varaukset näkyvät erillisessä Google-kalenterissa. Kalenterissa tehty muutos ei muuta varausta. Käytössä-tilassa Googleen kirjoitetaan vain, kun tapahtuman sisältö on muuttunut. Noin tunnin välein tehdään täysi uudelleenkirjoitus, joten kalenterista käsin poistettu tapahtuma palautuu seuraavassa täydessä ajossa.

Sulkukalenterit (`1 savusauna kiinni`, `1 perinnesaunotus kiinni`, `1 hoidot kiinni`, `1 Rauni kiinni`) pysyvät kaksisuuntaisina. Niiden tunnuksia ei käytetä tässä viennissä.

## Mitä kalenteriin tulee

- **Yksityinen varaus** on edelleen oma tapahtuma. Otsikko esimerkiksi `Savusauna – yksityisvaraus, 8 hlö`. Kuvauksessa on tilausnumero ja nimi tai yrityksen nimi sekä linkki hallintaan. Puhelinta ja sähköpostia ei kirjoiteta.
- **Päiväpalkki** tulee jokaiselle Helsinki-päivälle, jolla on vähintään yksi vahvistettu varaus, myös pelkälle yksityis- tai yritysvaraukselle. Palkki on yhteisessä Varaukset-kalenterissa. Se alkaa päivän ensimmäisen varauksen alusta ja päättyy viimeisen loppuun. Otsikko esimerkiksi `Varaukset 14–20 · 12 hlö (7 varausta)`. Jos palkki jatkuu yli keskiyön, tasan keskiyö näkyy lopussa `24`:na ja myöhempi loppu merkinnällä `+1`.
- Aikaisempi varaus leventää alkua. Peruutus lyhentää palkkia. Palkki poistuu vasta, kun päivän viimeinenkin varaus peruuntuu. Yksityiset tapahtumat pysyvät niin kauan kuin niiden varaukset ovat voimassa.
- Päiväpalkin kuvaus on erittely vuoroittain ja resursseittain. Siinä ei ole nimiä, puhelinta eikä sähköpostia.
- Mukaan otetaan varaukset, joiden tila on confirmed, completed tai no_show, tilaus on confirmed tai completed, eikä maksu ole kesken (`pending`) tai epäonnistunut (`failed`). Maksamatta oleva vahvistettu tilaus (kuten Johku-tuonti) näkyy. Keskeneräinen kassa ei näy.

Päiväpalkin kohde on **yhteinen kalenteri** (`shared_calendar_id`). Resurssin oma tunnus ohittaa sen vain kyseisen resurssin yksityisvarauksessa. Tyhjä yhteinen tunnus ei vie päiväpalkkia. Tunnukset ja tili vaihdetaan asetuksesta, ei koodista.

Vanhat vuoropalkit (`s:`), jos niitä on, eivät ole enää haluttuja. Seuraava käytössä-ajo poistaa ne. Toinen ajo ei löydä niitä uudelleen. Vientiä ei ole ajettu, joten tuotannossa rivejä on nyt nolla.

Ikkuna on oletuksena tänään − 7 päivää … + 180 päivää (Europe/Helsinki). Ajo on viiden minuutin välein. Nopea päivitys on valinnainen ja oletuksena pois.

## Oletus on pois

`integration_config.key = booking_calendar`, `mode = off`. Ajastus saa olla olemassa: `booking.booking_calendar_dispatch` palaa heti eikä kutsu Edgeä eikä Googlea. Pois-tilassa lausetriggeri `booking_calendar_nudge` palaa heti eikä päivitä tilariviä, jotta siivousajot ja rinnakkaiset varaukset eivät odota samaa lukkoa. Harjoitusajo (`dry_run`) laskee tapahtumat eikä kirjoita. `live` kirjoittaa Googleen vain muuttuneet tapahtumat. Täysi kirjoitus (`last_reconcile_at`, tunnin välein) palauttaa kalenterista poistetun tapahtuman.

## Kytkentä

1. Luo kalenteri halutulle Google-tilille (yksi nimeltä Varaukset). Tiliä ei ole lukittu koodiin: se voi olla nykyinen tai myöhemmin `savusauna@saunotus.fi`.
2. Jaa kalenteri olemassa olevan palvelutilin `client_email`-osoitteelle (salaisuus `GOOGLE_SERVICE_ACCOUNT_JSON`, sama kuin sulkusynkassa) oikeudella **Make changes to events**.
3. Kopioi kalenterin tunnus (muotoa `…@group.calendar.google.com` tai vastaava id).
4. Hallinta → Asetukset → Varaukset: liitä tunnus, tallenna. Älä liitä sulkukalenterin tunnusta.
5. Jätä tila pois tai vaihda harjoitusajoon ja katso esikatselun luvut. Esikatselu ei lähetä mitään.
6. Kun tunnus ja jako ovat kunnossa, vaihda tilaksi käytössä.

Hallinnan linkki tapahtuman kuvauksessa on `site_base_url` + `/hallinta`, ellei asetukseen ole annettu muuta https-osoitetta.

## Deploy

Migraatio `20261019161000_booking_114_calendar_export` luo taulut, funktiot ja ajastuksen `booking_calendar_export` (`*/5 * * * *`). Rollback: `booking/supabase/rollbacks/20261019161000_booking_114_ROLLBACK.sql`.

Migraatio `20261019221500_booking_115_calendar_quiet` hiljentää pois-tilan triggerin ja lisää täyden kirjoituksen leiman. Rollback: `booking/supabase/rollbacks/20261019221500_booking_115_ROLLBACK.sql`.

Migraatio `20261020053000_booking_116_calendar_day` kokoaa yleiset vuorot päiväpalkiksi ja jättää yksityisvaraukset omiksi tapahtumikseen. Rollback: `booking/supabase/rollbacks/20261020053000_booking_116_ROLLBACK.sql`. Nykyinen Edge poistaa halutusta joukosta kadonneet vuoropalkit, joten muutos ei vaadi uutta deployta. Tätä deployta ei ajeta tästä haarasta.

Edge, erillinen funktio (sulkusynkkaa ei muuteta):

```bash
supabase functions deploy booking-calendar-sync --project-ref sxbofnuisemspgquoxyv
```

Uusia salaisuuksia ei tarvita. Käytössä ovat `GOOGLE_SERVICE_ACCOUNT_JSON` ja `SYNC_CRON_SECRET` (holvissa `calendar_sync_cron_secret`). `verify_jwt = false`. Kutsu tulee otsikolla `x-sync-secret`.

Tekstit: `content/site-texts.pending-import-25.json` ja päiväpalkin muutokset `content/site-texts.pending-import-26.json` (fi + en). Sanakirja `booking/admin/calendar-export-texts.js` on varalla, kunnes tuonti on ajettu.

## Joonaksen päätökset

- Päiväpalkki tulee jokaiselle päivälle, jolla on vähintään yksi vahvistettu varaus. Yksityisvaraukset pysyvät omin tapahtumina ja lasketaan päiväpalkin aikaan sekä lukuihin.
- Millä Google-tilillä kalenterit ovat.
- Kalenteritunnukset asetuksiin, jako palvelutilille, ja milloin tila vaihdetaan pois-tilasta harjoitusajoon ja sitten käytössä-tilaan.
- Halutaanko nopea päivitys (noin minuutti) vai riittääkö viiden minuutin ajo.
