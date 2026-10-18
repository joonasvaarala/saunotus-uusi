-- Saunatietoa: FEIKKIdata VAIN testiprojektille (jztczwrqtnpuolhcmktb), skeema booking. Ei tuotantoon. Vaatii migraation booking_51_articles.
-- Storage-objektit ovat vain metadatariveja (ei tiedostoja): kuvien URL:t eivät avaudu, joten rakennus käyttää alkuperäistä URL:ia varakuvana.
do $do$
declare a1 bigint; a2 bigint; a3 bigint; a4 bigint; a5 bigint; i12 bigint; i13 bigint; r jsonb;
begin
  r := booking.admin_upsert_article(null, $j${"slug_fi":"miten-saunotaan-oikein","title_fi":"Miten saunotaan oikein? Perinteinen opas","summary_fi":"Perinteinen saunominen on rauhallista: kolme kierrosta, riittävästi lepoa ja vettä. Tässä lyhyt opas ensikertalaiselle.","meta_description_fi":"Miten saunotaan oikein? Käytännön opas löylyyn, lepoon ja juomiseen perinnesaunassa. Lue ohjeet ja varaa oma saunahetkesi.","category":"saunominen","tags":["sauna","löyly","opas"],"featured":true,"author_name":"Testikirjoittaja","slug_en":"how-to-sauna","title_en":"How to sauna: a traditional guide","summary_en":"Traditional sauna bathing is calm: three rounds, enough rest and water. A short guide for first-timers.","meta_description_en":"How to sauna properly? A practical guide to heat, rest and hydration in a heritage sauna. Read the tips and book your own sauna moment.","content_fi":"Testidataa."}$j$::jsonb);
  a1 := (r->'article'->>'id')::bigint;
  r := booking.admin_upsert_article(null, $j${"slug_fi":"savusauna-vanha-nimi","title_fi":"Savusauna: lämmitys ja löylyn luonne","summary_fi":"Savusaunaa lämmitetään tunteja. Löyly on pehmeä ja tuoksu ainutlaatuinen. Testidataa.","meta_description_fi":"Savusauna on perinteinen tapa saunoa. Lue miten savusauna lämpiää ja miksi löyly on erilainen. Varaa vuoro.","category":"perinne","tags":["savusauna","perinne"],"content_fi":"Savusauna lämpiää."}$j$::jsonb);
  a2 := (r->'article'->>'id')::bigint;
  r := booking.admin_upsert_article(null, $j${"slug_fi":"noindex-testiartikkeli","title_fi":"Piilotettu testiartikkeli (noindex)","summary_fi":"Tämä artikkeli on noindex eikä kuulu sitemapiin. Testidataa.","meta_description_fi":"Noindex-testiartikkeli: ei hakukoneille, ei sitemapissa. Vain rakennuksen testausta varten, feikkidataa.","category":"hoidot","tags":["testi"],"noindex":true,"content_fi":"Noindex."}$j$::jsonb);
  a3 := (r->'article'->>'id')::bigint;
  r := booking.admin_upsert_article(null, $j${"slug_fi":"luonnos-ei-nay","title_fi":"Luonnos","content_fi":"x"}$j$::jsonb); a4 := (r->'article'->>'id')::bigint;
  r := booking.admin_upsert_article(null, $j${"slug_fi":"ajastettu-tulevaisuus","title_fi":"Ajastettu artikkeli","summary_fi":"Ajastettu.","meta_description_fi":"Ajastettu testiartikkeli joka julkaistaan vasta tulevaisuudessa, feikkidataa vain.","content_fi":"Ajastettu."}$j$::jsonb); a5 := (r->'article'->>'id')::bigint;
  insert into storage.objects(bucket_id, name, metadata) values
   ('article-images', 'articles/'||a1||'/1760000001-heroaaa1.jpg', '{"mimetype":"image/jpeg","size":1000}'),
   ('article-images', 'articles/'||a1||'/1760000002-kuvabbb2.jpg', '{"mimetype":"image/jpeg","size":1000}'),
   ('article-images', 'articles/'||a1||'/1760000003-kuvaccc3.jpg', '{"mimetype":"image/jpeg","size":1000}'),
   ('article-images', 'articles/'||a2||'/1760000004-heroddd4.jpg', '{"mimetype":"image/jpeg","size":1000}'),
   ('article-images', 'articles/'||a3||'/1760000005-heroeee5.jpg', '{"mimetype":"image/jpeg","size":1000}'),
   ('article-images', 'articles/'||a5||'/1760000006-heroffff6.jpg', '{"mimetype":"image/jpeg","size":1000}');
  r := booking.admin_register_article_image(a1, 'articles/'||a1||'/1760000001-heroaaa1.jpg', 1600, 900, 'Savusaunan lauteet ja lämmin valo', 'Wooden benches and warm light in a smoke sauna', 'Savusaunan lauteet', 'Smoke sauna benches', 1000, 'image/jpeg', 0, true);
  r := booking.admin_register_article_image(a1, 'articles/'||a1||'/1760000002-kuvabbb2.jpg', 1200, 800, 'Vihta ja vesisanko lauteilla', 'Birch whisk and water bucket on the bench', 'Vihta kuuluu perinteiseen saunomiseen', 'The whisk belongs to traditional bathing', 1000, 'image/jpeg', 1, false); i12 := (r->'image'->>'id')::bigint;
  r := booking.admin_register_article_image(a1, 'articles/'||a1||'/1760000003-kuvaccc3.jpg', 1200, 800, 'Lepohetki ulkona saunan jälkeen', 'Resting outdoors after sauna', null, null, 1000, 'image/jpeg', 2, false); i13 := (r->'image'->>'id')::bigint;
  r := booking.admin_register_article_image(a2, 'articles/'||a2||'/1760000004-heroddd4.jpg', 1600, 900, 'Savusauna metsän laidalla', null, null, null, 1000, 'image/jpeg', 0, true);
  r := booking.admin_register_article_image(a3, 'articles/'||a3||'/1760000005-heroeee5.jpg', 1600, 900, 'Noindex-testin kuva', null, null, null, 1000, 'image/jpeg', 0, true);
  r := booking.admin_register_article_image(a5, 'articles/'||a5||'/1760000006-heroffff6.jpg', 1600, 900, 'Ajastetun testin kuva', null, null, null, 1000, 'image/jpeg', 0, true);
  r := booking.admin_upsert_article(a1, jsonb_build_object('content_fi',
   E'Saunominen on **rauhoittumista**, ei suorittamista. Tässä oppaassa käydään läpi miten saunotaan oikein: löyly, lepo ja vesi. Tämä on feikkidataa testausta varten.\n\n## Ensimmäinen kierros\n\nMene lauteille rauhassa ja heitä löylyä vähän kerrallaan. Lue lisää [saunavuoroista](/saunavuorot/) tai [ulkoinen lähde](https://example.com/sauna).\n\n![kuva](img:'||i12||E')\n\n## Lepo ja juominen\n\n- Juo vettä saunan jälkeen\n- Lepää kunnes syke rauhoittuu\n- Älä kiirehdi\n\n### Vihta\n\nVihta tuoksuu *koivulta*. Kokeile yhdessä ystävän kanssa.\n\n> Hyvä sauna ei kiirehdi.\n\n![kuva](img:'||i13||E')\n\n## Usein kysyttyä\n\n**Kuinka monta kierrosta?**\nKolme on perinteinen määrä.\n\n---\n\n:::cta\n**Varaa oma saunahetkesi**\nSipoonjoen perinnesauna tarjoaa savusaunan ja hoidot. Valitse aika ja varaa verkossa.\n[Varaa aika](/varaa/)\n:::',
   'content_en', E'Sauna bathing is about **calming down**. This guide covers how to sauna properly. This is fake test data.\n\n## First round\n\nSit calmly and throw a little water at a time. See [sauna sessions](/en/sauna/).\n\n![img](img:'||i12||E')\n\n## Rest and hydration\n\n- Drink water after sauna\n- Rest until your pulse settles\n\n:::cta\n**Book your own sauna moment**\nSipoonjoki Heritage Sauna offers a smoke sauna and treatments. Choose a time and book online.\n[Book now](/en/book/)\n:::'));
  r := booking.admin_upsert_article(a2, jsonb_build_object('content_fi', E'Savusauna lämpiää useita tunteja. Tämä on feikkidataa.\n\n## Lämmitys\n\nPuut poltetaan kiukaassa ja savu poistetaan ennen saunomista.'));
  r := booking.admin_upsert_article(a3, jsonb_build_object('content_fi', E'Tämä noindex-artikkeli on testidataa.\n\n## Väliotsikko\n\nTeksti.'));
  perform booking.admin_publish_article(a1, now() - interval '3 days');
  perform booking.admin_publish_article(a2, now() - interval '2 days');
  perform booking.admin_publish_article(a3, now() - interval '1 days');
  perform booking.admin_publish_article(a5, now() + interval '30 days');
  perform booking.admin_upsert_article(a2, '{"slug_fi":"savusauna-lampiaminen"}'::jsonb);   -- vanha osoite → moved
end $do$;
select id, slug_fi, slug_en, status, published_at from booking.articles order by id;
