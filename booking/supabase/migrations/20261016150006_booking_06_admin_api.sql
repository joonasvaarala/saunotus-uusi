-- =====================================================================
-- booking 06: hallinnan rajapinta (authenticated + booking.staff-tarkistus funktiossa)
-- Kaikki kirjoitukset kulkevat näiden funktioiden kautta (taulujen suoria kirjoitusoikeuksia ei anneta).
-- Jokainen funktio vaatii OIKEUDEN (booking.role_permissions → _require_permission), ei roolinimeä:
--   admin   = kaikki oikeudet (myös henkilöstön hallinta ja audit-loki)
--   manager = ylläpitäjä: varaukset + catalog.edit (tuotteet/hinnat/kuvaukset/tuoteasetukset), settings.edit, resources.edit, rules.edit, annual_cards.manage
--   staff   = peruskäyttäjä: bookings/customers/payments/blocks (ei hinnan/tuotteen/asetusten muokkausta)
-- kb.products / kb.product_price_variants on totuus: admin_update_product / admin_update_price_variant
-- kirjoittavat suoraan kb:hen (SECURITY DEFINER, oikeus catalog.edit) ja kirjaavat booking.audit_log + kb.change_log.
-- =====================================================================
set local search_path = booking, extensions, public;

-- ---------- tuotteet ja hinnat (kb) ----------
create or replace function booking.admin_list_products()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
end $$;

create or replace function booking.admin_update_product(p_product_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
end $$;

create or replace function booking.admin_update_price_variant(p_variant_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  allowed text[] := array['label','price','notes','active','included_persons','extra_person_price'];
  k text; o kb.product_price_variants; n kb.product_price_variants; v_price numeric;
begin
  perform booking._require_permission('catalog.edit');
  select * into o from kb.product_price_variants where id = p_variant_id;
  if not found then perform booking._err('not_found', 'Hintavarianttia ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'price' then
    v_price := (p_patch ->> 'price')::numeric;
    if v_price is null or v_price < 0 or v_price > 100000 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  end if;
  update kb.product_price_variants set
    label = case when p_patch ? 'label' then btrim(p_patch ->> 'label') else label end,
    price = case when p_patch ? 'price' then v_price else price end,
    notes = case when p_patch ? 'notes' then nullif(p_patch ->> 'notes', '') else notes end,
    active = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    included_persons = case when p_patch ? 'included_persons' then (p_patch ->> 'included_persons')::int else included_persons end,
    extra_person_price = case when p_patch ? 'extra_person_price' then (p_patch ->> 'extra_person_price')::numeric else extra_person_price end,
    updated_at = now()
   where id = p_variant_id returning * into n;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'kb.product_price_variants', p_variant_id::text, 'ADMIN_UPDATE', to_jsonb(o), to_jsonb(n));
  insert into kb.change_log(table_name, row_id, action, actor, old_data, new_data)
  values ('product_price_variants', p_variant_id, 'update', 'booking-admin:' || coalesce(auth.uid()::text, 'unknown'), to_jsonb(o), to_jsonb(n));
  return jsonb_build_object('ok', true, 'id', n.id);
end $$;

create or replace function booking.admin_update_product_config(p_product_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare allowed text[] := array['bookable','shop_visible','sort_order','min_persons','max_persons','notes']; k text;
begin
  perform booking._require_permission('catalog.edit');
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  update booking.product_config set
    bookable = case when p_patch ? 'bookable' then (p_patch ->> 'bookable')::boolean else bookable end,
    shop_visible = case when p_patch ? 'shop_visible' then (p_patch ->> 'shop_visible')::boolean else shop_visible end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end,
    min_persons = case when p_patch ? 'min_persons' then (p_patch ->> 'min_persons')::int else min_persons end,
    max_persons = case when p_patch ? 'max_persons' then (p_patch ->> 'max_persons')::int else max_persons end,
    notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end
   where product_id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotteella ei ole varauskonfiguraatiota'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- asetukset, resurssit, henkilöstö (admin) ----------
create or replace function booking.admin_set_setting(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform booking._require_permission('settings.edit');
  if not exists (select 1 from booking.settings where key = p_key) then perform booking._err('unknown_setting', 'Tuntematon asetus'); end if;
  -- perusvalidointi tärkeimmille
  if p_key = 'hold_minutes' and (jsonb_typeof(p_value) <> 'number' or (p_value #>> '{}')::numeric not between 1 and 240) then perform booking._err('invalid_value', 'Pitoaika 1–240 min'); end if;
  if p_key = 'public_payment_mode' and (p_value #>> '{}') not in ('pay_later','hold_until_paid') then perform booking._err('invalid_value', 'pay_later tai hold_until_paid'); end if;
  if p_key = 'customer_change_hours_before' and (jsonb_typeof(p_value) <> 'number' or (p_value #>> '{}')::numeric not between 0 and 720 or (p_value #>> '{}')::numeric <> trunc((p_value #>> '{}')::numeric)) then
    perform booking._err('invalid_value', 'Asiakkaan muutosraja 0–720 tuntia (kokonaisluku)');
  end if;
  if p_key = 'annual_card_max_persons' and (jsonb_typeof(p_value) <> 'number' or (p_value #>> '{}')::numeric not between 1 and 20 or (p_value #>> '{}')::numeric <> trunc((p_value #>> '{}')::numeric)) then
    perform booking._err('invalid_value', 'Vuosikortin henkilömäärä 1–20');
  end if;
  update booking.settings set value = p_value, updated_by = auth.uid() where key = p_key;
  return jsonb_build_object('ok', true);
end $$;

create or replace function booking.admin_update_resource(p_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare allowed text[] := array['name','capacity','active','notes','sort_order']; k text;
begin
  perform booking._require_permission('resources.edit');
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  update booking.resources set
    name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
    capacity = case when p_patch ? 'capacity' then (p_patch ->> 'capacity')::int else capacity end,
    active = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end
   where id = p_id;
  if not found then perform booking._err('not_found', 'Resurssia ei löydy'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function booking.admin_list_staff()
returns table (user_id uuid, email text, name text, role text, active boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('staff.manage');
  return query select s.user_id, s.email, s.name, s.role, s.active from booking.staff s order by s.name;
end $$;

create or replace function booking.admin_upsert_staff(p_user_id uuid, p_name text, p_role text, p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_old booking.staff;
begin
  perform booking._require_permission('staff.manage');   -- vain admin: manager/staff eivät voi muuttaa rooleja eikä antaa admin-oikeutta
  if not exists (select 1 from booking.roles r where r.code = p_role and r.is_staff and r.active) then
    perform booking._err('invalid_role', 'Tuntematon henkilöstörooli (booking.roles, is_staff=true)');
  end if;
  if char_length(btrim(coalesce(p_name, ''))) < 1 then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if not exists (select 1 from auth.users where id = p_user_id) then perform booking._err('no_such_user', 'Käyttäjää ei löydy (luo ensin Supabase Authissa)'); end if;
  select * into v_old from booking.staff where user_id = p_user_id;
  -- viimeistä aktiivista adminia ei saa alentaa tai poistaa käytöstä
  if found and v_old.role = 'admin' and v_old.active and (p_role <> 'admin' or not p_active) and
     (select count(*) from booking.staff where role = 'admin' and active and user_id <> p_user_id) = 0 then
    perform booking._err('last_admin', 'Viimeistä ylläpitäjää (admin) ei voi alentaa tai poistaa käytöstä');
  end if;
  insert into booking.staff(user_id, email, name, role, active)
  values (p_user_id, (select email from auth.users where id = p_user_id), btrim(p_name), p_role, p_active)
  on conflict (user_id) do update set name = excluded.name, role = excluded.role, active = excluded.active;
  return jsonb_build_object('ok', true);
end $$;

-- Omat oikeudet käyttöliittymää varten (näkymien/kenttien piilotus). Palvelin tarkistaa oikeudet aina itse.
create or replace function booking.admin_my_permissions()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_role text;
begin
  perform booking._require_staff();
  v_role := booking.current_staff_role();
  return jsonb_build_object('role', v_role,
    'role_label', (select r.label from booking.roles r where r.code = v_role),
    'permissions', coalesce((select jsonb_agg(rp.permission order by rp.permission) from booking.role_permissions rp where rp.role_code = v_role), '[]'::jsonb));
end $$;

-- Henkilöstöroolit valintalistaan (admin: henkilöstön hallinta)
create or replace function booking.admin_list_roles()
returns table (code text, label text, description text, is_staff boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  return query select r.code, r.label, r.description, r.is_staff from booking.roles r where r.active order by r.sort_order, r.code;
end $$;

-- Vuorosäännön muokkaus (rules.edit): vain turvalliset kentät. Aikataulun/tuotteen/tilan muutos tehdään edelleen SQL:llä.
create or replace function booking.admin_update_schedule_rule(p_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare allowed text[] := array['label','active','min_persons','max_persons','deadline_minutes','valid_from','valid_to','notes','sort_order']; k text;
  v_min integer; v_max integer;
begin
  perform booking._require_permission('rules.edit');
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'min_persons' and ((p_patch ->> 'min_persons')::int is null or (p_patch ->> 'min_persons')::int < 1) then perform booking._err('invalid_value', 'Vähimmäishenkilömäärä ≥ 1'); end if;
  if p_patch ? 'max_persons' and (p_patch ->> 'max_persons') is not null and (p_patch ->> 'max_persons')::int < 1 then perform booking._err('invalid_value', 'Enimmäishenkilömäärä ≥ 1'); end if;
  if p_patch ? 'deadline_minutes' and ((p_patch ->> 'deadline_minutes')::int is null or (p_patch ->> 'deadline_minutes')::int < 0) then perform booking._err('invalid_value', 'Myynnin sulkeutumisaika ≥ 0 min'); end if;
  if p_patch ? 'label' and char_length(btrim(coalesce(p_patch ->> 'label', ''))) = 0 then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  update booking.schedule_rules set
    label = case when p_patch ? 'label' then btrim(p_patch ->> 'label') else label end,
    active = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    min_persons = case when p_patch ? 'min_persons' then (p_patch ->> 'min_persons')::int else min_persons end,
    max_persons = case when p_patch ? 'max_persons' then (p_patch ->> 'max_persons')::int else max_persons end,
    deadline_minutes = case when p_patch ? 'deadline_minutes' then (p_patch ->> 'deadline_minutes')::int else deadline_minutes end,
    valid_from = case when p_patch ? 'valid_from' then (p_patch ->> 'valid_from')::date else valid_from end,
    valid_to = case when p_patch ? 'valid_to' then (p_patch ->> 'valid_to')::date else valid_to end,
    notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end
   where id = p_id returning min_persons, max_persons into v_min, v_max;
  if not found then perform booking._err('not_found', 'Vuorosääntöä ei löydy'); end if;
  if v_max is not null and v_max < v_min then perform booking._err('invalid_value', 'Enimmäishenkilömäärä on pienempi kuin vähimmäismäärä'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- sulut ----------
create or replace function booking.admin_create_block(p_space_id bigint, p_starts_at timestamptz, p_ends_at timestamptz, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  perform booking._require_permission('blocks.manage');
  perform pg_advisory_xact_lock(hashtextextended('booking:space:' || p_space_id::text, 0));
  perform booking._expire_holds(p_space_id);
  if exists (select 1 from booking.reservations r where r.space_id = p_space_id and booking._res_active(r.status, r.hold_expires_at)
              and r.during && tstzrange(p_starts_at, p_ends_at, '[)')) then
    perform booking._err('has_reservations', 'Ajalla on varauksia – peru ne ensin');
  end if;
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason, created_by)
  values (p_space_id, p_starts_at, p_ends_at, p_reason, auth.uid()) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function booking.admin_delete_block(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform booking._require_permission('blocks.manage');
  update booking.space_blocks set active = false where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- varaukset: listaus ja päivänäkymä ----------
create or replace function booking.admin_list_reservations(
  p_from timestamptz default null, p_to timestamptz default null, p_search text default null,
  p_status text default null, p_product_id bigint default null, p_limit integer default 50, p_offset integer default 0)
returns table (
  reservation_id bigint, order_id bigint, order_no bigint, status text, order_status text, payment_status text,
  product_id bigint, product_name text, mode text, starts_at timestamptz, ends_at timestamptz, persons integer,
  total_gross numeric, customer_id bigint, customer_name text, customer_email text, customer_phone text,
  source_channel text, created_at timestamptz, hold_expires_at timestamptz, notes text, annual_card_id bigint, total_count bigint)
language plpgsql stable security definer set search_path = '' as $$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select r.id, o.id, o.order_no,
           case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           o.status, o.payment_status, r.product_id, coalesce(it.product_name, p.name), r.mode, r.starts_at, r.ends_at, r.persons,
           o.total_gross, c.id, c.name, c.email, c.phone, o.source_channel, o.created_at, r.hold_expires_at, r.notes, r.annual_card_id,
           count(*) over ()
      from booking.reservations r
      join booking.orders o on o.id = r.order_id
      left join booking.order_items it on it.id = r.order_item_id
      left join kb.products p on p.id = r.product_id
      left join booking.customers c on c.id = o.customer_id
     where (p_from is null or r.starts_at >= p_from) and (p_to is null or r.starts_at < p_to)
       and (p_product_id is null or r.product_id = p_product_id)
       and (p_status is null
            or (p_status = 'active' and booking._res_active(r.status, r.hold_expires_at))
            or (p_status = 'expired' and r.status = 'pending' and r.hold_expires_at <= now()) or r.status = p_status)
       and (q is null or c.name ilike '%' || q || '%' or c.email ilike '%' || q || '%' or c.phone ilike '%' || q || '%'
            or o.order_no::text = q or c.company ilike '%' || q || '%')
     order by r.starts_at desc, r.id desc
     limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $$;

-- Päivänäkymä: päivän vuorot (myös täydet/suljetut) + päivän varaukset + sulut
create or replace function booking.admin_day_view(p_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_from timestamptz := p_date::timestamp at time zone 'Europe/Helsinki';
        v_to timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'date', p_date,
    'sessions', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.rule_id)
                           from booking._sessions(p_date, p_date, null, false) s), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object(
        'reservation_id', r.id, 'order_no', o.order_no, 'status', r.status, 'payment_status', o.payment_status,
        'product_name', coalesce(it.product_name, p.name), 'mode', r.mode, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
        'persons', r.persons, 'customer_name', c.name, 'customer_phone', c.phone, 'rule_id', r.rule_id, 'notes', r.notes,
        'annual_card', r.annual_card_id is not null, 'hold_expires_at', r.hold_expires_at) order by r.starts_at, r.id)
        from booking.reservations r join booking.orders o on o.id = r.order_id
        left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
        left join booking.customers c on c.id = o.customer_id
        where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'space_id', b.space_id, 'starts_at', b.starts_at,
        'ends_at', b.ends_at, 'reason', b.reason) order by b.starts_at)
        from booking.space_blocks b where b.active and b.starts_at < v_to and b.ends_at > v_from), '[]'::jsonb));
end $$;

-- ---------- varauksen luonti hallinnassa (käsivaraus) ----------
create or replace function booking.admin_create_booking(
  p_rule_id bigint, p_date date, p_persons integer,
  p_customer_id bigint default null, p_customer jsonb default null,
  p_payment_method text default 'pay_later', p_paid boolean default false,
  p_note text default null, p_start timestamptz default null, p_end timestamptz default null,
  p_price numeric default null, p_channel text default 'admin')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cust bigint := p_customer_id; v_res jsonb; v_email text; v_order bigint; v_pm booking.payment_methods;
begin
  perform booking._require_permission('bookings.manage');
  select * into v_pm from booking.payment_methods where code = p_payment_method and active;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä'); end if;
  if p_channel not in ('admin','phone','email','walk_in','other') then perform booking._err('invalid_channel', 'Virheellinen lähdekanava'); end if;
  if p_price is not null and p_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  if v_cust is null then
    if p_customer is null or char_length(btrim(coalesce(p_customer ->> 'name', ''))) < 2 then
      perform booking._err('customer_required', 'Valitse asiakas tai anna nimi');
    end if;
    v_email := lower(nullif(btrim(coalesce(p_customer ->> 'email', '')), ''));
    if v_email is not null then
      v_cust := booking._upsert_customer(btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                 coalesce((p_customer ->> 'marketing_consent')::boolean, false), 'admin', coalesce(p_customer ->> 'language', 'fi'));
    else
      insert into booking.customers(name, phone, company, language, marketing_consent, marketing_consent_at, marketing_consent_source)
      values (btrim(p_customer ->> 'name'), nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''), nullif(btrim(coalesce(p_customer ->> 'company', '')), ''),
              coalesce(p_customer ->> 'language', 'fi'), coalesce((p_customer ->> 'marketing_consent')::boolean, false),
              case when coalesce((p_customer ->> 'marketing_consent')::boolean, false) then now() end,
              case when coalesce((p_customer ->> 'marketing_consent')::boolean, false) then 'admin' end)
      returning id into v_cust;
    end if;
  elsif not exists (select 1 from booking.customers where id = v_cust) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;

  v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, p_channel, auth.uid(), 'fi', p_note,
                                        'confirmed', null, false, p_start, p_end, p_price);
  v_order := (v_res ->> 'order_id')::bigint;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
  values (v_order, p_payment_method, 'manual', case when p_paid then 'paid' else 'pending' end, (v_res ->> 'total')::numeric,
          case when p_paid then now() end, auth.uid());
  update booking.orders set payment_status = case when p_paid then 'paid' else 'unpaid' end where id = v_order;
  return v_res - 'public_token' || jsonb_build_object('customer_id', v_cust);
end $$;

-- Päivittää tilauksen maksutilan maksurivien perusteella
create or replace function booking._refresh_order_payment(p_order_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare v_total numeric; v_paid numeric; v_refunded numeric; v_pending int;
begin
  select total_gross into v_total from booking.orders where id = p_order_id;
  select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0),
         coalesce(sum(refunded_amount), 0),
         count(*) filter (where status = 'pending')
    into v_paid, v_refunded, v_pending from booking.payments where order_id = p_order_id;
  update booking.orders set payment_status = case
      when v_paid > 0 and v_refunded >= v_paid then 'refunded'
      when v_refunded > 0 then 'partially_refunded'
      when v_paid >= v_total and v_total > 0 then 'paid'
      when v_paid > 0 then 'partially_paid'
      when v_pending > 0 and exists (select 1 from booking.payments where order_id = p_order_id and status = 'pending' and provider <> 'manual') then 'pending'
      else 'unpaid' end
   where id = p_order_id;
end $$;

create or replace function booking.admin_record_payment(p_order_id bigint, p_method text, p_amount numeric, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Maksulinkki-paikka: Visma Pay -toteutus täyttää myöhemmin (ks. docs/maksut-visma-pay.md). Nyt vain stub.
create or replace function booking.admin_create_payment_link(p_order_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Varauksen tilan muutos (peruutus, saapunut/ei saapunut, vahvistus)
create or replace function booking.admin_set_reservation_status(p_reservation_id bigint, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r booking.reservations;
begin
  perform booking._require_permission('bookings.manage');
  if p_status not in ('confirmed','cancelled','completed','no_show') then perform booking._err('invalid_status', 'Tila ei sallittu'); end if;
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  update booking.reservations set
      status = p_status, hold_expires_at = case when p_status = 'confirmed' then null else hold_expires_at end,
      cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
      cancel_reason = case when p_status = 'cancelled' then p_reason else cancel_reason end,
      checkin_at = case when p_status = 'completed' and checkin_at is null then now() else checkin_at end
   where id = p_reservation_id;   -- trigger validoi uudelleenaktivoinnin
  if p_status = 'cancelled' and not exists (select 1 from booking.reservations x where x.order_id = r.order_id and x.status in ('pending','confirmed')) then
    update booking.orders set status = 'cancelled', cancelled_at = now() where id = r.order_id;
  elsif p_status = 'confirmed' then
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), cancelled_at = null where id = r.order_id;
  elsif p_status = 'completed' then
    update booking.orders set status = 'completed' where id = r.order_id and not exists (select 1 from booking.reservations x where x.order_id = r.order_id and x.status in ('pending','confirmed'));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- asiakasrekisteri ----------
create or replace function booking.admin_list_customers(p_search text default null, p_limit integer default 50, p_offset integer default 0)
returns table (
  id bigint, name text, email text, phone text, company text, city text, marketing_consent boolean,
  marketing_consent_at timestamptz, created_at timestamptz, orders_count bigint, last_visit timestamptz, total_count bigint,
  customer_type text)
language plpgsql stable security definer set search_path = '' as $$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select c.id, c.name, c.email, c.phone, c.company, c.city, c.marketing_consent, c.marketing_consent_at, c.created_at,
           (select count(*) from booking.orders o where o.customer_id = c.id and o.status in ('pending','confirmed','completed')),
           (select max(r.starts_at) from booking.reservations r join booking.orders o on o.id = r.order_id
             where o.customer_id = c.id and r.status in ('confirmed','completed')),
           count(*) over (), c.customer_type
      from booking.customers c
     where c.anonymized_at is null
       and (q is null or c.name ilike '%' || q || '%' or c.email ilike '%' || q || '%' or c.phone ilike '%' || q || '%' or c.company ilike '%' || q || '%')
     order by c.created_at desc, c.id desc
     limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $$;

create or replace function booking.admin_get_customer(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c booking.customers;
begin
  perform booking._require_staff();
  select * into c from booking.customers where id = p_id;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  return to_jsonb(c) - 'unsubscribe_token' - 'customer_type_is_staff' || jsonb_build_object(
    'annual_cards', coalesce((select jsonb_agg(to_jsonb(ac) - 'created_by' - 'revoked_by' order by ac.valid_from desc) from booking.annual_cards ac where ac.customer_id = c.id), '[]'::jsonb),
    'orders', coalesce((
    select jsonb_agg(jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status,
        'total', o.total_gross, 'created_at', o.created_at, 'channel', o.source_channel,
        'reservations', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'starts_at', r.starts_at, 'persons', r.persons, 'status', r.status,
              'product_name', coalesce(it.product_name, '')) order by r.starts_at), '[]'::jsonb)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id))
      order by o.created_at desc) from booking.orders o where o.customer_id = c.id), '[]'::jsonb));
end $$;

create or replace function booking.admin_update_customer(p_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare allowed text[] := array['name','email','phone','company','address','zip','city','country','language','notes','marketing_consent']; k text; v_consent boolean;
begin
  perform booking._require_permission('customers.manage');
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and char_length(btrim(coalesce(p_patch ->> 'name', ''))) < 1 then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'marketing_consent' then v_consent := (p_patch ->> 'marketing_consent')::boolean; end if;
  update booking.customers set
    name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
    email = case when p_patch ? 'email' then nullif(btrim(p_patch ->> 'email'), '') else email end,
    phone = case when p_patch ? 'phone' then nullif(btrim(p_patch ->> 'phone'), '') else phone end,
    company = case when p_patch ? 'company' then nullif(btrim(p_patch ->> 'company'), '') else company end,
    address = case when p_patch ? 'address' then p_patch ->> 'address' else address end,
    zip = case when p_patch ? 'zip' then p_patch ->> 'zip' else zip end,
    city = case when p_patch ? 'city' then p_patch ->> 'city' else city end,
    country = case when p_patch ? 'country' then p_patch ->> 'country' else country end,
    language = case when p_patch ? 'language' then p_patch ->> 'language' else language end,
    notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end,
    marketing_consent = coalesce(v_consent, marketing_consent),
    marketing_consent_at = case when v_consent is distinct from marketing_consent and v_consent is not null then now() else marketing_consent_at end,
    marketing_consent_source = case when v_consent is distinct from marketing_consent and v_consent is not null then 'admin' else marketing_consent_source end,
    marketing_unsubscribed_at = case when v_consent is false and marketing_consent then now() else marketing_unsubscribed_at end
   where id = p_id;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- varauksen muuttaminen hallinnasta (bookings.manage) ----------
-- Siirto toiseen vuoroon (SAMA tuote) ja/tai henkilömäärän muutos; ei 48 h rajaa eikä myyntisulkua. Samat lukitukset ja säännöt
-- kuin uudella varauksella (booking._change_booking_core). Vain vahvistettu varaus.
create or replace function booking.admin_change_booking(
  p_reservation_id bigint, p_rule_id bigint default null, p_date date default null, p_persons integer default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform booking._require_permission('bookings.manage');
  if p_rule_id is null and p_date is null and p_persons is null then perform booking._err('invalid_change', 'Ei muutettavaa'); end if;
  return booking._change_booking_core(p_reservation_id, p_rule_id, p_date, p_persons, false, null, auth.uid(), 'ADMIN_CHANGE')
         || jsonb_build_object('ok', true);
end $$;

-- ---------- vuosikortit ----------
-- Vuosikortti: asiakas saa varata ILMAISEKSI yleisiä vuoroja, yksi tuleva varaus kerrallaan (pakotus: trigger migraatiossa 04).
create or replace function booking.admin_grant_annual_card(p_customer_id bigint, p_valid_from date, p_valid_to date, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  perform booking._require_permission('annual_cards.manage');
  if not exists (select 1 from booking.customers where id = p_customer_id and anonymized_at is null) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;
  if p_valid_from is null or p_valid_to is null or p_valid_to < p_valid_from then
    perform booking._err('invalid_dates', 'Virheellinen voimassaoloaika');
  end if;
  begin
    insert into booking.annual_cards(customer_id, valid_from, valid_to, notes, created_by)
    values (p_customer_id, p_valid_from, p_valid_to, nullif(btrim(coalesce(p_notes, '')), ''), auth.uid()) returning id into v_id;
  exception when exclusion_violation then
    perform booking._err('annual_card_overlap', 'Asiakkaalla on jo aktiivinen vuosikortti tälle ajanjaksolle');
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Voimassaolon jatko / huomautusten muokkaus
create or replace function booking.admin_update_annual_card(p_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare allowed text[] := array['valid_from','valid_to','notes']; k text;
begin
  perform booking._require_permission('annual_cards.manage');
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  begin
    update booking.annual_cards set
      valid_from = case when p_patch ? 'valid_from' then (p_patch ->> 'valid_from')::date else valid_from end,
      valid_to = case when p_patch ? 'valid_to' then (p_patch ->> 'valid_to')::date else valid_to end,
      notes = case when p_patch ? 'notes' then nullif(btrim(coalesce(p_patch ->> 'notes', '')), '') else notes end
     where id = p_id;
  exception
    when exclusion_violation then perform booking._err('annual_card_overlap', 'Asiakkaalla on jo aktiivinen vuosikortti tälle ajanjaksolle');
    when check_violation then perform booking._err('invalid_dates', 'Virheellinen voimassaoloaika');
  end;
  if not found then perform booking._err('not_found', 'Vuosikorttia ei löydy'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Vuosikortin poisto (active=false, rivi säilyy historiana). p_cancel_future: peru myös kortin tulevat varaukset.
create or replace function booking.admin_revoke_annual_card(p_id bigint, p_cancel_future boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c booking.annual_cards; v_n integer; r record; v_cancelled integer := 0;
begin
  perform booking._require_permission('annual_cards.manage');
  select * into c from booking.annual_cards where id = p_id for update;
  if not found then perform booking._err('not_found', 'Vuosikorttia ei löydy'); end if;
  update booking.annual_cards set active = false, revoked_at = coalesce(revoked_at, now()), revoked_by = coalesce(revoked_by, auth.uid()) where id = p_id;
  select count(*) into v_n from booking.reservations x where x.annual_card_id = p_id and x.status in ('pending','confirmed') and x.starts_at > now();
  if p_cancel_future then
    for r in select x.id from booking.reservations x where x.annual_card_id = p_id and x.status in ('pending','confirmed') and x.starts_at > now() loop
      perform booking.admin_set_reservation_status(r.id, 'cancelled', 'annual_card_revoked');
      v_cancelled := v_cancelled + 1;
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'future_reservations', v_n, 'cancelled', v_cancelled);
end $$;

create or replace function booking.admin_list_annual_cards(p_customer_id bigint default null, p_only_active boolean default true)
returns table (id bigint, customer_id bigint, customer_name text, customer_email text, valid_from date, valid_to date, active boolean,
               notes text, created_at timestamptz, next_reservation_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  return query
    select a.id, a.customer_id, c.name, c.email, a.valid_from, a.valid_to, a.active, a.notes, a.created_at,
           (select min(r.starts_at) from booking.reservations r where r.annual_card_id = a.id and r.status in ('pending','confirmed') and r.starts_at > now())
      from booking.annual_cards a join booking.customers c on c.id = a.customer_id
     where (p_customer_id is null or a.customer_id = p_customer_id) and (not p_only_active or a.active)
     order by a.active desc, a.valid_to desc, a.id desc;
end $$;

-- Vuosikorttivaraus hallinnasta: ilmainen (0 €), vain yleinen vuoro, 1 hlö (asetus annual_card_max_persons), yksi tuleva varaus kerrallaan.
-- Käyttää asiakkaan voimassa olevaa korttia vuoron päivänä. Samat lukitukset/säännöt kuin muillakin varauksilla.
create or replace function booking.admin_create_annual_card_booking(
  p_customer_id bigint, p_rule_id bigint, p_date date, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_card booking.annual_cards; v_res jsonb; v_persons integer; v_mode text;
begin
  perform booking._require_permission('bookings.manage');
  if not exists (select 1 from booking.customers where id = p_customer_id) then perform booking._err('customer_not_found', 'Asiakasta ei löydy'); end if;
  select * into v_card from booking.annual_cards a
   where a.customer_id = p_customer_id and a.active and p_date between a.valid_from and a.valid_to order by a.id desc limit 1;
  if not found then perform booking._err('no_annual_card', 'Asiakkaalla ei ole voimassa olevaa vuosikorttia valittuna päivänä'); end if;
  select mode into v_mode from booking.schedule_rules where id = p_rule_id;
  if v_mode is distinct from 'shared' then perform booking._err('annual_card_shared_only', 'Vuosikortilla voi varata vain yleisiä vuoroja (ei yksityisvuoroja)'); end if;
  v_persons := coalesce((booking._setting('annual_card_max_persons', '1'::jsonb) #>> '{}')::int, 1);
  v_res := booking._create_booking_core(p_rule_id, p_date, v_persons, p_customer_id, 'admin', auth.uid(), 'fi', p_note,
                                        'confirmed', null, false, null, null, null, v_card.id);
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, note, created_by)
  values ((v_res ->> 'order_id')::bigint, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikorttivaraus', auth.uid());
  update booking.orders set payment_status = 'paid' where id = (v_res ->> 'order_id')::bigint;
  return v_res - 'public_token' || jsonb_build_object('customer_id', p_customer_id, 'annual_card_id', v_card.id);
end $$;

-- ---------- maksuvälittäjäadapteri (service_role; Visma Pay -toteutus kutsuu näitä Edge Functionista) ----------
-- Katso docs/maksut-visma-pay.md. Tässä vain tietokantapuoli; varsinainen HTTP-integraatio puuttuu tarkoituksella.
create or replace function booking.payment_prepare(p_order_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o booking.orders; v_id bigint; c booking.customers;
begin
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into c from booking.customers where id = o.customer_id;
  insert into booking.payments(order_id, method, provider, status, amount, currency)
  values (o.id, 'visma_pay', 'visma_pay', 'pending', o.total_gross, o.currency) returning id into v_id;
  return jsonb_build_object('payment_id', v_id, 'order_no', o.order_no, 'amount', o.total_gross, 'currency', o.currency,
                            'email', c.email, 'locale', o.locale);
end $$;

create or replace function booking.payment_attach_provider_ref(p_payment_id bigint, p_provider_ref text, p_link_url text default null, p_raw jsonb default null)
returns void language sql security definer set search_path = '' as $$
  update booking.payments set provider_ref = p_provider_ref, link_url = p_link_url, raw = coalesce(p_raw, raw)
   where id = p_payment_id and provider = 'visma_pay'
$$;

-- Maksu onnistui (kutsutaan vasta kun Visma Payn MAC on varmennettu Edge Functionissa). Idempotentti.
create or replace function booking.payment_mark_paid(p_provider text, p_provider_ref text, p_amount numeric, p_raw jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pay booking.payments;
begin
  select * into pay from booking.payments where provider = p_provider and provider_ref = p_provider_ref for update;
  if not found then perform booking._err('payment_not_found', 'Maksua ei löydy'); end if;
  if pay.status = 'paid' then return jsonb_build_object('ok', true, 'already', true); end if;
  if p_amount is not null and p_amount <> pay.amount then perform booking._err('amount_mismatch', 'Summa ei täsmää'); end if;
  update booking.payments set status = 'paid', paid_at = now(), provider_status = 'paid', raw = coalesce(p_raw, raw) where id = pay.id;
  perform booking._refresh_order_payment(pay.order_id);
  -- vahvista pitovaraukset; jos pito ehti vanhentua ja aika on mennyt, trigger estää → tilaus jää tarkistettavaksi
  begin
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = pay.order_id and status in ('pending','expired');
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = pay.order_id;
  exception when sqlstate 'BK001' then
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'MAKSETTU MUTTA AIKA EI ENÄÄ VAPAA – tarkista käsin / palauta maksu' where id = pay.order_id;
    return jsonb_build_object('ok', true, 'needs_manual_review', true);
  end;
  return jsonb_build_object('ok', true);
end $$;

create or replace function booking.payment_mark_failed(p_provider text, p_provider_ref text, p_status text default 'failed', p_raw jsonb default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update booking.payments set status = case when p_status in ('failed','cancelled') then p_status else 'failed' end,
         provider_status = p_status, raw = coalesce(p_raw, raw)
   where provider = p_provider and provider_ref = p_provider_ref and status = 'pending';
end $$;
