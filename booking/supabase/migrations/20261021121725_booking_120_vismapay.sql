-- booking_120_vismapay (21.10.2026)
-- Visma Pay (Paybyway REST w3.2): test/live-valmistelu, ilmoituksen kirjaus, hyvitys.
-- Migraatio EI kytke test- eikä live-tilaa. Oletus säilyy off.
-- Avaimet ovat vain Edge-salaisuuksia (VISMAPAY_TEST_* / VISMAPAY_LIVE_*). Ei salaisuuksia tähän.
-- Rollback: rollbacks/20261021121725_booking_120_ROLLBACK.sql

set local lock_timeout = '5s';

-- ---------- tila ----------
alter table booking.integration_config drop constraint if exists integration_config_test_only_mobilepay;
alter table booking.integration_config add constraint integration_config_test_only_online
  check (mode <> 'test' or key in ('mobilepay', 'vismapay'));

create or replace function booking._vismapay_guard_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.key = 'vismapay' and new.mode in ('test', 'live') and coalesce(btrim(new.settings ->> 'approved_by'), '') = '' then
    raise exception 'Visma Payta ei voi kytkeä test- tai live-tilaan ilman settings.approved_by -merkintää' using errcode = 'BK001', detail = 'approval_required';
  end if;
  return new;
end $$;
drop trigger if exists integration_config_vismapay_guard on booking.integration_config;
create trigger integration_config_vismapay_guard before insert or update of mode, settings on booking.integration_config
  for each row execute function booking._vismapay_guard_trg();

create or replace function booking._vismapay_mode() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((select mode from booking.integration_config where key = 'vismapay'), 'off')
$$;

create or replace function booking._vismapay_online() returns boolean
language sql stable security definer set search_path = '' as $$
  select booking._vismapay_mode() in ('test', 'live')
$$;

update booking.integration_config
   set notes = 'Visma Pay (Paybyway REST w3.2). off = ei verkkomaksua; dry_run = paikallinen pending, ei HTTP:tä; test = VISMAPAY_TEST_API_KEY + VISMAPAY_TEST_PRIVATE_KEY; live = VISMAPAY_LIVE_API_KEY + VISMAPAY_LIVE_PRIVATE_KEY (tai VISMAPAY_API_KEY + VISMAPAY_PRIVATE_KEY). test ja live vaativat settings.approved_by. Migraatio ei kytke niitä. Kauppiastunnusta (merchant id) ei käytetä w3.2:ssa.',
       settings = settings || jsonb_build_object('version', 'w3.2', 'currency', 'EUR', 'api', 'pbwapi')
 where key = 'vismapay';

-- ---------- valmistelu ----------
drop function if exists booking.vismapay_payment_prepare(uuid);

create function booking.vismapay_payment_prepare(p_order_token uuid default null, p_link_token uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
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
     or o.payment_status = 'invoiced' or o.customer_kind = 'company'
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
end $$;

create function booking.vismapay_payment_event(p_order_number text, p_state text, p_redirect_url text, p_token text, p_detail jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments; v_detail jsonb := coalesce(p_detail, '{}'::jsonb) - 'email' - 'customer' - 'api_key' - 'authcode' - 'card_token';
begin
  if p_order_number is null or p_order_number !~ '^sauna-[a-z0-9_-]+$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  select * into pay from booking.payments where provider = 'visma_pay' and provider_ref = p_order_number for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if pay.status = 'paid' and p_state is distinct from 'CREATED' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update booking.payments
     set provider_status = p_state,
         link_url = coalesce(p_redirect_url, link_url),
         raw = coalesce(raw, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
           'last_state', p_state,
           'redirect_url', p_redirect_url,
           'token', p_token,
           'token_valid_until', coalesce(v_detail ->> 'token_valid_until', raw ->> 'token_valid_until'),
           'detail', v_detail))
   where id = pay.id;
  return jsonb_build_object('ok', true);
end $$;

create function booking.vismapay_payment_lookup(p_order_number text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
end $$;

create function booking.vismapay_payment_apply(p_order_number text, p_outcome text, p_amount numeric default null, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
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
end $$;

create function booking.vismapay_order_refs(p_order_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders;
begin
  if p_order_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._rate_limit('vprefs:' || p_order_token::text, 40, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  select * into o from booking.orders where public_token = p_order_token;
  if not found or o.external_source is not null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'mode', booking._vismapay_mode(), 'payment_status', o.payment_status,
    'refs', coalesce((select jsonb_agg(jsonb_build_object(
              'order_number', p.provider_ref, 'env', coalesce(p.raw ->> 'env', 'test'),
              'amount_minor', round(p.amount * 100)::bigint, 'status', p.status) order by p.id)
            from booking.payments p
           where p.order_id = o.id and p.provider = 'visma_pay' and p.status = 'pending'
             and p.provider_ref ~ '^sauna-[a-z0-9_-]+$'
             and coalesce(p.raw ->> 'last_state', '') is distinct from 'create_failed'), '[]'::jsonb));
end $$;

-- ---------- hyvitykset (admin_refund luo rivin kun tila <> off) ----------
create function booking.vismapay_refund_claim(p_refund_id bigint default null, p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_rows jsonb;
begin
  if booking._vismapay_mode() not in ('test', 'live') then
    return jsonb_build_object('ok', true, 'claimed', '[]'::jsonb, 'mode', booking._vismapay_mode());
  end if;
  with c as (
    select f.id from booking.refunds f
     where f.provider = 'visma_pay' and (p_refund_id is null or f.id = p_refund_id)
       and (f.status = 'requested'
            or (f.status = 'processing' and f.provider_refund_id is not null and p_refund_id is not null)
            or (f.status = 'processing' and f.updated_at < now() - interval '10 minutes'))
     order by f.id limit greatest(least(coalesce(p_limit, 20), 50), 1)
     for update skip locked),
  u as (
    update booking.refunds f set status = 'processing', provider_status = coalesce(f.provider_status, 'processing'), updated_at = now()
     from c where f.id = c.id returning f.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'refund_id', u.id, 'payment_id', u.payment_id, 'amount', u.amount,
           'amount_minor', round(u.amount * 100)::bigint,
           'order_number', p.provider_ref, 'currency', p.currency,
           'env', coalesce(p.raw ->> 'env', 'test'),
           'provider_refund_id', u.provider_refund_id,
           'sibling_refund_ids', coalesce((select jsonb_agg(f2.provider_refund_id) from booking.refunds f2
                                            where f2.payment_id = p.id and f2.provider_refund_id is not null and f2.id <> u.id), '[]'::jsonb)
         ) order by u.id), '[]'::jsonb) into v_rows
    from u join booking.payments p on p.id = u.payment_id;
  return jsonb_build_object('ok', true, 'claimed', v_rows, 'mode', booking._vismapay_mode());
end $$;

create function booking.vismapay_refund_stamp(p_refund_id bigint, p_provider_refund_id text, p_provider_status text, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds;
begin
  if p_provider_refund_id is null or btrim(p_provider_refund_id) = '' then
    perform booking._err('invalid_param', 'Hyvityksen tunnus puuttuu');
  end if;
  select * into rf from booking.refunds where id = p_refund_id and provider = 'visma_pay' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  if rf.provider_refund_id is not null and rf.provider_refund_id is distinct from p_provider_refund_id then
    perform booking._err('refund_id_conflict', 'Hyvityksellä on jo toinen Visma-tunnus');
  end if;
  update booking.refunds
     set status = 'processing', provider_refund_id = p_provider_refund_id, provider_status = p_provider_status,
         raw = coalesce(p_raw, raw), updated_at = now()
   where id = rf.id;
  return jsonb_build_object('ok', true, 'refund_id', rf.id, 'provider_refund_id', p_provider_refund_id);
end $$;

create function booking.vismapay_refund_complete(p_refund_id bigint, p_provider_refund_id text, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds; pay booking.payments; v_full boolean; v_gc boolean;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'visma_pay' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  if rf.status not in ('requested', 'processing') then perform booking._err('refund_not_pending', 'Hyvitys ei ole käsiteltävänä'); end if;
  select * into pay from booking.payments where id = rf.payment_id for update;
  v_full := abs(rf.amount - pay.amount) < 0.005 and pay.refunded_amount = 0;
  v_gc := exists (select 1 from booking.payment_lines pl join booking.order_items oi on oi.id = pl.order_item_id where pl.payment_id = pay.id and oi.kind = 'gift_card')
          and exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status <> 'cancelled');
  update booking.refunds
     set status = 'done', provider_status = 'refunded', provider_refund_id = coalesce(p_provider_refund_id, provider_refund_id),
         raw = coalesce(p_raw, raw), done_at = now(), updated_at = now()
   where id = rf.id;
  update booking.payment_lines pl set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
    from jsonb_array_elements(coalesce(rf.lines, '[]'::jsonb)) x where pl.id = (x ->> 'payment_line_id')::bigint;
  update booking.payments set refunded_amount = refunded_amount + rf.amount,
         status = case when refunded_amount + rf.amount >= amount - 0.004 then 'refunded' else 'partially_refunded' end
   where id = pay.id;
  perform booking._sync_placeholder(pay.order_id);
  perform booking._refresh_order_payment(pay.order_id);
  perform booking._on_refund_done(rf.id);
  if v_gc and v_full then perform booking._gc_cancel_order_cards(pay.order_id, 'Ostomaksu hyvitetty (hyvitys #' || rf.id || ')'); end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (null, 'service_role', 'refunds', rf.id::text, 'VISMAPAY_REFUND', jsonb_build_object('provider_refund_id', coalesce(p_provider_refund_id, rf.provider_refund_id), 'amount', rf.amount));
  return jsonb_build_object('ok', true, 'refund_id', rf.id);
end $$;

create function booking.vismapay_refund_fail(p_refund_id bigint, p_error jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'visma_pay' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  if rf.status not in ('requested', 'processing') then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  update booking.refunds set status = 'failed', provider_status = 'failed', raw = jsonb_build_object('error', p_error, 'at', now()), updated_at = now() where id = rf.id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (null, 'service_role', 'refunds', rf.id::text, 'VISMAPAY_REFUND_FAIL', coalesce(p_error, '{}'::jsonb));
  return jsonb_build_object('ok', true, 'status', 'failed');
end $$;

create function booking.vismapay_refund_lookup(p_provider_refund_id text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare rf booking.refunds; pay booking.payments;
begin
  if p_provider_refund_id is null or btrim(p_provider_refund_id) = '' then return jsonb_build_object('found', false); end if;
  select * into rf from booking.refunds where provider = 'visma_pay' and provider_refund_id = p_provider_refund_id;
  if not found then return jsonb_build_object('found', false); end if;
  select * into pay from booking.payments where id = rf.payment_id;
  return jsonb_build_object('found', true, 'refund_id', rf.id, 'status', rf.status, 'amount', rf.amount,
    'env', coalesce(pay.raw ->> 'env', 'test'), 'order_number', pay.provider_ref);
end $$;

-- ---------- hallinta ----------
create function booking.admin_get_vismapay_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r booking.integration_config;
begin
  perform booking._require_permission('settings.edit');
  select * into r from booking.integration_config where key = 'vismapay';
  return jsonb_build_object('ok', true, 'mode', coalesce(r.mode, 'off'),
    'approved_by', nullif(btrim(coalesce(r.settings ->> 'approved_by', '')), ''),
    'version', coalesce(r.settings ->> 'version', 'w3.2'),
    'currency', coalesce(r.settings ->> 'currency', 'EUR'),
    'online', coalesce(r.mode, 'off') in ('test', 'live'));
end $$;

create function booking.admin_set_vismapay_mode(p_mode text, p_approved_by text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_old text; v_by text := nullif(btrim(coalesce(p_approved_by, '')), '');
begin
  perform booking._require_permission('settings.edit');
  if p_mode is null or p_mode not in ('off', 'dry_run', 'test', 'live') then
    perform booking._err('invalid_param', 'Tila on off, dry_run, test tai live');
  end if;
  if p_mode in ('test', 'live') and v_by is null then
    perform booking._err('approval_required', 'Testi- ja tuotantotila vaativat merkinnän kuka kytki tilan päälle');
  end if;
  select mode into v_old from booking.integration_config where key = 'vismapay';
  update booking.integration_config
     set mode = p_mode,
         settings = case when p_mode in ('test', 'live') then settings || jsonb_build_object('approved_by', v_by) else settings end
   where key = 'vismapay';
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'integration_config', 'vismapay', 'VISMAPAY_MODE',
          jsonb_build_object('mode', v_old), jsonb_build_object('mode', p_mode, 'approved_by', v_by));
  return booking.admin_get_vismapay_status();
end $$;

-- ---------- julkinen tarjonta: Visma näkyy test- ja live-tilassa (test-lippulippu kaupalle) ----------
create or replace function booking.public_payment_options(p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_mode text := booking._mobilepay_mode();
  v_vp text := booking._vismapay_mode();
  o booking.orders; v_unpaid numeric; v_can boolean := false; v_methods jsonb := '[]'::jsonb; v_order jsonb := null; v_pending boolean := false;
  v_any boolean;
begin
  v_any := v_mode <> 'off' or v_vp in ('test', 'live');
  if v_mode <> 'off' then
    v_methods := jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mode = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if v_vp in ('test', 'live') then
    v_methods := v_methods || jsonb_build_array(jsonb_build_object('code', 'visma_pay', 'provider', 'visma_pay', 'label', 'Visma Pay', 'label_en', 'Visma Pay', 'test', v_vp = 'test',
      'start', jsonb_build_object('function', 'vismapay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if p_token is null and booking._pay_later_test_enabled() then v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json()); end if;
  if p_token is not null then
    if not booking._order_rl('popt', p_token, 120, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
    select * into o from booking.orders where public_token = p_token;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_can := v_any and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004
      and not (o.status = 'pending' and o.hold_kind = 'preliminary')
      and o.payment_status is distinct from 'invoiced' and o.customer_kind is distinct from 'company';
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider = 'mobilepay' and status = 'pending' and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending) || booking._checkout_state_json(o.id);
    if not v_can then v_methods := '[]'::jsonb; end if;
    if booking._pay_later_test_enabled() and o.external_source is null and v_order ->> 'checkout_state' = 'awaiting_payment'
       and o.payment_status is distinct from 'invoiced' and o.customer_kind is distinct from 'company' then
      v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_any, 'methods', v_methods, 'order', v_order);
end $$;

create or replace function booking.public_checkout_payment_options() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_mp text := booking._mobilepay_mode();
  v_vp text := booking._vismapay_mode();
  v_gc boolean := coalesce((booking._setting('gift_cards.redeem_enabled', 'false'::jsonb) #>> '{}')::boolean, false);
  v_m jsonb := '[]'::jsonb;
begin
  if v_mp <> 'off' then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'kind', 'online', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mp = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', jsonb_build_object('order_token', '<tilauksen public_token>'))));
  end if;
  if v_vp in ('test', 'live') then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'visma_pay', 'kind', 'online', 'provider', 'visma_pay', 'label', 'Visma Pay', 'label_en', 'Visma Pay', 'test', v_vp = 'test',
      'start', jsonb_build_object('function', 'vismapay-start', 'method', 'POST', 'body', jsonb_build_object('order_token', '<tilauksen public_token>'))));
  end if;
  if v_gc then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'gift_card', 'kind', 'redeem', 'provider', 'gift_card', 'label', 'Lahjakortti', 'label_en', 'Gift card', 'test', false,
      'check_rpc', 'public_check_gift_card', 'apply_rpc', 'public_apply_gift_card'));
  end if;
  if booking._pay_later_test_enabled() then v_m := v_m || jsonb_build_array(booking._pay_later_method_json()); end if;
  return jsonb_build_object('ok', true, 'methods', v_m, 'mobilepay_enabled', v_mp <> 'off', 'vismapay_enabled', v_vp in ('test', 'live'), 'gift_card_redeem_enabled', v_gc, 'pay_later_test_enabled', booking._pay_later_test_enabled(),
    'hold_until_paid', (booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}') <> 'pay_later', 'hold_minutes', booking._checkout_hold_minutes(),
    'group_threshold_persons', booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000), 'group_hold_days', booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60));
end $$;

create or replace function booking.admin_create_payment_link(p_order_id bigint, p_send_email boolean default false, p_expires_days integer default 14, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_pid bigint; v_mail boolean := false;
begin
  perform booking._require_permission('payments.manage');
  v := booking._create_link_payment(p_order_id, p_expires_days, p_note);
  v_pid := (v ->> 'payment_id')::bigint;
  if p_send_email then v_mail := booking._enqueue_email('payment_link', p_order_id, null, v_pid, 'payment_link:' || v_pid || ':' || to_char(now(), 'YYYYMMDDHH24MI')); end if;
  return jsonb_build_object('ok', true) || (booking._link_json(v_pid)) || jsonb_build_object('online_payment_enabled', booking._vismapay_online(), 'email_queued', v_mail);
end $$;

-- public_get_order: verkkomaksulippu seuraa test/live-tilaa (aiemmin vain live).
create or replace function booking.public_get_order(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('get', p_token, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  select split_part(c.name, ' ', 1) into v_cust from booking.customers c where c.id = o.customer_id;
  v_bal := booking._order_balance(o.id);
  v_status := case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;
  v_online := booking._vismapay_online();
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'), 'option_choices', booking._product_options_json(r.product_id),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', a.addon_id, 'name', a.product_name, 'quantity', a.quantity, 'line_total', a.line_total_gross) order by a.id)
                                 from booking.order_items a where a.parent_item_id = r.order_item_id and a.kind = 'addon'), '[]'::jsonb)) order by r.starts_at), '[]'::jsonb)
    into v_res from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'amount', p.amount, 'paid_at', p.paid_at, 'method_label', coalesce(pm.label, p.method),
           'link_token', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then p.link_token end,
           'link_path', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then v_pl || '?p=' || p.link_token end,
           'refunded', p.refunded_amount) order by p.created_at, p.id), '[]'::jsonb)
    into v_pay from booking.payments p left join booking.payment_methods pm on pm.code = p.method
   where p.order_id = o.id and p.status <> 'cancelled'
     and not (p.provider = 'manual' and p.status = 'pending' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id));
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'kind', x.kind, 'issued_at', x.issued_at, 'token', x.public_token, 'total', x.total_gross) order by x.issued_at, x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  select jsonb_build_object('status', q.status, 'created_at', q.created_at) into v_creq from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' order by q.created_at desc, q.id desc limit 1;

  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now();
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;

  if v_can_add then
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en, 'price', a.price_gross, 'vat_rate', a.vat_rate,
             'max', x.lim, 'reservation_ids', x.rids) order by a.sort_order, a.id), '[]'::jsonb) into v_ups_a
      from booking.addons a
      join lateral (select max(booking._addon_limit(a.max_per_person, r.persons)) lim, jsonb_agg(r.id order by r.id) rids
                      from booking.reservations r left join booking.product_config pc on pc.product_id = r.product_id left join kb.products p on p.id = r.product_id
                     where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now()
                       and coalesce(case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end, r.mode) = any (a.applies_modes)) x on x.rids is not null
     where a.active;
    select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'duration_minutes', coalesce(pc.duration_minutes, p.duration_minutes),
             'description', p.description, 'description_en', p.description_en, 'category', p.category) order by pc.sort_order, p.id), '[]'::jsonb) into v_ups_t
      from booking.product_config pc join kb.products p on p.id = pc.product_id
     where pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current' and p.active and p.price is not null;
  end if;

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status', v_status, 'payment_status', o.payment_status, 'currency', o.currency, 'locale', coalesce(o.locale, 'fi'),
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq, 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)))
    || booking._checkout_state_json(o.id);
end $$;

revoke all on function booking._vismapay_guard_trg() from public, anon, authenticated;
revoke all on function booking._vismapay_mode() from public, anon, authenticated;
revoke all on function booking._vismapay_online() from public, anon, authenticated;
revoke all on function booking.vismapay_payment_prepare(uuid, uuid) from public, anon, authenticated;
revoke all on function booking.vismapay_payment_event(text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function booking.vismapay_payment_lookup(text) from public, anon, authenticated;
revoke all on function booking.vismapay_payment_apply(text, text, numeric, jsonb) from public, anon, authenticated;
revoke all on function booking.vismapay_order_refs(uuid) from public, anon, authenticated;
revoke all on function booking.vismapay_refund_claim(bigint, integer) from public, anon, authenticated;
revoke all on function booking.vismapay_refund_stamp(bigint, text, text, jsonb) from public, anon, authenticated;
revoke all on function booking.vismapay_refund_complete(bigint, text, jsonb) from public, anon, authenticated;
revoke all on function booking.vismapay_refund_fail(bigint, jsonb) from public, anon, authenticated;
revoke all on function booking.vismapay_refund_lookup(text) from public, anon, authenticated;
revoke all on function booking.admin_get_vismapay_status() from public, anon;
revoke all on function booking.admin_set_vismapay_mode(text, text) from public, anon;
grant execute on function booking.vismapay_payment_prepare(uuid, uuid) to service_role;
grant execute on function booking.vismapay_payment_event(text, text, text, text, jsonb) to service_role;
grant execute on function booking.vismapay_payment_lookup(text) to service_role;
grant execute on function booking.vismapay_payment_apply(text, text, numeric, jsonb) to service_role;
grant execute on function booking.vismapay_order_refs(uuid) to service_role;
grant execute on function booking.vismapay_refund_claim(bigint, integer) to service_role;
grant execute on function booking.vismapay_refund_stamp(bigint, text, text, jsonb) to service_role;
grant execute on function booking.vismapay_refund_complete(bigint, text, jsonb) to service_role;
grant execute on function booking.vismapay_refund_fail(bigint, jsonb) to service_role;
grant execute on function booking.vismapay_refund_lookup(text) to service_role;
grant execute on function booking.admin_get_vismapay_status() to authenticated, service_role;
grant execute on function booking.admin_set_vismapay_mode(text, text) to authenticated, service_role;
