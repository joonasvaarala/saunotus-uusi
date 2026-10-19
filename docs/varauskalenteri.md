# Varauskalenteri (vienti Googleen)

Yksisuuntainen vienti: vahvistetut varaukset näkyvät erillisessä Google-kalenterissa. Kalenterissa tehty muutos ei muuta varausta. Seuraava ajo kirjoittaa tapahtuman uudelleen varausjärjestelmän tiedoista.

Sulkukalenterit (`1 savusauna kiinni`, `1 perinnesaunotus kiinni`, `1 hoidot kiinni`, `1 Rauni kiinni`) pysyvät kaksisuuntaisina. Niiden tunnuksia ei käytetä tässä viennissä.

## Mitä kalenteriin tulee

- **Yksityinen varaus** (varauksen tila `exclusive`: koko tila, yritysvaraus, saunotus, hoito): yksi tapahtuma. Otsikko esimerkiksi `Savusauna – yksityisvaraus, 8 hlö` tai `Savusauna – Saunahoito, 2 hlö`. Kuvauksessa on tilausnumero ja linkki hallintaan. Nimi tai yrityksen nimi saa näkyä lyhyesti.
- **Yleinen vuoro** (tila `shared`, sama resurssi ja sama alku sekä loppu): yksi palkki, vain jos vuorossa on vähintään yksi vahvistettu varaus. Otsikko esimerkiksi `Savusauna · Yleinen vuoro 17–20 · 5 hlö (3 varausta)`. Palkki päivittyy ja poistuu, kun viimeinen varaus peruuntuu.
- Mukaan otetaan varaukset, joiden tila on confirmed, completed tai no_show, tilaus on confirmed tai completed, eikä maksu ole kesken (`pending`) tai epäonnistunut (`failed`). Maksamatta oleva vahvistettu tilaus (kuten Johku-tuonti) näkyy. Keskeneräinen kassa ei näy.
- Asiakkaan puhelinta ja sähköpostia ei kirjoiteta kalenteriin. Jos ne ovat kiinni nimessä, ne poistetaan.

Kohde on **yksi yhteinen Varaukset-kalenteri**. Resurssin nimi on aina otsikossa, jotta päivän ensimmäiset varaukset näkyvät samasta näkymästä. Resurssikohtainen tunnus `resource_calendars`-kohdassa ohittaa yhteisen kalenterin. Tyhjä tunnus ei vie kyseistä resurssia. Tunnukset ja tili vaihdetaan asetuksesta, ei koodista.

Ikkuna on oletuksena tänään − 7 päivää … + 180 päivää (Europe/Helsinki). Ajo on viiden minuutin välein. Nopea päivitys on valinnainen ja oletuksena pois.

## Oletus on pois

`integration_config.key = booking_calendar`, `mode = off`. Ajastus saa olla olemassa: `booking.booking_calendar_dispatch` palaa heti eikä kutsu Edgeä eikä Googlea. Harjoitusajo (`dry_run`) laskee tapahtumat eikä kirjoita. `live` kirjoittaa.

## Kytkentä

1. Luo kalenteri halutulle Google-tilille (yksi nimeltä Varaukset, tai yksi per resurssi). Tiliä ei ole lukittu koodiin: se voi olla nykyinen tai myöhemmin `savusauna@saunotus.fi`.
2. Jaa kalenteri olemassa olevan palvelutilin `client_email`-osoitteelle (salaisuus `GOOGLE_SERVICE_ACCOUNT_JSON`, sama kuin sulkusynkassa) oikeudella **Make changes to events**.
3. Kopioi kalenterin tunnus (muotoa `…@group.calendar.google.com` tai vastaava id).
4. Hallinta → Asetukset → Varaukset: liitä tunnus, tallenna. Älä liitä sulkukalenterin tunnusta.
5. Jätä tila pois tai vaihda harjoitusajoon ja katso esikatselun luvut. Esikatselu ei lähetä mitään.
6. Kun tunnus ja jako ovat kunnossa, vaihda tilaksi käytössä.

Hallinnan linkki tapahtuman kuvauksessa on `site_base_url` + `/hallinta`, ellei asetukseen ole annettu muuta https-osoitetta.

## Deploy

Migraatio `20261019161000_booking_114_calendar_export` luo taulut, funktiot ja ajastuksen `booking_calendar_export` (`*/5 * * * *`). Rollback: `booking/supabase/rollbacks/20261019161000_booking_114_ROLLBACK.sql`.

Edge, erillinen funktio (sulkusynkkaa ei muuteta):

```bash
supabase functions deploy booking-calendar-sync --project-ref sxbofnuisemspgquoxyv
```

Uusia salaisuuksia ei tarvita. Käytössä ovat `GOOGLE_SERVICE_ACCOUNT_JSON` ja `SYNC_CRON_SECRET` (holvissa `calendar_sync_cron_secret`). `verify_jwt = false`. Kutsu tulee otsikolla `x-sync-secret`.

Tekstit: `content/site-texts.pending-import-25.json` (fi + en). Sanakirja `booking/admin/calendar-export-texts.js` on varalla, kunnes tuonti on ajettu.

## Joonaksen päätökset

- Yksi yhteinen Varaukset-kalenteri vai erillinen kalenteri per resurssi (Savusauna, Hoitosauna Rauni, Lovi).
- Millä Google-tilillä kalenterit ovat.
- Kalenteritunnukset asetuksiin, jako palvelutilille, ja milloin tila vaihdetaan pois-tilasta harjoitusajoon ja sitten käytössä-tilaan.
- Halutaanko nopea päivitys (noin minuutti) vai riittääkö viiden minuutin ajo.
