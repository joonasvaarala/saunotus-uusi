-- booking_171 ROLLBACK (migraatio 20261024210635_booking_171_quiet_extra_person.sql).
-- Palauttaa _quiet_apply- ja public_preview_code-funktiot tuotannon määrittelyiksi täsmälleen (md5 alla) ja poistaa _quiet_base-funktion.
-- Jo tehdyt varaukset ennallaan (price_breakdown.quiet.discount_base jää riveille). Vartija: md5 on oltava booking_171:n tai tuotannon.
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking._quiet_apply(bigint,jsonb)'::regprocedure));
  if v not in ('92d6a01979c46e9f12b5edb2f9dacd2a', 'dd2139dc889d981e6623ef1fceaeec3d') then ok := false; msg := msg || ' _quiet_apply=' || v; end if;
  v := md5(pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure));
  if v not in ('4816fbaf5149e501a128aed40f2bf505', 'e8fe514b4ec9db4043d388e5547f94ad') then ok := false; msg := msg || ' public_preview_code=' || v; end if;
  if not ok then raise exception 'booking_171 rollback: funktioiden md5 ei ole booking_171:n eikä tuotannon (%); mitään ei muutettu', msg; end if;
end $g$;

-- booking._quiet_apply(bigint,jsonb) (tuotanto, md5 92d6a01979c46e9f12b5edb2f9dacd2a)
CREATE OR REPLACE FUNCTION booking._quiet_apply(p_order_id bigint, p_quiet jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_item booking.order_items; v_amt numeric;
begin
  if p_quiet is null or p_order_id is null then return 0; end if;
  select * into v_item from booking.order_items where order_id = p_order_id and kind = 'reservation' order by id limit 1 for update;
  if v_item.id is null or coalesce(v_item.line_total_gross, 0) <= 0 then return 0; end if;
  v_amt := least(v_item.line_total_gross, round(v_item.line_total_gross * (p_quiet ->> 'percent')::numeric / 100, 2));
  if v_amt <= 0 then return 0; end if;
  update booking.order_items
     set line_total_gross = line_total_gross - v_amt, discount_amount = v_amt,
         price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_build_object('quiet', jsonb_build_object(
           'rule_id', (p_quiet ->> 'rule_id')::bigint, 'percent', (p_quiet ->> 'percent')::numeric, 'base', v_item.line_total_gross,
           'amount', v_amt, 'hours_left', (p_quiet ->> 'hours_left')::numeric, 'source', 'quiet'))
   where id = v_item.id;
  update booking.orders set total_gross = total_gross - v_amt where id = p_order_id;
  return v_amt;
end $function$
;

-- booking.public_preview_code(text,bigint,date,integer,jsonb,text,text) (tuotanto, md5 4816fbaf5149e501a128aed40f2bf505)
CREATE OR REPLACE FUNCTION booking.public_preview_code(p_code text, p_rule_id bigint, p_date date, p_persons integer, p_addons jsonb DEFAULT NULL::jsonb, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip(); v_card booking.annual_cards; d booking.discount_codes;
  r booking.schedule_rules; pr record; v_lines jsonb := '[]'::jsonb; v_sub numeric; v_err text; v_calc jsonb; e jsonb; a booking.addons; v_q int;
  v_quiet jsonb; v_qamt numeric := 0;  -- booking_162
begin
  if v_code = '' or char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if r.id is null or p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse vuoro ja henkilömäärä');
  end if;
  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_lines := jsonb_build_array(jsonb_build_object('key', 0, 'product_id', r.product_id, 'kind', 'reservation', 'gross', pr.total));
  v_sub := pr.total;
  if p_addons is not null and jsonb_typeof(p_addons) = 'array' then
    for e in select x from jsonb_array_elements(p_addons) x limit 20 loop
      -- booking_166: saunarituaali-elementti mukaan esikatseluun samana rivinä kuin varauksessa (tuote + palvelimen hinta)
      if jsonb_typeof(e) = 'object' and e ? 'ritual_start' and coalesce(e ->> 'quantity', '') ~ '^\d{1,3}$' and (e ->> 'quantity')::int > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', -1, 'product_id', (booking._ritual_addon_cfg() ->> 'product_id')::bigint, 'kind', 'reservation',
                     'gross', round(booking._treatment_price((booking._ritual_addon_cfg() ->> 'product_id')::bigint, least((e ->> 'quantity')::int, p_persons)), 2)));
        v_sub := v_sub + round(booking._treatment_price((booking._ritual_addon_cfg() ->> 'product_id')::bigint, least((e ->> 'quantity')::int, p_persons)), 2);
        continue;
      end if;
      continue when jsonb_typeof(e) <> 'object' or coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or coalesce(e ->> 'id', '') !~ '^\d{1,18}$';
      v_q := (e ->> 'quantity')::int; continue when v_q = 0;
      select * into a from booking.addons where id = (e ->> 'id')::bigint and active;
      continue when a.id is null;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', a.id, 'product_id', null, 'kind', 'addon', 'gross', a.price_gross * v_q));
      v_sub := v_sub + a.price_gross * v_q;
    end loop;
  end if;

  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti + yhteystiedot, jotka eivät ole omistajan → sama vastaus kuin tuntemattomalla koodilla
  if v_card.id is not null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
     and not booking._annual_card_owner_ok(v_card, p_email, p_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  if v_card.id is not null or d.is_annual_card_code then
    v_err := booking._annual_rule_check(p_rule_id, p_date, v_card, d);
    if v_err is null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
       and booking._annual_limit(v_card.customer_id, p_email, p_phone) then v_err := 'annual_card_limit'; end if;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    select * into pr from booking._rule_price(p_rule_id, booking._annual_max_persons());
    return jsonb_build_object('ok', true, 'type', case when v_card.id is not null then 'annual_card' else 'annual_code' end, 'code', v_code,
      'persons', booking._annual_max_persons(), 'addons_allowed', false, 'subtotal', pr.total, 'discount', pr.total, 'total', 0,
      'valid_to', coalesce(v_card.valid_to, d.valid_to));
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  v_calc := booking._discount_split(d, v_lines);
  if (v_calc ->> 'discount')::numeric <= 0 then
    return jsonb_build_object('ok', false, 'code', 'code_not_applicable', 'message', booking._code_msg('code_not_applicable'));
  end if;
  -- booking_162: hiljaisen ajan ale ei pinoudu koodin kanssa; koodi voittaa vain jos se on suurempi etu
  v_quiet := booking._quiet_for_rule(p_rule_id, p_date);
  if v_quiet is not null then v_qamt := least(pr.total, round(pr.total * (v_quiet ->> 'percent')::numeric / 100, 2)); end if;
  if v_qamt > 0 and v_qamt >= (v_calc ->> 'discount')::numeric then
    return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
      'discount', v_qamt, 'total', v_sub - v_qamt, 'addons_allowed', true, 'discount_source', 'quiet', 'code_applied', false,
      'code_discount', (v_calc ->> 'discount')::numeric, 'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt));
  end if;
  return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
    'discount', (v_calc ->> 'discount')::numeric, 'total', v_sub - (v_calc ->> 'discount')::numeric, 'addons_allowed', true)
    || case when v_qamt > 0 then jsonb_build_object('discount_source', 'code', 'code_applied', true,
         'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt)) else '{}'::jsonb end;
end $function$
;

drop function if exists booking._quiet_base(jsonb, numeric);

do $v$ begin
  if md5(pg_get_functiondef('booking._quiet_apply(bigint,jsonb)'::regprocedure)) <> '92d6a01979c46e9f12b5edb2f9dacd2a'
     or md5(pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure)) <> '4816fbaf5149e501a128aed40f2bf505' then
    raise exception 'booking_171 rollback: palautettu md5 ei vastaa tuotantoa';
  end if;
end $v$;
