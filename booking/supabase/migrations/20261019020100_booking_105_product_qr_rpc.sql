-- ============================================================
-- booking_105_product_qr_rpc: QR-linkki myy vain yhden tuotteen.
-- public_drinks_catalog ja public_drinks_checkout korvataan booking_81:n
-- uusimmasta rungosta. Muutos on vain kohde: cold_units → product_qr,
-- ja katalogi ilman kelvollista koodia ei palauta yhtään tuotetta.
-- Ei koske: mobilepay_payment_prepare (booking_82), admin_update_product_config
-- (booking_81), expire_counter_orders (booking_83), vismapay_payment_prepare,
-- email_outbox_claim, _counter_checkout, _counter_lines.
-- source_channel pysyy kylmalaite. Hinta tulee kb.productsista.
-- Rollback: rollbacks/20261019020100_booking_105_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

-- pos.use tai settings.edit. Ilman kumpaakaan sama virhe kuin pelkkä pos.use.
create or replace function booking._require_pos_operator()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if booking.has_permission('pos.use') or booking.has_permission('settings.edit') then
    return;
  end if;
  perform booking._require_permission('pos.use');
end $$;

create or replace function booking._product_qr_json(p_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', q.id, 'code', q.code, 'product_id', q.product_id,
    'name', p.name, 'name_en', p.name_en, 'price', p.price,
    'label', q.label, 'active', q.active,
    'path', booking._drinks_path('fi') || '?laite=' || q.code,
    'path_en', booking._drinks_path('en') || '?laite=' || q.code,
    'print_url', case when rtrim(coalesce(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', ''), '/') = ''
                      then booking._drinks_path('fi') || '?laite=' || q.code
                      else rtrim(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', '/') || booking._drinks_path('fi') || '?laite=' || q.code end)
    from booking.product_qr q
    join kb.products p on p.id = q.product_id
   where q.id = p_id
$$;

-- Pikakassan jäsenyys. Ei muuta hintaa, ALV:tä eikä fridge_sale-lippua.
create or replace function booking.admin_set_pos_product(p_product_id bigint, p_enabled boolean, p_sort integer default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare p record;
begin
  perform booking._require_pos_operator();
  if p_enabled is null then perform booking._err('invalid_param', 'Valinta puuttuu'); end if;
  if p_sort is not null and p_sort not between 0 and 10000 then perform booking._err('invalid_param', 'Järjestys ei ole kelvollinen'); end if;
  select kp.id, kp.category, kp.active, kp.price, (c.product_id is not null) as has_cfg
    into p
    from kb.products kp
    left join booking.product_config c on c.product_id = kp.id
   where kp.id = p_product_id;
  if not found or not p.has_cfg then perform booking._err('not_found', 'Tuotteella ei ole varauskonfiguraatiota'); end if;
  if p.category in ('gift_card', 'season_card') or not coalesce(p.active, false) or p.price is null then
    perform booking._err('not_counter_product', 'Tuotetta ei voi lisätä pikakassaan');
  end if;
  update booking.product_config set
    pos_enabled = p_enabled,
    pos_sort = coalesce(p_sort, pos_sort)
   where product_id = p_product_id;
  return jsonb_build_object('ok', true, 'product_id', p_product_id, 'pos_enabled', p_enabled,
    'pos_sort', (select pos_sort from booking.product_config where product_id = p_product_id));
end $$;

create or replace function booking.admin_list_product_qr()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_pos_operator();
  return coalesce((select jsonb_agg(booking._product_qr_json(q.id) order by q.id) from booking.product_qr q where q.active), '[]'::jsonb);
end $$;

create or replace function booking.admin_create_product_qr(p_product_id bigint, p_label text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  p record;
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
  v_code text;
  v_id bigint;
  i int;
begin
  perform booking._require_pos_operator();
  if v_label is not null and char_length(v_label) > 120 then perform booking._err('invalid_param', 'Tarra on liian pitkä'); end if;
  select kp.id, kp.category, kp.active, kp.price, c.age_restricted, (c.product_id is not null) as has_cfg
    into p
    from kb.products kp
    left join booking.product_config c on c.product_id = kp.id
   where kp.id = p_product_id;
  if not found or not p.has_cfg then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  if not coalesce(p.active, false) or p.price is null then perform booking._err('not_counter_product', 'Tuotetta ei voi myydä QR-linkillä'); end if;
  if p.category in ('gift_card', 'season_card') then perform booking._err('not_counter_product', 'Lahjakorttia tai kausikorttia ei myydä QR-linkillä'); end if;
  if coalesce(p.age_restricted, false) then perform booking._err('age_restricted', 'Ikärajallista tuotetta ei voi myydä QR-linkillä'); end if;
  perform booking._assert_fridge_product(p_product_id);
  update booking.product_config set fridge_sale = true where product_id = p_product_id;
  for i in 1..5 loop
    v_code := replace(gen_random_uuid()::text, '-', '');
    begin
      insert into booking.product_qr(code, product_id, label, active) values (v_code, p_product_id, v_label, true) returning id into v_id;
      exit;
    exception when unique_violation then
      v_id := null;
    end;
  end loop;
  if v_id is null then perform booking._err('invalid_param', 'QR-koodia ei saatu luotua'); end if;
  return booking._product_qr_json(v_id);
end $$;

create or replace function booking.admin_delete_product_qr(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_id bigint;
begin
  perform booking._require_pos_operator();
  delete from booking.product_qr where id = p_id returning id into v_id;
  if v_id is null then perform booking._err('not_found', 'QR-koodia ei löydy'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Julkinen katalogi: ilman kelvollista aktiivista koodia ei yhtään tuotetta.
-- Kelvollinen koodi palauttaa vain sen tuotteen nimen ja hinnan (ei ALV:tä, ei kuvausta, ei muita tuotteita).
create or replace function booking.public_drinks_catalog(p_device text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
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
end $$;

-- Kassalle vain tämän koodin tuote. Raja kirjataan ennen virhettä, kuten booking_81:ssä.
create or replace function booking.public_drinks_checkout(p_device text, p_items jsonb, p_email text default null, p_locale text default 'fi')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_ip text := coalesce(booking._client_ip(), 'unknown');
  v_code text := nullif(lower(btrim(coalesce(p_device, ''))), '');
  q booking.product_qr;
begin
  if not booking._rate_limit('drinks-pay:' || v_ip, 8, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_code is not null and not booking._rate_limit('drinks-dev:' || v_code, 30, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  begin
    if v_code is null or v_code !~ '^[a-f0-9]{32}$' then
      return jsonb_build_object('ok', false, 'code', 'unknown_device', 'message', 'QR-koodia ei löydy');
    end if;
    select * into q from booking.product_qr where code = v_code and active;
    if not found then
      return jsonb_build_object('ok', false, 'code', 'unknown_device', 'message', 'QR-koodia ei löydy');
    end if;
    if jsonb_typeof(p_items) = 'array' and exists (
      select 1 from jsonb_array_elements(p_items) e
      where coalesce(e ->> 'product_id', '') is distinct from q.product_id::text
    ) then
      return jsonb_build_object('ok', false, 'code', 'not_counter_product', 'message', 'QR-linkki myy vain tämän tuotteen');
    end if;
    return booking._counter_checkout('kylmalaite', p_items, p_locale, p_email, q.code);
  exception when others then
    declare d text; m text; s text;
    begin
      get stacked diagnostics d = pg_exception_detail, m = message_text, s = returned_sqlstate;
      if s = 'BK001' then return jsonb_build_object('ok', false, 'code', d, 'message', m); end if;
      raise;
    end;
  end;
end $$;

-- Vanhat kylmälaitefunktiot. public_drinks_* on jo korvattu, joten ne eivät enää viittaa tauluun.
drop function if exists booking.admin_upsert_cold_unit(bigint, text, text, boolean);
drop function if exists booking.admin_list_cold_units();
drop function if exists booking._cold_unit_json(bigint);

do $drop$
begin
  if to_regclass('booking.cold_units') is null then
    return;
  end if;
  if exists (select 1 from booking.cold_units) then
    raise exception 'booking.cold_units ei ole tyhjä; booking_105 ei siirrä rivejä';
  end if;
  drop table booking.cold_units;
end
$drop$;

revoke all on function booking._require_pos_operator() from public, anon, authenticated;
revoke all on function booking._product_qr_json(bigint) from public, anon, authenticated;
grant execute on function booking._require_pos_operator() to service_role;
grant execute on function booking._product_qr_json(bigint) to service_role;

revoke all on function booking.admin_set_pos_product(bigint, boolean, integer) from public, anon;
revoke all on function booking.admin_list_product_qr() from public, anon;
revoke all on function booking.admin_create_product_qr(bigint, text) from public, anon;
revoke all on function booking.admin_delete_product_qr(bigint) from public, anon;
grant execute on function booking.admin_set_pos_product(bigint, boolean, integer) to authenticated, service_role;
grant execute on function booking.admin_list_product_qr() to authenticated, service_role;
grant execute on function booking.admin_create_product_qr(bigint, text) to authenticated, service_role;
grant execute on function booking.admin_delete_product_qr(bigint) to authenticated, service_role;

revoke all on function booking.public_drinks_catalog(text) from public;
revoke all on function booking.public_drinks_checkout(text, jsonb, text, text) from public;
grant execute on function booking.public_drinks_catalog(text) to anon, authenticated, service_role;
grant execute on function booking.public_drinks_checkout(text, jsonb, text, text) to anon, authenticated, service_role;
