-- ROLLBACK booking_105_product_qr_rpc.
-- Palauttaa booking_81:n public_drinks_catalog-, public_drinks_checkout- ja kylmälaitefunktiot
-- sellaisina kuin ne ovat migraatiossa 20261019011100. Ei koske mobilepay_payment_preparea,
-- admin_update_product_configia, expire_counter_ordersia eikä email_outbox_claimia.
-- cold_units luodaan uudelleen booking_80:n määrittelyllä (tuotannossa taulu oli tyhjä).
-- Aja tämä ennen booking_104-rollbackia.

drop function if exists booking.admin_delete_product_qr(bigint);
drop function if exists booking.admin_create_product_qr(bigint, text);
drop function if exists booking.admin_list_product_qr();
drop function if exists booking.admin_set_pos_product(bigint, boolean, integer);
drop function if exists booking._product_qr_json(bigint);
drop function if exists booking._require_pos_operator();

create table if not exists booking.cold_units (
  id          bigint generated always as identity primary key,
  code        text not null unique check (code ~ '^[a-z0-9-]{8,48}$'),
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  location    text check (location is null or char_length(location) <= 120),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table booking.cold_units is 'Pukuhuoneen kylmälaitteet. code on arvauksen kestävä ja menee QR-osoitteeseen (?laite=).';
drop trigger if exists cold_units_updated on booking.cold_units;
create trigger cold_units_updated before update on booking.cold_units for each row execute function booking.set_updated_at();
alter table booking.cold_units enable row level security;
revoke all on booking.cold_units from public, anon, authenticated;
grant all on booking.cold_units to service_role;
do $audit$
begin
  if not exists (select 1 from pg_trigger where tgname = 'audit_trg' and tgrelid = 'booking.cold_units'::regclass) then
    perform booking._add_audit('booking.cold_units'::regclass);
  end if;
end
$audit$;

-- booking_81, rivit 260–361, sellaisenaan (create or replace, jotta korvaus onnistuu).
create or replace function booking._cold_unit_json(p_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id, 'code', c.code, 'name', c.name, 'location', c.location, 'active', c.active,
    'path', booking._drinks_path('fi') || '?laite=' || c.code,
    'path_en', booking._drinks_path('en') || '?laite=' || c.code,
    'print_url', case when rtrim(coalesce(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', ''), '/') = ''
                      then booking._drinks_path('fi') || '?laite=' || c.code
                      else rtrim(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', '/') || booking._drinks_path('fi') || '?laite=' || c.code end)
    from booking.cold_units c where c.id = p_id
$$;

create or replace function booking.admin_list_cold_units()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not booking.has_permission('catalog.edit') and not booking.has_permission('pos.use') then
    perform booking._require_permission('pos.use');
  end if;
  return coalesce((select jsonb_agg(booking._cold_unit_json(c.id) order by c.name, c.id) from booking.cold_units c), '[]'::jsonb);
end $$;

create or replace function booking.admin_upsert_cold_unit(p_id bigint default null, p_name text default null, p_location text default null, p_active boolean default true)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_name text := nullif(btrim(coalesce(p_name, '')), ''); v_loc text := nullif(btrim(coalesce(p_location, '')), '');
        v_slug text; v_code text; v_id bigint; i int;
begin
  perform booking._require_permission('catalog.edit');
  if v_name is null or char_length(v_name) > 80 then perform booking._err('invalid_param', 'Laitteen nimi puuttuu tai on liian pitkä'); end if;
  if v_loc is not null and char_length(v_loc) > 120 then perform booking._err('invalid_param', 'Sijainti on liian pitkä'); end if;
  if p_id is not null then
    update booking.cold_units set name = v_name, location = v_loc, active = coalesce(p_active, true) where id = p_id returning id into v_id;
    if v_id is null then perform booking._err('not_found', 'Laitetta ei löydy'); end if;
    return booking._cold_unit_json(v_id);
  end if;
  v_slug := trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g'));
  if v_slug is null or v_slug = '' then v_slug := 'laite'; end if;
  v_slug := left(v_slug, 24);
  for i in 1..5 loop
    v_code := v_slug || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    begin
      insert into booking.cold_units(code, name, location, active) values (v_code, v_name, v_loc, coalesce(p_active, true)) returning id into v_id;
      exit;
    exception when unique_violation then
      v_id := null;
    end;
  end loop;
  if v_id is null then perform booking._err('invalid_param', 'Laitteen koodia ei saatu luotua'); end if;
  return booking._cold_unit_json(v_id);
end $$;

create or replace function booking.public_drinks_catalog(p_device text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_ip text := coalesce(booking._client_ip(), 'unknown'); u booking.cold_units; v_dev jsonb := null; v_rows jsonb;
begin
  if not booking._rate_limit('drinks-cat:' || v_ip, 60, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if nullif(btrim(coalesce(p_device, '')), '') is not null then
    select * into u from booking.cold_units where code = btrim(p_device);
    if found then v_dev := jsonb_build_object('code', u.code, 'name', u.name, 'location', u.location, 'active', u.active);
    else v_dev := jsonb_build_object('unknown', true); end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'vat_rate', p.vat_rate)
           order by c.pos_sort, p.name), '[]'::jsonb)
    into v_rows
    from booking.product_config c
    join kb.products p on p.id = c.product_id
   where c.fridge_sale and not c.age_restricted and p.active and p.price is not null
     and p.category not in ('gift_card', 'season_card')
     and not booking._text_looks_like_alcohol(p.name) and not booking._text_looks_like_alcohol(coalesce(p.name_en, ''))
     and not booking._text_looks_like_alcohol(coalesce(p.description, '')) and not booking._text_looks_like_alcohol(coalesce(p.description_en, ''));
  return jsonb_build_object('ok', true, 'device', v_dev, 'products', v_rows,
    'paths', jsonb_build_object('fi', booking._drinks_path('fi'), 'en', booking._drinks_path('en')));
end $$;

create or replace function booking.public_drinks_checkout(p_device text, p_items jsonb, p_email text default null, p_locale text default 'fi')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_ip text := coalesce(booking._client_ip(), 'unknown'); v_code text := nullif(btrim(coalesce(p_device, '')), ''); u booking.cold_units;
begin
  -- Raja kirjataan ennen virheenkäsittelyä. Sisempi poikkeuslohko peruu vain kassan,
  -- joten hylätty kutsu (esim. price_locked) kuluttaa silti drinks-pay / drinks-dev -kiintiön.
  if not booking._rate_limit('drinks-pay:' || v_ip, 8, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_code is not null and not booking._rate_limit('drinks-dev:' || v_code, 30, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  begin
    if v_code is null then return jsonb_build_object('ok', false, 'code', 'unknown_device', 'message', 'Kylmälaitetta ei löydy'); end if;
    select * into u from booking.cold_units where code = v_code and active;
    if not found then return jsonb_build_object('ok', false, 'code', 'unknown_device', 'message', 'Kylmälaitetta ei löydy'); end if;
    return booking._counter_checkout('kylmalaite', p_items, p_locale, p_email, u.code);
  exception when others then
    declare d text; m text; s text;
    begin
      get stacked diagnostics d = pg_exception_detail, m = message_text, s = returned_sqlstate;
      if s = 'BK001' then return jsonb_build_object('ok', false, 'code', d, 'message', m); end if;
      raise;
    end;
  end;
end $$;

revoke all on function booking._cold_unit_json(bigint) from public, anon, authenticated;
grant execute on function booking._cold_unit_json(bigint) to service_role;
revoke all on function booking.admin_list_cold_units() from public, anon;
revoke all on function booking.admin_upsert_cold_unit(bigint, text, text, boolean) from public, anon;
grant execute on function booking.admin_list_cold_units() to authenticated, service_role;
grant execute on function booking.admin_upsert_cold_unit(bigint, text, text, boolean) to authenticated, service_role;
revoke all on function booking.public_drinks_catalog(text) from public;
revoke all on function booking.public_drinks_checkout(text, jsonb, text, text) from public;
grant execute on function booking.public_drinks_catalog(text) to anon, authenticated, service_role;
grant execute on function booking.public_drinks_checkout(text, jsonb, text, text) to anon, authenticated, service_role;
