-- booking_178 ROLLBACK: palauttaa vismapay_payment_apply-, vismapay_payment_lookup- ja public_payment_link_info-funktiot täsmälleen booking_177-tilaan
-- (tuotannon määrittelyt ennen booking_178:aa) ja poistaa triggerin payments_vismapay_attempt, funktion booking._vismapay_attempt_trg() ja taulun booking.vismapay_attempts.
--   booking.vismapay_payment_apply(text,text,numeric,jsonb): 03fbbd2486b2c22dfa02d7ec84da626f -> e5ae519184809a5bc47202a4cd6e787d
--   booking.vismapay_payment_lookup(text): ddec24e2970bde7ff4dc6c6ecc3a63ac -> 413368e58d3f85eb437814ee836ccf1f
--   booking.public_payment_link_info(uuid): 647c556562046c75b7e7e33703c050a0 -> 1fb6153b39daa6f1055c93cac7cb4563
--   booking._vismapay_attempt_trg(): 8553fa9e304740124b64dd361439820a -> (poistettu); booking.vismapay_attempts -> (poistettu, yrityshistoria häviää)
-- Rollbackin jälkeen: pending-tilaan jääneet uudelleen yritettävät linkit toimivat vanhalla koodilla (prepare luo uuden yrityksen, koska last_state ≠ CREATED);
-- myöhästynyt ilmoitus vanhalle yritykselle palauttaa taas not_found (kuten ennen booking_178:aa).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_apply(text,text,numeric,jsonb)')));
  if v is null or v <> '03fbbd2486b2c22dfa02d7ec84da626f' then ok := false; msg := msg || ' vismapay_payment_apply=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_lookup(text)')));
  if v is null or v <> 'ddec24e2970bde7ff4dc6c6ecc3a63ac' then ok := false; msg := msg || ' vismapay_payment_lookup=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_link_info(uuid)')));
  if v is null or v <> '647c556562046c75b7e7e33703c050a0' then ok := false; msg := msg || ' public_payment_link_info=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vismapay_attempt_trg()')));
  if v is null or v <> '8553fa9e304740124b64dd361439820a' then ok := false; msg := msg || ' _vismapay_attempt_trg=' || coalesce(v, 'puuttuu'); end if;
  if to_regclass('booking.vismapay_attempts') is null then ok := false; msg := msg || ' vismapay_attempts puuttuu'; end if;
  if not ok then raise exception 'booking_178 ROLLBACK: määrittelyt eivät vastaa booking_178:aa:%. Ei muutoksia.', msg; end if;
end $g$;

drop trigger payments_vismapay_attempt on booking.payments;

CREATE OR REPLACE FUNCTION booking.vismapay_payment_apply(p_order_number text, p_outcome text, p_amount numeric DEFAULT NULL::numeric, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; v_raw jsonb := coalesce(p_raw, '{}'::jsonb); v_res jsonb;
begin
  if p_order_number is null or p_order_number !~ '^sauna-[a-z0-9_-]+$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  if p_outcome is null or p_outcome not in ('paid', 'failed', 'cancelled', 'pending', 'authorized', 'needs_review') then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  select * into pay from booking.payments where provider = 'visma_pay' and provider_ref = p_order_number for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if pay.status = 'paid' then
    return jsonb_build_object('ok', true, 'already', true, 'outcome', 'paid');
  end if;
  if pay.status in ('failed', 'cancelled', 'refunded') and p_outcome in ('failed', 'cancelled', 'pending', 'authorized') then
    return jsonb_build_object('ok', true, 'unchanged', true, 'outcome', pay.status);
  end if;

  if p_outcome = 'paid' then
    if p_amount is null or round(p_amount * 100) <> round(pay.amount * 100) then
      update booking.payments set provider_status = 'amount_mismatch', raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('amount_mismatch', true, 'reported_amount', p_amount) where id = pay.id;
      update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'VISMA PAY: summa ei täsmää, maksua ei merkitty maksetuksi (' || p_order_number || ')' where id = pay.order_id;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_AMOUNT_MISMATCH', jsonb_build_object('order_number', p_order_number, 'reported', p_amount, 'expected', pay.amount));
      return jsonb_build_object('ok', true, 'outcome', 'needs_review', 'code', 'amount_mismatch');
    end if;
    v_res := booking.payment_mark_paid('visma_pay', p_order_number, pay.amount, v_raw || jsonb_build_object('source', v_raw -> 'source'));
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_PAID', jsonb_build_object('order_number', p_order_number, 'result', v_res));
    return v_res || jsonb_build_object('outcome', 'paid');
  elsif p_outcome = 'needs_review' then
    update booking.payments set provider_status = 'needs_review', raw = coalesce(raw, '{}'::jsonb) || v_raw where id = pay.id;
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'VISMA PAY: maksu vaatii tarkistuksen (' || p_order_number || ')' where id = pay.order_id;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_NEEDS_REVIEW', v_raw);
    return jsonb_build_object('ok', true, 'outcome', 'needs_review');
  elsif p_outcome in ('failed', 'cancelled') then
    perform booking.payment_mark_failed('visma_pay', p_order_number, p_outcome, v_raw);
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_' || upper(p_outcome), v_raw);
    return jsonb_build_object('ok', true, 'outcome', p_outcome);
  else
    update booking.payments set provider_status = p_outcome, raw = coalesce(raw, '{}'::jsonb) || v_raw where id = pay.id and status = 'pending';
    return jsonb_build_object('ok', true, 'outcome', p_outcome);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION booking.vismapay_payment_lookup(p_order_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders;
begin
  if p_order_number is null or p_order_number !~ '^sauna-[a-z0-9_-]+$' then
    return jsonb_build_object('found', false);
  end if;
  select * into pay from booking.payments where provider = 'visma_pay' and provider_ref = p_order_number;
  if not found then return jsonb_build_object('found', false); end if;
  select * into o from booking.orders where id = pay.order_id;
  return jsonb_build_object(
    'found', true, 'payment_id', pay.id, 'status', pay.status, 'amount', pay.amount,
    'amount_minor', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'env', coalesce(pay.raw ->> 'env', 'test'), 'order_token', o.public_token, 'order_no', o.order_no,
    'site_base_url', booking._setting('site_base_url', 'null'::jsonb) #>> '{}',
    'order_page_path', coalesce(booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}', '/tilaus/'));
end $function$;

CREATE OR REPLACE FUNCTION booking.public_payment_link_info(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_177: maksulinkkisivun (/maksa/?p=, /en/pay/?p=) yhteenveto ENNEN maksun aloitusta. Vain luku (ei muuta tilausta eikä maksua; ainoa kirjoitus
-- on yhteinen nopeusrajoitin _order_rl). Palauttaa vain vähimmäistiedot: tila + kieletön syykoodi, summa, valuutta, tilausnumero, rivit (nimi, pvm, klo
-- Europe/Helsinki) ja voimassaolo. EI asiakkaan nimeä, sähköpostia, puhelinta, osoitetta, muistiinpanoja, tilauksen tokenia eikä maksuvälittäjän tunnisteita.
-- Tila seuraa vismapay_payment_prepare-funktion linkkihaaran tarkistuksia (sama järjestys), joten "open" = painike voi käynnistää maksun.
--   open | paid (link_paid, order_paid) | expired (link_expired, payment_cancelled, payment_not_pending) | replaced (replaced, link_stale)
--   not_payable (other_provider_started, order_not_payable, vismapay_off) | not_found (tuntematon tai puuttuva token; ei muita tietoja)
declare
  pay booking.payments; o booking.orders;
  v_ip_max int; v_unpaid numeric; v_paid_any boolean; v_newer boolean; v_mode text;
  v_status text; v_reason text; v_items jsonb;
begin
  v_ip_max := coalesce((booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, 60);
  if not booking._order_rl('pli', p_token, v_ip_max, v_ip_max) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  if p_token is not null then
    select * into pay from booking.payments where link_token = p_token;
  end if;
  if pay.id is null then
    return jsonb_build_object('ok', true, 'status', 'not_found', 'reason', 'not_found', 'can_pay', false);
  end if;
  select * into o from booking.orders where id = pay.order_id;

  v_unpaid := coalesce((booking._order_balance(o.id) ->> 'unpaid')::numeric, 0);
  v_paid_any := exists (select 1 from booking.payments x where x.order_id = o.id and x.status in ('paid', 'partially_refunded', 'refunded'));
  -- korvattu: tilaukselle on kirjattu tämän jälkeen uusi maksu tai maksulinkki (_create_link_payment / admin_record_payment perui tämän)
  v_newer := exists (select 1 from booking.payments x where x.order_id = o.id and x.id > pay.id);
  v_mode := booking._vismapay_mode();

  if pay.status in ('paid', 'partially_refunded', 'refunded') then
    v_status := 'paid'; v_reason := 'link_paid';
  elsif pay.status <> 'pending' then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    elsif pay.link_expires_at is not null and pay.link_expires_at < now() then v_status := 'expired'; v_reason := 'link_expired';
    elsif pay.provider_status in ('failed', 'cancelled') then v_status := 'expired'; v_reason := 'payment_cancelled';
    else v_status := 'expired'; v_reason := 'payment_not_pending'; end if;
  elsif pay.provider = 'mobilepay' and pay.provider_ref is not null then
    v_status := 'not_payable'; v_reason := 'other_provider_started';
  elsif pay.link_expires_at is not null and pay.link_expires_at < now() then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    else v_status := 'expired'; v_reason := 'link_expired'; end if;
  elsif pay.amount > v_unpaid + 0.004 then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    else v_status := 'replaced'; v_reason := 'link_stale'; end if;
  elsif o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed', 'expired') or o.currency <> 'EUR'
     or o.payment_status = 'invoiced' or o.customer_kind = 'company'
     or (o.status = 'pending' and o.hold_kind = 'preliminary') then
    v_status := 'not_payable'; v_reason := 'order_not_payable';
  elsif v_mode is null or v_mode not in ('test', 'live') then
    v_status := 'not_payable'; v_reason := 'vismapay_off';
  else
    v_status := 'open'; v_reason := 'open';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', it.kind,
           'name', it.product_name,
           'name_en', nullif(btrim(coalesce(ad.name_en, kp.name_en, '')), ''),
           'quantity', it.quantity,
           'date', to_char(r.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'),
           'start', to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24:MI'),
           'end', to_char(r.ends_at at time zone 'Europe/Helsinki', 'HH24:MI'),
           'end_date', to_char(r.ends_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'))
         order by coalesce(it.parent_item_id, it.id), it.parent_item_id is not null, r.starts_at nulls last, it.id), '[]'::jsonb)
    into v_items
    from booking.order_items it
    left join kb.products kp on kp.id = it.product_id and it.kind in ('reservation', 'product')
    left join booking.addons ad on ad.id = it.addon_id
    left join booking.reservations r on r.order_item_id = it.id and r.order_id = it.order_id and r.hidden_at is null and r.status <> 'cancelled'
   where it.order_id = o.id and it.kind <> 'discount';

  return jsonb_build_object(
    'ok', true, 'status', v_status, 'reason', v_reason, 'can_pay', v_status = 'open',
    'amount', pay.amount, 'amount_cents', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'order_no', o.order_no, 'order_total', o.total_gross,
    'expires_at', pay.link_expires_at,
    'expires_date', to_char(pay.link_expires_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'),
    'expires_time', to_char(pay.link_expires_at at time zone 'Europe/Helsinki', 'HH24:MI'),
    'paid_at', case when v_reason = 'link_paid' then pay.paid_at end,
    'items', v_items);
end $function$;

revoke all on function booking.vismapay_payment_apply(text,text,numeric,jsonb) from public, anon, authenticated;
grant execute on function booking.vismapay_payment_apply(text,text,numeric,jsonb) to service_role;
revoke all on function booking.vismapay_payment_lookup(text) from public, anon, authenticated;
grant execute on function booking.vismapay_payment_lookup(text) to service_role;
revoke all on function booking.public_payment_link_info(uuid) from public;
grant execute on function booking.public_payment_link_info(uuid) to anon, authenticated, service_role;

drop function booking._vismapay_attempt_trg();
drop table booking.vismapay_attempts;

do $v$
begin
  if md5(pg_get_functiondef('booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure)) <> 'e5ae519184809a5bc47202a4cd6e787d' then raise exception 'booking_178 ROLLBACK: vismapay_payment_apply md5 ei vastaa alkuperäistä'; end if;
  if md5(pg_get_functiondef('booking.vismapay_payment_lookup(text)'::regprocedure)) <> '413368e58d3f85eb437814ee836ccf1f' then raise exception 'booking_178 ROLLBACK: vismapay_payment_lookup md5 ei vastaa alkuperäistä'; end if;
  if md5(pg_get_functiondef('booking.public_payment_link_info(uuid)'::regprocedure)) <> '1fb6153b39daa6f1055c93cac7cb4563' then raise exception 'booking_178 ROLLBACK: public_payment_link_info md5 ei vastaa alkuperäistä'; end if;
  if to_regclass('booking.vismapay_attempts') is not null or to_regprocedure('booking._vismapay_attempt_trg()') is not null then raise exception 'booking_178 ROLLBACK: taulu/funktio jäi'; end if;
  if has_function_privilege('anon', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute') or not has_function_privilege('service_role', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute')
     or has_function_privilege('anon', 'booking.vismapay_payment_lookup(text)', 'execute') or not has_function_privilege('anon', 'booking.public_payment_link_info(uuid)', 'execute') then raise exception 'booking_178 ROLLBACK: oikeudet väärin'; end if;
end $v$;
