# Sulkukonfliktin kuittaus

Sipoonjoen Perinnesauna. Hallinnan Tarkista-näkymä (`booking/admin/views/review.js`) näyttää varaukset, jotka osuvat myöhemmin lisättyyn sulkuun. Joonaksen päätös 18.10.2026: savusaunan sulku voi olla tässä tapauksessa ei-todellinen, koska sulku on tehty käsin Johkussa perinnesaunotusillan takia tai koska varausta ei ollut vahvistettu. Kuittaus piilottaa parin Sulkukonfliktit-osiosta. Sulku, varaus ja saatavuus jäävät ennalleen.

Kuittaus ei käytä `admin_set_closure_override('ignore')` eikä `reservations.override_reason`. Ne muuttaisivat saatavuutta tai siirtäisivät varauksen Ylitykset-osioon.

## Taulu

`booking.closure_conflict_acks` (migraatio `20261018203000_booking_73_closure_conflict_ack.sql`):

| Sarake | Merkitys |
|---|---|
| `reservation_id`, `block_id` | Kuitattu pari. Yksi voimassa oleva rivi (`revoked_at is null`). |
| `closure_event_id` | Kalenteritapahtuma, jos sulku tuli synkasta. |
| `block_signature` | `t:<alku-epoch>\|<loppu-epoch>` ja kalenterisululla lisäksi `\|h:<content_hash>`. |
| `ack_reason` | Pakollinen perustelu, vähintään kolme merkkiä. |
| `acked_by_label`, `acked_by_uid`, `acked_at` | Kuka kuittasi. |
| `revoked_at` | Purku. |

RLS on päällä. Anonilla ja authenticated-roolilla ei ole suoraa luku- tai kirjoitusoikeutta. Kirjoitus tapahtuu vain RPC:llä.

Kuittaus on voimassa, kun `revoked_at` on tyhjä ja `block_signature` täsmää sulun nykyiseen allekirjoitukseen. Jos sulun alku, loppu tai `closure_events.content_hash` muuttuu, pari palaa avoimeksi. Vanhentunutta riviä ei näytetä Kuitatuissa.

`booking._reconcile_closure_blocks` ei koske kuittauksia. Sama sulku (sama `block_id` ja sama allekirjoitus) säilyttää kuittauksen, vaikka synkka ajetaan uudelleen.

## Oikeus ja funktiot

Oikeus on `blocks.manage` tai `bookings.override`. Työntekijällä on `blocks.manage`. Ylläpitäjällä ja pääkäyttäjällä on molemmat. Rooli, jolla on vain `bookings.override`, saa myös kuitata. Tavallinen käyttäjä ei saa.

Suora SQL-editori ilman JWT:tä (`current_user` on `postgres`, `supabase_admin` tai `service_role`) saa ajaa samat funktiot. Selaimen istunto ei käytä tätä oikotietä: `SET ROLE` vaihtaa `current_user`-arvon.

- `booking.admin_ack_block_conflict(p_reservation_id, p_block_id, p_note, p_label default null)` tarkistaa, että pari on oikeasti avoin konflikti. Sama allekirjoitus uudelleen on idempotentti (`already: true`) eikä kirjoita uutta audit-riviä.
- `booking.admin_unack_block_conflict(p_reservation_id, p_block_id)` purkaa kuittauksen. Toinen purku on idempotentti.
- `booking.admin_ack_block_conflicts_bulk(p_pairs jsonb, p_note, p_label)` kuittaa usean parin yhdessä kutsussa. Taulukko on muotoa `[{"reservation_id":1,"block_id":2}]`, enintään 200 paria. Yksi virhe peruu koko kutsun.

Audit-loki: `BLOCK_CONFLICT_ACK` ja `BLOCK_CONFLICT_UNACK`.

Tuotannon kerta-ajo (SQL-editori, ei tätä PR:ää):

```sql
select booking.admin_ack_block_conflicts_bulk(
  '[{"reservation_id": 1, "block_id": 2}]'::jsonb,
  'Sulku tehty käsin Johkussa',
  'Joonas (päätös 18.10.2026)');
```

Korvaa parit tuotannon todellisilla tunnuksilla. Jo kuitattu pari, jonka allekirjoitus täsmää, palauttaa `already: true`.

## Lista ja näkymä

`booking.admin_review_list()`:

- `block_conflicts` sisältää vain parit, joilla ei ole voimassa olevaa kuittausta. Kortin luku on tämän listan pituus.
- `acked_block_conflicts` näyttää kuitatut parit (perustelu, kuittaaja, sulun syy). Ne eivät kasvata näkymän «tarkistettavaa»-lukua.

Rivillä näkyy sulun syy: kalenterin nimi ja tapahtuman otsikko, tai käsisulun `reason`.

Näkymässä on nappi «Kuittaa (ei todellinen)», perustelukenttä (oletus «Sulku tehty käsin Johkussa») ja kaksivaiheinen vahvistus. Kuitatuissa on «Pura kuittaus». Tekstit ovat avaimia `ui.admin.review.*` (suomi ja englanti). Tuonti: `content/site-texts.pending-import-6.json` funktiolla `admin_texts_import` (enintään 500 riviä; olemassa olevia avaimia ei ylikirjoiteta; luokka `normal`). Sanakirja `booking/admin/review-texts.js` on varalla, kunnes tuonti on ajettu. `content/site-texts.fallback.json` ei päivity tästä.

## Saatavuus

Kuittaus ei aseta `override_reason`-arvoa, ei aseta `closure_events.override`-arvoa eikä passivoi sulkua. Uusi varaus, joka osuu sulkuun, saa edelleen virheen `space_closed`.

## Ajo ja peruutus

Migraatiota ei ajeta tämän muutoksen yhteydessä tuotantoon.

- Ajo: `booking/supabase/migrations/20261018203000_booking_73_closure_conflict_ack.sql`
- Peruutus: `booking/supabase/rollbacks/20261018203000_booking_73_ROLLBACK.sql` (poistaa kuittaukset ja palauttaa listan ilman kuittausosiota; sulut ja varaukset säilyvät)

Testit: `booking/supabase/tests/73_closure_conflict_ack.test.sql` (pgTAP) ja `booking/tests/sulkukonflikti-kuittaus.test.mjs`.
