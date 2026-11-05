-- booking_242: pikakassan vapaa rivi (kind=custom, product_id null, product_name = kuvaus)
-- Vanha product-muoto {product_id, quantity} säilyy. Uusi: {kind:'custom', description, quantity, unit_price, vat_rate}.
-- unit_price euroina (≥0, max 2 desimaalia); vaihtoehtoisesti unit_price_cents (≥0 kokonaisluku).
-- ALV vain booking.vat_rates.active. Vain pos-kanava (pikakassa); kylmälaite hylkää customin.
-- nothing_to_pay ennallaan: tilauksen total > 0.

alter table booking.order_items drop constraint if exists order_items_kind_check;
alter table booking.order_items
  add constraint order_items_kind_check
  check (kind = any (array['reservation'::text, 'product'::text, 'gift_card'::text, 'fee'::text, 'discount'::text, 'addon'::text, 'custom'::text]));

alter table booking.order_items drop constraint if exists order_items_custom_shape;
alter table booking.order_items
  add constraint order_items_custom_shape
  check (
    (kind <> 'custom')
    or (product_id is null and length(btrim(product_name)) >= 1 and length(btrim(product_name)) <= 200)
  );

create or replace function booking._counter_lines(p_items jsonb, p_channel text)
 returns table(product_id bigint, quantity integer, product_name text, unit_price numeric, vat_rate numeric, line_total numeric)
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
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
end $function$;

create or replace function booking._counter_checkout(p_channel text, p_items jsonb, p_locale text, p_email text, p_sale_ref text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_locale text := case when p_locale = 'en' then 'en' else 'fi' end;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_cust bigint; v_order bigint; v_no bigint; v_token uuid; v_total numeric := 0; v_lines jsonb := '[]'::jsonb; r record;
  v_kind text; v_name text;
begin
  if p_channel not in ('pikakassa', 'kylmalaite') then perform booking._err('invalid_param', 'Kanava'); end if;
  if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Sähköposti ei ole kelvollinen'); end if;
  if v_email is not null then
    select c.id into v_cust from booking.customers c
     where lower(c.email) = v_email and c.anonymized_at is null
     order by c.id desc limit 1;
    if v_cust is null then
      insert into booking.customers(name, email, language, marketing_consent, marketing_consent_source)
      values (v_email, v_email, v_locale, false, p_channel) returning id into v_cust;
    end if;
  end if;
  insert into booking.orders(customer_id, status, payment_status, total_gross, currency, source_channel, locale, created_by, sale_ref, customer_kind)
  values (v_cust, 'pending', 'unpaid', 0, 'EUR', p_channel, v_locale, auth.uid(), nullif(btrim(coalesce(p_sale_ref, '')), ''), 'private')
  returning id, order_no, public_token into v_order, v_no, v_token;
  for r in select * from booking._counter_lines(p_items, case when p_channel = 'pikakassa' then 'pos' else 'fridge' end) loop
    v_kind := case when r.product_id is null then 'custom' else 'product' end;
    if v_kind = 'custom' then
      v_name := r.product_name;
    elsif v_locale = 'en' then
      v_name := coalesce((select nullif(btrim(name_en), '') from kb.products where id = r.product_id), r.product_name);
    else
      v_name := r.product_name;
    end if;
    insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
    values (v_order, r.product_id, v_name, v_kind, r.quantity, r.unit_price, r.line_total, r.vat_rate,
            jsonb_build_object('source', p_channel, 'unit_price', r.unit_price, 'quantity', r.quantity,
              'custom', (v_kind = 'custom')));
    v_total := v_total + r.line_total;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'product_id', r.product_id, 'kind', v_kind, 'name', r.product_name,
      'quantity', r.quantity, 'unit_price', r.unit_price, 'vat_rate', r.vat_rate, 'line_total', r.line_total));
  end loop;
  if v_total <= 0 then perform booking._err('nothing_to_pay', 'Ei maksettavaa'); end if;
  update booking.orders set total_gross = v_total where id = v_order;
  return jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'public_token', v_token, 'total', v_total, 'currency', 'EUR',
    'source_channel', p_channel, 'sale_ref', nullif(btrim(coalesce(p_sale_ref, '')), ''), 'locale', v_locale, 'lines', v_lines);
end $function$;

-- admin_pos_checkout signature unchanged; body still delegates. Re-apply for clarity / grants consistency.
create or replace function booking.admin_pos_checkout(p_items jsonb, p_locale text default 'fi'::text, p_email text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  perform booking._require_permission('pos.use');
  return booking._counter_checkout('pikakassa', p_items, p_locale, p_email, null);
end $function$;
