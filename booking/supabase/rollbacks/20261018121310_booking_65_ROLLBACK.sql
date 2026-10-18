-- Rollback booking_65: palauttaa nimen pienellä p:llä asetuksiin ja kb-lähteisiin; teksteille julkaistaan vanha sisältö uusina versioina (admin_texts_rollback), versiohistoria säilyy.
set local lock_timeout = '5s';
update booking.settings set value = to_jsonb(replace(value #>> '{}', 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna')) where key = 'business_name' and jsonb_typeof(value) = 'string';
update booking.settings set value = replace(value::text, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna')::jsonb where key = 'seller';
update kb.businesses set trade_name = replace(trade_name, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna'), description = replace(description, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna') where id = 1;
update kb.faq set answer = replace(answer, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna') where id in (13, 14);
update kb.locations set name = replace(name, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna') where id = 1;
update kb.policies set body = replace(body, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna') where id in (1, 7, 8, 25) or (id = 26);
update kb.products set description = replace(description, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna') where id = 25;
do $$
declare r record; v jsonb;
begin
  for r in select key, lang, published_text from booking.site_texts where key in ('seo.book.description', 'ui.gift.marketing', 'ui.shop.consent_marketing') and lang = 'fi' and source_table is null and published_text like '%Sipoonjoen Perinnesauna%' loop
    v := booking.texts_propose(r.key, r.lang, replace(r.published_text, 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna'), 'Rollback booking_65', false);
    perform booking.admin_texts_approve((v ->> 'version_id')::bigint, 'Rollback booking_65', true);
  end loop;
end $$;
