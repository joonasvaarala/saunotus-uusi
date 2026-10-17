# Pyyntö Bottiavustukselle: lisäpalvelu **Pyyhe** (5 €) + lisäpalveluiden rajaus hoitoihin (migraatio 27)

> **Älä aja tuotantoon ennen kuin Joonas on hyväksynyt.** Frontti (hallinta, kauppa) toimii ilman tätä: jos riviä ei ole, pyyhettä ei näytetä; ilman uutta `resource`-tilaa lisäpalveluvalitsin on hoito-/saunotuslomakkeilla tyhjä (piilossa).

## Joonaksen päätös (17.10.)

* **Pyyhe 5 €** tarjotaan: yleisissä saunavuoroissa, yksityisvarauksissa **sekä hoidoissa ja saunotuksissa** (resurssivaraukset: kb 8, 10, 11, 12 ja muut resurssituotteet). **Ei tapahtumissa** (`kb.products.category = 'event'`: kb 9, 32, 33, 34).
* **Turvenaamio ja jalkakylpy** (nykyinen yhdistetty lisäpalvelu `turvenaamio_jalkakylpy`) ja **saunavihta** (`saunavihta`) tarjotaan **vain yleisissä vuoroissa ja yksityisvarauksessa**, **ei** hoidon, saunotuksen tai tapahtuman (resurssivarauksen) yhteydessä.

> **Valmis migraatio + pgTAP repossa (ajettu tuotantoon versiona 20261017072446):** `booking/supabase/migrations/20261017072446_booking_27_pyyhe_resource_addons.sql` + `booking/supabase/tests/27_pyyhe_resource_addons.test.sql` (37 testiä; kaikki 1103 pgTAP-testiä + kilpailutesti läpi). Kattaa kohdat 1–5 ja 8 alla (7 = `code` admin_day_view:hin on mukana). Funktiorungot ovat repon booking_11 / booking_22 -kopioita merkityin muutoksin ("MUUTOS"); ajettu kahdesti peräkkäin = idempotentti. **Numerointi:** tuotannossa on jo booking_24 (closure_writeback), 25 (public_treatment) ja 26 (publish_treatments), jotka eivät ole tässä repossa → tämä on **booking_27**; tiedoston aikaleima `20261017072446` on tuotantoon ajettu versio. Päivitetty testi `11_customer_kinds_addons.test.sql`: lisäpalvelujen lukumäärä 2 → 3 (uusi Pyyhe-rivi). Lisäksi käsin paikallisella demokannalla: hoito (kb 10) + pyyhe OK (+5 €), hoito + saunavihta / turvenaamio_jalkakylpy → `addon_not_allowed`, tapahtuma (kb 33, 9) + pyyhe → `addon_not_allowed`. **Ei mukana (vain pyyntö):** kohta 6 (`public_create_treatment_booking` + `p_addons`), koska booking_25 ei ole repon migraatioissa eikä sitä voi testata repon pgTAP-ketjussa; kauppa tarjoaa hoitopolulla toistaiseksi vain "ei lisäpalveluita" (oikein vihdan/turvenaamion osalta, pyyhe puuttuu).

## Nykytila (booking_11)

* `booking.addons.applies_modes text[]` sallii vain `shared` (yleinen vuoro) ja `exclusive` (yksityisvuoro) (check-rajoite). Kaikki nykyiset rivit: `{shared,exclusive}`.
* `booking._attach_addons(reservation_id, p_addons)` tarkistaa `r.mode = any(a.applies_modes)`. Resurssivaraus (hoito/saunotus) on `reservations.mode = 'exclusive'`, joten **nykyinen palvelinlogiikka sallisi vihdan ja turvenaamion myös hoitovarauksella** (`admin_create_resource_booking(p_addons => …)`). Frontti piilottaa ne jatkossa, mutta palvelimen pitää myös estää.
* `public_create_treatment_booking` (booking_25) ei ota `p_addons`-parametria.

## Pyydetyt muutokset (yksi migraatio, versio uudempi kuin viimeisin tuotannossa; additiivinen, idempotentti)

Tiedostonimi: `<versio>_booking_26_addon_towel_resource_mode.sql` (versio > viimeisin `supabase_migrations.schema_migrations`; kerro versio takaisin, niin repoon tulee tavutarkka kopio).

1. **Uusi tila `resource`** (hoito, saunotus, rituaali, tapahtuma = resurssivaraus) `applies_modes`-rajoitteeseen:
   ```sql
   do $$ declare c text; begin
     for c in select conname from pg_constraint where conrelid = 'booking.addons'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%applies_modes%' loop
       execute format('alter table booking.addons drop constraint %I', c);
     end loop;
     alter table booking.addons add constraint addons_applies_modes_check
       check (cardinality(applies_modes) > 0 and applies_modes <@ array['shared','exclusive','resource']);
   end $$;
   comment on column booking.addons.applies_modes is 'shared = yleinen vuoro, exclusive = yksityisvuoro, resource = resurssivaraus (hoito, saunotus, rituaali, tapahtuma).';
   ```
2. **Rivi Pyyhe** (idempotentti; ALV kuten muilla lisäpalveluilla 25,5 %, hinta 5,00 € sis. ALV):
   ```sql
   insert into booking.addons(code, name, name_en, description, description_en, price_gross, vat_rate, max_per_person, applies_modes, active, sort_order)
   values ('pyyhe', 'Pyyhe', 'Towel', 'Lisäpalvelu varaukseen: pyyhe.', 'Add-on for your booking: towel.', 5.00, 25.5, 1, '{shared,exclusive,resource}', true, 30)
   on conflict (code) do nothing;
   ```
   Vihta ja turvenaamio+jalkakylpy **eivät** saa `resource`-tilaa (`applies_modes` pysyy `{shared,exclusive}`); tarkista ajon jälkeen: `select code, applies_modes from booking.addons order by sort_order;`.
3. **`booking._attach_addons`**: laske varauksen *tehokas tila*: `resource`, jos varauksen tuote on resurssivaraus (`product_config.sale_kind = 'other'` ja `resource_class = 'resourced'`; sama joukko kuin `admin_create_resource_booking` / `admin_create_old_booking` / `public_create_treatment_booking`), **`event`, jos lisäksi `kb.products.category = 'event'`** (ei lisäpalveluita lainkaan), muuten `r.mode`. Tarkistus: `v_mode = any(a.applies_modes)`, virhe `addon_not_allowed` kuten nyt. (Siis pyyhe käy kaikkialla, vihta/turvenaamio vain `shared`/`exclusive`-vuoroilla.)
4. **`admin_create_addon` / `admin_update_addon`**: hyväksy `resource` `applies_modes`-taulukossa (nyt: `v_modes <@ array['shared','exclusive']`; uusi `array['shared','exclusive','resource']`, virheviesti päivitetään).
5. **`public_addons()`**: palauttaa jo `applies_modes`; ei muutosta (kauppa suodattaa `applies_modes.includes(tila)`; hoitopolku käyttää tilaa `resource`).
6. **`public_create_treatment_booking`** (booking_25): lisää viimeiseksi `p_addons jsonb default null` (rivit `{id, quantity}` kuten `public_create_booking`), kutsu `_attach_addons` samassa transaktiossa ja lisää hinta `total`-arvoon (+ `public_get_booking.addons`). Näin verkkosivun hoitopolku voi tarjota pyyhkeen (ja vain sen). Vanha kutsu ilman `p_addons` toimii ennallaan.
7. *(Toivomus, ei pakollinen)* **`admin_day_view.reservations[].addons[]` ja `prep[].items[]` / `addon_totals[]`**: lisää kenttä `code` (`a.code`; nyt `addon_id`, `name`, `quantity`). Frontti tunnistaa ikonit (vihta / turvenaamio / jalkakylpy / pyyhe) jo nyt: 1) `code` jos annettu, 2) `addon_id` → `admin_list_addons().code`, 3) nimi. Kenttä vain vahvistaisi tunnistuksen yhdellä kyselyllä vähemmän.
8. **Uusi `booking.admin_day_shifts(p_date date)`** (hallinnan etusivun työvuorot kaikille): nykyinen `admin_upcoming_shifts` vaatii `shifts.view` / `shifts.view_all` ja rajaa `staff`-roolin (jolla on vain `shifts.view`) **vain omiin vuoroihin** → peruskäyttäjä ei näe, kuka on missäkin vuorossa; rooli ilman kumpaakaan oikeutta ei näe mitään. Uusi funktio vaatii vain `_require_staff()` ja palauttaa samat sarakkeet (vuoro-id, ajat, role_type, calendar_name, staffing_status, staff_name; ei puhelinta/sähköpostia/muistiinpanoja). SQL: migraatio booking_27, kohta "MUUTOS 6". Frontti kokeilee ensin tätä ja putoaa tarvittaessa `admin_upcoming_shifts`-kutsuun (staff: "vain omat vuorot" -huomautus).

## pgTAP-testi (uusi tiedosto `26_addon_towel_resource_mode.test.sql`)

* `pyyhe` löytyy: hinta 5,00, ALV 25,5, `applies_modes = {shared,exclusive,resource}`, `active`.
* `saunavihta` ja `turvenaamio_jalkakylpy`: `applies_modes` ei sisällä `resource`.
* Rajoite: `update booking.addons set applies_modes = '{foo}'` → virhe; `'{resource}'` sallittu.
* `_attach_addons` yleisellä vuorolla (`shared`): pyyhe + vihta OK. Yksityisvuorolla (`exclusive`): pyyhe + vihta OK.
* Hoitovaraus (`admin_create_resource_booking` kb 10, `p_addons` = pyyhe): OK, rivi + hinta +5 €; `p_addons` = vihta tai turvenaamio_jalkakylpy → `addon_not_allowed` (BK001/`P0001` kuten nyt).
* `public_create_treatment_booking` + `p_addons` pyyhe: `total` + 5 €; vihta → `ok:false` (`addon_not_allowed`); ilman `p_addons` ennallaan.
* `admin_create_addon('{"applies_modes":["resource"],…}')` onnistuu `catalog.edit`-oikeudella; virheellinen tila (`foo`) → `invalid_modes`.
* Idempotenssi: migraation ajo kahdesti ei muuta mitään (`on conflict do nothing`, rajoite korvataan samannimiseksi).

## Ei tuotantoon ilman hyväksyntää

Tämä tiedosto on vain pyyntö. Frontti (v25) ei aja mitään tuotantokantaa vasten; testit käyttävät mock-dataa. Rollback: `delete from booking.addons where code = 'pyyhe' and not exists (select 1 from booking.order_items where addon_id = booking.addons.id)`; rajoite takaisin `array['shared','exclusive']` vain jos mikään rivi ei käytä `resource`-tilaa.
