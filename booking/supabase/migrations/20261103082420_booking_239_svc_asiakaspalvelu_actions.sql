-- booking_239: Asiakaspalvelu-botin svc_*-funktiot hallinnan toimintoihin (Joonas t1294u 3.11.2026)
-- Uudet: svc_create_discount_code, svc_create_booking, svc_cancel_reservation, svc_add_order_note, svc_update_customer
-- Refaktorointi (käytös ennallaan): admin_save_discount_code, _apply_admin_discount, _apply_admin_gift, admin_update_customer
--   → oikeustarkistus + uusi ydin (_save_discount_code_core, _apply_discount_core, _apply_gift_core, _update_customer_core).
-- Vanhat määrittelyt: prod_before/. Ei maksupalvelukutsuja eikä hyvityksiä.

CREATE OR REPLACE FUNCTION booking._save_discount_code_core(p_id bigint, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  d booking.discount_codes; v_annual boolean := coalesce((p_data ->> 'is_annual_card_code')::boolean, false);
  v_code text := booking._norm_code(p_data ->> 'code'); v_kind text := coalesce(p_data ->> 'kind', 'percent');
  v_value numeric; v_usage text := coalesce(p_data ->> 'usage_type', 'single'); v_scope text := coalesce(p_data ->> 'target_scope', 'order');
  v_max int; v_pids bigint[]; v_from date; v_to date; v_desc text := nullif(btrim(coalesce(p_data ->> 'description', '')), '');
begin
  -- booking_239: oikeustarkistukset kutsujassa (admin_save_discount_code / svc_create_discount_code)
  if p_id is not null then
    select * into d from booking.discount_codes where id = p_id for update;
    if d.id is null then perform booking._err('not_found', 'Koodia ei löydy'); end if;
  end if;
  if v_code = '' then v_code := booking._generate_discount_code(); end if;
  if v_code !~ '^[A-Z0-9-]{3,40}$' then perform booking._err('invalid_code', 'Koodissa saa olla 3–40 merkkiä: kirjaimia A–Z, numeroita ja väliviivoja'); end if;
  if v_kind not in ('percent', 'fixed') then perform booking._err('invalid_kind', 'Valitse prosentti tai euromäärä'); end if;
  if coalesce(p_data ->> 'value', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_value', 'Tarkista alennuksen määrä'); end if;
  v_value := (p_data ->> 'value')::numeric;
  if v_value <= 0 or (v_kind = 'percent' and v_value > 100) then perform booking._err('invalid_value', 'Prosentti 0–100, euromäärä yli 0'); end if;
  if v_usage not in ('single', 'multi', 'permanent') then perform booking._err('invalid_usage', 'Tarkista käyttökerrat'); end if;
  if v_usage = 'multi' then
    if coalesce(p_data ->> 'max_uses', '') !~ '^\d{1,6}$' or (p_data ->> 'max_uses')::int < 2 then perform booking._err('invalid_max_uses', 'Käyttökertoja vähintään 2'); end if;
    v_max := (p_data ->> 'max_uses')::int;
  end if;
  if v_scope not in ('order', 'product') then perform booking._err('invalid_scope', 'Tarkista kohdistus'); end if;
  if v_scope = 'product' then
    select coalesce(array_agg(distinct x::bigint order by x::bigint), '{}') into v_pids
      from jsonb_array_elements_text(case when jsonb_typeof(p_data -> 'product_ids') = 'array' then p_data -> 'product_ids' else '[]'::jsonb end) x where x ~ '^\d{1,18}$';
    if exists (select 1 from unnest(v_pids) u where not exists (select 1 from kb.products p where p.id = u)) then
      perform booking._err('invalid_products', 'Tuntematon tuote');
    end if;
  end if;
  begin
    v_from := nullif(p_data ->> 'valid_from', '')::date; v_to := nullif(p_data ->> 'valid_to', '')::date;
  exception when others then perform booking._err('invalid_dates', 'Tarkista päivämäärät'); end;
  if v_from is not null and v_to is not null and v_to < v_from then perform booking._err('invalid_dates', 'Päättymispäivä ennen alkua'); end if;
  if v_desc is not null and char_length(v_desc) > 300 then perform booking._err('invalid_description', 'Kuvaus on liian pitkä'); end if;
  if v_annual then v_kind := 'percent'; v_value := 100; v_usage := 'permanent'; v_scope := 'product'; v_max := null; end if;
  if exists (select 1 from booking.discount_codes where code = v_code and id is distinct from p_id) then
    perform booking._err('code_exists', 'Koodi on jo käytössä');
  end if;
  if p_id is null then
    insert into booking.discount_codes(code, description, kind, value, valid_from, valid_to, max_uses, product_ids, active, target_scope, usage_type, is_annual_card_code)
    values (v_code, v_desc, v_kind, v_value, v_from, v_to, v_max, case when v_scope = 'product' then v_pids end,
            coalesce((p_data ->> 'active')::boolean, true), v_scope, v_usage, v_annual)
    returning * into d;
  else
    if v_usage <> 'permanent' and v_max is null and v_usage = 'single' then v_max := 1; end if;
    if v_max is not null and v_max < d.used_count then perform booking._err('invalid_max_uses', 'Käyttökertoja ei voi asettaa alle jo käytetyn määrän'); end if;
    update booking.discount_codes set code = v_code, description = v_desc, kind = v_kind, value = v_value, valid_from = v_from, valid_to = v_to,
           max_uses = v_max, product_ids = case when v_scope = 'product' then v_pids end, active = coalesce((p_data ->> 'active')::boolean, active),
           target_scope = v_scope, usage_type = v_usage, is_annual_card_code = v_annual
     where id = p_id returning * into d;
  end if;
  return jsonb_build_object('ok', true, 'id', d.id, 'code', d.code);
end $function$;

CREATE OR REPLACE FUNCTION booking._apply_discount_core(p_order_id bigint, p_code text)
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
  -- booking_239: oikeustarkistus kutsujassa (_apply_admin_discount / svc_create_booking)
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

CREATE OR REPLACE FUNCTION booking._apply_gift_core(p_order_id bigint, p_code text, p_remainder_method text, p_paid boolean, p_label text DEFAULT 'Hallinta'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code); v_res jsonb; v_rest numeric; v_rm text; v_paid boolean;
  v_total numeric;
begin
  -- booking_239: oikeustarkistus kutsujassa (_apply_admin_gift / svc_create_booking)
  if v_norm is null or v_norm = '' then
    return jsonb_build_object('gift_card_amount', 0);
  end if;
  if v_norm !~ '^[A-Z0-9]{12}$' then perform booking._err('gift_card_not_found', 'Koodia ei löydy tai se ei ole käytettävissä'); end if;
  select * into g from booking.gift_cards where code = v_norm;
  if not found or g.status in ('cancelled', 'pending_payment') then
    perform booking._err('gift_card_not_found', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  select total_gross into v_total from booking.orders where id = p_order_id;
  if coalesce(v_total, 0) <= 0 then
    return jsonb_build_object('gift_card_amount', 0, 'gift_card_skipped', true, 'remaining', 0, 'total', v_total);
  end if;
  if not exists (select 1 from booking.payments where order_id = p_order_id and status = 'pending') then
    insert into booking.payments(order_id, method, provider, status, amount, created_by)
    values (p_order_id, 'pay_later', 'manual', 'pending', v_total, auth.uid());
  end if;
  v_res := booking._gc_redeem(p_order_id, g.id, null, coalesce(nullif(btrim(p_label), ''), 'Hallinta'), false);
  v_rest := coalesce((v_res ->> 'remaining')::numeric, 0);
  if v_rest > 0.004 then
    v_rm := coalesce(nullif(btrim(coalesce(p_remainder_method, '')), ''), 'pay_later');
    if v_rm = 'gift_card' then v_rm := 'pay_later'; end if;
    if not exists (select 1 from booking.payment_methods where code = v_rm and active) then
      perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä');
    end if;
    v_paid := coalesce(p_paid, false) and v_rm not in ('pay_later', 'invoice', 'bank_transfer');
    insert into booking.payments(order_id, method, provider, status, amount, paid_at, note, created_by)
    values (p_order_id, v_rm, 'manual', case when v_paid then 'paid' else 'pending' end, v_rest,
            case when v_paid then now() end, 'Lahjakortin jälkeen jäljelle jäänyt osuus', auth.uid());
    perform booking._refresh_order_payment(p_order_id);
  end if;
  return jsonb_build_object('gift_card_amount', v_res -> 'amount', 'remaining', v_rest, 'gift_card', v_res -> 'gift_card',
                            'total', (select total_gross from booking.orders where id = p_order_id));
end $function$;

CREATE OR REPLACE FUNCTION booking._update_customer_core(p_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['name','email','phone','company','address','zip','city','country','language','notes','marketing_consent',
                          'customer_kind','business_id','einvoice_address','einvoice_operator','invoice_reference'];
  k text; v_consent boolean; c booking.customers; v_bid text; v_ei text; v_op text; v_kind text; v_email text;
begin
  -- booking_239: oikeustarkistus kutsujassa (admin_update_customer / svc_update_customer)
  select * into c from booking.customers where id = p_id;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and char_length(btrim(coalesce(p_patch ->> 'name', ''))) < 1 then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'email' then
    v_email := nullif(btrim(coalesce(p_patch ->> 'email', '')), '');
    if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
  end if;
  if p_patch ? 'phone' and nullif(btrim(coalesce(p_patch ->> 'phone', '')), '') is not null and btrim(p_patch ->> 'phone') !~ '^[0-9+()\- ]{6,30}$' then
    perform booking._err('invalid_phone', 'Tarkista puhelinnumero');
  end if;
  if p_patch ? 'customer_kind' then
    v_kind := lower(btrim(coalesce(p_patch ->> 'customer_kind', '')));
    if not exists (select 1 from booking.customer_kinds where code = v_kind and active) then perform booking._err('invalid_customer_kind', 'Asiakastyyppi ei ole sallittu'); end if;
  end if;
  if p_patch ? 'business_id' then
    v_bid := booking._norm_business_id(p_patch ->> 'business_id');
    if v_bid is not null and not booking._business_id_ok(v_bid) then perform booking._err('invalid_business_id', 'Tarkista y-tunnus (muoto 1234567-8)'); end if;
  end if;
  v_ei := case when p_patch ? 'einvoice_address' then upper(regexp_replace(coalesce(p_patch ->> 'einvoice_address', ''), '\s', '', 'g')) else coalesce(c.einvoice_address, '') end;
  v_op := case when p_patch ? 'einvoice_operator' then upper(regexp_replace(coalesce(p_patch ->> 'einvoice_operator', ''), '\s', '', 'g')) else coalesce(c.einvoice_operator, '') end;
  if v_ei <> '' and v_ei !~ '^[A-Z0-9]{6,35}$' then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite / OVT-tunnus'); end if;
  if v_op <> '' and v_op !~ '^[A-Z0-9]{3,35}$' then perform booking._err('invalid_einvoice_operator', 'Tarkista verkkolaskuoperaattorin välittäjätunnus'); end if;
  if (v_ei = '') <> (v_op = '') then perform booking._err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että operaattorin välittäjätunnus (tai kumpikaan)'); end if;
  if p_patch ? 'marketing_consent' then v_consent := (p_patch ->> 'marketing_consent')::boolean; end if;
  begin
    update booking.customers set
      name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
      email = case when p_patch ? 'email' then v_email else email end,
      phone = case when p_patch ? 'phone' then nullif(btrim(p_patch ->> 'phone'), '') else phone end,
      company = case when p_patch ? 'company' then nullif(btrim(p_patch ->> 'company'), '') else company end,
      address = case when p_patch ? 'address' then p_patch ->> 'address' else address end,
      zip = case when p_patch ? 'zip' then p_patch ->> 'zip' else zip end,
      city = case when p_patch ? 'city' then p_patch ->> 'city' else city end,
      country = case when p_patch ? 'country' then p_patch ->> 'country' else country end,
      language = case when p_patch ? 'language' then p_patch ->> 'language' else language end,
      notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end,
      customer_kind = case when p_patch ? 'customer_kind' then v_kind else customer_kind end,
      business_id = case when p_patch ? 'business_id' then v_bid else business_id end,
      einvoice_address = case when p_patch ? 'einvoice_address' then nullif(v_ei, '') else einvoice_address end,
      einvoice_operator = case when p_patch ? 'einvoice_operator' then nullif(v_op, '') else einvoice_operator end,
      invoice_reference = case when p_patch ? 'invoice_reference' then nullif(btrim(coalesce(p_patch ->> 'invoice_reference', '')), '') else invoice_reference end,
      marketing_consent = coalesce(v_consent, marketing_consent),
      marketing_consent_at = case when v_consent is distinct from marketing_consent and v_consent is not null then now() else marketing_consent_at end,
      marketing_consent_source = case when v_consent is distinct from marketing_consent and v_consent is not null then 'admin' else marketing_consent_source end,
      marketing_unsubscribed_at = case when v_consent is false and marketing_consent then now() else marketing_unsubscribed_at end
     where id = p_id;
  exception when check_violation then
    perform booking._err('invalid_company', 'Yritysasiakkaalla pitää olla yrityksen nimi ja kelvollinen y-tunnus');
  end;
  return jsonb_build_object('ok', true);
end $function$;

-- ---------------------------------------------------------------------------------------------
-- Hallinnan kääreet: sama käytös kuin ennen (oikeustarkistus + ydin)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION booking.admin_save_discount_code(p_id bigint, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_annual boolean := coalesce((p_data ->> 'is_annual_card_code')::boolean, false);
begin
  perform booking._require_permission('catalog.edit');
  if p_id is not null and not v_annual then
    select coalesce(dc.is_annual_card_code, false) into v_annual from booking.discount_codes dc where dc.id = p_id;
    v_annual := coalesce(v_annual, false);
  end if;
  if v_annual then perform booking._require_permission('annual_cards.manage'); end if;
  return booking._save_discount_code_core(p_id, p_data);
end $function$;

CREATE OR REPLACE FUNCTION booking._apply_admin_discount(p_order_id bigint, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('bookings.manage');
  return booking._apply_discount_core(p_order_id, p_code);
end $function$;

CREATE OR REPLACE FUNCTION booking._apply_admin_gift(p_order_id bigint, p_code text, p_remainder_method text, p_paid boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('bookings.manage');
  return booking._apply_gift_core(p_order_id, p_code, p_remainder_method, p_paid, 'Hallinta');
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_update_customer(p_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('customers.manage');
  return booking._update_customer_core(p_id, p_patch);
end $function$;

-- ---------------------------------------------------------------------------------------------
-- svc_create_discount_code: alennuskoodin luonti (sama validointi kuin hallinnassa)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION booking.svc_create_discount_code(p_data jsonb, p_note text, p_actor text DEFAULT 'Asiakaspalvelu'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor text := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  allowed text[] := array['code','kind','value','usage_type','usage','max_uses','target_scope','product_ids','valid_from','valid_to','description','active'];
  v_data jsonb; k text; v_res jsonb; d booking.discount_codes;
begin
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then perform booking._err('invalid_data', 'Anna p_data JSON-objektina'); end if;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Tuntematon kenttä: ' || k); end if;
  end loop;
  if p_data ? 'usage' and p_data ? 'usage_type' then perform booking._err('invalid_usage', 'Anna joko usage tai usage_type, ei molempia'); end if;
  v_data := (p_data - 'usage') || case when p_data ? 'usage' then jsonb_build_object('usage_type', p_data -> 'usage') else '{}'::jsonb end;
  if not (v_data ? 'kind') or not (v_data ? 'value') then perform booking._err('invalid_value', 'Anna kind (fixed tai percent) ja value'); end if;
  if v_data ->> 'kind' not in ('fixed', 'percent') then perform booking._err('invalid_kind', 'kind on fixed (euroa) tai percent (prosenttia)'); end if;

  v_res := booking._save_discount_code_core(null, v_data);
  select * into d from booking.discount_codes where id = (v_res ->> 'id')::bigint;
  if d.usage_type = 'single' and d.max_uses is distinct from 1 then
    update booking.discount_codes set max_uses = 1 where id = d.id returning * into d;
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'discount_codes', d.id::text, 'SVC_CREATE_DISCOUNT_CODE', null,
          jsonb_build_object('code', d.code, 'kind', d.kind, 'value', d.value, 'usage_type', d.usage_type, 'max_uses', d.max_uses,
                             'target_scope', d.target_scope, 'product_ids', d.product_ids, 'valid_from', d.valid_from, 'valid_to', d.valid_to,
                             'active', d.active, 'note', v_note, 'actor', v_actor));

  return jsonb_build_object('ok', true, 'id', d.id, 'code', d.code, 'kind', d.kind, 'value', d.value, 'usage_type', d.usage_type,
                            'max_uses', d.max_uses, 'target_scope', d.target_scope, 'product_ids', d.product_ids,
                            'valid_from', d.valid_from, 'valid_to', d.valid_to, 'active', d.active, 'description', d.description);
end $function$;

-- ---------------------------------------------------------------------------------------------
-- svc_create_booking: uusi varaus asiakkaan puolesta (sama ydin kuin admin_create_booking)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION booking.svc_create_booking(
  p_rule_id bigint, p_date date, p_persons integer, p_note text,
  p_customer_id bigint DEFAULT NULL::bigint, p_customer jsonb DEFAULT NULL::jsonb,
  p_addons jsonb DEFAULT NULL::jsonb, p_price_override numeric DEFAULT NULL::numeric,
  p_payment text DEFAULT 'pay_later'::text, p_send_confirmation boolean DEFAULT true,
  p_internal_note text DEFAULT NULL::text, p_gift_card_code text DEFAULT NULL::text,
  p_voucher_code text DEFAULT NULL::text, p_voucher_source text DEFAULT NULL::text,
  p_discount_code text DEFAULT NULL::text, p_channel text DEFAULT 'email'::text,
  p_invoice_reference text DEFAULT NULL::text, p_actor text DEFAULT 'Asiakaspalvelu'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor text := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_inote text := nullif(btrim(coalesce(p_internal_note, '')), '');
  v_pay text := lower(btrim(coalesce(nullif(p_payment, ''), 'pay_later')));
  v_gc text := nullif(btrim(coalesce(p_gift_card_code, '')), '');
  v_vc text := nullif(btrim(coalesce(p_voucher_code, '')), '');
  v_vsrc text := nullif(lower(btrim(coalesce(p_voucher_source, ''))), '');
  v_ref text := nullif(btrim(coalesce(p_invoice_reference, '')), '');
  v_channel text := coalesce(nullif(btrim(p_channel), ''), 'email');
  v_send boolean := coalesce(p_send_confirmation, true);
  v_cust bigint := p_customer_id; v_kind text; v_is_company boolean; v_company jsonb; v_email text; v_consent boolean;
  v_locale text; v_res jsonb; v_order bigint; v_res_id bigint; v_item bigint; v_token uuid;
  v_list numeric; v_add numeric; v_disc jsonb; v_total numeric; v_extra jsonb := '{}'::jsonb; v_vres jsonb;
  v_lines text[] := '{}'; v_skipped integer := 0; v_ps text; v_starts timestamptz;
begin
  perform booking._clear_staff_overrides();   -- ei ylibuukkausta / aikataulun ohitusta svc-polulla
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if p_rule_id is null or p_date is null or p_persons is null then perform booking._err('invalid_input', 'Anna p_rule_id, p_date ja p_persons'); end if;
  if v_pay not in ('pay_later', 'invoice', 'paid_external') then
    perform booking._err('invalid_payment', 'p_payment on pay_later, invoice tai paid_external');
  end if;
  if v_channel not in ('admin', 'phone', 'email', 'walk_in', 'other') then perform booking._err('invalid_channel', 'Virheellinen lähdekanava'); end if;
  if v_gc is not null and v_vc is not null then perform booking._err('payment_conflict', 'Anna joko oma lahjakortti tai kumppanikoodi, ei molempia'); end if;
  if v_pay <> 'pay_later' and (v_gc is not null or v_vc is not null) then
    perform booking._err('payment_conflict', 'Lahjakortti / kumppanikoodi käyttää maksutapaa pay_later (jäljelle jäävä osuus maksetaan myöhemmin)');
  end if;
  if v_vc is not null and v_vsrc is null then perform booking._err('voucher_source_required', 'Anna p_voucher_source (elamyslahjat, kokemuskauppa tai offerilla)'); end if;
  if v_vc is null and v_vsrc is not null then perform booking._err('voucher_code_required', 'Anna p_voucher_code'); end if;
  if p_price_override is not null and (p_price_override < 0 or p_price_override <> round(p_price_override, 2) or p_price_override > 100000) then
    perform booking._err('invalid_price', 'Virheellinen hinta (p_price_override, euroa, enintään 2 desimaalia)');
  end if;
  if v_inote is not null and char_length(v_inote) > 2000 then perform booking._err('invalid_note', 'Sisäinen muistiinpano on liian pitkä (enintään 2000 merkkiä)'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;

  -- asiakas: olemassa oleva id tai etsi/luo kuten hallinnan varauksessa (sähköpostilla _upsert_customer)
  if v_cust is null then
    if p_customer is null or jsonb_typeof(p_customer) <> 'object' or char_length(btrim(coalesce(p_customer ->> 'name', ''))) < 2 then
      perform booking._err('customer_required', 'Anna p_customer_id tai p_customer {name, email, phone}');
    end if;
    v_kind := lower(btrim(coalesce(nullif(p_customer ->> 'kind', ''), 'private')));
    select ck.is_company into v_is_company from booking.customer_kinds ck where ck.code = v_kind and ck.active;
    if v_is_company is null then perform booking._err('invalid_customer_kind', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
    v_email := lower(nullif(btrim(coalesce(p_customer ->> 'email', '')), ''));
    if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
    v_consent := coalesce((p_customer ->> 'marketing_consent')::boolean, false);
    if v_is_company then
      v_company := booking._clean_company(p_customer -> 'company_details');
      v_cust := booking._upsert_company_customer(v_kind, btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                  v_company, v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    elsif v_email is not null then
      v_cust := booking._upsert_customer(btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                 v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    else
      insert into booking.customers(name, phone, company, language, marketing_consent, marketing_consent_at, marketing_consent_source)
      values (btrim(p_customer ->> 'name'), nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''), nullif(btrim(coalesce(p_customer ->> 'company', '')), ''),
              coalesce(p_customer ->> 'language', 'fi'), v_consent,
              case when v_consent then now() end, case when v_consent then 'admin' end)
      returning id into v_cust;
    end if;
  elsif not exists (select 1 from booking.customers where id = v_cust and anonymized_at is null) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;
  select case when c.language in ('fi', 'en', 'sv') then c.language else 'fi' end into v_locale from booking.customers c where c.id = v_cust;

  -- varaus (kapasiteetti ja säännöt tarkistetaan ytimessä / triggereissä kuten hallinnassa; ei ylibuukkausta)
  v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, v_channel, null, coalesce(v_locale, 'fi'), null,
                                        'confirmed', null, false, null, null, p_price_override);
  v_order := (v_res ->> 'order_id')::bigint;
  v_res_id := (v_res ->> 'reservation_id')::bigint;
  v_token := (v_res ->> 'public_token')::uuid;
  v_starts := (v_res ->> 'starts_at')::timestamptz;
  if v_starts <= now() then perform booking._err('not_in_future', 'Varauksen pitää alkaa tulevaisuudessa'); end if;
  perform booking._stamp_order_billing(v_order, v_cust, v_company);
  if v_ref is not null then update booking.orders set invoice_reference = v_ref where id = v_order and customer_kind <> 'private'; end if;

  select pr.total into v_list from booking._rule_price(p_rule_id, p_persons) pr;
  if p_price_override is not null then
    select r.order_item_id into v_item from booking.reservations r where r.id = v_res_id;
    update booking.order_items
       set price_breakdown = coalesce(price_breakdown, '{}'::jsonb)
             || jsonb_build_object('price_override', jsonb_build_object('amount', p_price_override, 'list_total', v_list,
                                                                         'by', v_actor, 'note', v_note, 'at', now()))
     where id = v_item;
    v_lines := v_lines || format('poikkeava hinta %s € (listahinta %s €)', p_price_override, v_list);
  end if;

  v_add := booking._attach_addons(v_res_id, p_addons);
  v_disc := booking._apply_discount_core(v_order, p_discount_code);
  v_total := (v_disc ->> 'total')::numeric;
  v_extra := v_disc;

  if coalesce((v_disc ->> 'payment_inserted')::boolean, false) then
    null;   -- vuosikortti / 100 % alennus: ei maksettavaa
  elsif v_gc is not null then
    v_extra := v_disc || booking._apply_gift_core(v_order, v_gc, 'pay_later', false, v_actor);
    v_total := coalesce((v_extra ->> 'total')::numeric, v_total);
  else
    if v_total > 0.004 and v_pay <> 'paid_external' then
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
      values (v_order, case when v_pay = 'invoice' then 'invoice' else 'pay_later' end, 'manual', 'pending', v_total, null, auth.uid());
    end if;
    update booking.orders set payment_status = case when v_total <= 0.004 or v_pay = 'paid_external' then 'paid' else 'unpaid' end where id = v_order;
    if v_pay = 'paid_external' and v_total > 0.004 then v_lines := v_lines || 'maksettu ulkoisesti (ei maksuriviä)'::text; end if;
    if v_vc is not null then
      -- sama polku kuin verkkokaupassa: kumppanilahjakortin lunastuspyyntö tilaukselle
      v_vres := booking.public_submit_voucher_claim(v_token, v_vc, v_vsrc, null);
      if not coalesce((v_vres ->> 'ok')::boolean, false) then
        perform booking._err(coalesce(v_vres ->> 'code', 'voucher_failed'), coalesce(v_vres ->> 'message', 'Kumppanikoodin kirjaus epäonnistui'));
      end if;
      v_extra := v_extra || jsonb_build_object('voucher_claim_id', v_vres -> 'claim_no', 'voucher_source', v_vres -> 'source',
                                               'voucher_code_masked', v_vres -> 'code_masked', 'voucher_source_mismatch', v_vres -> 'source_mismatch');
    end if;
  end if;

  update booking.orders
     set internal_note = concat_ws(E'\n', internal_note,
           to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI') || ' ' || v_actor || ': ' || v_note
             || case when cardinality(v_lines) > 0 then ' [' || array_to_string(v_lines, '; ') || ']' else '' end,
           v_inote)
   where id = v_order;

  if not v_send then
    update booking.email_outbox
       set status = 'skipped', last_error = 'booking_239: svc_create_booking p_send_confirmation=false (' || v_actor || ')'
     where order_id = v_order and status = 'pending';
    get diagnostics v_skipped = row_count;
  end if;

  select o.payment_status, o.total_gross into v_ps, v_total from booking.orders o where o.id = v_order;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'orders', v_order::text, 'SVC_CREATE_BOOKING', null,
          jsonb_build_object('order_no', v_res -> 'order_no', 'reservation_id', v_res_id, 'customer_id', v_cust, 'rule_id', p_rule_id,
                             'date', p_date, 'persons', p_persons, 'starts_at', v_starts, 'total', v_total, 'list_total', v_list,
                             'price_override', p_price_override, 'addons_total', v_add, 'payment', v_pay, 'payment_status', v_ps,
                             'gift_card', v_gc is not null, 'voucher_claim_id', v_extra -> 'voucher_claim_id',
                             'discount_code', v_disc ->> 'discount_code', 'send_confirmation', v_send, 'emails_skipped', v_skipped,
                             'channel', v_channel, 'note', v_note, 'actor', v_actor));

  return (v_res - 'public_token' - 'hold_expires_at' - 'status')
         || jsonb_build_object('ok', true, 'customer_id', v_cust, 'total', v_total, 'list_total', v_list, 'price_override', p_price_override,
                               'addons_total', v_add, 'payment_status', v_ps, 'send_confirmation', v_send, 'emails_skipped', v_skipped)
         || (v_extra - 'payment_inserted' - 'total');
end $function$;

-- ---------------------------------------------------------------------------------------------
-- svc_cancel_reservation: peruutus ilman hyvitystä (kuten admin_cancel_reservation p_refund=false)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION booking.svc_cancel_reservation(p_order_no bigint, p_note text, p_reservation_id bigint DEFAULT NULL::bigint, p_actor text DEFAULT 'Asiakaspalvelu'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor text := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  o booking.orders; r booking.reservations; v_ids bigint[] := '{}'; v_status text; v_bal jsonb;
begin
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if p_order_no is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into o from booking.orders where order_no = p_order_no;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null then perform booking._err('external_order', 'Johkusta tuotu tilaus perutaan Johkussa (synkronointi palauttaisi sen)'); end if;
  if o.status in ('cancelled', 'expired') then perform booking._err('order_cancelled', 'Tilaus on jo peruttu'); end if;
  if p_reservation_id is not null and not exists (select 1 from booking.reservations x where x.id = p_reservation_id and x.order_id = o.id) then
    perform booking._err('not_found', 'Varausta ei löydy tältä tilaukselta');
  end if;

  -- lukitusjärjestys: varaukset, sitten tilaus
  for r in select * from booking.reservations x
            where x.order_id = o.id and (p_reservation_id is null or x.id = p_reservation_id)
              and x.status in ('pending', 'confirmed')
            order by x.id for update loop
    update booking.reservations set status = 'cancelled', cancelled_at = now(), cancel_reason = v_note where id = r.id;
    v_ids := v_ids || r.id;
  end loop;
  if cardinality(v_ids) = 0 then perform booking._err('invalid_status', 'Vain voimassa olevan varauksen voi perua'); end if;

  select * into o from booking.orders where id = o.id for update;
  if not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status in ('pending', 'confirmed')) then
    update booking.orders set status = 'cancelled', cancelled_at = now() where id = o.id;
  end if;
  update booking.orders
     set internal_note = concat_ws(E'\n', internal_note, to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI') || ' ' || v_actor
                                   || ': peruttu (ei hyvitystä): ' || v_note)
   where id = o.id
  returning status into v_status;
  v_bal := booking._order_balance(o.id);

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'orders', o.id::text, 'SVC_CANCEL_RESERVATION',
          jsonb_build_object('order_no', o.order_no, 'status', o.status),
          jsonb_build_object('order_no', o.order_no, 'status', v_status, 'reservation_ids', to_jsonb(v_ids), 'refund', false,
                             'note', v_note, 'actor', v_actor));

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'cancelled_reservation_ids', to_jsonb(v_ids), 'order_status', v_status,
                            'balance', v_bal, 'refund_done', false);
end $function$;

-- ---------------------------------------------------------------------------------------------
-- svc_add_order_note: rivi tilauksen sisäiseen muistiinpanoon
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION booking.svc_add_order_note(p_order_no bigint, p_text text, p_note text, p_actor text DEFAULT 'Asiakaspalvelu'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor text := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_text text := nullif(btrim(coalesce(p_text, '')), '');
  o booking.orders;
begin
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if v_text is null or char_length(v_text) > 2000 then perform booking._err('invalid_note', 'Muistiinpano 1–2000 merkkiä'); end if;
  select * into o from booking.orders where order_no = p_order_no for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  update booking.orders
     set internal_note = concat_ws(E'\n', internal_note, to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI') || ' ' || v_actor || ': ' || v_text)
   where id = o.id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'orders', o.id::text, 'SVC_ADD_ORDER_NOTE', null,
          jsonb_build_object('order_no', o.order_no, 'note', v_note, 'actor', v_actor, 'chars', char_length(v_text)));
  return jsonb_build_object('ok', true, 'order_no', o.order_no);
end $function$;

-- ---------------------------------------------------------------------------------------------
-- svc_update_customer: asiakkaan yhteystiedot (sama validointi kuin hallinnassa)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION booking.svc_update_customer(p_customer_id bigint, p_patch jsonb, p_note text, p_actor text DEFAULT 'Asiakaspalvelu'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor text := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  allowed text[] := array['name','email','phone','address','zip','city','country','language'];
  k text; v_keys text[] := '{}'; c booking.customers;
begin
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then perform booking._err('invalid_data', 'Anna muutettavat kentät p_patch-objektina'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata tällä funktiolla: ' || k); end if;
    v_keys := v_keys || k;
  end loop;
  if p_patch ? 'language' and coalesce(p_patch ->> 'language', '') not in ('fi', 'en', 'sv') then perform booking._err('invalid_language', 'Kieli on fi, en tai sv'); end if;
  select * into c from booking.customers where id = p_customer_id for update;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  if c.anonymized_at is not null then perform booking._err('anonymized', 'Asiakas on anonymisoitu'); end if;
  perform booking._update_customer_core(p_customer_id, p_patch);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'customers', c.id::text, 'SVC_UPDATE_CUSTOMER', null,
          jsonb_build_object('fields', to_jsonb(v_keys), 'note', v_note, 'actor', v_actor));
  return jsonb_build_object('ok', true, 'customer_id', c.id, 'updated_fields', to_jsonb(v_keys));
end $function$;

-- ---------------------------------------------------------------------------------------------
-- Oikeudet: uudet funktiot vain service_role (ytimet kuten muut _-apufunktiot)
-- ---------------------------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'booking._save_discount_code_core(bigint, jsonb)',
    'booking._apply_discount_core(bigint, text)',
    'booking._apply_gift_core(bigint, text, text, boolean, text)',
    'booking._update_customer_core(bigint, jsonb)',
    'booking.svc_create_discount_code(jsonb, text, text)',
    'booking.svc_create_booking(bigint, date, integer, text, bigint, jsonb, jsonb, numeric, text, boolean, text, text, text, text, text, text, text, text)',
    'booking.svc_cancel_reservation(bigint, text, bigint, text)',
    'booking.svc_add_order_note(bigint, text, text, text)',
    'booking.svc_update_customer(bigint, jsonb, text, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

comment on function booking.svc_create_booking(bigint, date, integer, text, bigint, jsonb, jsonb, numeric, text, boolean, text, text, text, text, text, text, text, text) is
  'booking_239: Asiakaspalvelu-botin varaus asiakkaan puolesta (Joonas t1294u 3.11.2026). Ydin kuten admin_create_booking; ei ylibuukkausta.';
comment on function booking.svc_create_discount_code(jsonb, text, text) is
  'booking_239: alennuskoodin luonti (validointi kuten admin_save_discount_code; single → max_uses 1).';
