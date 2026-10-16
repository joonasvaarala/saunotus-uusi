# Pyyntö Bottiavustukselle: `booking`-skeeman käyttöönotto (Supabase Tapio-havuhattu)

> Valmis viesti. Lähetetään vasta kun Joonas on hyväksynyt. Tämä PR ei sisällä salaisuuksia eikä asiakasdataa.

---

**Aihe:** Pyyntö: uusi `booking`-skeema (varausjärjestelmä), 9 migraatiota + 3 käsin tehtävää vaihetta

Hei Bottiavustus,

tarvitsen Supabase-projektiin Tapio-havuhattu uuden skeeman `booking` (oma varausjärjestelmä Johkun tilalle). Kaikki muutokset ovat repossa `joonasvaarala/saunotus-uusi`, haara `booking`, hakemisto `booking/supabase/migrations/`. Testattu paikallisessa Postgresissa (466 pgTAP-tarkistusta + kilpa-ajotesti + mutaatiotarkistus, `booking/supabase/tests/run.sh`).

**Mitä EI muuteta:** `public`-skeema (Työvuoro-Tapio) ja `kb`-skeeman rakenne. Migraatiot eivät tee `ALTER`/`DROP`/`CREATE` mitään `kb`-skeemassa. Ne vain (a) viittaavat kb-tauluihin viiteavaimilla ja (b) lukevat kb:tä.

**Ajojärjestys (tiedostonimen mukaan, jokainen yhdessä transaktiossa):**

| # | Tiedosto | Mitä tekee |
|---|---|---|
| 1 | `20261016150001_booking_01_core.sql` | `create extension if not exists btree_gist` (extensions-skeemaan), skeema `booking`, apufunktiot (`is_staff`, `is_admin`, `has_permission`, `_require_permission`, `_err`…), roolitaulut `roles` (admin, manager, staff + ei-henkilöstö customer, annual_card) ja `role_permissions`, `staff`, `settings`, `resources`, `audit_log` |
| 2 | `…02_data_model.sql` | asiakkaat (`customer_type`, `auth_user_id` tulevaa itsepalvelua varten), tilaukset, rivit, varaukset, maksut, maksutavat, lahjakortit, alennuskoodit, markkinointitaulut, vuosikortit (`annual_cards`) |
| 3 | `…03_schedule_rules.sql` | `schedule_rules`, `schedule_rule_pools`, `product_config`, `space_blocks` |
| 4 | `…04_engine.sql` | päällekkäisyys-/kapasiteettitriggeri (advisory lock + exclusion constraint; vuosikorttisäännöt), `_sessions`, `expire_holds()` |
| 5 | `…05_booking_api.sql` | julkiset `public_*`-funktiot (SECURITY DEFINER, rate limit), mm. `public_change_booking` (asiakkaan varauksen muutos ≥ 48 h ennen alkua; vahvistetun varauksen asiakasperuutus ei käytössä) |
| 6 | `…06_admin_api.sql` | `admin_*`-funktiot (oikeustarkistus roolin oikeuksilla; uudet: `admin_my_permissions`, `admin_list_roles`, `admin_update_schedule_rule`, `admin_change_booking`, `admin_grant_annual_card`, `admin_update_annual_card`, `admin_revoke_annual_card`, `admin_list_annual_cards`, `admin_create_annual_card_booking`) ja `payment_*`-adapteri. **Nämä funktiot kirjoittavat kb:hen (ks. alla)** |
| 7 | `…07_rls_grants.sql` | RLS kaikille `booking`-tauluille, oikeudet minimiin (anon: vain `public_*`-funktiot; authenticated: luku staff-RLS:llä; kirjoitus vain funktioilla; `payment_*` vain service_role) |
| 8 | `…08_seed_rules.sql` | asetukset, resurssit/kapasiteettipoolit (viikonloppu: oma pooli per alkamisaika), tuotekonfiguraatio ja 30 vuorosääntöä (13 yleistä + 17 yksityistä; kb-tuotteet haetaan `external_system='johku'` + `external_id` -avaimella; kaatuu selkeästi jos yksityisvuoron hintavarianttia ei löydy) |
| 9 | `…09_cron_optional.sql` | **valinnainen:** pg_cron-ajastus pitojen vanhentamiselle (ohittaa hiljaa jos pg_cron ei ole päällä) |

**kb-muutokset (vain data, vain admin-funktioiden kautta, ei skeemamuutosta):**
* `booking.admin_update_product(id, patch)` päivittää `kb.products`: `name, name_en, description, description_en, price, price_text, vat_rate, active` (+ `updated_at`).
* `booking.admin_update_price_variant(id, patch)` päivittää `kb.product_price_variants`: `label, price, notes, active, included_persons, extra_person_price`.
* Molemmat kirjaavat rivin `kb.change_log` (actor `booking-admin:<uid>`) ja `booking.audit_log`. SECURITY DEFINER, `search_path=''`, vain `authenticated`; oikeus `catalog.edit` (roolit `manager` ja `admin`) tarkistetaan funktiossa. Peruskäyttäjä (`staff`) ei voi muokata hintoja.
* Kaikki päivitettävät sarakkeet ovat jo olemassa kb:ssä (varmistettu SELECT-vain `list_tables` 16.10.2026); kb-skeemaan ei lisätä mitään.

**Roolit:**
* `anon`: ei pääsyä tauluihin. Saa suorittaa vain `public_settings, public_catalog, public_availability, public_create_booking, public_get_booking, public_cancel_booking` (vain maksamattoman pidon vapautus), `public_change_booking`.
* `authenticated`: SELECT staff-RLS:llä (`booking.is_staff()`); kirjoitus vain `admin_*`-funktioilla, joiden oikeudet määräytyvät roolista (`booking.roles` / `booking.role_permissions`). Pelkkä Auth-tili ei anna oikeuksia ilman riviä `booking.staff`. Roolit: `admin` (kaikki), `manager` = ylläpitäjä (hinnat, kuvaukset, tuoteasetukset, asetukset, resurssit, vuorosäännöt, vuosikortit), `staff` = peruskäyttäjä (varaukset, asiakkaat, maksujen kirjaus, sulut).
* `service_role`: kaikki (tulevat Edge Functionit: Visma Pay, sähköpostit).
* Uusia Postgres-rooleja ei luoda.

**Käsin tehtävät (kertaluonteiset), kun migraatiot on ajettu (3 vaihetta):**
1. **Skeema REST-rajapintaan:** lisää `booking` Exposed schemas -listalle nykyisten jatkoksi (älä poista mitään). Ohje: `booking/supabase/manual/01_expose_schema.md`.
2. **Henkilökunnan tilit ja roolit:** Joonas luo Supabase Authiin käyttäjät (Dashboard → Authentication → Users → Add user, auto-confirm). Sen jälkeen ajetaan `booking/supabase/manual/02_first_admin.sql`, jossa on KOLME erillistä lohkoa (vaihda sähköpostit): (b1) `admin` – Joonas ja Koodari, (b2) `manager` (ylläpitäjä) – Otto ja Laura, (b3) `staff` (peruskäyttäjä) – muut työntekijät. Lisää rivit tauluun `booking.staff`. Jatkossa henkilöstöä hallitaan hallinnasta (vain `admin`).
3. **Tarkistus (vain luku):** `booking/supabase/manual/03_verify.sql` + `get_advisors` (security, performance) skeemalle `booking`; raportoi löydökset.

**Älä:** aja migraatioita muuhun projektiin, muuta `public`-skeemaa, tai tulosta/tallenna avaimia. Hallinnan ja kaupan käyttöön annetaan vain julkinen anon/publishable-avain (frontendissä); service role -avain ei mene frontendiin eikä repoon.

**Palauta minulle:** onnistuiko jokainen migraatio (virheilmoitus kokonaisena jos ei), advisor-löydökset, ja ovatko `kb.product_price_variants.included_persons`/`extra_person_price` olemassa.

Kiitos!
