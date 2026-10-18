create temp table pre64 as select booking.public_catalog() cat, booking.public_settings() st,
  (select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) prices,
  (select count(*) from booking.site_texts) ntexts, (select duration_text from kb.products where id = 7) dur7;
