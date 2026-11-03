-- PROD-määrittely ennen booking_239:ää (md5 sama DEV/PROD, 3.11.2026)
CREATE OR REPLACE FUNCTION booking._apply_admin_discount(p_order_id bigint, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code);
  v_card booking.annual_cards; d booking.discount_codes; v_err text;
  r booking.reservations; v_day date; v_lines jsonb; v_calc jsonb; s jsonb;
  v_disc numeric := 0; v_total numeric; pr record; v_inserted boolean := false;
begin
  perform booking._require_permission('bookings.manage');
  select total_gross into v_total from booking.orders where id = p_order_id;
  if v_code is null or v_code = '' then
    return jsonb_build_object('total', v_total, 'discount', 0, 'payment_inserted', false);
  end if;
  if char_length(v_code) > 40 then perform booking._err('invalid_code', booking._code_msg('invalid_code')); end if;
  select * into r from booking.reservations where order_id = p_order_id order by id limit 1;
  if r.id is null then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  v_day := (r.starts_at at time zone booking._tz())::date;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code for update; end if;
  if v_card.id is null and d.id is null then perform booking._err('invalid_code', booking._code_msg('invalid_code')); end if;

  if v_card.id is not null or coalesce(d.is_annual_card_code, false) then
    if r.persons is distinct from booking._annual_max_persons() then perform booking._err('annual_card_persons', booking._code_msg('annual_card_persons')); end if;
    if exists (select 1 from booking.order_items oi where oi.order_id = p_order_id and oi.kind = 'addon' and oi.quantity > 0) then
      perform booking._err('annual_card_no_addons', booking._code_msg('annual_card_no_addons'));
    end if;
    v_err := booking._annual_rule_check(r.rule_id, v_day, v_card, d);
    if v_err is not null then perform booking._err(v_err, booking._code_msg(v_err)); end if;
    if v_card.id is not null and (select customer_id from booking.orders where id = p_order_id) is distinct from v_card.customer_id then
      perform booking._err('annual_card_customer_mismatch', booking._code_msg('annual_card_customer_mismatch'));
    end if;
    select * into pr from booking._rule_price(r.rule_id, r.persons);
    update booking.order_items set line_total_gross = 0, unit_price_gross = 0,
           discount_amount = case when v_card.id is not null then pr.total else line_total_gross end,
           discount_code_id = d.id
     where order_id = p_order_id and kind = 'reservation';
    update booking.order_items set line_total_gross = 0, discount_amount = line_total_gross where order_id = p_order_id and kind = 'addon';
    update booking.orders set total_gross = 0, discount_code_id = d.id, payment_status = 'paid' where id = p_order_id;
    if d.id is not null then update booking.discount_codes set used_count = used_count + 1 where id = d.id; end if;
    if v_card.id is not null then update booking.reservations set annual_card_id = v_card.id where id = r.id; end if;
    update booking.payments set status = 'cancelled' where order_id = p_order_id and status = 'pending';
    insert into booking.payments(order_id, method, provider, status, amount, paid_at, note, created_by)
    values (p_order_id, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikortti / koodi ' || v_code, auth.uid());
    return jsonb_build_object('total', 0, 'discount', coalesce(pr.total, v_total), 'discount_code', v_code,
                              'code_type', case when v_card.id is not null then 'annual_card' else 'annual_code' end,
                              'payment_inserted', true);
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then perform booking._err(v_err, booking._code_msg(v_err)); end if;
  select coalesce(jsonb_agg(jsonb_build_object('key', oi.id, 'product_id', oi.product_id, 'kind', oi.kind, 'gross', oi.line_total_gross) order by oi.id), '[]'::jsonb)
    into v_lines from booking.order_items oi where oi.order_id = p_order_id;
  v_calc := booking._discount_split(d, v_lines);
  v_disc := (v_calc ->> 'discount')::numeric;
  if v_disc <= 0 then perform booking._err('code_not_applicable', booking._code_msg('code_not_applicable')); end if;
  for s in select x from jsonb_array_elements(v_calc -> 'shares') x loop
    update booking.order_items set discount_code_id = d.id, discount_amount = coalesce(discount_amount, 0) + (s ->> 'amount')::numeric,
           line_total_gross = line_total_gross - (s ->> 'amount')::numeric
     where id = (s ->> 'key')::bigint and order_id = p_order_id;
  end loop;
  update booking.orders set discount_code_id = d.id,
         total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = p_order_id), 0)
   where id = p_order_id returning total_gross into v_total;
  update booking.discount_codes set used_count = used_count + 1 where id = d.id;
  if v_total <= 0 then
    update booking.payments set status = 'cancelled' where order_id = p_order_id and status = 'pending';
    -- booking_217: 100 % alennus ei kirjaa 0 €:n paid-maksua (se jäi raporttiin kuittittomana, kun tilauksen summa myöhemmin muuttui).
    update booking.orders set payment_status = 'paid' where id = p_order_id;
    v_inserted := true;
  end if;
  return jsonb_build_object('total', v_total, 'discount', v_disc, 'discount_code', d.code, 'code_type', 'discount', 'payment_inserted', v_inserted);
end $function$;
