# Oma varausjärjestelmä (korvaa Johkun) – Sipoonjoen perinnesauna

Kevyt, nopea ja helposti muokattava varausjärjestelmä: **Supabase (Postgres, skeema `booking`) + staattinen kauppa + staattinen hallinta**.
Ei palvelinkoodia, ei build-vaihetta selaimen koodille, ei kirjastoriippuvuuksia. Kaikki säännöt (kapasiteetit, vuorot, hinnat) ovat dataa.

> Tila: **ei tuotannossa**. Visma Pay -maksut, sähköpostiviestit, lahjakortit, hoidot ja tapahtumat on rajattu pois ensimmäisestä vaiheesta (ks. [Puuttuu](#puuttuu-ja-seuraavat-vaiheet)).

## Sisältö

| Polku | Mitä |
|---|---|
| `supabase/migrations/` | SQL-migraatiot 01–50 (skeema `booking`; 01–09 ajettu testikantaan 16.10., 10 ja 11 odottavat ajoa; 12–13 ajettu tuotantoon, tiedostot lisättävä, ks. alla). **Ainoa tapa muuttaa tuotantokantaa.** |
| `supabase/tests/` | pgTAP-testit + kilpailutilannetesti (`run.sh`), mock-Supabase ja mock-kb |
| `supabase/manual/` | Käsin tehtävät vaiheet: skeeman avaus REST:iin, ensimmäinen admin, tarkistuskyselyt |
| `shared/sb.js` | ~110 rivin PostgREST/Auth-asiakas (käytetään kaupassa ja hallinnassa) |
| `shop/` | Varauskauppa: **kopio uudesta sivustosta**, jossa Johku-linkit avaavat sisäisen kalenterin |
| `admin/` | Hallinta-SPA (mobiili ensin + työpöytä), Supabase Auth. Näkymät: Päivä (+ lisäpalvelujen "Valmistele"-yhteenveto), Varaukset (**Ajanjakso**-pikavalinta Kaikki ajat (oletus) / Tulevat / Menneet / Tämä kuukausi / Oma ajanjakso, **lähdesuodatin Kaikki / Uudet / Johku**; Johku-varauksilla "Johku"-tunniste; kortin oikeassa yläkulmassa tilausnumero ja oikeassa alakulmassa hinta), **Kalenteri** (työvuorot + varaukset), Uusi varaus (asiakastyyppi, lisäpalvelut), Asiakkaat (**Lisää asiakas**: yksityinen/yritys), Tuotteet (+ **Lisäpalvelut**), Resurssit, Asetukset, **Käyttäjät** (vain admin) |
| `supabase/functions/admin-users/` | Edge Function (Deno, `verify_jwt = true`): käyttäjien kutsu, käytöstä poisto ja aktivointi. Validointilogiikka `logic.js` + testit |
| `supabase/functions/{send-emails,receipt-pdf,report-pdf,gift-card-pdf,vismapay-*,procountor-sync}/` | Talous-integraatiot (sähköposti Resend, kuitti-/raportti-/lahjakortti-PDF, Visma Pay- ja Procountor-rungot; mode `off`/`dry_run`). Ohje: [docs/talous-integraatiot.md](docs/talous-integraatiot.md); sähköpostipohjien testit `send-emails/templates.test.mjs` |
| `supabase/rollbacks/` | Migraatioiden 24–44, 49 ja 50 palautus-SQL:t (37–38 ja 39–40 yhteisiä; 43:lla lisäksi `…_43_import_ROLLBACK.sql` Johku-tuonnin purkuun; versionumero kuten tuotannossa; EI `migrations/`-kansiossa, ettei CLI aja niitä) |
| `dev/` | Paikallinen demo: PostgREST-konfiguraatio, kehityspalvelin (mock-auth), demo-siemen |
| `scripts/e2e-screenshots.mjs` | Playwright-savutesti + kuvakaappaukset + konsolivirhetarkistus |
| `scripts/e2e-shop-layout.mjs` | Kaupan varauslomakkeen ja päivänäkymän (`#/paiva/<pvm>`) asettelutesti (360/390/430/1280 px, FI+EN, yksityinen+yritys; kosketuskohteet, kontrasti, näppäimistö): ei vaakavieritystä, osiot samassa linjassa, järjestys ja otsikot; varauslomakkeen otsikon alla lyhyt yhteenveto (tuote, päivä, kellonaika) ja linkki "Vaihda päivää tai aikaa" (päivänäkymästä `?via=day` → `#/paiva/<pvm>?tuote=<slug>`, muuten `#/tuote/<slug>/<pvm>`) |
| `scripts/e2e-shop-vain-vapaat.mjs` | Kaupan asiakasnäkymä näyttää vain vapaat vuorot (päivänäkymän tuotekortti, tuotesivun vuorolista, ajanmuutosnäkymä; täynnä-päivä → ”Ei vapaita vuoroja”). Ei tarvitse tietokantaa: kaupan build + mockatut `public_*`-RPC:t (sekä vapaita että täynnä-vuoroja) |
| `docs/` | Maksurajapinta, Johku-tuonti, ristiriidat ja tulkinnat, Bottiavustuspyyntö, kuvakaappaukset |

## Arkkitehtuuri

```mermaid
flowchart LR
  subgraph Selain
    S[Kauppa shop/ - anon] --- SB[shared/sb.js]
    A[Hallinta admin/ - kirjautunut staff/manager/admin] --- SB
  end
  SB -->|REST + RPC, apikey| PR[Supabase PostgREST]
  A -->|Auth| AU[Supabase Auth]
  PR --> DB[(Postgres: schema booking)]
  DB --- KB[(schema kb: tuotteet, hinnat, sijainnit)]
  DB -.->|jatkossa| VP[Visma Pay - maksuadapteri, service_role]
```

* **Kauppa (anon)** käyttää vain 7 julkista RPC-funktiota: `public_catalog`, `public_availability`, `public_create_booking`, `public_get_booking`, `public_change_booking`, `public_cancel_booking` (vain maksamattoman pidon vapautus), `public_settings`. Suoraa taulu-oikeutta anonilla ei ole. Asiakastietoja ei voi lukea.
* **Asiakas ei peruuta vahvistettua varausta itse.** Peruutukset sähköpostilla henkilökunnalle, joka peruu hallinnasta. Asiakas voi sen sijaan **muuttaa** varausta kauppasivulla (token-linkki): siirtää toiselle vapaalle vuorolle (sama tuote) tai muuttaa henkilömäärää, viimeistään 48 h ennen vuoron alkua (asetus `customer_change_hours_before`). Muutos on atomistinen ja noudattaa samoja lukkoja ja sääntöjä kuin uusi varaus (kapasiteetti, yksityinen ↔ yleinen -päällekkäisyys).
* **Hallinta (authenticated + `booking.staff`)** käyttää `admin_*`-funktioita ja RLS-suojattua lukua. Roolit `admin` (kaikki), `manager` = ylläpitäjä (hinnat, kuvaukset, asetukset, resurssit, vuorosäännöt, vuosikortit) ja `staff` = peruskäyttäjä (varaukset, asiakkaat, maksut, sulut). Roolit ja oikeudet ovat tauluja (`roles`, `role_permissions`); uusi rooli = INSERT. Ks. [docs/roolit-ja-kb.md](docs/roolit-ja-kb.md).
* **Vuosikortti:** `annual_cards`; vuosikorttiasiakas varaa ilmaiseksi (0 €) vain yleisiä vuoroja, yksi tuleva varaus kerrallaan, ei yksityisvuoroja (pakotus varausmoottorissa). Itsepalvelua ei vielä ole, mutta `customers.auth_user_id` on valmiina.
* **Totuus tuotteille ja hinnoille on `kb`** (`kb.products`, `kb.product_price_variants`). Varausjärjestelmä lukee hinnat suoraan sieltä; hallinta muokkaa niitä rajatulla `SECURITY DEFINER` -funktiolla (oikeus `catalog.edit`: manager ja admin; auditoitu, kirjaa myös `kb.change_log`).
* **Vuorot ja kapasiteetit ovat dataa** (`schedule_rules`, `resources`), vuoroinstanssit lasketaan lennossa (`booking._sessions`). Ei etukäteen luotuja vuoroja → ei ajastettuja generointiajoja.

### Miksi vanilla JS + staattinen (ei React/Vue)?
Sivusto on jo staattinen, nopea ja ilman riippuvuuksia. Kauppa ja hallinta ovat ~600 + ~900 riviä ES-moduuleja ilman build-vaihetta: avaat tiedoston, muokkaat, päivität selaimen. Ei `node_modules`-tuontia, ei haavoittuvuuspäivityksiä, Lighthouse-pisteet pysyvät ylhäällä, ja Pages-julkaisu pysyy ennallaan. Haittapuoli (ei komponenttikirjastoa) on tässä laajuudessa pieni; jos hallinta kasvaa selvästi, näkymät (`admin/views/*.js`) on helppo siirtää esim. Preactiin.

## Tietomalli

```mermaid
erDiagram
  customers ||--o{ orders : "tekee"
  orders ||--|{ order_items : "rivit (ALV/rivi)"
  orders ||--o{ reservations : "sisältää"
  orders ||--o{ payments : "maksut"
  orders }o--o| discount_codes : "alennus"
  order_items }o--o| gift_cards : "lahjakortti (paikka)"
  gift_cards ||--o{ gift_card_ledger : "kirjaukset"
  payments }o--|| payment_methods : "tapa"
  reservations }o--|| resources : "tila (space)"
  reservations }o--o| schedule_rules : "sääntö"
  schedule_rules }o--|| product_config : "tuote"
  schedule_rules ||--o{ schedule_rule_pools : "kuluttaa"
  schedule_rule_pools }o--|| resources : "capacity_pool"
  product_config }o--|| kb_products : "FK kb.products"
  resources ||--o{ space_blocks : "sulut"
  customers ||--o{ marketing_consent_events : "suostumusloki"
  marketing_segments ||--o{ marketing_segment_members : ""
  campaigns ||--o{ campaign_sends : "lähetysloki"
  staff }o--|| auth_users : "FK auth.users"
  staff }o--|| roles : "rooli"
  roles ||--o{ role_permissions : "oikeudet"
  customers ||--o{ annual_cards : "vuosikortti"
  annual_cards ||--o{ reservations : "ilmaiset varaukset"
```

Keskeiset taulut (kaikissa RLS päällä; tarkka rakenne migraatioissa 02–03):

* `customers` – yhteystiedot, `marketing_consent` + `_at` + `_source` + `_text_version`, `unsubscribe_token`, `external_source/external_id`, `anonymized_at` (GDPR).
* `orders` – `order_no` (alkaa 10001), `public_token` (vahvistussivun salainen linkki), `status`, `payment_status`, `total_gross`, `source_channel` (`web|admin|phone|email|walk_in|johku_import|other`), `external_source='johku'`, `external_id`, `johku_order_no`.
* `order_items` – rivikohtainen `vat_rate` (24 / 25.5 / 14 / 13.5 / 10 / 0), generoidut `line_net` / `line_vat`.
* `reservations` – `space_id`, `mode` (`shared`/`exclusive`), `starts_at/ends_at`, generoitu `during`, `persons`, `pool_ids` (kapasiteettipoolit, snapshot), `status`, `hold_expires_at`, `rule_id`.
* `payments` – `provider`, `provider_ref`, `status`, `method`, `amount`, `link_url`, `raw`.
* `discount_codes`, `gift_cards`, `gift_card_ledger` – alennus- ja lahjakorttipaikat (ei vielä käytössä kaupassa).
* `marketing_segments`, `marketing_segment_members`, `campaigns`, `campaign_sends` – markkinoinnin rakenne (ei vielä käytössä).
* `roles`, `role_permissions` – roolit (admin, manager, staff + ei-henkilöstö customer, annual_card) ja niiden oikeudet; `staff.role` viittaa rooliin.
* `annual_cards` – asiakkaan vuosikortti (`valid_from/valid_to`, `active`); `customers.customer_type` ja `customers.auth_user_id` (tuleva itsepalvelu); `reservations.annual_card_id`.
* `audit_log` – kaikkien keskeisten taulujen muutokset (trigger) + hallinnan kb-muutokset.
* `customer_kinds` – asiakastyypit taulupohjaisesti (`private` = yksityisasiakas, `company` = yritysasiakas). `customers.customer_kind` + `business_id` (y-tunnus), `einvoice_address` (verkkolaskuosoite/OVT), `einvoice_operator` (välittäjätunnus), `invoice_reference`; osoite käyttää sarakkeita `company, address, zip, city, country`. **`customer_type` (customer/annual_card) on eri akseli** (etuustaso), `customer_kind` kertoo yksityinen vs. yritys. `orders.customer_kind`, `orders.billing` (laskutustietojen kuva tilaushetkeltä) ja `orders.invoice_reference` säilyttävät tilauksen laskutustiedot, vaikka asiakasrekisteri myöhemmin muuttuisi.
* `addons` – lisäpalvelut: `price_gross` (sis. ALV, kuten kaikki hinnat), `vat_rate`, `max_per_person`, `applies_modes` (yleinen/yksityinen vuoro), `active`. Tilauksella lisäpalvelu on `order_items`-rivi (`kind='addon'`, `addon_id`, `parent_item_id` = varausrivi), joten summa, ALV-erittely ja vuorokohtainen yhteenveto tulevat samasta rivitaulusta. Hinta kopioituu riville tilaushetkellä (hinnanmuutos ei muuta vanhoja tilauksia).

## Päällekkäisyyssäännöt (yksityinen ↔ yleinen) – miten varmistetaan

Kaikki yhdessä paikassa: trigger `booking.reservations_validate` (BEFORE INSERT/UPDATE, `migraatio 04`). Jokainen varaus (kauppa, hallinta, tuonti) kulkee sen läpi.

1. Trigger ottaa tilakohtaisen **advisory-lukon** (`pg_advisory_xact_lock('booking:space:<id>')`) → saman tilan varaukset käsitellään yksi kerrallaan.
2. Lukon sisällä tarkistetaan aktiiviset varaukset (`confirmed` tai `pending` jonka pito ei ole vanhentunut):
   * **yksityinen** + mikä tahansa aktiivinen päällekkäinen → virhe `public_shift_booked` / `private_booked`;
   * **yleinen** + aktiivinen yksityinen päällekkäin → `private_booked`;
   * **yleinen**: kapasiteettipoolien huippukuorma aikavälillä (sweep alkuhetkien yli) + henkilöt > pool → `capacity_exceeded`;
   * sulku (`space_blocks`) → `space_closed`.
3. Varalla **exclusion constraint** (`btree_gist`) estää kaksi yksityistä päällekkäin vaikka trigger ohitettaisiin.
4. Lukukysely (`_sessions`) laskee saman logiikan, joten kalenteri näyttää myös yksityisvuoron vaikutuksen ("Ei varattavissa") ja täydet vuorot.

Kapasiteetit (data, `resources` + `schedule_rule_pools`):

| Aika | Sääntö |
|---|---|
| ma–ke | 16 hlöä (pooli `yleinen_arki`) |
| to | Turvesauna 16–17: max 8 (pooli `turve`); yleinen 17–19; yhteensä max 16 (turve kuluttaa myös `yleinen_arki`-poolia) |
| la–su 2 h vuorot | Alkuajat 14:00, 14:30, 15:00, 16:00, 16:30, 17:00 (viimeinen päättyy 19:00); **6 hlöä PER ALKAMISAIKA** – jokaisella alkamisajalla oma pooli `yleinen_vkp_1400` … `yleinen_vkp_1700` (6 hlö), alkamisajat eivät jaa paikkoja. 15:30 ei ole alkuaika. |
| la–su 1 h vuorot | 14:00 ja 18:00 (Johku 152, 18 €): **10 hlöä / vuoro**, omat poolit `tunti_vkp_1400` ja `tunti_vkp_1800`; ei jaa paikkoja 2 h vuorojen kanssa |
| yksityinen ↔ yleinen | Yksityinen ja yleinen vuoro eivät saa olla päällekkäin kumpaankaan suuntaan (myös 1 h vuorot); yksikin yleisen vuoron varaus estää päällekkäisen yksityisvuoron |

Tulkinnat ja avoimet kysymykset: [docs/ristiriidat-ja-tulkinnat.md](docs/ristiriidat-ja-tulkinnat.md).

## Asennus (tuotanto)

**Edellytykset:** Supabase-projekti, jossa on `kb`-skeema (tuotteet, hintavariantit, sijainnit, `kb.change_log`).
**Kantaan kirjoittaa vain Bottiavustus** – migraatioita ei aja kukaan muu eikä mitään SQL:ää ajeta tuotantoon käsin muuten kuin `supabase/manual/`-tiedostoista.

### Migraatiojärjestys

| # | Tiedosto | Mitä tekee |
|---|---|---|
| 01 | `…_booking_01_core.sql` | Skeema `booking`, `btree_gist`, apufunktiot, `roles` + `role_permissions`, `staff`, `settings`, `resources`, `product_config`, `audit_log`, roolifunktiot (`is_staff`, `is_admin`, `has_permission`) |
| 02 | `…_booking_02_data_model.sql` | Asiakkaat, tilaukset, rivit, varaukset (exclusion constraint), maksut, vuosikortit, lahjakortit, alennukset, markkinointi, rate limit |
| 03 | `…_booking_03_schedule_rules.sql` | Vuorosäännöt, kapasiteettipoolit, sulut |
| 04 | `…_booking_04_engine.sql` | Päällekkäisyys- ja kapasiteettilogiikka (trigger; poolikohtainen kapasiteetti, vuosikorttisäännöt), vuorogeneraattori, vanhenevat pidot |
| 05 | `…_booking_05_booking_api.sql` | Julkiset RPC:t (validointi, rate limit, pito, varauksen muutos 48 h) |
| 06 | `…_booking_06_admin_api.sql` | `admin_*`-funktiot (oikeustarkistus roolin oikeuksilla), kb-tuotemuokkaus, vuorosääntöjen muokkaus, varauksen muutos, vuosikortit, käyttäjähallinta (`admin_set_staff_role`, `admin_link_public_staff`…), työvuorojen lukunäkymä `admin_upcoming_shifts` (lukee `public`-skeemaa, ei kirjoita), `svc_*` (vain service_role, Edge Function), maksuadapterin funktiot (vain service_role) |
| 07 | `…_booking_07_rls_grants.sql` | RLS kaikkialla + minimioikeudet (revoke all → explicit grant) |
| 08 | `…_booking_08_seed_rules.sql` | Asetukset, resurssit (poolit), `product_config`, 30 vuorosääntöä kb:n pohjalta (13 yleistä + 17 yksityistä) |
| 09 | `…_booking_09_cron_optional.sql` | (valinnainen) pg_cron-ajastus pitojen siivoukseen; ohitetaan jos pg_cron puuttuu |
| 10 | `…_booking_10_rls_initplan.sql` | Suorituskyky: RLS-politiikat `(select auth.uid())` / `(select booking.is_staff())` -muotoon (advisor `auth_rls_initplan`); sama semantiikka, idempotentti. Ei muokkaa migraatioita 01–09 |
| 11 | `…_booking_11_customer_kinds_addons.sql` | Asiakastyypit (`customer_kinds`, yritysasiakkaan y-tunnus + verkkolaskutiedot, tilauksen laskutustietojen kuva), lisäpalvelut (`addons`, `order_items.kind='addon'`), `public_addons`, `public_create_booking` (+ asiakastyyppi, yritystiedot, lisäpalvelut), `admin_create_customer`, `admin_set_reservation_addons`, `admin_get_order`, `admin_list/create/update_addon` (`catalog.edit`), `admin_day_view` (+ "valmistele"-yhteenveto). Ei muokkaa migraatioita 01–10 eikä `kb`-skeemaa |
| 17a | `…20261016213905_booking_17a_schema.sql` | Resurssivaraukset: `reservation_legs`, `reservations.quota_exempt` / `claim_offset_min` / `claim_minutes` / `parent_reservation_id` / `override_reason`, näkymä `v_claims`, roolioikeus `bookings.override` (admin, manager) |
| 17b | `…20261016213924_booking_17b_validators.sql` | Validaattorit (tila varattu, saunottaja, vanhempi varaus, tilasäännöt) – virheet SQLSTATE `BK001`, koodi DETAIL-kentässä |
| 17c | `…20261016213953_booking_17c_admin.sql` | `admin_create_old_booking`, `admin_create_resource_booking`, `admin_move_reservation_space`, `admin_review_list`; `admin_day_view` / `admin_list_reservations` palauttavat lisäksi `space_code`, `lifecycle`, `legs`, `quota_exempt`, `override_reason`, claim-kentät |
| 17d | `…20261016214007_booking_17d_private_weekend_rules.sql` | Yksityisvuorojen viikonloppusäännöt |
| 18a | `…20261016221808_booking_18a_schema.sql` | Sulkukalenterit: resurssi `laura` (person, käsin tehtävät koulutus-/poissaolosulut), `closure_calendars` (4 kalenteria, `active=false`), `closure_event_rules` (luokittelusäännöt: peilit, merkinnät, Koulutus → ei sulje), `closure_events` (kirjanpito + ohitus), `closure_sync_runs`, `space_blocks.closure_event_id`, trigger joka estää kalenterisulun muokkauksen (`closure_managed`) |
| 18b | `…20261016221825_booking_18b_sync.sql` | `apply_closure_events` (idempotentti snapshot-synkka, massapoistosuoja, dry-run; vain `service_role`), `_reconcile_closure_blocks`, `admin_closure_overview(p_days)` ja `admin_set_closure_override(p_event_id, p_override, p_note)` (oikeus `blocks.manage`) |
| 18c | `…20261016221840_booking_18c_validators.sql` | Validaattorit lukevat kalenterisulut; Lauran taidon legit laura-resurssille; `admin_day_view`: `blocks`-riveillä `closure_event_id` ja `resource_code` |
| 19 | `…_booking_19_product_images.sql` | Tuotekuvat: `product_config.image_path/image_alt`, Storage-bucket `product-images` (julkinen luku, kirjoitus `catalog.edit`), `public_product_images()`, `admin_set_product_image()` (+ audit). Vain lisäyksiä – ei korvaa aiempia funktioita. Ajettu tuotantoon (versio `20261016222439`). |
| 20 | `…20261016224525_booking_20_fk_indexes.sql` | Suorituskyky: puuttuvat viiteavainindeksit (advisor `unindexed_foreign_keys`). Ajettu tuotantoon. |
| 21 | `…20261016233600_booking_21_ritual_pool_1730.sql` | Uusi kapasiteettipooli `yleinen_vkp_1730`: kb 7 -paketti voi alkaa klo 17:00. Ajettu tuotantoon. |
| 22 | `…20261016234502_booking_22_therapist_missing.sql` | Saunottaja puuttuu -merkintä: `reservations.therapist_missing` + `therapist_exception_by/at/note`; jos vain saunottajatarkistus ei täyty, varaus luodaan merkittynä (`warning: 'therapist_missing'`); `admin_review_list.missing_therapist`; `admin_grant_therapist_exception`; `therapist_missing_digest` (vain `service_role`). Ajettu tuotantoon. |
| 23 | `…20261016234534_booking_23_time_windows.sql` | Aikaikkunat: hoitotyyppiset tuotteet (kb 10, 11–15, 16–22, 23, 24) ma–pe 16:00–20:30, la–su 13:00–20:30, ei yli keskiyön; rituaalit (kb 7, 8) alkavat vain 16:00 / 16:30 / 17:00; virheet `time_window` / `ritual_start`; ylitys `bookings.override`. Ajettu tuotantoon. |
| 24 | `…20261017000153_booking_24_closure_writeback.sql` | Hallinnan sulut → Google-sulkukalenteri (jono / outbox). Additiivinen. Ajettu tuotantoon. |
| 25 | `…20261017002011_booking_25_public_treatment.sql` | Julkinen hoito-/saunotusvaraus (aikaväli- eli legipohjainen "slots"-polku), `admin_treatment_availability`. Ajettu tuotantoon. |
| 26 | `…20261017011809_booking_26_publish_treatments.sql` | Hoito- ja rituaalivaraus kb 8, 10, 11, 12 näkyviin ja varattaviksi (liput; rollback palauttaa liput `false`). Ajettu tuotantoon. |
| 27 | `…20261017072446_booking_27_pyyhe_resource_addons.sql` | Pyyhe (5 €), lisäpalvelurajaus hoitoihin/saunotuksiin/tapahtumiin, `code` `admin_day_view`:hin, päivän työvuorot kaikille henkilöstöroolille. Ajettu tuotantoon. |
| 28 | `…20261017073438_booking_28_descriptions.sql` | Tuotekuvaukset kb 8, 10, 11, 12 (`kb.products.description` / `description_en`); vain tekstit. Ajettu tuotantoon. |
| 29 | `…20261017083344_booking_29_talous_schema.sql` | Talous (vaiheet A–D): `vat_rates`, `payment_lines`, `refunds`, `receipts`, `email_outbox`, `order_requests`, `accounting_outbox`, `integration_config`; `payments.rounding/link_sent_at`; uudet oikeudet. Ajettu tuotantoon. |
| 30 | `…20261017083349_booking_30_talous_rpc.sql` | Vaihe A: RPC:t, maksujen kohdistus, maksulinkki, hyvitys, ALV. Ajettu tuotantoon. |
| 31 | `…20261017084040_booking_31_talous_receipts.sql` | Vaihe B: kuitit, hyvityskuitit, sähköpostijono, tilausvahvistus. Ajettu tuotantoon. |
| 32 | `…20261017084644_booking_32_talous_reports.sql` | Vaihe D: päivä-/kuukausiraportit kuittien snapshoteista (kassaperuste). Ajettu tuotantoon. |
| 33 | `…20261017085256_booking_33_talous_customer_order.sql` | Vaihe C (tietokantapuoli): asiakkaan tilaussivu, lisäykset, peruutuspyyntö, ajanmuutos. Ajettu tuotantoon. |
| 34 | `…20261017090939_booking_34_talous_followups.sql` | CSV-sarakkeet, hyvitykset negatiivisina raportissa, maksurivien net/vat, `order_page_path`. Ajettu tuotantoon. |
| 35 | `…20261017093548_booking_35_talous_report_fields.sql` | Raportin `totals.gross_after_refunds`, `period.kind`. Ajettu tuotantoon. |
| 36 | `…20261017093814_booking_36_talous_grants_fix.sql` | `_vat_active` ei kutsuttavissa REST-rajapinnasta (advisor). Ajettu tuotantoon. |
| 37 | `…20261017100926_booking_37_addon_merge_step1.sql` | Johku-lisäpalvelurivit (kb 45) → addon-rivi emovarauksen tietoihin; `reservations.hidden_at/hidden_reason`. **Tuotantodataa** (kiinteät id:t). Ajettu tuotantoon. |
| 38 | `…20261017100937_booking_38_addon_merge_hide.sql` | Yhdistettyjen Johku-varausrivien piilotus + listausfunktiot suodattavat `hidden_at is null`. **Tuotantodataa**. Ajettu tuotantoon. |
| 39 | `…20261017102039_booking_39_vihta_move_addon.sql` | Saunavihta-lisäpalvelu siirretty tilaukselta 11552 tilaukselle 11551. **Tuotantodataa**. Ajettu tuotantoon. |
| 40 | `…20261017102049_booking_40_vihta_hide_10212.sql` | Varaus 10212 piilotettu (yhdistetty lisäpalveluksi). **Tuotantodataa**. Ajettu tuotantoon. |
| 41 | `…20261017102841_booking_41_johku_ei_kirjanpitoon.sql` | Johku ei kirjanpitoon: `_acct_excluded`, kuitti-/outbox-triggerit, `statistics.johku` raporteissa, `source/is_johku` + `*_ex_johku`-summat `admin_list_payments`:ssa. Ajettu tuotantoon. |
| 42 | `…20261017103037_booking_42_hide_package_side_shifts.sql` | Paketin (kb 7) oheisvuoroiksi tuodut 25 Johku-varausta piilotetaan (`status='cancelled'`, `hidden_at`, `merged_into_package`; alkuperäiset arvot talteen `external_meta.merged_into`). **Tuotantodataa**: tarkistaa tasan 25 riviä, joten ei aja tyhjällä kannalla eikä testiprojektissa. Rollback palauttaa rivit alkuperäisiksi. Ajettu tuotantoon. |
| 43 | `…20261017120517_booking_43_giftcards_schema.sql` | Lahjakortit, skeema (sopimus §13): uudet `gift_card_packages` (avoin + 4 pakettia), `gift_card_blocked_codes`, `gift_card_check_log`; `gift_cards` ja `gift_card_ledger` laajennettu (lähde, paketti, ostaja/saaja, tervehdys ≤300, ALV-käsittely, `public_token`, saldon varmistus; ledger append-only); `payment_methods.gift_card` ei enää käsin kirjattava; kytkimet `gift_cards.*` (kaikki `false`); oikeudet `giftcards.manage/admin`. Ajettu tuotantoon. Johku-korttien tuonti on erillinen datasidonnainen vaihe (purku `…_43_import_ROLLBACK.sql`; skriptit `docs/giftcards/`). |
| 44 | `…20261017120522_booking_44_giftcards_rpc.sql` | Lahjakortit, RPC:t (sopimus §13.2–13.3): `public_gift_card_packages`, `public_buy_gift_card`, `public_check_gift_card`, `public_apply_gift_card`, `public_get_order_gift_cards`, `public_get_gift_card`; `admin_list_gift_card_packages`, `admin_update_gift_card_package`, `admin_list_gift_cards`, `admin_get_gift_card`, `admin_create_gift_card`, `admin_set_gift_card_expiry`, `admin_adjust_gift_card`, `admin_deactivate_gift_card`, `admin_reactivate_gift_card`, `admin_redeem_gift_card`; laajennetut `admin_refund`, `admin_list_payments`, raportti (`statistics.gift_cards`) ja `_acct_excluded`; tunneittainen vanhenemisajo (pg_cron, vartioitu). Ajettu tuotantoon. |
| 45 | `…20261017134127_booking_45_giftcards_pdf_email.sql` | Lahjakortit, vaihe 2 (sopimus §13.9): `svc_get_gift_card_pdf_data(uuid)` (service_role; PDF:n tiedot), `public_get_gift_card` palauttaa nyt myös `redeemable_now` ja `package.is_open`, `public_gift_card_packages().items[].label_en`, sähköpostitapahtumat `gift_card_buyer` / `gift_card_recipient` (`email_outbox.kind`, `_gc_activate_order`, `email_outbox_claim`). Rollback: `rollbacks/20261017134127_booking_45_ROLLBACK.sql`. md5 = tuotanto (`schema_migrations.statements`). |
| 46 | `…20261017152725_booking_46_giftcards_delivery.sql` | Lahjakortin toimitusvalinta (sopimus §13.11): `gift_cards.delivery_to` (`buyer`/`recipient`), `cover_message` (saateteksti, ei PDF:ssä), `deliver_on`/`deliver_time` (ajastus, Helsingin aika), `delivered_at`; uudet parametrit `p_delivery_to`, `p_cover_message`, `p_deliver_on`, `p_deliver_time` funktioissa `public_buy_gift_card` / `admin_create_gift_card` (myös `p_items[]`-riveillä), virhekoodit `invalid_delivery_to`, `recipient_email_required`, `invalid_cover_message`, `invalid_deliver_on`, `invalid_deliver_time`, `deliver_on_past`, `deliver_on_too_far`; `email_outbox_claim`/`email_outbox_mark`, `_gc_card_json`, `public_get_order_gift_cards` palauttavat toimituskentät. Rollback: `rollbacks/20261017152725_booking_46_ROLLBACK.sql`. md5 = tuotanto. |
| 49 | `…20261017172554_booking_49_mobilepay_epayment.sql` | Vipps MobilePay ePayment -integraation tietokantaosa (sopimus §14): `integration_config` avain `mobilepay` (tilat off/test/live; päälle vaatii `settings.approved_by`; oletus **off**), adapteri-RPC:t `mobilepay_payment_prepare/_event/_lookup/_confirmable/_fail/_fill_customer`, `mobilepay_refund_claim/_complete/_fail`, `mobilepay_order_refs` (vain service_role), anon `public_payment_options(p_token)`. Edge: `mobilepay-start`, `mobilepay-notify`, `mobilepay-refund`. Rollback: `rollbacks/20261017172554_booking_49_ROLLBACK.sql`. Testit: `tests/mobilepay/t49_mobilepay.sql`. |


> **Migraatiot 12 ja 13 on ajettu tuotantoon** (Bottiavustus ajoi ne 16.10.2026). Tiedostot ovat `supabase/migrations/`-kansiossa versionimillä `20261016202540_booking_12_johku_marker.sql` ja `20261016202553_booking_13_audit_skip.sql` (sama SQL kuin ajettu), jotta paikallinen `run.sh`/`setup-db.sh` vastaa tuotantoa.
> * **12 `johku_marker`:** `orders.external_meta`, `reservations.external_meta` (jsonb; maksutiedot vain henkilökunnalle, ei anonille), indeksi `reservations_source_idx`; `admin_day_view` palauttaa jokaisessa `reservations`-objektissa `source` (`'johku'` | `'native'`) ja `external_id`; `admin_list_reservations(…, p_source text default null)` (8 parametria; `null` = kaikki) + sarakkeet `source`, `external_id` vanhojen perään. Vanhat kutsut toimivat.
> * **13 `audit_skip`:** `audit_trg` ohittaa kirjauksen, kun `booking.skip_audit='on'` ja JWT-rooli on tyhjä/`service_role` (massatuonti).
> * **Hallinta (Tuotteet):** tuotelistan suodatinpalkki: **Näkyvyys** (Kaikki / Verkossa / Ei verkossa) ja **Kategoria** (Kaikki kategoriat / yksittäiset kategoriat, lukumäärät suluissa; kapealla näytöllä pudotusvalikko) sekä nimihaku. "Verkossa" = sama ehto kuin `public_catalog`issa: `product_config.bookable` ja `shop_visible` ja `lifecycle = 'current'` (puuttuva `product_config` = ei verkossa); tuoterivin merkki käyttää samaa ehtoa. Suodatus tehdään clientissä jo ladatusta `admin_list_products`-listasta (ei uusia RPC-kutsuja), tulosrivi "7 / 12 tuotetta", "Tyhjennä suodattimet", tyhjän tuloksen viesti; valinnat säilyvät URL:ssa (`#/tuotteet?nakyvyys=ei-verkossa&kategoria=treatment&haku=…`). Testit: `scripts/e2e-screenshots.mjs` (tuotesuodatin-osio: lukumäärät, yhdistelmät, URL, nuolinäppäimet, 44 px, kontrasti, ei vaakavieritystä 360/390/430/1280), `scripts/smoke-pages.mjs`.
> * **Hallinta (Varaukset / Päivä / varauksen tiedot):** "Johku"-tunniste (teksti, hiekka + tummanvihreä; näytetään vain kun `source = 'johku'`, puuttuva kenttä = ei tunnistetta), varauksen tiedoissa **Johku-tunnus** (`external_id`). Varauslistan suodatin **Kaikki / Uudet / Johku** välittyy `p_source`-parametriin (`Uudet` = `'native'`, `Johku` = `'johku'`, `Kaikki` = parametria ei lähetetä). Testit: `supabase/tests/12_johku_marker.test.sql` (ohittuu, jos migraatiota 12 ei ole testikannassa), `scripts/e2e-screenshots.mjs` (Johku-osio), `scripts/smoke-pages.mjs`.

Migraatiot **eivät muuta `kb`-skeemaa** (vain viittaavat siihen FK:lla ja funktiot kirjoittavat `kb.products`, `kb.product_price_variants`, `kb.change_log`). Roolit: ei uusia tietokantaroolia; käytetään Supabasen `anon`, `authenticated`, `service_role`.

Migraatioiden jälkeen (käsin, järjestyksessä):
1. `supabase/manual/01_expose_schema.md` – lisää `booking` Exposed schemas -listalle.
2. `supabase/manual/02_first_admin.sql` – luo Joonakselle käyttäjä Authissa ja aja YKSI lohko (admin, Joonas.vaarala@gmail.com); muut roolit on kommentoitu. Muut käyttäjät kutsutaan hallinnan Käyttäjät-näkymästä.
3. Edge Function `admin-users`: salaisuudet + deploy, ks. [Edge Function](#edge-function-admin-users) ja [docs/bottiavustus-pyynto.md](docs/bottiavustus-pyynto.md).
4. `supabase/manual/03_verify.sql` – tarkistukset.
5. Rakenna kauppa ja hallinta (alla) ja julkaise.

### Kauppa

```bash
BOOKING_SUPABASE_URL=https://<ref>.supabase.co \
BOOKING_ANON_KEY=<anon/publishable-avain> \
SITE_URL=https://<julkinen-osoite> \
node booking/shop/build.mjs        # → booking/shop/dist/  (koko sivusto + varauskauppa)
```

Kauppa on sivuston kopio: `scripts/build.mjs` ajetaan erilliseen hakemistoon ja Johku-linkit (`*.johku.com/<kieli>/<kategoria>/<tuote>`) korvataan sisäisillä (`/varaa/#/tuote/<slug>`). Lahjakortti-, yritys- ja info-linkit jäävät toistaiseksi Johkuun (ei vielä toteutettu). Perussivuston tiedostoihin ei kosketa; `booking/shop/dist` on `.gitignore`ssa (`dist/`).
Ajonaikainen konfiguraatio on tiedostossa `dist/booking/config.js` (voi vaihtaa ilman uudelleenrakennusta).

#### Kaksi tapaa selata: kategorioittain ja päivän mukaan

Kaupan etusivulla (`/varaa/`, `/en/book/`) on valinta **Selaa kategorioittain** (oletus; tuote → päivä → vuoro, reitit `#/` ja `#/tuote/<slug>/<pvm>` ennallaan) ja **Selaa päivän mukaan** (reitti `#/paiva/<YYYY-MM-DD>`, linkitettävissä):
* Viikkoliuska (ma–su, merkkinä vapaa / täynnä / ei varattavissa, nuolet viikon vaihtoon), "Tänään"-painike ja päivävalitsin (`<input type=date>`) kuukausien välillä liikkumiseen. Menneet päivät ja varausikkunan (`booking_horizon_days`) jälkeiset päivät eivät ole valittavissa.
* **Tuotteet ensin, ajat vasta valinnan jälkeen:** valitulle päivälle näytetään ensin vain ne tuotteet, joilla on vähintään yksi varattavissa oleva vuoro (ryhmittelynä Yleiset vuorot / Yksityisvuorot / Muut): nimi, lyhyt kuvaus, hinta (alk. tai € / hlö) ja tiivistelmä ("N aikaa vapaana · ensimmäinen klo hh"). Täynnä olevat ja ei varattavissa olevat tuotteet jätetään pois. Ajat (alkamis- ja päättymisaika, vapaita paikkoja / Täynnä / Ei varattavissa, hinta ja **Valitse**) aukeavat vasta kun tuotekortti avataan.
* **Valinta: accordion (ei erillistä alinäkymää).** Kortti avautuu paikallaan, joten päivävalitsin pysyy näkyvissä ja päivän vaihto on yhden napautuksen päässä; erillinen alinäkymä veisi sivun alkuun ja vaatisi ylimääräisen Takaisin-askeleen mobiilissa. Saavutettavuus: kortin otsikko on `<button aria-expanded aria-controls>`, paneeli `role=region aria-labelledby`, Enter/väli avaa ja sulkee. Kaikki kortit ovat oletuksena kiinni, yksi auki kerrallaan; jos päivällä on vain yksi saatavilla oleva tuote, se on valmiiksi auki.
* **Tila URL:ssa:** `#/paiva/<pvm>?tuote=<slug>` avaa kyseisen kortin. Valitse-linkki (`?via=day`) vie lomakkeelle (`#/varaa/<rule_id>/<pvm>/<tuote-id>?via=day`), ja lomakkeen Takaisin palaa osoitteeseen `#/paiva/<pvm>?tuote=<slug>` eli samaan päivään ja samaan avoimeen korttiin.
* Tyhjä päivä (ei yhtään saatavilla olevaa tuotetta): "Ei vapaita vuoroja valitulle päivälle." + ehdotus seuraavasta päivästä, jolla on vapaita vuoroja (haetaan enintään 3 kuukautta eteenpäin).
* **Haku:** ei SQL-muutoksia. `public_availability(p_product_id, p_from, p_to)` on tuotekohtainen, joten päivänäkymä kutsuu sitä kullekin kaupan tuotteelle rinnakkain koko kuukauden väliltä (1 kutsu / tuote / kuukausi; viikon yli kuukauden rajan 2 kuukautta). Tulokset välimuistitetaan (`state.months`, sama kuin tuotenäkymässä), joten päivän vaihto samassa kuukaudessa ei kutsu palvelinta. Jos tuotteita tulee paljon, kannattaa lisätä migraatio (Bottiavustus), jossa on `public_availability_all(p_from date, p_to date)` (kaikki tuotteet yhdellä kutsulla); frontend vaihtuisi yhteen kutsuun muuttamalla vain `ensureMonths`-funktiota.

#### Tuotekuvat (migraatio 19)

* **Tallennus:** kuva on varauskonfiguraation tieto: `booking.product_config.image_path` (polku bucketissa `product-images`, `products/<tuote-id>-<tunnus>.<jpg|png|webp>`) ja valinnainen `image_alt` (tyhjä = tuotteen nimi). `kb.products`-taulua ei muuteta. `admin_list_products` palauttaa kentät jo `config`-objektissa.
* **Storage:** bucket `product-images` on julkinen (kuvat näkyvät suoraan osoitteesta `<supabase>/storage/v1/object/public/product-images/<polku>`), enintään 2 MB, vain JPEG/PNG/WebP. Kirjoitus (insert/update/delete) vain kirjautuneelle, jolla on oikeus `catalog.edit` (manager + admin) ja vain yllä olevaan polkumuotoon.
* **RPC:** julkinen `public_product_images()` (vain varattavat, kaupassa näkyvät, aktiiviset tuotteet: `product_id`, `slug`, `path`, `alt`) ja hallinnan `admin_set_product_image(tuote, polku, alt)` (null-polku poistaa kuvan; validoi polun, kirjaa `audit_log`iin `ADMIN_SET_IMAGE`). Uusi erillinen funktio, jotta `public_catalog`/`admin_update_product` eivät korvaudu. Jos `public_product_images` puuttuu (migraatio ajamatta), kauppa toimii ilman kuvia.
* **Hallinta (Tuotteet → tuote):** "Tuotekuva": esikatselu, Valitse/Vaihda kuva, alt-teksti, Tallenna kuva, Poista kuva. Selain tarkistaa tyypin (JPEG/PNG/WebP) ja koon (alkuperäinen enintään 15 Mt, vähintään 400×250 px), pienentää kuvan automaattisesti (enintään 1600 px, WebP/JPEG, ≤ 2 MB) ja lataa sen käyttäjän omalla istunnolla Storageen; vanha tiedosto poistetaan vaihdossa. Tuotelistassa pikkukuva. Peruskäyttäjä (staff) ei näe muokkausta.
* **Kauppa:** tuotelistassa (kategoriat) kuvakortti (3:2, `object-fit: cover`, lazy, `width`/`height` + kiinteä kuvasuhde → ei layout-hyppyä; rikkinäinen kuva poistuu); päivänäkymän tuotekortissa pikkukuva (koriste, nimi on tekstinä); **tuotesivulla ja varauslomakkeella sivun hero-banneri käyttää tuotteen kuvaa taustana** (kuvaton tuote: oletushero), h1 = tuotteen nimi ja sen alla tiivis kuvaus (ensimmäinen virke, enintään ~130 merkkiä; pitkä kuvaus pysyy sisältöosassa). Vahvempi peittokerros takaa tekstin kontrastin (mitattu huonoin kohta ≥ 4,5:1, e2e).
* **Demo:** `dev/seed_demo.sql` asettaa kuvat neljälle tuotteelle (tiedostot `dev/demo-images/`), dev-palvelin mockaa Storagen (`/storage/v1/object/…`, samat säännöt kuin migraatiossa).

### Hallinta

Staattinen: kopioi `admin/` + `shared/sb.js` palvelimelle (esim. `/hallinta/`; älä linkitä julkisesta sivustosta, `noindex` on päällä):

```bash
mkdir -p out/hallinta && cp -r booking/admin/* out/hallinta/ && cp booking/shared/sb.js out/hallinta/sb.js
cp out/hallinta/config.example.js out/hallinta/config.js   # täytä url + anonKey
```

Kaupan ja hallinnan saa yhdellä komennolla samaan julkaisuun: `node scripts/build-pages.mjs` (ks. [Testiversion julkaisu](../README.md#testiversion-julkaisu-github-pages) juuri-READMEssä). Skripti generoi `hallinta/config.js`:n rakennusajan ympäristömuuttujista.

### Resurssivaraukset hallinnassa (migraatio 17)

Migraatio 17 (17a–17d) on ajettu tuotantoon (versiot 20261016213905 / 213924 / 213953 / 214007; tiedostot tavutarkasti samat kuin ajetut). Hallinta (`admin/`):

* **Uusi varaus → Varaustyyppi** (radiogroup, tallentuu osoitteeseen `#/uusi?tyyppi=…`): *Vuoro* (entinen lomake), *Resurssivaraus* (`admin_create_resource_booking`: hoito, saunotus, rituaali, seremonia, lisäpalvelu; nykyiset tuotteet) ja *Vanha varaus* (`admin_create_old_booking`; vain `lifecycle = 'old'` -tuotteet). Lomake: tuote, päivä, alku (loppu valinnainen), henkilömäärä, tila (Automaattinen / Rauni / Lovi tuotteen `product_space_rules`-sääntöjen mukaan), asiakas, maksu, lisäpalvelut, vanhempi varaus (lisäpalvelulle; automaattinen haku).
* **Ylitys** (sulku- ja saunottajatarkistuksen ohitus, `p_override` + pakollinen `p_override_reason`) näkyy lomakkeella vain käyttäjälle, jolla on oikeus `bookings.override` (admin, manager). Oikeus tarkistetaan silti tietokannassa.
* **Päivänäkymä, Varaukset-lista ja varauksen tiedot** näyttävät hillitysti tilan (Rauni/Lovi), *Vanha tuote* -merkin, ylityksen, kiintiövapauden, tilan käyttöikkunan (`claim_offset_min`/`claim_minutes`), vanhemman varauksen ja legit (saunottaja + taito, tila). Kaikki kentät ovat valinnaisia (vanha palvelin ilman kenttiä ei riko näkymiä). Päivänäkymä näyttää vain aktiiviset varaukset; Johku-historia näkyy vain varauslistassa (`admin_list_reservations`).
* **Rauni ↔ Lovi -siirto** varauksen tiedoissa (`admin_move_reservation_space`, syy valinnainen). Lovi on vain 1 henkilölle, joten usean hengen varausta ei tarjota siirrettäväksi Loviin.
* **Tarkista** (valikko ja pikapainike Varaukset-sivulla; `admin_review_list`, vain luku): saunottajakonfliktit, sulkukonfliktit, ylitykset (syyn kanssa) ja orvot lisäpalvelut. Laskuri pikapainikkeessa.
* **Virheilmoitukset suomeksi**: BK001-koodit (`space_busy`, `no_therapist`, `therapist_closed`, `parent_required`, `override_reason_required`, `wrong_lifecycle`, `space_not_allowed`, `no_space`, `no_pool_for_start`, `no_primary_leg`, `bad_rule`, `skill_unknown`, `not_resourced` sekä vanhat `capacity_exceeded`, `space_closed`, `private_booked`, `public_shift_booked`, `bad_pool`, `has_reservations`, `forbidden`) kartoitetaan `admin/ui.js`:n `ERR_FI`-taulukolla; tuntematon koodi näyttää palvelimen viestin.
* Testit: pgTAP `17_resource_bookings` (75 testiä: skeema, validaattorit, ylitys + oikeus, siirto, katselmointi, vanhat polut), selainsavutesti `scripts/smoke-pages.mjs` (Tarkista, varaustyyppi, BK001 suomeksi, ylitys vain oikeudella) ja `scripts/e2e-screenshots.mjs` (resurssi-osio, 360/390/430/1280, ei vaakavieritystä).

### Saunottaja puuttuu ja aikaikkunat hallinnassa (migraatiot 20–23)

Migraatiot 20–23 on ajettu tuotantoon (versiot 20261016224525 / 233600 / 234502 / 234534; tiedostot tavutarkasti samat). Migraatio 19 (tuotekuvat) on ajettu tuotantoon versiolla `20261016222439` (tiedosto tavutarkasti sama kuin tuotannossa: ilman `begin;`/`commit;`-käärettä, koska migraatioajuri ajaa jokaisen migraation omassa transaktiossaan); versio on 18c:n (`20261016221840`) ja 20:n (`20261016224525`) välissä, joten paikallinen ajojärjestys on sama kuin tuotannossa (… 18c, 19, 20, 21 …). Hallinta (`admin/`):

* **Ei saunottajaa** -tunniste (hillitty hiekka/meripihka, ei sinistä) päivänäkymän resurssivarauksissa ja varauksen tiedoissa (`therapist_missing`, avoin = `therapist_missing_open`). Poikkeuksen myöntämisen jälkeen tunniste muuttuu *Poikkeus myönnetty* -merkiksi ja tiedoissa näkyy perustelu.
* **Tarkista**: uusi ensimmäinen osio *Ei saunottajaa* (`admin_review_list.missing_therapist`): varaus, tuote, henkilömäärä, tilaus, lähde ja päiviä alkuun.
* **Myönnä poikkeus** (`admin_grant_therapist_exception(p_reservation_id, p_note)`): painike näkyy vain oikeudella `bookings.override` (admin, manager); perustelu (≥ 3 merkkiä) on pakollinen (`note_required`). Idempotentti.
* **Luonnin varoitus**: kun `admin_create_resource_booking` / `admin_create_old_booking` palauttaa `warning: 'therapist_missing'`, näytetään huomiolaatikko *Varaus tehty, mutta saunottaja puuttuu työvuorosta* (+ ilmoitus ja linkki Tarkistaan) ennen varauksen vahvistusta.
* **Virheilmoitukset suomeksi**: `time_window`, `ritual_start`, `note_required`, `not_missing`, `therapist_present`. Resurssivarauslomake näyttää tuotteen aikaikkunavihjeen (`time_window_class`); ylitysvalinta ohittaa myös aikaikkunan.
* Huom: `admin_list_reservations` ei palauta `therapist_missing`-kenttää (speksin mukaan), joten Varaukset-listassa ei ole tunnistetta; se näkyy päivänäkymässä, tiedoissa ja Tarkistassa. Aikaikkunasääntöjen muokkaukseen ei ole hallintanäkymää.
* Testit: pgTAP `17_resource_bookings` laajennettu Bottiavustuksen v2-testeillä (ryhmät A–N ajetaan aikaikkunatriggeri pois päältä, kuten tuotannossa; uudet ryhmät W ja X testaavat aikaikkunat ja rituaalin alkuajat sekä poikkeukset), selainsavutesti ja e2e (kuvat `admin-*-90…95`).

### Vapaat ajat hallinnan Uusi varaus -lomakkeella (booking_25, `admin_treatment_availability`)

Resurssivaraus-lomakkeella tuotteet kb 8 (rituaali) ja 10–12 (hoidot) näyttävät **Vapaat ajat** -paneelin, joka kutsuu `admin_treatment_availability(p_product_id, p_from, p_to, p_persons, p_override, p_override_reason)` ja näyttää saman tarjonnan kuin verkkosivu (`admin/views/availability.js`):

* Haku 14 päivää valitusta päivästä (`SPAN_DAYS`), päiväpainikkeet (lukumäärä) ja alkuajat (44 px painikkeet). Aika valittaessa lomakkeen päivä ja kellonaika täyttyvät; yhteenvedossa hinta (`total`) ja merkinnät **Ei saunottajaa** (`therapist_missing`, sama kuin booking_22-varoitus) ja **Vaatii ylityksen** (`needs_override`).
* Raskas haku: **ei pollausta**; haetaan kun tuote, päivä, henkilömäärä (400 ms viive) tai ylitys vaihtuu. Välimuisti muistissa 3 min / haun parametrit; *Päivitä*-painike ohittaa välimuistin.
* Ylitysajat vain oikeudella `bookings.override` (admin, manager): Ylitys-valinta + perustelu (≥ 3 merkkiä) → haku `p_override=true`. Ilman perustelua haetaan vain tavalliset ajat. Perustason käyttäjä (`bookings.manage`) ei näe ylitysvalintaa.
* Varaus tehdään edelleen lomakkeen `admin_create_resource_booking`-kutsulla; ajan voi syöttää käsin myös silloin, kun saatavuushaku epäonnistuu (virhe suomeksi: `bad_range`, `busy`, `rate_limited`, `forbidden`, `override_reason_required`).
* Tuotteet, joilla paneeli näytetään: `SLOT_PRODUCT_IDS = [8, 10, 11, 12]` (`availability.js`). Vanha varaus -lomake ei käytä paneelia.
* Testit: `scripts/smoke-pages.mjs` (mockattu RPC: argumentit, valinta, välimuisti, virhe, ylitys + oikeus) ja `scripts/e2e-screenshots.mjs` (kuvat `admin-*-96…98`; RPC mockattu, koska migraatioita 24–25 ei ole vielä repossa/paikallisessa kannassa).

### Päivänäkymä ja lisäpalvelut (v25)

* **Työvuorot päivän alla** (`views/dayparts.js` → `shiftsBar`): `admin_upcoming_shifts` (vain luku; `shifts.view_all` = kaikki, `shifts.view` = vain omat; data `public.work_shifts` / `shift_assignments` / `staff`) rooleittain suomeksi ja kalenterin väreillä (Lämmitykset ruskehtava, Saunottaja vihreä, Vastaanotto vaimea kulta, ei sinistä): *Saunottaja 14–20 Maija*; ei nimettyä → "ei nimettyä tekijää". Ei oikeutta tai tietoa → palkkia ei näytetä (varaukset näkyvät silti). Uutta RPC:tä ei tarvittu.
* **Vuoron otsikkorivi**: oikeassa reunassa henkilömäärä (*4 hlö*) ja kapasiteettinappi: vihreä *Vapaana: N* / *Vapaa* on linkki Uusi varaus -lomakkeelle (`#/uusi?d=…&r=<rule_id>&t=<alkamisaika>`; vuoro esivalittuna, lomake vierittyy näkyviin ja fokus otsikkoon kuten v22:ssa), punainen *Täynnä* / *Varattu* ei ole painike. Nappi ≥ 44 px.
* **Myymätön vuoro**: tyhjä vuoro, joka ei ole myynnissä (päällekkäisyys, sulku, myynti päättynyt), piilotetaan (`admin_day_view.sessions[].status`: näytetään vain `available` ja `full`); jos vuorolla on varauksia, se näytetään ilman "ei myynnissä" -tekstiä ja ilman nappia. Tietoa ei puuttunut RPC:stä.
* **Saapunut-nappi** jokaisella varausrivillä (oikeus `bookings.manage`): vihreä ympyrä, painettuna täytetty ✓ (`aria-pressed`, `aria-label` "Saapunut: nimi"); optimistinen päivitys, virheessä palautus + ilmoitus. Käyttää olemassa olevaa `admin_set_reservation_status(…, 'completed')` (asettaa `checkin_at`); uudelleen painaminen palauttaa tilaan `confirmed`. Uutta RPC:tä ei tarvittu.
* **Lisäpalveluikonit** varausriveillä (`icons.js`: `whisk` saunavihta, `mask` turvenaamio, `towel` pyyhe; yksivärinen viiva kuten valikon ikonit, `title`). Tunnistus `addon.code` tai nimestä (`admin_day_view` antaa vain `addon_id`, `name`, `quantity`; koodi olisi varmempi, ks. pyyntö).
* **Lisäpalvelut ja resurssivaraus**: Pyyhe 5 € tarjotaan myös hoidoissa ja saunotuksissa; saunavihta, turvenaamio ja jalkakylpy vain yleisillä vuoroilla ja yksityisvarauksessa. Frontti: lisäpalveluvalitsin resurssi- ja vanha varaus -lomakkeilla käyttää tilaa `resource` (`applies_modes` sisältää `resource`), kauppa suodattaa kuten ennen `applies_modes.includes(vuoron tila)`; ylläpitolomakkeella uusi valinta *Hoito / saunotus*. **Vaatii tietokantamuutoksen** (uusi tila + Pyyhe-rivi + palvelinpuolen rajaus + `public_create_treatment_booking`-lisäpalvelut): `docs/bottiavustus-pyynto-pyyhe.md`. Ennen sitä pyyhettä ei ole ja hoitolomakkeen lisäpalvelualue on piilossa.
* Testit: `scripts/smoke-pages.mjs` (mockattu päivänäkymä: työvuorot, piilotettu myymätön vuoro, näkyvä myymätön vuoro ilman tekstiä, napit, saapunut + virhepalautus, esivalinta, ikonit, lisäpalvelut lomakkeittain) ja `scripts/e2e-screenshots.mjs` (kuvat `admin-*-100…103`).

### Päivänäkymän korjauskierros (t66u/t67u)

* **Etusivu = päivänäkymä** heti kirjautumisen jälkeen (`#/`): päivämäärä, työvuorot, päiväsiirtymä, **Valmistelu-kortti**, vuorot aikajärjestyksessä yhdessä sarakkeessa (390 ja 1280 px), Sulut.
* **Valmistelu** (`dayparts.js` → `prepCard`): oma, hillitty hiekanvihreä kortti listan yläpuolella: isot luvut + ikonit (henkilöä, saunavihta, turvenaamio + jalkakylpy, pyyhe; `admin_day_view.addon_totals`) ja alla aloitusajoittain `prep`-rivit. Vuorojen sisällä ei enää "Valmistele"-huomautuksia (ei sekoitu varausriveihin).
* **Aikajärjestys ja aloitusajat**: vuorokortit ja muut aktiiviset varaukset (hoito, saunotus, rituaali, tapahtuma: ei vuorosääntöä) samassa aikajärjestyksessä; hoitovaraukset ryhmitellään aloitusajan ja tuotteen mukaan omaan korttiinsa (*13:30–14:30 Saunahoito · 2 hlö*). Peruutetut ja päättyneet varaukset omassa suljetussa osiossaan "Peruutetut ja päättyneet varaukset (N)" (ei enää "Muut varaukset" -sekamelskaa).
* **Työvuorot kaikille** (`shiftsBar`): ensisijaisesti `admin_day_shifts(p_date)` (ei vaadi `shifts.*`-oikeutta, palauttaa vain roolin, ajan ja nimen; **vaatii migraation 26**, ks. `supabase/migrations/20261017072446_booking_27_pyyhe_resource_addons.sql` (MUUTOS 6)). Ilman sitä käytetään `admin_upcoming_shifts`: `shifts.view_all` (admin, manager) = kaikki, `shifts.view` (staff) = vain omat + huomautus "Näytetään vain omat vuorosi", ei kumpaakaan oikeutta = selite "Työvuorot eivät näy tällä tunnuksella". Palkki ei katoa hiljaa. Funktion puuttuminen näkyy selaimessa yhtenä 404-konsoliviestinä.
* **Lisäpalveluikonit**: tunnistus 1) `code` (jos `admin_day_view` antaa), 2) `addon_id` → `admin_list_addons().code`, 3) nimi. Ikonit: saunavihta `whisk`, turvenaamio `mask`, jalkakylpy `foot`, pyyhe `towel`; yhdistetty "Turvenaamio ja jalkakylpy" saa naamion ja jalkakylvyn.
* **Pyyhe ja tapahtumat**: resurssivarauslomakkeella tapahtumatuote (kategoria `event`) = tila `event`: ei lisäpalveluita lainkaan (pyyhekään ei). Palvelinpuolen rajaus + Pyyhe-rivi + `resource`-tila: migraatio booking_27 + pgTAP `27_pyyhe_resource_addons.test.sql`.
* Testit: `scripts/smoke-pages.mjs` (Valmistelu, aikajärjestys, hoitokortti, peruutetut, työvuoropolut, ikonit) ja **`scripts/e2e-hallinta-etusivu.mjs`** (oikea demokanta, ei mockeja: admin/manager/staff-kirjautuminen, etusivu, *Vapaana: N* → esivalittu Uusi varaus → varaus lisäpalveluineen luodaan kantaan → näkyy vuoron alla, hlö/kapasiteetti päivittyvät, ikonit, Valmistelu, saapunut säilyy latauksen yli, hoito-/tapahtumalomakkeen lisäpalvelut; `EXPECT_DAY_SHIFTS=0 EXPECT_TOWEL=0` jos migraatiota 27 ei ole ajettu kantaan; oletus: demokanta sisältää sen).

### Talous (hallinta › Talous + asiakkaan tilaussivu; mock + live-testattu testiprojektilla)

* **Hallinta › Talous** (`#/talous`, oikeus `payments.manage`): välilehdet **Tilaukset** (haku, lajittelu, suodattimet, palvelinpuolinen sivutus 25/50/100, rivin laajennus: maksut + **kuitit maksujen alla** (numero, päivä, summa; Lataa PDF / Näytä kuitti (kopioitava teksti) / Lähetä uudelleen) + varaukset; napit Lisää tilaukseen / Luo maksulinkki / Kirjaa maksu / Hyvitä), **Maksut** (aikajärjestys, haku, kuittinumero + PDF-lataus joka rivillä, rivin laajennus: laskurivit ja kuitit), **Raportit** (päivä/kuukausi, ALV-kannoittain, maksutavoittain, CSV, PDF palvelimelta `report-pdf` + selaimen tulostus). FI/EN.
* **Datakerros** `admin/talous-api.js` (ainoa paikka joka tuntee RPC-nimet ja parametrit; sopimus `KOODARI_talous_A_D_fi.md`). Mock = `admin/talous-mock.js` samalla `rpc(nimi, parametrit)`-rajapinnalla. `?mock=1` → mock; Raportit: päivä = reports.daily|reports.view, kuukausi+CSV = reports.view; puuttuva lukeva RPC → vain kyseinen toiminto mockiin + banneri; kirjoittavat toiminnot (lisäys, maksulinkki, maksun kirjaus, hyvitys, kuitin uudelleenlähetys) eivät koskaan putoa mockiin eikä niillä ole erillisiä käyttöönottolippuja. Kuitti-PDF: `<SUPABASE_URL>/functions/v1/receipt-pdf?t=<public_token>` (`sb.js` `functionUrl`; ei palvelimen `pdf_url`-kenttä). Katso `docs/talous-kehys-api-oletukset.md`.
* **Asiakkaan tilaussivu** `/tilaus/?t=<token>` (EN `/en/order/`; = `settings.order_page_path`; tilauksen kieli ohjaa oikealle sivulle): rivit, varaukset, maksutila, kuitit, lisäpalvelun lisäys, peruutuspyyntö. Ei automaattista mockia asiakkaalle (puuttuva RPC → "ei vielä käytössä"); noindex, `referrer=no-referrer`.
* **Johku ei kirjanpitoon** (migraatio 41, sopimus §12): Raportit-välilehdellä erillinen lohko *Johku (ei kirjanpitoon)* (`statistics.johku`, ei totals-lukuihin, ei PDF/CSV/tulosteeseen); Maksut-listassa Johku-merkki ja ex_johku-summarivi (+ Johku-rivien määrä). Migraatiot 37–41 (+ rollbackit `supabase/rollbacks/`) ovat repossa tuotannon versionumeroilla; 37–40 ovat tuotantodataan sidottuja (kiinteät id:t), joten ne eivät aja tyhjällä kannalla – testiprojektiin ajettiin vain niiden skeema-/funktio-osat (37: sarakkeet, 38: funktiot) ja 41 kokonaan.
* Testit: `node --test booking/tests/talous.test.mjs` (CSV, mock-palvelin, datakerros, tekstit FI/EN, tilaussivu); e2e: `SHOP_DIST=/tmp/shop-dist-talous node booking/shop/build.mjs && PW_DIR=<playwright-core:n kansio> node booking/scripts/e2e-talous.mjs` (Playwright + google-chrome; 360/390/430/1280, FI/EN, kuvat `SHOT_DIR`); `scripts/smoke-pages.mjs` lohko 7. **Live-e2e testiprojektia vasten**: `PW_DIR=… node booking/scripts/e2e-talous-live.mjs` (osoite/avaimet tiedostosta `LIVE_ENV`, ei tuotantoa; ks. `docs/talous-kehys-api-oletukset.md`). CSV = palvelimen `admin_report_csv` (12 saraketta). Kuittilogo `public/img/logo-kuitti.png`.

### Lahjakortit – hallinta (migraatiot 43–46, sopimus §13)

* **Talous › Lahjakortit** (`admin/views/talous-giftcards.js`, datakerros `admin/giftcards-api.js`, mock `admin/giftcards-mock.js`, tekstit `admin/giftcards-texts.js` FI/EN). Näkyy oikeudella `giftcards.manage` (staff, manager, admin); Talous-nav aukeaa myös pelkällä `giftcards.manage`:lla (silloin vain Lahjakortit-välilehti).
* **Lista:** haku (koodin osa, ostajan/saajan nimi tai sähköposti, tilausnumero), suodattimet (tila, lähde Oma/Johku, paketti, saldo, vanhenee pian, saldo varmistamatta), lajittelu, sivutus (`admin_list_gift_cards`). Rivi aukeaa kortin tiedoiksi (`admin_get_gift_card`): tiedot, **tapahtumahistoria** (ledger), voimassaolon muutosloki, lunastusmaksut (linkki tilaukseen). Mobiilissa rivit ovat korttimaisia, ei vaakavieritystä.
* **Toiminnot:** uusi kortti (`admin_create_gift_card`: *maksuton myöntö* syyn kanssa tai *myynti* maksutavalla; maksutavalla myynti vaatii `payments.manage`), voimassaolon muutos (`giftcards.manage`), saldokorjaus / mitätöinti / uudelleenaktivointi (`giftcards.admin`, painikkeet pois käytöstä ilman oikeutta; maksamatonta ostoa ei voi aktivoida). Luodun kortin koodi näytetään heti ja kortin tiedoissa.
* **Lisää maksu → Lahjakortti:** tilauksen maksulomakkeessa maksutapa *Lahjakortti* kutsuu `admin_redeem_gift_card` (koodi `hhxx-xxxx-xxxx` / ilman viivoja, "Hae kortti" näyttää saldon ja voimassaolon, summa tyhjänä = pienempi kortin saldosta ja maksamattomasta, osittainen lunastus sallittu). `admin_record_payment` ei koskaan saa `gift_card`-tapaa (palvelin hylkää: `gift_card_required`). Vaatii `payments.manage`. Kun `accounted:false` (ALV kirjattu jo myynnissä/Johkussa), ilmoitus kertoo ettei uutta kuittia synny.
* **Avaa PDF** (kortin tiedoissa): linkki `gift-card-pdf?t=<card.public_token>&lang=<hallinnan kieli>` uuteen välilehteen (`createGiftApi({ rpc, io: { functionUrl } }).pdfUrl`, sama tapa kuin `receiptPdfUrl`); vain jos `public_token` on; `pending_payment`/`cancelled`/`pending_verification` → nappi pois käytöstä (PDF antaisi 409); `balance_verified=false` → varoitus. Sopimus §13.9.
* **Toimitusvalinta (§13.11, migraatio 46):** myynti-/myöntölomakkeella *Lähetä lahjakortti: Ostajalle / Suoraan saajalle* (oletus ostajalle). Saajalle: saajan sähköposti pakollinen (`recipient_email_required` kentän alla), *Lähetä heti / Valitse ajankohta* (päivä min tänään – max `min(12, voimassaolo)` kk, kellonaika valinnainen, ilman klo 9), *Tervehdys lahjakorttiin (näkyy kortissa)* (≤ 300, laskuri) ja *Saateteksti sähköpostiin (ei näy kortissa)* (≤ 1000, laskuri). `admin_create_gift_card` saa `p_delivery_to`, `p_cover_message`, `p_deliver_on`, `p_deliver_time` (`buyer` → vain `p_delivery_to`; `deliver_time` vain päivän kanssa). Palvelimen BK001-virhekoodit (`detail` = koodi) näytetään kentän alla; tarkistus = `admin/giftcards-delivery.js` (kopio kaupan `gift-logic.js`:n toimitusosasta, yhtäpitävyys testataan). Kortin tiedoissa: Toimitus, Toimituksen tila (*Toimitettu* `delivered_at` / *Ajastettu* `deliver_on`+`deliver_time` / *Odottaa lähetystä*), Lähetysajankohta, Saateteksti; listassa *Toimitettu*/*Ajastettu*-merkki; *Avaa PDF* säilyy.
* **Kytkimet:** `gift_cards.sale_enabled`, `gift_cards.redeem_enabled`, `gift_cards.johku_cards_redeemable` luetaan `admin_list_gift_card_packages().settings`-vastauksesta ja näytetään Lahjakortit-välilehden yläreunassa (teksti *päällä/pois*). Hallinnan luonti toimii kytkimistä riippumatta (sopimus); lunastus on estetty kun `redeem_enabled=false` (selkeä ilmoitus, lähetys pois käytöstä).
* **Testit:** `booking/tests/giftcards.test.mjs` (yksikkö), `booking/scripts/e2e-giftcards.mjs` (mock-e2e, `ONLY=admin|shop`), `booking/scripts/e2e-giftcards-live.mjs` (testiprojekti `jztczwrqtnpuolhcmktb`, vaatii kytkimet `true` testikannassa ja `LIVE_FROM`-päivän jolta on vapaita vuoroja).

### Lahjakortit – kauppa (lahjakorttisivu, saldotarkistus, lahjakortti maksutapana; sopimus §13.2)

* **Moduulit** (`booking/shop/src/`): `gift.js` (sivu), `gift-logic.js` (puhdas logiikka: koodin normalisointi, tarkistukset, `p_items`), `gift-api.js` (RPC-kerros, puuttuva RPC → "ei käytössä" = ei muutoksia), `gift-texts.js` (FI/EN), `gift-ui.js`, `gift-mock.js` (vain `?mock=1` ja testit), `order-gift.js` (tilaussivun osat). Rakennus (`build.mjs`) kopioi ne `/booking/`-hakemistoon ja lisää `/lahjakortti/`- ja `/en/gift-card/`-sivuille piilotetut `#gift-app`- ja `#gift-balance`-lohkot sekä `gift.js`:n.
* **Näkyvyys kytkimillä** (`public_gift_card_packages()`): `sale_enabled=true` → myyntilohko (5 korttia palvelimen nimillä ja hinnoilla, ostoskori, ostaja, tervehdys ≤ 300 merkkiä laskurilla) **korvaa** staattiset Johku-osiot `#avoin` ja `#paketit` (ankkurit säilyvät myyntilohkossa). `redeem_enabled=true` → saldotarkistus (`public_check_gift_card`) ja tilaussivun "Käytä lahjakortti" (`public_apply_gift_card`). Muuten (tuotannossa nyt molemmat `false`) sivut ovat täsmälleen ennallaan: ei "ei vielä käytössä" -tekstejä, Johku-linkit paikallaan. Puuttuva RPC tai verkkovirhe → sivu ennallaan.
* **Osto:** `public_buy_gift_card(p_items, p_name, p_email, p_phone, p_marketing_consent, p_locale)`; rivikohtainen saaja/tervehdys `p_items`-alkioissa (`recipient_name`, `recipient_email`, `greeting`), avoimella `amount` (29–500 €, ≤ 2 desimaalia), enintään 10 korttia / 10 riviä. Palvelimen virhekoodit näytetään FI/EN-teksteinä (`err.*`). Onnistuessa: kuittaus, tilausnumero, linkki tilaussivulle (`orders.public_token`). **Maksu:** `payment_mode` on nyt `pay_later` ja `payment_url` null → teksti "maksu paikan päällä / laskulla"; kun `payment_url` tulee, näytetään "Siirry maksamaan" -painike.
* **Toimitusvalinta (§13.11, migraatio 46):** jokaisella korttirivillä *Lähetä lahjakortti: Minulle / Suoraan saajalle* (oletus minulle → `delivery_to:'buyer'`, saajan sähköposti/saate/ajankohta eivät lähde palvelimelle). Saajalle: saajan nimi + sähköposti pakollisia (nimi vain asiakaspuolella; palvelin vaatii sähköpostin), *Lähetä heti / Valitse ajankohta* (oletus heti; päivä min tänään – max `min(12, voimassaolo)` = 6 kk, kellonaika valinnainen = klo 9; `deliver_on`/`deliver_time` vain kun ajankohta valittu), *Tervehdys lahjakorttiin (näkyy kortissa)* (`greeting` ≤ 300) ja *Saateteksti sähköpostiin (ei näy kortissa)* (`cover_message` ≤ 1000), kummallakin oma laskuri. Valinnat menevät `p_items[]`-alkioihin (rivikohtainen ohitus, §13.11). Asiakaspuolen tarkistus (`gift-logic.js: resolveDelivery`) peilaa palvelimen `_gc_delivery_resolve`:a; kaikki virhekoodit (`deliver_on_past`, `deliver_on_too_far`, `invalid_cover_message`, `invalid_greeting`, `invalid_deliver_on`, `invalid_deliver_time`, `invalid_email`, `recipient_email_required`) näytetään FI/EN kenttäkohtaisesti, myös palvelimelta tulleina (palvelin ei kerro riviä → virhe niille riveille, joita se koskee). Vahvistus kertoo valinnan ("Lahjakortti lähetetään saajalle 24.12.2026 klo 18:30" / "toimitetaan sinulle"); tilaussivulla saajalle menevän kortin koodia ja PDF-linkkiä **ei näytetä** (yllätys säilyy), ostajalle menevällä Näytä koodi + PDF kuten ennen.
* **Koodi:** syöte käy pienillä kirjaimilla, viivoilla ja välilyönneillä (`hh4a bcde-fghj`); kenttä muotoilee `HH4A-BCDE-FGHJ`, RPC:lle menee aina normalisoitu 12 merkkiä (`gift-logic.js: normalizeCode`).
* **Tilaussivu** (`/tilaus/?t=…`): "Käytä lahjakortti" vain kun `redeem_enabled`, maksamatonta on eikä tilauksella ole lahjakorttirivejä (lahjakortilla ei osteta lahjakorttia); osittainen lunastus (tyhjä summa = pienempi kortin saldosta ja maksamattomasta); onnistuessa tilaus ladataan uudelleen. "Lahjakortit"-osio (`public_get_order_gift_cards`) vain jos tilauksella on kortteja; koodi näytetään (**Näytä koodi**, `public_get_gift_card`) vasta kun kortti on `ready` (maksettu). **PDF-lataus:** "Lataa PDF" / "Download PDF" (uusi välilehti) kortin koodin avauksen yhteydessä kun kortti on `ready`; linkki `<functions>/gift-card-pdf?t=<public_token>&lang=fi|en` (sivun kieli; edge function `gift-card-pdf` on tuotannossa, sopimus §13.9). `config.js`:n `giftCardPdf` on oletuksena `true`; `BOOKING_GIFT_CARD_PDF=0` rakennusajossa (tai `giftCardPdf: false` julkaistussa `config.js`:ssä) piilottaa napin, merkkijono = toisen funktion nimi. Myyntisivun valmis-paneelissa ei PDF-linkkiä (kortit maksamattomia → 409); PDF tulee sähköpostissa ja tilaussivulta. **Paketin sisältö** (myyntisivun korteissa): `items[].label` (FI) / `items[].label_en` (EN, migraatio 45); jos kyseisen kielen nimiä ei ole, listaa ei näytetä. Tilausmock (`createOrderMock({ locale })`): tilauksen `locale` ohjaa sivun kieleen.
* **Tyyli:** vihreä `.btn` (valkoinen teksti 12:1) – `.btn.gold` ei käy (valkoinen kullalla 3,8:1); kosketuskohteet ≥ 44 px; kentät `aria-describedby` / `aria-invalid`, virheet `role=alert`.
* **Testit:** `booking/tests/gift-shop.test.mjs` (yksikkö), `booking/scripts/e2e-giftcards.mjs` `ONLY=shop` (mock; `SHOP_DIST=/tmp/shop-dist-lahjakortti node booking/shop/build.mjs` ensin), `booking/scripts/e2e-giftcards-live.mjs` (kauppa-osuus testiprojektia vasten, ks. skriptin otsikko). Toimitusvalinta (§13.11): yksikkötestit kaikille kahdeksalle virhekoodille (`gift-shop.test.mjs`, `giftcards.test.mjs`), mock-e2e (kauppa, tilaussivun skenaario `cardsdelivery`, hallinnan lomake) ja live-e2e `ONLY=delivery` (vaatii migraation 46 testiprojektissa; nosta tilapäisesti `gift_cards.rl_buy_per_10min` testiprojektissa).

### Kalenterisulut hallinnassa (migraatio 18)

Migraatio 18 (18a–18c; versiot 20261016221808 / 221825 / 221840) on ajettu tuotantoon; kalenterit ovat rekisterissä `active = false` eikä synkkaa ole käynnissä. Hallinta (`admin/`):

* **Päivänäkymä ja Resurssit → Sulut:** kalenterista tuleva sulku (`closure_event_id` ei null) näkyy merkillä *Kalenterisulku*, vain luettavana (ei Poista-nappia; palvelin estää muutoksen virheellä `closure_managed`, joka näytetään suomeksi). Käsin tehdyt sulut poistetaan kuten ennen. Sulun kohde näkyy merkkinä (esim. Rauni, Laura).
* **+ Lisää sulku:** kohteeksi voi valita tilan tai **Lauran** (koulutus, poissaolo): Koulutus-kalenteritapahtumat eivät sulje mitään, joten koulutus kirjataan käsin Laura-resurssille, joka estää Lauran taitoa vaativat tuotteet.
* **Kalenterisulut** (valikko; oikeus `blocks.manage` = staff, manager, admin; funktiot tarkistavat saman oikeuden, hallinta piilottaa valikon ja estää suoran osoitteen ilman sitä): `admin_closure_overview` → kalenterit (käytössä / ei käytössä, viimeisin synkka ja virhe), *Synkronointi ei ole käynnissä* -ilmoitus kun mikään kalenteri ei ole käytössä, konfliktit (varaukset, jotka osuvat kalenterisulkuun), tulevat tapahtumat (jakso 30 / 60 / 180 / 365 pv; luokka *Sulku* / *Karkea jakso*, *Sulkee* / *Ei sulje*) ja viimeisimmät synkkaajot.
* **Ohitus** (`admin_set_closure_override`): *Ohita* (tapahtuma ei sulje), *Estä* (sulkee, esim. yli 36 h karkea jakso) ja *Palauta automaattinen*, valinnainen muistiinpano. Synkka säilyttää ohituksen; vastaus kertoo lisätyt/päivitetyt/poistetut sulut.
* Demo (`dev/seed_demo.sql`): hoidot ja savusauna on merkitty käyttöön keinotekoisella kalenteritunnuksella, tapahtumia, ohitus, konflikti ylitysvaraukseen, ajoloki ja Lauran käsin tehty sulku; rauni ja perinnesaunotus jäävät käyttämättömiksi.
* Testit: pgTAP `18_closure_calendars` (76 testiä; Bottiavustuksen luonnos + päivänäkymän `closure_event_id`), `scripts/smoke-pages.mjs` (Kalenterisulut-näkymä, ohituskutsut, oikeuspiilotus, `closure_managed` suomeksi) ja `scripts/e2e-screenshots.mjs` (kalenterisulut-osio, 360/390/430/1280).

### Asiakastyypit ja lisäpalvelut (migraatio 11)

* **Asiakastyyppi** valitaan kaupassa (`/varaa/`, `/en/book/`), hallinnan Uusi varaus -lomakkeella ja Asiakkaat → **Lisää asiakas** -ikkunassa: *yksityisasiakas* (nimi, sähköposti, puhelin kuten ennen) tai *yritysasiakas* (yrityksen nimi, **y-tunnus** + tarkistenumero, katuosoite/postinumero/postitoimipaikka, valinnaiset verkkolaskutiedot: verkkolaskuosoite/OVT + operaattorin välittäjätunnus – vain yhdessä –, valinnainen viite/tilausnumero, yhteyshenkilön nimi/puhelin/sähköposti). Validointi on selaimessa ja tietokannassa (sama sääntö); kauppa ja hallinta kutsuvat samoja funktioita (`public_create_booking` / `admin_create_customer` / `admin_create_booking`).
* **Hallinta (Uusi varaus):** vuoron valinta (ja vaihto toiseen vuoroon) vierittää näkymän heti varauslomakkeeseen (`scrollIntoView`, pehmeä vain jos `prefers-reduced-motion` ei estä; sticky-yläpalkki huomioitu `scroll-margin`-arvolla) ja siirtää fokuksen lomakkeen otsikkoon (`Vuoro: …`), ei kenttään → mobiilinäppäimistö ei aukea turhaan; Tab vie Henkilömäärä-kenttään. **Asiakashaku:** Hae-painike / Enter hakee heti; jos osumia ei löydy, näytetään "Ei löytynyt – luo uusi asiakas" ja hakusana esitäytetään: sähköpostiosoite → Sähköposti, puhelinnumero → Puhelin, muu → Nimi (yritysasiakkaalla Yrityksen nimi); jo täytettyä kenttää ei ylikirjoiteta, fokus siirtyy seuraavaan tyhjään kenttään. Enter hakukentässä ei enää lähetä varauslomaketta. Sama jaettu asiakashaku (`customerSearch` + `cf.prefill`, `views/customerform.js`) on myös Resurssivaraus- ja Vanha varaus -lomakkeilla (Varaustyyppi-valitsin). Testit: `e2e-screenshots.mjs` (mobiili 390, desktop, vähennetty liike) ja `smoke-pages.mjs`.
* **Lisäpalvelut** (alussa *Turvenaamio ja jalkakylpy* 15 €, *Saunavihta* 13 €; hinnat sis. ALV 25,5 %): asiakas valitsee määrän (0 … henkilömäärä × `max_per_person`, oletus 1/hlö, max 99) kaupassa tai henkilökunta hallinnassa; hinta lisätään tilauksen summaan ja tilaukselle tulee oma `order_items`-rivi/lisäpalvelu. Päivänäkymä näyttää *Valmistele*-yhteenvedon vuoroittain ja koko päivälle sekä merkinnän varauksilla; varauksen tiedoissa näkyvät lisäpalvelut, yritysasiakkaan laskutustiedot ja *Muokkaa lisäpalveluita*. Lisäpalvelujen ylläpito (nimi, kuvaus FI/EN, hinta, ALV, enimmäismäärä, vuorotyypit, aktiivisuus): hallinta → Tuotteet → Lisäpalvelut, oikeus `catalog.edit` (manager, admin). Tulkinnat ja avoimet kysymykset: [docs/ristiriidat-ja-tulkinnat.md](docs/ristiriidat-ja-tulkinnat.md#g-asiakastyypit-ja-lisäpalvelut-migraatio-11-v8).
* RPC:t: julkiset `public_addons()`, `public_create_booking(…, p_customer_kind, p_company, p_addons)`, `public_get_booking` (+ `addons`); hallinta `admin_create_customer`, `admin_update_customer`, `admin_list_customers`, `admin_get_order`, `admin_set_reservation_addons`, `admin_list_addons`, `admin_create_addon`, `admin_update_addon`, `admin_create_booking(…, p_addons, p_invoice_reference)`, `admin_day_view` (+ `prep`, `addon_totals`).

### Edge Function `admin-users`

Kutsu sähköpostilla, käytöstä poisto/aktivointi (Auth-esto) – tarvitsee service role -avaimen, joten se ajetaan **palvelimella** (Supabase Edge Function), ei selaimessa.
Kutsuja tunnistetaan omalla JWT:llään (`booking.is_admin()`), sen jälkeen säännöt ja audit-loki tulevat `booking.svc_*`-funktioista.

| Muuttuja | Mistä |
|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Supabase asettaa automaattisesti Edge Functioneille |
| `ALLOWED_ORIGINS` | käsin: sallitut originit (esim. `https://<hallinta>`; GitHub Pages -testissä `https://joonasvaarala.github.io` – vain origin, ei polkua), ei jokerimerkkiä |
| `SITE_URL` / `INVITE_REDIRECT_URL` | käsin: kutsulinkin kohde. `INVITE_REDIRECT_URL` käytetään sellaisenaan (ensisijainen); jos puuttuu, kohde on `SITE_URL/hallinta/`. Lisättävä myös Authin *Redirect URLs* -listaan |

```bash
cd booking     # supabase/config.toml: verify_jwt = true
supabase secrets set ALLOWED_ORIGINS="https://<hallinta>" SITE_URL="https://<sivusto>" --project-ref <ref>
supabase functions deploy admin-users --project-ref <ref>
node --test supabase/functions/admin-users/logic.test.js      # yksikkötestit (myös: deno test …)
```
Hallinnan `config.js`:ssä oletus `functions: '/functions/v1'`. Paikallisessa demossa kehityspalvelin tarjoaa **mock-version** samasta rajapinnasta (sama `logic.js` ja samat tietokantafunktiot; kutsulinkki palautetaan vastauksessa sähköpostin sijaan).

### Roolit, käyttäjät ja työvuorot

* `admin` – kaikki, myös **Käyttäjät** (kutsu, rooli, käytöstä poisto, linkitys työntekijään). `manager` – ylläpito + kaikkien työvuorot, **ei** käyttäjähallintaa. `staff` – varaukset + omat työvuorot. Ks. [docs/roolit-ja-kb.md](docs/roolit-ja-kb.md).
* **Kalenteri** (kuukausi/viikko): työvuorot sinisellä, varaukset vihreällä; päivän klikkaus näyttää tiedot. Työvuorot luetaan `public`-skeemasta (Työvuoro-Tapio; vain luku, **muokkausta ei ole**) funktiolla `admin_upcoming_shifts` – oletetut sarakenimet ja niiden tarkistus: [docs/roolit-ja-kb.md](docs/roolit-ja-kb.md#oletetut-public-sarakkeet-varmistettava-ennen-migraatioiden-ajoa). Jos vuorodataa ei saada, varaukset näkyvät silti ja näytetään huomautus.
* Staff näkee vain omat vuoronsa, kun hänen käyttäjänsä on linkitetty työntekijään (Käyttäjät → Työntekijä).

### Ympäristömuuttujat / avaimet

| Muuttuja | Missä | Huom |
|---|---|---|
| `BOOKING_SUPABASE_URL`, `BOOKING_ANON_KEY` | kaupan build, `config.js` | anon/publishable-avain saa olla julkinen |
| `BOOKING_REST`, `BOOKING_AUTH`, `BOOKING_SCHEMA` | kaupan build | oletus `/rest/v1`, `/auth/v1`, `booking` |
| `SITE_URL`, `SITE_ENV` | sivuston build | kuten nykyinen build (`SITE_ENV=test` → noindex) |
| service role -avain | **ei koskaan selaimessa** | vain tulevalle Visma Pay -callback-funktiolle (palvelinpuoli) |
| `PGHOST/PGPORT/PGUSER/PGPASSWORD`, `BOOKING_TEST_DB` | testit | paikallinen testikanta |

## Paikallinen demo

Vaatii PostgreSQL 15+ (`btree_gist`), [PostgREST](https://postgrest.org) ja Node 20.

```bash
# 1) kanta: mock-Supabase + kb (oikea tuotedata, ei asiakkaita) + migraatiot + demo-siemen (keksittyjä @example.com-asiakkaita)
PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres booking/dev/setup-db.sh
# 2) REST
postgrest booking/dev/postgrest.conf &
# 3) kauppa + kehityspalvelin (staattiset + PostgREST-proxy + mock-kirjautuminen)
BOOKING_SUPABASE_URL= BOOKING_ANON_KEY=demo node booking/shop/build.mjs
node booking/dev/server.mjs        # http://localhost:4180/  ja  /admin/   (admin@demo.local / staff@demo.local, salasana: demo)
# 4) kuvakaappaukset + konsolivirhetarkistus
PW_DIR=/polku/node_modules node booking/scripts/e2e-screenshots.mjs
PW_DIR=/polku/node_modules node booking/scripts/e2e-shop-layout.mjs   # kaupan lomakkeen asettelu eri leveyksillä
# ilman tietokantaa (mock-RPC): vain vapaat vuorot asiakkaalle
SHOP_DIST=/tmp/shop-dist node booking/shop/build.mjs && SHOP_DIST=/tmp/shop-dist PW_DIR=/polku/node_modules node booking/scripts/e2e-shop-vain-vapaat.mjs
```

Demodata (`dev/seed_demo.sql`) sisältää kiinteän "tyhjän päivän" (savusauna suljettu koko päivän ensi maanantaista +9 pv), jota kaupan e2e-testit käyttävät; testi ei siis enää riipu kellonajasta.

Kuvakaappaukset: [`docs/screenshots/`](docs/screenshots/).

## Testit

```bash
PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres booking/supabase/tests/run.sh
```
Vaatii PostgreSQL + pgTAP. Luo kannan `booking_test`, lataa mock-Supabasen (roolit `anon/authenticated/service_role`, `auth.uid()/auth.jwt()`), mock-kb:n (oikea tuotedata), `public`-skeeman mockin (`fixtures/public_mock.sql`: työvuorotaulut, `shift_assignments.status`, `staff_roles` ja kolme mock-saunottajaa tuotannon `public.staff`-UUID:illa, joita migraatio 16 vaatii; ei GRANTteja), kaikki migraatiot ja ajaa:

* `01_security` – RLS kaikissa tauluissa, `search_path` kaikissa funktioissa, anonin/staffin/ei-staffin oikeudet, ei vuotoja
* `02_overlap_rules` – yksityinen ↔ yleinen molempiin suuntiin (to, la–su, 1 h vuorot mukaan lukien), sulut, peruutus, vanhenevat pidot
* `03_capacity` – ma–ke 16, to turve 8 + yleinen = 16, la–su 6 / alkamisaika (15:30 ei tarjolla), 1 h vuorot 10 / vuoro omana kapasiteettinaan
* `04_public_api` – validointi, hinnoittelu, rate limit, tokenilla haku ei vuoda henkilötietoja, asiakas-upsert, suostumuslogi
* `05_admin` – roolit, kb-tuotemuokkaus (+ audit + `kb.change_log`), manuaalivaraus, maksut, maksuadapteri, asiakashaku
* `06_roles` – roolitaulut, admin/manager/staff-oikeusmatriisi (staff ei voi päivittää hintaa, manager voi, manager ei voi muokata henkilöstöä tai antaa admin-oikeutta), viimeisen adminin suojaus, uusi rooli ilman koodimuutosta
* `07_change_booking` – asiakkaan varauksen muutos (`public_change_booking`): vuoron vaihto, henkilömäärä, 48 h raja (rajatapaukset), kapasiteetti ja päällekkäisyys molempiin suuntiin, atomisuus, `admin_change_booking`
* `08_annual_card` – vuosikortti: vain yleinen vuoro, 0 €, yksi tuleva varaus kerrallaan, ohitusyritykset suoraan tietokannassa, myöntö/peruutus, RLS
* `09_users_shifts` – työvuorojen lukunäkymä (staff vain omat, manager kaikki, ei oikeutta → virhe, väli > 62 pv → virhe, ei vuotavia kenttiä), roolin vaihdon ja linkityksen suojat (ei itseä, ei viimeistä adminia, epäaktiivinen/tuntematon kohde, vain staff-rooli, sama työntekijä kahdelle), `svc_*`-funktiot (vain service_role, säännöt, audit), ei kirjoituksia `public`-skeemaan
* `supabase/functions/admin-users/logic.test.js` – Edge Functionin validointi (rooli-sallittulista, syötteet, CORS, kutsulinkin osoite, virhekartoitus); `node --test` tai `deno test`
* `11_customer_kinds_addons` – asiakastyypit (y-tunnuksen tarkistenumero ja normalisointi, yritystietojen validointi, tuplien esto, yksityinen ≠ yritys samalla sähköpostilla, laskutustietojen kuva tilauksella), lisäpalvelujen hinnoittelu ja tilaus (summat, ALV-osuus, määrärajat, passiivinen/tuntematon/väärä vuorotyyppi), muutos lisäpalveluiden kanssa (rajaus, maksetun tilauksen hintatarkistus), hallinnan oikeudet (`catalog.edit`: staff ei, manager/admin kyllä), päivänäkymän "valmistele"-yhteenveto, RLS-eristys ja sisäisten funktioiden oikeudet
* `12_johku_marker` – Johku-merkintä (migraatio 12): `admin_list_reservations` `p_source`-suodatin (johku/native/null), `source`/`external_id` listassa ja `admin_day_view`:ssä, vanhat kutsut ja sarakkeet, `external_meta` ei vuoda (anon ei lue, ei listassa/päivänäkymässä), oikeudet (ei anon). Ohittuu, jos migraatiota 12 ei ole testikannassa
* `17_resource_bookings` – resurssivaraukset (migraatio 17): `reservation_legs`, validaattorit ja BK001-koodit, `admin_create_resource_booking` / `admin_create_old_booking` (lifecycle-rajaus, ylitys vaatii `bookings.override` + syyn), Rauni↔Lovi-siirto, `admin_review_list`, `v_claims`, yksityisvuorojen viikonloppusäännöt, oikeudet (anon ei pääse, staff ilman oikeutta ei ylitä). Ohittuu, jos migraatiota 17 ei ole testikannassa
* `18_closure_calendars` – sulkukalenterit (migraatio 18): rekisteri ja säännöt, `apply_closure_events` (alkuajo, idempotenssi, muutos, poisto, massapoistosuoja, dry-run, ikkuna, DST), ohitus (`admin_set_closure_override`), hallinta-esto (`closure_managed`), validaattorit (hoidot / perinne / Rauni / savusauna kiinni, Laura), konfliktit (`admin_review_list`, `admin_closure_overview`), `admin_day_view`:n `closure_event_id`. Ohittuu, jos migraatiota 18 ei ole testikannassa
* `10_rls_initplan` – politiikkojen lausekkeissa ei ole suoraa `auth.uid()`/`is_staff()`/`has_permission()`-kutsua ilman `select`-kääreitä; politiikkojen määrä ja oikeudet (staff/manager/admin/anon) ennallaan
* `19_product_images` – tuotekuvat: rajoitteet, bucket + storage-politiikat (anon/staff/manager), `admin_set_product_image` (oikeudet, validointi, audit, polkuhyökkäykset), `public_product_images` (ei vuotoja, piilotettu tuote ei näy)
* `race.sh` – rinnakkaiset yhteydet yrittävät varata samaa aikaa yhtä aikaa (advisory-lock-portti); invariantit: ei yksityisen ja yleisen päällekkäisyyttä, kapasiteetti ei ylity (ma–to 16, la–su 6 / alkamisaika, 1 h vuoro 10, poolit riippumattomia), vuosikortilla vain yksi tuleva varaus, asiakkaan rinnakkaiset muutokset eivät ylitä kapasiteettia eivätkä riko päällekkäisyyssääntöä
* `mutation_check.sh` – todistaa että kilpailutesti on herkkä: poistaa lukon testikannasta ja odottaa `race.sh`:n epäonnistuvan

## Sääntöjen muuttaminen

Kaikki data, ei koodia. Pienet muutokset (kapasiteetit, sääntöjen nimi/päällä/pois, henkilömäärät, deadline, voimassaolo, asetukset) voi tehdä hallinnan Resurssit- ja Asetukset-näkymistä (manager ja admin). Uudet vuorot ja aikataulumuutokset tehdään **uudella migraatiotiedostolla** (`supabase/migrations/<aikaleima>_*.sql`), jonka Bottiavustus ajaa. Viikonlopun 2 h vuoron kapasiteetti on poolikohtainen: jokaisella alkamisajalla on oma pooli (`yleinen_vkp_HHMM`).

```sql
-- Viikonlopun yhden alkamisajan (14:00) kapasiteetti 6 → 8
update booking.resources set capacity = 8 where code = 'yleinen_vkp_1400';        -- (tai hallinnan Resurssit-näkymästä)

-- Uusi yleinen vuoro la–su klo 18:30 (2 h) – oma kapasiteettipooli (6 hlö / alkamisaika)
with p as (insert into booking.resources (code, name, kind, parent_id, capacity, notes, sort_order)
           select 'yleinen_vkp_1830', 'La–su 2 h vuoro 18:30 (paikat / vuoro)', 'capacity_pool', id, 6, 'Viikonlopun 2 h yleinen vuoro klo 18:30: 6 hlö per vuoro.', 39
             from booking.resources where code = 'savusauna' returning id),
     r as (insert into booking.schedule_rules (product_id, label, mode, space_id, weekdays, start_time, duration_minutes, max_persons, price_mode, deadline_minutes, sort_order)
           select 1, 'Yleinen vuoro la–su 18:30 (2 h)', 'shared', (select id from booking.resources where code = 'savusauna'), '{6,7}', '18:30', 120, 6, 'per_person', 15, 100 returning id)
insert into booking.schedule_rule_pools (rule_id, pool_id) select r.id, p.id from r, p;

-- Sulje vuoro pysyvästi / väliaikaisesti
update booking.schedule_rules set active = false where id = 9;                    -- tai valid_to = '2026-08-31'
```
Hinnat ja tuotetekstit **eivät** ole sääntöjä: ne muokataan hallinnan Tuotteet-näkymästä (kb on totuus). Vuoroaikojen ja kapasiteettien muutos vaikuttaa vain tuleviin varauksiin; olemassa olevat varaukset säilyvät (poolit tallennetaan varaukselle).

## Puuttuu ja seuraavat vaiheet

* **Visma Pay** – ei toteutettu (vain taulut, adapterifunktiot ja `pay_later`/`hold_until_paid` -tilat), ks. [docs/maksut-visma-pay.md](docs/maksut-visma-pay.md)
* Sähköpostivahvistukset ja muistutukset – **avoin, ei toteutettu**. Suunnitelma: lähetys osoitteesta savusauna@saunotus.fi Supabase Edge Functionilla ja transaktiosähköpostipalvelulla (valitaan myöhemmin). Siihen asti vahvistus näkyy vain sivulla ja peruutukset tulevat sähköpostilla.
* Vuosikorttiasiakkaan itsepalvelu (kirjautuminen) – rakenne valmis (`customers.auth_user_id`, `annual_card`-rooli), ei toteutettu
* Lahjakortit (taulut valmiina), alennuskoodit (taulu valmiina), tuotesarjat
* Hoidot, saunotukset, rituaalit, tapahtumat (kalenteri- ja resurssimalli: hoitajat `person`-resursseina – tyyppi on jo skeemassa)
* Yritysvaraukset / tarjouspyynnöt
* Johku-tuonti (rakenne valmis: `external_source`, `johku_order_no`, `payment_methods.johku_codes`) – ks. [docs/johku-tuonti.md](docs/johku-tuonti.md)
* Markkinointilähetykset (segmentit/kampanjat: vain rakenne)
* Kaupan EN-käännökset tuotteille (`name_en`/`description_en` kb:ssä osin tyhjiä)

## Avoimet kysymykset

Ks. [docs/ristiriidat-ja-tulkinnat.md](docs/ristiriidat-ja-tulkinnat.md) (yhteenveto raportissa).

### Varauslistan ajanjakso
`Kaikki ajat` kutsuu `admin_list_reservations`:ia ilman päivärajoja (`p_from`/`p_to` = null; funktio sallii nullin, ei SQL-muutoksia). `Tulevat` = tästä päivästä alkaen, `Menneet` = ennen tätä päivää, `Tämä kuukausi` = kuukauden 1. päivä – seuraavan kuun 1. päivä, `Oma ajanjakso` näyttää Alkaen/Päättyen-kentät (tyhjä kenttä = ei rajaa). Lista sivutetaan (50 / sivu, `Näytä lisää`; funktion yläraja 500 / kutsu), joten tuhansia Johku-varauksia sisältävä "Kaikki ajat" ei kuormita. Tulosrivi: `11 / 11 varausta · Kaikki ajat`.

## MobilePay-maksu (UI: tilaussivu, vahvistussivu, hallinnan hyvitys)

Backend (migraatio 49, `mobilepay-start|notify|refund`) on kuvattu sopimuksessa [docs/KOODARI_talous_A_D_fi.md](docs/KOODARI_talous_A_D_fi.md) §14; tämä osio kuvaa käyttöliittymän.

* **Moduulit** (`booking/shop/src/`): `mobilepay-logic.js` (puhdas logiikka: painikkeen näyttöpäätös, `safeRedirect`, paluutilan luokittelu, polling 2,5 s / 60 s), `mobilepay-api.js` (RPC `public_payment_options` + edge-kutsut `mobilepay-start` / `mobilepay-notify {action:'reconcile'}`; virheet palautetaan arvoina, ei heitetä), `mobilepay-ui.js` (painike, virhe- ja tulospaneelit), `mobilepay-texts.js` (FI/EN). Liitetty `order.js`:ään (tilaussivu `/tilaus/?t=…`, `?pay=mobilepay`-paluu) ja `shop.js`:ään (vahvistussivun painike).
* **Painike** näkyy vain kun `public_payment_options(token)` palauttaa `methods`-listassa `mobilepay` ja `order.can_pay_online = true`. `methods[].test = true` (backend `mode='test'`) näytetään vain testiympäristössä: `config.js` `mobilepayTestUi` (build: `SITE_ENV=test` tai `BOOKING_MOBILEPAY_TEST_UI=1`; `?mock=1` aina). **Tuotantorakennuksessa aseta `SITE_ENV=production` (oletus on `test`)**, jolloin test-tapa piilotetaan. Virallinen Vipps MobilePay -painike ladataan web-komponenttina (`vipps-mobilepay-button`, cdn.vippsmobilepay.com; ei-CORS-skripti, 5 s aikakatkaisu) ja jos lataus epäonnistuu tai `mobilepayOfficialButton: false`, näytetään ohjeistuksen mukainen varapainike.
* **Paluu** `?pay=mobilepay`: `reconcile` heti ja sitten ~10 s välein, `public_get_order` 2,5 s välein enintään 60 s; tulos: maksettu / tarkistettavana / epäonnistui / aika meni / ota yhteyttä / odottaa / verkkovirhe (FI+EN), "Tarkista uudelleen" -nappi.
* **Hallinta**: `admin_refund` → kun maksu on MobilePay ja rivi `requested`, `views/talous-orders.js` kutsuu `api.mobilepayRefund(refund_id)` (`mobilepay-refund {refund_id}` käyttäjän JWT:llä, §14.4) ja näyttää tuloksen (done / failed / retry_later / unverified …); keskeneräisen hyvityksen voi käsitellä uudelleen maksun alta.
* **Mock-demo** (ei verkkoa): `/tilaus/?t=<uuid>&mock=1&scenario=mp` (+ `mpresult=paid|review|failed|pending|slotlost|contact|netfail|starterror|neterror`, `mpinterval=<ms>`, `mpmax=<ms>`); `scenario=mp-prod` (live-tapa), `mp-off` (ei painiketta).
* **Testit:** `node --test booking/tests/mobilepay-shop.test.mjs` (yksikkö; CI); e2e: `SHOP_DIST=/tmp/shop-dist-mp node booking/shop/build.mjs && PW_DIR=<playwright-core:n kansio> node booking/scripts/e2e-mobilepay.mjs` (kauppa; `CDN=real` hakee virallisen painikkeen, `SHOTS=0` ohittaa kuvat) ja `node booking/scripts/e2e-mobilepay-admin.mjs` (hallinnan hyvitys); `scripts/smoke-pages.mjs` kattaa tilaussivun mock-skenaarion.
