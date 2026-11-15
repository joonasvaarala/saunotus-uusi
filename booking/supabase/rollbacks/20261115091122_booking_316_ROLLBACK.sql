-- booking_316 ROLLBACK: palauttaa julkiset funktiot ja kassat PRODin 15.11.2026 määrittelyihin (lukevat taas vanhoja kenttiä),
-- poistaa synkkatriggerit, kanavafunktiot ja taulut booking.product_sales_channels ja booking.sales_channels.
-- Vanhat kentät (shop_visible, channels, fridge_sale, pos_enabled) ovat synkassa, joten tuotteiden näkyvyys säilyy.
-- HUOM: Lahjakorttikauppa-kanavan (gift_shop) valinnat eivät palaudu vanhoihin kenttiin (vanhassa mallissa paketti näkyy, jos se on aktiivinen).
set local lock_timeout = '5s';

do $pre$
declare v text; bad text := '';
begin
  if to_regclass('booking.product_sales_channels') is null or to_regclass('booking.sales_channels') is null then
    raise exception 'booking_316 ROLLBACK: kanavataulut puuttuvat (booking_316 ajamatta?). Ei muutoksia.';
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_catalog()')));
  if v is distinct from 'e90f2a6ee476a21968a41a784d7321f5' then bad := bad || ' public_catalog=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_availability(bigint,date,date)')));
  if v is distinct from '08618d80143879b777ab2c4c12f266b5' then bad := bad || ' public_availability=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_availability_all(date,date,text)')));
  if v is distinct from '79c37f88c9e8e4b20ff4c656ff1816d3' then bad := bad || ' public_availability_all=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_events(date,text)')));
  if v is distinct from 'd027ea741125757ddbfb968ca8b8d5fd' then bad := bad || ' public_events=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_training_checkout(bigint,date)')));
  if v is distinct from 'a1310d54be0a112d5de8b3696708f281' then bad := bad || ' public_training_checkout=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_product_by_slug(text)')));
  if v is distinct from 'f9243b802c2c70bd10d8a54ebc1fbee0' then bad := bad || ' public_product_by_slug=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._upsell_options(bigint[],bigint[],date,integer,integer)')));
  if v is distinct from '1f0b473ea6d3ec3c52e430aaf659c54f' then bad := bad || ' _upsell_options=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._public_create_booking_impl(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb)')));
  if v is distinct from '2bad68b49d0477132bfd0fac498e12af' then bad := bad || ' _public_create_booking_impl=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._public_create_booking_code_impl(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text)')));
  if v is distinct from 'de81e9b1f0dc29553f9c30e82bb49d2f' then bad := bad || ' _public_create_booking_code_impl=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._public_create_training_signup_impl(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[])')));
  if v is distinct from '28e1041b77b70d307216604941a05279' then bad := bad || ' _public_create_training_signup_impl=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_ritual_addon(bigint,date,integer)')));
  if v is distinct from '1fbf0b1e79e2a2909c555b037bab0670' then bad := bad || ' public_ritual_addon=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._ritual_addon_fit(timestamp with time zone,integer,boolean)')));
  if v is distinct from 'd8d85d79b372c83c30d48aca05787b54' then bad := bad || ' _ritual_addon_fit=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._counter_lines(jsonb,text)')));
  if v is distinct from 'd1714647df90f6c24c9881c18d80c2f8' then bad := bad || ' _counter_lines=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_catalog()')));
  if v is distinct from 'abbf3ea10c7a71f6cfb8103b20105e24' then bad := bad || ' admin_pos_catalog=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_drinks_catalog(text)')));
  if v is distinct from '431e44e38be94ef24c5bf5f1ad3c73af' then bad := bad || ' public_drinks_catalog=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_gift_card_packages()')));
  if v is distinct from '90eca5cada3e28b9c98fd07d1d9c1c72' then bad := bad || ' public_gift_card_packages=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._public_buy_gift_card_impl(jsonb,text,text,text,boolean,text,text,text,text,text,text,text,text)')));
  if v is distinct from '3354339ce7db3f6a7cd64df7fb23695f' then bad := bad || ' _public_buy_gift_card_impl=' || coalesce(v, 'puuttuu'); end if;
  if bad <> '' then raise exception 'booking_316 ROLLBACK: määrittelyt eivät vastaa booking_316:ta:%. Ei muutoksia.', bad; end if;
end $pre$;

drop trigger zz_sales_channels_sync on booking.product_config;
drop trigger zz_config_sync on booking.product_sales_channels;

CREATE OR REPLACE FUNCTION booking.public_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(booking._catalog_product_json(p.id) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    -- booking_158: vain kauppa-kanavan tuotteet; tapahtumat ja koulutukset vasta kun events.sale_enabled = true
    and 'shop' = any (booking._channels_effective(pc.channels, p.category))
    and (p.category not in ('event', 'training') or booking._events_sale_enabled())
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)) $function$
;

CREATE OR REPLACE FUNCTION booking.public_availability(p_product_id bigint, p_from date, p_to date)
 RETURNS TABLE(rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_horizon integer;
begin
  if p_product_id is null or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 92 päivää)');
  end if;
  if not exists (select 1 from booking.product_config pc join kb.products p on p.id = pc.product_id
                  where pc.product_id = p_product_id and pc.bookable and pc.lifecycle = 'current'
                    and (
                      ('shop' = any (booking._channels_effective(pc.channels, p.category)) and pc.shop_visible)
                      or 'link' = any (booking._channels_effective(pc.channels, p.category))
                    )) then
    return;
  end if;
  v_horizon := case when exists (
      select 1 from kb.products p
      join booking.product_config pc on pc.product_id = p.id
      where p.id = p_product_id
        and (p.category = 'training' or 'link' = any (booking._channels_effective(pc.channels, p.category))))
    then 400
    else (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int end;
  return query
    select s.rule_id, s.label, s.mode, s.session_date, s.starts_at, s.ends_at,
           case when s.status = 'closed' then 'closed'
                when s.status = 'available'
                     and pc.required_skill is not null
                     and booking._therapist_slack(
                           pc.required_skill,
                           s.starts_at + make_interval(mins => coalesce(pc.therapist_offset_min, 0)),
                           least(
                             s.ends_at,
                             case
                               when pc.therapist_minutes is null then s.ends_at
                               else s.starts_at + make_interval(mins => coalesce(pc.therapist_offset_min, 0) + pc.therapist_minutes)
                             end
                           ),
                           coalesce(pc.therapists_needed, 1)
                         ) < 0 then 'unavailable'
                when s.mode = 'exclusive' and s.status = 'unavailable'
                     and booking._waitlist_private_taken(s.rule_id, s.starts_at, s.ends_at) then 'full'
                when cap.left_n is not null and (cap.left_n <= 0 or (s.status = 'available' and cap.left_n < coalesce(s.min_persons, 1))) then 'full'
                else s.status end,
           case when cap.left_n is null then s.remaining else least(s.remaining, cap.left_n) end,
           s.min_persons, s.max_persons, s.price_mode, s.unit_price, s.base_price, s.included_persons, s.extra_person_price,
           s.label_en
      from booking._sessions(greatest(p_from, (now() at time zone booking._tz())::date),
                             least(p_to, (now() at time zone booking._tz())::date + v_horizon),
                             p_product_id, true) s
      join booking.schedule_rules rr on rr.id = s.rule_id
      join booking.product_config pc on pc.product_id = s.product_id
      left join lateral (
        select case when exists (select 1 from booking.training_segments ts where ts.option_rule_id = s.rule_id)
                    then booking._training_option_seats_left(s.rule_id) end as left_n
      ) cap on true
     where s.status <> 'closed'
       and not rr.training_segment_only;
end
$function$
;

CREATE OR REPLACE FUNCTION booking.public_availability_all(p_from date, p_to date, p_audience text DEFAULT 'consumer'::text)
 RETURNS TABLE(product_id bigint, rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_from date;
  v_to date;
  v_audience text := case when lower(btrim(coalesce(p_audience, ''))) = 'business' then 'business' else 'consumer' end;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 92 päivää)');
  end if;
  v_from := greatest(p_from, (now() at time zone booking._tz())::date);
  v_to := least(p_to, (now() at time zone booking._tz())::date
                       + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int);
  if v_from > v_to then return; end if;
  return query
    select s.product_id, s.rule_id, s.label, s.mode, s.session_date,
           s.starts_at, s.ends_at,
           case when s.mode = 'exclusive' and s.status = 'unavailable'
                     and booking._waitlist_private_taken(s.rule_id, s.starts_at, s.ends_at) then 'full'
                else s.status end,
           s.remaining, s.min_persons,
           s.max_persons, s.price_mode, s.unit_price, s.base_price, s.included_persons,
           s.extra_person_price, s.label_en
      from booking._sessions(v_from, v_to, null, true) s
      join booking.product_config pc on pc.product_id = s.product_id
      join kb.products p on p.id = s.product_id
     where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
       and 'shop' = any (booking._channels_effective(pc.channels, p.category))  -- booking_158: kanava
       and pc.audience = v_audience and s.status <> 'closed';
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_events(p_from date DEFAULT NULL::date, p_channel text DEFAULT 'shop'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_today date := (now() at time zone booking._tz())::date;
  v_from date := greatest(coalesce(p_from, v_today), v_today);
  v_sale boolean := booking._events_sale_enabled();
  v_fi text[] := array['ma', 'ti', 'ke', 'to', 'pe', 'la', 'su'];
begin
  if coalesce(p_channel, 'shop') not in ('shop', 'widget') then perform booking._err('invalid_param', 'Kanava on shop tai widget'); end if;
  return coalesce((
    select jsonb_agg(ev.j order by ev.first_start, ev.pid) from (
      select p.id as pid, min(o.starts_at) as first_start,
             jsonb_build_object(
               'product_id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
               'description_short', p.short_description, 'description_short_en', p.short_description_en,
               'price', p.price, 'price_text', p.price_text, 'image_path', pc.image_path, 'image_alt', pc.image_alt, 'category', p.category,
               'sale_open', v_sale,
               'occurrences', jsonb_agg(jsonb_build_object(
                  'rule_id', o.rule_id, 'starts_at', o.starts_at, 'ends_at', o.ends_at, 'label', o.label, 'label_en', o.label_en,
                  'time_text', o.time_text, 'time_text_en', o.time_text_en, 'status', o.status,
                  'remaining', case when o.status = 'closed' then null else greatest(o.remaining, 0) end,
                  'price', o.price) order by o.starts_at, o.rule_id)) as j
        from kb.products p
        join booking.product_config pc on pc.product_id = p.id
        cross join lateral (
          select r.id as rule_id, s.starts_at, s.ends_at, r.label, r.label_en, s.remaining,
                 case when v_sale and pc.bookable and pc.lifecycle = 'current' and s.status in ('available', 'full') then s.status else 'closed' end as status,
                 coalesce(s.unit_price, s.base_price) as price,
                 v_fi[extract(isodow from ls)::int] || ' ' || to_char(ls, 'FMDD.FMMM.') || ' klo ' || to_char(ls, 'HH24.MI')
                   || case when ls::date = le::date then '–' || to_char(le, 'HH24.MI')
                           else ' – ' || v_fi[extract(isodow from le)::int] || ' ' || to_char(le, 'FMDD.FMMM.') || ' klo ' || to_char(le, 'HH24.MI') end as time_text,
                 to_char(ls, 'Dy FMDD Mon HH24:MI')
                   || case when ls::date = le::date then '–' || to_char(le, 'HH24:MI') else ' – ' || to_char(le, 'Dy FMDD Mon HH24:MI') end as time_text_en
            from booking.schedule_rules r
            cross join lateral booking._sessions(r.valid_from, r.valid_from, r.product_id, false) s
            cross join lateral (select s.starts_at at time zone booking._tz() as ls, s.ends_at at time zone booking._tz() as le) t
           where r.product_id = p.id and r.kind = 'event' and r.active and r.valid_from >= v_from and r.valid_from <= v_today + 400
             and s.rule_id = r.id and s.ends_at > now()
        ) o
       where p.active and p.category in ('event', 'training')
         and coalesce(p_channel, 'shop') = any (booking._channels_effective(pc.channels, p.category))
       group by p.id, pc.product_id
    ) ev
  ), '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_training_checkout(p_rule_id bigint, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r booking.schedule_rules; p kb.products; pc booking.product_config;
  v_deposit numeric; v_left integer; v_offers jsonb;
begin
  select * into r from booking.schedule_rules where id = p_rule_id and active and kind = 'event';
  if not found or r.valid_from is distinct from p_date or r.training_segment_only then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Kurssikertaa ei löydy');
  end if;
  select * into p from kb.products where id = r.product_id and active and category = 'training';
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Kurssia ei löydy'); end if;
  select * into pc from booking.product_config where product_id = p.id and bookable and lifecycle = 'current';
  if not found or not ('link' = any (booking._channels_effective(pc.channels, p.category))) or not booking._events_sale_enabled() then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Kurssia ei löydy');
  end if;
  v_deposit := coalesce(pc.deposit_amount, case when p.price_type = 'deposit' then p.price end, 200);
  v_left := booking._training_single_rooms_remaining(r.id);
  select coalesce(jsonb_agg(jsonb_build_object(
      'code', o.code, 'price', o.price,
      'remaining', case when o.code = 'single_room' then v_left end,
      'available', case when o.code = 'single_room' then coalesce(v_left, 1) > 0 else true end
    ) order by o.code), '[]'::jsonb)
    into v_offers
    from booking.training_addon_offers o
   where o.product_id = p.id and o.active;
  return jsonb_build_object(
    'ok', true, 'rule_id', r.id, 'product_id', p.id,
    'course_price', pc.course_price, 'deposit_amount', v_deposit,
    'single_rooms_remaining', v_left, 'seats_remaining', booking._training_option_seats_left(r.id), 'addons', v_offers,
    'segments', booking._training_segment_json(r.id));
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_product_by_slug(p_slug text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select booking._catalog_product_json(p.id) || jsonb_build_object(
      'listed', false,
      'deposit', true,
      'course_price', pc.course_price,
      'deposit_amount', coalesce(pc.deposit_amount, case when p.price_type = 'deposit' then p.price end, 200),
      'training_addons', coalesce((
        select jsonb_agg(jsonb_build_object('code', o.code, 'price', o.price) order by o.code)
          from booking.training_addon_offers o
         where o.product_id = p.id and o.active), '[]'::jsonb))
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where p.slug = p_slug
    and p.category = 'training'
    and pc.bookable and pc.lifecycle = 'current'
    and 'link' = any (booking._channels_effective(pc.channels, p.category))
    and booking._events_sale_enabled()
    and exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active and r.kind = 'event')
$function$
;

CREATE OR REPLACE FUNCTION booking._upsell_options(p_origins bigint[], p_existing bigint[], p_date date, p_persons integer, p_limit integer DEFAULT 9)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION booking._public_create_booking_impl(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_ip text := booking._client_ip();
  v_cust bigint; v_res jsonb; v_status text; v_pay_method text; v_pay_provider text;
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_detail text; v_msg text;
  v_hold int; v_invoice boolean; v_online boolean; v_hold_mode boolean; v_group boolean; v_thr int := booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000);
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb; v_add numeric; v_total numeric;
  v_quiet jsonb; v_qamt numeric := 0;  -- booking_162: hiljaisten aikojen ale
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;

  -- rate limit (kirjataan myös estetyt yritykset)
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;

  -- syötteiden validointi
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then
    return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite');
  end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero');
  end if;
  if p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä');
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä');
  end if;
  if p_date is null or p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  if exists (
    select 1 from booking.schedule_rules r
    join kb.products kp on kp.id = r.product_id
    where r.id = p_rule_id and kp.category = 'training'
  ) then
    return jsonb_build_object('ok', false, 'code', 'training_signup_only', 'message', 'Koulutukseen ilmoittaudutaan kurssisivun kautta');
  end if;
  -- rajoita samanaikaisia maksamattomia pitoja / sähköposti
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;

  -- booking_53: pitotila (public_payment_mode <> 'pay_later'): varaus odottaa maksua; yritysasiakas laskulle jos checkout_company_invoice_enabled
  v_online := v_is_company and lower(btrim(coalesce(p_company ->> 'invoice_method', ''))) = 'online';
  v_invoice := v_is_company and not v_online and coalesce((booking._setting('checkout_company_invoice_enabled', 'true'::jsonb) #>> '{}')::boolean, true);
  v_hold_mode := v_mode <> 'pay_later' and not v_invoice;
  v_group := v_hold_mode and v_thr > 0 and p_persons >= v_thr;
  if v_hold_mode and not v_group and not booking._checkout_online_available() then
    return jsonb_build_object('ok', false, 'code', 'online_payment_unavailable', 'message', 'Verkkomaksu ei ole tilapäisesti käytettävissä – varausta ei voi tehdä juuri nyt');
  end if;
  v_status := case when v_hold_mode then 'pending' else 'confirmed' end;
  v_pay_method := case when v_invoice then 'invoice' else 'pay_later' end;
  v_pay_provider := 'manual';
  v_hold := case when v_group then booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60) * 1440 else booking._checkout_hold_minutes() end;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    -- booking_139: jonotuspidon haltija (sama sähköposti, voimassa oleva pito tähän vuoroon) ei kilpaile omaa pitoaan vastaan.
    -- Transaktiokohtainen asetus; virhe kumoaa sen alitransaktion mukana, onnistuneen luonnin jälkeen se nollataan alla.
    perform set_config('booking.waitlist_hold_exempt', coalesce((select w.id::text from booking.waitlist_entries w
      where w.rule_id = p_rule_id and w.session_date = p_date and lower(w.customer_email) = v_email
        and w.status = 'notified' and w.hold_expires_at > now() order by w.id limit 1), ''), true);
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale,
                                                 (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                         (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    -- booking_162: hiljaisen ajan ale arvioidaan ennen varauksen luontia (tyhjä vuoro); null kun asetus pois tai ei tarjousta
    v_quiet := booking._quiet_for_rule(p_rule_id, p_date);
    v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note,
                                          v_status, v_hold, true);
    perform booking._stamp_order_billing((v_res ->> 'order_id')::bigint, v_cust, v_company);
    v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
    v_qamt := booking._quiet_apply((v_res ->> 'order_id')::bigint, v_quiet);
    v_total := (v_res ->> 'total')::numeric - v_qamt + v_add;
    if not v_hold_mode then   -- pitotilassa ei luoda paikkaajamaksua: maksu syntyy vasta kun asiakas maksaa (MobilePay / lahjakortti)
      insert into booking.payments(order_id, method, provider, status, amount)
      values ((v_res ->> 'order_id')::bigint, v_pay_method, v_pay_provider, 'pending', v_total);
    end if;
    update booking.orders set payment_status = 'unpaid', hold_kind = case when v_hold_mode then (case when v_group then 'preliminary' else 'checkout' end) end
     where id = (v_res ->> 'order_id')::bigint;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform set_config('booking.waitlist_hold_exempt', '', true);

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token',
                            'status', v_status, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'total', v_total, 'addons_total', v_add, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name', 'customer_kind', v_kind)
         || case when v_qamt > 0 then jsonb_build_object('discount', v_qamt, 'discount_source', 'quiet',
                 'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt)) else '{}'::jsonb end
         || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
end $function$
;

CREATE OR REPLACE FUNCTION booking._public_create_booking_code_impl(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb, p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private')));
  v_card booking.annual_cards; d booking.discount_codes; v_res jsonb; v_order booking.orders; v_cust bigint; v_err text; v_detail text; v_msg text;
  v_lines jsonb; v_calc jsonb; s jsonb; v_disc numeric; v_total numeric; pr record; v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_qamt numeric := 0; v_qitem bigint;  -- booking_162: hiljaisen ajan ale (ei pinoudu koodin kanssa, suurempi etu voittaa)
begin
  if v_code = '' then
    return booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                         p_customer_kind, p_company, p_addons);
  end if;
  if char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  if not booking._code_rate_ok(v_code, v_email, v_phone, v_ip) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code for update; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti, jonka omistaja ei täsmää → sama vastaus kuin tuntemattomalla koodilla (ennen muita tarkistuksia)
  if v_card.id is not null and not booking._annual_card_owner_ok(v_card, v_email, v_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  -- ---- vuosikortti / yhteinen vuosikorttikoodi
  if v_card.id is not null or d.is_annual_card_code then
    if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
      return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
    end if;
    if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
    if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
    if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
    if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
    if p_date is null or p_date < (now() at time zone booking._tz())::date
       or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
      return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
    end if;
    v_err := case
      when v_kind <> 'private' then 'annual_card_private_only'
      when p_addons is not null and jsonb_typeof(p_addons) = 'array' and exists (select 1 from jsonb_array_elements(p_addons) x where coalesce(x ->> 'quantity', '0') <> '0') then 'annual_card_no_addons'
      when p_persons is distinct from booking._annual_max_persons() then 'annual_card_persons'
      else booking._annual_rule_check(p_rule_id, p_date, v_card, d) end;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    begin
      if v_card.id is not null then v_cust := v_card.customer_id;
      else
        v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                           (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
      end if;
      perform booking._annual_lock_identity(v_cust, v_email, v_phone);
      if booking._annual_limit(v_cust, v_email, v_phone) then perform booking._err('annual_card_limit', booking._code_msg('annual_card_limit')); end if;
      -- henkilökohtaisen kortin rivin alennus (alkuperäinen hinta) kirjataan triggerissä reservations_annual_discount
      v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note, 'confirmed', null, true,
                                            null, null, case when v_card.id is null then 0 end, v_card.id);
      if d.id is not null then
        select * into pr from booking._rule_price(p_rule_id, p_persons);
        update booking.order_items set discount_code_id = d.id, discount_amount = pr.total
         where order_id = (v_res ->> 'order_id')::bigint and kind = 'reservation';
        update booking.orders set discount_code_id = d.id where id = (v_res ->> 'order_id')::bigint;
        update booking.discount_codes set used_count = used_count + 1 where id = d.id;
      end if;
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values ((v_res ->> 'order_id')::bigint, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikorttivaraus verkossa (' || v_code || ')');
      update booking.orders set payment_status = 'paid' where id = (v_res ->> 'order_id')::bigint;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
    end;
    return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token', 'status', 'confirmed',
                              'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at', 'total', 0, 'addons_total', 0,
                              'hold_expires_at', null, 'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name',
                              'customer_kind', 'private', 'code_type', case when v_card.id is not null then 'annual_card' else 'annual_code' end,
                              'discount', (select coalesce(sum(discount_amount), 0) from booking.order_items where order_id = (v_res ->> 'order_id')::bigint))
           || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
  end if;

  -- ---- alennuskoodi
  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  begin
    v_res := booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                           p_customer_kind, p_company, p_addons);
    if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;
    select * into v_order from booking.orders where public_token = (v_res ->> 'token')::uuid for update;
    -- booking_162: koodin alennus lasketaan alennuksettomista riveistä (hiljaisen ajan ale lisätään takaisin)
    select oi.id, coalesce((oi.price_breakdown #>> '{quiet,amount}')::numeric, 0) into v_qitem, v_qamt
      from booking.order_items oi where oi.order_id = v_order.id and oi.kind = 'reservation' and oi.price_breakdown ? 'quiet' order by oi.id limit 1;
    v_qamt := coalesce(v_qamt, 0);
    select coalesce(jsonb_agg(jsonb_build_object('key', oi.id, 'product_id', oi.product_id, 'kind', oi.kind,
             'gross', oi.line_total_gross + case when oi.id = v_qitem then v_qamt else 0 end) order by oi.id), '[]'::jsonb)
      into v_lines from booking.order_items oi where oi.order_id = v_order.id;
    v_calc := booking._discount_split(d, v_lines);
    v_disc := (v_calc ->> 'discount')::numeric;
    if v_disc <= 0 then perform booking._err('code_not_applicable', booking._code_msg('code_not_applicable')); end if;
    if v_qamt > 0 and v_qamt >= v_disc then
      -- hiljaisen ajan ale on vähintään yhtä suuri etu: koodia ei käytetä (käyttökertaa ei kuluteta), varaus jää alennettuun hintaan
      return v_res || jsonb_build_object('code_applied', false, 'discount_source', 'quiet', 'code_discount', v_disc, 'discount_code', null, 'code_type', 'discount');
    end if;
    if v_qamt > 0 then   -- koodi on suurempi etu: hiljaisen ajan ale perutaan riviltä ennen koodin alennusta
      update booking.order_items
         set line_total_gross = line_total_gross + v_qamt, discount_amount = 0,
             price_breakdown = (price_breakdown - 'quiet') || jsonb_build_object('quiet_superseded', (price_breakdown -> 'quiet') || jsonb_build_object('by', 'code'))
       where id = v_qitem;
    end if;
    for s in select x from jsonb_array_elements(v_calc -> 'shares') x loop
      update booking.order_items set discount_code_id = d.id, discount_amount = coalesce(discount_amount, 0) + (s ->> 'amount')::numeric,
             line_total_gross = line_total_gross - (s ->> 'amount')::numeric
       where id = (s ->> 'key')::bigint and order_id = v_order.id;
    end loop;
    update booking.orders set discount_code_id = d.id,
           total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = v_order.id), 0)
     where id = v_order.id returning total_gross into v_total;
    update booking.discount_codes set used_count = used_count + 1 where id = d.id;
    if v_total > 0 then
      update booking.payments set amount = v_total where order_id = v_order.id and status = 'pending' and provider = 'manual';
    else   -- 100 % alennus: ei maksettavaa → vahvistetaan heti, ilman 0 €:n paid-maksua (booking_217)
      update booking.payments set status = 'cancelled' where order_id = v_order.id and status = 'pending';
      update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = v_order.id and status = 'pending';
      update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), hold_kind = null where id = v_order.id and status = 'pending';
      update booking.orders set payment_status = 'paid' where id = v_order.id;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  select * into v_order from booking.orders where id = v_order.id;
  return v_res || jsonb_build_object('total', v_total, 'status', v_order.status, 'hold_expires_at',
                    (select min(hold_expires_at) from booking.reservations where order_id = v_order.id and status = 'pending'),
                    'discount', v_disc, 'discount_code', d.code, 'code_type', 'discount',
                    'addons_total', (select coalesce(sum(line_total_gross), 0) from booking.order_items where order_id = v_order.id and kind = 'addon'))
                || case when v_qamt > 0 then jsonb_build_object('discount_source', 'code', 'quiet', null) else '{}'::jsonb end
                || booking._checkout_state_json(v_order.id);
end $function$
;

CREATE OR REPLACE FUNCTION booking._public_create_training_signup_impl(p_rule_id bigint, p_date date, p_name text, p_email text, p_phone text, p_country text, p_language text, p_locale text, p_note text, p_marketing_consent boolean, p_privacy_consent boolean, p_addons text[] DEFAULT '{}'::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name text := btrim(coalesce(p_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_country text := upper(btrim(coalesce(p_country, 'FI')));
  v_locale text := case when lower(btrim(coalesce(p_locale, 'fi'))) = 'en' then 'en' else 'fi' end;
  v_lang text := lower(btrim(coalesce(nullif(p_language, ''), v_locale)));
  v_codes text[]; v_bad text; v_offer_n int; v_addons numeric := 0; v_addon_json jsonb := '[]'::jsonb;
  v_deposit numeric; v_course numeric; v_total numeric; v_remaining numeric;
  v_cust bigint; v_res jsonb; v_order bigint; v_resid bigint; v_detail text; v_msg text; v_hold int;
  v_seg jsonb; v_hold_at timestamptz; v_sid bigint;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if p_privacy_consent is not true then
    return jsonb_build_object('ok', false, 'code', 'privacy_required', 'message', 'Tietosuojasuostumus puuttuu');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi');
  end if;
  if not booking._valid_email(v_email) then
    return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite');
  end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero');
  end if;
  if v_country !~ '^[A-Z]{2}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_country', 'message', 'Tarkista maa');
  end if;
  if v_lang not in ('fi', 'en', 'sv') then
    return jsonb_build_object('ok', false, 'code', 'invalid_language', 'message', 'Tarkista kieli');
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä');
  end if;
  if p_date is null or p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + 400 then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  if not booking._checkout_online_available() then
    return jsonb_build_object('ok', false, 'code', 'online_payment_unavailable', 'message', 'Verkkomaksu ei ole tilapäisesti käytettävissä – ilmoittautumista ei voi tehdä juuri nyt');
  end if;
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;
  if not exists (
    select 1 from booking.schedule_rules sr
    join kb.products kp on kp.id = sr.product_id and kp.category = 'training' and kp.active
    join booking.product_config cfg on cfg.product_id = kp.id and cfg.bookable and cfg.lifecycle = 'current'
    where sr.id = p_rule_id and sr.kind = 'event' and sr.active and not sr.training_segment_only
  ) then
    return jsonb_build_object('ok', false, 'code', 'not_training', 'message', 'Ilmoittautuminen koskee vain koulutusta');
  end if;

  select coalesce(array_agg(distinct lower(btrim(c)) order by lower(btrim(c))), '{}'::text[])
    into v_codes
    from unnest(coalesce(p_addons, '{}'::text[])) c
   where btrim(coalesce(c, '')) <> '';
  select c into v_bad from unnest(v_codes) c where c not in ('single_room', 'internship') limit 1;
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'code', 'invalid_addon', 'message', 'Lisävalinta ei kelpaa');
  end if;

  select count(*)::int, coalesce(sum(o.price), 0),
         coalesce(jsonb_agg(jsonb_build_object('code', o.code, 'price', o.price) order by o.code), '[]'::jsonb)
    into v_offer_n, v_addons, v_addon_json
    from booking.training_addon_offers o
    join booking.schedule_rules sr on sr.id = p_rule_id
   where o.product_id = sr.product_id and o.active and o.code = any (v_codes);
  if v_offer_n is distinct from coalesce(cardinality(v_codes), 0) then
    return jsonb_build_object('ok', false, 'code', 'addon_not_offered', 'message', 'Lisävalinta ei ole tällä kurssilla');
  end if;

  select coalesce(pc.deposit_amount, case when kp.price_type = 'deposit' then kp.price end, 200), pc.course_price
    into v_deposit, v_course
    from booking.schedule_rules sr
    join kb.products kp on kp.id = sr.product_id
    join booking.product_config pc on pc.product_id = kp.id
   where sr.id = p_rule_id;
  if v_deposit is null or v_deposit <= 0 then
    return jsonb_build_object('ok', false, 'code', 'invalid_price', 'message', 'Varausmaksu puuttuu');
  end if;
  v_total := case when v_course is null then null else round(v_course + v_addons, 2) end;
  v_remaining := case when v_total is null then null else round(v_total - v_deposit, 2) end;
  v_hold := booking._checkout_hold_minutes();
  v_seg := booking._training_segment_json(p_rule_id);

  begin
    perform r.id from booking.schedule_rules r
     where r.id = p_rule_id or r.id in (select booking._training_segment_ids(p_rule_id))
     order by r.id
     for update;
    perform res.id from booking.resources res
     where res.id in (
       select rp.pool_id from booking.schedule_rule_pools rp
        where rp.rule_id = p_rule_id or rp.rule_id in (select booking._training_segment_ids(p_rule_id)))
     order by res.id
     for update;
    if 'single_room' = any (v_codes) and exists (
      select 1 from booking.schedule_rules r
       where r.id in (select booking._training_single_room_pools(p_rule_id))
         and booking._training_single_rooms_used(r.id) >= r.single_room_max
    ) then
      return jsonb_build_object('ok', false, 'code', 'single_room_full', 'message', 'Yhden hengen huoneet ovat täynnä');
    end if;
    v_cust := booking._upsert_customer(v_name, v_email, v_phone, coalesce(p_marketing_consent, false), 'web_booking', v_locale,
                                       (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    update booking.customers set country = v_country, language = v_lang where id = v_cust;
    v_res := booking._create_booking_core(p_rule_id, p_date, 1, v_cust, 'web', null, v_locale, nullif(btrim(coalesce(p_note, '')), ''),
                                          'pending', v_hold, true, null, null, v_deposit);
    v_order := (v_res ->> 'order_id')::bigint;
    v_resid := (v_res ->> 'reservation_id')::bigint;
    v_hold_at := (v_res ->> 'hold_expires_at')::timestamptz;
    -- booking_254: _create_booking_core now holds the segments for every channel.
    update booking.orders set payment_status = 'unpaid', hold_kind = 'checkout' where id = v_order;
    update booking.order_items set price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
        'deposit', true, 'deposit_amount', v_deposit, 'course_price', v_course,
        'addons_total', v_addons, 'total', v_total, 'remaining', v_remaining, 'addons', v_addon_json, 'segments', v_seg))
     where order_id = v_order and kind = 'reservation';
    insert into booking.training_participants(
      reservation_id, order_id, name, email, phone, country, language, privacy_consent_at, marketing_consent,
      single_room, addons, course_price, addons_total, total, deposit_paid, remaining, segments)
    values (
      v_resid, v_order, v_name, v_email, v_phone, v_country, v_lang, now(), coalesce(p_marketing_consent, false),
      'single_room' = any (v_codes), v_addon_json, v_course, v_addons, v_total, v_deposit, v_remaining, v_seg);
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;

  return jsonb_build_object(
      'ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token',
      'status', 'pending', 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
      'total', v_deposit, 'hold_expires_at', v_res -> 'hold_expires_at',
      'payment_mode', 'hold_until_paid', 'payment_url', null, 'product_name', v_res -> 'product_name', 'customer_kind', 'private',
      'training', jsonb_strip_nulls(jsonb_build_object(
        'course_price', v_course, 'addons_total', v_addons, 'total', v_total,
        'deposit_paid', v_deposit, 'remaining', v_remaining, 'addons', v_addon_json, 'segments', v_seg)))
    || booking._checkout_state_json(v_order);
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_ritual_addon(p_rule_id bigint, p_date date, p_persons integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c jsonb := booking._ritual_addon_cfg(); v_prod bigint; p kb.products; pc booking.product_config; s record; v_n int; v_max int; v_min int; v_dur int;
  t timestamptz; k int; v_st text; v_times jsonb := '[]'::jsonb; v_prices jsonb := '{}'::jsonb; i int;
begin
  v_prod := nullif(c ->> 'product_id', '')::bigint;
  if not coalesce((c ->> 'enabled')::boolean, false) or v_prod is null then
    return jsonb_build_object('ok', true, 'available', false, 'reason', 'disabled', 'times', '[]'::jsonb);
  end if;
  select * into p from kb.products where id = v_prod and active;
  select * into pc from booking.product_config where product_id = v_prod;
  if p.id is null or pc.product_id is null or not pc.bookable or pc.lifecycle <> 'current' then
    return jsonb_build_object('ok', true, 'available', false, 'reason', 'product_unavailable', 'times', '[]'::jsonb);
  end if;
  if p_rule_id is null or p_date is null or not booking._ritual_addon_session_ok(p_rule_id) then
    return jsonb_build_object('ok', true, 'available', false, 'reason', 'not_eligible', 'times', '[]'::jsonb);
  end if;
  v_n := least(greatest(coalesce(p_persons, 1), 1), 50);
  begin
    select * into s from booking._resolve_session(p_rule_id, p_date, v_n, true);
  exception when sqlstate 'BK001' then
    return jsonb_build_object('ok', true, 'available', false, 'reason', 'no_session', 'times', '[]'::jsonb);
  end;
  v_min := greatest(coalesce(pc.min_persons, 1), 1);
  v_max := least(v_n, booking._treatment_max_persons(v_prod));
  v_dur := coalesce(pc.duration_minutes, p.duration_minutes);
  if v_max >= v_min then
    for i in v_min .. v_max loop v_prices := v_prices || jsonb_build_object(i::text, round(booking._treatment_price(v_prod, i), 2)); end loop;
    for t in select x from booking._ritual_addon_starts(s.o_starts_at, s.o_ends_at) x loop
      k := v_max; v_st := null;
      while k >= v_min loop
        v_st := booking._ritual_addon_fit(t, k, true);
        exit when v_st is not null;
        k := k - 1;
      end loop;
      continue when v_st is null;
      v_times := v_times || jsonb_build_object('starts_at', t, 'ends_at', t + make_interval(mins => v_dur), 'max_persons', k,
        'label', to_char(t at time zone booking._tz(), 'HH24:MI'),
        'position', case when t < s.o_starts_at then 'before' when t = s.o_starts_at then 'start' when t >= s.o_ends_at then 'end' else 'during' end);
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'available', jsonb_array_length(v_times) > 0, 'reason', case when jsonb_array_length(v_times) = 0 then 'full' end,
    'product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price_type', p.price_type, 'unit_price', round(booking._treatment_price(v_prod, 1), 2),
    'prices', v_prices, 'vat_rate', p.vat_rate, 'duration_minutes', v_dur, 'min_persons', v_min, 'max_persons', greatest(v_max, 0),
    'session_starts_at', s.o_starts_at, 'session_ends_at', s.o_ends_at, 'times', v_times);
end $function$
;

CREATE OR REPLACE FUNCTION booking._ritual_addon_fit(p_start timestamp with time zone, p_persons integer, p_public boolean DEFAULT true)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c jsonb := booking._ritual_addon_cfg(); v_prod bigint; pc booking.product_config; p kb.products; ls timestamp; v_lead int; v_h int; v_dur int;
begin
  v_prod := nullif(c ->> 'product_id', '')::bigint;
  if p_start is null or p_persons is null or p_persons < 1 or v_prod is null then return null; end if;
  select * into pc from booking.product_config where product_id = v_prod;
  select * into p from kb.products where id = v_prod and active;
  if pc.product_id is null or p.id is null or not pc.bookable or pc.lifecycle <> 'current' then return null; end if;
  if p_persons < greatest(coalesce(pc.min_persons, 1), 1) or p_persons > booking._treatment_max_persons(v_prod) then return null; end if;
  v_dur := coalesce(pc.duration_minutes, p.duration_minutes);
  if v_dur is null or v_dur <= 0 then return null; end if;
  if p_public then
    v_lead := coalesce((booking._setting('public_treatment_min_lead_minutes', '120'::jsonb) #>> '{}')::int, 120);
    if p_start < now() + make_interval(mins => v_lead) then return null; end if;
    ls := p_start at time zone booking._tz();
    if ls::date < (now() at time zone booking._tz())::date then return null; end if;
    v_h := nullif(c ->> 'horizon_days', '')::int;
    if v_h is not null and ls::date > (now() at time zone booking._tz())::date + v_h then return null; end if;
    if pc.public_weekdays is not null and not (extract(isodow from ls)::smallint = any (pc.public_weekdays)) then return null; end if;
    if not booking._public_shift_day_open(ls::date) then return null; end if;
  end if;
  return booking._treatment_plan_status(v_prod, p_start, p_start + make_interval(mins => v_dur), p_persons);
end $function$
;

CREATE OR REPLACE FUNCTION booking._counter_lines(p_items jsonb, p_channel text)
 RETURNS TABLE(product_id bigint, quantity integer, product_name text, unit_price numeric, vat_rate numeric, line_total numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  e jsonb; k text; v_id bigint; v_qty int; v_acc jsonb := '{}'::jsonb; v_key text; v_sum int;
  r record; pr record; v_name text; v_line numeric;
  v_custom jsonb := '[]'::jsonb; v_cust_n int := 0;
  v_desc text; v_price numeric; v_vat numeric; v_is_custom boolean; v_keys text[];
begin
  if p_channel not in ('pos', 'fridge') then perform booking._err('invalid_param', 'Kanava'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then perform booking._err('invalid_items', 'Ostoskori puuttuu'); end if;
  if jsonb_array_length(p_items) < 1 then perform booking._err('nothing_to_pay', 'Ostoskori on tyhjä'); end if;
  if jsonb_array_length(p_items) > 12 then perform booking._err('invalid_items', 'Enintään 12 riviä'); end if;

  for e in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_items', 'Rivi ei ole kelvollinen'); end if;
    v_is_custom := coalesce(e ->> 'kind', '') = 'custom';

    if v_is_custom then
      if p_channel <> 'pos' then
        perform booking._err('invalid_items', 'Vapaa rivi vain pikakassassa');
      end if;
      select array_agg(x order by x) into v_keys from jsonb_object_keys(e) x;
      if exists (
        select 1 from unnest(v_keys) x
         where x not in ('kind', 'description', 'quantity', 'unit_price', 'unit_price_cents', 'vat_rate')
      ) then
        perform booking._err('invalid_items', 'Vapaan rivin kentät eivät ole kelvolliset');
      end if;

      v_desc := btrim(coalesce(e ->> 'description', ''));
      if v_desc = '' then perform booking._err('invalid_items', 'Vapaan rivin kuvaus puuttuu'); end if;
      if char_length(v_desc) > 200 then perform booking._err('invalid_items', 'Vapaan rivin kuvaus on liian pitkä'); end if;
      if position('<' in v_desc) > 0 then perform booking._err('invalid_items', 'Vapaan rivin kuvaus ei ole kelvollinen'); end if;

      if coalesce(e ->> 'quantity', '') !~ '^[0-9]{1,6}$' then
        perform booking._err('invalid_items', 'Määrä ei ole kelvollinen');
      end if;
      v_qty := (e ->> 'quantity')::int;
      if v_qty < 1 or v_qty > 20 then
        perform booking._err('invalid_items', 'Määrän pitää olla 1–20');
      end if;

      v_price := null;
      if e ? 'unit_price_cents' then
        if jsonb_typeof(e -> 'unit_price_cents') = 'number' then
          if (e ->> 'unit_price_cents') ~ '^-?[0-9]+$' then
            v_price := ((e ->> 'unit_price_cents')::bigint)::numeric / 100.0;
          end if;
        elsif coalesce(e ->> 'unit_price_cents', '') ~ '^[0-9]{1,9}$' then
          v_price := ((e ->> 'unit_price_cents')::bigint)::numeric / 100.0;
        end if;
      end if;
      if v_price is null and e ? 'unit_price' then
        if coalesce(e ->> 'unit_price', '') ~ '^[0-9]+([.][0-9]{1,2})?$' then
          v_price := (e ->> 'unit_price')::numeric;
        end if;
      end if;
      if v_price is null then perform booking._err('invalid_items', 'Vapaan rivin hinta ei ole kelvollinen'); end if;
      if v_price < 0 or v_price > 100000 or v_price <> round(v_price, 2) then
        perform booking._err('invalid_items', 'Vapaan rivin hinta ei ole kelvollinen');
      end if;

      if coalesce(e ->> 'vat_rate', '') !~ '^[0-9]+([.][0-9]+)?$' then
        perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu');
      end if;
      v_vat := (e ->> 'vat_rate')::numeric;
      if not booking._vat_active(v_vat) then
        perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu: ' || v_vat::text);
      end if;

      v_cust_n := v_cust_n + 1;
      v_custom := v_custom || jsonb_build_array(jsonb_build_object(
        'description', v_desc, 'quantity', v_qty, 'unit_price', v_price, 'vat_rate', v_vat,
        'line_total', round(v_price * v_qty, 2)));
    else
      for k in select jsonb_object_keys(e) loop
        if k not in ('product_id', 'quantity') then
          perform booking._err('price_locked', 'Hintaa tai verokantaa ei voi antaa ostoskorissa');
        end if;
      end loop;
      if coalesce(e ->> 'product_id', '') !~ '^[0-9]{1,18}$' or coalesce(e ->> 'quantity', '') !~ '^[0-9]{1,6}$' then
        perform booking._err('invalid_items', 'Tuote tai määrä ei ole kelvollinen');
      end if;
      v_id := (e ->> 'product_id')::bigint;
      v_qty := (e ->> 'quantity')::int;
      if v_qty < 1 then perform booking._err('invalid_items', 'Määrän pitää olla vähintään yksi'); end if;
      v_key := v_id::text;
      v_sum := coalesce((v_acc ->> v_key)::int, 0) + v_qty;
      if v_sum > 20 then perform booking._err('invalid_items', 'Yhtä tuotetta enintään 20 kappaletta'); end if;
      v_acc := jsonb_set(v_acc, array[v_key], to_jsonb(v_sum), true);
    end if;
  end loop;

  if (select count(*) from jsonb_object_keys(v_acc)) + v_cust_n > 12 then
    perform booking._err('invalid_items', 'Enintään 12 riviä');
  end if;
  if (select count(*) from jsonb_object_keys(v_acc)) + v_cust_n < 1 then
    perform booking._err('nothing_to_pay', 'Ostoskori on tyhjä');
  end if;

  for r in select key, value from jsonb_each(v_acc) loop
    v_id := r.key::bigint;
    v_qty := (r.value #>> '{}')::int;
    select kp.id, kp.name, kp.name_en, kp.price, kp.vat_rate, kp.category, kp.active,
           c.pos_enabled, c.fridge_sale, c.age_restricted
      into pr
      from kb.products kp
      left join booking.product_config c on c.product_id = kp.id
     where kp.id = v_id;
    if not found or not coalesce(pr.active, false) or pr.price is null then
      perform booking._err('not_counter_product', 'Tuotetta ei voi myydä kassalla');
    end if;
    if pr.category in ('gift_card', 'season_card') then
      perform booking._err('not_counter_product', 'Lahjakortti ja kausikortti myydään omasta toiminnosta, ei tuotepainikkeena');
    end if;
    if pr.price < 0 or pr.price <> round(pr.price, 2) then perform booking._err('invalid_items', 'Tuotteen hinta ei ole kelvollinen'); end if;
    if p_channel = 'pos' then
      if not coalesce(pr.pos_enabled, false) then perform booking._err('not_counter_product', 'Tuote ei ole pikakassassa'); end if;
    else
      if not coalesce(pr.fridge_sale, false) or coalesce(pr.age_restricted, false) then
        perform booking._err('not_counter_product', 'Tuote ei ole myynnissä kylmälaitteessa');
      end if;
      perform booking._assert_fridge_product(v_id);
    end if;
    v_name := pr.name;
    v_line := round(pr.price * v_qty, 2);
    product_id := v_id; quantity := v_qty; product_name := v_name; unit_price := pr.price; vat_rate := pr.vat_rate; line_total := v_line;
    return next;
  end loop;

  for r in select value from jsonb_array_elements(v_custom) loop
    product_id := null;
    quantity := (r.value ->> 'quantity')::int;
    product_name := r.value ->> 'description';
    unit_price := (r.value ->> 'unit_price')::numeric;
    vat_rate := (r.value ->> 'vat_rate')::numeric;
    line_total := (r.value ->> 'line_total')::numeric;
    return next;
  end loop;
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_pos_catalog()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb;
begin
  perform booking._require_permission('pos.use');
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'vat_rate', p.vat_rate,
           'category', p.category, 'age_restricted', c.age_restricted, 'pos_sort', c.pos_sort)
           order by c.pos_sort, p.name), '[]'::jsonb)
    into v
    from booking.product_config c
    join kb.products p on p.id = c.product_id
   where c.pos_enabled and p.active and p.price is not null and p.category not in ('gift_card', 'season_card');
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_drinks_catalog(p_device text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ip text := coalesce(booking._client_ip(), 'unknown');
  v_code text := nullif(lower(btrim(coalesce(p_device, ''))), '');
  q booking.product_qr;
  p record;
  v_ok boolean := false;
  v_paths jsonb := jsonb_build_object('fi', booking._drinks_path('fi'), 'en', booking._drinks_path('en'));
begin
  if not booking._rate_limit('drinks-cat:' || v_ip, 60, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_code is null or v_code !~ '^[a-f0-9]{32}$' then
    return jsonb_build_object('ok', true, 'device', jsonb_build_object('unknown', true), 'products', '[]'::jsonb, 'paths', v_paths);
  end if;
  select * into q from booking.product_qr where code = v_code;
  if not found then
    return jsonb_build_object('ok', true, 'device', jsonb_build_object('unknown', true), 'products', '[]'::jsonb, 'paths', v_paths);
  end if;
  if q.active then
    select kp.id, kp.name, kp.name_en, kp.price into p
      from kb.products kp
      join booking.product_config c on c.product_id = kp.id
     where kp.id = q.product_id
       and c.fridge_sale and not c.age_restricted
       and kp.active and kp.price is not null
       and kp.category not in ('gift_card', 'season_card')
       and not booking._text_looks_like_alcohol(kp.name)
       and not booking._text_looks_like_alcohol(coalesce(kp.name_en, ''))
       and not booking._text_looks_like_alcohol(coalesce(kp.description, ''))
       and not booking._text_looks_like_alcohol(coalesce(kp.description_en, ''));
    v_ok := found;
  end if;
  if not q.active or not v_ok then
    return jsonb_build_object('ok', true, 'device', jsonb_build_object('label', q.label, 'active', false), 'products', '[]'::jsonb, 'paths', v_paths);
  end if;
  return jsonb_build_object('ok', true,
    'device', jsonb_build_object('label', q.label, 'active', true),
    'products', jsonb_build_array(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price)),
    'paths', v_paths);
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_gift_card_packages()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('ok', true, 'sale_enabled', booking._gc_flag('gift_cards.sale_enabled'), 'redeem_enabled', booking._gc_flag('gift_cards.redeem_enabled'),
    'max_cards_per_order', (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int, 'currency', 'EUR',
    'packages', coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en,
        'kind', p.kind, 'is_open', p.is_open, 'price', p.price, 'min_amount', p.min_amount, 'max_amount', p.max_amount, 'persons', p.persons,
        'min_persons', p.min_persons, 'max_persons', p.max_persons,
        'unit_price', case when not p.is_open and p.items is not null and not exists (
            select 1 from jsonb_array_elements(p.items) it where coalesce(it ->> 'price_type', 'per_person') <> 'per_person' or it ->> 'unit_price' is null)
          then booking._gc_package_amount(p.items, 1) end,
        'vat_rate', p.vat_rate, 'valid_months', p.valid_months, 'items', p.items) order by p.sort_order, p.code)
      from booking.gift_card_packages p where p.active), '[]'::jsonb))
$function$
;

CREATE OR REPLACE FUNCTION booking._public_buy_gift_card_impl(p_items jsonb, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_recipient_name text DEFAULT NULL::text, p_recipient_email text DEFAULT NULL::text, p_greeting text DEFAULT NULL::text, p_delivery_to text DEFAULT NULL::text, p_cover_message text DEFAULT NULL::text, p_deliver_on text DEFAULT NULL::text, p_deliver_time text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_ip text := booking._client_ip(); v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_cust bigint; v_res jsonb; v_status text; v_detail text; v_msg text;
begin
  if not booking._gc_flag('gift_cards.sale_enabled') then
    return jsonb_build_object('ok', false, 'code', 'sale_disabled', 'message', 'Lahjakorttien verkkomyynti ei ole vielä käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('gcbuy:ip:' || v_ip, (booking._setting('gift_cards.rl_buy_per_10min', '6'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('gcbuy:email:' || v_email, 4, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  v_status := case when v_mode = 'pay_later' then 'confirmed' else 'pending' end;
  begin
    v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_gift_card', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    v_res := booking._gc_sell(p_items, v_cust, 'web', p_locale, v_name, v_email, v_status, null, null, p_recipient_name, p_recipient_email, p_greeting, p_delivery_to, p_cover_message, p_deliver_on, p_deliver_time);
    insert into booking.payments(order_id, method, provider, status, amount)
    values ((v_res ->> 'order_id')::bigint, case when v_mode = 'pay_later' then 'pay_later' else 'visma_pay' end, case when v_mode = 'pay_later' then 'manual' else 'visma_pay' end,
            'pending', (v_res ->> 'total')::numeric);
    update booking.orders set payment_status = case when v_mode = 'pay_later' then 'unpaid' else 'pending' end where id = (v_res ->> 'order_id')::bigint;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token', 'status', v_status, 'total', v_res -> 'total',
    'payment_mode', v_mode, 'payment_url', null, 'cards', (select coalesce(jsonb_agg(c - 'id'), '[]'::jsonb) from jsonb_array_elements(v_res -> 'cards') c),
    'note', 'Kortit aktivoituvat ja koodit toimitetaan kun tilaus on maksettu');
end $function$
;

drop function booking.admin_set_product_sales_channels(bigint, text[]);
drop function booking.admin_list_sales_channels();
drop function booking._psc_to_config_trg();
drop function booking._psc_from_config_trg();
drop function booking._gc_package_in_shop(text);
drop function booking._public_channel_ok(bigint);
drop function booking._in_channel(bigint, text);
drop table booking.product_sales_channels;
drop table booking.sales_channels;
