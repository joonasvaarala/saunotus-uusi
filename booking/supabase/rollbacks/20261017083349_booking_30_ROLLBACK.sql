-- booking_30 rollback: palauttaa A-vaiheen funktiot entiseen (taulut: booking_29_ROLLBACK). Aja tämä ENNEN booking_29_ROLLBACK:ia.

select cron.unschedule('booking_expire_payment_links');

drop trigger if exists payments_paid_ins on booking.payments;
drop trigger if exists payments_paid_upd on booking.payments;

drop function if exists booking._cash_rounding(numeric), booking._order_uncovered(bigint, boolean), booking._order_balance(bigint), booking._sync_placeholder(bigint),
 booking._enqueue_email(text, bigint, bigint, bigint, text, jsonb), booking._alloc_payment_lines(bigint), booking._on_payment_paid(bigint), booking._on_refund_done(bigint),
 booking.payments_paid_trg(), booking._create_link_payment(bigint, integer, text), booking._link_json(bigint), booking.expire_payment_links(), booking._add_to_order(bigint, jsonb, boolean),
 booking.admin_list_orders(text, text, text, text, boolean, text, date, date, text, integer, integer), booking.admin_list_payments(text, text, text, date, date, text, boolean, integer, integer),
 booking.admin_add_to_order(bigint, jsonb, boolean, boolean, text), booking.admin_create_payment_link(bigint, boolean, integer, text), booking.admin_record_payment(bigint, text, numeric, text, jsonb),
 booking.admin_refund(bigint, numeric, text, jsonb, boolean), booking.admin_list_vat_rates(), booking.admin_set_product_vat(bigint, numeric, text), booking.admin_set_addon_vat(bigint, numeric),
 booking.admin_upsert_vat_rate(numeric, text, boolean), booking._create_legs_booking(text, bigint, timestamptz, timestamptz, integer, bigint, text, uuid, text, numeric, bigint, boolean, text, boolean, bigint, bigint),
 booking._create_booking_core(bigint, date, integer, bigint, text, uuid, text, text, text, integer, boolean, timestamptz, timestamptz, numeric, bigint, bigint);

CREATE OR REPLACE FUNCTION booking._create_legs_booking(p_lifecycle text, p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_note text, p_price numeric, p_space_id bigint, p_override boolean, p_override_reason text, p_quota_exempt boolean, p_parent_reservation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p kb.products; pc booking.product_config; v_end timestamptz; v_total numeric; v_order booking.orders; v_item bigint; v_res booking.reservations;
  v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_prim booking.leg_plan; v_parent bigint; v_pools bigint[]; v_off integer; v_cmin integer; v_n integer := 0; v_missing boolean := false; v_ecode text;
begin
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('product_not_found', 'Tuotetta ei löydy'); end if;
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  if p_lifecycle is not null and pc.lifecycle <> p_lifecycle then
    perform booking._err('wrong_lifecycle', case p_lifecycle when 'old' then 'Valitse vanha tuote (current-tuotteet: Uusi varaus)' else 'Valitse nykyinen tuote' end);
  end if;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
  v_end := coalesce(p_end, p_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes)));
  if p_start is null or v_end is null or v_end <= p_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  if p_override and (p_override_reason is null or length(btrim(p_override_reason)) < 3) then perform booking._err('override_reason_required', 'Ylitys vaatii perustelun'); end if;

  -- lisäpalvelu (kb 27/28): vaatii kattavan vanhempivarauksen (jälkilöyly / oma vuoro)
  if cardinality(pc.requires_parent_product_ids) > 0 then
    select r.id into v_parent
      from booking.reservations r join booking.orders o on o.id = r.order_id
     where r.product_id = any (pc.requires_parent_product_ids) and booking._res_active(r.status, r.hold_expires_at)
       and r.starts_at <= p_start and r.ends_at >= v_end
       and (p_parent_reservation_id is null or r.id = p_parent_reservation_id)
     order by (o.customer_id is not distinct from p_customer_id) desc, r.starts_at limit 1;
    if v_parent is null and not p_override then
      perform booking._err('parent_required', 'Lisäpalvelu vaatii jälkilöyly-/yksityisvuorovarauksen samalle ajalle');
    end if;
  end if;

  begin
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override) loop v_plan := array_append(v_plan, lp); end loop;
  exception when sqlstate 'BK001' then
    -- booking_22: ei vapaata saunottajaa -> varaus syntyy ilman saunottajalegiä (therapist_missing), kaikki muut virheet nousevat ennallaan
    get stacked diagnostics v_ecode = pg_exception_detail;
    if v_ecode is distinct from 'no_therapist' then raise; end if;
    v_plan := '{}'; v_missing := true;
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override, null, true) loop v_plan := array_append(v_plan, lp); end loop;
  end;
  select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
  if v_prim.resource_id is null then perform booking._err('no_primary_leg', 'Tuotteelta puuttuu ensisijainen tila (product_space_rules leg 1)'); end if;
  v_off := (extract(epoch from (v_prim.claim_start - p_start)) / 60)::int;
  v_cmin := case when v_prim.claim_end >= v_end then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
  if v_prim.mode = 'exclusive' and (v_off <> 0 or v_cmin is not null) then perform booking._err('bad_rule', 'Yksinoikeusvarauksen claim-ikkuna on aina koko varaus'); end if;
  v_pools := case when v_prim.pool_id is null then '{}'::bigint[] else array[v_prim.pool_id] end;

  v_total := coalesce(p_price, coalesce(p.price, 0) + coalesce(p.extra_person_price, 0) * greatest(p_persons - coalesce(p.included_persons, p_persons), 0));
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by, confirmed_at)
  values (p_customer_id, 'confirmed', 'unpaid', v_total, p_channel, 'fi', p_note, p_created_by, now()) returning * into v_order;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          jsonb_build_object('model', 'legs_v2', 'lifecycle', pc.lifecycle, 'persons', p_persons)) returning id into v_item;

  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status,
                                   quota_exempt, claim_offset_min, claim_minutes, parent_reservation_id, override_reason, created_by, therapist_missing)
  values (v_order.id, v_item, p.id, v_prim.resource_id, v_prim.mode, p_start, v_end, p_persons, v_pools, 'confirmed',
          p_quota_exempt, v_off, v_cmin, v_parent, case when p_override then btrim(p_override_reason) end, p_created_by, v_missing)
  returning * into v_res;                                    -- trigger validoi ensisijaisen claimin

  for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
    insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key,
                                         quota_exempt, override_reason, rule_id)
    values (v_res.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
            case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key,
            p_quota_exempt, case when p_override then btrim(p_override_reason) end, lp.rule_id);   -- trigger validoi legin
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'reservation_id', v_res.id, 'total', v_total,
                            'starts_at', v_res.starts_at, 'ends_at', v_res.ends_at, 'legs', v_n, 'space_id', v_res.space_id,
                            'product_name', p.name, 'parent_reservation_id', v_parent,
                            'therapist_missing', v_missing, 'warning', case when v_missing then 'therapist_missing' end);
end $function$;

CREATE OR REPLACE FUNCTION booking._create_booking_core(p_rule_id bigint, p_date date, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_locale text, p_note text, p_status text, p_hold_minutes integer, p_enforce_deadline boolean, p_override_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_override_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_price_override numeric DEFAULT NULL::numeric, p_annual_card_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  rs record; p kb.products;
  pr record; v_total numeric; v_order booking.orders; v_item_id bigint; v_res_id bigint;
  v_hold timestamptz;
begin
  select * into rs from booking._resolve_session(p_rule_id, p_date, p_persons, p_enforce_deadline, p_override_start, p_override_end);
  select * into p from kb.products where id = rs.o_product_id;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;

  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_total := case when p_annual_card_id is not null then 0 else coalesce(p_price_override, pr.total) end;

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by)
  values (p_customer_id, case when p_status = 'confirmed' then 'confirmed' else 'pending' end, 'unpaid', v_total,
          p_channel, coalesce(p_locale, 'fi'), p_note, p_created_by)
  returning * into v_order;
  if p_status = 'confirmed' then update booking.orders set confirmed_at = now() where id = v_order.id; end if;

  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          pr.breakdown || jsonb_build_object('rule_id', p_rule_id, 'rule_label', (select label from booking.schedule_rules where id = p_rule_id))
                       || case when p_annual_card_id is not null then jsonb_build_object('annual_card_id', p_annual_card_id) else '{}'::jsonb end)
  returning id into v_item_id;

  v_hold := case when p_status = 'pending' then now() + make_interval(mins => greatest(coalesce(p_hold_minutes, 15), 1)) end;
  -- Trigger reservations_validate lukitsee tilan ja tarkistaa päällekkäisyydet/kapasiteetin/vuosikortin; virhe kumoaa koko lisäyksen.
  insert into booking.reservations(order_id, order_item_id, product_id, rule_id, annual_card_id, space_id, mode, starts_at, ends_at, persons,
                                   pool_ids, status, hold_expires_at, created_by)
  values (v_order.id, v_item_id, p.id, p_rule_id, p_annual_card_id, rs.o_space_id, rs.o_mode, rs.o_starts_at, rs.o_ends_at, p_persons,
          rs.o_pool_ids, p_status, v_hold, p_created_by)
  returning id into v_res_id;

  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'public_token', v_order.public_token,
                            'reservation_id', v_res_id, 'total', v_total, 'starts_at', rs.o_starts_at, 'ends_at', rs.o_ends_at,
                            'status', p_status, 'hold_expires_at', v_hold, 'product_name', p.name);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_update_product(p_product_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['name','name_en','description','description_en','price','price_text','vat_rate','active'];
  k text; o kb.products; n kb.products; v_price numeric; v_vat numeric;
begin
  perform booking._require_permission('catalog.edit');
  select * into o from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and char_length(btrim(coalesce(p_patch ->> 'name', ''))) = 0 then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'price' then
    v_price := (p_patch ->> 'price')::numeric;
    if v_price is null or v_price < 0 or v_price > 100000 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  end if;
  if p_patch ? 'vat_rate' then
    v_vat := (p_patch ->> 'vat_rate')::numeric;
    if v_vat is null or v_vat not in (0, 10, 13.5, 14, 24, 25.5) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (0, 10, 13.5, 14, 24, 25.5)'); end if;
  end if;
  update kb.products set
    name           = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
    name_en        = case when p_patch ? 'name_en' then nullif(btrim(p_patch ->> 'name_en'), '') else name_en end,
    description    = case when p_patch ? 'description' then nullif(p_patch ->> 'description', '') else description end,
    description_en = case when p_patch ? 'description_en' then nullif(p_patch ->> 'description_en', '') else description_en end,
    price          = case when p_patch ? 'price' then v_price else price end,
    price_text     = case when p_patch ? 'price_text' then nullif(p_patch ->> 'price_text', '') else price_text end,
    vat_rate       = case when p_patch ? 'vat_rate' then v_vat else vat_rate end,
    active         = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    updated_at     = now()
   where id = p_product_id returning * into n;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'kb.products', p_product_id::text, 'ADMIN_UPDATE', to_jsonb(o), to_jsonb(n));
  insert into kb.change_log(table_name, row_id, action, actor, old_data, new_data)
  values ('products', p_product_id, 'update', 'booking-admin:' || coalesce(auth.uid()::text, 'unknown'), to_jsonb(o), to_jsonb(n));
  return jsonb_build_object('ok', true, 'id', n.id);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_update_addon(p_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['name','name_en','description','description_en','price','vat_rate','max_per_person','applies_modes','active','sort_order'];
  k text; v_price numeric; v_vat numeric; v_max integer; v_modes text[];
begin
  perform booking._require_permission('catalog.edit');
  if not exists (select 1 from booking.addons where id = p_id) then perform booking._err('not_found', 'Lisäpalvelua ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and (char_length(btrim(coalesce(p_patch ->> 'name', ''))) = 0 or char_length(p_patch ->> 'name') > 200) then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'price' then
    if coalesce(p_patch ->> 'price', '') !~ '^\d{1,6}([.,]\d{1,2})?$' then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
    v_price := replace(p_patch ->> 'price', ',', '.')::numeric;
  end if;
  if p_patch ? 'vat_rate' then
    v_vat := case when coalesce(p_patch ->> 'vat_rate', '') ~ '^\d{1,2}([.,]\d)?$' then replace(p_patch ->> 'vat_rate', ',', '.')::numeric else -1 end;
    if v_vat not in (0, 10, 13.5, 14, 24, 25.5) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (0, 10, 13.5, 14, 24, 25.5)'); end if;
  end if;
  if p_patch ? 'max_per_person' and nullif(p_patch ->> 'max_per_person', '') is not null then
    if p_patch ->> 'max_per_person' !~ '^\d{1,2}$' or (p_patch ->> 'max_per_person')::int not between 1 and 20 then perform booking._err('invalid_max', 'Enimmäismäärä / henkilö: 1–20'); end if;
    v_max := (p_patch ->> 'max_per_person')::int;
  end if;
  if p_patch ? 'applies_modes' then
    if jsonb_typeof(p_patch -> 'applies_modes') <> 'array' then perform booking._err('invalid_modes', 'Vuorotyypit virheellisessä muodossa'); end if;
    select array_agg(distinct x) into v_modes from jsonb_array_elements_text(p_patch -> 'applies_modes') x;
    if v_modes is null or not (v_modes <@ array['shared','exclusive','resource']) then perform booking._err('invalid_modes', 'Vuorotyyppi: shared (yleinen), exclusive (yksityinen) ja/tai resource (hoito, saunotus)'); end if;
  end if;
  if p_patch ? 'sort_order' and coalesce(p_patch ->> 'sort_order', '') !~ '^\d{1,5}$' then perform booking._err('invalid_sort', 'Virheellinen järjestys'); end if;
  update booking.addons set
    name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
    name_en = case when p_patch ? 'name_en' then nullif(btrim(coalesce(p_patch ->> 'name_en', '')), '') else name_en end,
    description = case when p_patch ? 'description' then nullif(p_patch ->> 'description', '') else description end,
    description_en = case when p_patch ? 'description_en' then nullif(p_patch ->> 'description_en', '') else description_en end,
    price_gross = case when p_patch ? 'price' then v_price else price_gross end,
    vat_rate = case when p_patch ? 'vat_rate' then v_vat else vat_rate end,
    max_per_person = case when p_patch ? 'max_per_person' then v_max else max_per_person end,
    applies_modes = case when p_patch ? 'applies_modes' then v_modes else applies_modes end,
    active = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end
   where id = p_id;
  return jsonb_build_object('ok', true, 'id', p_id);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_create_addon(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['code','name','name_en','description','description_en','price','vat_rate','max_per_person','applies_modes','active','sort_order'];
  k text; v_price numeric; v_vat numeric; v_max integer; v_modes text[]; v_id bigint; v_sort integer;
begin
  perform booking._require_permission('catalog.edit');
  if p_data is null or jsonb_typeof(p_data) <> 'object' then perform booking._err('invalid_addon', 'Anna lisäpalvelun tiedot'); end if;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa antaa: ' || k); end if;
  end loop;
  if coalesce(p_data ->> 'code', '') !~ '^[a-z][a-z0-9_]{1,40}$' then perform booking._err('invalid_code', 'Tunnus: pienet kirjaimet, numerot ja alaviiva (alkaa kirjaimella)'); end if;
  if exists (select 1 from booking.addons where code = p_data ->> 'code') then perform booking._err('code_exists', 'Tunnus on jo käytössä'); end if;
  if char_length(btrim(coalesce(p_data ->> 'name', ''))) = 0 or char_length(p_data ->> 'name') > 200 then perform booking._err('invalid_name', 'Anna nimi'); end if;
  if coalesce(p_data ->> 'price', '') !~ '^\d{1,6}([.,]\d{1,2})?$' then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  v_price := replace(p_data ->> 'price', ',', '.')::numeric;
  v_vat := case when coalesce(p_data ->> 'vat_rate', '') ~ '^\d{1,2}([.,]\d)?$' then replace(p_data ->> 'vat_rate', ',', '.')::numeric when p_data ? 'vat_rate' then -1 else 25.5 end;
  if v_vat not in (0, 10, 13.5, 14, 24, 25.5) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (0, 10, 13.5, 14, 24, 25.5)'); end if;
  if p_data ? 'max_per_person' and nullif(p_data ->> 'max_per_person', '') is not null then
    if p_data ->> 'max_per_person' !~ '^\d{1,2}$' or (p_data ->> 'max_per_person')::int not between 1 and 20 then perform booking._err('invalid_max', 'Enimmäismäärä / henkilö: 1–20'); end if;
    v_max := (p_data ->> 'max_per_person')::int;
  end if;
  if p_data ? 'applies_modes' then
    if jsonb_typeof(p_data -> 'applies_modes') <> 'array' then perform booking._err('invalid_modes', 'Vuorotyypit virheellisessä muodossa'); end if;
    select array_agg(distinct x) into v_modes from jsonb_array_elements_text(p_data -> 'applies_modes') x;
    if v_modes is null or not (v_modes <@ array['shared','exclusive','resource']) then perform booking._err('invalid_modes', 'Vuorotyyppi: shared (yleinen), exclusive (yksityinen) ja/tai resource (hoito, saunotus)'); end if;
  end if;
  v_sort := case when coalesce(p_data ->> 'sort_order', '') ~ '^\d{1,5}$' then (p_data ->> 'sort_order')::int else 100 end;
  insert into booking.addons(code, name, name_en, description, description_en, price_gross, vat_rate, max_per_person, applies_modes, active, sort_order)
  values (p_data ->> 'code', btrim(p_data ->> 'name'), nullif(btrim(coalesce(p_data ->> 'name_en', '')), ''), nullif(p_data ->> 'description', ''),
          nullif(p_data ->> 'description_en', ''), v_price, v_vat, v_max, coalesce(v_modes, '{shared,exclusive}'),
          coalesce((p_data ->> 'active')::boolean, true), v_sort)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_set_reservation_addons(p_reservation_id bigint, p_addons jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare res booking.reservations; v_old jsonb; v_total numeric;
begin
  perform booking._require_permission('bookings.manage');
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if res.status not in ('pending','confirmed') then perform booking._err('not_editable', 'Lisäpalveluita voi muuttaa vain voimassa olevaan varaukseen'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('addon_id', addon_id, 'name', product_name, 'quantity', quantity) order by id), '[]'::jsonb)
    into v_old from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';
  delete from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';
  update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = res.order_id), 0) where id = res.order_id;
  perform booking._attach_addons(res.id, p_addons);
  select total_gross into v_total from booking.orders where id = res.order_id;
  update booking.payments set amount = v_total where order_id = res.order_id and status = 'pending' and provider = 'manual';
  perform booking._refresh_order_payment(res.order_id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'order_items', res.order_id::text, 'ADMIN_SET_ADDONS', jsonb_build_object('addons', v_old),
          jsonb_build_object('addons', coalesce(p_addons, '[]'::jsonb), 'total', v_total));
  return jsonb_build_object('ok', true, 'total', v_total);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_get_order(p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; c booking.customers;
begin
  perform booking._require_staff();
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into c from booking.customers where id = o.customer_id;
  return jsonb_build_object(
    'order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'total', o.total_gross,
    'source_channel', o.source_channel, 'created_at', o.created_at, 'customer_note', o.customer_note, 'internal_note', o.internal_note,
    'customer_kind', o.customer_kind, 'billing', o.billing, 'invoice_reference', o.invoice_reference,
    'customer', case when c.id is null then null else jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone,
        'company', c.company, 'customer_kind', c.customer_kind, 'business_id', c.business_id) end,
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'product_name', it.product_name, 'mode', r.mode,
        'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'notes', r.notes, 'item_total', it.line_total_gross,
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity,
                     'unit_price', ai.unit_price_gross, 'line_total', ai.line_total_gross, 'vat_rate', ai.vat_rate) order by ai.id)
                   from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb)) order by r.starts_at)
        from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'method', p.method, 'status', p.status, 'amount', p.amount, 'paid_at', p.paid_at) order by p.id)
        from booking.payments p where p.order_id = o.id), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_create_payment_link(p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_amount numeric; v_id bigint;
begin
  perform booking._require_permission('payments.manage');
  select total_gross into v_amount from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  insert into booking.payments(order_id, method, provider, status, amount, link_expires_at, note, created_by)
  values (p_order_id, 'visma_pay', 'visma_pay', 'pending', v_amount, now() + interval '7 days',
          'STUB: maksulinkki luodaan kun Visma Pay -integraatio on toteutettu', auth.uid()) returning id into v_id;
  perform booking._refresh_order_payment(p_order_id);
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'implemented', false, 'link_url', null,
                            'message', 'Visma Pay -maksulinkki ei ole vielä käytössä (paikkavaraus luotu)');
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_record_payment(p_order_id bigint, p_method text, p_amount numeric, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pm booking.payment_methods; v_id bigint;
begin
  perform booking._require_permission('payments.manage');
  select * into v_pm from booking.payment_methods where code = p_method and active and is_manual;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä / ei käsin kirjattava'); end if;
  if p_amount is null or p_amount <= 0 then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  if not exists (select 1 from booking.orders where id = p_order_id) then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  -- merkitse mahdollinen odottava käsinkirjaus maksetuksi, muuten uusi rivi
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, note, created_by)
  values (p_order_id, p_method, 'manual', 'paid', p_amount, now(), p_note, auth.uid()) returning id into v_id;
  update booking.payments set status = 'cancelled' where order_id = p_order_id and provider = 'manual' and status = 'pending' and id <> v_id;
  perform booking._refresh_order_payment(p_order_id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = p_order_id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = p_order_id and status = 'pending';
  return jsonb_build_object('ok', true, 'payment_id', v_id);
end $function$;

CREATE OR REPLACE FUNCTION booking.payment_prepare(p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; v_id bigint; c booking.customers;
begin
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into c from booking.customers where id = o.customer_id;
  insert into booking.payments(order_id, method, provider, status, amount, currency)
  values (o.id, 'visma_pay', 'visma_pay', 'pending', o.total_gross, o.currency) returning id into v_id;
  return jsonb_build_object('payment_id', v_id, 'order_no', o.order_no, 'amount', o.total_gross, 'currency', o.currency,
                            'email', c.email, 'locale', o.locale);
end $function$;

grant execute on function booking._create_legs_booking(text, bigint, timestamptz, timestamptz, integer, bigint, text, uuid, text, numeric, bigint, boolean, text, boolean, bigint) to service_role;

grant execute on function booking._create_booking_core(bigint, date, integer, bigint, text, uuid, text, text, text, integer, boolean, timestamptz, timestamptz, numeric, bigint) to service_role;

grant execute on function booking.admin_create_payment_link(bigint), booking.admin_record_payment(bigint, text, numeric, text) to authenticated, service_role;
