create temp table pre65 as select key, lang, class, published_text, published_version, placeholders, status, needs_review from booking.site_texts;
create temp table pre65s as select (select value from booking.settings where key='business_name') bn, (select value from booking.settings where key='seller') seller, (select row_to_json(b)::jsonb from kb.businesses b where id=1) biz,
  (select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) prices,
  (select count(*) from booking.audit_log) naudit;
