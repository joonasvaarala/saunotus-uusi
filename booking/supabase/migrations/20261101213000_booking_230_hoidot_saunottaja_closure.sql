-- booking_230: Hoidot kiinni sulkee kaiken, mikä tarvitsee saunottajaa (Joonas 1.11.2026).
--
-- Sääntö on jo moottorissa, datasta eikä tuotetunnuksista:
--   product_config.required_skill → booking._skill_block_resource
--     vuoropohjainen taito (yleinen, saunotus, morsiussauna) → resurssi saunottaja
--     henkilömääräpohjainen taito (laura) → oma resurssi, hoidot kiinni ei koske sitä
--   sulkukalenteri hoidot kirjoittaa space_blocks-rivin saunottajalle
--   _plan_legs / _check_claim: päällekkäinen sulku roolilla therapist → therapist_closed
--   _treatment_plan_status: therapist_closed (ja muu kuin no_therapist) → null, aikaa ei tarjota
--   no_therapist (kukaan ei ole vuorossa) → therapist_missing, aika myydään (päätös 17.10., booking_22)
--
-- Koskee verkkokaupan saatavuutta (public_treatment_availability → _treatment_availability_core),
-- kassan ja pidon tarkistusta (public_create_treatment_booking → _plan_legs) sekä hallinnan
-- saatavuutta (admin_treatment_availability, sama ydin). Henkilökunta voi yhä ylittää sulun
-- (p_override / allow_off_schedule), kuten ennenkin. Olemassa olevaa varausta sulku ei peru.
--
-- Paketti, jonka saunottajaikkuna on vain rituaalijalka (therapist_offset_min + therapist_minutes,
-- paketilla sama kuin Raunin rituaalijalka): sulku, joka osuu vain savusaunaosaan, ei piilota
-- pakettia. Yleinen vuoro ja yksityinen savusauna (required_skill null) pysyvät myynnissä.
-- Rauni kiinni sulkee vain Raunin: hoito, jolla on Lovi-vaihtoehto (auto_if_blocked), siirtyy
-- Loviin; pelkkä Rauni-tuote (rituaali, paketin rituaalijalka) ei.
--
-- Tämä migraatio ei vaihda funktioiden runkoja. Se kirjaa säännön niiden kommentteihin, jotta
-- seuraava muutos ei yhdistä therapist_closed-virhettä therapist_missing-myyntiin.
-- Ei teksti-importtia. Ei edge-funktion julkaisua.
-- Rollback: rollbacks/20261101213000_booking_230_ROLLBACK.sql
-- Testi: tests/t230_hoidot_saunottaja_closure.sql

set local lock_timeout = '5s';

comment on function booking._treatment_plan_status(bigint, timestamp with time zone, timestamp with time zone, integer) is
  'ok | therapist_missing | null. Hoidot kiinni: saunottajataidon sulkuresurssin space_blocks osuu saunottajaikkunaan (required_skill, therapist_offset_min, therapist_minutes) → null, aikaa ei myydä. Ei vapaata saunottajaa vuorolla (no_therapist) → therapist_missing ja aika myydään (booking_22). Rauni kiinni ei ole saunottajasulku. Joonas 1.11.2026.';

comment on function booking._check_claim(bigint, bigint, bigint, text, text, timestamp with time zone, timestamp with time zone, integer, bigint[], text, text, boolean, boolean, text) is
  'Varausjalan tarkistus. Rooli therapist + aktiivinen space_blocks sulkuresurssilla → therapist_closed (hoidot kiinni), ei no_therapist. no_therapist vain kun slack < 0 eikä sulkua ole. p_override ohittaa sulun. Joonas 1.11.2026: sama sulku koskee jokaista tuotetta, jonka required_skill osoittaa tähän resurssiin.';
