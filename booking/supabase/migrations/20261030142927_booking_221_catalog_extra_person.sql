-- booking_221: public_catalog palauttaa included_persons ja extra_person_price.
-- Hoitokassa (public_create_treatment_booking → booking._treatment_price) lukee VAIN kb.products:
--   per_person: price * henkilömäärä
--   muuten: price + extra_person_price * greatest(henkilömäärä - coalesce(included_persons, henkilömäärä), 0)
-- Vuorokassa on eri lähde (_rule_price / _sessions): perushinta coalesce(kb.product_price_variants.price, kb.products.price),
-- lisähenkilö coalesce(schedule_rules, variant, product). Yhdellä tuotteella on monta sääntöä, eikä niitä voi
-- tiivistää yhdeksi katalogiriviksi muuttamatta näytettyä hintaa. Katalogin price on jo p.price (ei varianttia, ei sääntöä).
-- Siksi nämä kaksi kenttää tulevat samoista kb.products-sarakkeista kuin _treatment_price, jotta hoitotuotteen
-- näytetty summa = kassan summa (esim. saunahoito 2 hlö = 99 + 35 = 134). Hintoja, price- eikä price_type-arvoja ei muuteta.
-- Paluu: booking/supabase/rollbacks/20261030142927_booking_221_ROLLBACK.sql (palauttaa booking_158:n public_catalogin).
-- Ajettu: DEV 20261030142905, PROD 20261030142927 (tiedostonimi = PROD-versio).
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
      'short_description', p.short_description, 'short_description_en', p.short_description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'included_persons', p.included_persons, 'extra_person_price', p.extra_person_price,
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
    -- booking_158: vain kauppa-kanavan tuotteet; tapahtumat ja koulutukset vasta kun events.sale_enabled = true
    and 'shop' = any (booking._channels_effective(pc.channels, p.category))
    and (p.category not in ('event', 'training') or booking._events_sale_enabled())
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)) $function$;
