-- booking_163_booking_url_kauppaan: kb.products.booking_url (Johku-tuotesivut) → uuden kaupan tuotesivu, kun tuote on uudessa kaupassa.
-- Tuotannon versio 20261024185115 (ajettu tuotannossa 24.10.2026). Projektin oletus (Joonas 24.10.2026): ei Johku-linkkejä.
-- Miksi: booking_url on kb.productsissa anon/authenticated-luettava sarake, ja sivuston build (src/render.mjs bookingUrl) käyttää sitä korttien,
-- aukioloaikojen ja rituaalirivien linkkeinä. #162 ohjaa Johku-osoitteet buildissa kauppaan, mutta lähdedata osoitti yhä Johkuun.
-- Uusi arvo on kanoninen absoluuttinen osoite (FI): https://saunotus.fi/varaa/#/tuote/<slug> (vuosikortti: /varaa/#/vuosikortti).
-- EN-sivut muuntavat sen muotoon /en/book/#/tuote/<slug> (src/lib.mjs bookingUrl), ja build ohjaa kanonisen osoitteen sivuston BASE-polkuun.
-- Vain tuotteet, jotka ovat uuden kaupan katalogissa (booking.public_catalog, 15 kpl tuotannossa 24.10.2026) + vuosikortti (kaupan oma sivu).
-- Vartijat: slug ja nykyinen booking_url TÄSMÄLLEEN odotetut, muuten exception ennen yhtään muutosta; jo uusi arvo ohitetaan (uudelleenajettava).
-- Hinnat, ALV, slugit ja muut kentät ennallaan. Lukittu sivuteksti product.<id>.booking_url saa uuden version triggeristä zz_site_text_sync.
-- Rollback: booking/supabase/rollbacks/20261024185115_booking_163_ROLLBACK.sql (sama vartija peilikuvana).
-- Muutettavat (tuote, slug, Johku-polku → uusi polku), 16 kpl:
--     1 yleinensauna                     /fi_FI/yleinen-sauna/yleinensauna → /varaa/#/tuote/yleinensauna
--     2 miestensauna-2                   /fi_FI/yleinen-sauna/miestensauna-2 → /varaa/#/tuote/miestensauna-2
--     3 naistensauna                     /fi_FI/yleinen-sauna/naistensauna → /varaa/#/tuote/naistensauna
--     4 hiljainen-sauna                  /fi_FI/yleinen-sauna/hiljainen-sauna → /varaa/#/tuote/hiljainen-sauna
--     5 turvetorstai                     /fi_FI/yleinen-sauna/turvetorstai → /varaa/#/tuote/turvetorstai
--     6 tunnin-vuoro                     /fi_FI/yleinen-sauna/tunnin-vuoro → /varaa/#/tuote/tunnin-vuoro
--     7 saunarituaali-ja-savusaunavuoro  /fi_FI/yleinen-sauna/saunarituaali-ja-savusaunavuoro → /varaa/#/tuote/saunarituaali-ja-savusaunavuoro
--     8 saunotusrituaali                 /fi_FI/hoidot/saunotusrituaali → /varaa/#/tuote/saunotusrituaali
--    10 saunahoito-2                     /fi_FI/hoidot/saunahoito-2 → /varaa/#/tuote/saunahoito-2
--    11 saunotus-2                       /fi_FI/hoidot/saunotus-2 → /varaa/#/tuote/saunotus-2
--    12 syvasaunotus                     /fi_FI/hoidot/syvasaunotus → /varaa/#/tuote/syvasaunotus
--    25 oma-saunavuoro                   /fi_FI/yksityisvuorot/oma-saunavuoro → /varaa/#/tuote/oma-saunavuoro
--    26 jalkiloylyt                      /fi_FI/yksityisvuorot/jalkiloylyt → /varaa/#/tuote/jalkiloylyt
--    43 vuosikortti                      /fi_FI/sarja-ja-lahjakortit/vuosikortti → /varaa/#/vuosikortti
--    48 saunavuoro-yrityksille           /fi_FI/yrityksille/saunavuoro-yrityksille → /varaa/#/tuote/saunavuoro-yrityksille
--    49 jalkiloylyt-yrityksille          /fi_FI/yrityksille/jalkiloylyt-yrityksille → /varaa/#/tuote/jalkiloylyt-yrityksille
-- md5 (alkuperäinen → uusi):
--     1 38b21ff95ded1500ef298664574e1711 → 3c1ea95e45f74d98f525cd8dfbd1d7d7
--     2 2724662449fe66bcc6663c0bbea8365b → 09fe7c426bc0fa87c5ca025f817d74ac
--     3 8b12062fec23a5d01b8698f042c45da7 → 79b2baa7c3936ddb07501ba6f6be8270
--     4 20174df0e6910c22f6c4f321be20bc8d → c3a3bb270d9ae410959b533096609637
--     5 a4631e8ae2f3a34f0326a169ebd312be → 821fef43dd3a40e8cbd30b4f9638f870
--     6 40ecf273cdd2cd5fe1c0e57ce37ac699 → 82071d9285b216ea0ebb4b147cc2238c
--     7 83d0ad1d0eb632339cb9f0b504bcdd51 → e44d6f342ad36c5b57862de268ad1c7a
--     8 04ee683a467daf3d2338b363bb6486da → 74e26e64e4dfc1c79e15bfde84c0be5f
--    10 8d54b072dda9b3d2ccc8340448d57cda → d7136fbd00d14ff14168d8408b4c895b
--    11 60590f97aa8208a1ebb0eef9df27ccc8 → 8c8450c49b9f6f01b099f3210a715f7d
--    12 241a3199c8520571acaf724dcc86eacb → 5166ad6e9cf7321443dea0dfc41ff1c2
--    25 70392ea0b7f056d5ee91ce7b0ad95e34 → 4c957cbf80e6096315fe1406ecd8b255
--    26 2df60a637b23a212054fff3548bffca0 → 56a282747eae83e80446e8299a2fcde6
--    43 972129398d848f610f3e1391deeb6024 → 49236d8aea7e6ab6f68c89cda568cdb1
--    48 df80c600df821bd7aaeb6d68cabb6c15 → 9c03a4bb3b782cf44ac2878c4bfed570
--    49 0cce4aea53a7f7f99b93fc5c3694c664 → 3d6590e50cea015d7b7856c50351baeb
-- EI muuteta (ei vastaavaa uuden kaupan tuotetta; jäävät Johku-osoitteiksi, build ohjaa ne #162:n säännöillä), 33 kpl:
--     9 perinnesaunotusilta                      event           /fi_FI/tapahtumat/perinnesaunotusilta  (tapahtuma: kaupan tapahtumasivu tulee booking_158:ssa (#159/#161), myynti pois päältä)
--    13 perinnesaunotus-ryhmalle                 treatment       /fi_FI/saunaseremoniat/perinnesaunotus-ryhmalle  (lifecycle old, ei kaupassa)
--    14 perinnevihdonta                          add_on          /fi_FI/yleinen-sauna/naistensauna  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    15 perinnevihdonta-kahdelle                 add_on          /fi_FI/yleinen-sauna/naistensauna  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    16 vihtahoito                               add_on          /fi_FI/yleinen-sauna/naistensauna  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    17 vihtahoito-kahdelle                      add_on          /fi_FI/yleinen-sauna/naistensauna  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    18 turvehoito-15min                         add_on          /fi_FI/yleinen-sauna/naistensauna  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    19 turvehoito-30                            add_on          /fi_FI/yleinen-sauna/naistensauna  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    20 turvehoito-koko-vartalo                  add_on          /fi_FI/yleinen-sauna/miestensauna-2  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    21 saunahieronta-60min                      add_on          /fi_FI/yleinen-sauna/naistensauna  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    22 saunahieronta-30                         add_on          /fi_FI/yleinen-sauna/naistensauna  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    23 perinnesaunotus-yhdelle                  add_on          /fi_FI/yleinen-sauna/naistensauna  (active=false (vanha lisäpalvelu); Johku-osoite on yleisen vuoron sivu)
--    24 vihtahoito-opiskelijatyona               treatment       /fi_FI/hoidot/vihtahoito-opiskelijatyona  (varattava (Lovi), mutta shop_visible=false)
--    27 perinnesaunotus-jalkiloylyille           ceremony        /fi_FI/saunaseremoniat/perinnesaunotus-jalkiloylyille  (seremonia, ei kaupassa)
--    28 perinnesaunotus-yksityisvuorolle         ceremony        /fi_FI/saunaseremoniat/perinnesaunotus-yksityisvuorolle  (seremonia, ei kaupassa)
--    29 morsiussauna                             ceremony        /fi_FI/saunaseremoniat/morsiussauna  (seremonia, ei kaupassa)
--    30 synttarisauna                            ceremony        /fi_FI/saunaseremoniat/synttarisauna  (seremonia, ei kaupassa)
--    31 turvesauna                               ceremony        /fi_FI/saunaseremoniat/turvesauna  (seremonia, ei kaupassa)
--    32 naisten-joulusauna                       event           /fi_FI/tapahtumat/naisten-joulusauna  (tapahtuma (booking_158))
--    33 sipoonjoen-kekri                         event           /fi_FI/tapahtumat/sipoonjoen-kekri  (tapahtuma (booking_158))
--    34 saunottajien-yhteisopaiva-2              event           /fi_FI/tapahtumat/saunottajien-yhteisopaiva-2  (tapahtuma (booking_158))
--    35 saunottajakoulutus-syksy-2026            training        /fi_FI/koulutukset/saunottajakoulutus-syksy-2026  (koulutus, lifecycle old)
--    36 saunottajakoulutus-kevat-syksy-2027      training        /fi_FI/koulutukset/saunottajakoulutus-kevat-syksy-2027  (koulutus (booking_158: vain widget-kanava))
--    37 saunottajakoulutus-kevat-2026            training        /fi_FI/koulutukset/saunottajakoulutus-kevat-2026  (active=false)
--    38 lahjakortti                              gift_card       /fi_FI/sarja-ja-lahjakortit/lahjakortti  (lahjakortti: sivuston /lahjakortti/-sivu, ei kaupan tuote)
--    39 savusaunaelamys-ja-koivuvihta            gift_card       /fi_FI/sarja-ja-lahjakortit/savusaunaelamys-ja-koivuvihta  (lahjakorttipaketti (/lahjakortti/#paketit))
--    40 paikka-yleiselle-vuorolle-ja-saunahoito  gift_card       /fi_FI/sarja-ja-lahjakortit/paikka-yleiselle-vuorolle-ja-saunahoito  (lahjakorttipaketti (/lahjakortti/#paketit))
--    41 savusaunaelamys-ja-vihtahoito-kahdelle-lahjakortti gift_card       /fi_FI/sarja-ja-lahjakortit/savusaunaelamys-ja-vihtahoito-kahdelle-lahjakortti  (lahjakorttipaketti (/lahjakortti/#paketit))
--    42 savusaunaelamys-turvenaamiolla-ja-jalkakylvylla-kahdelle gift_card       /fi_FI/sarja-ja-lahjakortit/savusaunaelamys-turvenaamiolla-ja-jalkakylvylla-kahdelle  (lahjakorttipaketti (/lahjakortti/#paketit))
--    44 saunavihta                               product_rental  /fi_FI/saunatuotteet/saunavihta  (vuokratuote/lisä, ei omaa kaupan sivua)
--    45 jalkakylpy-ja-turvenaamio                product_rental  /fi_FI/saunatuotteet/jalkakylpy-ja-turvenaamio  (vuokratuote/lisä, ei omaa kaupan sivua)
--    46 pyyhe-vuokralle                          product_rental  /fi_FI/saunatuotteet/pyyhe-vuokralle  (vuokratuote/lisä, ei omaa kaupan sivua)
--    47 tossut-saunatakki-vuokra                 product_rental  /fi_FI/yleinen-sauna/yleinensauna  (vuokratuote/lisä; Johku-osoite on yleisen saunan sivu)
--   50 yrityspaivat ja 82 virvoitusjuoma: booking_url tyhjä (NULL), ei muutettavaa.
--   kb.businesses.booking_url = https://sipoonjoenperinnesauna.johku.com/ (yrityksen yleinen varauslinkki, ei tuote; ei tässä paketissa)
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $m163$
declare
  r record; cur text; cur_slug text; k int; rc int; n int := 0; skip int := 0;
  ids bigint[] := '{}'; froms text[] := '{}'; tos text[] := '{}';
begin
  -- 1) tarkistus ennen yhtään muutosta: slug ennallaan ja booking_url TÄSMÄLLEEN odotettu (tai jo uusi → ohitus)
  for r in select * from (values
    (1, 'yleinensauna', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/yleinensauna', 'https://saunotus.fi/varaa/#/tuote/yleinensauna', '38b21ff95ded1500ef298664574e1711', '3c1ea95e45f74d98f525cd8dfbd1d7d7'),
    (2, 'miestensauna-2', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/miestensauna-2', 'https://saunotus.fi/varaa/#/tuote/miestensauna-2', '2724662449fe66bcc6663c0bbea8365b', '09fe7c426bc0fa87c5ca025f817d74ac'),
    (3, 'naistensauna', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/naistensauna', 'https://saunotus.fi/varaa/#/tuote/naistensauna', '8b12062fec23a5d01b8698f042c45da7', '79b2baa7c3936ddb07501ba6f6be8270'),
    (4, 'hiljainen-sauna', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/hiljainen-sauna', 'https://saunotus.fi/varaa/#/tuote/hiljainen-sauna', '20174df0e6910c22f6c4f321be20bc8d', 'c3a3bb270d9ae410959b533096609637'),
    (5, 'turvetorstai', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/turvetorstai', 'https://saunotus.fi/varaa/#/tuote/turvetorstai', 'a4631e8ae2f3a34f0326a169ebd312be', '821fef43dd3a40e8cbd30b4f9638f870'),
    (6, 'tunnin-vuoro', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/tunnin-vuoro', 'https://saunotus.fi/varaa/#/tuote/tunnin-vuoro', '40ecf273cdd2cd5fe1c0e57ce37ac699', '82071d9285b216ea0ebb4b147cc2238c'),
    (7, 'saunarituaali-ja-savusaunavuoro', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/saunarituaali-ja-savusaunavuoro', 'https://saunotus.fi/varaa/#/tuote/saunarituaali-ja-savusaunavuoro', '83d0ad1d0eb632339cb9f0b504bcdd51', 'e44d6f342ad36c5b57862de268ad1c7a'),
    (8, 'saunotusrituaali', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/saunotusrituaali', 'https://saunotus.fi/varaa/#/tuote/saunotusrituaali', '04ee683a467daf3d2338b363bb6486da', '74e26e64e4dfc1c79e15bfde84c0be5f'),
    (10, 'saunahoito-2', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/saunahoito-2', 'https://saunotus.fi/varaa/#/tuote/saunahoito-2', '8d54b072dda9b3d2ccc8340448d57cda', 'd7136fbd00d14ff14168d8408b4c895b'),
    (11, 'saunotus-2', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/saunotus-2', 'https://saunotus.fi/varaa/#/tuote/saunotus-2', '60590f97aa8208a1ebb0eef9df27ccc8', '8c8450c49b9f6f01b099f3210a715f7d'),
    (12, 'syvasaunotus', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/syvasaunotus', 'https://saunotus.fi/varaa/#/tuote/syvasaunotus', '241a3199c8520571acaf724dcc86eacb', '5166ad6e9cf7321443dea0dfc41ff1c2'),
    (25, 'oma-saunavuoro', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yksityisvuorot/oma-saunavuoro', 'https://saunotus.fi/varaa/#/tuote/oma-saunavuoro', '70392ea0b7f056d5ee91ce7b0ad95e34', '4c957cbf80e6096315fe1406ecd8b255'),
    (26, 'jalkiloylyt', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yksityisvuorot/jalkiloylyt', 'https://saunotus.fi/varaa/#/tuote/jalkiloylyt', '2df60a637b23a212054fff3548bffca0', '56a282747eae83e80446e8299a2fcde6'),
    (43, 'vuosikortti', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/sarja-ja-lahjakortit/vuosikortti', 'https://saunotus.fi/varaa/#/vuosikortti', '972129398d848f610f3e1391deeb6024', '49236d8aea7e6ab6f68c89cda568cdb1'),
    (48, 'saunavuoro-yrityksille', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yrityksille/saunavuoro-yrityksille', 'https://saunotus.fi/varaa/#/tuote/saunavuoro-yrityksille', 'df80c600df821bd7aaeb6d68cabb6c15', '9c03a4bb3b782cf44ac2878c4bfed570'),
    (49, 'jalkiloylyt-yrityksille', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yrityksille/jalkiloylyt-yrityksille', 'https://saunotus.fi/varaa/#/tuote/jalkiloylyt-yrityksille', '0cce4aea53a7f7f99b93fc5c3694c664', '3d6590e50cea015d7b7856c50351baeb')
  ) v(product_id, slug, from_url, to_url, from_md5, to_md5) loop
    if md5(r.from_url) <> r.from_md5 or md5(r.to_url) <> r.to_md5 then raise exception 'booking_163: sisäinen md5-virhe (tuote %)', r.product_id; end if;
    select p.booking_url, p.slug into cur, cur_slug from kb.products p where p.id = r.product_id;
    if not found then raise exception 'booking_163: kb.products id % puuttuu. Ei muutoksia.', r.product_id; end if;
    if cur_slug is distinct from r.slug then
      raise exception 'booking_163: kb.products id % slug on % (odotettu %). Ei muutoksia.', r.product_id, cur_slug, r.slug;
    end if;
    if cur is not distinct from r.to_url then skip := skip + 1; continue; end if;   -- jo ajettu (uudelleenajo ei tee mitään)
    if cur is distinct from r.from_url then
      raise exception 'booking_163: kb.products id % booking_url ei vastaa odotettua (md5 %, odotettu %). Ei muutoksia.', r.product_id, md5(coalesce(cur, '')), r.from_md5;
    end if;
    ids := ids || r.product_id; froms := froms || r.from_url; tos := tos || r.to_url;
  end loop;
  -- 2) päivitys (tarkka vertailu myös WHERE-ehdossa; trigger zz_site_text_sync kirjaa lukitun sivutekstin product.<id>.booking_url uuden version)
  for k in 1 .. coalesce(array_length(ids, 1), 0) loop
    update kb.products set booking_url = tos[k] where id = ids[k] and booking_url = froms[k];
    get diagnostics rc = row_count;
    if rc <> 1 then raise exception 'booking_163: päivitys epäonnistui (tuote %)', ids[k]; end if;
    n := n + 1;
  end loop;
  raise notice 'booking_163: päivitetty % booking_url-kenttää, jo valmiina %', n, skip;
end $m163$;
