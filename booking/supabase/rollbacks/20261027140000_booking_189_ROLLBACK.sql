-- booking_189 ROLLBACK: palauttaa Visma Pay- ja MobilePay-valmistelun sekä kuitin, hyvityksen ja kassan tenderit booking_189:ää edeltävään runkoon.
-- Aja vasta kun booking_189 on kannassa, tai uudelleen (vartija hyväksyy uuden tai vanhan md5:n).
-- Dataa ei muuteta. Verkkomaksun aloitus Visma Paylla ja MobilePaylla palaa.
set local lock_timeout = '5s';

-- booking.mobilepay_payment_prepare(uuid,uuid,integer,text): c6a64c1ff9353a5e581d72af10966665 -> e6888446c4b44e554d31c0920609ddb6
-- booking.vismapay_payment_prepare(uuid,uuid): d22cda7beb5cea5967b267e52d79ab99 -> d1f8df803a45c2b77aa9f8554fc41890
-- booking.admin_refund(bigint,numeric,text,jsonb,boolean): 709d5fd54d877846682571b60c5d21bd -> 73923b95960933015bc121cd5a4845ef
-- booking._issue_receipt(bigint): 1bd426bef2ff856c712749d0a665f2b3 -> ae8b663945b78d1849b0028987689c8e
-- booking._issue_refund_receipt(bigint): ce97e81bd11e71aa92ba70f9719cae66 -> 1286d1a2a7cf12718a0022e72126b526
-- booking.admin_pos_tenders(): 443e6462ede3ec9d3118d08be43759fa -> 0b100e5beb55de1d34bd7aa3cbdb9b54

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)')));
  if v is null or v not in ('c6a64c1ff9353a5e581d72af10966665','e6888446c4b44e554d31c0920609ddb6') then
    raise exception 'booking_189 rollback: mobilepay_payment_prepare md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_prepare(uuid,uuid)')));
  if v is null or v not in ('d22cda7beb5cea5967b267e52d79ab99','d1f8df803a45c2b77aa9f8554fc41890') then
    raise exception 'booking_189 rollback: vismapay_payment_prepare md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_refund(bigint,numeric,text,jsonb,boolean)')));
  if v is null or v not in ('709d5fd54d877846682571b60c5d21bd','73923b95960933015bc121cd5a4845ef') then
    raise exception 'booking_189 rollback: admin_refund md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._issue_receipt(bigint)')));
  if v is null or v not in ('1bd426bef2ff856c712749d0a665f2b3','ae8b663945b78d1849b0028987689c8e') then
    raise exception 'booking_189 rollback: _issue_receipt md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._issue_refund_receipt(bigint)')));
  if v is null or v not in ('ce97e81bd11e71aa92ba70f9719cae66','1286d1a2a7cf12718a0022e72126b526') then
    raise exception 'booking_189 rollback: _issue_refund_receipt md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_tenders()')));
  if v is null or v not in ('443e6462ede3ec9d3118d08be43759fa','0b100e5beb55de1d34bd7aa3cbdb9b54') then
    raise exception 'booking_189 rollback: admin_pos_tenders md5=%', coalesce(v,'puuttuu');
  end if;
end $g$;

CREATE OR REPLACE FUNCTION booking.mobilepay_payment_prepare(p_order_token uuid DEFAULT NULL::uuid, p_link_token uuid DEFAULT NULL::uuid, p_expires_minutes integer DEFAULT 120, p_user_flow text DEFAULT 'WEB_REDIRECT'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._mobilepay_mode(); o booking.orders; pay booking.payments; v_tot numeric; v_unpaid numeric; v_open booking.payments;
  v_super jsonb := '[]'::jsonb; v_raw jsonb; v_mp jsonb; v_att int; v_ref text; v_id bigint; v_exp timestamptz; r record; v_started timestamptz;
  v_flow text; v_mins integer;
begin
  if v_mode = 'off' then perform booking._err('mobilepay_off', 'MobilePay-verkkomaksu ei ole käytössä'); end if;
  if (p_order_token is null) = (p_link_token is null) then perform booking._err('invalid_param', 'Anna joko p_order_token tai p_link_token'); end if;
  if p_expires_minutes is null or p_expires_minutes < 15 or p_expires_minutes > 1440 then perform booking._err('invalid_param', 'Voimassaolo 15–1440 min'); end if;
  v_flow := upper(btrim(coalesce(p_user_flow, 'WEB_REDIRECT')));
  if v_flow not in ('WEB_REDIRECT', 'QR', 'PUSH_MESSAGE') then perform booking._err('invalid_param', 'userFlow: WEB_REDIRECT, QR tai PUSH_MESSAGE'); end if;
  v_mins := p_expires_minutes;
  if v_flow in ('QR', 'PUSH_MESSAGE') and v_mins > 20 then v_mins := 20; end if;
  if not booking._rate_limit('mpstart:' || coalesce(p_order_token, p_link_token)::text, 12, interval '10 minutes') then perform booking._err('rate_limited', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;

  if p_link_token is not null then
    select * into pay from booking.payments where link_token = p_link_token for update;
    if not found then perform booking._err('not_found', 'Maksulinkkiä ei löydy'); end if;
    select * into o from booking.orders where id = pay.order_id for update;
  else
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  end if;
  if o.external_source is not null then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;       -- Johku-eristys
  if booking._order_invoice_locked(o.id) or o.payment_status = 'invoiced' then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;
  if o.status not in ('pending', 'confirmed', 'completed', 'expired') then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;
  if o.status = 'pending' and o.hold_kind = 'preliminary' then perform booking._err('order_not_payable', 'Alustavaa varausta ei makseta ennen vahvistusta'); end if;
  if v_flow = 'PUSH_MESSAGE' and o.source_channel is distinct from 'pikakassa' then
    perform booking._err('push_not_allowed', 'Mobiilimaksupyyntö on vain pikakassan tilauksille');
  end if;
  if o.currency <> 'EUR' then perform booking._err('unsupported_currency', 'Vain EUR tuettu'); end if;
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;

  if p_link_token is not null then
    if pay.status = 'paid' then perform booking._err('already_paid', 'Maksu on jo maksettu'); end if;
    if pay.status <> 'pending' then perform booking._err('payment_not_pending', 'Maksulinkki ei ole enää voimassa'); end if;
    if pay.provider not in ('visma_pay', 'mobilepay') then perform booking._err('payment_not_online', 'Ei verkkomaksu'); end if;
    if pay.provider = 'visma_pay' and pay.provider_ref is not null then perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla'); end if;
    if pay.link_expires_at is not null and pay.link_expires_at < now() then perform booking._err('link_expired', 'Maksulinkki on vanhentunut'); end if;
    if pay.amount > v_unpaid + 0.004 then perform booking._err('link_stale', 'Maksulinkin summa ei vastaa enää maksamatonta osuutta – pyydä uusi linkki'); end if;
    if pay.provider = 'visma_pay' then   -- asiakas valitsi MobilePayn maksulinkin sivulla: siirretään maksu MobilePaylle
      update booking.payments set provider = 'mobilepay', method = 'mobilepay', note = concat_ws(' | ', note, 'vaihdettu MobilePaylle') where id = pay.id returning * into pay;
    end if;
  else
    select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
    v_tot := least(v_tot, v_unpaid);
    if v_tot <= 0.004 then
      if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then perform booking._err('already_paid', 'Tilaus on jo maksettu'); end if;
      perform booking._err('nothing_to_pay', 'Ei maksettavaa');
    end if;
    if exists (select 1 from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and provider_ref is not null and (link_expires_at is null or link_expires_at > now())) then
      perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla');
    end if;
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and provider = 'mobilepay' and (link_expires_at is null or link_expires_at > now()) and amount = v_tot
      order by id desc limit 1 for update;
    if found then
      pay := v_open;
    else
      for r in select id, provider_ref, raw from booking.payments where order_id = o.id and status = 'pending' and provider in ('mobilepay', 'visma_pay') for update loop
        if r.provider_ref is not null and coalesce(r.raw -> 'mobilepay' ->> 'last_state', 'CREATED') = 'CREATED' then
          v_super := v_super || jsonb_build_array(r.provider_ref);
        end if;
        update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella MobilePay-maksulla') where id = r.id;
      end loop;
      v_exp := now() + make_interval(mins => v_mins);
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'mobilepay', 'mobilepay', 'pending', v_tot, o.currency, v_exp, 'MobilePay-verkkomaksu') returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
    end if;
  end if;

  perform booking._checkout_extend_hold(o.id);    -- booking_53: MobilePay-maksu alkaa -> paikka pysyy varattuna lopputulokseen asti (katto: checkout_mobilepay_max_wait_minutes)
  v_raw := coalesce(pay.raw, '{}'::jsonb); v_mp := coalesce(v_raw -> 'mobilepay', '{}'::jsonb);
  v_started := nullif(v_mp ->> 'attempt_started_at', '')::timestamptz;
  -- sama yritys vielä kesken (alle 8 min, sama user_flow, Vipps-maksu luotu, ei lopputilaa): käytetään samaa ohjausosoitetta
  if pay.provider_ref is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' and v_started is not null and v_started > now() - interval '8 minutes'
     and coalesce(v_mp ->> 'user_flow', 'WEB_REDIRECT') = v_flow
     and (v_flow = 'PUSH_MESSAGE' or pay.link_url is not null) then
    return jsonb_build_object('ok', true, 'reuse', true, 'payment_id', pay.id, 'reference', pay.provider_ref, 'redirect_url', pay.link_url,
      'user_flow', v_flow, 'pushed', v_flow = 'PUSH_MESSAGE', 'order_no', o.order_no, 'order_token', o.public_token, 'mode', v_mode);
  end if;
  if pay.provider_ref is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' then
    v_super := v_super || jsonb_build_array(pay.provider_ref);   -- edellinen keskeneräinen yritys perutaan Vippsissä
  end if;
  v_att := coalesce((v_mp ->> 'attempts')::int, 0) + 1;
  v_ref := 'sauna-o' || o.order_no || '-p' || pay.id || '-a' || v_att;
  v_mp := v_mp || jsonb_build_object('attempts', v_att, 'attempt_started_at', now(), 'last_state', null, 'env', v_mode, 'user_flow', v_flow,
                                     'refs', coalesce(v_mp -> 'refs', '[]'::jsonb) || to_jsonb(v_ref));
  update booking.payments set provider_ref = v_ref, provider_status = 'initiating', link_url = null,
         -- booking_184: 20 min katkaisu vain verkkokaupan maksulle, ei maksulinkille (takarajaton tai voimassaolo yli 2 h)
         link_expires_at = case when p_link_token is null and v_flow in ('QR', 'PUSH_MESSAGE')
                                     and not coalesce((pay.link_expires_at is null and coalesce(pay.raw ->> 'paylink', '') = 'no_deadline')
                                                      or pay.link_expires_at - pay.created_at > interval '2 hours', false)
                                then least(coalesce(link_expires_at, now() + interval '20 minutes'), now() + interval '20 minutes') else link_expires_at end,
         raw = jsonb_set(v_raw, '{mobilepay}', v_mp, true) where id = pay.id;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('ok', true, 'reuse', false, 'payment_id', pay.id, 'reference', v_ref, 'attempt', v_att, 'amount', pay.amount, 'amount_minor', round(pay.amount * 100)::bigint,
    'currency', pay.currency, 'order_id', o.id, 'order_no', o.order_no, 'order_token', o.public_token, 'locale', o.locale, 'mode', v_mode, 'user_flow', v_flow, 'superseded', v_super,
    'description', left('Sipoonjoen Perinnesauna – tilaus ' || o.order_no, 100),
    'site_base_url', booking._setting('site_base_url', null) #>> '{}', 'order_page_path', booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}');
end $function$
;

CREATE OR REPLACE FUNCTION booking.vismapay_payment_prepare(p_order_token uuid DEFAULT NULL::uuid, p_link_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._vismapay_mode();
  o booking.orders; pay booking.payments; c booking.customers;
  v_tot numeric; v_unpaid numeric; v_att int; v_ref text; v_until bigint; v_reuse boolean := false;
  v_cust jsonb := null; v_first text; v_last text; v_email text;
begin
  if (p_order_token is null) = (p_link_token is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_param', 'message', 'Anna joko order_token tai link_token');
  end if;
  if not booking._rate_limit('vpstart:' || coalesce(p_order_token, p_link_token)::text, 12, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_mode = 'off' then
    return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;

  if v_mode = 'dry_run' then
    if p_link_token is not null then
      return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
    end if;
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
    if o.external_source is not null or o.status not in ('pending', 'confirmed') or o.currency <> 'EUR' then
      return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa');
    end if;
    if booking._order_invoice_locked(o.id) or o.payment_status = 'invoiced' or booking._order_pays_by_invoice(o.customer_kind, o.billing) then
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
  end if;

  if v_mode not in ('test', 'live') then
    return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;

  if p_link_token is not null then
    select * into pay from booking.payments where link_token = p_link_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Maksulinkkiä ei löydy'); end if;
    select * into o from booking.orders where id = pay.order_id for update;
    if pay.status = 'paid' then return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Maksu on jo maksettu'); end if;
    if pay.status <> 'pending' then return jsonb_build_object('ok', false, 'code', 'payment_not_pending', 'message', 'Maksulinkki ei ole enää voimassa'); end if;
    if pay.provider = 'mobilepay' and pay.provider_ref is not null then
      return jsonb_build_object('ok', false, 'code', 'other_provider_started', 'message', 'Maksu on aloitettu toisella maksutavalla');
    end if;
    if pay.link_expires_at is not null and pay.link_expires_at < now() then
      return jsonb_build_object('ok', false, 'code', 'link_expired', 'message', 'Maksulinkki on vanhentunut');
    end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    if pay.amount > v_unpaid + 0.004 then
      return jsonb_build_object('ok', false, 'code', 'link_stale', 'message', 'Maksulinkin summa ei vastaa enää maksamatonta osuutta');
    end if;
    v_tot := pay.amount;
  else
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
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
     where order_id = o.id and status = 'pending' and provider = 'visma_pay' and amount = v_tot
       and coalesce(provider_ref, '') not like 'dryrun-%'
     order by (provider_ref is not null) desc, id desc
     limit 1 for update;
  end if;

  if o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed', 'expired') or o.currency <> 'EUR'
     or o.payment_status = 'invoiced' or booking._order_invoice_locked(o.id) or booking._order_pays_by_invoice(o.customer_kind, o.billing)
     or (o.status = 'pending' and o.hold_kind = 'preliminary') then
    return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa verkossa');
  end if;

  v_until := floor(extract(epoch from now() + interval '60 minutes'))::bigint;
  if pay.id is not null
     and coalesce(pay.raw ->> 'last_state', '') = 'CREATED'
     and coalesce(pay.raw ->> 'redirect_url', '') <> ''
     and coalesce(pay.raw ->> 'token', '') <> ''
     and coalesce(pay.raw ->> 'token_valid_until', '') ~ '^\d+$'
     and (pay.raw ->> 'token_valid_until')::bigint > floor(extract(epoch from now()))::bigint
     and pay.provider_ref ~ '^sauna-[a-z0-9_-]+$' then
    v_reuse := true;
  elsif pay.id is not null
     and coalesce(pay.raw ->> 'last_state', '') = 'initiating'
     and pay.updated_at > now() - interval '2 minutes' then
    return jsonb_build_object('ok', false, 'code', 'payment_in_progress', 'message', 'Maksun avaus on jo käynnissä. Odota hetki ja yritä uudelleen.');
  else
    if pay.id is null then
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, now() + interval '60 minutes', 'Visma Pay')
      returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
      v_att := 1;
    else
      v_att := coalesce((pay.raw ->> 'attempt')::int, 0) + 1;
      if v_att < 1 then v_att := 1; end if;
      if not exists (select 1 from booking.payment_lines where payment_id = pay.id) then
        insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
        select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      end if;
    end if;
    v_ref := 'sauna-o' || o.order_no::text || '-p' || pay.id::text || '-a' || v_att::text;
    update booking.payments
       set method = 'visma_pay', provider = 'visma_pay', provider_ref = v_ref, provider_status = 'initiating',
           raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('env', v_mode, 'attempt', v_att, 'last_state', 'initiating', 'token_valid_until', v_until::text)
     where id = pay.id
     returning * into pay;
    perform booking._refresh_order_payment(o.id);
  end if;

  if o.customer_id is not null then
    select * into c from booking.customers where id = o.customer_id;
    if found and c.anonymized_at is null then
      v_first := nullif(split_part(btrim(coalesce(c.name, '')), ' ', 1), '');
      v_last := nullif(btrim(substring(btrim(coalesce(c.name, '')) from char_length(split_part(btrim(coalesce(c.name, '')), ' ', 1)) + 1)), '');
      v_email := case when c.email is not null and booking._valid_email(c.email) then lower(btrim(c.email)) end;
      v_cust := jsonb_strip_nulls(jsonb_build_object(
        'firstname', v_first, 'lastname', v_last, 'email', v_email,
        'address_street', nullif(btrim(coalesce(c.address, '')), ''),
        'address_zip', nullif(btrim(coalesce(c.zip, '')), ''),
        'address_city', nullif(btrim(coalesce(c.city, '')), ''),
        'address_country', nullif(upper(btrim(coalesce(c.country, ''))), '')));
    end if;
  end if;

  return jsonb_build_object(
    'ok', true, 'mode', v_mode, 'dry_run', false, 'implemented', true, 'reuse', v_reuse,
    'payment_id', pay.id, 'order_number', pay.provider_ref, 'provider_ref', pay.provider_ref,
    'amount', pay.amount, 'amount_minor', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'order_no', o.order_no, 'order_token', o.public_token, 'status', pay.status,
    'locale', case when o.locale in ('fi', 'en', 'sv') then o.locale else 'fi' end,
    'description', 'Sipoonjoen Perinnesauna – tilaus ' || o.order_no::text,
    'site_base_url', booking._setting('site_base_url', 'null'::jsonb) #>> '{}',
    'order_page_path', coalesce(booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}', '/tilaus/'),
    'token_valid_until', coalesce(pay.raw ->> 'token_valid_until', v_until::text),
    'redirect_url', case when v_reuse then pay.raw ->> 'redirect_url' end,
    'customer', v_cust, 'env', coalesce(pay.raw ->> 'env', v_mode));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_refund(p_payment_id bigint, p_amount numeric, p_reason text, p_lines jsonb DEFAULT NULL::jsonb, p_manual_done boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders; v_cap numeric; v_mode text; v_online boolean; v_id bigint; l jsonb; v_pl booking.payment_lines; v_sum numeric := 0; v_full boolean;
        r record; v_total_cap numeric; v_alloc numeric; v_left numeric; v_alloc_json jsonb := '[]'::jsonb; v_status text; rc record; v_n int; v_i int := 0;
        v_gc_sale boolean := false;
begin
  perform booking._require_permission('payments.refund');
  select * into pay from booking.payments where id = p_payment_id for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  select * into o from booking.orders where id = pay.order_id for update;
  if o.external_source is not null or pay.external_source is not null then perform booking._err('order_not_editable', 'Johku-historian maksuja ei voi hyvittää tässä'); end if;
  if pay.status = 'refunded' then perform booking._err('already_refunded', 'Maksu on jo hyvitetty kokonaan'); end if;
  if pay.status not in ('paid','partially_refunded') then perform booking._err('refund_not_allowed', 'Vain maksettu maksu voidaan hyvittää'); end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(p_reason) > 500 then perform booking._err('invalid_param', 'Anna hyvityksen syy (3–500 merkkiä)'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_cap := pay.amount - pay.refunded_amount - coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = pay.id and f.status in ('requested','processing')), 0);
  if p_amount > v_cap + 0.004 then perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', v_cap)); end if;
  v_online := pay.provider <> 'manual';
  select mode into v_mode from booking.integration_config where key = replace(pay.provider, '_', '');
  if v_online and coalesce(v_mode, 'off') = 'off' then
    if not p_manual_done then perform booking._err('refund_not_allowed', 'Verkkomaksun hyvitys ei ole vielä käytössä – hyvitä Visman portaalissa ja kirjaa käsin (vain admin)'); end if;
    if booking.current_staff_role() is distinct from 'admin' then perform booking._err('forbidden', 'Käsinkirjaus verkkomaksulle vaatii admin-roolin'); end if;
  end if;
  v_full := abs(p_amount - v_cap) < 0.005 and pay.refunded_amount = 0;
  -- lahjakortit (booking_44): lahjakorttien ostomaksu hyvitetään vain kokonaan ja vain käyttämättömille korteille (kortit mitätöidään)
  if exists (select 1 from booking.payment_lines pl join booking.order_items oi on oi.id = pl.order_item_id where pl.payment_id = pay.id and oi.kind = 'gift_card')
     and exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status <> 'cancelled') then
    if not v_full then perform booking._err('gift_card_refund_full_only', 'Lahjakorttien ostomaksu hyvitetään kokonaan (kortit mitätöidään)'); end if;
    if exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status not in ('cancelled', 'pending_payment') and gc.balance < gc.initial_amount) then
      perform booking._err('gift_card_in_use', 'Kortilla on jo käyttöä: ostoa ei voi hyvittää kokonaan (mitätöi kortti hallinnassa ja hyvitä tarvittaessa käsin)');
    end if;
    v_gc_sale := true;
  end if;

  -- rivijako
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'p_lines väärässä muodossa'); end if;
    for l in select * from jsonb_array_elements(p_lines) loop
      if coalesce(l ->> 'payment_line_id', '') !~ '^\d{1,18}$' or coalesce(l ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
      select * into v_pl from booking.payment_lines where id = (l ->> 'payment_line_id')::bigint and payment_id = pay.id;
      if not found then perform booking._err('item_not_found', 'Maksun riviä ei löydy'); end if;
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_pl.amount_gross - v_pl.refunded_gross + 0.004 then perform booking._err('amount_exceeds_refundable', 'Rivin hyvitys ylittää hyvitettävissä olevan'); end if;
      v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', v_pl.id, 'amount', (l ->> 'amount')::numeric);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa hyvityksen summaa'); end if;
  elsif v_full then
    select coalesce(jsonb_agg(jsonb_build_object('payment_line_id', id, 'amount', amount_gross - refunded_gross) order by id), '[]'::jsonb) into v_alloc_json
      from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross <> 0;
  else   -- suhteessa positiivisten rivien hyvitettävään osuuteen
    select coalesce(sum(amount_gross - refunded_gross), 0) into v_total_cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    if v_total_cap < p_amount - 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
    v_left := p_amount; select count(*) into v_n from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    for r in select id, amount_gross - refunded_gross as cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0 order by id loop
      v_i := v_i + 1;
      v_alloc := case when v_i = v_n then v_left else least(round(p_amount * r.cap / v_total_cap, 2), r.cap) end;
      v_alloc := least(v_alloc, r.cap, v_left);
      if v_alloc > 0 then v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', r.id, 'amount', v_alloc); v_left := v_left - v_alloc; end if;
    end loop;
    if v_left > 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
  end if;

  v_status := case when v_online and coalesce(v_mode, 'off') <> 'off' then 'requested' else 'done' end;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, provider_status, lines, created_by, done_at)
  values (pay.id, pay.order_id, p_amount, btrim(p_reason), v_status, case when v_online and v_status = 'requested' then pay.provider else 'manual' end,
          case when v_online and v_status = 'done' then 'manual_done' end, v_alloc_json, auth.uid(), case when v_status = 'done' then now() end) returning id into v_id;
  if v_status = 'done' then
    update booking.payment_lines pl set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
      from jsonb_array_elements(v_alloc_json) x where pl.id = (x ->> 'payment_line_id')::bigint;
    update booking.payments set refunded_amount = refunded_amount + p_amount,
           status = case when refunded_amount + p_amount >= amount then 'refunded' else 'partially_refunded' end where id = pay.id;
    perform booking._sync_placeholder(pay.order_id);
    perform booking._refresh_order_payment(pay.order_id);
    perform booking._on_refund_done(v_id);
    -- lahjakortit (booking_44): ostomaksun hyvitys mitätöi kortit; lahjakorttimaksun hyvitys palautetaan kortille (ei rahana)
    if v_gc_sale then perform booking._gc_cancel_order_cards(pay.order_id, 'Ostomaksu hyvitetty (hyvitys #' || v_id || ')'); end if;
    if pay.gift_card_id is not null then perform booking._gc_apply(pay.gift_card_id, p_amount, 'refund', pay.order_id, pay.id, 'Hyvitys kortille: ' || btrim(p_reason)); end if;
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', v_id::text, 'ADMIN_REFUND', null, jsonb_build_object('payment_id', pay.id, 'amount', p_amount, 'reason', p_reason, 'status', v_status));
  select id, receipt_no into rc from booking.receipts where refund_id = v_id;
  return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', v_status, 'balance', booking._order_balance(pay.order_id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no);
end $function$;

CREATE OR REPLACE FUNCTION booking._issue_receipt(p_payment_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders; pm booking.payment_methods; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb; v_seq int; v_year int; v_no text;
        v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text;
begin
  select * into pay from booking.payments where id = p_payment_id;
  if not found or pay.amount <= 0 or booking._acct_excluded(pay.order_id, pay.id) then return null; end if;   -- Johku-lähtöinen (tilaus tai maksu) ei kuittiin/kirjanpitoon
  select id into v_id from booking.receipts where payment_id = pay.id and kind = 'receipt';
  if found then return v_id; end if;
  select * into o from booking.orders where id = pay.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select jsonb_agg(jsonb_build_object('description', concat(pl.description, (select ' – ' || case when o.locale = 'en' then coalesce(po.name_en, po.name) else po.name end from booking.reservations rr join booking.product_options po on po.id = rr.product_option_id where rr.order_item_id = oi.id and oi.kind = 'reservation')), 'quantity', pl.quantity, 'unit_gross', round(pl.amount_gross / greatest(pl.quantity, 1), 2),
           'unit_net', round(pl.line_net / greatest(pl.quantity, 1), 2), 'line_gross', pl.amount_gross, 'line_net', pl.line_net, 'vat_rate', pl.vat_rate, 'kind', pl.kind,
           'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind), 'starts_at', r.starts_at, 'ends_at', r.ends_at) order by pl.id)
    into v_lines
    from booking.payment_lines pl left join booking.order_items oi on oi.id = pl.order_item_id left join kb.products prod on prod.id = oi.product_id
    left join booking.reservations r on r.order_item_id = coalesce(oi.parent_item_id, oi.id)
   where pl.payment_id = pay.id;
  if v_lines is null then return null; end if;
  v_vat := booking._vat_groups(v_lines);
  select sum((x ->> 'gross')::numeric), sum((x ->> 'vat')::numeric) into v_gross, v_vatsum from jsonb_array_elements(v_vat) x;
  v_buyer := booking._buyer_json(o.id);
  v_year := booking._receipt_year(v_ts);
  v_series := booking._setting('receipt_series', '{"receipt":"K"}'::jsonb) ->> 'receipt';
  v_seq := booking._next_receipt_no(v_series, v_year);
  v_no := format('%s-%s-%s', v_series, v_year, lpad(v_seq::text, 6, '0'));
  v_snap := jsonb_build_object('v', 1, 'document', 'receipt', 'receipt_no', v_no, 'issued_at', v_ts, 'issued_local', to_char(v_ts at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'),
     'seller', booking._seller(), 'order_no', o.order_no,
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', coalesce(pm.label, pay.method), 'paid_at', pay.paid_at),
     'buyer', v_buyer, 'invoice_required', v_buyer is not null and v_gross > 400, 'lines', v_lines, 'vat', v_vat,
     'total_gross', v_gross, 'total_net', v_gross - v_vatsum, 'total_vat', v_vatsum, 'rounding', pay.rounding, 'total_paid', v_gross + pay.rounding,
     'currency', 'EUR', 'original', null, 'reason', null, 'locale', case when o.locale = 'en' then 'en' else 'fi' end);
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, locale, snapshot, text_body, created_by)
  values (v_no, 'receipt', v_series, v_year, v_seq, o.id, pay.id, v_ts, v_gross, v_snap ->> 'locale', v_snap, booking._receipt_text(v_snap), auth.uid()) returning id into v_id;
  if exists (select 1 from booking.integration_config where key = 'procountor' and mode <> 'off') then
    insert into booking.accounting_outbox(kind, order_id, payment_id, receipt_id, dedupe_key, payload, environment)
    values ('receipt', o.id, pay.id, v_id, 'receipt:' || v_id, v_snap, coalesce(booking._setting('procountor_env') #>> '{}', 'pts')) on conflict (dedupe_key) do nothing;
  end if;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION booking._issue_refund_receipt(p_refund_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f booking.refunds; pay booking.payments; o booking.orders; pm booking.payment_methods; orig booking.receipts; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text; v_rnd numeric := 0;
begin
  select * into f from booking.refunds where id = p_refund_id;
  if not found or f.status <> 'done' then return null; end if;
  select id into v_id from booking.receipts where refund_id = f.id;
  if found then return v_id; end if;
  select * into pay from booking.payments where id = f.payment_id;
  if booking._acct_excluded(pay.order_id, pay.id) then return null; end if;   -- Johku-lähtöinen ei hyvityskuittiin/kirjanpitoon
  select * into o from booking.orders where id = f.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select * into orig from booking.receipts where payment_id = pay.id and kind = 'receipt';
  select jsonb_agg(jsonb_build_object('description', pl.description, 'quantity', 1, 'unit_gross', -(x ->> 'amount')::numeric,
           'unit_net', -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)),
           'line_gross', -(x ->> 'amount')::numeric, 'line_net', -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)),
           'vat_rate', pl.vat_rate, 'kind', pl.kind, 'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind), 'starts_at', null, 'ends_at', null) order by pl.id)
    into v_lines
    from jsonb_array_elements(f.lines) x join booking.payment_lines pl on pl.id = (x ->> 'payment_line_id')::bigint
    left join booking.order_items oi on oi.id = pl.order_item_id left join kb.products prod on prod.id = oi.product_id;
  if v_lines is null then return null; end if;
  v_vat := booking._vat_groups(v_lines);
  select sum((x ->> 'gross')::numeric), sum((x ->> 'vat')::numeric) into v_gross, v_vatsum from jsonb_array_elements(v_vat) x;
  if pay.method = 'cash' then v_rnd := -booking._cash_rounding(-v_gross); end if;
  v_buyer := booking._buyer_json(o.id);
  v_year := booking._receipt_year(v_ts);
  v_series := booking._setting('receipt_series', '{"refund_receipt":"H"}'::jsonb) ->> 'refund_receipt';
  v_seq := booking._next_receipt_no(v_series, v_year);
  v_no := format('%s-%s-%s', v_series, v_year, lpad(v_seq::text, 6, '0'));
  v_snap := jsonb_build_object('v', 1, 'document', 'refund_receipt', 'receipt_no', v_no, 'issued_at', v_ts, 'issued_local', to_char(v_ts at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'),
     'seller', booking._seller(), 'order_no', o.order_no,
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', coalesce(pm.label, pay.method), 'paid_at', pay.paid_at),
     'buyer', v_buyer, 'invoice_required', false, 'lines', v_lines, 'vat', v_vat,
     'total_gross', v_gross, 'total_net', v_gross - v_vatsum, 'total_vat', v_vatsum, 'rounding', v_rnd, 'total_paid', v_gross + v_rnd,
     'currency', 'EUR', 'original', case when orig.id is null then null else jsonb_build_object('receipt_no', orig.receipt_no, 'issued_at', orig.issued_at,
         'issued_local', to_char(orig.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI')) end,
     'reason', f.reason, 'locale', case when o.locale = 'en' then 'en' else 'fi' end);
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, refund_id, original_receipt_id, issued_at, total_gross, locale, snapshot, text_body, created_by)
  values (v_no, 'refund_receipt', v_series, v_year, v_seq, o.id, pay.id, f.id, orig.id, v_ts, v_gross, v_snap ->> 'locale', v_snap, booking._receipt_text(v_snap), auth.uid()) returning id into v_id;
  if exists (select 1 from booking.integration_config where key = 'procountor' and mode <> 'off') then
    insert into booking.accounting_outbox(kind, order_id, payment_id, receipt_id, dedupe_key, payload, environment)
    values ('refund_receipt', o.id, pay.id, v_id, 'receipt:' || v_id, v_snap, coalesce(booking._setting('procountor_env') #>> '{}', 'pts')) on conflict (dedupe_key) do nothing;
  end if;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_pos_tenders()
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

revoke all on function booking.mobilepay_payment_prepare(uuid,uuid,integer,text) from public, anon, authenticated;
grant execute on function booking.mobilepay_payment_prepare(uuid,uuid,integer,text) to service_role;
revoke all on function booking.vismapay_payment_prepare(uuid,uuid) from public, anon, authenticated;
grant execute on function booking.vismapay_payment_prepare(uuid,uuid) to service_role;
revoke all on function booking.admin_refund(bigint,numeric,text,jsonb,boolean) from public, anon, authenticated;
grant execute on function booking.admin_refund(bigint,numeric,text,jsonb,boolean) to service_role, authenticated;
revoke all on function booking._issue_receipt(bigint) from public, anon, authenticated;
grant execute on function booking._issue_receipt(bigint) to service_role;
revoke all on function booking._issue_refund_receipt(bigint) from public, anon, authenticated;
grant execute on function booking._issue_refund_receipt(bigint) to service_role;
revoke all on function booking.admin_pos_tenders() from public, anon;
grant execute on function booking.admin_pos_tenders() to authenticated, service_role;

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)')));
  if v <> 'e6888446c4b44e554d31c0920609ddb6' then raise exception 'booking_189 rollback: mobilepay_payment_prepare md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_prepare(uuid,uuid)')));
  if v <> 'd1f8df803a45c2b77aa9f8554fc41890' then raise exception 'booking_189 rollback: vismapay_payment_prepare md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_refund(bigint,numeric,text,jsonb,boolean)')));
  if v <> '73923b95960933015bc121cd5a4845ef' then raise exception 'booking_189 rollback: admin_refund md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._issue_receipt(bigint)')));
  if v <> 'ae8b663945b78d1849b0028987689c8e' then raise exception 'booking_189 rollback: _issue_receipt md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._issue_refund_receipt(bigint)')));
  if v <> '1286d1a2a7cf12718a0022e72126b526' then raise exception 'booking_189 rollback: _issue_refund_receipt md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_tenders()')));
  if v <> '0b100e5beb55de1d34bd7aa3cbdb9b54' then raise exception 'booking_189 rollback: admin_pos_tenders md5=%', v; end if;
end $g$;
