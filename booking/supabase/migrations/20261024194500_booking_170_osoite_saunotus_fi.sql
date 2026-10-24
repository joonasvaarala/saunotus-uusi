-- booking_170_osoite_saunotus_fi: kb.productsin tallennetut osoitteet vanhasta kehitysosoitteesta → https://saunotus.fi.
-- Joonas 24.10.2026: uusi sivusto on 1.11.2026 alkaen osoitteessa saunotus.fi; vanha kehityssivusto ei kuulu uuteen sivustoon.
-- Koodi (booking/shop/src/johku-links.js CANONICAL, src/lib.mjs SHOP_CANON) tunnistaa tämän PR:n jälkeen vain https://saunotus.fi -osoitteet,
-- joten tämä migraatio ajetaan SAMAAN AIKAAN kuin PR yhdistetään (ks. docs/siirto-saunotus-fi.md, vaihe A).
-- Kohteet tuotannossa 24.10.2026 (SELECT): 11 kenttää 7 tuotteessa, 31 osoitetta. Mikään kentistä ei sisällä ennestään saunotus.fi-merkkijonoa,
-- joten rollback voi palauttaa täsmälleen (sama vartija peilikuvana).
-- Vartija: jos kentässä on vanha osoite, sen md5 on oltava täsmälleen odotettu, muuten exception ennen yhtään muutosta. Kenttä, jossa vanhaa
-- osoitetta ei ole (jo ajettu tai tyhjä kanta), ohitetaan (uudelleenajettava). Lopuksi tarkistetaan, ettei kb.productsiin jäänyt vanhaa osoitetta.
-- Lukitut sivutekstit (booking.site_texts product.<id>.description) saavat uuden version triggeristä zz_site_text_sync (kuten booking_161).
-- Historia (kb.change_log, booking.audit_log, booking.site_text_versions) jätetään ennalleen.
-- Rollback: booking/supabase/rollbacks/20261024194500_booking_170_ROLLBACK.sql
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $mfi$
declare
  old_base constant text := 'https://uusi.saunotus.com';
  new_base constant text := 'https://saunotus.fi';
  r record; cur text; cnt int; n int := 0; skip int := 0; left_n int;
begin
  for r in select * from (values
    (1, 'description', 1, '75312781e1c3861c69c0112428ebf5f1', 'f0561a9145ea81e3854f1123fa714f0e'),
    (1, 'description_en', 1, '6a13d49ee1062e4daa24e06eb7e3d5ab', 'd54cfa6c0285dff0ef8e0798d641a971'),
    (7, 'description', 1, 'f2dde2a51904c4cdef62b32a0a9f2416', '902eab3acb73ea0cd05fc2b52721d86e'),
    (7, 'description_en', 1, '3a71fb4a777706c5aa35971402163309', 'c2ff0e24d34dd0a92c591f3fa06072e4'),
    (25, 'description', 1, 'f800f8b84a5ff1a2644c33c8b5a5dbdd', '997d7234a1018e3e6cbddcf2b9c2e0a9'),
    (25, 'description_en', 1, 'daf48be5d93eb6c82061309e757bb329', '6815e2c9830f476b691b719905c507dc'),
    (26, 'description', 1, '7a97893d31f62f1fe0fcc0970ac4f256', 'd66c8a9d9764ae632f71e6a1c3193500'),
    (26, 'description_en', 1, 'db2bef46783a45b5a3540509dca42c51', '55c23bdd08657f938654a921ec467685'),
    (38, 'description', 11, '311d6c639941a129d4c19c50cd6c0653', '9daeb541dd2d9979e2253fcdc876c6b7'),
    (38, 'description_en', 11, '515737aa1a9c3c7b8130da0a7e97132f', '9ff3964455b08b596172e47ab42c0f91'),
    (50, 'source_url', 1, '2161d42f25636101c92bdb11b8891b00', '75d6af77b63c3b473172ea2c99da3073')
  ) v(product_id, col, occurrences, from_md5, to_md5) loop
    if r.col not in ('description', 'description_en', 'source_url') then raise exception 'booking_170: sarake % ei sallittu', r.col; end if;
    execute format('select %I from kb.products where id = $1', r.col) into cur using r.product_id;
    -- jo ajettu tai kentässä ei vanhaa osoitetta (esim. tyhjä kanta, jossa booking_161 kirjoitti suoraan saunotus.fi-osoitteet) → ohitetaan
    if cur is null or md5(cur) = r.to_md5 or position(old_base in cur) = 0 then skip := skip + 1; continue; end if;
    if md5(cur) <> r.from_md5 then
      raise exception 'booking_170: tuote % % on muuttunut (md5 %, odotettu %) – ei muutoksia', r.product_id, r.col, md5(cur), r.from_md5;
    end if;
    cnt := (length(cur) - length(replace(cur, old_base, ''))) / length(old_base);
    if cnt <> r.occurrences or position(new_base in cur) > 0 then
      raise exception 'booking_170: tuote % %: % osoitetta (odotettu %) tai jo uutta osoitetta', r.product_id, r.col, cnt, r.occurrences;
    end if;
    if md5(replace(cur, old_base, new_base)) <> r.to_md5 then raise exception 'booking_170: sisäinen md5-virhe (tuote %, %)', r.product_id, r.col; end if;
  end loop;

  for r in select * from (values
    (1, 'description', 1, '75312781e1c3861c69c0112428ebf5f1', 'f0561a9145ea81e3854f1123fa714f0e'),
    (1, 'description_en', 1, '6a13d49ee1062e4daa24e06eb7e3d5ab', 'd54cfa6c0285dff0ef8e0798d641a971'),
    (7, 'description', 1, 'f2dde2a51904c4cdef62b32a0a9f2416', '902eab3acb73ea0cd05fc2b52721d86e'),
    (7, 'description_en', 1, '3a71fb4a777706c5aa35971402163309', 'c2ff0e24d34dd0a92c591f3fa06072e4'),
    (25, 'description', 1, 'f800f8b84a5ff1a2644c33c8b5a5dbdd', '997d7234a1018e3e6cbddcf2b9c2e0a9'),
    (25, 'description_en', 1, 'daf48be5d93eb6c82061309e757bb329', '6815e2c9830f476b691b719905c507dc'),
    (26, 'description', 1, '7a97893d31f62f1fe0fcc0970ac4f256', 'd66c8a9d9764ae632f71e6a1c3193500'),
    (26, 'description_en', 1, 'db2bef46783a45b5a3540509dca42c51', '55c23bdd08657f938654a921ec467685'),
    (38, 'description', 11, '311d6c639941a129d4c19c50cd6c0653', '9daeb541dd2d9979e2253fcdc876c6b7'),
    (38, 'description_en', 11, '515737aa1a9c3c7b8130da0a7e97132f', '9ff3964455b08b596172e47ab42c0f91'),
    (50, 'source_url', 1, '2161d42f25636101c92bdb11b8891b00', '75d6af77b63c3b473172ea2c99da3073')
  ) v(product_id, col, occurrences, from_md5, to_md5) loop
    execute format('update kb.products set %1$I = replace(%1$I, $1, $2) where id = $3 and md5(%1$I) = $4', r.col)
      using old_base, new_base, r.product_id, r.from_md5;
    get diagnostics cnt = row_count;
    n := n + cnt;
  end loop;

  select count(*) into left_n from kb.products
   where concat_ws(' ', description, description_en, short_description, short_description_en, booking_url, source_url) like '%' || old_base || '%';
  if left_n > 0 then raise exception 'booking_170: kb.productsiin jäi % riviä vanhalla osoitteella', left_n; end if;
  raise notice 'booking_170: päivitetty % kenttää, ohitettu % (jo ajettu)', n, skip;
end
$mfi$;
