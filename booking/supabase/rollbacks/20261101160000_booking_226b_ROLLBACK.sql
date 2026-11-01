-- ROLLBACK booking_226b. Palauttaa booking_226:n funktiot (uudelleenajo) ja poistaa osakerrat.
-- Ei poista booking_226:ta. Uudelleenajettava.
set local lock_timeout = '5s';

\ir ../migrations/20261101143000_booking_226_training_signup.sql

drop function if exists booking._training_hold_segment(bigint, bigint, timestamptz);
drop function if exists booking._training_option_seats_left(bigint);
drop function if exists booking._training_rule_seats_left(bigint);
drop function if exists booking._training_segment_json(bigint);
drop function if exists booking._training_segment_ids(bigint);
drop function if exists booking._training_segments_of(bigint);

-- booking_226 ei koske _product_addon_codes-funktioon. Palauta booking_64:n runko (ei koulutuksen tyhjennystä).
create or replace function booking._product_addon_codes(p_product_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare pc booking.product_config; v_cat text; v_modes text[];
begin
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found then return '[]'::jsonb; end if;
  select category into v_cat from kb.products where id = p_product_id;
  if v_cat = 'event' then return '[]'::jsonb; end if;
  if pc.public_slots or (pc.sale_kind = 'other' and pc.resource_class = 'resourced') then
    return coalesce((select jsonb_agg(a.code order by a.sort_order, a.id) from booking.product_addon_allow pa join booking.addons a on a.id = pa.addon_id
                      where pa.product_id = p_product_id and a.active and 'resource' = any (a.applies_modes)), '[]'::jsonb);
  end if;
  select array_agg(distinct r.mode::text) into v_modes from booking.schedule_rules r where r.product_id = p_product_id and r.active;
  return coalesce((select jsonb_agg(a.code order by a.sort_order, a.id) from booking.addons a where a.active and a.applies_modes && coalesce(v_modes, '{}'::text[])), '[]'::jsonb);
end $$;
drop function if exists booking.admin_training_segments_get(bigint);
drop function if exists booking.admin_training_segments_set(bigint, bigint[]);
drop table if exists booking.training_segments;
alter table booking.training_participants drop column if exists segments;
alter table booking.schedule_rules drop column if exists training_segment_only;
