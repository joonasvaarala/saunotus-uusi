# booking_263 – myöhäinen maksu perutulle tilaukselle (late_paid_cancelled_order)

- Migraatio: `booking/supabase/migrations/20261107075613_booking_263_late_paid_cancelled_order.sql` (tiedostonimen aikaleima = PROD-ledgerin versio, käytäntö kuten booking_19/27).
- Rollback: `booking/supabase/rollbacks/20261107075613_booking_263_ROLLBACK.sql` (lähtöhashvartija; palauttaa booking_53-määrittelyn md5 `8ceb0a7dea60d37e3ea6a17cec0e4c25`).
- Ajettu (Bottiavustus 7.11.2026; varmennettu read-only `supabase_migrations.schema_migrations` + `pg_get_functiondef`):
  - DEV (Tapio-dev): versio `20261107075540`
  - PROD (Tapio-havuhattu): versio `20261107075613`
  - Molemmissa ledgerin statements-md5 = repon tiedoston md5 `198605640385ee5a55c5f913dcff13f1`; funktion md5 `b35618b8cd17fa9e7c5902719d0804a2`.
- Tiedoston sha256 `1aae778ebd4aa7b129cbe28988695fd6065a5229e72a5586a1dc05babd85e696`, rollback sha256 `ea29d445238a78910ab3246cfba625f8dbc86bbc2b319c65168fe6851857a72b`.
- Huom: migraation sisäinen kommentti viittaa vanhaan rollback-polkuun (`rollbacks/late_paid_cancelled_order_ROLLBACK.sql`); jätetty, jotta SQL-tavut vastaavat ajettua.

## Mitä korjaus tekee (kapea)
`booking.payment_mark_paid`: maksurivin lukko, vartijat ja maksun UPDATE + triggerit (kirjanpitokuitti) kuten ennen. Sen jälkeen tilaus lukitaan
`FOR NO KEY UPDATE` (sama kohta ja lukkotaso kuin baselinen `_refresh_order_payment` → UPDATE orders) ja tila luetaan tuoreena. Jos tilaus on
`cancelled`: vain payment_status lasketaan, ei `_refresh_order_payment`ia, ei varaus-/rivipito-/status-muutoksia, ei tilausvahvistusta;
samassa transaktiossa jonotettu kuittiviesti → `skipped`; internal_note + audit `LATE_PAID_CANCELLED_ORDER`; paluu `needs_manual_review`.
Muut tilat ennallaan. Ei automaattista palautusta eikä asiakasviestiä.

## Jäljellä olevat baseline-riskit (EI korjattu tässä)
- Globaalit baseline-deadlockit maksu- ja peruutus-/siivouspolkujen välillä (paikallinen race: public, expire_holds, cancel_expired, release
  saavat 40P01 samoin baselinessa ja korjauksessa).
- Maksun kirjaaminen 40P01:n tai muun RPC-virheen jälkeen riippuu palveluntarjoajan uusintayrityksestä, jota ei ole taattu; ei retry/reconcile-ajoa.
  Korjaus ei takaa, että jokainen veloitus kirjautuu.
- MobilePay: capture voi onnistua, vaikka DB-kirjaus epäonnistuu (capture-retry ei kuulu tähän).
- Lisäyksen maksu, jonka lisäys ehdittiin vapauttaa: `amount_mismatch` → ei kirjata, tarkistusmerkintä (kuten baseline).
- Jos maksu ehti vahvistaa tilauksen ja lähettää vahvistuksen ennen myöhempää peruutusta, viestiä ei peruta.

## Testit (LOCAL ONLY)
`booking/supabase/tests/checkout/t_late_paid_cancelled_order.sql`, `booking/supabase/tests/late_paid_race.py` + `late_paid_race_compare.py`
(baseline vs fix), `t178_paylink_retry.sql` (hash-pin).
