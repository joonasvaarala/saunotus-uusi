create temp table pre61 as select booking.public_catalog() cat, booking.public_settings() st, booking.public_addons() ad,
  (select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) prices,
  (select description from kb.products where id = 7) d7, (select count(*) from booking.site_texts) ntexts;
