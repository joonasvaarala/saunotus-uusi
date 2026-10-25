# Johku-synkka (Varmistaja)

Tuntiluku Johkusta uuteen hallintaan (`booking`), kunnes Johku sulkeutuu kirjanpidolta **1.11.2026 00:00** (Europe/Helsinki). Palvelimella ei ole Supabasen `service_role`-avainta. Cron kutsuu edge-funktiota `johku-sync`, joka hyväksyy vain Johku-rivien kirjoituksen.

Säännöt ovat samat kuin `SYNC_SAANNOT.md`: piilotettuja varauksia ei herätetä, lisäpalvelu (kb 44/45) ja paketin 0 € oheisvuoro eivät saa omaa varausta, `addon_merge`-tilauksen summaa ei palauteta, kadonnut rivi peruutetaan syyllä `johku_removed`. Maksuja, kuitteja, sähköpostia ja Procountor-rivejä ei synny.

## Migraatio

`booking/supabase/migrations/20261022091609_booking_126_johku_sync.sql`

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
./run_sync.sh --seed-baseline /polku/vientiin
./run_sync.sh --save-baseline    # tallentaa tuoreen viennin pohjaksi, ei kirjoita kantaan
```

Tilaukset haetaan `orders.json?items=true&limit=100000`. Ilman `items=true` Johku ei palauta `ownItem`-rivejä, ja synkka ylikirjoittaisi tilaukset ilman rivejä. Jos uusi vienti on rivitön vaikka edellinen ei ollut, tai isosta viennistä alle 5 %:lla tilauksista on rivejä, ajo keskeytyy (`export_missing_items`) eikä pohjaa päivitetä. Varauslista ei tarvitse samaa lippua: rivit tulevat tilauksesta. Lahjakortin saldo haetaan edelleen `valuecards/<koodi>.json?details=true`.

Lukko: `~/.johku-sync.lock` (`flock`). Vertailupohja: `~/.johku-sync/state/baseline.json` (henkilötietoja, `chmod 600`, ei gitiin). Epäonnistuminen tulostaa koodin ja palauttaa arvon 1. Jos `~/valvonta/lib.sh` määrittelee funktion `alert`, sitä kutsutaan.

Ensimmäinen käyttöönotto, kun kanta vastaa 17.10.2026 vientiä (11952 Johku-tilausta, viimeinen 17.10. 00:38): älä aja `--save-baseline` tuoreella haulla, se ohittaisi 17.–22.10. muutokset. Syötä pohja vanhasta vientihakemistosta, jossa on `customers.json`, `orders.json` (ownItem mukana), `reservations.json`, `bills.json` ja `valuecards.json`:

```bash
./run_sync.sh --seed-baseline /polku/johku-vienti-2026-10-17
./run_sync.sh --dry-run
./run_sync.sh
```

`--seed-baseline` ei soita Johkuun eikä edge-funktioon. Sen jälkeen normaali ajo lähettää vain eron. `--full` lähettää kaikki nykyiset rivit ja peruuttaa edelleen ne, jotka katosivat pohjaan nähden. Yli 5 % pudotus listassa (kun pohjassa on vähintään 50 riviä) keskeyttää ajon, jotta katkennut vastaus ei peruuta varauksia.

Asiakkaan sähköpostia, puhelinta ja muita yhteystietoja ei ylikirjoiteta, jos hallinta on muuttanut ne tuonnin jälkeen: kenttä päivittyy vain jos se on tyhjä tai se on yhä sama kuin edellisessä viennissä. `addon_merge`-tilauksen summaa ei muuteta myöskään silloin, kun tilaus peruutetaan syyllä `johku_removed`. Rivikohtainen audit jää pois (henkilötiedot), mutta jokainen kirjoitus jättää `audit_log`-rivin, jonka `row_pk` on ajon id taulussa `johku_sync_runs`.

Lahjakorttilista ei sisällä saldoa. Yöajo hakee kortin, jos listarivi muuttui tai kortti on yhä aktiivinen. `--cards full` hakee jokaisen kortin. Aktiivisia kortteja on noin tuhat, ja kutsujen väli on vähintään sekunti, joten yöajo kestää noin vartin. Johkuun lähtee vain GET.

## Crontab (Europe/Helsinki)

Varmistajan käyttäjä on `joonas`, repo `~/saunotus-uusi`. Cron ajaa komennon `/bin/sh`:lla, joten `$HOME` aukeaa.

```
CRON_TZ=Europe/Helsinki
0 7-23 * * *  "$HOME/saunotus-uusi/booking/tools/johku-sync/run_sync.sh" >> "$HOME/.johku-sync/cron.log" 2>&1
30 2 * * *    "$HOME/saunotus-uusi/booking/tools/johku-sync/run_sync.sh" --cards >> "$HOME/.johku-sync/cron.log" 2>&1
35 19 31 10 * "$HOME/saunotus-uusi/booking/tools/johku-sync/run_sync.sh" >> "$HOME/.johku-sync/cron.log" 2>&1
30 23 31 10 * "$HOME/saunotus-uusi/booking/tools/johku-sync/run_sync.sh" --full --cards full >> "$HOME/.johku-sync/cron.log" 2>&1
```

31.10. rivit laukeavat joka vuosi; poista crontab, kun Johku on kiinni. Lokista näkee ajon yhteenvedon. Kannassa:

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
