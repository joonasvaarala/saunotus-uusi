-- booking_147: tuotteen kesto englanniksi kauppaan. booking.public_catalog() palauttaa lisäksi 'duration_text_en' (kb.products.duration_text_en)
-- ja hallinnan booking.admin_list_products() samoin (vain luku, kenttä näkyy hallinnan datassa; hallinnan näkymät jäävät suomeksi).
-- Sarake kb.products.duration_text_en (nullable text) + site_texts-rivit product.<id>.duration_text [en] (protected) on jo tuotannossa:
-- Bottiavustuksen migraatio kb_products_duration_text_en (versio 20261024121904, 24.10.2026). Tämä migraatio EI luo saraketta eikä muuta kb-dataa.
-- Pohjana viimeisimmät määritelmät: public_catalog = booking_64 (20261018112116), admin_list_products = booking_06 (20261016150006);
-- tarkistettu 24.10.2026 pg_get_functiondef-vertailulla, että tuotanto = repo. Muutos: vain uusi avain 'duration_text_en' heti 'duration_text':n jälkeen.
-- Ei hintojen, ALV:n, slugien, URL:ien eikä rivijoukon muutoksia. CREATE OR REPLACE säilyttää omistajan ja oikeudet (public_catalog: anon, authenticated,
-- service_role; admin_list_products: authenticated, service_role); security definer + search_path = '' ennallaan.
-- Paluu: booking/supabase/rollbacks/20261024230000_booking_147_ROLLBACK.sql.
set local lock_timeout = '5s';

do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'kb' and table_name = 'products' and column_name = 'duration_text_en') then
    raise exception 'booking_147: kb.products.duration_text_en puuttuu (aja ensin kb_products_duration_text_en)';
  end if;
end $$;

create or replace function booking.public_catalog() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_text_en', p.duration_text_en, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', case when pc.public_slots then booking._treatment_max_persons(p.id) else pc.max_persons end,
      'booking_kind', case when pc.public_slots then 'slots' else 'rules' end, 'slot_grid_minutes', case when pc.public_slots then 30 end,
      'options', booking._product_options_json(p.id, true), 'option_required', (pc.option_required and exists (select 1 from booking.product_options x where x.product_id = p.id and x.active)),
      'option_label', pc.option_label, 'option_label_en', pc.option_label_en,
      'voucher_note', pc.voucher_note, 'voucher_note_en', pc.voucher_note_en,
      'addons_enabled', (jsonb_array_length(booking._product_addon_codes(p.id)) > 0), 'allowed_addons', booking._product_addon_codes(p.id),
      'timeline', booking._timeline_json(p.id) -> 'segments', 'timeline_text', booking._timeline_json(p.id) ->> 'text', 'timeline_text_en', booking._timeline_json(p.id) ->> 'text_en'
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)) $$;

create or replace function booking.admin_list_products()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'external_id', p.external_id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en, 'category', p.category,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text, 'vat_rate', p.vat_rate,
      'duration_minutes', p.duration_minutes, 'duration_text', p.duration_text, 'duration_text_en', p.duration_text_en,
      'active', p.active, 'updated_at', p.updated_at,
      'config', (select to_jsonb(pc) - 'updated_at' from booking.product_config pc where pc.product_id = p.id),
      'variants', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'label', v.label, 'price', v.price,
                   'duration_minutes', v.duration_minutes, 'weekdays', v.weekdays, 'time_start', v.time_start, 'time_end', v.time_end,
                   'included_persons', v.included_persons, 'extra_person_price', v.extra_person_price,
                   'valid_from', v.valid_from, 'valid_to', v.valid_to, 'notes', v.notes, 'active', v.active) order by v.id)
                   from kb.product_price_variants v where v.product_id = p.id), '[]'::jsonb)
    ) order by (pc2.product_id is null), pc2.sort_order, p.id)
    from kb.products p left join booking.product_config pc2 on pc2.product_id = p.id), '[]'::jsonb);
end $$;
