# Johku-synkka (Varmistaja)

Tuntiluku Johkusta uuteen hallintaan (`booking`), kunnes Johku sulkeutuu kirjanpidolta **1.11.2026 00:00** (Europe/Helsinki). Palvelimella ei ole Supabasen `service_role`-avainta. Cron kutsuu edge-funktiota `johku-sync`, joka hyväksyy vain Johku-rivien kirjoituksen.

Säännöt ovat samat kuin `SYNC_SAANNOT.md`: piilotettuja varauksia ei herätetä, lisäpalvelu (kb 44/45) ja paketin 0 € oheisvuoro eivät saa omaa varausta, `addon_merge`-tilauksen summaa ei palauteta, kadonnut rivi peruutetaan syyllä `johku_removed`. Maksuja, kuitteja, sähköpostia ja Procountor-rivejä ei synny.

## Migraatio

`booking/supabase/migrations/20261022090000_booking_126_johku_sync.sql`

Funktiot (vain `service_role`):

- `booking.svc_johku_sync_state()` — tunnisteet ja tilat, ei nimiä eikä korttikoodeja
- `booking.svc_johku_sync_apply(jsonb)` — upsert ja peruutus
- `booking.svc_johku_sync_log(jsonb)` — ajon loki tauluun `booking.johku_sync_runs`

Lahjakortin saldo käyttää jo olevaa funktiota `booking.svc_gift_cards_johku_upsert`. Tätä migraatiota ei ajeta tuotantoon tästä haarasta.

## Salaisuudet

Edge-ympäristöön (Supabase), ennen kuin funktio deployataan:

| Nimi | Missä |
|---|---|
| `JOHKU_SYNC_SECRET` | Edge-funktion salaisuus. Pitkä satunnainen merkkijono. Ei service role -avain. |

`booking/supabase/config.toml`: `[functions.johku-sync]` ja `verify_jwt = false`. Tunnistus on otsake `x-johku-sync-secret`.

Palvelimella, `chmod 600`, ei repoon:

`~/.secrets/johku.env`

```
JOHKU_SHOP=sipoonjoenperinnesauna
JOHKU_API_KEY=...
```

`~/.secrets/johku_sync.env`

```
JOHKU_SYNC_URL=https://<projekti>.supabase.co/functions/v1/johku-sync
JOHKU_SYNC_SECRET=<sama arvo kuin JOHKU_SYNC_SECRET>
```

Vuotanut synkkasalaisuus voi vain lähettää Johku-muotoista dataa tähän funktioon. Se ei lue muita tauluja eikä kirjoita maksuja.

## Komento

```bash
cd booking/tools/johku-sync
chmod +x run_sync.sh
./run_sync.sh --dry-run          # hakee Johkun, ei kirjoita
./run_sync.sh                    # inkrementaalinen kirjoitus
./run_sync.sh --cards            # lisäksi aktiiviset lahjakortit
./run_sync.sh --full --cards full
./run_sync.sh --save-baseline    # tallentaa viennin, ei kirjoita kantaan
```

Lukko: `~/.johku-sync.lock` (`flock`). Vertailupohja: `~/.johku-sync/state/baseline.json` (henkilötietoja, `chmod 600`, ei gitiin). Epäonnistuminen tulostaa koodin ja palauttaa arvon 1. Jos `~/valvonta/lib.sh` määrittelee funktion `alert`, sitä kutsutaan.

Ensimmäinen käyttöönotto, kun kanta on jo tuotu: aja `--dry-run`, tarkista yhteenveto, sitten `--save-baseline`. Sen jälkeen cron lähettää vain muutokset. `--full` lähettää kaikki nykyiset rivit ja peruuttaa edelleen ne, jotka katosivat pohjaan nähden. Yli 5 % pudotus listassa (kun pohjassa on vähintään 50 riviä) keskeyttää ajon, jotta katkennut vastaus ei peruuta varauksia.

Lahjakorttilista ei sisällä saldoa. Yöajo hakee kortin, jos listarivi muuttui tai kortti on yhä aktiivinen. `--cards full` hakee jokaisen kortin. Aktiivisia kortteja on noin tuhat, ja kutsujen väli on vähintään sekunti, joten yöajo kestää noin vartin. Johkuun lähtee vain GET.

## Crontab (Europe/Helsinki)

```
CRON_TZ=Europe/Helsinki
0 7-23 * * *  /home/box/saunotus-uusi/booking/tools/johku-sync/run_sync.sh >> /home/box/.johku-sync/cron.log 2>&1
30 2 * * *    /home/box/saunotus-uusi/booking/tools/johku-sync/run_sync.sh --cards >> /home/box/.johku-sync/cron.log 2>&1
35 19 31 10 * /home/box/saunotus-uusi/booking/tools/johku-sync/run_sync.sh >> /home/box/.johku-sync/cron.log 2>&1
30 23 31 10 * /home/box/saunotus-uusi/booking/tools/johku-sync/run_sync.sh --full --cards full >> /home/box/.johku-sync/cron.log 2>&1
```

Polku on esimerkki. 31.10. rivit laukeavat joka vuosi; poista crontab, kun Johku on kiinni. Lokista näkee ajon yhteenvedon. Kannassa:

```sql
select id, started_at, finished_at, status, mode, counts, error_summary
  from booking.johku_sync_runs
 order by id desc
 limit 20;
```

## Kuiva ajo ilman Johkua

```bash
python3 booking/tools/johku-sync/sync.py --dry-run --fixture case
```

Fixture on keksittyä dataa (`fixtures/case_data.py`). Se kattaa piilotetun varauksen, siirretyn vihdan, paketin oheisvuoron, erillisen rituaalin ja vuoron, viikonlopun 30 minuutin vuoron pidennyksen, tilausnumeron törmäyksen ja `johku_removed`-peruutuksen.
