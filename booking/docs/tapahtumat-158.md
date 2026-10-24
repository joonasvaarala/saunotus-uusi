# booking_158: tapahtumat ja koulutukset (tietokantaosa)

Migraatio `supabase/migrations/20261024300000_booking_158_events.sql`, rollback `supabase/rollbacks/20261024300000_booking_158_ROLLBACK.sql`,
SQL-testi `supabase/tests/t158_events.sql`, rakenteen testi `tests/tapahtumat-158.test.mjs`.

Joonaksen päätökset 24.10.2026 (sitovat): kerrat ovat erillisiä alkuaikoja (ei toistuvuutta), monipäiväinen yksi lippu vain koulutuksille,
tapahtuma voi varata tiloja ja saunottajia, hoitojen varauslogiikka ei muutu, etusivun kortti linkittää `/tuote/<slug>`,
myynti siirtyy omaan kauppaan 1.11.2026 → ominaisuus valmiina, **myynti pois päältä**.

## Malli

- **Tapahtumakerta** = `booking.schedule_rules`-rivi, jolla `kind = 'event'`, `valid_from = valid_to = päivä`, `mode = 'shared'`, tila `ei_resurssia`.
  Jokaisella kerralla on oma kapasiteettipooli (`resources.code = 'event_rule_<id>'`, kapasiteetti = kerran `max_persons`).
  Oletusotsikko `DD.MM.YYYY klo HH.MI`. Yli vuorokauden kesto vain koulutuksille (`multi_day_training_only`).
- **Resurssivaraus** = `booking.event_resource_blocks` (kerran sisällä). Ajoitus joko suhteellinen (`offset_min` + `minutes` kerran alusta)
  tai kellonaika (`starts_at`/`ends_at` HH:MM tai ISO; tallennetaan päivä + kello suhteessa kerran päivään).
  Tilan `exclusive`-varaus materialisoituu heti `booking.space_blocks`-riviksi (`event_block_id`), vaikka lippuja ei olisi myyty.
  Kerran passivointi tai poisto poistaa sulut, uudelleenaktivointi luo ne. Oma lippu ohittaa oman kerran sulut.
  Saunottajan (person) ja shared-tilan varaukset tallennetaan, mutta niitä ei materialisoida (päätös 3: hoitojen logiikka ennallaan).
- Tapahtumasulkuja ei voi muokata eikä poistaa suoraan (`event_managed`), eivätkä ne mene sulkukalenteriin.
- **Myyntikanavat** `product_config.channels` (`shop`, `widget`; null = koulutus → `{widget}`, muut → `{shop}`). Kauppa näyttää vain shop-tuotteet.
- **Myyntikytkin** `booking.settings 'events.sale_enabled'` (oletus `false`). Kun false: kerrat eivät näy julkisessa saatavuudessa,
  asiakkaan varaus hylätään (`sale_closed`), `public_catalog` piilottaa event/training-tuotteet, `public_events` palauttaa kerrat tilassa `closed`.
  Henkilökunta voi tehdä käsivarauksen. Avaus 1.11.2026: `update booking.settings set value = 'true' where key = 'events.sale_enabled';`
- **Lovi**: Loviin ohjautuvat (Rauni varattu) vain tuotteet 10 Saunahoito, 11 Saunotus, 12 Syväsaunotus, 23 Perinnesaunotus yhdelle ja
  24 Saunahoito opiskelijatyönä (Joonas 24.10.2026). Muiden tuotteiden aktiiviset Lovi-rivit (tuotannossa 14–22, 9 riviä) passivoidaan; muutetut rivit tallennetaan `booking.m158_lovi_rows` (rollback palauttaa).

## RPC:t

Kaikki `security definer`, `search_path ''`. Hallinnan RPC:t vaativat `catalog.edit` (paitsi `admin_event_list`: henkilökunta lukee).
Virheet: `{code, message}` (SQLSTATE BK001, DETAIL = code). Konfliktissa `code = 'conflict'` ja `details` (JSON-taulukko HINT-kentässä):
`[{resource_id, resource_name, starts_at, ends_at, reason}]`, reason = `reservation` | `block` | `event`.

| RPC | Parametrit | Palauttaa |
|---|---|---|
| `admin_event_list` | `p_category` (event/training/null), `p_include_past` | tuotteet + kerrat (ruleObj) |
| `admin_event_rule_upsert` | `p_id` (null = uusi), `p_product_id`, `p_patch {date,start_time,duration_minutes,max_persons,min_persons,deadline_minutes,label,label_en,active,price_variant_id}` | ruleObj |
| `admin_event_rule_delete` | `p_id` | `{ok}`; `has_reservations`, `has_waitlist` |
| `admin_event_blocks_set` | `p_rule_id`, `p_blocks [{resource_id,mode,offset_min,minutes \| starts_at,ends_at,note}]` (≤ 50) | `[block]`; `conflict` |
| `admin_event_set_channels` | `p_product_id`, `p_channels` (null = oletus) | `{ok}` |
| `admin_product_copy` | `p_product_id` | `{product_id, slug}` (Kopio:/Copy:, passiivinen, ei myynnissä) |
| `admin_event_copy` | `p_product_id`, `p_include_rules`, `p_shift_days` | `{product_id, slug, rules_copied}` (tulevat kerrat passiivisina) |
| `admin_event_rule_copy` | `p_rule_id`, `p_date` | ruleObj |
| `public_events` | `p_from`, `p_channel` (oletus shop) | `[{product_id, slug, name, name_en, description_short(_en), price, price_text, image_path, image_alt, category, sale_open, occurrences[{rule_id, starts_at, ends_at, label, label_en, time_text, time_text_en, status available\|full\|closed, remaining, price}]}]` |

ruleObj: `{id, product_id, kind, date, start_time, duration_minutes, starts_at, ends_at, max_persons, min_persons, deadline_minutes,
label, label_en, active, price_variant_id, space_id, pool_id, sold_persons, waitlist_count, blocks[]}`.

Muut virheet: `not_found`, `not_event`, `invalid_param`, `unknown_field`, `bad_time`, `bad_range`, `invalid_resource`,
`max_below_sold`, `multi_day_training_only`, `has_reservations` (ajan muutos tai passivointi, kun kerralla on varauksia).

## Ajojärjestys

1. Tarkista tuotannon md5:t (alla) – jos jokin poikkeaa, älä aja.
2. Aja migraatio (Bottiavustus vaihtaa version tuotannon versioksi).
3. Tarkista: `select key, value from booking.settings where key = 'events.sale_enabled'` → `false`;
   `select id, product_id, active from booking.product_space_rules where space_id = (select id from booking.resources where code = 'lovi')`.
4. Käyttöliittymä (erillinen PR) käyttää yllä olevia RPC:itä.

## Rollback

`supabase/rollbacks/20261024300000_booking_158_ROLLBACK.sql` palauttaa funktiot täsmälleen ja tarkistaa md5:t (virhe → koko transaktio perutaan):

```
booking._sessions                  872ef0fc6a9d38726ea2438f11ba3f01
booking._check_claim               bf875a55f4d73bfdcbaf107c29f09f45
booking._resolve_session           132d5ce9356106af79cfa84658e76fd1
booking._block_conflict_pairs      cd2a64faf36994de5c99979816876f99
booking.space_blocks_managed_guard 6b9f525403f3a69285b65921c1a79196
booking.closure_blocks_outbox_trg  17ce83a9fbf50bebaffe2568438757ec
booking.closure_outbox_backfill    d6ddcaf1e152d74b8093d158e3394209
booking.public_catalog             b869be5d3444cc3d6923153efc336120
booking.public_availability        503709f45fe0e98b9d4701c95297312f
booking.public_availability_all    eeb7cf54b957b2d29b9ea2fcc4f2a409
```

Rollback poistaa tapahtumien resurssivaraukset ja niiden sulut pysyvästi; tapahtumakerrat jäävät tavallisiksi yhden päivän vuoroiksi.

## Testit

`psql -X -d <testikanta> -f supabase/tests/t158_events.sql` (hakemistosta `supabase/tests`, fixtures ladattu) → `TESTRESULT pass=87 fail=0`.
Testi ajaa migraation uudelleen, rollbackin kahdesti (md5-tarkistus) ja migraation uudelleen.
