-- PALUU booking_147 (kesto englanniksi kauppaan). Palauttaa booking_147:ää edeltävät määritelmät täsmälleen
-- (public_catalog = booking_64, admin_list_products = booking_06; tekstit = tuotannon pg_get_functiondef 24.10.2026,
-- md5(pg_get_functiondef): public_catalog 0cd7d46e6d9bb24499e1b2ab6e334587, admin_list_products 7a881ee43d8231528c5a05f8359da540).
-- Ei koske saraketta kb.products.duration_text_en eikä site_texts-rivejä (ne kuuluvat Bottiavustuksen migraatiolle kb_products_duration_text_en
-- ja sen omalle paluulle). CREATE OR REPLACE säilyttää oikeudet. Kaupan frontend toimii paluun jälkeen: duration_text_en puuttuu → duration_text.
set local lock_timeout = '5s';

CREATE OR REPLACE FUNCTION booking.public_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_minutes', p.duration_minutes,
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
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)) $function$
;

CREATE OR REPLACE FUNCTION booking.admin_list_products()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'external_id', p.external_id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en, 'category', p.category,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text, 'vat_rate', p.vat_rate,
      'duration_minutes', p.duration_minutes, 'duration_text', p.duration_text,
      'active', p.active, 'updated_at', p.updated_at,
      'config', (select to_jsonb(pc) - 'updated_at' from booking.product_config pc where pc.product_id = p.id),
      'variants', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'label', v.label, 'price', v.price,
                   'duration_minutes', v.duration_minutes, 'weekdays', v.weekdays, 'time_start', v.time_start, 'time_end', v.time_end,
                   'included_persons', v.included_persons, 'extra_person_price', v.extra_person_price,
                   'valid_from', v.valid_from, 'valid_to', v.valid_to, 'notes', v.notes, 'active', v.active) order by v.id)
                   from kb.product_price_variants v where v.product_id = p.id), '[]'::jsonb)
    ) order by (pc2.product_id is null), pc2.sort_order, p.id)
    from kb.products p left join booking.product_config pc2 on pc2.product_id = p.id), '[]'::jsonb);
end $function$
;
