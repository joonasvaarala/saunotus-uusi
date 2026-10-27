-- booking_188: verkkomaksu siirtyy Montonioon (Stargate Orders API). Visma Pay ja MobilePay jäävät lepotilaan.
-- Asiakkaalle näkyvä nimi on "Maksa verkossa" / "Pay online". Migraatio EI kytke test- eikä live-tilaa eikä koske Procountorin tilaan tai daily_enablediin.
-- md5 = md5(pg_get_functiondef). Vanhat tarkistettu paikallisella PostgreSQL 16.15:llä tuotannon dumpeista (täsmäävät kirjattuihin md5:iin).
-- Uudet laskettu samalla menetelmällä. Rollback: rollbacks/20261027120000_booking_188_ROLLBACK.sql
-- Testi: tests/checkout/t188_montonio.sql
--
-- Korvattavat (vanha -> uusi):
--   booking.public_payment_options(uuid): 46834d95db5127935ad94e8759758ceb -> 2557c31f99a77e70e5a3f35a3c44304e
--   booking.public_payment_link_info(uuid): 1b729ef4d72dc925001169c38bad3315 -> 2c9e06b3153aa5c0edd25341024ae6a8
--   booking.public_get_order(uuid): 5d0a5c1623ed4495be2d3ad0173284f1 -> 78d7b0b394dbd4d6d0a47a234d613159
--   booking._create_link_payment(bigint,integer,text): f40db96ca201e40467f20cc1db5866c9 -> adc14e6983e60d80498508c9b969f60d
--   booking.admin_create_payment_link(bigint,boolean,integer,text): 80004933a80f77a10fcf625f493a20ef -> 5d44526fd3c8ce105d8f6c1f6bc74327
--   booking._vc_redeem(bigint,numeric,text,text,text): 2aa8e44cb2c6f150d3488f53f8d94c25 -> 6576dc3dda048de2a438f1cdf333b0d9
--   booking.admin_set_procountor_settings(jsonb): 0b67b832a42a1f85fca071a3dc4ac471 -> 1195e099ba7447d6eca60d3c0a2aa4d9
--   booking.public_checkout_payment_options(): e6f019284f2b222013133af83d8fface -> 36b2d584cb3dd5abdf3bdf48e448c6aa
--   booking._checkout_online_available(): 9a0f7cb941024228438961c9c934e713 -> 7d9f58952e73b40ba666fb07ed9476a8
--   booking._order_mp_inflight(bigint): 0f6a9f95ebc3944e388bee7474d83cfc -> 15f53ed473122bd87b7b249f0b877c43
-- Uudet:
--   booking._montonio_mode(): bd80449b1c324f39825aad817a0e25be
--   booking._montonio_online(): f75ddbda6ed375ccb7be7d0470dd81f2
--   booking._montonio_guard_trg(): 38ee2f801b200de76faf20896ccd6dd7
--   booking._montonio_attempt_trg(): 75082f23542f834331d418b31aeb0542
--   booking.montonio_payment_prepare(uuid,uuid,text): 438ba5857d711f4686e3665bacd0eb18
--   booking.montonio_payment_event(text,text,text,text,jsonb): 23efc7c7d357fc3c80fe7852a5357f25
--   booking.montonio_payment_lookup(text): 58d2571e0bea01c06294afaaed3a5c09
--   booking.montonio_payment_apply(text,text,numeric,jsonb): ef052d2d9baa94bbe8cc4a9e1784d0ed
--   booking.montonio_order_refs(uuid): 7eba43609592bcb9ae6b03c3413e6c2f
--   booking.montonio_refund_claim(bigint,integer): a9043815ddcd211b411b86409846ac6b
--   booking.montonio_refund_stamp(bigint,text,text,jsonb): 9c9e1b6bcbc7af3094ee0db94c20bebe
--   booking.montonio_refund_complete(bigint,text,jsonb): e56363b9adacd24dd3237c5cfa78c0e0
--   booking.montonio_refund_fail(bigint,jsonb): b1513f446ed0bee8cf8182bdc1153ec4
--   booking.montonio_refund_release(bigint,jsonb): 8bd1e960a6967521ac7c0c588b8a6717
--   booking.montonio_refund_lookup(text,text): d620544da35d4914a70a16b320cc777b
--   booking.admin_get_montonio_status(): 62b32d73e18ea5f517d901a50701fa53
--   booking.admin_set_montonio_mode(text,text): 9716a05fb410e4b4980be6b66dc4f551
set local lock_timeout = '5s';

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_options(uuid)')));
  if v is null or v not in ('46834d95db5127935ad94e8759758ceb','2557c31f99a77e70e5a3f35a3c44304e') then
    raise exception 'booking_188: public_payment_options md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_link_info(uuid)')));
  if v is null or v not in ('1b729ef4d72dc925001169c38bad3315','2c9e06b3153aa5c0edd25341024ae6a8') then
    raise exception 'booking_188: public_payment_link_info md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_get_order(uuid)')));
  if v is null or v not in ('5d0a5c1623ed4495be2d3ad0173284f1','78d7b0b394dbd4d6d0a47a234d613159') then
    raise exception 'booking_188: public_get_order md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_link_payment(bigint,integer,text)')));
  if v is null or v not in ('f40db96ca201e40467f20cc1db5866c9','adc14e6983e60d80498508c9b969f60d') then
    raise exception 'booking_188: _create_link_payment md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_create_payment_link(bigint,boolean,integer,text)')));
  if v is null or v not in ('80004933a80f77a10fcf625f493a20ef','5d44526fd3c8ce105d8f6c1f6bc74327') then
    raise exception 'booking_188: admin_create_payment_link md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_redeem(bigint,numeric,text,text,text)')));
  if v is null or v not in ('2aa8e44cb2c6f150d3488f53f8d94c25','6576dc3dda048de2a438f1cdf333b0d9') then
    raise exception 'booking_188: _vc_redeem md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_set_procountor_settings(jsonb)')));
  if v is null or v not in ('0b67b832a42a1f85fca071a3dc4ac471','1195e099ba7447d6eca60d3c0a2aa4d9') then
    raise exception 'booking_188: admin_set_procountor_settings md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_checkout_payment_options()')));
  if v is null or v not in ('e6f019284f2b222013133af83d8fface','36b2d584cb3dd5abdf3bdf48e448c6aa') then
    raise exception 'booking_188: public_checkout_payment_options md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._checkout_online_available()')));
  if v is null or v not in ('9a0f7cb941024228438961c9c934e713','7d9f58952e73b40ba666fb07ed9476a8') then
    raise exception 'booking_188: _checkout_online_available md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_mp_inflight(bigint)')));
  if v is null or v not in ('0f6a9f95ebc3944e388bee7474d83cfc','15f53ed473122bd87b7b249f0b877c43') then
    raise exception 'booking_188: _order_mp_inflight md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_mark_paid(text,text,numeric,jsonb)')));
  if v is distinct from '8ceb0a7dea60d37e3ea6a17cec0e4c25' then
    raise exception 'booking_188: riippuvuus payment_mark_paid md5=%', coalesce(v,'puuttuu');
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_mark_failed(text,text,text,jsonb)')));
  if v is distinct from '2dfe2d2c0757157be90484d60cef8046' then
    raise exception 'booking_188: riippuvuus payment_mark_failed md5=%', coalesce(v,'puuttuu');
  end if;
end $g$;

alter table booking.integration_config drop constraint if exists integration_config_key_check;
alter table booking.integration_config add constraint integration_config_key_check
  check (key in ('resend', 'vismapay', 'procountor', 'mobilepay', 'booking_calendar', 'montonio'));
alter table booking.integration_config drop constraint if exists integration_config_test_only_online;
alter table booking.integration_config add constraint integration_config_test_only_online
  check (mode <> 'test' or key in ('mobilepay', 'vismapay', 'montonio'));

insert into booking.integration_config(key, mode, settings, notes)
values ('montonio', 'off', jsonb_build_object('currency','EUR','api','stargate','sandbox_base','https://sandbox-stargate.montonio.com','live_base','https://stargate.montonio.com'),
        'Verkkomaksu (Stargate). off = pois; dry_run = paikallinen pending, ei HTTP; test = sandbox kun MONTONIO_MODE=sandbox tai tyhjä; live vain kun MONTONIO_MODE=live. test ja live vaativat settings.approved_by. Avaimet vain Edge-salaisuuksina. Migraatio ei kytke tilaa.')
on conflict (key) do nothing;

create table if not exists booking.montonio_attempts (
  order_number  text primary key check (order_number ~ '^sauna-[a-z0-9_-]+$'),
  payment_id    bigint not null references booking.payments(id) on delete cascade,
  attempt       integer,
  env           text,
  created_at    timestamptz not null default now(),
  superseded_at timestamptz,
  outcome       text check (outcome in ('paid', 'failed', 'cancelled', 'duplicate_paid')),
  outcome_at    timestamptz
);
comment on table booking.montonio_attempts is 'booking_188: jokainen verkkomaksun tilausnumero (merchantReference). Ei henkilötietoja.';
create index if not exists montonio_attempts_payment_idx on booking.montonio_attempts(payment_id);
alter table booking.montonio_attempts enable row level security;
revoke all on table booking.montonio_attempts from public, anon, authenticated;
grant select on table booking.montonio_attempts to authenticated;
grant all on table booking.montonio_attempts to service_role;
drop policy if exists staff_read on booking.montonio_attempts;
create policy staff_read on booking.montonio_attempts for select to authenticated using ((select booking.is_staff()));

insert into booking.payment_methods(code, label, is_manual, active, johku_codes, sort_order)
values ('montonio', 'Maksa verkossa', false, false, '{}'::text[], 91)
on conflict (code) do update set label = excluded.label, is_manual = false;

-- Procountor: kopioi visma_pay-tili montonio-avaimeksi vain jos visma on asetettu ja montonio puuttuu. mode ja daily_enabled ennallaan.
update booking.integration_config c
   set settings = jsonb_set(c.settings, '{accounts,clearing_by_method,montonio}',
         to_jsonb(c.settings #>> '{accounts,clearing_by_method,visma_pay}'), true)
 where c.key = 'procountor'
   and coalesce(c.settings #>> '{accounts,clearing_by_method,visma_pay}', '') <> ''
   and coalesce(c.settings #>> '{accounts,clearing_by_method,montonio}', '') = '';

-- uudet apurit ja RPC:t (booking_188). Runko luodaan ennen korvattavia funktioita.

create or replace function booking._montonio_guard_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.key = 'montonio' and new.mode in ('test', 'live') and coalesce(btrim(new.settings ->> 'approved_by'), '') = '' then
    raise exception 'Verkkomaksua ei voi kytkeä test- tai live-tilaan ilman settings.approved_by -merkintää' using errcode = 'BK001', detail = 'approval_required';
  end if;
  return new;
end $$;

create or replace function booking._montonio_mode() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((select mode from booking.integration_config where key = 'montonio'), 'off')
$$;

create or replace function booking._montonio_online() returns boolean
language sql stable security definer set search_path = '' as $$
  select booking._montonio_mode() in ('test', 'live')
$$;

create or replace function booking._montonio_attempt_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.provider = 'montonio' and new.provider_ref ~ '^sauna-[a-z0-9_-]+$'
     and (tg_op = 'INSERT' or new.provider_ref is distinct from old.provider_ref) then
    insert into booking.montonio_attempts(order_number, payment_id, attempt, env)
    values (new.provider_ref, new.id,
            case when coalesce(new.raw ->> 'attempt', '') ~ '^\d{1,6}$' then (new.raw ->> 'attempt')::int end,
            nullif(new.raw ->> 'env', ''))
    on conflict (order_number) do update set superseded_at = null
     where booking.montonio_attempts.payment_id = excluded.payment_id;
    update booking.montonio_attempts set superseded_at = now()
     where payment_id = new.id and order_number <> new.provider_ref and superseded_at is null;
  end if;
  return null;
end $$;

create or replace function booking.montonio_payment_prepare(p_order_token uuid default null, p_link_token uuid default null, p_method text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_mode text := booking._montonio_mode();
  o booking.orders; pay booking.payments;
  v_tot numeric; v_unpaid numeric; v_att int; v_ref text; v_until bigint; v_reuse boolean := false;
begin
  if (p_order_token is null) = (p_link_token is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_param', 'message', 'Virheellinen pyyntö');
  end if;
  if p_method is null or p_method not in ('paymentInitiation', 'cardPayments', 'applePay', 'googlePay', 'mobilePay') then
    return jsonb_build_object('ok', false, 'code', 'invalid_param', 'message', 'Valitse maksutapa.');
  end if;
  if not booking._rate_limit('onlinestart:' || coalesce(p_order_token, p_link_token)::text, 12, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_mode = 'off' then
    return jsonb_build_object('ok', false, 'code', 'online_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;
  if v_mode = 'dry_run' then
    if p_link_token is not null then
      return jsonb_build_object('ok', false, 'code', 'online_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
    end if;
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
    if o.external_source is not null or o.status not in ('pending', 'confirmed') or o.currency <> 'EUR'
       or booking._order_invoice_locked(o.id) or o.payment_status = 'invoiced' or booking._order_pays_by_invoice(o.customer_kind, o.billing) then
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
     where order_id = o.id and status = 'pending' and provider = 'montonio' and amount = v_tot and provider_ref like 'dryrun-%'
     order by id desc limit 1 for update;
    if not found then
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'montonio', 'montonio', 'pending', v_tot, o.currency, now() + interval '30 minutes', 'Verkkomaksu dry_run, ei veloitusta')
      returning * into pay;
      update booking.payments set provider_ref = 'dryrun-' || pay.id, provider_status = 'dry_run' where id = pay.id returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
      perform booking._refresh_order_payment(o.id);
    end if;
    return jsonb_build_object('ok', true, 'mode', 'dry_run', 'dry_run', true,
      'payment_id', pay.id, 'order_number', pay.provider_ref, 'amount', pay.amount, 'currency', pay.currency,
      'order_no', o.order_no, 'status', pay.status, 'message', 'Testitila: maksua ei veloiteta eikä kuittia synny.');
  end if;
  if v_mode not in ('test', 'live') then
    return jsonb_build_object('ok', false, 'code', 'online_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;
  if p_link_token is not null then
    select * into pay from booking.payments where link_token = p_link_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Maksulinkkiä ei löydy'); end if;
    select * into o from booking.orders where id = pay.order_id for update;
    if pay.status in ('paid', 'partially_refunded', 'refunded') then return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Maksu on jo maksettu'); end if;
    if pay.status <> 'pending' then return jsonb_build_object('ok', false, 'code', 'payment_not_pending', 'message', 'Maksulinkki ei ole enää voimassa'); end if;
    if pay.provider in ('visma_pay', 'mobilepay') and pay.provider_ref is not null then
      return jsonb_build_object('ok', false, 'code', 'other_provider_started', 'message', 'Maksu on aloitettu toisella maksutavalla');
    end if;
    if pay.provider not in ('montonio', 'visma_pay', 'mobilepay') then
      return jsonb_build_object('ok', false, 'code', 'payment_not_online', 'message', 'Ei verkkomaksu');
    end if;
    if pay.link_expires_at is not null and pay.link_expires_at < now() then
      return jsonb_build_object('ok', false, 'code', 'link_expired', 'message', 'Maksulinkki on vanhentunut');
    end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    if pay.amount > v_unpaid + 0.004 then
      return jsonb_build_object('ok', false, 'code', 'link_stale', 'message', 'Maksulinkin summa ei vastaa enää maksamatonta osuutta');
    end if;
    v_tot := pay.amount;
    if pay.provider is distinct from 'montonio' then
      update booking.payments set provider = 'montonio', method = 'montonio' where id = pay.id returning * into pay;
    end if;
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
     where order_id = o.id and status = 'pending' and amount = v_tot
       and ((provider = 'montonio' and coalesce(provider_ref, '') not like 'dryrun-%')
            or (provider in ('visma_pay', 'mobilepay') and provider_ref is null))
     order by (provider = 'montonio') desc, (provider_ref is not null) desc, id desc
     limit 1 for update;
    if pay.id is not null and pay.provider is distinct from 'montonio' then
      update booking.payments set provider = 'montonio', method = 'montonio' where id = pay.id returning * into pay;
    end if;
  end if;
  if o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed', 'expired') or o.currency <> 'EUR'
     or o.payment_status = 'invoiced' or booking._order_invoice_locked(o.id) or booking._order_pays_by_invoice(o.customer_kind, o.billing)
     or (o.status = 'pending' and o.hold_kind = 'preliminary') then
    return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa verkossa');
  end if;
  v_until := floor(extract(epoch from now() + interval '30 minutes'))::bigint;
  if pay.id is not null
     and coalesce(pay.raw ->> 'last_state', '') = 'CREATED'
     and coalesce(pay.raw ->> 'method', '') = p_method
     and coalesce(pay.raw ->> 'redirect_url', '') <> ''
     and coalesce(pay.raw ->> 'redirect_valid_until', '') ~ '^\d+$'
     and (pay.raw ->> 'redirect_valid_until')::bigint > floor(extract(epoch from now()))::bigint
     and pay.provider_ref ~ '^sauna-[a-z0-9_-]+$' then
    v_reuse := true;
  elsif pay.id is not null
     and coalesce(pay.raw ->> 'last_state', '') = 'initiating'
     and pay.updated_at > now() - interval '2 minutes' then
    return jsonb_build_object('ok', false, 'code', 'payment_in_progress', 'message', 'Maksun avaus on jo käynnissä. Odota hetki ja yritä uudelleen.');
  else
    if pay.id is null then
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'montonio', 'montonio', 'pending', v_tot, o.currency, now() + interval '60 minutes', 'Verkkomaksu')
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
       set method = 'montonio', provider = 'montonio', provider_ref = v_ref, provider_status = 'initiating',
           raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('env', v_mode, 'attempt', v_att, 'method', p_method, 'last_state', 'initiating', 'attempt_started_at', now())
     where id = pay.id
     returning * into pay;
    perform booking._refresh_order_payment(o.id);
    perform booking._checkout_extend_hold(o.id);
  end if;
  return jsonb_build_object(
    'ok', true, 'mode', v_mode, 'dry_run', false, 'reuse', v_reuse,
    'payment_id', pay.id, 'order_number', pay.provider_ref, 'amount', pay.amount, 'currency', pay.currency,
    'order_no', o.order_no, 'order_token', o.public_token, 'status', pay.status,
    'locale', case when o.locale in ('fi', 'en', 'sv') then o.locale else 'fi' end,
    'redirect_url', case when v_reuse then pay.raw ->> 'redirect_url' end,
    'order_uuid', pay.raw ->> 'order_uuid',
    'env', coalesce(pay.raw ->> 'env', v_mode));
end $$;

create or replace function booking.montonio_payment_event(p_order_number text, p_state text, p_redirect_url text, p_order_uuid text, p_detail jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments; v_detail jsonb := coalesce(p_detail, '{}'::jsonb) - 'email' - 'customer' - 'accessKey' - 'secretKey' - 'senderName' - 'senderIban';
begin
  if p_order_number is null or p_order_number !~ '^sauna-[a-z0-9_-]+$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  select * into pay from booking.payments where provider = 'montonio' and provider_ref = p_order_number for update;
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
           'order_uuid', coalesce(p_order_uuid, raw ->> 'order_uuid'),
           'redirect_valid_until', case when p_state = 'CREATED' then (floor(extract(epoch from now())) + 1800)::text else raw ->> 'redirect_valid_until' end,
           'attempt_started_at', coalesce(raw ->> 'attempt_started_at', now()::text),
           'method', coalesce(v_detail ->> 'method', raw ->> 'method'),
           'env', coalesce(v_detail ->> 'env', raw ->> 'env'),
           'detail', v_detail))
   where id = pay.id;
  if p_state = 'CREATED' then perform booking._checkout_extend_hold(pay.order_id); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function booking.montonio_payment_lookup(p_order_number text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare pay booking.payments; o booking.orders; v_env text;
begin
  if p_order_number is null or p_order_number !~ '^sauna-[a-z0-9_-]+$' then
    return jsonb_build_object('found', false);
  end if;
  select * into pay from booking.payments where provider = 'montonio' and provider_ref = p_order_number;
  if not found then
    select p.* into pay from booking.montonio_attempts a join booking.payments p on p.id = a.payment_id
     where a.order_number = p_order_number and p.provider = 'montonio';
    if not found then return jsonb_build_object('found', false); end if;
  end if;
  select a.env into v_env from booking.montonio_attempts a where a.order_number = p_order_number;
  select * into o from booking.orders where id = pay.order_id;
  return jsonb_build_object(
    'found', true, 'payment_id', pay.id, 'status', pay.status, 'amount', pay.amount,
    'currency', pay.currency, 'order_uuid', pay.raw ->> 'order_uuid',
    'env', coalesce(v_env, pay.raw ->> 'env', 'test'), 'order_token', o.public_token, 'order_no', o.order_no,
    'current', pay.provider_ref is not distinct from p_order_number,
    'site_base_url', booking._setting('site_base_url', 'null'::jsonb) #>> '{}',
    'order_page_path', coalesce(booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}', '/tilaus/'));
end $$;

create or replace function booking.montonio_order_refs(p_order_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders;
begin
  if p_order_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._rate_limit('onlinerefs:' || p_order_token::text, 40, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  select * into o from booking.orders where public_token = p_order_token;
  if not found or o.external_source is not null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'payment_status', o.payment_status,
    'refs', coalesce((select jsonb_agg(jsonb_build_object(
              'order_number', p.provider_ref, 'amount', p.amount, 'order_uuid', p.raw ->> 'order_uuid',
              'env', coalesce(p.raw ->> 'env', 'test'), 'status', p.status) order by p.id)
            from booking.payments p
           where p.order_id = o.id and p.provider = 'montonio' and p.status = 'pending'
             and p.provider_ref ~ '^sauna-[a-z0-9_-]+$'
             and coalesce(p.raw ->> 'last_state', '') is distinct from 'create_failed'), '[]'::jsonb));
end $$;

create or replace function booking.montonio_refund_claim(p_refund_id bigint default null, p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_rows jsonb;
begin
  if booking._montonio_mode() not in ('test', 'live') then
    return jsonb_build_object('ok', true, 'claimed', '[]'::jsonb, 'mode', booking._montonio_mode());
  end if;
  with c as (
    select f.id from booking.refunds f
     where f.provider = 'montonio' and (p_refund_id is null or f.id = p_refund_id)
       and (f.status = 'requested'
            or (f.status = 'processing' and f.provider_status = 'awaiting_settlement' and (p_refund_id is not null or f.updated_at < now() - interval '12 hours'))
            or (f.status = 'processing' and f.provider_refund_id is not null and p_refund_id is not null)
            or (f.status = 'processing' and coalesce(f.provider_status, '') <> 'awaiting_settlement' and f.updated_at < now() - interval '10 minutes'))
     order by f.id limit greatest(least(coalesce(p_limit, 20), 50), 1)
     for update skip locked),
  u as (
    update booking.refunds f set status = 'processing', provider_status = coalesce(f.provider_status, 'processing'), updated_at = now()
     from c where f.id = c.id returning f.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'refund_id', u.id, 'payment_id', u.payment_id, 'amount', u.amount,
           'order_uuid', p.raw ->> 'order_uuid', 'currency', p.currency,
           'env', coalesce(p.raw ->> 'env', 'test'),
           'provider_refund_id', u.provider_refund_id,
           'idempotency_key', 'refund-' || u.id::text
         ) order by u.id), '[]'::jsonb) into v_rows
    from u join booking.payments p on p.id = u.payment_id;
  return jsonb_build_object('ok', true, 'claimed', v_rows, 'mode', booking._montonio_mode());
end $$;

create or replace function booking.montonio_refund_stamp(p_refund_id bigint, p_provider_refund_id text, p_provider_status text, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds;
begin
  if p_provider_refund_id is null or btrim(p_provider_refund_id) = '' then
    perform booking._err('invalid_param', 'Hyvityksen tunnus puuttuu');
  end if;
  select * into rf from booking.refunds where id = p_refund_id and provider = 'montonio' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  if rf.provider_refund_id is not null and rf.provider_refund_id is distinct from p_provider_refund_id then
    perform booking._err('refund_id_conflict', 'Hyvityksellä on jo toinen tunnus');
  end if;
  update booking.refunds
     set status = 'processing', provider_refund_id = p_provider_refund_id, provider_status = p_provider_status,
         raw = coalesce(p_raw, raw), updated_at = now()
   where id = rf.id;
  return jsonb_build_object('ok', true, 'refund_id', rf.id, 'provider_refund_id', p_provider_refund_id);
end $$;

create or replace function booking.montonio_refund_complete(p_refund_id bigint, p_provider_refund_id text, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds; pay booking.payments; v_full boolean; v_gc boolean;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'montonio' for update;
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
  values (null, 'service_role', 'refunds', rf.id::text, 'MONTONIO_REFUND', jsonb_build_object('provider_refund_id', coalesce(p_provider_refund_id, rf.provider_refund_id), 'amount', rf.amount));
  return jsonb_build_object('ok', true, 'refund_id', rf.id);
end $$;

create or replace function booking.montonio_refund_fail(p_refund_id bigint, p_error jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'montonio' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  if rf.status not in ('requested', 'processing') then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  update booking.refunds set status = 'failed', provider_status = 'failed', raw = jsonb_build_object('error', p_error, 'at', now()), updated_at = now() where id = rf.id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (null, 'service_role', 'refunds', rf.id::text, 'MONTONIO_REFUND_FAIL', coalesce(p_error, '{}'::jsonb));
  return jsonb_build_object('ok', true, 'status', 'failed');
end $$;

create or replace function booking.montonio_refund_release(p_refund_id bigint, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'montonio' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  if rf.status not in ('requested', 'processing') then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  update booking.refunds
     set status = 'processing', provider_status = 'awaiting_settlement', raw = coalesce(p_raw, raw), updated_at = now()
   where id = rf.id;
  return jsonb_build_object('ok', true, 'status', 'awaiting_settlement');
end $$;

create or replace function booking.montonio_refund_lookup(p_provider_refund_id text default null, p_order_uuid text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare rf booking.refunds; pay booking.payments;
begin
  if coalesce(btrim(p_provider_refund_id), '') <> '' then
    select * into rf from booking.refunds where provider = 'montonio' and provider_refund_id = p_provider_refund_id;
  end if;
  if rf.id is null and coalesce(btrim(p_order_uuid), '') <> '' then
    select f.* into rf
      from booking.refunds f join booking.payments p on p.id = f.payment_id
     where f.provider = 'montonio' and f.status in ('requested', 'processing') and p.raw ->> 'order_uuid' = p_order_uuid
     order by f.id desc limit 1;
  end if;
  if rf.id is null then return jsonb_build_object('found', false); end if;
  select * into pay from booking.payments where id = rf.payment_id;
  return jsonb_build_object('found', true, 'refund_id', rf.id, 'status', rf.status, 'amount', rf.amount,
    'order_uuid', pay.raw ->> 'order_uuid', 'provider_refund_id', rf.provider_refund_id,
    'env', coalesce(pay.raw ->> 'env', 'test'));
end $$;

create or replace function booking.admin_get_montonio_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r booking.integration_config;
begin
  perform booking._require_permission('settings.edit');
  select * into r from booking.integration_config where key = 'montonio';
  return jsonb_build_object('ok', true, 'provider', 'Montonio', 'mode', coalesce(r.mode, 'off'),
    'approved_by', nullif(btrim(coalesce(r.settings ->> 'approved_by', '')), ''),
    'currency', coalesce(r.settings ->> 'currency', 'EUR'),
    'online', coalesce(r.mode, 'off') in ('test', 'live'),
    'secrets', jsonb_build_array('MONTONIO_ACCESS_KEY', 'MONTONIO_SECRET_KEY', 'MONTONIO_MODE'));
end $$;

create or replace function booking.admin_set_montonio_mode(p_mode text, p_approved_by text default null)
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
  select mode into v_old from booking.integration_config where key = 'montonio';
  update booking.integration_config
     set mode = p_mode,
         settings = case when p_mode in ('test', 'live') then settings || jsonb_build_object('approved_by', v_by) else settings end
   where key = 'montonio';
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'integration_config', 'montonio', 'MONTONIO_MODE',
          jsonb_build_object('mode', v_old), jsonb_build_object('mode', p_mode, 'approved_by', v_by));
  return booking.admin_get_montonio_status();
end $$;

CREATE OR REPLACE FUNCTION booking.public_payment_options(p_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._montonio_mode();
  o booking.orders; v_unpaid numeric; v_can boolean := false; v_methods jsonb := '[]'::jsonb; v_order jsonb := null; v_pending boolean := false;
  v_any boolean;
begin
  v_any := v_mode <> 'off';
  if v_any then
    v_methods := jsonb_build_array(jsonb_build_object('code', 'online', 'provider', 'montonio', 'label', 'Maksa verkossa', 'label_en', 'Pay online', 'test', v_mode in ('test', 'dry_run'),
      'choices', jsonb_build_array(
        jsonb_build_object('method', 'paymentInitiation', 'label', 'Verkkopankki', 'label_en', 'Online bank'),
        jsonb_build_object('method', 'cardPayments', 'label', 'Kortti', 'label_en', 'Card'),
        jsonb_build_object('method', 'applePay', 'label', 'Apple Pay', 'label_en', 'Apple Pay'),
        jsonb_build_object('method', 'googlePay', 'label', 'Google Pay', 'label_en', 'Google Pay'),
        jsonb_build_object('method', 'mobilePay', 'label', 'MobilePay', 'label_en', 'MobilePay')),
      'start', jsonb_build_object('function', 'montonio-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if p_token is null and booking._pay_later_test_enabled() then v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json()); end if;
  if p_token is not null then
    if not booking._order_rl('popt', p_token, 120, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
    select * into o from booking.orders where public_token = p_token;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_can := v_any and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004
      and not (o.status = 'pending' and o.hold_kind = 'preliminary')
      and o.payment_status is distinct from 'invoiced' and not booking._order_pays_by_invoice(o.customer_kind, o.billing);
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider in ('montonio', 'mobilepay') and status = 'pending' and provider_ref is not null and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending) || booking._checkout_state_json(o.id);
    if not v_can then v_methods := '[]'::jsonb; end if;
    if booking._pay_later_test_enabled() and o.external_source is null and v_order ->> 'checkout_state' = 'awaiting_payment'
       and o.payment_status is distinct from 'invoiced' and not booking._order_pays_by_invoice(o.customer_kind, o.billing) then
      v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_any, 'methods', v_methods, 'order', v_order);
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
-- booking_178: peruttu/hylätty Visma-yritys ei kuluta maksulinkkiä (vismapay_payment_apply jättää maksun pending-tilaan) → tila on taas "open" ja
-- last_attempt = cancelled | failed kertoo sivulle, että edellinen yritys jäi kesken (muuten null). payment_cancelled jää vain vanhoille (ennen booking_178:aa
-- perutuille) riveille; peruttu + summa ei enää vastaa maksamatonta → replaced (link_stale).
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
  v_mode := booking._montonio_mode();

  if pay.status in ('paid', 'partially_refunded', 'refunded') then
    v_status := 'paid'; v_reason := 'link_paid';
  elsif pay.status <> 'pending' then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    elsif pay.link_expires_at is not null and pay.link_expires_at < now() then v_status := 'expired'; v_reason := 'link_expired';
    elsif pay.amount > v_unpaid + 0.004 then v_status := 'replaced'; v_reason := 'link_stale';
    elsif pay.provider_status in ('failed', 'cancelled') then v_status := 'expired'; v_reason := 'payment_cancelled';
    else v_status := 'expired'; v_reason := 'payment_not_pending'; end if;
  elsif pay.provider in ('mobilepay', 'visma_pay') and pay.provider_ref is not null then
    v_status := 'not_payable'; v_reason := 'other_provider_started';
  elsif pay.link_expires_at is not null and pay.link_expires_at < now() then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    else v_status := 'expired'; v_reason := 'link_expired'; end if;
  elsif pay.amount > v_unpaid + 0.004 then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    else v_status := 'replaced'; v_reason := 'link_stale'; end if;
  elsif o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed', 'expired') or o.currency <> 'EUR'
     or o.payment_status = 'invoiced' or booking._order_pays_by_invoice(o.customer_kind, o.billing)
     or (o.status = 'pending' and o.hold_kind = 'preliminary') then
    v_status := 'not_payable'; v_reason := 'order_not_payable';
  elsif v_mode is null or v_mode not in ('test', 'live') then
    v_status := 'not_payable'; v_reason := 'online_off';
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
    'last_attempt', case when v_status = 'open' and pay.provider_status in ('cancelled', 'failed') then pay.provider_status end,
    'items', v_items);
end $function$;
CREATE OR REPLACE FUNCTION booking.public_get_order(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
  v_cancel_dl timestamptz; v_cancel_closed boolean;   -- booking_149: asiakkaan peruutuspyynnön takaraja
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
  v_status := case when o.status = 'pending' and exists (select 1 from booking.reservations r where r.order_id = o.id) and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;
  v_online := booking._montonio_online();
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
  select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'amount', p.amount, 'paid_at', p.paid_at,
           'method_label', case when p.provider in ('montonio', 'visma_pay', 'mobilepay') or p.method in ('montonio', 'visma_pay', 'mobilepay')
                                then case when coalesce(o.locale, 'fi') = 'en' then 'Pay online' else 'Maksa verkossa' end
                                else coalesce(pm.label, p.method) end,
           'link_token', case when p.status = 'pending' and (p.provider = 'montonio' or (p.provider in ('visma_pay', 'mobilepay') and p.provider_ref is null)) and (p.link_expires_at is null or p.link_expires_at > now()) then p.link_token end,
           'link_path', case when p.status = 'pending' and (p.provider = 'montonio' or (p.provider in ('visma_pay', 'mobilepay') and p.provider_ref is null)) and (p.link_expires_at is null or p.link_expires_at > now()) then v_pl || '?p=' || p.link_token end,
           'refunded', p.refunded_amount,
           'refund_pending', exists (select 1 from booking.refunds rf where rf.payment_id = p.id and rf.status in ('requested', 'processing'))) order by p.created_at, p.id), '[]'::jsonb)
    into v_pay from booking.payments p left join booking.payment_methods pm on pm.code = p.method
   where p.order_id = o.id and p.status <> 'cancelled'
     and not (p.provider = 'manual' and p.status = 'pending' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id));
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'kind', x.kind, 'issued_at', x.issued_at, 'token', x.public_token, 'total', x.total_gross) order by x.issued_at, x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  select jsonb_build_object('status', q.status, 'created_at', q.created_at) into v_creq from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' order by q.created_at desc, q.id desc limit 1;

  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not booking._order_invoice_locked(o.id);
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  -- booking_149: asiakas voi pyytää peruutusta (ja sen hyvitystä) vain, kun ensimmäisen voimassa olevan vuoron alkuun on vähintään customer_change_hours_before tuntia (oletus 48).
  v_cancel_dl := booking._customer_cancel_deadline(o.id);
  v_cancel_closed := v_open and (v_cancel_dl is null or v_cancel_dl < now());
  v_open := v_open and v_cancel_dl is not null and v_cancel_dl >= now();
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
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind, 'invoice_method', case when o.customer_kind <> 'private' then o.billing ->> 'invoice_method' end,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
    'invoice_locked', booking._order_invoice_locked(o.id),
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq,
    'cancel_deadline', v_cancel_dl, 'cancel_hours_before', v_hours, 'cancel_closed', coalesce(v_cancel_closed, false), 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)),
    'instructions', booking._order_full_instructions(o.id, coalesce(o.locale, 'fi')))
    || booking._checkout_state_json(o.id);
end $function$;
CREATE OR REPLACE FUNCTION booking._create_link_payment(p_order_id bigint, p_expires_days integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_184: p_expires_days null = maksulinkki ilman takarajaa (link_expires_at null, raw.paylink = 'no_deadline'); muuten 1–60 päivää kuten ennen.
-- Uudelleenkäyttö (sama summa, yksi avoin Visma-rivi): takarajaton pyyntö käyttää vain merkittyä takarajatonta linkkiä; takarajallinen pyyntö käyttää
-- avointa riviä kuten ennen, paitsi henkilökunta (is_staff) korvaa takarajattoman linkin takarajallisella. Asiakkaan/järjestelmän polut eivät siis peru
-- henkilökunnan takarajatonta linkkiä, kun summa ei muutu.
declare o booking.orders; v_tot numeric; v_open booking.payments; v_n int; v_id bigint; v_token uuid; v_exp timestamptz; v_unpaid numeric; v_open_nd boolean;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if o.external_source is not null or o.status not in ('pending','confirmed','completed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi luoda maksulinkkiä'); end if;
  if p_expires_days is not null and (p_expires_days < 1 or p_expires_days > 60) then perform booking._err('invalid_param', 'Linkin voimassaolo 1–60 päivää'); end if;
  select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  v_tot := least(v_tot, v_unpaid);
  if v_tot <= 0.004 then perform booking._err('nothing_to_pay', 'Ei maksettavaa'); end if;
  select count(*) into v_n from booking.payments where order_id = o.id and status = 'pending' and (provider = 'montonio' or provider = 'visma_pay' or (provider = 'mobilepay' and provider_ref is null)) and (link_expires_at is null or link_expires_at > now());
  if v_n = 1 then
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and (provider = 'montonio' or provider = 'visma_pay' or (provider = 'mobilepay' and provider_ref is null)) and (link_expires_at is null or link_expires_at > now());
    v_open_nd := v_open.link_expires_at is null and coalesce(v_open.raw ->> 'paylink', '') = 'no_deadline';
    if v_open.amount = v_tot and (case when p_expires_days is null then v_open_nd
                                       when v_open_nd then not booking.is_staff()
                                       else true end) then
      if v_open.provider is distinct from 'montonio' or v_open.method is distinct from 'montonio' then update booking.payments set method = 'montonio', provider = 'montonio' where id = v_open.id; end if;
      return jsonb_build_object('payment_id', v_open.id, 'link_token', v_open.link_token, 'amount', v_open.amount, 'expires_at', v_open.link_expires_at, 'reused', true);
    end if;
  end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella maksulinkillä')
   where order_id = o.id and status = 'pending' and (provider = 'montonio' or provider = 'visma_pay' or (provider = 'mobilepay' and provider_ref is null));
  v_exp := case when p_expires_days is null then null else now() + make_interval(days => p_expires_days) end;
  insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, raw, note, created_by)
  values (o.id, 'montonio', 'montonio', 'pending', v_tot, o.currency, v_exp,
          case when v_exp is null then jsonb_build_object('paylink', 'no_deadline') end, p_note, auth.uid()) returning id, link_token into v_id, v_token;
  insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
  select v_id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
  -- jos rivit ylittävät jäännöksen (poikkeus: hyvitetty/poistettu rivi), pienennetään suurinta riviä
  update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = v_id) - v_tot)
   where id = (select id from booking.payment_lines where payment_id = v_id order by amount_gross desc, id limit 1)
     and (select sum(amount_gross) from booking.payment_lines where payment_id = v_id) > v_tot;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('payment_id', v_id, 'link_token', v_token, 'amount', v_tot, 'expires_at', v_exp, 'reused', false);
end $function$
;
CREATE OR REPLACE FUNCTION booking.admin_create_payment_link(p_order_id bigint, p_send_email boolean DEFAULT false, p_expires_days integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; v_pid bigint; v_mail boolean := false;
begin
  perform booking._require_permission('payments.manage');
  v := booking._create_link_payment(p_order_id, p_expires_days, p_note);
  v_pid := (v ->> 'payment_id')::bigint;
  if p_send_email then v_mail := booking._enqueue_email('payment_link', p_order_id, null, v_pid, 'payment_link:' || v_pid || ':' || to_char(now(), 'YYYYMMDDHH24MI')); end if;
  return jsonb_build_object('ok', true) || (booking._link_json(v_pid)) || jsonb_build_object('online_payment_enabled', booking._montonio_online(), 'email_queued', v_mail);
end $function$
;
CREATE OR REPLACE FUNCTION booking._vc_redeem(p_id bigint, p_amount numeric, p_partner_ref text, p_note text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.voucher_claims; o booking.orders; v jsonb; v_due numeric; v_link jsonb; v_pid bigint; v_diff numeric; v_mail boolean := false;
begin
  if p_amount is not null then
    if p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Lahjakortin arvon pitää olla yli 0 € (enintään 2 desimaalia)'); end if;
    select * into c from booking.voucher_claims where id = p_id for update;
    if found and c.status in ('open', 'processing', 'problem') then
      select * into o from booking.orders where id = c.order_id for update;
      if found and o.status in ('pending', 'confirmed') and o.external_source is null then
        v_due := booking._vc_due(o, c);
        if p_amount > v_due then
          perform booking._err('voucher_exceeds_total', format('Lahjakortin arvo %s € ylittää maksettavan summan %s €', p_amount, v_due));
        end if;
      end if;
    end if;
  end if;
  v := booking._vc_mark_redeemed(p_id, p_amount, p_partner_ref, p_note, p_by);
  -- booking_174 (booking_176: myös botti): arvo pienempi kuin maksettava → erotus maksulinkkinä asiakkaalle (Visma Pay -linkki, sähköposti payment_link / voucher_difference)
  if v_due is not null and p_amount < v_due and not coalesce((v ->> 'already')::boolean, false) and (v ->> 'payment_id') is not null then
    select * into o from booking.orders where id = o.id;
    v_link := booking._create_link_payment(o.id, null::integer, 'Kumppanilahjakortin erotus, pyyntö #' || p_id);   -- booking_184: ei takarajaa
    v_pid := (v_link ->> 'payment_id')::bigint;
    v_diff := (v_link ->> 'amount')::numeric;
    v_mail := booking._enqueue_email('payment_link', o.id, null, v_pid, 'payment_link:voucher_difference:' || p_id || ':' || v_pid,
                jsonb_build_object('variant', 'voucher_difference', 'claim_id', p_id, 'voucher_value', (v ->> 'amount')::numeric, 'difference', v_diff,
                                   'total', (v ->> 'amount')::numeric + v_diff));
    -- booking_176: erotuksen maksusta ei kuittisähköpostia (_on_payment_paid)
    insert into booking.vc_difference_payments(order_id, claim_id, payment_id) values (o.id, p_id, v_pid) on conflict (payment_id) do nothing;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'booking.voucher_claims', p_id::text, 'VOUCHER_DIFFERENCE_LINK', null,
            jsonb_build_object('voucher_value', (v ->> 'amount')::numeric, 'due', v_due, 'difference', v_diff, 'link_payment_id', v_pid, 'email_queued', v_mail, 'by', p_by));
  end if;
  return v || jsonb_build_object('voucher_value', case when (v ->> 'already')::boolean then null else (v ->> 'amount')::numeric end, 'due', v_due,
    'difference', v_diff, 'payment_link', case when v_pid is not null then booking._link_json(v_pid) || jsonb_build_object('online_payment_enabled', booking._montonio_online()) end,
    'email_queued', v_mail);
end $function$
;
CREATE OR REPLACE FUNCTION booking.admin_set_procountor_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  cur booking.integration_config;
  s jsonb; v_mode text; env text; approved text; vat text; prefix text; iban text;
  accounts jsonb; sales jsonb := '{}'::jsonb; clearing jsonb := '{}'::jsonb; rounding text;
  k text; v text;
  rates text[] := array['25.5','13.5','0','14','24','10'];
  methods text[] := array['cash','card_terminal','mobilepay','bank_transfer','invoice','gift_card','partner_voucher','partner_voucher_kokemuskauppa','partner_voucher_offerilla','partner_voucher_elamyslahjat','visma_pay','montonio','annual_card','pay_later','other'];
begin
  perform booking._require_permission('settings.edit');
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_setting', 'Asetusten pitää olla objekti'); end if;
  if booking._json_has_secret_key(p) then perform booking._err('secrets_not_allowed', 'Salaisuuksia ei tallenneta asetuksiin'); end if;
  select * into cur from booking.integration_config where key = 'procountor';
  if not found then perform booking._err('not_configured', 'procountor-asetus puuttuu'); end if;
  v_mode := coalesce(nullif(btrim(p->>'mode'), ''), cur.mode);
  if v_mode not in ('off', 'dry_run', 'live') then perform booking._err('invalid_setting', 'Tila on off, dry_run tai live'); end if;
  env := lower(btrim(coalesce(p->>'environment', cur.settings->>'environment', 'pts')));
  if env in ('sandbox', '') then env := 'pts'; end if;
  if env not in ('pts', 'prod') then perform booking._err('invalid_setting', 'Ympäristö on pts tai prod'); end if;
  if p ? 'approved_by' then approved := btrim(coalesce(p->>'approved_by', ''));
  else approved := btrim(coalesce(cur.settings->>'approved_by', '')); end if;
  if approved <> '' and (char_length(approved) < 3 or char_length(approved) > 80 or approved like 'eyJ%') then
    perform booking._err('invalid_setting', 'approved_by on nimi ja päivä, ei tunnusta');
  end if;
  if v_mode = 'live' and approved = '' then perform booking._err('approval_required', 'Yhdistetty tila vaatii approved_by'); end if;
  if p ? 'daily_enabled' and jsonb_typeof(p->'daily_enabled') is distinct from 'boolean' then perform booking._err('invalid_setting', 'daily_enabled on totuusarvo'); end if;
  if p ? 'vat_status' then vat := btrim(coalesce(p->>'vat_status', ''));
  else vat := btrim(coalesce(cur.settings->>'vat_status', '')); end if;
  if vat <> '' and vat !~ '^[0-9]{1,4}$' then perform booking._err('invalid_setting', 'ALV-tila on 1–4 numeroa'); end if;
  prefix := btrim(coalesce(nullif(p->>'api_prefix', ''), cur.settings->>'api_prefix', '/supported/api'));
  if prefix !~ '^/api$|^/latest/api$|^/supported/api$|^/v[0-9]{4}/api$' then perform booking._err('invalid_setting', 'API-etuliite ei kelpaa'); end if;
  if p ? 'bank_account' then iban := upper(regexp_replace(coalesce(p->>'bank_account', ''), '\s', '', 'g'));
  else iban := coalesce(cur.settings->>'bank_account', ''); end if;
  if iban <> '' and iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then perform booking._err('invalid_setting', 'Tilinumero on IBAN tai tyhjä'); end if;
  accounts := coalesce(p->'accounts', '{}'::jsonb);
  if jsonb_typeof(accounts) <> 'object' then perform booking._err('invalid_setting', 'accounts on objekti'); end if;
  rounding := btrim(coalesce(accounts->>'rounding', ''));
  if rounding <> '' and rounding !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
  if accounts ? 'sales_by_vat' then
    if jsonb_typeof(accounts->'sales_by_vat') <> 'object' then perform booking._err('invalid_setting', 'sales_by_vat on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'sales_by_vat') loop
      if not (k = any (rates)) then perform booking._err('invalid_setting', 'Tuntematon ALV-kanta: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then sales := sales || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if accounts ? 'clearing_by_method' then
    if jsonb_typeof(accounts->'clearing_by_method') <> 'object' then perform booking._err('invalid_setting', 'clearing_by_method on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'clearing_by_method') loop
      if not (k = any (methods)) then perform booking._err('invalid_setting', 'Tuntematon maksutapa: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then clearing := clearing || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if v_mode = 'live' and (vat !~ '^[0-9]{1,4}$' or sales = '{}'::jsonb or clearing = '{}'::jsonb) then
    perform booking._err('live_incomplete', 'Yhdistetty tila vaatii ALV-tilan, vähintään yhden myyntitilin ja maksutavan tilin');
  end if;
  s := coalesce(cur.settings, '{}'::jsonb)
    || jsonb_build_object(
         'environment', env,
         'daily_enabled', case when p ? 'daily_enabled' then (p->>'daily_enabled')::boolean else coalesce((cur.settings->>'daily_enabled')::boolean, false) end,
         'api_prefix', prefix,
         'vat_status', vat,
         'approved_by', nullif(approved, ''),
         'bank_account', nullif(iban, ''),
         'accounts', jsonb_build_object('rounding', nullif(rounding, ''), 'sales_by_vat', sales, 'clearing_by_method', clearing));
  s := jsonb_strip_nulls(s);
  update booking.integration_config
     set mode = v_mode, settings = s, updated_by = auth.uid()
   where key = 'procountor';
  return booking.admin_get_procountor_settings();
end $function$;
create or replace function booking.public_checkout_payment_options() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_on text := booking._montonio_mode();
  v_gc boolean := coalesce((booking._setting('gift_cards.redeem_enabled', 'false'::jsonb) #>> '{}')::boolean, false);
  v_m jsonb := '[]'::jsonb;
begin
  if v_on <> 'off' then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'online', 'kind', 'online', 'provider', 'montonio', 'label', 'Maksa verkossa', 'label_en', 'Pay online', 'test', v_on in ('test', 'dry_run'),
      'choices', jsonb_build_array(
        jsonb_build_object('method', 'paymentInitiation', 'label', 'Verkkopankki', 'label_en', 'Online bank'),
        jsonb_build_object('method', 'cardPayments', 'label', 'Kortti', 'label_en', 'Card'),
        jsonb_build_object('method', 'applePay', 'label', 'Apple Pay', 'label_en', 'Apple Pay'),
        jsonb_build_object('method', 'googlePay', 'label', 'Google Pay', 'label_en', 'Google Pay'),
        jsonb_build_object('method', 'mobilePay', 'label', 'MobilePay', 'label_en', 'MobilePay')),
      'start', jsonb_build_object('function', 'montonio-start', 'method', 'POST', 'body', jsonb_build_object('order_token', '<tilauksen public_token>'))));
  end if;
  if v_gc then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'gift_card', 'kind', 'redeem', 'provider', 'gift_card', 'label', 'Lahjakortti', 'label_en', 'Gift card', 'test', false,
      'check_rpc', 'public_check_gift_card', 'apply_rpc', 'public_apply_gift_card'));
  end if;
  if booking._pay_later_test_enabled() then v_m := v_m || jsonb_build_array(booking._pay_later_method_json()); end if;
  return jsonb_build_object('ok', true, 'methods', v_m, 'mobilepay_enabled', false, 'vismapay_enabled', false, 'online_enabled', v_on <> 'off', 'gift_card_redeem_enabled', v_gc, 'pay_later_test_enabled', booking._pay_later_test_enabled(),
    'hold_until_paid', (booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}') <> 'pay_later', 'hold_minutes', booking._checkout_hold_minutes(),
    'group_threshold_persons', booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000), 'group_hold_days', booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60));
end $$;
create or replace function booking._checkout_online_available() returns boolean language sql stable security definer set search_path = '' as $$
  select booking._montonio_mode() <> 'off'
$$;
create or replace function booking._order_mp_inflight(p_order bigint) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from booking.payments p
     where p.order_id = p_order and p.status = 'pending' and p.provider_ref is not null
       and (
         (p.provider = 'mobilepay'
           and coalesce(p.raw #>> '{mobilepay,last_state}', 'CREATED') in ('CREATED', 'AUTHORIZED')
           and coalesce(nullif(p.raw #>> '{mobilepay,attempt_started_at}', '')::timestamptz, p.created_at)
               > now() - make_interval(mins => booking._checkout_cfg_int('checkout_mobilepay_grace_minutes', 15, 0, 60)))
         or
         (p.provider = 'montonio'
           and coalesce(p.raw ->> 'last_state', 'CREATED') in ('CREATED', 'PENDING', 'AUTHORIZED')
           and coalesce(nullif(p.raw ->> 'attempt_started_at', '')::timestamptz, p.created_at)
               > now() - make_interval(mins => booking._checkout_cfg_int('checkout_mobilepay_grace_minutes', 15, 0, 60)))
       ))
$$;
CREATE OR REPLACE FUNCTION booking.montonio_payment_apply(p_order_number text, p_outcome text, p_amount numeric DEFAULT NULL::numeric, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_178: (1) maksulinkki (link_expires_at - created_at > 2 h, eli _create_link_payment; booking_184: myös takarajaton linkki = link_expires_at null
-- ja raw.paylink = 'no_deadline'; verkkokaupan maksurivi, jolla link_expires_at null ilman merkintää, EI ole linkki) EI kulu peruttuun/hylättyyn Visma-yritykseen: maksu jää
-- pending-tilaan, vanha Visma-token/ohjausosoite poistetaan (vismapay_payment_prepare luo seuraavalla painalluksella uuden yrityksen -a<n+1>), kun linkki on
-- voimassa, ei korvattu ja tilauksella on maksettavaa (summa ≤ maksamatta). Muuten ja verkkokaupan tavallisessa maksussa kuten ennen (cancelled/failed).
-- (2) vanhan yrityksen tilausnumero löytyy booking.montonio_attempts-taulusta: myöhästynyt "maksettu" kirjataan samalle maksuriville täsmälleen kerran
-- (provider_ref vaihdetaan maksaneeseen yritykseen, jotta hyvitys osuu oikeaan Visma-tilaukseen); jos rivi on jo maksettu toisella yrityksellä, maksua ei
-- kirjata toista kertaa vaan tilaukselle merkitään TUPLAVELOITUS tarkistettavaksi (outcome needs_review, code duplicate_paid). Vanhan yrityksen
-- peruutus/hylkäys ei muuta maksua.
declare
  pay booking.payments; att booking.montonio_attempts;
  v_raw jsonb := coalesce(p_raw, '{}'::jsonb); v_res jsonb; v_current boolean; v_unpaid numeric; v_why text; v_prev text;
begin
  if p_order_number is null or p_order_number !~ '^sauna-[a-z0-9_-]+$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  if p_outcome is null or p_outcome not in ('paid', 'failed', 'cancelled', 'pending', 'authorized', 'needs_review') then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  select * into pay from booking.payments where provider = 'montonio' and provider_ref = p_order_number for update;
  if not found then
    select * into att from booking.montonio_attempts where order_number = p_order_number;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    select * into pay from booking.payments where id = att.payment_id and provider = 'montonio' for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  end if;
  select * into att from booking.montonio_attempts where order_number = p_order_number for update;
  v_current := pay.provider_ref is not distinct from p_order_number;

  if pay.status in ('paid', 'partially_refunded', 'refunded') then
    if p_outcome = 'paid' and not v_current then
      -- sama maksurivi on jo maksettu toisella Visma-yrityksellä → ei toista kirjausta; rahat palautetaan käsin
      if att.outcome is distinct from 'duplicate_paid' then
        update booking.montonio_attempts set outcome = 'duplicate_paid', outcome_at = now() where order_number = p_order_number;
        update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'VERKKOMAKSU: TUPLAVELOITUS – maksu ' || coalesce(pay.provider_ref, '?')
               || ' on jo kirjattu, myös ' || p_order_number || ' maksettiin. Palauta ' || p_order_number || ' verkkomaksun hallinnasta.' where id = pay.order_id;
        insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
        values (null, 'service_role', 'payments', pay.id::text, 'MONTONIO_DUPLICATE_PAID',
                jsonb_build_object('order_number', p_order_number, 'paid_order_number', pay.provider_ref, 'reported', p_amount, 'payment_status', pay.status));
      end if;
      return jsonb_build_object('ok', true, 'already', true, 'outcome', 'needs_review', 'code', 'duplicate_paid');
    end if;
    if pay.status = 'paid' or p_outcome = 'paid' then
      return jsonb_build_object('ok', true, 'already', true, 'outcome', 'paid');
    end if;
  end if;
  if pay.status in ('failed', 'cancelled', 'refunded') and p_outcome in ('failed', 'cancelled', 'pending', 'authorized') then
    if not v_current and p_outcome in ('failed', 'cancelled') and att.order_number is not null and att.outcome is null then
      update booking.montonio_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
    end if;
    return jsonb_build_object('ok', true, 'unchanged', true, 'outcome', pay.status);
  end if;

  if p_outcome = 'paid' then
    if p_amount is null or round(p_amount * 100) <> round(pay.amount * 100) then
      update booking.payments set provider_status = 'amount_mismatch', raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('amount_mismatch', true, 'reported_amount', p_amount) where id = pay.id;
      update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'VERKKOMAKSU: summa ei täsmää, maksua ei merkitty maksetuksi (' || p_order_number || ')' where id = pay.order_id;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, 'service_role', 'payments', pay.id::text, 'MONTONIO_AMOUNT_MISMATCH', jsonb_build_object('order_number', p_order_number, 'reported', p_amount, 'expected', pay.amount));
      return jsonb_build_object('ok', true, 'outcome', 'needs_review', 'code', 'amount_mismatch');
    end if;
    if not v_current then
      -- myöhästynyt maksu vanhalle yritykselle: rivi siirretään maksaneeseen tilausnumeroon (uudempi yritys merkitään korvatuksi triggerissä)
      v_prev := pay.provider_ref;
      update booking.payments
         set provider_ref = p_order_number,
             link_url = case when link_url like 'https://%.montonio.com/%' or link_url like 'https://montonio.com/%' then null else link_url end,
             raw = (coalesce(raw, '{}'::jsonb) - 'token' - 'redirect_url' - 'token_valid_until') || jsonb_build_object('last_state', 'late_paid', 'replaced_ref', v_prev)
       where id = pay.id;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, 'service_role', 'payments', pay.id::text, 'MONTONIO_LATE_PAID', jsonb_build_object('order_number', p_order_number, 'superseded', v_prev, 'status_before', pay.status));
    end if;
    -- payment_mark_paid korvaa raw'n: yhdistä aiempi raw (order_uuid CREATED-tapahtumasta) ja ilmoituksen kentät.
    v_raw := (coalesce((select p2.raw from booking.payments p2 where p2.id = pay.id), '{}'::jsonb) - 'email' - 'customer' - 'accessKey' - 'secretKey' - 'senderName' - 'senderIban')
             || coalesce(p_raw, '{}'::jsonb);
    if nullif(btrim(coalesce(v_raw ->> 'order_uuid', '')), '') is null and nullif(btrim(coalesce(v_raw ->> 'uuid', '')), '') is not null then
      v_raw := v_raw || jsonb_build_object('order_uuid', v_raw ->> 'uuid');
    end if;
    v_res := booking.payment_mark_paid('montonio', p_order_number, pay.amount, v_raw || jsonb_build_object('source', v_raw -> 'source'));
    update booking.montonio_attempts set outcome = 'paid', outcome_at = now() where order_number = p_order_number;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'MONTONIO_PAID', jsonb_build_object('order_number', p_order_number, 'result', v_res));
    return v_res || jsonb_build_object('outcome', 'paid');
  elsif p_outcome = 'needs_review' then
    update booking.payments set provider_status = 'needs_review', raw = coalesce(raw, '{}'::jsonb) || v_raw where id = pay.id;
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'VERKKOMAKSU: maksu vaatii tarkistuksen (' || p_order_number || ')' where id = pay.order_id;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'MONTONIO_NEEDS_REVIEW', v_raw);
    return jsonb_build_object('ok', true, 'outcome', 'needs_review');
  elsif p_outcome in ('failed', 'cancelled') then
    if not v_current then
      -- vanha yritys peruttu/hylätty: maksu (ja sen uudempi yritys) ennallaan
      if att.order_number is not null and att.outcome is null then
        update booking.montonio_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
        insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
        values (null, 'service_role', 'payments', pay.id::text, 'MONTONIO_ATTEMPT_' || upper(p_outcome), v_raw || jsonb_build_object('order_number', p_order_number, 'current', pay.provider_ref));
      end if;
      return jsonb_build_object('ok', true, 'unchanged', true, 'stale', true, 'outcome', p_outcome);
    end if;
    if pay.status <> 'pending' then
      return jsonb_build_object('ok', true, 'unchanged', true, 'outcome', pay.status);
    end if;
    if pay.provider_status is not distinct from p_outcome and coalesce(pay.raw ->> 'retryable', '') = 'true' then
      return jsonb_build_object('ok', true, 'unchanged', true, 'retryable', true, 'outcome', p_outcome);
    end if;
    v_unpaid := coalesce((booking._order_balance(pay.order_id) ->> 'unpaid')::numeric, 0);
    if (case when pay.link_expires_at is null then coalesce(pay.raw ->> 'paylink', '') <> 'no_deadline'
             else pay.link_expires_at - pay.created_at <= interval '2 hours' end) then v_why := 'not_link';
    elsif pay.link_expires_at <= now() then v_why := 'link_expired';
    elsif exists (select 1 from booking.payments x where x.order_id = pay.order_id and x.id > pay.id and x.status not in ('cancelled', 'failed')) then v_why := 'replaced';
    elsif v_unpaid <= 0.004 then v_why := 'nothing_to_pay';
    elsif pay.amount > v_unpaid + 0.004 then v_why := 'link_stale';
    end if;
    if v_why is null then
      update booking.payments
         set provider_status = p_outcome,
             link_url = case when link_url like 'https://%.montonio.com/%' or link_url like 'https://montonio.com/%' then null else link_url end,
             raw = (coalesce(raw, '{}'::jsonb) - 'token' - 'redirect_url' - 'token_valid_until')
                   || jsonb_build_object('last_state', p_outcome, 'retryable', true, 'detail', v_raw - 'customer' - 'email')
       where id = pay.id;
      update booking.montonio_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, 'service_role', 'payments', pay.id::text, 'MONTONIO_' || upper(p_outcome) || '_RETRYABLE',
              v_raw || jsonb_build_object('order_number', p_order_number, 'attempt', att.attempt, 'link_expires_at', pay.link_expires_at));
      return jsonb_build_object('ok', true, 'outcome', p_outcome, 'retryable', true);
    end if;
    perform booking.payment_mark_failed('montonio', p_order_number, p_outcome, v_raw);
    update booking.montonio_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'MONTONIO_' || upper(p_outcome),
            case when v_why = 'not_link' then v_raw else v_raw || jsonb_build_object('retry_blocked', v_why) end);
    return jsonb_build_object('ok', true, 'outcome', p_outcome) || case when v_why = 'not_link' then '{}'::jsonb else jsonb_build_object('retryable', false, 'reason', v_why) end;
  else
    if not v_current then
      return jsonb_build_object('ok', true, 'unchanged', true, 'stale', true, 'outcome', p_outcome);
    end if;
    update booking.payments set provider_status = p_outcome, raw = coalesce(raw, '{}'::jsonb) || v_raw where id = pay.id and status = 'pending';
    return jsonb_build_object('ok', true, 'outcome', p_outcome);
  end if;
end $function$
;


drop trigger if exists integration_config_montonio_guard on booking.integration_config;
create trigger integration_config_montonio_guard before insert or update of mode, settings on booking.integration_config
  for each row execute function booking._montonio_guard_trg();
drop trigger if exists payments_montonio_attempt on booking.payments;
create trigger payments_montonio_attempt after insert or update of provider_ref on booking.payments
  for each row execute function booking._montonio_attempt_trg();

revoke all on function booking._montonio_guard_trg() from public, anon, authenticated;
revoke all on function booking._montonio_mode() from public, anon, authenticated;
revoke all on function booking._montonio_online() from public, anon, authenticated;
revoke all on function booking._montonio_attempt_trg() from public, anon, authenticated;
revoke all on function booking.montonio_payment_prepare(uuid,uuid,text) from public, anon, authenticated;
revoke all on function booking.montonio_payment_event(text,text,text,text,jsonb) from public, anon, authenticated;
revoke all on function booking.montonio_payment_lookup(text) from public, anon, authenticated;
revoke all on function booking.montonio_payment_apply(text,text,numeric,jsonb) from public, anon, authenticated;
revoke all on function booking.montonio_order_refs(uuid) from public, anon, authenticated;
revoke all on function booking.montonio_refund_claim(bigint,integer) from public, anon, authenticated;
revoke all on function booking.montonio_refund_stamp(bigint,text,text,jsonb) from public, anon, authenticated;
revoke all on function booking.montonio_refund_complete(bigint,text,jsonb) from public, anon, authenticated;
revoke all on function booking.montonio_refund_fail(bigint,jsonb) from public, anon, authenticated;
revoke all on function booking.montonio_refund_release(bigint,jsonb) from public, anon, authenticated;
revoke all on function booking.montonio_refund_lookup(text,text) from public, anon, authenticated;
grant execute on function booking.montonio_payment_prepare(uuid,uuid,text) to service_role;
grant execute on function booking.montonio_payment_event(text,text,text,text,jsonb) to service_role;
grant execute on function booking.montonio_payment_lookup(text) to service_role;
grant execute on function booking.montonio_payment_apply(text,text,numeric,jsonb) to service_role;
grant execute on function booking.montonio_order_refs(uuid) to service_role;
grant execute on function booking.montonio_refund_claim(bigint,integer) to service_role;
grant execute on function booking.montonio_refund_stamp(bigint,text,text,jsonb) to service_role;
grant execute on function booking.montonio_refund_complete(bigint,text,jsonb) to service_role;
grant execute on function booking.montonio_refund_fail(bigint,jsonb) to service_role;
grant execute on function booking.montonio_refund_release(bigint,jsonb) to service_role;
grant execute on function booking.montonio_refund_lookup(text,text) to service_role;
revoke all on function booking.admin_get_montonio_status() from public, anon;
revoke all on function booking.admin_set_montonio_mode(text,text) from public, anon;
grant execute on function booking.admin_get_montonio_status() to authenticated, service_role;
grant execute on function booking.admin_set_montonio_mode(text,text) to authenticated, service_role;

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_options(uuid)')));
  if v <> '2557c31f99a77e70e5a3f35a3c44304e' then raise exception 'booking_188: public_payment_options uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_get_order(uuid)')));
  if v <> '78d7b0b394dbd4d6d0a47a234d613159' then raise exception 'booking_188: public_get_order uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_link_info(uuid)')));
  if v <> '2c9e06b3153aa5c0edd25341024ae6a8' then raise exception 'booking_188: public_payment_link_info uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_link_payment(bigint,integer,text)')));
  if v <> 'adc14e6983e60d80498508c9b969f60d' then raise exception 'booking_188: _create_link_payment uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.montonio_payment_prepare(uuid,uuid,text)')));
  if v <> '438ba5857d711f4686e3665bacd0eb18' then raise exception 'booking_188: montonio_payment_prepare uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.montonio_payment_apply(text,text,numeric,jsonb)')));
  if v <> 'ef052d2d9baa94bbe8cc4a9e1784d0ed' then raise exception 'booking_188: montonio_payment_apply uusi md5=%', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._montonio_mode()')));
  if v <> 'bd80449b1c324f39825aad817a0e25be' then raise exception 'booking_188: _montonio_mode uusi md5=%', v; end if;
end $g$;
