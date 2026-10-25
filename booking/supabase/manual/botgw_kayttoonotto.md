# bot-gateway (Oton botin yhdyskäytävä): käyttöönotto

Lähde: `/workspace/otto_bot/koodari_otto.md` (Joonaksen hyväksyntä 25.10.2026 klo 17.06 ja 17.08, kb.bot_permissions id 3–6).
Tämä PR **ei** deployaa, **ei** myönnä avainta eikä luo cron-jobia. Kaikki alla olevat vaiheet tehdään vasta Joonaksen luvalla.

## Tila tämän PR:n jälkeen
- Tietokanta (jo tuotannossa): migraatiot `20261025145539_botgw_otto_disabled`, `20261025151402_botgw_otto_scope_v2`,
  `20261025160316_botgw_otto_backlog_claim` ja `20261025160701_botgw_otto_calendar_guard`.
  Oton rivi `otto-grok-bot`: `active=false`, `key_hash` null. `wake_targets('tyovuoro-tapio').active=false`.
- Edge-funktio `booking/supabase/functions/bot-gateway` (repossa, ei deployattu). `verify_jwt = false` (config.toml).

## 1. Deploy (kytkin ensin päälle = funktio pois päältä)
```sh
supabase secrets set BOTGW_DISABLED=1 --project-ref sxbofnuisemspgquoxyv
supabase functions deploy bot-gateway --no-verify-jwt --project-ref sxbofnuisemspgquoxyv
```
Tarkistus (odotus 503 `{"ok":false,"error":"disabled"}`, tietokantaa ei kutsuta):
```sh
curl -s -X POST https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/bot-gateway -d '{"action":"me"}'
```
SUPABASE_URL ja SUPABASE_SERVICE_ROLE_KEY tulevat Supabasesta automaattisesti; jos ne puuttuvat, funktio on pois päältä (503).

## 2. Avaimen myöntö (koodari_otto.md §5) – MYÖHEMMIN
Ajetaan vasta käyttöönotossa Joonaksen hyväksynnällä Bottiavustuksen boxilla. 32 tavun satunnaisavain, sha256 hex tietokantaan:
`update botgw.bot_clients set key_hash=$1, issued_at=now(), active=true where name='otto-grok-bot'`.
Avain Otolle suojatulla lomakkeella / holvijaolla, ei chatissa, ei boxille. Avaimen pituus 20–256 näkyvää ASCII-merkkiä (hex tai base64url).

## 3. Kytkimen pois otto
```sh
supabase secrets unset BOTGW_DISABLED --project-ref sxbofnuisemspgquoxyv   # tai BOTGW_DISABLED=0
```

## 4. Työvuoro-Tapion herätyksen uudelleenyritys (koodari_otto.md §4) – MYÖHEMMIN
Cron-jobia ei ole. Kun wake_targets on aktivoitu (URL + avain vaultissa `vault.create_secret`, ei chatissa):
```sql
select cron.schedule('botgw-wake-retry-5m', '*/5 * * * *', $$select botgw.wake_retry()$$);
```

## Hätäkatkaisu ja peruutus
- Edge: `supabase secrets set BOTGW_DISABLED=1` (503 heti, ei tietokantaa).
- Tietokanta: `booking/supabase/manual/botgw_disable.sql` (kaikki avaimet ja herätys pois).
- Peruutus käänteisessä järjestyksessä: `rollbacks/20261025160701_botgw_otto_calendar_guard_ROLLBACK.sql`
  → `rollbacks/20261025160316_botgw_otto_backlog_claim_ROLLBACK.sql` → `rollbacks/20261025151402_botgw_otto_scope_v2_ROLLBACK.sql`.
  Edge v2 tuntee uudet toiminnot; jos tietokanta perutaan, ne palauttavat 400 `unknown_action` (tietokannasta).
- Koko botgw pois: `booking/supabase/rollbacks/20261025145539_botgw_otto_disabled_ROLLBACK.sql` (poista ensin funktio tai kytkin päälle).

## Rajapinta
POST, otsikko `x-bot-key`, runko `{"action": "...", "args": {...}}` (≤ 16 kB, action ≤ 50 merkkiä `[a-z_]`).
Vastaus `{ok:true, data, request_id?}` / uusinta `{ok:true, duplicate:true, request_id}` / `{ok:false, error}`.

| Tilanne | HTTP |
|---|---|
| BOTGW_DISABLED / asetukset puuttuvat | 503 `disabled` |
| muu kuin POST | 405 (Allow: POST; ei CORS-otsikoita, selainkäyttöä ei tueta) |
| runko > 16 kB | 413 |
| avain puuttuu / väärä | 401 |
| 42501 forbidden / not_editable / field_not_editable / calendar_managed | 403 (viesti) |
| 22023 | 400 (viesti sellaisenaan) |
| 22P02 / 23505 | 400 `bad_input` / `already_exists` |
| P0002 | 404 |
| BG429 tai edge-raja (60/min per avain, 30/min per IP, muistissa) | 429, Retry-After: 60 |
| 55000 (DB-first pois) | 503 `shift_sync_disabled` |
| muut | 500 `internal_error` |

Edge tarkistaa lisäksi toimintokohtaisesti argumenttien nimet ja muodot (core.ts `ACTIONS`); sisällölliset säännöt
(aikarajat, roolit, kalenterinimen uniikkius, puhelinnumero, scopet, rajat, idempotenssi) tekee `botgw.call`.
Virheen jälkeen `botgw_log_failure(p_key_hash, p_action, p_error)` lyhyellä koodilla (esim. `22023`, `42501:forbidden`,
`edge:validation`); ei viestisisältöä. Edge-tason 401 (ei avainta), 405, 413 (otsikko), 429 ja 503 eivät kutsu tietokantaa.
Lokiin vain `{fn, action, status, result, request_id}`.

## Edge v2 (koodari_otto.md §1b)
Uudet toiminnot ACTIONS-listassa: `backlog_claim {item_id, note ≤1000}`, `backlog_task_add {item_id, title ≤300, due_date}`,
`own_absence_sync {from, to, events[≤300]}`, `own_shift_release {shift_id, absence_id, reason ≤300, confirmed}`.
`not_claimable` (42501) → 403. `confirm_required: …` (22023) → 400 viesti sellaisenaan.
Huom: rungon 16 kB raja rajaa own_absence_syncin käytännössä noin 240 tapahtumaan (ISO-ajat ilman sekunteja, lyhyt ref);
300 tapahtumaa ei mahdu yhteen kutsuun → 413. Otto jakaa synkan useampaan väliin (from/to), tai raja nostetaan erikseen.
Deploy kuten yllä (BOTGW_DISABLED=1 pysyy), `supabase functions deploy bot-gateway --no-verify-jwt`.
