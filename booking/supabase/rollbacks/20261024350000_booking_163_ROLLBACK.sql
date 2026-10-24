-- booking_163 ROLLBACK: palauttaa kb.products.booking_url-arvot Johku-osoitteiksi (16 tuotetta), tarkka vartija peilikuvana.
-- Ajo: vain jos 20261024350000_booking_163_booking_url_kauppaan.sql on ajettu. Jo palautettu arvo ohitetaan; muu poikkeama → exception, ei muutoksia.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $r163$
declare
  r record; cur text; cur_slug text; k int; rc int; n int := 0; skip int := 0;
  ids bigint[] := '{}'; froms text[] := '{}'; tos text[] := '{}';
begin
  -- 1) tarkistus ennen yhtään muutosta: slug ennallaan ja booking_url TÄSMÄLLEEN odotettu (tai jo uusi → ohitus)
  for r in select * from (values
    (1, 'yleinensauna', 'https://uusi.saunotus.com/varaa/#/tuote/yleinensauna', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/yleinensauna', '610d665fc16b620c63480110bf149e78', '38b21ff95ded1500ef298664574e1711'),
    (2, 'miestensauna-2', 'https://uusi.saunotus.com/varaa/#/tuote/miestensauna-2', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/miestensauna-2', '4563e0a3e6a29c2278570ca054d22da8', '2724662449fe66bcc6663c0bbea8365b'),
    (3, 'naistensauna', 'https://uusi.saunotus.com/varaa/#/tuote/naistensauna', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/naistensauna', 'b3e0d3911ba4ea3a3c22cb61567dd9ab', '8b12062fec23a5d01b8698f042c45da7'),
    (4, 'hiljainen-sauna', 'https://uusi.saunotus.com/varaa/#/tuote/hiljainen-sauna', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/hiljainen-sauna', 'c6f60f90e606bb65f75dce2a81333c41', '20174df0e6910c22f6c4f321be20bc8d'),
    (5, 'turvetorstai', 'https://uusi.saunotus.com/varaa/#/tuote/turvetorstai', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/turvetorstai', '669f3f79367d502fcec8b2e31829c7a9', 'a4631e8ae2f3a34f0326a169ebd312be'),
    (6, 'tunnin-vuoro', 'https://uusi.saunotus.com/varaa/#/tuote/tunnin-vuoro', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/tunnin-vuoro', '6cdc5b7f0774d933116f0eeb7f105698', '40ecf273cdd2cd5fe1c0e57ce37ac699'),
    (7, 'saunarituaali-ja-savusaunavuoro', 'https://uusi.saunotus.com/varaa/#/tuote/saunarituaali-ja-savusaunavuoro', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yleinen-sauna/saunarituaali-ja-savusaunavuoro', 'fd362662efbd513ddff246e1583a5e49', '83d0ad1d0eb632339cb9f0b504bcdd51'),
    (8, 'saunotusrituaali', 'https://uusi.saunotus.com/varaa/#/tuote/saunotusrituaali', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/saunotusrituaali', 'f899b8d7c53869d908bde7f76a5483cc', '04ee683a467daf3d2338b363bb6486da'),
    (10, 'saunahoito-2', 'https://uusi.saunotus.com/varaa/#/tuote/saunahoito-2', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/saunahoito-2', '25179591c7d9f3f13563bc305a18cf43', '8d54b072dda9b3d2ccc8340448d57cda'),
    (11, 'saunotus-2', 'https://uusi.saunotus.com/varaa/#/tuote/saunotus-2', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/saunotus-2', 'd568ece1a823438ccf129c2ae13ed32e', '60590f97aa8208a1ebb0eef9df27ccc8'),
    (12, 'syvasaunotus', 'https://uusi.saunotus.com/varaa/#/tuote/syvasaunotus', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/hoidot/syvasaunotus', '013816aa15a3cd2bd3c34943be6c39a6', '241a3199c8520571acaf724dcc86eacb'),
    (25, 'oma-saunavuoro', 'https://uusi.saunotus.com/varaa/#/tuote/oma-saunavuoro', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yksityisvuorot/oma-saunavuoro', '208858ee55d482eee7eec5d316210ad4', '70392ea0b7f056d5ee91ce7b0ad95e34'),
    (26, 'jalkiloylyt', 'https://uusi.saunotus.com/varaa/#/tuote/jalkiloylyt', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yksityisvuorot/jalkiloylyt', '2133c5ee642a15b3b7a346a40e4c34ad', '2df60a637b23a212054fff3548bffca0'),
    (43, 'vuosikortti', 'https://uusi.saunotus.com/varaa/#/vuosikortti', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/sarja-ja-lahjakortit/vuosikortti', 'f0743204db22b7af48d271a18675090c', '972129398d848f610f3e1391deeb6024'),
    (48, 'saunavuoro-yrityksille', 'https://uusi.saunotus.com/varaa/#/tuote/saunavuoro-yrityksille', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yrityksille/saunavuoro-yrityksille', '963adfaf096221bf79506bbc747ee839', 'df80c600df821bd7aaeb6d68cabb6c15'),
    (49, 'jalkiloylyt-yrityksille', 'https://uusi.saunotus.com/varaa/#/tuote/jalkiloylyt-yrityksille', 'https://sipoonjoenperinnesauna.johku.com/fi_FI/yrityksille/jalkiloylyt-yrityksille', 'c78ecc75a04bd517234704ec6eb91453', '0cce4aea53a7f7f99b93fc5c3694c664')
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
