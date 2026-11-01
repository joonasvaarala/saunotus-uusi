-- booking_226b: koulutuksen osakerrat. Ei muuta booking_226:ta (DEV:ssä jo versio 20261101121533).
-- Ilmoittautumisvaihtoehto (schedule_rules-rivi, jonka asiakas valitsee) osoittaa järjestettyyn
-- listaan kertoja. Osakerta voi olla toisen koulutustuotteen kerta (Full-3 = kolme retriittiä)
-- tai saman tuotteen oma kerta (Saunottajakoulutus-viikonloput, 15 päivän jatkopäivät).
-- Jokainen osakerta kuluttaa yhden paikan (max 6) ja yhden hengen huoneen valittaessa sen kerran poolista.
-- Jako on eksplisiittinen data, ei päivien päällekkäisyys. Kaikki osakerrat lukitaan id-järjestyksessä.
-- Verkkomaksu on yhä vain varausmaksu. Lisähinnat ovat tuotekohtaisia (training_addon_offers).
-- Rollback: rollbacks/20261101160000_booking_226b_ROLLBACK.sql
set local lock_timeout = '5s';

alter table booking.schedule_rules
  add column if not exists training_segment_only boolean not null default false;
comment on column booking.schedule_rules.training_segment_only is
  'booking_226b: true = kerta on vain toisen ilmoittautumisen osakerta, ei oma myyntivalinta.';

alter table booking.training_participants
  add column if not exists segments jsonb not null default '[]'::jsonb;
comment on column booking.training_participants.segments is
  'booking_226b: snapshot [{position, rule_id, label, starts_at, ends_at}]. Paikat ja huoneet kuluvat näistä kerroista.';

create table if not exists booking.training_segments (
  option_rule_id bigint not null references booking.schedule_rules(id) on delete cascade,
  position int not null check (position between 1 and 24),
  segment_rule_id bigint not null references booking.schedule_rules(id),
  primary key (option_rule_id, position),
  unique (option_rule_id, segment_rule_id)
);
comment on table booking.training_segments is
  'booking_226b: ilmoittautumisvaihtoehdon osakerrat järjestyksessä. Tyhjä lista = vaihtoehto on oma kertansa.';
create index if not exists training_segments_rule_idx on booking.training_segments (segment_rule_id);
alter table booking.training_segments enable row level security;
revoke all on booking.training_segments from public, anon, authenticated;
grant select on booking.training_segments to authenticated;
grant all on booking.training_segments to service_role;
drop policy if exists staff_read on booking.training_segments;
create policy staff_read on booking.training_segments for select to authenticated using ((select booking.is_staff()));

-- Koulutustuote ei paljasta kaupan lisäpalveluita (turve, vihta, pyyhe).
create or replace function booking._product_addon_codes(p_product_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare pc booking.product_config; v_cat text; v_modes text[];
begin
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found then return '[]'::jsonb; end if;
  select category into v_cat from kb.products where id = p_product_id;
  if v_cat in ('event', 'training') then return '[]'::jsonb; end if;
  if pc.public_slots or (pc.sale_kind = 'other' and pc.resource_class = 'resourced') then
    return coalesce((select jsonb_agg(a.code order by a.sort_order, a.id) from booking.product_addon_allow pa join booking.addons a on a.id = pa.addon_id
                      where pa.product_id = p_product_id and a.active and 'resource' = any (a.applies_modes)), '[]'::jsonb);
  end if;
  select array_agg(distinct r.mode::text) into v_modes from booking.schedule_rules r where r.product_id = p_product_id and r.active;
  return coalesce((select jsonb_agg(a.code order by a.sort_order, a.id) from booking.addons a where a.active and a.applies_modes && coalesce(v_modes, '{}'::text[])), '[]'::jsonb);
end $$;

create or replace function booking._training_segments_of(p_rule_id bigint)
returns table(sort_pos int, rule_id bigint)
language sql stable security definer set search_path = '' as $$
  select s.position, s.segment_rule_id
    from booking.training_segments s
   where s.option_rule_id = p_rule_id
  union all
  select 1, p_rule_id
   where not exists (select 1 from booking.training_segments s where s.option_rule_id = p_rule_id)
$$;

create or replace function booking._training_rule_seats_left(p_rule_id bigint)
returns integer language sql stable security definer set search_path = '' as $$
  select booking._pools_remaining(
    coalesce((select array_agg(rp.pool_id order by rp.pool_id) from booking.schedule_rule_pools rp where rp.rule_id = p_rule_id), '{}'::bigint[]),
    lower(booking._training_rule_range(p_rule_id)),
    upper(booking._training_rule_range(p_rule_id)))
$$;

-- Pienin vapaa paikkamäärä: valinnan oma pooli ja jokainen osakerta.
create or replace function booking._training_option_seats_left(p_rule_id bigint)
returns integer language sql stable security definer set search_path = '' as $$
  select min(n)::integer from (
    select booking._training_rule_seats_left(p_rule_id) as n
    union all
    select booking._training_rule_seats_left(s.rule_id)
      from booking._training_segments_of(p_rule_id) s
  ) q
$$;

create or replace function booking._training_segment_ids(p_rule_id bigint)
returns setof bigint language sql stable security definer set search_path = '' as $$
  select s.rule_id from booking._training_segments_of(p_rule_id) s
$$;

create or replace function booking._training_segment_json(p_rule_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'position', s.sort_pos, 'rule_id', s.rule_id,
      'label', r.label, 'label_en', r.label_en,
      'starts_at', lower(booking._training_rule_range(r.id)),
      'ends_at', upper(booking._training_rule_range(r.id))
    ) order by s.sort_pos), '[]'::jsonb)
    from booking._training_segments_of(p_rule_id) s
    join booking.schedule_rules r on r.id = s.rule_id
$$;

-- Huonepooli on osakertalista, ei päällekkäisten päivien arvaus.
create or replace function booking._training_single_room_pools(p_rule_id bigint)
returns setof bigint language sql stable security definer set search_path = '' as $$
  select r.id
    from booking.schedule_rules r
   where r.id in (select booking._training_segment_ids(p_rule_id))
     and r.single_room_max is not null
$$;

create or replace function booking._training_single_rooms_used(p_rule_id bigint)
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::integer
    from booking.training_participants tp
    join booking.reservations res on res.id = tp.reservation_id
   where tp.single_room
     and booking._res_active(res.status, res.hold_expires_at)
     and (
       exists (
         select 1 from jsonb_array_elements(coalesce(tp.segments, '[]'::jsonb)) e
          where e ->> 'rule_id' ~ '^[0-9]+$' and (e ->> 'rule_id')::bigint = p_rule_id)
       or (jsonb_array_length(coalesce(tp.segments, '[]'::jsonb)) = 0 and res.rule_id = p_rule_id))
$$;

create or replace function booking._training_hold_segment(p_order_id bigint, p_rule_id bigint, p_hold timestamptz)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  r booking.schedule_rules;
  v_pools bigint[];
  v_id bigint;
  v_start timestamptz;
  v_end timestamptz;
begin
  select * into r from booking.schedule_rules where id = p_rule_id and kind = 'event' and active;
  if not found then perform booking._err('segment_missing', 'Osakerta puuttuu'); end if;
  select coalesce(array_agg(rp.pool_id order by rp.pool_id), '{}') into v_pools
    from booking.schedule_rule_pools rp where rp.rule_id = r.id;
  if cardinality(v_pools) = 0 then perform booking._err('segment_pool', 'Osakerralta puuttuu kapasiteetti'); end if;
  v_start := lower(booking._training_rule_range(r.id));
  v_end := upper(booking._training_rule_range(r.id));
  if v_start is null or v_end is null or v_end <= v_start then
    perform booking._err('segment_missing', 'Osakerran aika puuttuu');
  end if;
  if coalesce(booking._pools_remaining(v_pools, v_start, v_end), 0) < 1 then
    perform booking._err('capacity_exceeded', 'Ei tarpeeksi vapaita paikkoja');
  end if;
  insert into booking.reservations(
      order_id, product_id, rule_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status, hold_expires_at, notes)
  values (p_order_id, r.product_id, r.id, r.space_id, r.mode, v_start, v_end, 1, v_pools, 'pending', p_hold, 'training_segment')
  returning id into v_id;
  return v_id;
end $$;

create or replace function booking.public_availability(p_product_id bigint, p_from date, p_to date)
returns table(rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)
language plpgsql stable security definer set search_path = '' as $$
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
      left join lateral (
        select booking._training_option_seats_left(s.rule_id) as left_n
         where exists (select 1 from booking.training_segments ts where ts.option_rule_id = s.rule_id)
      ) cap on true
     where s.status <> 'closed'
       and not rr.training_segment_only;
end $$;

create or replace function booking.public_training_checkout(p_rule_id bigint, p_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
end $$;

create or replace function booking.public_create_training_signup(
  p_rule_id bigint, p_date date, p_name text, p_email text, p_phone text,
  p_country text, p_language text, p_locale text, p_note text,
  p_marketing_consent boolean, p_privacy_consent boolean, p_addons text[] default '{}'::text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
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
    for v_sid in
      select s.rule_id from booking._training_segments_of(p_rule_id) s
       where s.rule_id is distinct from p_rule_id
       order by s.rule_id
    loop
      perform booking._training_hold_segment(v_order, v_sid, v_hold_at);
    end loop;
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
end $$;

create or replace function booking.admin_training_segments_get(p_option_rule_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'position', s.position, 'rule_id', s.segment_rule_id, 'label', r.label, 'product_id', r.product_id, 'date', r.valid_from
      ) order by s.position)
      from booking.training_segments s
      join booking.schedule_rules r on r.id = s.segment_rule_id
     where s.option_rule_id = p_option_rule_id
  ), '[]'::jsonb);
end $$;

create or replace function booking.admin_training_segments_set(p_option_rule_id bigint, p_segment_rule_ids bigint[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r booking.schedule_rules;
  v_product bigint;
  v_ids bigint[] := coalesce(p_segment_rule_ids, '{}'::bigint[]);
  v_id bigint;
  v_pos int := 0;
begin
  perform booking._require_permission('catalog.edit');
  if cardinality(v_ids) > 24 then perform booking._err('invalid_param', 'Osakertoja enintään 24'); end if;
  if exists (select 1 from unnest(v_ids) x group by x having count(*) > 1) then
    perform booking._err('invalid_param', 'Sama osakerta kahdesti');
  end if;
  select * into r from booking.schedule_rules where id = p_option_rule_id and kind = 'event' and active for update;
  if not found then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
  if r.training_segment_only then perform booking._err('invalid_param', 'Piilotettu osakerta ei ole ilmoittautumisvaihtoehto'); end if;
  select p.id into v_product from kb.products p where p.id = r.product_id and p.category = 'training';
  if v_product is null then perform booking._err('not_event', 'Tuote ei ole koulutus'); end if;
  foreach v_id in array v_ids loop
    if not exists (
      select 1 from booking.schedule_rules sr
      join kb.products p on p.id = sr.product_id and p.category = 'training'
      where sr.id = v_id and sr.kind = 'event' and sr.active
    ) then perform booking._err('segment_missing', 'Osakerta ei ole koulutuksen kerta'); end if;
  end loop;
  update booking.schedule_rules sr
     set training_segment_only = false
   where sr.product_id = v_product
     and sr.id <> p_option_rule_id
     and sr.id in (select s.segment_rule_id from booking.training_segments s where s.option_rule_id = p_option_rule_id)
     and not exists (
       select 1 from booking.training_segments o
        where o.segment_rule_id = sr.id and o.option_rule_id <> p_option_rule_id);
  delete from booking.training_segments where option_rule_id = p_option_rule_id;
  foreach v_id in array v_ids loop
    v_pos := v_pos + 1;
    insert into booking.training_segments(option_rule_id, position, segment_rule_id)
    values (p_option_rule_id, v_pos, v_id);
  end loop;
  update booking.schedule_rules sr
     set training_segment_only = true
   where sr.id = any (v_ids)
     and sr.id <> p_option_rule_id
     and sr.product_id = v_product;
  return booking.admin_training_segments_get(p_option_rule_id);
end $$;

create or replace function booking.admin_event_participants(p_product_id bigint, p_rule_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cat text;
begin
  perform booking._require_staff();
  select p.category into v_cat from kb.products p where p.id = p_product_id;
  if v_cat is null or v_cat not in ('event', 'training') then perform booking._err('not_event', 'Tuote ei ole tapahtuma tai koulutus'); end if;
  if p_rule_id is not null and not exists (
    select 1 from booking.schedule_rules r where r.id = p_rule_id and r.product_id = p_product_id and r.kind = 'event'
  ) then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'reservation_id', x.id, 'order_id', o.id, 'order_no', o.order_no, 'rule_id', sr.id,
      'source', case when x.external_source = 'johku' then 'johku' else 'shop' end,
      'occurrence_label', sr.label, 'occurrence_label_en', sr.label_en, 'starts_at', x.starts_at,
      'name', c.name, 'email', c.email, 'phone', c.phone, 'persons', x.persons,
      'order_status', o.status, 'payment_status', o.payment_status, 'reservation_status', x.status,
      'booked_at', o.created_at, 'customer_note', nullif(left(coalesce(o.customer_note, ''), 1000), ''),
      'option_label', po.name, 'option_label_en', po.name_en,
      'adults', case when x.participant_breakdown ->> 'adults' ~ '^[0-9]{1,3}$' then (x.participant_breakdown ->> 'adults')::int end,
      'children', case when x.participant_breakdown ->> 'children' ~ '^[0-9]{1,3}$' then (x.participant_breakdown ->> 'children')::int end,
      'staff_note', n.note,
      'country', tp.country, 'language', tp.language, 'is_foreign', tp.is_foreign,
      'single_room', coalesce(tp.single_room, false),
      'course_price', tp.course_price, 'addons', tp.addons, 'addons_total', tp.addons_total,
      'participant_total', tp.total, 'deposit_paid', tp.deposit_paid, 'remaining', tp.remaining,
      'capacity_only', tp.id is not null and tp.reservation_id is distinct from x.id
    ) order by x.starts_at, c.name, x.id)
    from booking.schedule_rules sr
    cross join lateral booking._event_rule_res_ids(sr.id) i
    join booking.reservations x on x.id = i.id
    join booking.orders o on o.id = x.order_id
    left join booking.customers c on c.id = o.customer_id
    left join booking.product_options po on po.id = x.product_option_id
    left join booking.event_participant_notes n on n.reservation_id = x.id
    left join booking.training_participants tp on tp.order_id = o.id
    where sr.kind = 'event' and sr.product_id = p_product_id
      and (p_rule_id is null or sr.id = p_rule_id)
      and x.status in ('pending', 'confirmed', 'completed', 'no_show', 'cancelled')
      and (x.status <> 'pending' or x.hold_expires_at > now())
  ), '[]'::jsonb);
end $$;

create or replace function booking.email_outbox_claim(p_limit integer default 20)
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(
    case when z.item->>'kind' = 'payment_link_reminder' then
      (case when exists (
          select 1 from booking.email_outbox e
          join booking.payments p on p.id = e.payment_id
          join booking.orders o on o.id = e.order_id
         where e.id = (z.item->>'id')::bigint
           and p.status = 'pending' and p.provider <> 'manual' and p.external_source is null and o.external_source is null
           and (p.link_expires_at is null or p.link_expires_at > now()))
        then z.item
        else z.item || jsonb_build_object('payment', (coalesce(z.item->'payment', '{}'::jsonb) - 'link_url'))
       end)
      || coalesce((select jsonb_build_object('payment_reminder', jsonb_build_object(
            'n', e.payload -> 'reminder_no', 'kind', e.payload ->> 'reminder_kind',
            'cancel_if_unpaid', coalesce((e.payload ->> 'cancel_if_unpaid')::boolean, false),
            'due_at', e.payload -> 'due_at'))
          from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    else case when z.item->>'kind' = 'order_confirmation' then
      z.item || coalesce((
        select jsonb_build_object('order', coalesce(z.item->'order', '{}'::jsonb) || jsonb_build_object(
          'deposit', true,
          'training', jsonb_build_object(
            'course_price', tp.course_price, 'addons_total', tp.addons_total, 'total', tp.total,
            'deposit_paid', tp.deposit_paid, 'remaining', tp.remaining, 'addons', tp.addons,
            'segments', tp.segments)))
          from booking.email_outbox e
          join booking.training_participants tp on tp.order_id = e.order_id
         where e.id = (z.item->>'id')::bigint
         order by tp.id limit 1
      ), '{}'::jsonb)
    else z.item end end
  order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_215(p_limit)) with ordinality as z(item, ord);
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'booking._training_segments_of(bigint)',
    'booking._training_rule_seats_left(bigint)',
    'booking._training_option_seats_left(bigint)',
    'booking._training_segment_ids(bigint)',
    'booking._training_segment_json(bigint)',
    'booking._training_hold_segment(bigint, bigint, timestamp with time zone)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
revoke all on function booking.admin_training_segments_get(bigint) from public, anon;
grant execute on function booking.admin_training_segments_get(bigint) to authenticated, service_role;
revoke all on function booking.admin_training_segments_set(bigint, bigint[]) from public, anon;
grant execute on function booking.admin_training_segments_set(bigint, bigint[]) to authenticated, service_role;

comment on function booking.public_create_training_signup(bigint, date, text, text, text, text, text, text, text, boolean, boolean, text[]) is
  'booking_226b: varausmaksu verkossa. Osakerrat kuluttavat paikan ja yhden hengen huoneen. Kaikki tai ei mitään.';
