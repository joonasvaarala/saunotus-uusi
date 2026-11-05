CREATE OR REPLACE FUNCTION booking._counter_checkout(p_channel text, p_items jsonb, p_locale text, p_email text, p_sale_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_locale text := case when p_locale = 'en' then 'en' else 'fi' end;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_cust bigint; v_order bigint; v_no bigint; v_token uuid; v_total numeric := 0; v_lines jsonb := '[]'::jsonb; r record;
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
end $function$
