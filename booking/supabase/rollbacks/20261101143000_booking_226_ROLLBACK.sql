-- ROLLBACK booking_226 (20261101143000_booking_226_training_signup.sql). Uudelleenajettava.
-- Poistaa koulutuksen ilmoittautumisen: training_participants, training_addon_offers, link-kanavan,
-- course_price, deposit_amount ja single_room_max. Palauttaa korvatut funktiot täsmälleen mainin muotoon
-- ennen booking_226:ta (pg_get_functiondef). Odotetut md5(pg_get_functiondef) ajon jälkeen:

--   booking._event_rule_json: f75c969f5620e57d69dee85cee62aacf
--   booking.admin_event_participants: dc6ec356d490eb60a8780a7cb5c9d86b
--   booking.admin_event_rule_upsert: e5387d87c6be2400c6be7f37c82e0c26
--   booking.admin_event_set_channels: e340b362893a19c65f4404f0c09ed1dc
--   booking.admin_update_product_config: d1dc15f168234dfe8274ffd2d660c299
--   booking.customers_drop_event_notes: 0e9642dce2393cc9d203e47fad4745a6
--   booking.email_outbox_claim: 530bf169dfab8b59e4a456dbf94c7d6e
--   booking.public_availability: 98eb72261254d7f47cae7ded66ac922c
--   booking.public_catalog: 2294bbb6675677aea1dc813b151fe8e4
--   booking.public_create_booking: 6bf51ffd45c259ef5546aa19f63f5066
--   booking.public_get_booking: 3a8e4b3eee34b07e58acb06b679ff709
--   booking.public_get_order: d95b749725c672d45025f34be71fdbb6
-- Lopussa tarkistus: jos jokin md5 ei täsmää, rollback keskeytyy ja koko transaktio perutaan.
-- Ennen ajoa: link-kanavan tuotteet menettävät kanavan link (jäljelle jää shop/widget tai null).
set local lock_timeout = '5s';

-- 1) korvatut funktiot entiseen muotoon (ennen uusien objektien poistoa)

CREATE OR REPLACE FUNCTION booking._event_rule_json(p_rule_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', r.id, 'product_id', r.product_id, 'kind', r.kind, 'date', r.valid_from, 'start_time', to_char(r.start_time, 'HH24:MI'),
    'duration_minutes', r.duration_minutes,
    'starts_at', (r.valid_from + r.start_time) at time zone booking._tz(),
    'ends_at', ((r.valid_from + r.start_time) + make_interval(mins => r.duration_minutes)) at time zone booking._tz(),
    'max_persons', r.max_persons, 'min_persons', r.min_persons, 'deadline_minutes', r.deadline_minutes,
    'label', r.label, 'label_en', r.label_en, 'active', r.active, 'cancelled_at', r.cancelled_at,
    'price_variant_id', r.price_variant_id, 'space_id', r.space_id,
    'pool_id', (select pr.id from booking.resources pr where pr.code = 'event_rule_' || r.id::text),
    -- booking_213: myydyt = uuden kaupan liput (rule_id) + kerralle kohdistuvat Johku-varaukset (_event_rule_res_ids).
    'sold_persons', (select coalesce(sum(x.persons), 0)::int from booking._event_rule_res_ids(r.id) i
                      join booking.reservations x on x.id = i.id
                      where booking._res_active(x.status, x.hold_expires_at)),
    'johku_persons', (select coalesce(sum(x.persons), 0)::int from booking._event_rule_res_ids(r.id) i
                      join booking.reservations x on x.id = i.id
                      where i.external and booking._res_active(x.status, x.hold_expires_at)),
    'reservation_count', (select count(*)::int from booking._event_rule_res_ids(r.id) i),
    'johku_count', (select count(*)::int from booking._event_rule_res_ids(r.id) i where i.external),
    'waitlist_count', (select count(*)::int from booking.waitlist_entries w where w.rule_id = r.id and w.status in ('waiting', 'notified')),
    'blocks', coalesce((select jsonb_agg(booking._event_block_json(b) order by b.sort_order, b.id)
                          from booking.event_resource_blocks b where b.rule_id = r.id), '[]'::jsonb))
  from booking.schedule_rules r where r.id = p_rule_id
$function$;

CREATE OR REPLACE FUNCTION booking.admin_event_participants(p_product_id bigint, p_rule_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      'staff_note', n.note
    ) order by x.starts_at, c.name, x.id)
    from booking.schedule_rules sr
    cross join lateral booking._event_rule_res_ids(sr.id) i
    join booking.reservations x on x.id = i.id
    join booking.orders o on o.id = x.order_id
    left join booking.customers c on c.id = o.customer_id
    left join booking.product_options po on po.id = x.product_option_id
    left join booking.event_participant_notes n on n.reservation_id = x.id
    where sr.kind = 'event' and sr.product_id = p_product_id
      and (p_rule_id is null or sr.id = p_rule_id)
      and x.status in ('pending', 'confirmed', 'completed', 'no_show', 'cancelled')
      and (x.status <> 'pending' or x.hold_expires_at > now())
  ), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_event_rule_upsert(p_id bigint DEFAULT NULL::bigint, p_product_id bigint DEFAULT NULL::bigint, p_patch jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['date','start_time','duration_minutes','max_persons','min_persons','deadline_minutes','label','label_en','active','price_variant_id'];
  k text; r booking.schedule_rules; p kb.products; pc booking.product_config;
  v_date date; v_start time; v_dur integer; v_max integer; v_min integer; v_deadline integer; v_label text; v_label_en text; v_active boolean;
  v_variant bigint; v_space bigint; v_sold integer; v_ext integer; v_has_res boolean; v_id bigint; v_auto_label boolean := false;
  v_moved integer := 0; v_new_start timestamptz; v_new_end timestamptz;
begin
  perform booking._require_permission('catalog.edit');
  p_patch := coalesce(p_patch, '{}'::jsonb);
  if jsonb_typeof(p_patch) <> 'object' then perform booking._err('invalid_param', 'p_patch puuttuu'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;

  if p_id is not null then
    select * into r from booking.schedule_rules where id = p_id for update;
    if not found or r.kind <> 'event' then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
    if p_product_id is not null and p_product_id <> r.product_id then perform booking._err('invalid_param', 'Kerta kuuluu toiseen tuotteeseen'); end if;
    p_product_id := r.product_id;
  end if;
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  if p.category not in ('event', 'training') then perform booking._err('not_event', 'Tuote ei ole tapahtuma tai koulutus'); end if;
  select * into pc from booking.product_config where product_id = p.id;
  if not found then perform booking._err('not_found', 'Tuotteen varausasetukset puuttuvat'); end if;

  if p_patch ? 'date' then
    if coalesce(p_patch ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' then perform booking._err('invalid_param', 'Päivä muodossa VVVV-KK-PP'); end if;
    begin v_date := (p_patch ->> 'date')::date; exception when others then perform booking._err('invalid_param', 'Virheellinen päivä'); end;
  else v_date := r.valid_from; end if;
  if p_patch ? 'start_time' then
    if coalesce(p_patch ->> 'start_time', '') !~ '^\d{1,2}[:.]\d{2}(:00)?$' then perform booking._err('invalid_param', 'Alkuaika muodossa HH:MM'); end if;
    begin v_start := replace(p_patch ->> 'start_time', '.', ':')::time; exception when others then perform booking._err('invalid_param', 'Virheellinen alkuaika'); end;
  else v_start := r.start_time; end if;
  if v_date is null then perform booking._err('invalid_param', 'Päivä puuttuu'); end if;
  if v_start is null then perform booking._err('invalid_param', 'Alkuaika puuttuu'); end if;
  -- booking_202 (Joonas 29.10.): olemassa olevaa kertaa ei voi siirtää menneisyyteen (uusi alkuhetki <= nyt).
  if p_id is not null and (v_date, v_start) is distinct from (r.valid_from, r.start_time)
     and ((v_date + v_start) at time zone booking._tz()) <= now() then
    perform booking._err('past_move', 'Kertaa ei voi siirtää menneisyyteen');
  end if;

  v_dur := case when p_patch ? 'duration_minutes' then booking._event_jint(p_patch -> 'duration_minutes', 'duration_minutes', 1, 20160)
                else coalesce(r.duration_minutes, pc.duration_minutes, p.duration_minutes) end;
  if v_dur is null then perform booking._err('invalid_param', 'Kesto puuttuu'); end if;
  if v_dur > 1440 and p.category <> 'training' then
    perform booking._err('multi_day_training_only', 'Monipäiväinen kerta (yksi lippu) on sallittu vain koulutuksille');
  end if;
  v_max := case when p_patch ? 'max_persons' then booking._event_jint(p_patch -> 'max_persons', 'max_persons', 1, 1000)
                when p_id is not null then r.max_persons else pc.max_persons end;
  v_min := coalesce(case when p_patch ? 'min_persons' then booking._event_jint(p_patch -> 'min_persons', 'min_persons', 1, 1000) end,
                    r.min_persons, pc.min_persons, 1);
  if v_max is not null and v_min > v_max then perform booking._err('invalid_param', 'Vähimmäismäärä on suurempi kuin enimmäismäärä'); end if;
  v_deadline := coalesce(case when p_patch ? 'deadline_minutes' then booking._event_jint(p_patch -> 'deadline_minutes', 'deadline_minutes', 0, 43200) end,
                         r.deadline_minutes, 0);
  v_active := coalesce(case when p_patch ? 'active' then booking._event_jbool(p_patch -> 'active', 'active') end, r.active, true);
  if p_patch ? 'price_variant_id' then
    v_variant := booking._event_jint(p_patch -> 'price_variant_id', 'price_variant_id', 1, 2000000000);
    if v_variant is not null and not exists (select 1 from kb.product_price_variants v where v.id = v_variant and v.product_id = p.id) then
      perform booking._err('invalid_param', 'Hintavaihtoehto ei kuulu tuotteeseen');
    end if;
  else v_variant := r.price_variant_id; end if;
  if p_patch ? 'label' then v_label := nullif(btrim(coalesce(p_patch ->> 'label', '')), ''); else v_label := r.label; end if;
  if v_label is null
     or (p_id is not null and not (p_patch ? 'label') and r.label = to_char(r.valid_from, 'DD.MM.YYYY') || ' klo ' || to_char(r.start_time, 'HH24.MI')) then
    v_label := to_char(v_date, 'DD.MM.YYYY') || ' klo ' || to_char(v_start, 'HH24.MI');
    v_auto_label := true;
  end if;
  if char_length(v_label) > 200 then perform booking._err('invalid_param', 'Nimi on liian pitkä'); end if;
  if p_patch ? 'label_en' then v_label_en := nullif(btrim(coalesce(p_patch ->> 'label_en', '')), ''); else v_label_en := r.label_en; end if;
  if v_label_en is not null and char_length(v_label_en) > 200 then perform booking._err('invalid_param', 'Englanninkielinen nimi on liian pitkä'); end if;

  if p_id is null then
    select id into v_space from booking.resources where code = 'ei_resurssia';
    if v_space is null then perform booking._err('not_found', 'Resurssia ei_resurssia ei löydy'); end if;
    insert into booking.schedule_rules(product_id, label, label_en, mode, space_id, weekdays, start_time, duration_minutes, valid_from, valid_to,
                                       min_persons, max_persons, price_mode, price_variant_id, deadline_minutes, active, sort_order, kind, notes)
    values (p.id, v_label, v_label_en, 'shared', v_space, array[extract(isodow from v_date)::smallint], v_start, v_dur, v_date, v_date,
            v_min, v_max, 'per_person', v_variant, v_deadline, v_active, 100, 'event', 'booking_158: tapahtumakerta')
    returning id into v_id;
  else
    -- booking_213: myydyt sisältävät kerralle kohdistuvat Johku-varaukset.
    select coalesce(sum(x.persons), 0)::int, count(*) > 0, coalesce(sum(x.persons) filter (where i.external), 0)::int
      into v_sold, v_has_res, v_ext
      from booking._event_rule_res_ids(r.id) i join booking.reservations x on x.id = i.id
     where booking._res_active(x.status, x.hold_expires_at);
    -- Johku-varaukset kohdistuvat kertaan alkuajan perusteella eivätkä siirry tämän mukana.
    if v_ext > 0 and (v_date, v_start) is distinct from (r.valid_from, r.start_time) then
      perform booking._err('has_reservations', 'Kerralla on Johku-varauksia: aikaa ei voi siirtää');
    end if;
    -- booking_202: aikaa saa siirtää. Passivointi ei käy, jos lippuja on (käytä admin_event_occurrence_cancel).
    if v_has_res and r.active and not v_active then
      perform booking._err('has_reservations', 'Kerralla on varauksia: kertaa ei voi passivoida. Peruuta kerta.');
    end if;
    -- Hallinnan ylibuukkaama kerta (booking_192) on yhä muokattavissa; enimmäismäärää ei silti voi laskea alle myydyn.
    if p_patch ? 'max_persons' and coalesce(v_max, pc.max_persons) is not null and coalesce(v_max, pc.max_persons) < v_sold then
      perform booking._err('max_below_sold', format('Enimmäismäärä ei voi olla pienempi kuin myydyt paikat (%s)', v_sold));
    end if;
    update booking.schedule_rules
       set label = v_label, label_en = v_label_en, weekdays = array[extract(isodow from v_date)::smallint], start_time = v_start,
           duration_minutes = v_dur, valid_from = v_date, valid_to = v_date, min_persons = v_min, max_persons = v_max,
           price_variant_id = v_variant, deadline_minutes = v_deadline, active = v_active,
           cancelled_at = case when v_active then null else cancelled_at end
     where id = r.id;
    v_id := r.id;
    if (v_date, v_start, v_dur) is distinct from (r.valid_from, r.start_time, r.duration_minutes) then
      v_new_start := (v_date + v_start) at time zone booking._tz();
      v_new_end := v_new_start + make_interval(mins => v_dur);
      -- Kerran oma pooli: myydyt paikat siirtyvät sellaisenaan. Pooli nostetaan hetkeksi myytyyn määrään, jotta
      -- hallinnan ylibuukkaama kerta siirtyy; _event_rule_pool_sync palauttaa kapasiteetin alla. Uusia paikkoja ei synny.
      update booking.resources set capacity = v_sold - v_ext where code = 'event_rule_' || r.id::text and capacity < v_sold - v_ext and v_sold - v_ext > 0;
      -- Vanhentuneita pitoja ei siirretä (reservations_validate perii ne _expire_holdsilla saman lauseen aikana).
      update booking.reservations x
         set starts_at = v_new_start, ends_at = v_new_end
       where x.rule_id = r.id
         and (booking._res_active(x.status, x.hold_expires_at) or x.status in ('completed', 'no_show'));
      get diagnostics v_moved = row_count;
      update booking.waitlist_entries w
         set starts_at = v_new_start, ends_at = v_new_end, session_date = v_date
       where w.rule_id = r.id and w.status in ('waiting', 'notified');
    end if;
  end if;

  perform booking._event_rule_pool_sync(v_id);
  perform booking._event_sync_blocks(v_id);
  perform booking._event_raise_conflicts(v_id);
  perform booking._texts_register_sources();
  return booking._event_rule_json(v_id) || jsonb_build_object('moved_bookings', v_moved);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_event_set_channels(p_product_id bigint, p_channels text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v text[];
begin
  perform booking._require_permission('catalog.edit');
  if not exists (select 1 from booking.product_config where product_id = p_product_id) then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  select coalesce(array_agg(distinct c order by c), '{}'::text[]) into v from unnest(coalesce(p_channels, '{}'::text[])) c where c is not null;
  if not (v <@ array['shop', 'widget']::text[]) then perform booking._err('invalid_param', 'Kanavat: shop, widget'); end if;
  update booking.product_config set channels = v where product_id = p_product_id and channels is distinct from v;
  return jsonb_build_object('ok', true, 'product_id', p_product_id, 'channels', to_jsonb(v));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_update_product_config(p_product_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare allowed text[] := array['bookable','shop_visible','sort_order','min_persons','max_persons','notes',
                                'lifecycle','resource_class','closure_group','duration_minutes','required_skill',
                                'therapists_needed','therapist_offset_min','therapist_minutes','audience',
                                'pos_enabled','pos_sort','fridge_sale','age_restricted'];
  k text; c booking.product_config; v_age boolean; v_fridge boolean; v_sort int;
begin
  perform booking._require_permission('catalog.edit');
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then perform booking._err('invalid_param', 'p_patch'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'audience' and coalesce(p_patch ->> 'audience', '') not in ('consumer', 'business') then
    perform booking._err('invalid_audience', 'Näkyvyys on consumer tai business');
  end if;
  select * into c from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotteella ei ole varauskonfiguraatiota'); end if;
  v_age := case when p_patch ? 'age_restricted' then (p_patch ->> 'age_restricted')::boolean else c.age_restricted end;
  v_fridge := case when p_patch ? 'fridge_sale' then (p_patch ->> 'fridge_sale')::boolean else c.fridge_sale end;
  if p_patch ? 'age_restricted' and v_age and not (p_patch ? 'fridge_sale') then
    v_fridge := false;
  end if;
  if v_age and v_fridge then
    perform booking._err('age_restricted', 'Ikärajallista tuotetta ei voi myydä kylmälaitteessa');
  end if;
  if p_patch ? 'pos_sort' then
    v_sort := (p_patch ->> 'pos_sort')::int;
    if v_sort < 0 or v_sort > 10000 then perform booking._err('invalid_param', 'Järjestys 0–10000'); end if;
  end if;
  update booking.product_config set
    bookable = case when p_patch ? 'bookable' then (p_patch ->> 'bookable')::boolean else bookable end,
    shop_visible = case when p_patch ? 'shop_visible' then (p_patch ->> 'shop_visible')::boolean else shop_visible end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end,
    min_persons = case when p_patch ? 'min_persons' then (p_patch ->> 'min_persons')::int else min_persons end,
    max_persons = case when p_patch ? 'max_persons' then (p_patch ->> 'max_persons')::int else max_persons end,
    notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end,
    lifecycle = case when p_patch ? 'lifecycle' then p_patch ->> 'lifecycle' else lifecycle end,
    resource_class = case when p_patch ? 'resource_class' then p_patch ->> 'resource_class' else resource_class end,
    closure_group = case when p_patch ? 'closure_group' then nullif(btrim(p_patch ->> 'closure_group'), '') else closure_group end,
    duration_minutes = case when p_patch ? 'duration_minutes' then (p_patch ->> 'duration_minutes')::int else duration_minutes end,
    required_skill = case when p_patch ? 'required_skill' then nullif(btrim(p_patch ->> 'required_skill'), '') else required_skill end,
    therapists_needed = case when p_patch ? 'therapists_needed' then (p_patch ->> 'therapists_needed')::int else therapists_needed end,
    therapist_offset_min = case when p_patch ? 'therapist_offset_min' then (p_patch ->> 'therapist_offset_min')::int else therapist_offset_min end,
    therapist_minutes = case when p_patch ? 'therapist_minutes' then (p_patch ->> 'therapist_minutes')::int else therapist_minutes end,
    audience = case when p_patch ? 'audience' then p_patch ->> 'audience' else audience end,
    pos_enabled = case when p_patch ? 'pos_enabled' then (p_patch ->> 'pos_enabled')::boolean else pos_enabled end,
    pos_sort = case when p_patch ? 'pos_sort' then (p_patch ->> 'pos_sort')::int else pos_sort end,
    fridge_sale = v_fridge,
    age_restricted = v_age
   where product_id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotteella ei ole varauskonfiguraatiota'); end if;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION booking.customers_drop_event_notes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  delete from booking.event_participant_notes n
   using booking.reservations x, booking.orders o
   where n.reservation_id = x.id and x.order_id = o.id and o.customer_id = new.id;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    else z.item end
  order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_215(p_limit)) with ordinality as z(item, ord);
$function$;

CREATE OR REPLACE FUNCTION booking.public_availability(p_product_id bigint, p_from date, p_to date)
 RETURNS TABLE(rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_product_id is null or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 92 päivää)');
  end if;
  if not exists (select 1 from booking.product_config pc join kb.products p on p.id = pc.product_id
                  where pc.product_id = p_product_id and pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
                    and 'shop' = any (booking._channels_effective(pc.channels, p.category))) then  -- booking_158: kanava
    return;
  end if;
  return query
    select s.rule_id, s.label, s.mode, s.session_date, s.starts_at, s.ends_at,
           case when s.status = 'closed' then 'closed'
                when s.mode = 'exclusive' and s.status = 'unavailable'
                     and booking._waitlist_private_taken(s.rule_id, s.starts_at, s.ends_at) then 'full'
                else s.status end,
           s.remaining, s.min_persons, s.max_persons, s.price_mode, s.unit_price, s.base_price, s.included_persons, s.extra_person_price,
           s.label_en
      from booking._sessions(greatest(p_from, (now() at time zone booking._tz())::date),
                             least(p_to, (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int),
                             p_product_id, true) s
     where s.status <> 'closed';
end $function$;

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

CREATE OR REPLACE FUNCTION booking.public_create_booking(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb)
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
end $function$;

CREATE OR REPLACE FUNCTION booking.public_get_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; res jsonb; adds jsonb; cust text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_conf_n integer; v_conf_start timestamptz; v_kind text; v_supported boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'product_id', r.product_id, 'rule_id', r.rule_id,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode, 'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at,
           'ritual_addon', booking._is_ritual_addon_item(it.id))   -- booking_166: vuoron lisäpalveluna varattu saunarituaali (näytetään vuoron jälkeen)
         order by booking._is_ritual_addon_item(it.id), r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id and it.kind = 'reservation';
  select jsonb_agg(jsonb_build_object('addon_id', it.addon_id, 'name', it.product_name, 'name_en', it.price_breakdown ->> 'name_en',
           'quantity', it.quantity, 'unit_price', it.unit_price_gross, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'max_per_person', ad.max_per_person) order by it.id)
    into adds from booking.order_items it left join booking.addons ad on ad.id = it.addon_id where it.order_id = o.id and it.kind = 'addon';
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  -- booking_25: varaustyyppi. 'rules' = sääntöpohjainen (muutettavissa public_change_booking), 'slots' = verkossa tehty hoitovaraus (public_change_treatment_booking), 'other' = ei muutettavissa verkossa (tuonti/ylläpito)
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;
  v_supported := v_kind in ('rules', 'slots');
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'invoice_method', case when o.customer_kind <> 'private' then o.billing ->> 'invoice_method' end, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_supported),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours,
           'has_ritual_addon', exists (select 1 from booking.order_items x where x.order_id = o.id and x.kind = 'reservation' and booking._is_ritual_addon_item(x.id)),
           'booking_kind', v_kind, 'change_via', case v_kind when 'slots' then 'public_change_treatment_booking' when 'rules' then 'public_change_booking' end,
           'invoice_locked', booking._order_invoice_locked(o.id))
         || booking._checkout_state_json(o.id)
         || jsonb_build_object('pending_additions', booking._pending_additions_json(o.id));
end $function$;

CREATE OR REPLACE FUNCTION booking.public_get_order(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
  v_cancel_dl timestamptz; v_cancel_closed boolean;   -- booking_149: asiakkaan peruutuspyynnön takaraja
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('get', p_token, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  select split_part(c.name, ' ', 1) into v_cust from booking.customers c where c.id = o.customer_id;
  v_bal := booking._order_balance(o.id);
  v_status := case when o.status = 'pending' and exists (select 1 from booking.reservations r where r.order_id = o.id) and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;
  v_online := booking._montonio_online();
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'), 'option_choices', booking._product_options_json(r.product_id),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', a.addon_id, 'name', a.product_name, 'quantity', a.quantity, 'line_total', a.line_total_gross) order by a.id)
                                 from booking.order_items a where a.parent_item_id = r.order_item_id and a.kind = 'addon'), '[]'::jsonb)) order by r.starts_at), '[]'::jsonb)
    into v_res from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'amount', p.amount, 'paid_at', p.paid_at,
           'method_label', case when p.provider in ('montonio', 'visma_pay', 'mobilepay') or p.method in ('montonio', 'visma_pay', 'mobilepay')
                                then case when coalesce(o.locale, 'fi') = 'en' then 'Pay online' else 'Maksa verkossa' end
                                else coalesce(pm.label, p.method) end,
           'link_token', case when p.status = 'pending' and (p.provider = 'montonio' or (p.provider in ('visma_pay', 'mobilepay') and p.provider_ref is null)) and (p.link_expires_at is null or p.link_expires_at > now()) then p.link_token end,
           'link_path', case when p.status = 'pending' and (p.provider = 'montonio' or (p.provider in ('visma_pay', 'mobilepay') and p.provider_ref is null)) and (p.link_expires_at is null or p.link_expires_at > now()) then v_pl || '?p=' || p.link_token end,
           'refunded', p.refunded_amount,
           'refund_pending', exists (select 1 from booking.refunds rf where rf.payment_id = p.id and rf.status in ('requested', 'processing'))) order by p.created_at, p.id), '[]'::jsonb)
    into v_pay from booking.payments p left join booking.payment_methods pm on pm.code = p.method
   where p.order_id = o.id and p.status <> 'cancelled'
     and not (p.provider = 'manual' and p.status = 'pending' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id));
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'kind', x.kind, 'issued_at', x.issued_at, 'token', x.public_token, 'total', x.total_gross) order by x.issued_at, x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  select jsonb_build_object('status', q.status, 'created_at', q.created_at) into v_creq from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' order by q.created_at desc, q.id desc limit 1;

  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not booking._order_invoice_locked(o.id);
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  -- booking_149: asiakas voi pyytää peruutusta (ja sen hyvitystä) vain, kun ensimmäisen voimassa olevan vuoron alkuun on vähintään customer_change_hours_before tuntia (oletus 48).
  v_cancel_dl := booking._customer_cancel_deadline(o.id);
  v_cancel_closed := v_open and (v_cancel_dl is null or v_cancel_dl < now());
  v_open := v_open and v_cancel_dl is not null and v_cancel_dl >= now();
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;

  if v_can_add then
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en, 'price', a.price_gross, 'vat_rate', a.vat_rate,
             'max', x.lim, 'reservation_ids', x.rids) order by a.sort_order, a.id), '[]'::jsonb) into v_ups_a
      from booking.addons a
      join lateral (select max(booking._addon_limit(a.max_per_person, r.persons)) lim, jsonb_agg(r.id order by r.id) rids
                      from booking.reservations r left join booking.product_config pc on pc.product_id = r.product_id left join kb.products p on p.id = r.product_id
                     where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now()
                       and coalesce(case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end, r.mode) = any (a.applies_modes)) x on x.rids is not null
     where a.active;
    select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'duration_minutes', coalesce(pc.duration_minutes, p.duration_minutes),
             'description', p.description, 'description_en', p.description_en, 'category', p.category) order by pc.sort_order, p.id), '[]'::jsonb) into v_ups_t
      from booking.product_config pc join kb.products p on p.id = pc.product_id
     where pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current' and p.active and p.price is not null;
  end if;

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status', v_status, 'payment_status', o.payment_status, 'currency', o.currency, 'locale', coalesce(o.locale, 'fi'),
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind, 'invoice_method', case when o.customer_kind <> 'private' then o.billing ->> 'invoice_method' end,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
    'invoice_locked', booking._order_invoice_locked(o.id),
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq,
    'cancel_deadline', v_cancel_dl, 'cancel_hours_before', v_hours, 'cancel_closed', coalesce(v_cancel_closed, false), 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)),
    'instructions', booking._order_full_instructions(o.id, coalesce(o.locale, 'fi')))
    || booking._checkout_state_json(o.id)
    || jsonb_build_object('pending_additions', booking._pending_additions_json(o.id));
end $function$;


-- 2) uudet objektit pois
drop trigger if exists product_config_training_defaults on booking.product_config;
drop function if exists booking.product_config_training_defaults();
drop function if exists booking.public_create_training_signup(bigint, date, text, text, text, text, text, text, text, boolean, boolean, text[]);
drop function if exists booking.public_training_checkout(bigint, date);
drop function if exists booking.public_product_by_slug(text);
drop function if exists booking.admin_training_addons_set(bigint, jsonb);
drop function if exists booking.admin_training_addons_get(bigint);
drop function if exists booking._training_money(jsonb, text);
drop function if exists booking._training_single_rooms_remaining(bigint);
drop function if exists booking._training_single_rooms_used(bigint);
drop function if exists booking._training_single_room_pools(bigint);
drop function if exists booking._training_rule_range(bigint);
drop function if exists booking._catalog_product_json(bigint);
drop table if exists booking.training_participants;
drop table if exists booking.training_addon_offers;

alter table booking.schedule_rules drop constraint if exists schedule_rules_single_room_max_check;
alter table booking.schedule_rules drop column if exists single_room_max;
alter table booking.product_config drop constraint if exists product_config_course_price_check;
alter table booking.product_config drop constraint if exists product_config_deposit_amount_check;
alter table booking.product_config drop column if exists course_price;
alter table booking.product_config drop column if exists deposit_amount;

update booking.product_config
   set channels = array_remove(channels, 'link')
 where channels is not null and channels @> array['link']::text[];
update booking.product_config set channels = null where channels = '{}'::text[];
alter table booking.product_config drop constraint if exists product_config_channels_check;
alter table booking.product_config add constraint product_config_channels_check
  check (channels is null or channels <@ array['shop', 'widget']::text[]);

-- 3) md5-tarkistus
do $$
declare x record; v text;
begin
  for x in select * from (values

    ('_event_rule_json', 'f75c969f5620e57d69dee85cee62aacf'),
    ('admin_event_participants', 'dc6ec356d490eb60a8780a7cb5c9d86b'),
    ('admin_event_rule_upsert', 'e5387d87c6be2400c6be7f37c82e0c26'),
    ('admin_event_set_channels', 'e340b362893a19c65f4404f0c09ed1dc'),
    ('admin_update_product_config', 'd1dc15f168234dfe8274ffd2d660c299'),
    ('customers_drop_event_notes', '0e9642dce2393cc9d203e47fad4745a6'),
    ('email_outbox_claim', '530bf169dfab8b59e4a456dbf94c7d6e'),
    ('public_availability', '98eb72261254d7f47cae7ded66ac922c'),
    ('public_catalog', '2294bbb6675677aea1dc813b151fe8e4'),
    ('public_create_booking', '6bf51ffd45c259ef5546aa19f63f5066'),
    ('public_get_booking', '3a8e4b3eee34b07e58acb06b679ff709'),
    ('public_get_order', 'd95b749725c672d45025f34be71fdbb6')

  ) as t(f, m) loop
    select md5(pg_get_functiondef(p.oid)) into v
      from pg_proc p
     where p.pronamespace = 'booking'::regnamespace and p.proname = x.f
     order by p.oid limit 1;
    if v is distinct from x.m then
      raise exception 'booking_226 rollback: booking.% md5 % <> odotettu %', x.f, v, x.m;
    end if;
  end loop;
end $$;
