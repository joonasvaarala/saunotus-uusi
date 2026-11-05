CREATE OR REPLACE FUNCTION booking._counter_lines(p_items jsonb, p_channel text)
 RETURNS TABLE(product_id bigint, quantity integer, product_name text, unit_price numeric, vat_rate numeric, line_total numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$
