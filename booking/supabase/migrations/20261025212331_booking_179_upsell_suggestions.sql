-- booking_179: ehdotetut tuotteet (upsell). Uusia tauluja ja RPC:itä. Ei korvaa public_create_booking-,
-- public_create_booking_code-, _create_legs_booking-, public_add_to_order-, _add_to_order-, public_treatment_availability-,
-- _treatment_slot_check-, _public_pay_json-, _create_link_payment-, payments_paid_trg- tai public_get_site_texts-funktiota.
-- Hintoja, ALV:tä, osoitteita ja maksuasetuksia ei muuteta. Julkiset vastaukset eivät sisällä tokenia.
-- Kaksivaiheinen kassa: perusvaraus syntyy entisellä RPC:llä, public_upsell_checkout_attach liittää lisähoidon jälkeen.
-- Jos liitos epäonnistuu, vain liitoksen alitransaktio perutaan. Rajoituslaskuri jää, ja perusvaraus on edellisessä transaktiossa.
-- Liitos onnistuu vain maksamattomaan tilaukseen (payment_status unpaid, ei maksettua tai kesken olevaa verkkomaksua).
-- Saatavuus haetaan _treatment_availability_core-funktiosta, ei julkisesta rajoitetusta RPC:stä.
set local lock_timeout = '5s';

insert into booking.settings(key, value, description, is_public)
values ('upsell_cutoff_minutes', '120'::jsonb, 'Upsell additions must be at least this many minutes before first booking start', false)
on conflict (key) do nothing;

create table booking.product_suggestions (
  product_id bigint not null references kb.products(id) on delete cascade,
  suggested_product_id bigint references kb.products(id) on delete cascade,
  suggested_addon_id bigint references booking.addons(id) on delete cascade,
  position smallint not null check (position between 1 and 3),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  constraint suggestion_one_target check ((suggested_product_id is null) <> (suggested_addon_id is null)),
  constraint suggestion_no_self check (suggested_product_id is distinct from product_id),
  constraint suggestion_one_position unique (product_id, position)
);
create unique index suggestion_product_unique on booking.product_suggestions(product_id, suggested_product_id) where suggested_product_id is not null;
create unique index suggestion_addon_unique on booking.product_suggestions(product_id, suggested_addon_id) where suggested_addon_id is not null;
create index suggestion_enabled_idx on booking.product_suggestions(product_id, position) where enabled;
comment on table booking.product_suggestions is 'booking_179: enintään 3 ehdotusta / päätuote (position 1–3). Ei suoraa kirjoitusta; admin_set_product_suggestions.';

create table booking.upsell_events (
  id bigint generated always as identity primary key,
  order_id bigint references booking.orders(id) on delete set null,
  session_id uuid not null,
  source text not null check (source in ('checkout', 'confirmation', 'email')),
  product_id bigint not null references kb.products(id),
  suggested_from_product_id bigint references kb.products(id),
  suggested_addon_id bigint references booking.addons(id),
  event text not null check (event in ('shown', 'opened', 'added', 'paid')),
  order_item_id bigint references booking.order_items(id) on delete set null,
  payment_id bigint references booking.payments(id) on delete set null,
  amount_gross numeric(12,2) not null default 0 check (amount_gross >= 0),
  created_at timestamptz not null default now()
);
create unique index upsell_event_payment_once on booking.upsell_events(order_item_id, payment_id) where event = 'paid' and order_item_id is not null and payment_id is not null;
create unique index upsell_event_added_once on booking.upsell_events(order_item_id) where event = 'added' and order_item_id is not null;
create index upsell_events_created_idx on booking.upsell_events(created_at, source, event);
create index upsell_events_order_idx on booking.upsell_events(order_id, order_item_id);
comment on table booking.upsell_events is 'booking_179: shown/opened vain public_upsell_event; added vain palvelimen lisäys; paid vain zz_upsell_paid_* maksun kohdistuksen jälkeen.';

alter table booking.product_suggestions enable row level security;
alter table booking.upsell_events enable row level security;
-- Ei suoraa lukua eikä kirjoitusta. SECURITY DEFINER -funktiot ohittavat RLS omistajana; service_role ohittaa RLS (bypassrls).
create policy product_suggestions_no_direct on booking.product_suggestions as restrictive for all to anon, authenticated using (false) with check (false);
create policy upsell_events_no_direct on booking.upsell_events as restrictive for all to anon, authenticated using (false) with check (false);
revoke all on table booking.product_suggestions from public, anon, authenticated;
revoke all on table booking.upsell_events from public, anon, authenticated;
grant all on table booking.product_suggestions to service_role;
grant all on table booking.upsell_events to service_role;

create function booking._upsell_cutoff() returns integer
language sql stable security definer set search_path = '' as $$
  select greatest(0, least(10080, coalesce((booking._setting('upsell_cutoff_minutes', '120'::jsonb) #>> '{}')::integer, 120)))
$$;
revoke all on function booking._upsell_cutoff() from public, anon, authenticated;
comment on function booking._upsell_cutoff() is 'booking_179: lisäyksen takaraja minuutteina ennen aikaisinta varausta.';

create function booking.admin_set_product_suggestions(p_product_id bigint, p_items jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare e jsonb; v_pos int := 0; v_isprod boolean; v_isaddon boolean;
begin
  perform booking._require_permission('catalog.edit');
  if not exists (select 1 from booking.staff st where st.user_id = auth.uid() and st.role = 'admin') then
    perform booking._err('forbidden', 'Administrator permission required');
  end if;
  if not exists (select 1 from kb.products where id = p_product_id) then perform booking._err('not_found', 'Product not found'); end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 3 then perform booking._err('invalid_items', 'Maximum three suggestions'); end if;
  perform pg_advisory_xact_lock(hashtextextended('booking.upsell:' || p_product_id::text, 0));
  delete from booking.product_suggestions where product_id = p_product_id;
  for e in select value from jsonb_array_elements(p_items) loop
    v_pos := v_pos + 1;
    v_isprod := nullif(e->>'product_id', '') is not null;
    v_isaddon := nullif(e->>'addon_id', '') is not null;
    if v_isprod = v_isaddon then perform booking._err('invalid_items', 'One target per row'); end if;
    if v_isprod then
      insert into booking.product_suggestions(product_id, suggested_product_id, position, enabled)
      values (p_product_id, (e->>'product_id')::bigint, v_pos, coalesce((e->>'enabled')::boolean, true));
    else
      insert into booking.product_suggestions(product_id, suggested_addon_id, position, enabled)
      values (p_product_id, (e->>'addon_id')::bigint, v_pos, coalesce((e->>'enabled')::boolean, true));
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_pos);
end $f$;
revoke all on function booking.admin_set_product_suggestions(bigint, jsonb) from public, anon, authenticated;
grant execute on function booking.admin_set_product_suggestions(bigint, jsonb) to authenticated, service_role;

create function booking.admin_get_product_suggestions(p_product_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  perform booking._require_permission('catalog.edit');
  return coalesce((select jsonb_agg(jsonb_build_object('product_id', s.suggested_product_id, 'addon_id', s.suggested_addon_id, 'position', s.position, 'enabled', s.enabled) order by s.position)
    from booking.product_suggestions s where s.product_id = p_product_id), '[]'::jsonb);
end $f$;
revoke all on function booking.admin_get_product_suggestions(bigint) from public, anon, authenticated;
grant execute on function booking.admin_get_product_suggestions(bigint) to authenticated, service_role;

-- Päivän vapaat ajat ilman julkista avail-rajoitusta. lock_timeout ja public_booking_enabled kuten public_treatment_availability.
create function booking._upsell_day_slots(p_product bigint, p_day date, p_persons integer)
returns table(starts_at timestamptz, ends_at timestamptz, total numeric)
language plpgsql volatile security definer set search_path = '' set lock_timeout to '400ms' as $f$
declare v_persons integer := greatest(1, least(coalesce(p_persons, 1), 50));
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then return; end if;
  return query
    select c.starts_at, c.ends_at, c.total
      from booking._treatment_availability_core(p_product, p_day, p_day, v_persons, false, false) c
     where c.status = 'available';
exception when lock_not_available then
  perform booking._err('busy', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
end $f$;
revoke all on function booking._upsell_day_slots(bigint, date, integer) from public, anon, authenticated;

-- Saatavuus tuote kerrallaan. Lukko tai kiire (BK001) ohittaa yhden tuotteen, lista ei kaadu.
-- option_required-tuotteet jäävät pois (paneelissa ei ole pakollista valitsinta).
create function booking._upsell_options(p_origins bigint[], p_existing bigint[], p_date date, p_persons integer, p_limit integer default 9)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare v_products jsonb := '[]'::jsonb; v_addons jsonb := '[]'::jsonb; v_slots jsonb; r record;
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
           p.description, p.description_en, pc.image_path, x.origin, x.tier, x.position
      from uniq x join kb.products p on p.id = x.id join booking.product_config pc on pc.product_id = p.id
     where p.active and p.price is not null and not coalesce(pc.option_required, false) and pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
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
      v_products := v_products || jsonb_build_array(jsonb_build_object('product_id', r.id, 'origin', r.origin, 'suggested', r.tier = 0,
        'name', r.name, 'name_en', r.name_en, 'slug', r.slug, 'price_from', r.price, 'short_description', r.short_description,
        'short_description_en', r.short_description_en, 'description', r.description, 'description_en', r.description_en, 'image_path', r.image_path,
        'slots', v_slots));
    end if;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('addon_id', a.id, 'origin', s.product_id, 'name', a.name, 'name_en', a.name_en, 'price', a.price_gross, 'applies_modes', a.applies_modes)
      order by s.position, s.product_id, a.id), '[]'::jsonb) into v_addons
    from booking.product_suggestions s join booking.addons a on a.id = s.suggested_addon_id and a.active
   where s.enabled and s.product_id = any (coalesce(p_origins, '{}'::bigint[]));
  return jsonb_build_object('products', v_products, 'addons', v_addons);
end $f$;
revoke all on function booking._upsell_options(bigint[], bigint[], date, integer, integer) from public, anon, authenticated;

create function booking.public_upsell_suggestions(p_product_ids bigint[], p_date date, p_persons integer default 1, p_visit_start timestamptz default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
begin
  if cardinality(p_product_ids) not between 1 and 6 or p_date is null or p_persons not between 1 and 50 or p_visit_start is null
     or p_visit_start <= now() + make_interval(mins => booking._upsell_cutoff())
     or (p_visit_start at time zone booking._tz())::date <> p_date then
    return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb);
  end if;
  if booking._client_ip() is not null and not booking._rate_limit('upsell-list:' || booking._client_ip(), 60, interval '10 minutes') then
    return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb);
  end if;
  return booking._upsell_options(p_product_ids, p_product_ids, p_date, p_persons, 9);
end $f$;
revoke all on function booking.public_upsell_suggestions(bigint[], date, integer, timestamptz) from public, anon, authenticated;
grant execute on function booking.public_upsell_suggestions(bigint[], date, integer, timestamptz) to anon, authenticated, service_role;

create function booking.public_upsell_for_order(p_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare o booking.orders; v_start timestamptz; v_origins bigint[]; v_date date; v_options jsonb; v_addons jsonb;
begin
  if p_token is null or not booking._order_rl('upsell', p_token, 30, 12) then return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found or o.external_source is not null or o.status <> 'confirmed' then return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb); end if;
  select min(starts_at), array_agg(distinct product_id) into v_start, v_origins from booking.reservations
   where order_id = o.id and booking._res_active(status, hold_expires_at);
  if v_start is null or v_start <= now() + make_interval(mins => booking._upsell_cutoff()) then return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb); end if;
  v_date := (v_start at time zone booking._tz())::date;
  v_options := booking._upsell_options(v_origins, v_origins, v_date, 1, 9);
  select coalesce(jsonb_agg(a.value), '[]'::jsonb) into v_addons from jsonb_array_elements(v_options->'addons') a
   where not exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.addon_id = (a.value->>'addon_id')::bigint)
     and exists (select 1 from booking.reservations r where r.order_id = o.id and r.product_id = (a.value->>'origin')::bigint and booking._res_active(r.status, r.hold_expires_at));
  return jsonb_set(v_options, '{addons}', v_addons);
end $f$;
revoke all on function booking.public_upsell_for_order(uuid) from public, anon, authenticated;
grant execute on function booking.public_upsell_for_order(uuid) to anon, authenticated, service_role;

-- Vain shown/opened. added ja paid hylätään (ne syntyvät palvelimella).
create function booking.public_upsell_event(p_session_id uuid, p_source text, p_product_id bigint, p_event text, p_origin bigint default null, p_addon_id bigint default null)
returns boolean language plpgsql volatile security definer set search_path = '' as $f$
declare v_ip text := booking._client_ip();
begin
  if p_session_id is null or p_source not in ('checkout', 'confirmation', 'email') or p_event not in ('shown', 'opened')
    or p_product_id is null or not exists (select 1 from kb.products where id = p_product_id and active) then return false; end if;
  if not booking._rate_limit('upsell-evt:' || coalesce(v_ip, p_session_id::text), 80, interval '10 minutes') then return false; end if;
  if p_addon_id is not null and not exists (select 1 from booking.product_suggestions where enabled and product_id = p_origin and suggested_addon_id = p_addon_id) then return false; end if;
  insert into booking.upsell_events(session_id, source, product_id, suggested_from_product_id, suggested_addon_id, event)
    values (p_session_id, p_source, p_product_id, p_origin, p_addon_id, p_event);
  return true;
end $f$;
revoke all on function booking.public_upsell_event(uuid, text, bigint, text, bigint, bigint) from public, anon, authenticated;
grant execute on function booking.public_upsell_event(uuid, text, bigint, text, bigint, bigint) to anon, authenticated, service_role;

create function booking._upsell_attach_reservation(p_order_id bigint, p_product_id bigint, p_start timestamptz, p_persons integer, p_main_day date)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare o booking.orders; v_end timestamptz; v_result jsonb;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found or o.external_source is not null or o.status not in ('pending', 'confirmed') then perform booking._err('order_not_editable', 'Order cannot be amended'); end if;
  if p_start is null or p_persons not between 1 and 50 or (p_start at time zone booking._tz())::date <> p_main_day then perform booking._err('invalid_date', 'Choose your visit date'); end if;
  if exists (select 1 from booking.reservations where order_id = o.id and product_id = p_product_id and booking._res_active(status, hold_expires_at)) then perform booking._err('duplicate_product', 'Already in order'); end if;
  if not exists (select 1 from booking._upsell_day_slots(p_product_id, p_main_day, p_persons) q where q.starts_at = p_start) then
    perform booking._err('slot_unavailable', 'Selected time is no longer available');
  end if;
  v_end := booking._treatment_slot_check(p_product_id, p_start, p_persons, true);
  -- Nykyinen 17-argumenttinen _create_legs_booking. p_price null → tuotteen oma hintakaava. Pito periytyy odottavasta tilauksesta.
  v_result := booking._create_legs_booking('current', p_product_id, p_start, v_end, p_persons, o.customer_id, 'web', null, null, null, null, false, null, false, null, o.id, null);
  return v_result;
end $f$;
revoke all on function booking._upsell_attach_reservation(bigint, bigint, timestamptz, integer, date) from public, anon, authenticated;

-- Ei korvaa public_create_booking / public_create_booking_code. Ei palauta tokenia.
-- Tyhjä p_upsell kirjaa vain jo kassalla valitut suositellut lisäpalvelut (alennuskoodi sallittu).
-- Ei-tyhjä lista hylätään, jos tilauksella on alennuskoodi tai vuosikorttimaksu (ei hiljaista täyden hinnan lisäystä alennettuun tilaukseen).
-- Maksu kesken tai jo maksettu: order_closed. Koskematon pay_later-paikkamerkki (pending, manual, ei payment_lines) ei estä.
-- _order_rl on poikkeuslohkon ulkopuolella, jotta epäonnistunut liitos kuluttaa rajoituksen.
create function booking.public_upsell_checkout_attach(p_token uuid, p_upsell jsonb, p_session_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare o booking.orders; v_main bigint; v_main_start timestamptz; v_date date; e jsonb;
  v_pid bigint; v_pers int; v_start timestamptz; v_result jsonb; v_n int := 0; v_res_id bigint;
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
      v_start := (e->>'start')::timestamptz;
      v_result := booking._upsell_attach_reservation(o.id, v_pid, v_start, v_pers, v_date);
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
  exception when sqlstate 'BK001' or exclusion_violation or invalid_text_representation or datetime_field_overflow then
    return jsonb_build_object('ok', false, 'code', 'slot_unavailable');
  end;
end $f$;
revoke all on function booking.public_upsell_checkout_attach(uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function booking.public_upsell_checkout_attach(uuid, jsonb, uuid) to anon, authenticated, service_role;

-- Vahvistetun tilauksen lisäys kulkee olemassa olevan public_add_to_orderin kautta (hinta, kapasiteetti, maksulinkki vain jos Visma on live).
-- Jos reservation_id puuttuu, se päätellään lähtötuotteen ainoasta aktiivisesta varauksesta (public_get_booking ei palauta reservation_id:tä).
-- Rajoituslaskuri on alitransaktion ulkopuolella. Aikojen tarkistus käyttää _upsell_day_slots-funktiota.
create function booking.public_upsell_add(p_token uuid, p_item jsonb, p_session_id uuid, p_origin bigint default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare o booking.orders; v_first timestamptz; v_product bigint; v_addon bigint; v_result jsonb; v_before bigint; v_new bigint; v_date date;
        v_n int; v_res bigint; v_item jsonb;
begin
  if p_token is null or p_session_id is null or not booking._order_rl('upselladd', p_token, 15, 6) then return jsonb_build_object('ok', false, 'code', 'rate_limited'); end if;
  select * into o from booking.orders where public_token = p_token for update;
  if not found or o.status <> 'confirmed' or o.external_source is not null then return jsonb_build_object('ok', false, 'code', 'order_closed'); end if;
  select min(starts_at) into v_first from booking.reservations where order_id = o.id and booking._res_active(status, hold_expires_at);
  if v_first is null or v_first <= now() + make_interval(mins => booking._upsell_cutoff()) then return jsonb_build_object('ok', false, 'code', 'order_closed'); end if;
  if jsonb_typeof(p_item) <> 'object' or p_item->>'type' not in ('reservation', 'addon') then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
  v_date := (v_first at time zone booking._tz())::date;
  v_item := p_item;
  if p_item->>'type' = 'reservation' then
    if coalesce(p_item->>'product_id', '') !~ '^\d{1,18}$' or p_item->>'start' is null or coalesce(p_item->>'persons', '') !~ '^\d{1,3}$' then
      return jsonb_build_object('ok', false, 'code', 'invalid_items');
    end if;
    v_product := (p_item->>'product_id')::bigint;
    if exists (select 1 from booking.reservations where order_id = o.id and product_id = v_product and booking._res_active(status, hold_expires_at)) then
      return jsonb_build_object('ok', false, 'code', 'duplicate_product');
    end if;
  else
    if coalesce(p_item->>'addon_id', '') !~ '^\d{1,18}$' then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
    v_addon := (p_item->>'addon_id')::bigint;
    if coalesce(p_item->>'reservation_id', '') ~ '^\d{1,18}$' then
      select product_id into v_product from booking.reservations
       where order_id = o.id and id = (p_item->>'reservation_id')::bigint and booking._res_active(status, hold_expires_at);
      if v_product is null then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
    else
      if p_origin is null then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
      select count(*), min(r.id), min(r.product_id) into v_n, v_res, v_product
        from booking.reservations r
       where r.order_id = o.id and r.product_id = p_origin and booking._res_active(r.status, r.hold_expires_at);
      if v_n <> 1 then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
      v_item := v_item || jsonb_build_object('reservation_id', v_res);
    end if;
    if exists (select 1 from booking.order_items where order_id = o.id and addon_id = v_addon) then return jsonb_build_object('ok', false, 'code', 'duplicate_product'); end if;
    if coalesce(v_item->>'quantity', '') !~ '^\d{1,4}$' then v_item := v_item || jsonb_build_object('quantity', 1); end if;
  end if;
  begin
    if p_item->>'type' = 'reservation' then
      if ((p_item->>'start')::timestamptz at time zone booking._tz())::date <> v_date then return jsonb_build_object('ok', false, 'code', 'invalid_date'); end if;
      if not exists (select 1 from booking._upsell_day_slots(v_product, v_date, (p_item->>'persons')::int) q
                     where q.starts_at = (p_item->>'start')::timestamptz) then
        return jsonb_build_object('ok', false, 'code', 'slot_unavailable');
      end if;
    end if;
    select coalesce(max(id), 0) into v_before from booking.order_items where order_id = o.id;
    v_result := booking.public_add_to_order(p_token, jsonb_build_array(v_item));
    if v_result->>'ok' <> 'true' then return jsonb_build_object('ok', false, 'code', coalesce(v_result->>'code', 'invalid_items')); end if;
    select id into v_new from booking.order_items where order_id = o.id and id > v_before order by id desc limit 1;
    if v_new is not null then
      insert into booking.upsell_events(order_id, session_id, source, product_id, suggested_from_product_id, suggested_addon_id, event, order_item_id)
      values (o.id, p_session_id, 'confirmation', v_product, p_origin, v_addon, 'added', v_new) on conflict do nothing;
    end if;
    return jsonb_build_object('ok', true, 'added_total', v_result->'added_total');
  exception when sqlstate 'BK001' or exclusion_violation or invalid_text_representation or datetime_field_overflow then
    return jsonb_build_object('ok', false, 'code', 'slot_unavailable');
  end;
end $f$;
revoke all on function booking.public_upsell_add(uuid, jsonb, uuid, bigint) from public, anon, authenticated;
grant execute on function booking.public_upsell_add(uuid, jsonb, uuid, bigint) to anon, authenticated, service_role;

-- payments_paid_trg kohdistaa payment_lines ennen aakkosissa myöhempää zz_-triggeriä. Tätä triggerifunktiota ei korvata.
create function booking._upsell_paid_trg() returns trigger
language plpgsql volatile security definer set search_path = '' as $f$
begin
  insert into booking.upsell_events(order_id, session_id, source, product_id, suggested_from_product_id, suggested_addon_id, event, order_item_id, payment_id, amount_gross)
  select e.order_id, e.session_id, e.source, e.product_id, e.suggested_from_product_id, e.suggested_addon_id, 'paid', e.order_item_id, new.id,
         least(coalesce(pl.amount_gross, 0), coalesce(oi.line_total_gross, 0))
  from booking.upsell_events e join booking.order_items oi on oi.id = e.order_item_id
  join booking.payment_lines pl on pl.order_item_id = oi.id and pl.payment_id = new.id
  where e.order_id = new.order_id and e.event = 'added' and pl.amount_gross > 0
  on conflict do nothing;
  return null;
end $f$;
revoke all on function booking._upsell_paid_trg() from public, anon, authenticated;
create trigger zz_upsell_paid_insert after insert on booking.payments for each row when (new.status = 'paid') execute function booking._upsell_paid_trg();
create trigger zz_upsell_paid_update after update of status on booking.payments for each row when (new.status = 'paid' and old.status is distinct from 'paid') execute function booking._upsell_paid_trg();

create function booking.admin_upsell_report(p_from date default current_date - 30, p_to date default current_date)
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  perform booking._require_permission('catalog.edit');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then perform booking._err('invalid_date', 'Invalid range'); end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.paid_eur desc, x.shown desc)
    from (select e.product_id, p.name as product_name, e.suggested_from_product_id as origin_id, e.suggested_addon_id as addon_id,
             count(*) filter (where e.event = 'shown') as shown, count(*) filter (where e.event = 'opened') as opened,
             count(*) filter (where e.event = 'added') as added, count(*) filter (where e.event = 'paid') as paid,
             round(coalesce(sum(e.amount_gross) filter (where e.event = 'paid'), 0), 2) as paid_eur
            from booking.upsell_events e join kb.products p on p.id = e.product_id
           where (e.created_at at time zone booking._tz())::date between p_from and p_to
           group by e.product_id, p.name, e.suggested_from_product_id, e.suggested_addon_id
          ) x), '[]'::jsonb);
end $f$;
revoke all on function booking.admin_upsell_report(date, date) from public, anon, authenticated;
grant execute on function booking.admin_upsell_report(date, date) to authenticated, service_role;
