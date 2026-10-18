-- booking_65_business_name_case: yrityksen nimen kirjoitusasu "Sipoonjoen Perinnesauna" (iso P; päätös Joonas 18.10.2026).
-- Vain nimen kirjoitusasu: ei muutu Havuhattu Oy:n tiedot, y-tunnus, hinnat, lukitut rivit. Idempotentti.
-- Lähdetauluun sidotut tekstit päivitetään lähdesarakkeesta (trigger zz_site_text_sync kirjaa uuden version + audit TEXT_DIRECT_EDIT);
-- vapaat avaimet (seo.book.description/fi, ui.gift.marketing/fi, ui.shop.consent_marketing/fi) ehdotus + hyväksyntä + julkaisu RPC:illä (versiohistoria + audit).
set local lock_timeout = '5s';
set local statement_timeout = '60s';

update booking.settings set value = to_jsonb(replace(value #>> '{}', 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna'))
 where key = 'business_name' and jsonb_typeof(value) = 'string' and (value #>> '{}') like '%Sipoonjoen perinnesauna%';
update booking.settings set value = replace(value::text, 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna')::jsonb
 where key = 'seller' and value::text like '%Sipoonjoen perinnesauna%';

update kb.businesses set trade_name = replace(trade_name, 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna'),
                         description = replace(description, 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna')
 where id = 1 and (trade_name like '%Sipoonjoen perinnesauna%' or description like '%Sipoonjoen perinnesauna%');
update kb.faq set answer = replace(answer, 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna') where id in (13, 14) and answer like '%Sipoonjoen perinnesauna%';
update kb.locations set name = replace(name, 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna') where id = 1 and name like '%Sipoonjoen perinnesauna%';
update kb.policies set body = replace(body, 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna') where id in (1, 7, 8, 25, 26) and body like '%Sipoonjoen perinnesauna%';
update kb.products set description = replace(description, 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna') where id = 25 and description like '%Sipoonjoen perinnesauna%';

do $$
declare r record; v jsonb;
begin
  for r in select key, lang, published_text from booking.site_texts
            where key in ('seo.book.description', 'ui.gift.marketing', 'ui.shop.consent_marketing') and lang = 'fi' and source_table is null and published_text like '%Sipoonjoen perinnesauna%' loop
    v := booking.texts_propose(r.key, r.lang, replace(r.published_text, 'Sipoonjoen perinnesauna', 'Sipoonjoen Perinnesauna'), 'Yrityksen nimen kirjoitusasu yhtenäistetty: Sipoonjoen Perinnesauna (päätös Joonas 18.10.2026); vain isot/pienet kirjaimet', false);
    perform booking.admin_texts_approve((v ->> 'version_id')::bigint, 'Kirjoitusasumuutos (Joonas 18.10.2026)', true);
  end loop;
end $$;
