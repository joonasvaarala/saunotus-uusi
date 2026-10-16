# Pyyntö Bottiavustukselle: `booking`-skeeman käyttöönotto (Supabase Tapio-havuhattu)

> **PÄIVITYS 16.10. (v5, testiversion julkaisu GitHub Pagesiin) – lue ensin tämä:**
> 1. **Aja uusi migraatio 10:** `booking/supabase/migrations/20261016150010_booking_10_rls_initplan.sql`. Se korvaa RLS-politiikat (`staff_self_read` ym.) muodolla `(select auth.uid())` / `(select booking.is_staff())` (advisor `auth_rls_initplan`, WARN). Sama semantiikka, idempotentti (`drop policy if exists` + `create policy`), ei kosketa migraatioihin 01–09, ei `public`- eikä `kb`-skeemaan. Ajon jälkeen aja `get_advisors` (performance) uudelleen: `auth_rls_initplan`-varoituksia ei pitäisi enää olla `booking`-skeemassa. Paikallinen testi: 571 pgTAP-tarkistusta + kilpailutesti läpi.
> 2. **Edge Function `admin-users` – uudelleendeploy SUOSITELTAVA, ei pakollinen.** `index.ts` EI muuttunut; muutos on `logic.js`:ssä (`resolveRedirect`): kutsulinkin kohde on `INVITE_REDIRECT_URL` (ensisijainen, sellaisenaan), muuten `SITE_URL + /hallinta/` (aiemmin varakohde oli `/admin/`), tyhjät/välilyönnit trimmataan. Jos Joonas asettaa `INVITE_REDIRECT_URL`-salaisuuden (`https://joonasvaarala.github.io/saunotus-uusi/hallinta/`), jo deployattu versio toimii sellaisenaan; deploy tarvitaan vain, jos halutaan uusi varakäyttäytyminen. **Salaisuuksien muutos ei vaadi deployta**, mutta tarkista, että `ALLOWED_ORIGINS` sisältää `https://joonasvaarala.github.io` (CORS; muuten hallinnan Käyttäjät-kutsu epäonnistuu selaimessa).
> 3. **Auth → URL Configuration → Redirect URLs:** lisää `https://joonasvaarala.github.io/saunotus-uusi/hallinta/` (muuten kutsulinkki ohjautuu Site URL:iin).
> 4. Julkaisun (GitHub Pages) frontend-konfiguraatio tulee workflow'sta (`.github/workflows/pages.yml`): vain julkinen publishable-avain; service role -avain ei koskaan frontendiin tai repoon. Bottiavustuksen ei tarvitse tehdä sille mitään.

> Valmis viesti. Lähetetään vasta kun Joonas on hyväksynyt. Tämä PR ei sisällä salaisuuksia eikä asiakasdataa.

---

**Aihe:** Pyyntö: uusi `booking`-skeema (varausjärjestelmä), 10 migraatiota (01–09 ajettu jo; **10 uusi**) + Edge Function `admin-users` + käsin tehtävät vaiheet

Hei Bottiavustus,

tarvitsen Supabase-projektiin Tapio-havuhattu uuden skeeman `booking` (oma varausjärjestelmä Johkun tilalle). Kaikki muutokset ovat repossa `joonasvaarala/saunotus-uusi`, haara `booking`, hakemisto `booking/supabase/migrations/`. Testattu paikallisessa Postgresissa (555 pgTAP-tarkistusta + kilpa-ajotesti + mutaatiotarkistus, `booking/supabase/tests/run.sh`; Edge Functionin validointilogiikalle 9 yksikkötestiä: `node --test` / `deno test`).

**Mitä EI muuteta:** `public`-skeema (Työvuoro-Tapio) ja `kb`-skeeman rakenne. Migraatiot eivät kirjoita `public`-skeemaan mitään (ei INSERT/UPDATE/DELETE, ei DDL, ei GRANT); ne vain **lukevat** neljää taulua (ks. alla *Uusi: työvuorot*). Migraatiot eivät tee `ALTER`/`DROP`/`CREATE` mitään `kb`-skeemassa. Ne vain (a) viittaavat kb-tauluihin viiteavaimilla ja (b) lukevat kb:tä.

**Ajojärjestys (tiedostonimen mukaan, jokainen yhdessä transaktiossa):**

| # | Tiedosto | Mitä tekee |
|---|---|---|
| 1 | `20261016150001_booking_01_core.sql` | `create extension if not exists btree_gist` (extensions-skeemaan), skeema `booking`, apufunktiot (`is_staff`, `is_admin`, `has_permission`, `_require_permission`, `_err`…), roolitaulut `roles` (admin, manager, staff + ei-henkilöstö customer, annual_card) ja `role_permissions`, `staff`, `settings`, `resources`, `audit_log` |
| 2 | `…02_data_model.sql` | asiakkaat (`customer_type`, `auth_user_id` tulevaa itsepalvelua varten), tilaukset, rivit, varaukset, maksut, maksutavat, lahjakortit, alennuskoodit, markkinointitaulut, vuosikortit (`annual_cards`) |
| 3 | `…03_schedule_rules.sql` | `schedule_rules`, `schedule_rule_pools`, `product_config`, `space_blocks` |
| 4 | `…04_engine.sql` | päällekkäisyys-/kapasiteettitriggeri (advisory lock + exclusion constraint; vuosikorttisäännöt), `_sessions`, `expire_holds()` |
| 5 | `…05_booking_api.sql` | julkiset `public_*`-funktiot (SECURITY DEFINER, rate limit), mm. `public_change_booking` (asiakkaan varauksen muutos ≥ 48 h ennen alkua; vahvistetun varauksen asiakasperuutus ei käytössä) |
| 6 | `…06_admin_api.sql` | `admin_*`-funktiot (oikeustarkistus roolin oikeuksilla; uudet: `admin_my_permissions`, `admin_list_roles`, `admin_update_schedule_rule`, `admin_change_booking`, `admin_grant_annual_card`, `admin_update_annual_card`, `admin_revoke_annual_card`, `admin_list_annual_cards`, `admin_create_annual_card_booking`; **uudet 16.10.:** `admin_set_staff_role`, `admin_list_public_staff`, `admin_link_public_staff`, `admin_upcoming_shifts`, laajennetut `admin_list_staff` / `admin_upsert_staff`, sekä service_role-vain `svc_find_auth_user`, `svc_staff_upsert`, `svc_staff_set_active` Edge Functionia varten) ja `payment_*`-adapteri. **Nämä funktiot kirjoittavat kb:hen (ks. alla)** |
| 7 | `…07_rls_grants.sql` | RLS kaikille `booking`-tauluille, oikeudet minimiin (anon: vain `public_*`-funktiot; authenticated: luku staff-RLS:llä; kirjoitus vain funktioilla; `payment_*` vain service_role) |
| 8 | `…08_seed_rules.sql` | asetukset, resurssit/kapasiteettipoolit (viikonloppu: oma pooli per alkamisaika), tuotekonfiguraatio ja 30 vuorosääntöä (13 yleistä + 17 yksityistä; kb-tuotteet haetaan `external_system='johku'` + `external_id` -avaimella; kaatuu selkeästi jos yksityisvuoron hintavarianttia ei löydy) |
| 9 | `…09_cron_optional.sql` | **valinnainen:** pg_cron-ajastus pitojen vanhentamiselle (ohittaa hiljaa jos pg_cron ei ole päällä) |

**kb-muutokset (vain data, vain admin-funktioiden kautta, ei skeemamuutosta):**
* `booking.admin_update_product(id, patch)` päivittää `kb.products`: `name, name_en, description, description_en, price, price_text, vat_rate, active` (+ `updated_at`).
* `booking.admin_update_price_variant(id, patch)` päivittää `kb.product_price_variants`: `label, price, notes, active, included_persons, extra_person_price`.
* Molemmat kirjaavat rivin `kb.change_log` (actor `booking-admin:<uid>`) ja `booking.audit_log`. SECURITY DEFINER, `search_path=''`, vain `authenticated`; oikeus `catalog.edit` (roolit `manager` ja `admin`) tarkistetaan funktiossa. Peruskäyttäjä (`staff`) ei voi muokata hintoja.
* Kaikki päivitettävät sarakkeet ovat jo olemassa kb:ssä (varmistettu SELECT-vain `list_tables` 16.10.2026); kb-skeemaan ei lisätä mitään.

**Uusi: työvuorot (LUKU `public`-skeemasta) – TARKISTA SARAKENIMET ENNEN AJOA**
* Migraatiossa 01: `booking.staff.public_staff_id uuid unique` (nullable, **ei viiteavainta** `public`-skeemaan, selittävä `comment on column`) sekä oikeudet `shifts.view` (omat vuorot: staff) ja `shifts.view_all` (kaikki: manager, admin). `staff.manage` on edelleen vain adminilla.
* Migraatiossa 06 funktiot `admin_upcoming_shifts(from, to)` (SECURITY DEFINER, `search_path=''`, täysin kvalifioidut nimet; enintään 62 pv; palauttaa vain `shift_id, starts_at, ends_at, role_type, calendar_name, staffing_status, staff_name`), `admin_list_public_staff()` (vain `id, name, email, active`) ja `admin_link_public_staff(user, public_staff_id)` lukevat `public`-skeemaa. **Kirjoitusta `public`-skeemaan ei ole** (testattu).
* Koska koodia kirjoitettaessa ei ollut yhteyttä oikeaan `public`-skeemaan, sarakkeet ovat **OLETUKSIA**. Aja ensin `list_tables` (vain luku) skeemalle `public` ja varmista, että seuraavat löytyvät (tyypit/nimet täsmälleen):
  * `public.work_shifts`: `id uuid`, `calendar_source_id uuid`, `starts_at timestamptz`, `ends_at timestamptz`, `role_type text`, `status text` (arvo `'active'`), `staffing_status text`
  * `public.shift_assignments`: `shift_id uuid`, `staff_id uuid`
  * `public.staff`: `id uuid`, `name text`, `email text`, `active boolean`
  * `public.calendar_sources`: `id uuid`, `calendar_name text` (tarkistettu Bottiavustuksen toimesta)
  Jos jokin poikkeaa, **älä aja migraatiota 06 sellaisenaan**, vaan palauta minulle poikkeamat (taulu.sarake, todellinen nimi/tyyppi), niin korjaan funktioiden SELECT-osat. (Funktiot ovat plpgsql, joten väärä sarakenimi ei kaada migraatiota vaan vasta ajonaikaisen kutsun; siksi tarkistus ennen ajoa.) Funktiot toimivat SECURITY DEFINER -oikeuksilla (omistaja lukee `public`-taulut), joten `authenticated`/`anon`-rooleille **ei anneta** mitään oikeuksia `public`-tauluihin.
* Jos työvuorotiedot puuttuvat tai haku epäonnistuu, hallinnan kalenteri näyttää varaukset ja ystävällisen huomautuksen.

**Roolit:**
* `anon`: ei pääsyä tauluihin (eikä uusiin admin_*/svc_*-funktioihin). Saa suorittaa vain `public_settings, public_catalog, public_availability, public_create_booking, public_get_booking, public_cancel_booking` (vain maksamattoman pidon vapautus), `public_change_booking`.
* `authenticated`: SELECT staff-RLS:llä (`booking.is_staff()`); kirjoitus vain `admin_*`-funktioilla, joiden oikeudet määräytyvät roolista (`booking.roles` / `booking.role_permissions`). Pelkkä Auth-tili ei anna oikeuksia ilman riviä `booking.staff`. Roolit: `admin` (kaikki), `manager` = ylläpitäjä (hinnat, kuvaukset, tuoteasetukset, asetukset, resurssit, vuorosäännöt, vuosikortit), `staff` = peruskäyttäjä (varaukset, asiakkaat, maksujen kirjaus, sulut).
* `service_role`: kaikki (Edge Function `admin-users`; tulevat Visma Pay ja sähköpostit). `svc_*`-funktiot ovat vain service_rolen käytössä.
* Uusia Postgres-rooleja ei luoda.

**Edge Function `admin-users` (kutsu, käytöstä poisto, aktivointi) – Deno, `verify_jwt = true`**
Koodi: `booking/supabase/functions/admin-users/` (`index.ts`, `logic.js`, `logic.test.js`), asetus `booking/supabase/config.toml`.
* Toiminnot (POST, JSON): `invite {email, name, role}`, `deactivate {user_id}`, `reactivate {user_id}`. Vastaus `{ok: true, …}` tai `{ok: false, code, message}`.
* Turvamalli: funktio tunnistaa kutsujan **kutsujan omalla JWT:llä** (`booking.is_admin()` anon-avaimella + kutsujan Authorization) – vain admin pääsee eteenpäin. Vasta sen jälkeen käytetään service role -avainta (vain palvelimella, ympäristömuuttujasta; ei lokiin eikä selaimelle) Auth Admin API:in (`inviteUserByEmail`, esto `ban_duration`) ja `booking.svc_*`-funktioihin, joissa säännöt ja audit-loki ovat (ei itseä, ei viimeistä adminia, rooli vain admin/manager/staff). CORS vain `ALLOWED_ORIGINS`-listan originille, syötteet validoidaan, salaisuuksia ei lokiteta.
* **Salaisuudet / ympäristömuuttujat:**
  | Muuttuja | Mistä | Huom |
  |---|---|---|
  | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Supabase asettaa Edge Functioneille automaattisesti | ei tarvitse asettaa käsin; älä tulosta |
  | `ALLOWED_ORIGINS` | **asetetaan käsin** | pilkuilla erotetut originit, esim. `https://<hallinnan-osoite>` (ei jokerimerkkiä; testissä myös `http://localhost:4180`) |
  | `SITE_URL` (tai `INVITE_REDIRECT_URL`) | **asetetaan käsin** | kutsulinkin kohde on `INVITE_REDIRECT_URL` sellaisenaan (ensisijainen) tai varana `SITE_URL + /hallinta/`; pitää olla https (tai http://localhost) |
* **Deploy** (Bottiavustus; ajetaan hakemistosta `booking/`, jossa `supabase/config.toml` on):
  ```
  supabase secrets set ALLOWED_ORIGINS="https://<hallinnan-osoite>" SITE_URL="https://<sivuston-osoite>" --project-ref <ref>
  supabase functions deploy admin-users --project-ref <ref>      # verify_jwt = true tulee config.toml:sta; ÄLÄ käytä --no-verify-jwt
  ```
  (Vaihtoehtoisesti Dashboardin kautta; tärkeintä: JWT-tarkistus päällä ja kaksi käsin asetettavaa muuttujaa.)
* **Auth-asetukset (Dashboard → Authentication):** (1) *URL Configuration → Redirect URLs*: lisää kutsulinkin kohde (`INVITE_REDIRECT_URL`, testiversiossa `https://joonasvaarala.github.io/saunotus-uusi/hallinta/`), muuten Supabase ohjaa kutsulinkin Site URL:iin. (2) Suositus: *Sign ups* pois päältä (kutsut toimivat silti). (3) Kutsusähköposti lähtee Supabasen oletuslähettäjältä (rajoitettu määrä, voi mennä roskapostiin) – kokeilulle riittää; tuotantoon oma SMTP (savusauna@saunotus.fi), ks. README *Puuttuu*. (4) Tarvittaessa muokkaa *Email Templates → Invite user* suomeksi (linkki `{{ .ConfirmationURL }}` pitää säilyä).
* **Testaus deployn jälkeen (ilman salaisuuksia):** a) kutsu ei-admin-tunnuksella (manager/staff) → 403; b) admin kutsuu testiosoitteen → rivi `booking.staff` + sähköposti; c) admin yrittää poistaa itsensä käytöstä → 409 `cannot_change_self`.

**Käsin tehtävät (kertaluonteiset), kun migraatiot on ajettu:**
1. **Skeema REST-rajapintaan:** lisää `booking` Exposed schemas -listalle nykyisten jatkoksi (älä poista mitään). Ohje: `booking/supabase/manual/01_expose_schema.md`.
2. **Ensimmäinen admin:** Joonas luo Supabase Authiin oman käyttäjänsä (Dashboard → Authentication → Users → Add user, auto-confirm; Joonas.vaarala@gmail.com). Sen jälkeen ajetaan `booking/supabase/manual/02_first_admin.sql`: testivaiheessa vain YKSI lohko (Joonas = `admin`); muut roolit ovat kommentoituina. Muut käyttäjät kutsutaan hallinnan Käyttäjät-näkymästä (vain `admin`) Edge Functionin kautta.
3. **Edge Function:** salaisuudet, deploy ja Auth-asetukset kuten yllä.
4. **Tarkistus (vain luku):** `booking/supabase/manual/03_verify.sql` + `get_advisors` (security, performance) skeemalle `booking`; raportoi löydökset.

**Älä:** aja migraatioita muuhun projektiin, muuta `public`-skeemaa (vain luku!), tai tulosta/tallenna avaimia. Hallinnan ja kaupan käyttöön annetaan vain julkinen anon/publishable-avain (frontendissä); service role -avain ei mene frontendiin eikä repoon.

**Palauta minulle:** `public`-sarakkeiden tarkistuksen tulos (täsmäävätkö oletetut nimet), onnistuiko jokainen migraatio (virheilmoitus kokonaisena jos ei), advisor-löydökset, ja ovatko `kb.product_price_variants.included_persons`/`extra_person_price` olemassa.

Kiitos!
