-- booking_295: Pikakassan "Korttipääte (SumUp Solo)" – SumUp Cloud API + Solo-lukija (Payment Switch ja Tap to Pay eivät kuulu tähän).
-- EI AJETA TÄSTÄ HAARASTA: Bottiavustus ajaa ensin DEV, katselmoinnin jälkeen PROD.
-- Migraatio EI kytke tilaa päälle: integration_config.sumup.mode = 'off'. Off-tilassa Pikakassa ei näe maksutapaa lainkaan
-- (admin_pos_tenders suodattaa sumup-rivin pois) ja sumup-pos / sumup-notify kieltäytyvät kaikesta.
-- test = SumUpin sandbox-kauppiastili (Edge-salaisuus SUMUP_ENV = 'sandbox'), live = oikea tili (SUMUP_ENV = 'live'). Molemmat vaativat settings.approved_by.
-- CheckoutX (booking_286) piilotetaan Pikakassasta: admin_pos_tenders ei palauta checkoutx-käsittelijää enää koskaan. Taulut, funktiot ja data jäävät.
-- Avaimet vain Edge-salaisuuksina: SUMUP_API_KEY, SUMUP_AFFILIATE_KEY, SUMUP_AFFILIATE_APP_ID, SUMUP_MERCHANT_CODE, SUMUP_WEBHOOK_SECRET, SUMUP_ENV, SUMUP_API_URL (valinn.).
-- Kantaan vain tekniset lukija-id:t ja nimi. Maksun provider_ref = SumUpin client_transaction_id (checkoutin tunniste), raw.transaction_id = SumUpin transaktio-id.
-- Ei public-skeemaa. Maksun summa = tilauksen maksamaton osuus (booking._order_balance), kuten maksulinkissä ja CheckoutX:ssä.
-- Rollback: rollbacks/20261113190000_booking_295_ROLLBACK.sql. Testi: tests/pos/t295_sumup_pos.sql.
--
-- Korvattava (vanha -> uusi):
--   booking.admin_pos_tenders(): 864bc26d1e42f6cb36eaf06da46dd6e6 (booking_286) -> uusi md5 kirjataan, kun migraatio on ajettu paikallisessa PG:ssä (ei ajettu tässä ympäristössä).
set local lock_timeout = '5s';

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_tenders()')));
  if v is null or v <> '864bc26d1e42f6cb36eaf06da46dd6e6' then
    raise exception 'booking_295: admin_pos_tenders md5=% (odotettiin booking_286 864bc26d…). Ei muutoksia.', coalesce(v, 'puuttuu');
  end if;
  if to_regprocedure('booking.payment_mark_paid(text,text,numeric,jsonb)') is null then
    raise exception 'booking_295: payment_mark_paid puuttuu';
  end if;
  if exists (select 1 from booking.integration_config where key = 'sumup') then
    raise exception 'booking_295: integration_config sumup on jo olemassa';
  end if;
end $g$;

-- ---------- kytkin ----------
-- Sallittujen avainten lista luetaan nykyisestä rajoitteesta ja siihen lisätään sumup, jotta muissa migraatioissa lisätyt avaimet (esim. uutiskirje) eivät katoa.
do $c$
declare d_key text; d_test text;
begin
  select pg_get_constraintdef(oid) into d_key from pg_constraint where conrelid = 'booking.integration_config'::regclass and conname = 'integration_config_key_check';
  select pg_get_constraintdef(oid) into d_test from pg_constraint where conrelid = 'booking.integration_config'::regclass and conname = 'integration_config_test_only_online';
  if d_key is null or d_key not like '%''checkoutx''::text%' or d_test is null or d_test not like '%''checkoutx''::text%' then
    raise exception 'booking_295: integration_config-rajoitteet eivät ole odotetussa muodossa (key_check=%, test_only_online=%)', d_key, d_test;
  end if;
  execute 'alter table booking.integration_config drop constraint integration_config_key_check';
  execute 'alter table booking.integration_config add constraint integration_config_key_check ' || replace(d_key, '''checkoutx''::text', '''checkoutx''::text, ''sumup''::text');
  execute 'alter table booking.integration_config drop constraint integration_config_test_only_online';
  execute 'alter table booking.integration_config add constraint integration_config_test_only_online ' || replace(d_test, '''checkoutx''::text', '''checkoutx''::text, ''sumup''::text');
end $c$;
alter table booking.integration_config drop constraint if exists integration_config_sumup_modes;
alter table booking.integration_config add constraint integration_config_sumup_modes
  check (key <> 'sumup' or mode in ('off', 'test', 'live'));

insert into booking.integration_config(key, mode, settings, notes)
values ('sumup', 'off', jsonb_build_object('currency', 'EUR', 'provider', 'SumUp Solo (Cloud API)', 'partial_refund', false),
        'booking_295: Pikakassan korttipääte (SumUp Solo, Cloud API). off = pois; test = SumUp sandbox-tili; live = oikea tili. test ja live vaativat approved_by ja vastaavan Edge-salaisuuden SUMUP_ENV (sandbox/live). Avaimet vain Edge-salaisuuksina.');

insert into booking.payment_methods(code, label, is_manual, active, johku_codes, sort_order)
values ('sumup', 'Korttipääte (SumUp Solo)', false, false, '{}'::text[], 94)
on conflict (code) do nothing;

insert into booking.pos_tenders(code, handler, channels, active, sort_order, unavailable_reason)
values ('sumup', 'sumup', array['pos'], true, 14, null)
on conflict (code) do nothing;

-- ---------- paritetut lukijat ----------
create table booking.sumup_readers (
  reader_id   text primary key check (reader_id ~ '^[A-Za-z0-9_-]{4,64}$'),
  name        text not null check (char_length(btrim(name)) between 1 and 60),
  env         text not null check (env in ('test', 'live')),
  is_default  boolean not null default false,
  active      boolean not null default true,
  paired_by   uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index sumup_readers_one_default on booking.sumup_readers(env) where is_default and active;
comment on table booking.sumup_readers is 'booking_295: SumUp Solo -lukijat, jotka on paritettu Cloud API:lla. Vain tekniset id:t ja nimi. Ei henkilö-, kortti- eikä avaintietoja.';
alter table booking.sumup_readers enable row level security;
revoke all on table booking.sumup_readers from public, anon, authenticated;
grant all on table booking.sumup_readers to service_role;

-- ---------- apurit ----------
create or replace function booking._sumup_mode() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((select mode from booking.integration_config where key = 'sumup'), 'off')
$$;

create or replace function booking._sumup_guard_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.key = 'sumup' and new.mode in ('test', 'live') and coalesce(btrim(new.settings ->> 'approved_by'), '') = '' then
    raise exception 'SumUp-tilaa (%) ei voi kytkeä ilman settings.approved_by -merkintää', new.mode using errcode = 'BK001', detail = 'approval_required';
  end if;
  return new;
end $$;
drop trigger if exists integration_config_sumup_guard on booking.integration_config;
create trigger integration_config_sumup_guard before insert or update on booking.integration_config
  for each row when (new.key = 'sumup') execute function booking._sumup_guard_trg();

-- ---------- hallinta ----------
create or replace function booking.admin_get_sumup_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r booking.integration_config; v_mode text; v_readers jsonb;
begin
  perform booking._require_permission('pos.use');
  select * into r from booking.integration_config where key = 'sumup';
  v_mode := coalesce(r.mode, 'off');
  select coalesce(jsonb_agg(jsonb_build_object('reader_id', x.reader_id, 'name', x.name, 'is_default', x.is_default, 'created_at', x.created_at)
                            order by x.is_default desc, x.name, x.reader_id), '[]'::jsonb)
    into v_readers from booking.sumup_readers x where x.active and x.env = v_mode;
  return jsonb_build_object('ok', true, 'provider', 'SumUp Solo', 'mode', v_mode,
    'approved_by', nullif(btrim(coalesce(r.settings ->> 'approved_by', '')), ''),
    'enabled', v_mode in ('test', 'live'),
    'partial_refund', coalesce((r.settings ->> 'partial_refund')::boolean, false),
    'readers', v_readers,
    'secrets', jsonb_build_array('SUMUP_API_KEY', 'SUMUP_AFFILIATE_KEY', 'SUMUP_AFFILIATE_APP_ID', 'SUMUP_MERCHANT_CODE', 'SUMUP_WEBHOOK_SECRET', 'SUMUP_ENV'));
end $$;

create or replace function booking.admin_set_sumup_mode(p_mode text, p_approved_by text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_old text; v_by text := nullif(btrim(coalesce(p_approved_by, '')), '');
begin
  perform booking._require_permission('settings.edit');
  if p_mode is null or p_mode not in ('off', 'test', 'live') then
    perform booking._err('invalid_param', 'SumUp-tila on off, test tai live');
  end if;
  if p_mode in ('test', 'live') and v_by is null then
    perform booking._err('approval_required', 'Tila vaatii merkinnän kuka kytki sen päälle');
  end if;
  if p_mode = 'live' and booking.current_staff_role() is distinct from 'admin' then
    perform booking._err('forbidden', 'Live-tilan kytkee vain admin');
  end if;
  select mode into v_old from booking.integration_config where key = 'sumup';
  update booking.integration_config
     set mode = p_mode,
         settings = case when p_mode in ('test', 'live') then settings || jsonb_build_object('approved_by', v_by) else settings end
   where key = 'sumup';
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'integration_config', 'sumup', 'SUMUP_MODE',
          jsonb_build_object('mode', v_old), jsonb_build_object('mode', p_mode, 'approved_by', v_by));
  return booking.admin_get_sumup_status();
end $$;

create or replace function booking.admin_sumup_reader_remove(p_reader_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  perform booking._require_permission('settings.edit');
  update booking.sumup_readers set active = false, is_default = false, updated_at = now() where reader_id = p_reader_id;
  if not found then perform booking._err('not_found', 'Lukijaa ei löydy'); end if;
  return jsonb_build_object('ok', true, 'reader_id', p_reader_id);
end $$;

create or replace function booking.admin_sumup_reader_set_default(p_reader_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_env text;
begin
  perform booking._require_permission('settings.edit');
  select env into v_env from booking.sumup_readers where reader_id = p_reader_id and active;
  if not found then perform booking._err('not_found', 'Lukijaa ei löydy'); end if;
  update booking.sumup_readers set is_default = false, updated_at = now() where env = v_env and is_default and reader_id <> p_reader_id;
  update booking.sumup_readers set is_default = true, updated_at = now() where reader_id = p_reader_id;
  return jsonb_build_object('ok', true, 'reader_id', p_reader_id);
end $$;

-- ---------- Edge (service_role) ----------
create or replace function booking.sumup_reader_save(p_reader_id text, p_name text, p_actor uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_name text := left(btrim(coalesce(p_name, '')), 60); v_mode text := booking._sumup_mode();
begin
  if v_mode not in ('test', 'live') then perform booking._err('sumup_off', 'Korttipääte ei ole käytössä'); end if;
  if p_reader_id is null or p_reader_id !~ '^[A-Za-z0-9_-]{4,64}$' then perform booking._err('invalid_param', 'Virheellinen lukijan tunnus'); end if;
  if v_name = '' then v_name := 'Lukija ' || right(p_reader_id, 4); end if;
  insert into booking.sumup_readers(reader_id, name, env, active, is_default, paired_by)
  values (p_reader_id, v_name, v_mode, true,
          not exists (select 1 from booking.sumup_readers x where x.env = v_mode and x.active and x.is_default), p_actor)
  on conflict (reader_id) do update set name = excluded.name, env = excluded.env, active = true, updated_at = now();
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (p_actor, booking._jwt_role(), 'sumup_readers', p_reader_id, 'SUMUP_READER', jsonb_build_object('name', v_name, 'env', v_mode));
  return jsonb_build_object('ok', true, 'reader_id', p_reader_id, 'name', v_name);
end $$;

-- Aloitus: luo avoimen maksurivin. Aiemmat avoimet SumUp-yritykset samalle tilaukselle merkitään korvatuiksi (Edge päättää lukijan checkoutin terminate-kutsulla).
create or replace function booking.sumup_pos_prepare(p_order_id bigint, p_reader_id text, p_actor uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; v_amount numeric; v_id bigint; v_mode text := booking._sumup_mode(); v_old jsonb;
begin
  if v_mode not in ('test', 'live') then perform booking._err('sumup_off', 'Korttipääte ei ole käytössä'); end if;
  if not exists (select 1 from booking.sumup_readers r where r.reader_id = p_reader_id and r.active and r.env = v_mode) then
    perform booking._err('reader_not_paired', 'Lukijaa ei ole paritettu');
  end if;
  select * into o from booking.orders where id = p_order_id and source_channel = 'pikakassa' for update;
  if not found then perform booking._err('not_found', 'Kassatilausta ei löydy'); end if;
  if o.status is distinct from 'pending' or o.payment_status not in ('unpaid', 'pending') then
    perform booking._err('order_not_payable', 'Tilausta ei voi enää maksaa');
  end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.provider not in ('manual', 'sumup')
               and (p.link_expires_at is null or p.link_expires_at > now())) then
    perform booking._err('payment_in_progress', 'Tilauksella on jo avoin maksu toisella maksutavalla');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('reader_id', p.raw ->> 'reader_id', 'client_transaction_id', p.provider_ref)), '[]'::jsonb) into v_old
    from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.provider = 'sumup' and p.provider_ref is not null;
  update booking.payments set status = 'cancelled', provider_status = coalesce(provider_status, 'superseded'),
         note = concat_ws(' | ', note, 'korvattu uudella SumUp-yrityksellä')
   where order_id = o.id and status = 'pending' and provider = 'sumup';
  v_amount := round(((booking._order_balance(o.id)) ->> 'unpaid')::numeric, 2);
  if v_amount is null or v_amount <= 0.004 then perform booking._err('nothing_to_pay', 'Ei maksettavaa'); end if;
  insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, raw, note, created_by)
  values (o.id, 'sumup', 'sumup', 'pending', v_amount, o.currency, now() + interval '15 minutes',
          jsonb_build_object('reader_id', p_reader_id, 'env', v_mode), 'pikakassa', p_actor)
  returning id into v_id;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'order_id', o.id, 'order_no', o.order_no,
    'amount', v_amount, 'currency', o.currency, 'reader_id', p_reader_id, 'mode', v_mode, 'superseded', v_old);
end $$;

-- Checkout lähti lukijalle: client_transaction_id talteen (provider_ref).
create or replace function booking.sumup_pos_started(p_payment_id bigint, p_client_tx_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments;
begin
  if p_client_tx_id is null or p_client_tx_id !~ '^[A-Za-z0-9_-]{4,64}$' then perform booking._err('invalid_param', 'Virheellinen checkout-tunnus'); end if;
  select * into pay from booking.payments where id = p_payment_id and provider = 'sumup' for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  if pay.status <> 'pending' then perform booking._err('payment_not_pending', 'Maksu ei ole avoin'); end if;
  if pay.provider_ref is not null and pay.provider_ref <> p_client_tx_id then perform booking._err('ref_conflict', 'Maksulla on jo toinen checkout-tunnus'); end if;
  update booking.payments
     set provider_ref = p_client_tx_id, provider_status = 'PENDING',
         raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('client_transaction_id', p_client_tx_id)
   where id = pay.id;
  return jsonb_build_object('ok', true, 'payment_id', pay.id);
end $$;

create or replace function booking._sumup_lookup_json(pay booking.payments)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders;
begin
  select * into o from booking.orders where id = pay.order_id;
  return jsonb_build_object('ok', true, 'payment_id', pay.id, 'order_id', pay.order_id, 'order_no', o.order_no,
    'status', pay.status, 'provider_status', pay.provider_status, 'amount', pay.amount, 'currency', pay.currency,
    'client_transaction_id', pay.provider_ref, 'transaction_id', pay.raw ->> 'transaction_id', 'reader_id', pay.raw ->> 'reader_id',
    'order_status', o.status, 'order_payment_status', o.payment_status, 'source_channel', o.source_channel);
end $$;

create or replace function booking.sumup_pos_lookup(p_payment_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare pay booking.payments;
begin
  select * into pay from booking.payments where id = p_payment_id and provider = 'sumup';
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  return booking._sumup_lookup_json(pay);
end $$;

-- Webhook löytää maksun SumUpin client_transaction_id:llä.
create or replace function booking.sumup_pos_lookup_ref(p_client_tx_id text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare pay booking.payments;
begin
  select * into pay from booking.payments where provider = 'sumup' and provider_ref = p_client_tx_id;
  if not found then return jsonb_build_object('ok', true, 'found', false); end if;
  return booking._sumup_lookup_json(pay) || jsonb_build_object('found', true);
end $$;

-- p_outcome: paid | failed | cancelled.
-- paid vaatii p_confirmed_by = 'api' (Edge on lukenut tilan SumUpin rajapinnasta; webhook yksin ei riitä) ja rajapinnan vahvistaman summan.
create or replace function booking.sumup_pos_apply(p_payment_id bigint, p_outcome text, p_transaction_id text default null,
                                                    p_confirmed_by text default null, p_amount numeric default null, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments; v jsonb; v_raw jsonb;
begin
  if p_outcome is null or p_outcome not in ('paid', 'failed', 'cancelled') then perform booking._err('invalid_param', 'Tuntematon lopputulos'); end if;
  select * into pay from booking.payments where id = p_payment_id and provider = 'sumup' for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  if pay.provider_ref is null then perform booking._err('payment_not_started', 'Maksua ei ole aloitettu'); end if;
  if p_outcome = 'paid' then
    if p_confirmed_by is distinct from 'api' then perform booking._err('not_confirmed', 'Maksua ei voi merkitä maksetuksi ilman SumUpin rajapinnan vahvistusta'); end if;
    if p_amount is null then perform booking._err('invalid_param', 'Vahvistettu summa puuttuu'); end if;
    if p_transaction_id is not null and p_transaction_id !~ '^[A-Za-z0-9_-]{4,64}$' then perform booking._err('invalid_param', 'Virheellinen transaktiotunnus'); end if;
    if pay.status = 'paid' then return jsonb_build_object('ok', true, 'already', true, 'status', 'paid'); end if;
    update booking.payments
       set raw = coalesce(raw, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('transaction_id', p_transaction_id, 'confirmed_by', 'api', 'sumup_status', p_raw))
     where id = pay.id;
    select raw into v_raw from booking.payments where id = pay.id;
    v := booking.payment_mark_paid('sumup', pay.provider_ref, p_amount, v_raw);
    update booking.payments set provider_status = 'SUCCESSFUL' where id = pay.id;
    return coalesce(v, '{}'::jsonb) || jsonb_build_object('status', 'paid', 'payment_id', pay.id);
  end if;
  if pay.status <> 'pending' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', pay.status); end if;
  update booking.payments
     set status = p_outcome, provider_status = upper(case when p_outcome = 'failed' then 'FAILED' else 'CANCELLED' end),
         raw = coalesce(raw, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('sumup_status', p_raw)),
         note = concat_ws(' | ', note, case when p_outcome = 'failed' then 'SumUp-maksu epäonnistui' else 'SumUp-maksu peruttiin' end)
   where id = pay.id;
  perform booking._refresh_order_payment(pay.order_id);
  return jsonb_build_object('ok', true, 'status', p_outcome, 'payment_id', pay.id);
end $$;

-- Checkoutin luonti lukijalle epäonnistui: avoin rivi pois.
create or replace function booking.sumup_pos_create_failed(p_payment_id bigint, p_detail jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments;
begin
  select * into pay from booking.payments where id = p_payment_id and provider = 'sumup' for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  if pay.status <> 'pending' or pay.provider_ref is not null then return jsonb_build_object('ok', true, 'unchanged', true, 'status', pay.status); end if;
  update booking.payments set status = 'failed', provider_status = 'create_failed',
         raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('create_error', coalesce(p_detail, '{}'::jsonb))
   where id = pay.id;
  perform booking._refresh_order_payment(pay.order_id);
  return jsonb_build_object('ok', true, 'status', 'failed');
end $$;

-- ---------- hyvitys: admin_refund luo rivin provider='sumup' status='requested' (tila test/live). Edge kutsuu SumUpin refund-rajapintaa. ----------
create or replace function booking.sumup_refund_claim(p_refund_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_rows jsonb; v_partial boolean;
begin
  if booking._sumup_mode() not in ('test', 'live') then
    return jsonb_build_object('ok', true, 'claimed', '[]'::jsonb, 'mode', booking._sumup_mode());
  end if;
  select coalesce((settings ->> 'partial_refund')::boolean, false) into v_partial from booking.integration_config where key = 'sumup';
  with c as (
    select f.id from booking.refunds f
     where f.provider = 'sumup' and f.id = p_refund_id
       and (f.status = 'requested' or (f.status = 'processing' and f.updated_at < now() - interval '10 minutes'))
     for update skip locked),
  u as (
    update booking.refunds f set status = 'processing', provider_status = 'processing', updated_at = now()
      from c where f.id = c.id returning f.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'refund_id', u.id, 'payment_id', u.payment_id, 'amount', u.amount, 'payment_amount', p.amount,
           'refunded_amount', p.refunded_amount, 'paid_at', p.paid_at, 'currency', p.currency,
           'client_transaction_id', p.provider_ref, 'transaction_id', p.raw ->> 'transaction_id') order by u.id), '[]'::jsonb) into v_rows
    from u join booking.payments p on p.id = u.payment_id;
  return jsonb_build_object('ok', true, 'claimed', v_rows, 'mode', booking._sumup_mode(), 'partial_refund', coalesce(v_partial, false));
end $$;

create or replace function booking.sumup_refund_complete(p_refund_id bigint, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds; pay booking.payments;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'sumup' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  if rf.status not in ('requested', 'processing') then perform booking._err('refund_not_pending', 'Hyvitys ei ole käsiteltävänä'); end if;
  select * into pay from booking.payments where id = rf.payment_id for update;
  update booking.refunds
     set status = 'done', provider_status = 'refunded',
         provider_refund_id = coalesce(provider_refund_id, 'sumup-' || coalesce(pay.raw ->> 'transaction_id', pay.provider_ref)),
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
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (null, 'service_role', 'refunds', rf.id::text, 'SUMUP_REFUND', jsonb_build_object('amount', rf.amount, 'payment_id', pay.id));
  return jsonb_build_object('ok', true, 'refund_id', rf.id);
end $$;

create or replace function booking.sumup_refund_fail(p_refund_id bigint, p_error jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'sumup' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status not in ('requested', 'processing') then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  update booking.refunds set status = 'failed', provider_status = 'failed', raw = jsonb_build_object('error', p_error, 'at', now()), updated_at = now() where id = rf.id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (null, 'service_role', 'refunds', rf.id::text, 'SUMUP_REFUND_FAIL', coalesce(p_error, '{}'::jsonb));
  return jsonb_build_object('ok', true, 'status', 'failed');
end $$;

-- ---------- Pikakassan maksutavat: checkoutx piilossa aina, sumup vain tiloissa test/live ----------
CREATE OR REPLACE FUNCTION booking.admin_pos_tenders()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_base text := rtrim(coalesce(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', ''), '/');
        v_cx text := booking._checkoutx_mode();
        v_su text := booking._sumup_mode();
begin
  perform booking._require_permission('pos.use');
  return jsonb_build_object(
    'montonio_mode', booking._montonio_mode(),
    'mobilepay_mode', booking._mobilepay_mode(),
    'vismapay_mode', coalesce((select mode from booking.integration_config where key = 'vismapay'), 'off'),
    'checkoutx_mode', v_cx,
    'sumup_mode', v_su,
    'site_base_url', v_base,
    'drinks_path', booking._drinks_path('fi'),
    'drinks_path_en', booking._drinks_path('en'),
    'tenders', coalesce((select jsonb_agg(jsonb_build_object(
        'code', t.code, 'handler', t.handler, 'channels', to_jsonb(t.channels), 'active', t.active,
        'sort_order', t.sort_order, 'unavailable_reason', t.unavailable_reason) order by t.sort_order, t.code)
      from booking.pos_tenders t
     where t.handler <> 'checkoutx' and (t.handler <> 'sumup' or v_su in ('test', 'live'))), '[]'::jsonb));
end $function$
;

-- ---------- oikeudet ----------
revoke all on function booking._sumup_mode() from public, anon, authenticated;
grant execute on function booking._sumup_mode() to service_role;
revoke all on function booking._sumup_guard_trg() from public, anon, authenticated;
revoke all on function booking._sumup_lookup_json(booking.payments) from public, anon, authenticated;
grant execute on function booking._sumup_lookup_json(booking.payments) to service_role;
revoke all on function booking.admin_get_sumup_status() from public, anon;
grant execute on function booking.admin_get_sumup_status() to authenticated, service_role;
revoke all on function booking.admin_set_sumup_mode(text,text) from public, anon;
grant execute on function booking.admin_set_sumup_mode(text,text) to authenticated, service_role;
revoke all on function booking.admin_sumup_reader_remove(text) from public, anon;
grant execute on function booking.admin_sumup_reader_remove(text) to authenticated, service_role;
revoke all on function booking.admin_sumup_reader_set_default(text) from public, anon;
grant execute on function booking.admin_sumup_reader_set_default(text) to authenticated, service_role;
revoke all on function booking.sumup_reader_save(text,text,uuid) from public, anon, authenticated;
grant execute on function booking.sumup_reader_save(text,text,uuid) to service_role;
revoke all on function booking.sumup_pos_prepare(bigint,text,uuid) from public, anon, authenticated;
grant execute on function booking.sumup_pos_prepare(bigint,text,uuid) to service_role;
revoke all on function booking.sumup_pos_started(bigint,text) from public, anon, authenticated;
grant execute on function booking.sumup_pos_started(bigint,text) to service_role;
revoke all on function booking.sumup_pos_lookup(bigint) from public, anon, authenticated;
grant execute on function booking.sumup_pos_lookup(bigint) to service_role;
revoke all on function booking.sumup_pos_lookup_ref(text) from public, anon, authenticated;
grant execute on function booking.sumup_pos_lookup_ref(text) to service_role;
revoke all on function booking.sumup_pos_apply(bigint,text,text,text,numeric,jsonb) from public, anon, authenticated;
grant execute on function booking.sumup_pos_apply(bigint,text,text,text,numeric,jsonb) to service_role;
revoke all on function booking.sumup_pos_create_failed(bigint,jsonb) from public, anon, authenticated;
grant execute on function booking.sumup_pos_create_failed(bigint,jsonb) to service_role;
revoke all on function booking.sumup_refund_claim(bigint) from public, anon, authenticated;
grant execute on function booking.sumup_refund_claim(bigint) to service_role;
revoke all on function booking.sumup_refund_complete(bigint,jsonb) from public, anon, authenticated;
grant execute on function booking.sumup_refund_complete(bigint,jsonb) to service_role;
revoke all on function booking.sumup_refund_fail(bigint,jsonb) from public, anon, authenticated;
grant execute on function booking.sumup_refund_fail(bigint,jsonb) to service_role;
revoke all on function booking.admin_pos_tenders() from public, anon;
grant execute on function booking.admin_pos_tenders() to authenticated, service_role;

do $g$
begin
  if booking._sumup_mode() <> 'off' then raise exception 'booking_295: sumup-tilan pitää olla off'; end if;
  if not exists (select 1 from booking.pos_tenders where code = 'sumup' and handler = 'sumup') then raise exception 'booking_295: pos_tenders sumup puuttuu'; end if;
end $g$;
