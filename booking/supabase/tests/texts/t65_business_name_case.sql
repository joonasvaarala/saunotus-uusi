do $t$
declare n int; bad int; res text; seq0 bigint; r record;
begin
  -- 13 muuttunutta riviä
  select count(*) into n from booking.site_texts t join pre65 p using (key, lang) where t.published_text is distinct from p.published_text;
  res := 'changed=' || n;
  -- vain kirjoitusasumuutos
  select count(*) into bad from booking.site_texts t join pre65 p using (key, lang) where t.published_text is distinct from p.published_text
     and replace(t.published_text, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna') is distinct from p.published_text;
  res := res || ' nonCaseChange=' || bad;
  select count(*) into bad from booking.site_texts t join pre65 p using (key, lang) where t.published_text is distinct from p.published_text and (t.published_version <> p.published_version + 1 or t.class <> p.class or t.placeholders <> p.placeholders or t.status <> 'published' or t.needs_review is distinct from p.needs_review);
  res := res || ' badVersionOrMeta=' || bad;
  select count(*) into bad from booking.site_text_versions v join booking.site_texts t on t.id = v.text_id join pre65 p using (key, lang) where t.published_text is distinct from p.published_text and v.version = t.published_version and v.status = 'published' and v.protected is distinct from (t.class = 'protected') ;
  res := res || ' protFlagMismatch=' || bad;
  select count(*) into bad from booking.site_texts t join pre65 p using (key, lang) where t.published_text is distinct from p.published_text and not exists (select 1 from booking.site_text_versions v where v.text_id = t.id and v.version = p.published_version and v.text = p.published_text);
  res := res || ' oldVersionLost=' || bad;
  res := res || ' remaining_old=' || (select count(*) from booking.site_texts where published_text like '%Sipoonjoen perinnesauna%') || ' remaining_old_src=' || (select count(*) from booking.site_texts where published_text like '%Sipoonjoen perinnesauna%' and source_table is not null);
  res := res || ' unchanged_others_ok=' || (select count(*) = 0 from booking.site_texts t join pre65 p using (key, lang) where t.published_text is distinct from p.published_text and p.published_text not like '%Sipoonjoen perinnesauna%');
  res := res || ' rows_total_same=' || ((select count(*) from booking.site_texts) = (select count(*) from pre65));
  res := res || ' pending=' || (select count(*) from booking.site_text_versions where status in ('draft', 'proposed', 'approved'));
  -- asetukset ja kb
  res := res || ' bn=' || (select value #>> '{}' from booking.settings where key = 'business_name');
  res := res || ' seller_only_case=' || ((select value from booking.settings where key = 'seller') = (select replace(seller::text, 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna')::jsonb from pre65s))
    || ' seller_legal=' || (select value ->> 'legal_name' || '/' || (value ->> 'business_id') || '/' || (value ->> 'vat_id') from booking.settings where key = 'seller')
    || ' seller_name=' || (select value ->> 'name' from booking.settings where key = 'seller');
  res := res || ' biz_other_cols_same=' || ((select (row_to_json(b)::jsonb - 'trade_name' - 'description' - 'updated_at') from kb.businesses b where id = 1) = (select biz - 'trade_name' - 'description' - 'updated_at' from pre65s))
    || ' biz_trade=' || (select trade_name from kb.businesses where id = 1);
  res := res || ' prices_same=' || ((select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) = (select prices from pre65s))
    || ' locked=' || (select count(*) from booking.site_texts where class = 'locked')
    || ' drift=' || jsonb_array_length(booking.admin_texts_drift() -> 'drift')
    || ' audit_new=' || ((select count(*) from booking.audit_log) - (select naudit from pre65s))
    || ' public_old=' || (select count(*) from jsonb_array_elements(booking.public_get_site_texts() -> 'texts') x where x ->> 'text' like '%Sipoonjoen perinnesauna%')
    || ' public_new=' || (select count(*) from jsonb_array_elements(booking.public_get_site_texts() -> 'texts') x where x ->> 'text' like '%Sipoonjoen Perinnesauna%');
  raise exception 'RESULT %', res;
end $t$;
