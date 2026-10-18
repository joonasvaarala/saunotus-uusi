-- ============================================================
-- booking_81_pos_fridge_rpc: pikakassan ja kylmälaitteen tilaukset samaan tilaus-/kuittipolkuun.
-- Lähde source_channel pikakassa | kylmalaite. Hinta ja ALV aina kb.productsista (asiakas ei lähetä hintaa).
-- Lahjakortti ja kausikortti eivät ole kassarivejä (kortti syntyy omassa myynnissä).
-- Kylmälaite: vain fridge_sale, ei ikärajallista eikä alkoholin näköistä nimeä, aktiivinen laite, nopeusraja.
-- Visma Pay: vismapay_payment_prepare vain service_role. off ja live eivät luo maksua; dry_run luo pending-maksun eikä merkitse maksetuksi.
-- Rollback: rollbacks/20261018211100_booking_81_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

-- ---------- tuoteasetukset: pikakassa / kylmälaite (catalog.edit) ----------
create or replace function booking.admin_update_product_config(p_product_id bigint, p_patch jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $fn$
declare
  allowed text[] := array['bookable','shop_visible','sort_order','min_persons','max_persons','notes',
                          'lifecycle','resource_class','closure_group','duration_minutes','required_skill',
                          'therapists_needed','therapist_offset_min','therapist_minutes',
                          'pos_enabled','pos_sort','fridge_sale','age_restricted'];
  k text; c booking.product_config; v_age boolean; v_fridge boolean; v_sort int;
begin
  perform booking._require_permission('catalog.edit');
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then perform booking._err('invalid_param', 'p_patch'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
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
    pos_enabled = case when p_patch ? 'pos_enabled' then (p_patch ->> 'pos_enabled')::boolean else pos_enabled end,
    pos_sort = case when p_patch ? 'pos_sort' then (p_patch ->> 'pos_sort')::int else pos_sort end,
    fridge_sale = v_fridge,
    age_restricted = v_age
   where product_id = p_product_id;
  return jsonb_build_object('ok', true);
end $fn$;

-- ---------- ostoskorin rivit: vain product_id + quantity, hinta palvelimelta ----------
create function booking._counter_lines(p_items jsonb, p_channel text)
returns table(product_id bigint, quantity integer, product_name text, unit_price numeric, vat_rate numeric, line_total numeric)
language plpgsql stable security definer set search_path = '' as $$
declare
  e jsonb; k text; v_id bigint; v_qty int; v_acc jsonb := '{}'::jsonb; v_key text; v_sum int; r record; pr record; v_name text; v_line numeric;
begin
  if p_channel not in ('pos', 'fridge') then perform booking._err('invalid_param', 'Kanava'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then perform booking._err('invalid_items', 'Ostoskori puuttuu'); end if;
  if jsonb_array_length(p_items) < 1 then perform booking._err('nothing_to_pay', 'Ostoskori on tyhjä'); end if;
  if jsonb_array_length(p_items) > 12 then perform booking._err('invalid_items', 'Enintään 12 riviä'); end if;
  for e in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_items', 'Rivi ei ole kelvollinen'); end if;
    for k in select jsonb_object_keys(e) loop
      if k not in ('product_id', 'quantity') then perform booking._err('price_locked', 'Hintaa tai verokantaa ei voi antaa ostoskorissa'); end if;
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
  end loop;
  if (select count(*) from jsonb_object_keys(v_acc)) > 12 then perform booking._err('invalid_items', 'Enintään 12 riviä'); end if;
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
end $$;

create function booking._counter_checkout(p_channel text, p_items jsonb, p_locale text, p_email text, p_sale_ref text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_locale text := case when p_locale = 'en' then 'en' else 'fi' end;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_cust bigint; v_order bigint; v_no bigint; v_token uuid; v_total numeric := 0; v_lines jsonb := '[]'::jsonb; r record;
begin
  if p_channel not in ('pikakassa', 'kylmalaite') then perform booking._err('invalid_param', 'Kanava'); end if;
  if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Sähköposti ei ole kelvollinen'); end if;
  if v_email is not null then
    insert into booking.customers(name, email, language, marketing_consent, marketing_consent_source)
    values (v_email, v_email, v_locale, false, p_channel) returning id into v_cust;
  end if;
  insert into booking.orders(customer_id, status, payment_status, total_gross, currency, source_channel, locale, created_by, sale_ref, customer_kind)
  values (v_cust, 'pending', 'unpaid', 0, 'EUR', p_channel, v_locale, auth.uid(), nullif(btrim(coalesce(p_sale_ref, '')), ''), 'private')
  returning id, order_no, public_token into v_order, v_no, v_token;
  for r in select * from booking._counter_lines(p_items, case when p_channel = 'pikakassa' then 'pos' else 'fridge' end) loop
    insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
    values (v_order, r.product_id, case when v_locale = 'en' then coalesce((select nullif(btrim(name_en), '') from kb.products where id = r.product_id), r.product_name) else r.product_name end,
            'product', r.quantity, r.unit_price, r.line_total, r.vat_rate,
            jsonb_build_object('source', p_channel, 'unit_price', r.unit_price, 'quantity', r.quantity));
    v_total := v_total + r.line_total;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('product_id', r.product_id, 'name', r.product_name, 'quantity', r.quantity, 'unit_price', r.unit_price, 'vat_rate', r.vat_rate, 'line_total', r.line_total));
  end loop;
  if v_total <= 0 then perform booking._err('nothing_to_pay', 'Ei maksettavaa'); end if;
  update booking.orders set total_gross = v_total where id = v_order;
  return jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'public_token', v_token, 'total', v_total, 'currency', 'EUR',
    'source_channel', p_channel, 'sale_ref', nullif(btrim(coalesce(p_sale_ref, '')), ''), 'locale', v_locale, 'lines', v_lines);
end $$;

create function booking._counter_expire(p_order_id bigint)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found or o.status <> 'pending' then return; end if;
  if o.created_at >= now() - interval '30 minutes' then return; end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.provider <> 'manual'
                and (p.link_expires_at is null or p.link_expires_at > now())) then return; end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'maksamaton kassatilaus vanheni')
   where order_id = o.id and status = 'pending';
  update booking.orders set status = 'expired' where id = o.id;
  perform booking._refresh_order_payment(o.id);
end $$;

-- ---------- pikakassa (pos.use) ----------
create function booking.admin_pos_catalog()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
end $$;

create function booking.admin_pos_tenders()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_base text := rtrim(coalesce(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', ''), '/');
begin
  perform booking._require_permission('pos.use');
  return jsonb_build_object(
    'mobilepay_mode', booking._mobilepay_mode(),
    'vismapay_mode', coalesce((select mode from booking.integration_config where key = 'vismapay'), 'off'),
    'site_base_url', v_base,
    'drinks_path', booking._drinks_path('fi'),
    'drinks_path_en', booking._drinks_path('en'),
    'tenders', coalesce((select jsonb_agg(jsonb_build_object(
        'code', t.code, 'handler', t.handler, 'channels', to_jsonb(t.channels), 'active', t.active,
        'sort_order', t.sort_order, 'unavailable_reason', t.unavailable_reason) order by t.sort_order, t.code)
      from booking.pos_tenders t), '[]'::jsonb));
end $$;

create function booking.admin_pos_checkout(p_items jsonb, p_locale text default 'fi', p_email text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  perform booking._require_permission('pos.use');
  return booking._counter_checkout('pikakassa', p_items, p_locale, p_email, null);
end $$;

create function booking.admin_pos_status(p_order_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; v_lines jsonb; v_rec jsonb;
begin
  perform booking._require_permission('pos.use');
  if p_order_id is null then perform booking._err('invalid_param', 'Tilaus puuttuu'); end if;
  perform booking._counter_expire(p_order_id);
  select * into o from booking.orders where id = p_order_id and source_channel = 'pikakassa';
  if not found then perform booking._err('not_found', 'Kassatilausta ei löydy'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate) order by i.id), '[]'::jsonb)
    into v_lines from booking.order_items i where i.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'token', x.public_token, 'total', x.total_gross, 'kind', x.kind) order by x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  return jsonb_build_object('ok', true, 'order_id', o.id, 'order_no', o.order_no, 'public_token', o.public_token,
    'status', o.status, 'payment_status', o.payment_status, 'total', o.total_gross, 'source_channel', o.source_channel,
    'lines', v_lines, 'receipts', v_rec);
end $$;

create function booking.admin_pos_void(p_order_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders;
begin
  perform booking._require_permission('pos.use');
  select * into o from booking.orders where id = p_order_id and source_channel = 'pikakassa' for update;
  if not found then perform booking._err('not_found', 'Kassatilausta ei löydy'); end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid', 'partially_refunded', 'refunded'))
     or o.payment_status in ('paid', 'partially_paid', 'partially_refunded', 'refunded') then
    perform booking._err('already_paid', 'Maksettua tilausta ei voi perua kassalla');
  end if;
  if o.status in ('cancelled', 'expired') then return jsonb_build_object('ok', true, 'already', true, 'status', o.status); end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'pikakassa perui maksamattoman tilauksen')
   where order_id = o.id and status = 'pending';
  update booking.orders set status = 'cancelled' where id = o.id;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('ok', true, 'order_id', o.id, 'status', 'cancelled');
end $$;

-- ---------- kylmälaitteet (catalog.edit kirjoittaa, pos.use lukee tulostusta varten) ----------
create function booking._cold_unit_json(p_id bigint)
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

create function booking.admin_list_cold_units()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not booking.has_permission('catalog.edit') and not booking.has_permission('pos.use') then
    perform booking._require_permission('pos.use');
  end if;
  return coalesce((select jsonb_agg(booking._cold_unit_json(c.id) order by c.name, c.id) from booking.cold_units c), '[]'::jsonb);
end $$;

create function booking.admin_upsert_cold_unit(p_id bigint default null, p_name text default null, p_location text default null, p_active boolean default true)
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

-- ---------- julkinen kylmälaite ----------
create function booking.public_drinks_catalog(p_device text default null)
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

create function booking.public_drinks_checkout(p_device text, p_items jsonb, p_email text default null, p_locale text default 'fi')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_ip text := coalesce(booking._client_ip(), 'unknown'); v_code text := nullif(btrim(coalesce(p_device, '')), ''); u booking.cold_units;
begin
  if not booking._rate_limit('drinks-pay:' || v_ip, 8, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_code is not null and not booking._rate_limit('drinks-dev:' || v_code, 30, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_code is null then return jsonb_build_object('ok', false, 'code', 'unknown_device', 'message', 'Kylmälaitetta ei löydy'); end if;
  select * into u from booking.cold_units where code = v_code and active;
  if not found then return jsonb_build_object('ok', false, 'code', 'unknown_device', 'message', 'Kylmälaitetta ei löydy'); end if;
  return booking._counter_checkout('kylmalaite', p_items, p_locale, p_email, u.code);
exception when others then
  declare d text; m text; s text;
  begin
    get stacked diagnostics d = pg_exception_detail, m = message_text, s = sqlstate;
    if s = 'BK001' then return jsonb_build_object('ok', false, 'code', d, 'message', m); end if;
    raise;
  end;
end $$;

create function booking.public_drinks_status(p_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; v_id bigint; v_lines jsonb; v_rec jsonb;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
  if not booking._rate_limit('drinks-stat:' || p_token::text, 60, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select id into v_id from booking.orders where public_token = p_token and source_channel = 'kylmalaite';
  if v_id is null then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
  perform booking._counter_expire(v_id);
  select * into o from booking.orders where id = v_id;
  select coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate) order by i.id), '[]'::jsonb)
    into v_lines from booking.order_items i where i.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'token', x.public_token, 'total', x.total_gross) order by x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status,
    'total', o.total_gross, 'currency', o.currency, 'sale_ref', o.sale_ref, 'lines', v_lines, 'receipts', v_rec);
end $$;

-- ---------- Visma Pay dry_run (ei tunnuksia, ei HTTP-kutsua, ei maksetuksi merkintää) ----------
create function booking.vismapay_payment_prepare(p_order_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_mode text := coalesce((select mode from booking.integration_config where key = 'vismapay'), 'off');
  o booking.orders; v_tot numeric; v_unpaid numeric; pay booking.payments;
begin
  if p_order_token is null then return jsonb_build_object('ok', false, 'code', 'invalid_param', 'message', 'order_token puuttuu'); end if;
  if not booking._rate_limit('vpstart:' || p_order_token::text, 12, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_mode = 'live' then
    return jsonb_build_object('ok', false, 'code', 'vismapay_live_not_implemented', 'mode', v_mode, 'message', 'Visma Payn tuotantomaksu ei ole vielä toteutettu');
  end if;
  if v_mode <> 'dry_run' then
    return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;
  select * into o from booking.orders where public_token = p_order_token for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or o.status not in ('pending', 'confirmed') or o.currency <> 'EUR' then
    return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa');
  end if;
  select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  v_tot := least(v_tot, v_unpaid);
  if v_tot <= 0.004 then
    if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then
      return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Tilaus on jo maksettu');
    end if;
    return jsonb_build_object('ok', false, 'code', 'nothing_to_pay', 'message', 'Ei maksettavaa');
  end if;
  select * into pay from booking.payments
   where order_id = o.id and status = 'pending' and provider = 'visma_pay' and amount = v_tot and provider_ref like 'dryrun-%'
   order by id desc limit 1 for update;
  if not found then
    insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
    values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, now() + interval '30 minutes', 'Visma Pay dry_run, ei veloitusta')
    returning * into pay;
    update booking.payments set provider_ref = 'dryrun-' || pay.id, provider_status = 'dry_run' where id = pay.id returning * into pay;
    insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
    update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
     where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
       and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
    perform booking._refresh_order_payment(o.id);
  end if;
  return jsonb_build_object('ok', true, 'mode', 'dry_run', 'dry_run', true, 'implemented', false,
    'payment_id', pay.id, 'provider_ref', pay.provider_ref, 'amount', pay.amount, 'currency', pay.currency,
    'order_no', o.order_no, 'order_token', o.public_token, 'status', pay.status,
    'message', 'Testitila: maksua ei veloiteta eikä kuittia synny.');
end $$;

-- ---------- oikeudet ----------
revoke all on function booking._counter_lines(jsonb, text) from public, anon, authenticated;
revoke all on function booking._counter_checkout(text, jsonb, text, text, text) from public, anon, authenticated;
revoke all on function booking._counter_expire(bigint) from public, anon, authenticated;
revoke all on function booking._cold_unit_json(bigint) from public, anon, authenticated;
revoke all on function booking.vismapay_payment_prepare(uuid) from public, anon, authenticated;
grant execute on function booking._counter_lines(jsonb, text) to service_role;
grant execute on function booking._counter_checkout(text, jsonb, text, text, text) to service_role;
grant execute on function booking._counter_expire(bigint) to service_role;
grant execute on function booking._cold_unit_json(bigint) to service_role;
grant execute on function booking.vismapay_payment_prepare(uuid) to service_role;

revoke all on function booking.admin_pos_catalog() from public, anon;
revoke all on function booking.admin_pos_tenders() from public, anon;
revoke all on function booking.admin_pos_checkout(jsonb, text, text) from public, anon;
revoke all on function booking.admin_pos_status(bigint) from public, anon;
revoke all on function booking.admin_pos_void(bigint) from public, anon;
revoke all on function booking.admin_list_cold_units() from public, anon;
revoke all on function booking.admin_upsert_cold_unit(bigint, text, text, boolean) from public, anon;
grant execute on function booking.admin_pos_catalog() to authenticated, service_role;
grant execute on function booking.admin_pos_tenders() to authenticated, service_role;
grant execute on function booking.admin_pos_checkout(jsonb, text, text) to authenticated, service_role;
grant execute on function booking.admin_pos_status(bigint) to authenticated, service_role;
grant execute on function booking.admin_pos_void(bigint) to authenticated, service_role;
grant execute on function booking.admin_list_cold_units() to authenticated, service_role;
grant execute on function booking.admin_upsert_cold_unit(bigint, text, text, boolean) to authenticated, service_role;

revoke all on function booking.public_drinks_catalog(text) from public;
revoke all on function booking.public_drinks_checkout(text, jsonb, text, text) from public;
revoke all on function booking.public_drinks_status(uuid) from public;
grant execute on function booking.public_drinks_catalog(text) to anon, authenticated, service_role;
grant execute on function booking.public_drinks_checkout(text, jsonb, text, text) to anon, authenticated, service_role;
grant execute on function booking.public_drinks_status(uuid) to anon, authenticated, service_role;
