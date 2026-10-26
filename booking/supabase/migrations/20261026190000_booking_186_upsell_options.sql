-- booking_186: ehdotuksiin mukaan tuotteet, jotka vaativat valinnan (Saunahoito, product_options).
-- _upsell_options ei enää suodata option_required-tuotteita pois. Payloadiin tulee option_required,
-- option_label(_en) ja options[]: id, code, name, name_en, price_delta.
-- product_options-taulussa ei ole hintasaraketta (booking_50: ei hintaeroa), joten price_delta on null.
-- _upsell_attach_reservation saa p_option_id (viimeinen, oletus null) ja välittää koodin _create_legs_bookingille.
-- public_upsell_checkout_attach lukee rivin option_id:n. Tilaussivun public_upsell_add välittää option_coden
-- jo public_add_to_orderille; sitä ei korvata, jotta laskutuslukko (booking_185) pysyy ennallaan.
-- Laskutettu tilaus jää kiinni: _create_legs_booking kutsuu _order_invoice_locked ja nostaa order_invoiced.
-- Vartija: md5(pg_get_functiondef) = nykyinen tuotanto, muuten RAISE. Näitä md5-arvoja EI ole vahvistettu
-- tästä työtilasta (ei tietokantayhteyttä). Dry run Tapio-devissä tulostaa todellisen md5:n, jos vartija kaatuu.
-- Odotetut (vahvistamattomat, ks. PR):
--   booking._upsell_options(bigint[],bigint[],date,integer,integer): UNVERIFIED
--   booking.public_upsell_checkout_attach(uuid,jsonb,uuid): UNVERIFIED
--   booking._upsell_attach_reservation(bigint,bigint,timestamptz,integer,date): UNVERIFIED
-- Rollback: rollbacks/20261026190000_booking_186_ROLLBACK.sql
-- Testi: tests/checkout/t186_upsell_options.sql (fixtures/10_test_helpers.sql jälkeen).
set local lock_timeout = '5s';

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._upsell_options(bigint[],bigint[],date,integer,integer)')));
  if v is distinct from 'UNVERIFIED_upsell_options' then
    raise exception 'booking_186: _upsell_options md5=% ei vastaa odotettua (vahvistamaton; päivitä vartija dry runin md5:llä)', coalesce(v, 'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_upsell_checkout_attach(uuid,jsonb,uuid)')));
  if v is distinct from 'UNVERIFIED_checkout_attach' then
    raise exception 'booking_186: public_upsell_checkout_attach md5=% ei vastaa odotettua (vahvistamaton; päivitä vartija dry runin md5:llä)', coalesce(v, 'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._upsell_attach_reservation(bigint,bigint,timestamptz,integer,date)')));
  if v is distinct from 'UNVERIFIED_attach_reservation' then
    raise exception 'booking_186: _upsell_attach_reservation md5=% ei vastaa odotettua (vahvistamaton; päivitä vartija dry runin md5:llä)', coalesce(v, 'puuttuu');
  end if;
end $g$;

create or replace function booking._upsell_options(p_origins bigint[], p_existing bigint[], p_date date, p_persons integer, p_limit integer default 9)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare v_products jsonb := '[]'::jsonb; v_addons jsonb := '[]'::jsonb; v_slots jsonb; v_opts jsonb; r record;
        v_today date := (now() at time zone booking._tz())::date;
begin
  if p_date is null or p_date < v_today or p_date > v_today + 14 then return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb); end if;
  for r in
    with suggested as (
      select s.suggested_product_id id, s.product_id origin, s.position, 0 tier
      from booking.product_suggestions s where s.enabled and s.product_id = any (p_origins) and s.suggested_product_id is not null
    ), fallback as (
      select pc.product_id id, null::bigint origin, 100::smallint position, 1 tier
      from booking.product_config pc where pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    ), uniq as (
      select distinct on (id) id, origin, position, tier from (select * from suggested union all select * from fallback) q
      order by id, tier, position, origin nulls last
    )
    select p.id, p.name, p.name_en, p.slug, p.price, p.short_description, p.short_description_en,
           p.description, p.description_en, pc.image_path, pc.option_required, pc.option_label, pc.option_label_en,
           x.origin, x.tier, x.position
      from uniq x join kb.products p on p.id = x.id join booking.product_config pc on pc.product_id = p.id
     where p.active and p.price is not null and pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
       and not (p.id = any (coalesce(p_existing, '{}'::bigint[])))
     order by x.tier, x.position, p.id limit greatest(1, least(p_limit, 12))
  loop
    v_slots := '[]'::jsonb;
    begin
      select coalesce(jsonb_agg(jsonb_build_object('start', q.starts_at, 'end', q.ends_at, 'total', q.total) order by q.starts_at), '[]'::jsonb)
        into v_slots from booking._upsell_day_slots(r.id, p_date, p_persons) q;
    exception when sqlstate 'BK001' or lock_not_available then
      v_slots := '[]'::jsonb;
    end;
    if jsonb_array_length(v_slots) > 0 then
      select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name, 'name_en', o.name_en, 'price_delta', null::numeric) order by o.sort_order, o.id), '[]'::jsonb)
        into v_opts from booking.product_options o where o.product_id = r.id and o.active;
      v_products := v_products || jsonb_build_array(jsonb_build_object('product_id', r.id, 'origin', r.origin, 'suggested', r.tier = 0,
        'name', r.name, 'name_en', r.name_en, 'slug', r.slug, 'price_from', r.price, 'short_description', r.short_description,
        'short_description_en', r.short_description_en, 'description', r.description, 'description_en', r.description_en, 'image_path', r.image_path,
        'option_required', coalesce(r.option_required, false), 'option_label', r.option_label, 'option_label_en', r.option_label_en, 'options', v_opts,
        'slots', v_slots));
    end if;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('addon_id', a.id, 'origin', s.product_id, 'name', a.name, 'name_en', a.name_en, 'price', a.price_gross, 'applies_modes', a.applies_modes)
      order by s.position, s.product_id, a.id), '[]'::jsonb) into v_addons
    from booking.product_suggestions s join booking.addons a on a.id = s.suggested_addon_id and a.active
   where s.enabled and s.product_id = any (coalesce(p_origins, '{}'::bigint[]));
  return jsonb_build_object('products', v_products, 'addons', v_addons);
end $f$;

create or replace function booking.public_upsell_checkout_attach(p_token uuid, p_upsell jsonb, p_session_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare o booking.orders; v_main bigint; v_main_start timestamptz; v_date date; e jsonb;
  v_pid bigint; v_pers int; v_start timestamptz; v_result jsonb; v_n int := 0; v_res_id bigint; v_opt bigint; v_detail text;
begin
  if p_token is null or p_session_id is null or jsonb_typeof(p_upsell) <> 'array' or jsonb_array_length(p_upsell) > 3 or
     not booking._order_rl('upschk', p_token, 20, 8) then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
  select * into o from booking.orders where public_token = p_token for update;
  if not found or o.external_source is not null or o.status not in ('pending', 'confirmed') or o.source_channel <> 'web'
     or o.created_at < now() - interval '5 minutes' then return jsonb_build_object('ok', false, 'code', 'order_closed'); end if;
  select r.product_id, r.starts_at into v_main, v_main_start from booking.reservations r where r.order_id = o.id order by r.id limit 1;
  if v_main_start is null or v_main_start <= now() + make_interval(mins => booking._upsell_cutoff()) then return jsonb_build_object('ok', false, 'code', 'order_closed'); end if;
  if o.status = 'pending' and not exists (select 1 from booking.reservations r
      where r.order_id = o.id and r.status = 'pending' and r.hold_expires_at > now()) then
    return jsonb_build_object('ok', false, 'code', 'order_closed');
  end if;
  if o.payment_status is distinct from 'unpaid'
     or exists (
       select 1 from booking.payments p
        where p.order_id = o.id
          and (
            p.status in ('paid', 'partially_refunded', 'refunded')
            or (p.status = 'pending' and p.provider is distinct from 'manual')
            or exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id)
          )
     ) then
    return jsonb_build_object('ok', false, 'code', 'order_closed');
  end if;
  if jsonb_array_length(p_upsell) > 0 and (
       o.discount_code_id is not null
       or exists (select 1 from booking.payments p where p.order_id = o.id and p.method = 'annual_card' and p.status in ('pending', 'paid'))
     ) then
    return jsonb_build_object('ok', false, 'code', 'code_conflict');
  end if;
  v_date := (v_main_start at time zone booking._tz())::date;
  begin
    for e in select value from jsonb_array_elements(p_upsell) loop
      if jsonb_typeof(e) <> 'object' or coalesce(e->>'product_id', '') !~ '^\d{1,18}$' or
         coalesce(e->>'persons', '') !~ '^\d{1,3}$' then perform booking._err('invalid_items', 'Invalid treatment'); end if;
      v_pid := (e->>'product_id')::bigint; v_pers := (e->>'persons')::int;
      if v_pid = v_main then perform booking._err('duplicate_product', 'Already in order'); end if;
      if exists (select 1 from booking.reservations where order_id = o.id and product_id = v_pid and booking._res_active(status, hold_expires_at)) then
        continue;
      end if;
      v_opt := null;
      if coalesce(e->>'option_id', '') <> '' then
        if e->>'option_id' !~ '^\d{1,18}$' then perform booking._err('invalid_option', 'Virheellinen valinta'); end if;
        v_opt := (e->>'option_id')::bigint;
      end if;
      v_start := (e->>'start')::timestamptz;
      v_result := booking._upsell_attach_reservation(o.id, v_pid, v_start, v_pers, v_date, v_opt);
      v_res_id := (v_result->>'reservation_id')::bigint;
      insert into booking.upsell_events(order_id, session_id, source, product_id, suggested_from_product_id, event, order_item_id)
      values (o.id, p_session_id, 'checkout', v_pid, v_main, 'added', (select order_item_id from booking.reservations where id = v_res_id))
      on conflict do nothing;
      v_n := v_n + 1;
    end loop;
    if v_n > 0 then perform booking._sync_placeholder(o.id); end if;
    insert into booking.upsell_events(order_id, session_id, source, product_id, suggested_from_product_id, suggested_addon_id, event, order_item_id)
      select o.id, p_session_id, 'checkout', v_main, v_main, oi.addon_id, 'added', oi.id
      from booking.order_items oi join booking.product_suggestions sug on sug.product_id = v_main and sug.suggested_addon_id = oi.addon_id and sug.enabled
      where oi.order_id = o.id and oi.kind = 'addon' on conflict do nothing;
    return jsonb_build_object('ok', true, 'added_count', v_n, 'total', (select total_gross from booking.orders where id = o.id));
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail;
      if v_detail in ('option_required', 'invalid_option', 'order_invoiced') then
        return jsonb_build_object('ok', false, 'code', v_detail);
      end if;
      return jsonb_build_object('ok', false, 'code', 'slot_unavailable');
    when exclusion_violation or invalid_text_representation or datetime_field_overflow then
      return jsonb_build_object('ok', false, 'code', 'slot_unavailable');
  end;
end $f$;

drop function booking._upsell_attach_reservation(bigint, bigint, timestamptz, integer, date);

create function booking._upsell_attach_reservation(p_order_id bigint, p_product_id bigint, p_start timestamptz, p_persons integer, p_main_day date, p_option_id bigint default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare o booking.orders; v_end timestamptz; v_result jsonb; v_code text;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found or o.external_source is not null or o.status not in ('pending', 'confirmed') then perform booking._err('order_not_editable', 'Order cannot be amended'); end if;
  if p_start is null or p_persons not between 1 and 50 or (p_start at time zone booking._tz())::date <> p_main_day then perform booking._err('invalid_date', 'Choose your visit date'); end if;
  if exists (select 1 from booking.reservations where order_id = o.id and product_id = p_product_id and booking._res_active(status, hold_expires_at)) then perform booking._err('duplicate_product', 'Already in order'); end if;
  if not exists (select 1 from booking._upsell_day_slots(p_product_id, p_main_day, p_persons) q where q.starts_at = p_start) then
    perform booking._err('slot_unavailable', 'Selected time is no longer available');
  end if;
  if p_option_id is not null then
    select po.code into v_code from booking.product_options po where po.id = p_option_id and po.product_id = p_product_id and po.active;
    if v_code is null then perform booking._err('invalid_option', 'Virheellinen valinta'); end if;
  end if;
  v_end := booking._treatment_slot_check(p_product_id, p_start, p_persons, true);
  -- 17. argumentti on p_option_code. null sallii tuotteen, joka ei vaadi valintaa. Laskulukko on _create_legs_bookingissa.
  v_result := booking._create_legs_booking('current', p_product_id, p_start, v_end, p_persons, o.customer_id, 'web', null, null, null, null, false, null, false, null, o.id, v_code);
  return v_result;
end $f$;
revoke all on function booking._upsell_attach_reservation(bigint, bigint, timestamptz, integer, date, bigint) from public, anon, authenticated;
