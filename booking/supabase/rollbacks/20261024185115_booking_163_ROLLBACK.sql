-- booking_163 ROLLBACK: palauttaa kb.products.booking_url-arvot Johku-osoitteiksi (16 tuotetta), tarkka vartija peilikuvana.
-- Ajo: vain jos 20261024185115_booking_163_booking_url_kauppaan.sql on ajettu. Jo palautettu arvo ohitetaan; muu poikkeama → exception, ei muutoksia.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $r163$
declare
  r record; cur text; cur_slug text; k int; rc int; n int := 0; skip int := 0;
  ids bigint[] := '{}'; froms text[] := '{}'; tos text[] := '{}';
begin
  -- 1) tarkistus ennen yhtään muutosta: slug ennallaan ja booking_url TÄSMÄLLEEN odotettu (tai jo uusi → ohitus)
  for r in select * from (values
    (1, 'yleinensauna', 'https://saunotus.fi/varaa/#/tuote/yleinensauna', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/yleinensauna', '3c1ea95e45f74d98f525cd8dfbd1d7d7', '38b21ff95ded1500ef298664574e1711'),
    (2, 'miestensauna-2', 'https://saunotus.fi/varaa/#/tuote/miestensauna-2', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/miestensauna-2', '09fe7c426bc0fa87c5ca025f817d74ac', '2724662449fe66bcc6663c0bbea8365b'),
    (3, 'naistensauna', 'https://saunotus.fi/varaa/#/tuote/naistensauna', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/naistensauna', '79b2baa7c3936ddb07501ba6f6be8270', '8b12062fec23a5d01b8698f042c45da7'),
    (4, 'hiljainen-sauna', 'https://saunotus.fi/varaa/#/tuote/hiljainen-sauna', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/hiljainen-sauna', 'c3a3bb270d9ae410959b533096609637', '20174df0e6910c22f6c4f321be20bc8d'),
    (5, 'turvetorstai', 'https://saunotus.fi/varaa/#/tuote/turvetorstai', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/turvetorstai', '821fef43dd3a40e8cbd30b4f9638f870', 'a4631e8ae2f3a34f0326a169ebd312be'),
    (6, 'tunnin-vuoro', 'https://saunotus.fi/varaa/#/tuote/tunnin-vuoro', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/tunnin-vuoro', '82071d9285b216ea0ebb4b147cc2238c', '40ecf273cdd2cd5fe1c0e57ce37ac699'),
    (7, 'saunarituaali-ja-savusaunavuoro', 'https://saunotus.fi/varaa/#/tuote/saunarituaali-ja-savusaunavuoro', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/saunarituaali-ja-savusaunavuoro', 'e44d6f342ad36c5b57862de268ad1c7a', '83d0ad1d0eb632339cb9f0b504bcdd51'),
    (8, 'saunotusrituaali', 'https://saunotus.fi/varaa/#/tuote/saunotusrituaali', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/saunotusrituaali', '74e26e64e4dfc1c79e15bfde84c0be5f', '04ee683a467daf3d2338b363bb6486da'),
    (10, 'saunahoito-2', 'https://saunotus.fi/varaa/#/tuote/saunahoito-2', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/saunahoito-2', 'd7136fbd00d14ff14168d8408b4c895b', '8d54b072dda9b3d2ccc8340448d57cda'),
    (11, 'saunotus-2', 'https://saunotus.fi/varaa/#/tuote/saunotus-2', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/saunotus-2', '8c8450c49b9f6f01b099f3210a715f7d', '60590f97aa8208a1ebb0eef9df27ccc8'),
    (12, 'syvasaunotus', 'https://saunotus.fi/varaa/#/tuote/syvasaunotus', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/syvasaunotus', '5166ad6e9cf7321443dea0dfc41ff1c2', '241a3199c8520571acaf724dcc86eacb'),
    (25, 'oma-saunavuoro', 'https://saunotus.fi/varaa/#/tuote/oma-saunavuoro', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yksityisvuorot/oma-saunavuoro', '4c957cbf80e6096315fe1406ecd8b255', '70392ea0b7f056d5ee91ce7b0ad95e34'),
    (26, 'jalkiloylyt', 'https://saunotus.fi/varaa/#/tuote/jalkiloylyt', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yksityisvuorot/jalkiloylyt', '56a282747eae83e80446e8299a2fcde6', '2df60a637b23a212054fff3548bffca0'),
    (43, 'vuosikortti', 'https://saunotus.fi/varaa/#/vuosikortti', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/sarja-ja-lahjakortit/vuosikortti', '49236d8aea7e6ab6f68c89cda568cdb1', '972129398d848f610f3e1391deeb6024'),
    (48, 'saunavuoro-yrityksille', 'https://saunotus.fi/varaa/#/tuote/saunavuoro-yrityksille', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yrityksille/saunavuoro-yrityksille', '9c03a4bb3b782cf44ac2878c4bfed570', 'df80c600df821bd7aaeb6d68cabb6c15'),
    (49, 'jalkiloylyt-yrityksille', 'https://saunotus.fi/varaa/#/tuote/jalkiloylyt-yrityksille', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yrityksille/jalkiloylyt-yrityksille', '3d6590e50cea015d7b7856c50351baeb', '0cce4aea53a7f7f99b93fc5c3694c664')
  ) v(product_id, slug, from_url, to_url, from_md5, to_md5) loop
    if md5(r.from_url) <> r.from_md5 or md5(r.to_url) <> r.to_md5 then raise exception 'booking_163 ROLLBACK: sisäinen md5-virhe (tuote %)', r.product_id; end if;
    select p.booking_url, p.slug into cur, cur_slug from kb.products p where p.id = r.product_id;
    if not found then raise exception 'booking_163 ROLLBACK: kb.products id % puuttuu. Ei muutoksia.', r.product_id; end if;
    if cur_slug is distinct from r.slug then
      raise exception 'booking_163 ROLLBACK: kb.products id % slug on % (odotettu %). Ei muutoksia.', r.product_id, cur_slug, r.slug;
    end if;
    if cur is not distinct from r.to_url then skip := skip + 1; continue; end if;   -- jo ajettu (uudelleenajo ei tee mitään)
    if cur is distinct from r.from_url then
      raise exception 'booking_163 ROLLBACK: kb.products id % booking_url ei vastaa odotettua (md5 %, odotettu %). Ei muutoksia.', r.product_id, md5(coalesce(cur, '')), r.from_md5;
    end if;
    ids := ids || r.product_id; froms := froms || r.from_url; tos := tos || r.to_url;
  end loop;
  -- 2) päivitys (tarkka vertailu myös WHERE-ehdossa; trigger zz_site_text_sync kirjaa lukitun sivutekstin product.<id>.booking_url uuden version)
  for k in 1 .. coalesce(array_length(ids, 1), 0) loop
    update kb.products set booking_url = tos[k] where id = ids[k] and booking_url = froms[k];
    get diagnostics rc = row_count;
    if rc <> 1 then raise exception 'booking_163 ROLLBACK: päivitys epäonnistui (tuote %)', ids[k]; end if;
    n := n + 1;
  end loop;
  raise notice 'booking_163 ROLLBACK: päivitetty % booking_url-kenttää, jo valmiina %', n, skip;
end $r163$;
