# Pyyntö Bottiavustukselle: lisäpalvelu **Pyyhe** (5 €) + lisäpalveluiden rajaus hoitoihin (migraatio 26+)

> Luonnos. **Älä aja ennen kuin Joonas on hyväksynyt.** Frontti (hallinta, kauppa) toimii ilman tätä: jos riviä ei ole, pyyhettä ei näytetä; ilman uutta `resource`-tilaa lisäpalveluvalitsin on hoito-/saunotuslomakkeilla tyhjä (piilossa).

## Joonaksen päätös (17.10.)

* **Pyyhe 5 €** tarjotaan **kaikissa**: yleisissä saunavuoroissa, yksityisvarauksissa **sekä hoidoissa ja saunotuksissa** (resurssivaraukset: kb 8, 10, 11, 12 ja muut resurssituotteet).
* **Turvenaamio ja jalkakylpy** (nykyinen yhdistetty lisäpalvelu `turvenaamio_jalkakylpy`) ja **saunavihta** (`saunavihta`) tarjotaan **vain yleisissä vuoroissa ja yksityisvarauksessa**, **ei** hoidon, saunotuksen tai tapahtuman (resurssivarauksen) yhteydessä.

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
3. **`booking._attach_addons`**: laske varauksen *tehokas tila*: `resource`, jos varauksen tuote on resurssituote (`product_config.resource_class = 'resourced'` ja `lifecycle in ('current','old')`, eli sama joukko kuin `admin_create_resource_booking` / `admin_create_old_booking` / `public_create_treatment_booking`), muuten `r.mode`. Tarkistus: `v_mode = any(a.applies_modes)`, virhe `addon_not_allowed` kuten nyt. (Siis pyyhe käy kaikkialla, vihta/turvenaamio vain `shared`/`exclusive`-vuoroilla.)
4. **`admin_create_addon` / `admin_update_addon`**: hyväksy `resource` `applies_modes`-taulukossa (nyt: `v_modes <@ array['shared','exclusive']`; uusi `array['shared','exclusive','resource']`, virheviesti päivitetään).
5. **`public_addons()`**: palauttaa jo `applies_modes`; ei muutosta (kauppa suodattaa `applies_modes.includes(tila)`; hoitopolku käyttää tilaa `resource`).
6. **`public_create_treatment_booking`** (booking_25): lisää viimeiseksi `p_addons jsonb default null` (rivit `{id, quantity}` kuten `public_create_booking`), kutsu `_attach_addons` samassa transaktiossa ja lisää hinta `total`-arvoon (+ `public_get_booking.addons`). Näin verkkosivun hoitopolku voi tarjota pyyhkeen (ja vain sen). Vanha kutsu ilman `p_addons` toimii ennallaan.
7. *(Toivomus, ei pakollinen)* **`admin_day_view.reservations[].addons[]`**: lisää kenttä `code` (`a.code`; nyt `addon_id`, `name`, `quantity`), jotta hallinnan ikonit (vihta / turvenaamio / pyyhe) tunnistetaan koodista eikä nimestä. Frontti käyttää `code`-kenttää jos se on, muuten nimeä.

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
