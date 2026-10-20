# Varauskalenteri (vienti Googleen)

Yksisuuntainen vienti: vahvistetut varaukset näkyvät erillisessä Google-kalenterissa. Kalenterissa tehty muutos ei muuta varausta. Käytössä-tilassa Googleen kirjoitetaan vain, kun tapahtuman sisältö on muuttunut. Noin tunnin välein tehdään täysi uudelleenkirjoitus, joten kalenterista käsin poistettu tapahtuma palautuu seuraavassa täydessä ajossa.

Sulkukalenterit (`1 savusauna kiinni`, `1 perinnesaunotus kiinni`, `1 hoidot kiinni`, `1 Rauni kiinni`) pysyvät kaksisuuntaisina. Niiden tunnuksia ei käytetä tässä viennissä.

## Mitä kalenteriin tulee

- **Yksi palkki per päivä** (Europe/Helsinki). Palkki alkaa päivän ensimmäisen vahvistetun varauksen alusta ja päättyy viimeisen varauksen loppuun. Mukana ovat kaikki resurssit: yksityisvaraukset ja yleiset vuorot, joissa on vähintään yksi vahvistettu varaus. Otsikko esimerkiksi `Varaukset 14–21 · 6 varausta`.
- Aikaisempi uusi varaus leventää alkua. Peruutus lyhentää palkkia. Jos päivän kaikki varaukset peruuntuvat, palkki poistuu.
- Kuvauksessa on lista: aika, resurssi, tyyppi, henkilömäärä ja yksityisvarauksen tilausnumero. Yksityisvarauksessa näkyy nimi tai yrityksen nimi. Yleisestä vuorosta näkyy vain henkilö- ja varausmäärä, ei nimiä eikä tilausnumeroita.
- Mukaan otetaan varaukset, joiden tila on confirmed, completed tai no_show, tilaus on confirmed tai completed, eikä maksu ole kesken (`pending`) tai epäonnistunut (`failed`). Maksamatta oleva vahvistettu tilaus (kuten Johku-tuonti) näkyy. Keskeneräinen kassa ei näy.
- Asiakkaan puhelinta ja sähköpostia ei kirjoiteta kalenteriin. Jos ne ovat kiinni nimessä, ne poistetaan.

Kohde on **yksi yhteinen Varaukset-kalenteri** (`shared_calendar_id`). Päiväpalkki ei jakaudu resurssikohtaisiin kalentereihin. Tyhjä tunnus ei vie mitään. Tunnus ja tili vaihdetaan asetuksesta, ei koodista.

Vanhat yksittäistapahtumat (`r:` ja `s:`), jos niitä on ehditty kirjoittaa, eivät ole enää haluttuja. Seuraava käytössä-ajo poistaa ne. Toinen ajo ei löydä niitä uudelleen.

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

Migraatio `20261020053000_booking_116_calendar_day` vaihtaa viennin päiväpalkkiin. Rollback: `booking/supabase/rollbacks/20261020053000_booking_116_ROLLBACK.sql`. Nykyinen Edge poistaa halutusta joukosta kadonneet tapahtumat, joten päiväpalkki ja vanhojen rivien siivous eivät vaadi uutta deployta. Tätä deployta ei ajeta tästä haarasta.

Edge, erillinen funktio (sulkusynkkaa ei muuteta):

```bash
supabase functions deploy booking-calendar-sync --project-ref sxbofnuisemspgquoxyv
```

Uusia salaisuuksia ei tarvita. Käytössä ovat `GOOGLE_SERVICE_ACCOUNT_JSON` ja `SYNC_CRON_SECRET` (holvissa `calendar_sync_cron_secret`). `verify_jwt = false`. Kutsu tulee otsikolla `x-sync-secret`.

Tekstit: `content/site-texts.pending-import-25.json` ja päiväpalkin muutokset `content/site-texts.pending-import-26.json` (fi + en). Sanakirja `booking/admin/calendar-export-texts.js` on varalla, kunnes tuonti on ajettu.

## Joonaksen päätökset

- Kalenterissa on yksi palkki per päivä, ei erillistä tapahtumaa per varaus. Kohde on yhteinen Varaukset-kalenteri.
- Millä Google-tilillä kalenterit ovat.
- Kalenteritunnukset asetuksiin, jako palvelutilille, ja milloin tila vaihdetaan pois-tilasta harjoitusajoon ja sitten käytössä-tilaan.
- Halutaanko nopea päivitys (noin minuutti) vai riittääkö viiden minuutin ajo.
