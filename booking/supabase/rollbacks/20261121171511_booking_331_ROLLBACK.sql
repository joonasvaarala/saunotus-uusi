-- booking_331 ROLLBACK: palauttaa booking_330:n funktiot (ei kattoa) ja poistaa sarakkeen redeem_cover_max.
set local lock_timeout = '5s';
create or replace function booking._gc_rules_json(p_code text) returns jsonb
language sql stable security definer set search_path to '' as $f$
  select case when p.redeem_product_ids is null and p.redeem_weekdays is null then null else
    jsonb_build_object('product_ids', to_jsonb(p.redeem_product_ids), 'weekdays', to_jsonb(p.redeem_weekdays),
      'covers_base', p.redeem_covers_base, 'note', p.redeem_note, 'note_en', p.redeem_note_en,
      'products', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'slug', k.slug, 'name', k.name, 'name_en', k.name_en) order by k.id), '[]'::jsonb)
                     from kb.products k where k.id = any (p.redeem_product_ids))) end
    from booking.gift_card_packages p where p.code = p_code
$f$;

create or replace function booking._gc_redeem_rules(p_order_id bigint, p_card_id bigint) returns numeric
language plpgsql security definer set search_path to '' as $f$
declare g booking.gift_cards; pk booking.gift_card_packages; it booking.order_items; v_pb jsonb; v_base numeric; v_amt numeric;
begin
  select * into g from booking.gift_cards where id = p_card_id;
  if g.package_code is null then return 0; end if;
  select * into pk from booking.gift_card_packages where code = g.package_code;
  if pk.code is null or (pk.redeem_product_ids is null and pk.redeem_weekdays is null) then return 0; end if;
  select oi.* into it
    from booking.order_items oi
    join booking.reservations r on r.order_item_id = oi.id and r.order_id = oi.order_id
   where oi.order_id = p_order_id and oi.kind = 'reservation'
     and r.status in ('pending', 'confirmed', 'completed')
     and (pk.redeem_product_ids is null or oi.product_id = any (pk.redeem_product_ids))
     and (pk.redeem_weekdays is null or extract(isodow from (r.starts_at at time zone booking._tz()))::int = any (pk.redeem_weekdays))
   order by (coalesce(oi.price_breakdown, '{}'::jsonb) ? 'gift_cover'), oi.id
   limit 1
   for update of oi;
  if it.id is null then
    perform booking._err('gift_card_not_applicable', coalesce(nullif(btrim(pk.redeem_note), ''), 'Lahjakortti ei käy tähän varaukseen'));
  end if;
  if not pk.redeem_covers_base or coalesce(it.price_breakdown, '{}'::jsonb) ? 'gift_cover' then return 0; end if;
  if it.discount_code_id is not null then
    perform booking._err('gift_card_not_applicable', 'Tätä lahjakorttia ei voi käyttää yhdessä alennuskoodin kanssa');
  end if;
  v_pb := coalesce(it.price_breakdown, '{}'::jsonb);
  v_base := case when v_pb ->> 'mode' = 'fixed_plus_extra' and coalesce(v_pb ->> 'base', '') ~ '^\d+(\.\d+)?$'
                 then (v_pb ->> 'base')::numeric - coalesce(nullif(v_pb #>> '{quiet,amount}', '')::numeric, 0)
                 else it.line_total_gross end;
  v_base := least(greatest(v_base, 0), coalesce(it.line_total_gross, 0));
  v_amt := round(greatest(v_base - g.initial_amount, 0), 2);
  if v_amt <= 0 then return 0; end if;
  update booking.order_items
     set line_total_gross = line_total_gross - v_amt, discount_amount = coalesce(discount_amount, 0) + v_amt,
         price_breakdown = v_pb || jsonb_build_object('gift_cover', jsonb_build_object('gift_card_id', g.id, 'package', pk.code,
           'base', v_base, 'card_value', g.initial_amount, 'amount', v_amt, 'at', now()))
   where id = it.id;
  update booking.orders set total_gross = total_gross - v_amt where id = p_order_id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.order_items', it.id::text, 'GIFT_CARD_COVER',
          jsonb_build_object('line_total_gross', it.line_total_gross, 'discount_amount', it.discount_amount),
          jsonb_build_object('order_id', p_order_id, 'gift_card_id', g.id, 'package', pk.code, 'base', v_base, 'card_value', g.initial_amount, 'amount', v_amt));
  return v_amt;
end $f$;

alter table booking.gift_card_packages drop constraint if exists gift_card_packages_redeem_cover_max_check;
alter table booking.gift_card_packages drop column if exists redeem_cover_max;
notify pgrst, 'reload schema';
