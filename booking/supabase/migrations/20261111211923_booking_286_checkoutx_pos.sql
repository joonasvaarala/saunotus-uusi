-- booking_286: Pikakassan "Kortti puhelimella (CheckoutX)" – Surfboard Payments / Worldline CheckoutX (SoftPOS, inter-app).
-- VAIN TESTIYMPÄRISTÖÖN (DEV aoejjmfzulhkhxbehphs). Migraatio EI kytke tilaa päälle: integration_config.checkoutx.mode = 'off'.
-- Tuotannossa (mode off) Pikakassa ei näe uutta maksutapaa lainkaan: admin_pos_tenders suodattaa checkoutx-rivin pois,
-- ja checkoutx-pos-Edge kieltäytyy kaikesta, ellei tila ole 'test' JA salaisuus CHECKOUTX_ENV = 'demo'.
-- admin_set_checkoutx_mode hyväksyy vain off/test: live-tilaa ei tässä versiossa ole.
-- Avaimet vain Edge-salaisuuksina: SURFBOARD_API_URL, SURFBOARD_API_KEY, SURFBOARD_API_SECRET, SURFBOARD_MERCHANT_ID, SURFBOARD_STORE_ID, CHECKOUTX_ENV.
-- Ei public-skeemaa. Hinnat/ALV ennallaan: maksun summa on tilauksen maksamaton osuus (booking._order_balance), sama kuin maksulinkissä.
-- Rollback: rollbacks/20261111203000_booking_286_ROLLBACK.sql. Testi: tests/pos/t286_checkoutx_pos.sql.
--
-- Korvattava (vanha -> uusi):
--   booking.admin_pos_tenders(): 443e6462ede3ec9d3118d08be43759fa (booking_189) -> 864bc26d1e42f6cb36eaf06da46dd6e6: lisää checkoutx_mode ja suodattaa checkoutx-käsittelijän pois, kun tila ei ole test.
--
-- Uudet funktiot, md5(pg_get_functiondef) paikallisessa PG:ssä migraation jälkeen:
--   booking._checkoutx_guard_trg()                    9f9372ef604094ed12c617e751d309f9
--   booking._checkoutx_mode()                         aa16b701fe910d5f1770a9aa522fac38
--   booking.admin_checkoutx_terminal_remove(text)     afc3136912df435a9735ea10c03eeb23
--   booking.admin_get_checkoutx_status()              17063f3620b0c327de68bff129f1b755
--   booking.admin_set_checkoutx_mode(text,text)       2583bf33a8608b4debbcc5bcb695b064
--   booking.checkoutx_pos_apply(bigint,text,text,jsonb) 6b0bfca3b7132bdfc60a89a1cba6312d
--   booking.checkoutx_pos_create_failed(bigint,jsonb) dd6148f93bdd8b981b5495351920d7d8
--   booking.checkoutx_pos_created(bigint,text,text)   d2458f73709aa96f556499dbbcb9eda7
--   booking.checkoutx_pos_lookup(bigint)              bc7ba21ad6adf2131ec86d1b1d253b09
--   booking.checkoutx_pos_prepare(bigint,text,uuid)   3dc2ff5b8472d58f572bb45fd983a3a4
--   booking.checkoutx_refund_claim(bigint)            2c03d1d07d500934e9746a6202941de2
--   booking.checkoutx_refund_complete(bigint,jsonb)   de90f677ae17232ad7e9a195bc3ba237
--   booking.checkoutx_refund_fail(bigint,jsonb)       d7d8ed9ad5e75f2d9abde12efd46a6fa
--   booking.checkoutx_terminal_save(text,text,uuid)   48009013778d3990630f1653728a2cd4
set local lock_timeout = '5s';

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_tenders()')));
  if v is null or v <> '443e6462ede3ec9d3118d08be43759fa' then
    raise exception 'booking_286: admin_pos_tenders md5=% (odotettiin booking_189 443e6462…). Ei muutoksia.', coalesce(v, 'puuttuu');
  end if;
  if to_regprocedure('booking.payment_mark_paid(text,text,numeric,jsonb)') is null then
    raise exception 'booking_286: payment_mark_paid puuttuu';
  end if;
  if exists (select 1 from booking.integration_config where key = 'checkoutx') then
    raise exception 'booking_286: integration_config checkoutx on jo olemassa';
  end if;
end $g$;

-- ---------- kytkin ----------
alter table booking.integration_config drop constraint if exists integration_config_key_check;
alter table booking.integration_config add constraint integration_config_key_check
  check (key in ('resend', 'vismapay', 'procountor', 'mobilepay', 'booking_calendar', 'montonio', 'checkoutx'));
alter table booking.integration_config drop constraint if exists integration_config_test_only_online;
alter table booking.integration_config add constraint integration_config_test_only_online
  check (mode <> 'test' or key in ('mobilepay', 'vismapay', 'montonio', 'checkoutx'));
alter table booking.integration_config drop constraint if exists integration_config_checkoutx_no_live;
alter table booking.integration_config add constraint integration_config_checkoutx_no_live
  check (key <> 'checkoutx' or mode in ('off', 'test'));

insert into booking.integration_config(key, mode, settings, notes)
values ('checkoutx', 'off', jsonb_build_object('currency', 'EUR', 'env', 'demo', 'provider', 'Surfboard Payments / Worldline CheckoutX'),
        'booking_286: Pikakassan kortti puhelimella (CheckoutX, Surfboard demo). off = pois; test = Surfboard demo, vaatii approved_by ja Edge-salaisuuden CHECKOUTX_ENV=demo. Live-tilaa ei ole. Avaimet vain Edge-salaisuuksina.');

insert into booking.payment_methods(code, label, is_manual, active, johku_codes, sort_order)
values ('checkoutx', 'Kortti puhelimella (CheckoutX)', false, false, '{}'::text[], 93)
on conflict (code) do nothing;

insert into booking.pos_tenders(code, handler, channels, active, sort_order, unavailable_reason)
values ('checkoutx', 'checkoutx', array['pos'], true, 15, null)
on conflict (code) do nothing;

-- ---------- rekisteröidyt puhelimet (CheckoutX-terminaalit) ----------
create table booking.checkoutx_terminals (
  terminal_id   text primary key check (terminal_id ~ '^[A-Za-z0-9_-]{4,64}$'),
  label         text not null check (char_length(btrim(label)) between 1 and 60),
  active        boolean not null default true,
  env           text not null default 'demo' check (env = 'demo'),
  registered_by uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table booking.checkoutx_terminals is 'booking_286: CheckoutX-sovellukseen liitetyt puhelimet (Surfboard terminalId). Ei henkilö- eikä korttitietoja.';
alter table booking.checkoutx_terminals enable row level security;
revoke all on table booking.checkoutx_terminals from public, anon, authenticated;
grant all on table booking.checkoutx_terminals to service_role;

-- ---------- apurit ----------
create or replace function booking._checkoutx_mode() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((select mode from booking.integration_config where key = 'checkoutx'), 'off')
$$;

create or replace function booking._checkoutx_guard_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.key = 'checkoutx' and new.mode = 'test' and coalesce(btrim(new.settings ->> 'approved_by'), '') = '' then
    raise exception 'CheckoutX-testitilaa ei voi kytkeä ilman settings.approved_by -merkintää' using errcode = 'BK001', detail = 'approval_required';
  end if;
  return new;
end $$;
drop trigger if exists integration_config_checkoutx_guard on booking.integration_config;
create trigger integration_config_checkoutx_guard before insert or update on booking.integration_config
  for each row when (new.key = 'checkoutx') execute function booking._checkoutx_guard_trg();

-- ---------- hallinta ----------
create or replace function booking.admin_get_checkoutx_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r booking.integration_config; v_terms jsonb;
begin
  perform booking._require_permission('pos.use');
  select * into r from booking.integration_config where key = 'checkoutx';
  select coalesce(jsonb_agg(jsonb_build_object('terminal_id', t.terminal_id, 'label', t.label, 'created_at', t.created_at) order by t.label, t.terminal_id), '[]'::jsonb)
    into v_terms from booking.checkoutx_terminals t where t.active;
  return jsonb_build_object('ok', true, 'provider', 'CheckoutX', 'mode', coalesce(r.mode, 'off'),
    'approved_by', nullif(btrim(coalesce(r.settings ->> 'approved_by', '')), ''),
    'enabled', coalesce(r.mode, 'off') = 'test',
    'terminals', v_terms,
    'secrets', jsonb_build_array('SURFBOARD_API_URL', 'SURFBOARD_API_KEY', 'SURFBOARD_API_SECRET', 'SURFBOARD_MERCHANT_ID', 'SURFBOARD_STORE_ID', 'CHECKOUTX_ENV'));
end $$;

create or replace function booking.admin_set_checkoutx_mode(p_mode text, p_approved_by text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_old text; v_by text := nullif(btrim(coalesce(p_approved_by, '')), '');
begin
  perform booking._require_permission('settings.edit');
  if p_mode is null or p_mode not in ('off', 'test') then
    perform booking._err('invalid_param', 'CheckoutX-tila on off tai test');
  end if;
  if p_mode = 'test' and v_by is null then
    perform booking._err('approval_required', 'Testitila vaatii merkinnän kuka kytki tilan päälle');
  end if;
  select mode into v_old from booking.integration_config where key = 'checkoutx';
  update booking.integration_config
     set mode = p_mode,
         settings = case when p_mode = 'test' then settings || jsonb_build_object('approved_by', v_by) else settings end
   where key = 'checkoutx';
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'integration_config', 'checkoutx', 'CHECKOUTX_MODE',
          jsonb_build_object('mode', v_old), jsonb_build_object('mode', p_mode, 'approved_by', v_by));
  return booking.admin_get_checkoutx_status();
end $$;

create or replace function booking.admin_checkoutx_terminal_remove(p_terminal_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  perform booking._require_permission('settings.edit');
  update booking.checkoutx_terminals set active = false, updated_at = now() where terminal_id = p_terminal_id;
  if not found then perform booking._err('not_found', 'Puhelinta ei löydy'); end if;
  return jsonb_build_object('ok', true, 'terminal_id', p_terminal_id);
end $$;

-- ---------- Edge (service_role) ----------
create or replace function booking.checkoutx_terminal_save(p_terminal_id text, p_label text, p_actor uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_label text := left(btrim(coalesce(p_label, '')), 60);
begin
  if booking._checkoutx_mode() <> 'test' then perform booking._err('checkoutx_off', 'Kortti puhelimella ei ole käytössä'); end if;
  if p_terminal_id is null or p_terminal_id !~ '^[A-Za-z0-9_-]{4,64}$' then perform booking._err('invalid_param', 'Virheellinen terminaalin tunnus'); end if;
  if v_label = '' then v_label := 'Puhelin ' || right(p_terminal_id, 4); end if;
  insert into booking.checkoutx_terminals(terminal_id, label, active, registered_by)
  values (p_terminal_id, v_label, true, p_actor)
  on conflict (terminal_id) do update set label = excluded.label, active = true, updated_at = now();
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (p_actor, booking._jwt_role(), 'checkoutx_terminals', p_terminal_id, 'CHECKOUTX_TERMINAL', jsonb_build_object('label', v_label));
  return jsonb_build_object('ok', true, 'terminal_id', p_terminal_id, 'label', v_label);
end $$;

create or replace function booking.checkoutx_pos_prepare(p_order_id bigint, p_terminal_id text, p_actor uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; v_amount numeric; v_id bigint;
begin
  if booking._checkoutx_mode() <> 'test' then perform booking._err('checkoutx_off', 'Kortti puhelimella ei ole käytössä'); end if;
  if not exists (select 1 from booking.checkoutx_terminals t where t.terminal_id = p_terminal_id and t.active) then
    perform booking._err('terminal_not_registered', 'Puhelinta ei ole liitetty CheckoutX:ään');
  end if;
  select * into o from booking.orders where id = p_order_id and source_channel = 'pikakassa' for update;
  if not found then perform booking._err('not_found', 'Kassatilausta ei löydy'); end if;
  if o.status is distinct from 'pending' or o.payment_status not in ('unpaid', 'pending') then
    perform booking._err('order_not_payable', 'Tilausta ei voi enää maksaa');
  end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.provider not in ('manual', 'checkoutx')
               and (p.link_expires_at is null or p.link_expires_at > now())) then
    perform booking._err('payment_in_progress', 'Tilauksella on jo avoin maksu toisella maksutavalla');
  end if;
  -- aiempi kesken jäänyt yritys samalle tilaukselle perutaan (Surfboardin tilaus perutaan Edgessä cancelPreviousPendingOrder-valinnalla)
  update booking.payments set status = 'cancelled', provider_status = coalesce(provider_status, 'superseded'),
         note = concat_ws(' | ', note, 'korvattu uudella CheckoutX-yrityksellä')
   where order_id = o.id and status = 'pending' and provider = 'checkoutx';
  v_amount := round(((booking._order_balance(o.id)) ->> 'unpaid')::numeric, 2);
  if v_amount is null or v_amount <= 0.004 then perform booking._err('nothing_to_pay', 'Ei maksettavaa'); end if;
  insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, raw, note, created_by)
  values (o.id, 'checkoutx', 'checkoutx', 'pending', v_amount, o.currency, now() + interval '15 minutes',
          jsonb_build_object('terminal_id', p_terminal_id, 'env', 'demo'), 'pikakassa', p_actor)
  returning id into v_id;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'order_id', o.id, 'order_no', o.order_no,
    'amount', v_amount, 'currency', o.currency, 'terminal_id', p_terminal_id, 'mode', 'test');
end $$;

create or replace function booking.checkoutx_pos_created(p_payment_id bigint, p_sb_order_id text, p_sb_payment_id text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments;
begin
  if p_sb_order_id is null or p_sb_order_id !~ '^[A-Za-z0-9_-]{4,64}$' then perform booking._err('invalid_param', 'Virheellinen tilaustunnus'); end if;
  select * into pay from booking.payments where id = p_payment_id and provider = 'checkoutx' for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  if pay.status <> 'pending' then perform booking._err('payment_not_pending', 'Maksu ei ole avoin'); end if;
  if pay.provider_ref is not null and pay.provider_ref <> p_sb_order_id then perform booking._err('ref_conflict', 'Maksulla on jo toinen tilaustunnus'); end if;
  update booking.payments
     set provider_ref = p_sb_order_id, provider_status = 'PENDING',
         raw = coalesce(raw, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('sb_order_id', p_sb_order_id, 'sb_payment_id', p_sb_payment_id))
   where id = pay.id;
  return jsonb_build_object('ok', true, 'payment_id', pay.id);
end $$;

create or replace function booking.checkoutx_pos_lookup(p_payment_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare pay booking.payments; o booking.orders;
begin
  select * into pay from booking.payments where id = p_payment_id and provider = 'checkoutx';
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  select * into o from booking.orders where id = pay.order_id;
  return jsonb_build_object('ok', true, 'payment_id', pay.id, 'order_id', pay.order_id, 'order_no', o.order_no,
    'status', pay.status, 'provider_status', pay.provider_status, 'amount', pay.amount, 'currency', pay.currency,
    'sb_order_id', pay.provider_ref, 'sb_payment_id', pay.raw ->> 'sb_payment_id', 'terminal_id', pay.raw ->> 'terminal_id',
    'order_status', o.status, 'order_payment_status', o.payment_status, 'source_channel', o.source_channel);
end $$;

-- p_outcome: paid | failed | cancelled. paid → payment_mark_paid (sama polku kuin muilla välittäjillä: kuitti, tilauksen maksutila).
create or replace function booking.checkoutx_pos_apply(p_payment_id bigint, p_outcome text, p_sb_payment_id text default null, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments; v jsonb; v_raw jsonb;
begin
  if p_outcome is null or p_outcome not in ('paid', 'failed', 'cancelled') then perform booking._err('invalid_param', 'Tuntematon lopputulos'); end if;
  select * into pay from booking.payments where id = p_payment_id and provider = 'checkoutx' for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  if pay.provider_ref is null then perform booking._err('payment_not_started', 'Maksua ei ole aloitettu'); end if;
  if p_outcome = 'paid' then
    if pay.status = 'paid' then return jsonb_build_object('ok', true, 'already', true, 'status', 'paid'); end if;
    update booking.payments
       set raw = coalesce(raw, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('sb_payment_id', p_sb_payment_id, 'sb_status', p_raw))
     where id = pay.id;
    select raw into v_raw from booking.payments where id = pay.id;
    v := booking.payment_mark_paid('checkoutx', pay.provider_ref, pay.amount, v_raw);
    update booking.payments set provider_status = 'PAYMENT_COMPLETED' where id = pay.id;
    return coalesce(v, '{}'::jsonb) || jsonb_build_object('status', 'paid', 'payment_id', pay.id);
  end if;
  if pay.status <> 'pending' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', pay.status); end if;
  update booking.payments
     set status = p_outcome, provider_status = upper('payment_' || p_outcome),
         raw = coalesce(raw, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('sb_status', p_raw)),
         note = concat_ws(' | ', note, case when p_outcome = 'failed' then 'CheckoutX-maksu epäonnistui' else 'CheckoutX-maksu peruttiin' end)
   where id = pay.id;
  perform booking._refresh_order_payment(pay.order_id);
  return jsonb_build_object('ok', true, 'status', p_outcome, 'payment_id', pay.id);
end $$;

-- Tilauksen luonti Surfboardiin epäonnistui: avoin rivi pois, jotta tilaus vanhenee tavalliseen tapaan.
create or replace function booking.checkoutx_pos_create_failed(p_payment_id bigint, p_detail jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments;
begin
  select * into pay from booking.payments where id = p_payment_id and provider = 'checkoutx' for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  if pay.status <> 'pending' or pay.provider_ref is not null then return jsonb_build_object('ok', true, 'unchanged', true, 'status', pay.status); end if;
  update booking.payments set status = 'failed', provider_status = 'create_failed',
         raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('create_error', coalesce(p_detail, '{}'::jsonb))
   where id = pay.id;
  perform booking._refresh_order_payment(pay.order_id);
  return jsonb_build_object('ok', true, 'status', 'failed');
end $$;

-- ---------- hyvitys: admin_refund luo rivin provider='checkoutx' status='requested' (tila test). Edge mitätöi (void) saman päivän koko maksun. ----------
create or replace function booking.checkoutx_refund_claim(p_refund_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_rows jsonb;
begin
  if booking._checkoutx_mode() <> 'test' then
    return jsonb_build_object('ok', true, 'claimed', '[]'::jsonb, 'mode', booking._checkoutx_mode());
  end if;
  with c as (
    select f.id from booking.refunds f
     where f.provider = 'checkoutx' and f.id = p_refund_id
       and (f.status = 'requested' or (f.status = 'processing' and f.updated_at < now() - interval '10 minutes'))
     for update skip locked),
  u as (
    update booking.refunds f set status = 'processing', provider_status = 'processing', updated_at = now()
      from c where f.id = c.id returning f.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'refund_id', u.id, 'payment_id', u.payment_id, 'amount', u.amount, 'payment_amount', p.amount,
           'refunded_amount', p.refunded_amount, 'paid_at', p.paid_at,
           'sb_order_id', p.provider_ref, 'sb_payment_id', p.raw ->> 'sb_payment_id') order by u.id), '[]'::jsonb) into v_rows
    from u join booking.payments p on p.id = u.payment_id;
  return jsonb_build_object('ok', true, 'claimed', v_rows, 'mode', booking._checkoutx_mode());
end $$;

create or replace function booking.checkoutx_refund_complete(p_refund_id bigint, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds; pay booking.payments;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'checkoutx' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  if rf.status not in ('requested', 'processing') then perform booking._err('refund_not_pending', 'Hyvitys ei ole käsiteltävänä'); end if;
  select * into pay from booking.payments where id = rf.payment_id for update;
  update booking.refunds
     set status = 'done', provider_status = 'voided', provider_refund_id = coalesce(provider_refund_id, 'void-' || coalesce(pay.raw ->> 'sb_payment_id', pay.provider_ref)),
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
  values (null, 'service_role', 'refunds', rf.id::text, 'CHECKOUTX_VOID', jsonb_build_object('amount', rf.amount, 'payment_id', pay.id));
  return jsonb_build_object('ok', true, 'refund_id', rf.id);
end $$;

create or replace function booking.checkoutx_refund_fail(p_refund_id bigint, p_error jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'checkoutx' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status not in ('requested', 'processing') then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  update booking.refunds set status = 'failed', provider_status = 'failed', raw = jsonb_build_object('error', p_error, 'at', now()), updated_at = now() where id = rf.id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (null, 'service_role', 'refunds', rf.id::text, 'CHECKOUTX_REFUND_FAIL', coalesce(p_error, '{}'::jsonb));
  return jsonb_build_object('ok', true, 'status', 'failed');
end $$;

-- ---------- Pikakassan maksutavat: checkoutx näkyy vain testitilassa ----------
CREATE OR REPLACE FUNCTION booking.admin_pos_tenders()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_base text := rtrim(coalesce(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', ''), '/');
        v_cx text := booking._checkoutx_mode();
begin
  perform booking._require_permission('pos.use');
  return jsonb_build_object(
    'montonio_mode', booking._montonio_mode(),
    'mobilepay_mode', booking._mobilepay_mode(),
    'vismapay_mode', coalesce((select mode from booking.integration_config where key = 'vismapay'), 'off'),
    'checkoutx_mode', v_cx,
    'site_base_url', v_base,
    'drinks_path', booking._drinks_path('fi'),
    'drinks_path_en', booking._drinks_path('en'),
    'tenders', coalesce((select jsonb_agg(jsonb_build_object(
        'code', t.code, 'handler', t.handler, 'channels', to_jsonb(t.channels), 'active', t.active,
        'sort_order', t.sort_order, 'unavailable_reason', t.unavailable_reason) order by t.sort_order, t.code)
      from booking.pos_tenders t
     where t.handler <> 'checkoutx' or v_cx = 'test'), '[]'::jsonb));
end $function$
;

-- ---------- oikeudet ----------
revoke all on function booking._checkoutx_mode() from public, anon, authenticated;
grant execute on function booking._checkoutx_mode() to service_role;
revoke all on function booking._checkoutx_guard_trg() from public, anon, authenticated;
revoke all on function booking.admin_get_checkoutx_status() from public, anon;
grant execute on function booking.admin_get_checkoutx_status() to authenticated, service_role;
revoke all on function booking.admin_set_checkoutx_mode(text,text) from public, anon;
grant execute on function booking.admin_set_checkoutx_mode(text,text) to authenticated, service_role;
revoke all on function booking.admin_checkoutx_terminal_remove(text) from public, anon;
grant execute on function booking.admin_checkoutx_terminal_remove(text) to authenticated, service_role;
revoke all on function booking.checkoutx_terminal_save(text,text,uuid) from public, anon, authenticated;
grant execute on function booking.checkoutx_terminal_save(text,text,uuid) to service_role;
revoke all on function booking.checkoutx_pos_prepare(bigint,text,uuid) from public, anon, authenticated;
grant execute on function booking.checkoutx_pos_prepare(bigint,text,uuid) to service_role;
revoke all on function booking.checkoutx_pos_created(bigint,text,text) from public, anon, authenticated;
grant execute on function booking.checkoutx_pos_created(bigint,text,text) to service_role;
revoke all on function booking.checkoutx_pos_lookup(bigint) from public, anon, authenticated;
grant execute on function booking.checkoutx_pos_lookup(bigint) to service_role;
revoke all on function booking.checkoutx_pos_apply(bigint,text,text,jsonb) from public, anon, authenticated;
grant execute on function booking.checkoutx_pos_apply(bigint,text,text,jsonb) to service_role;
revoke all on function booking.checkoutx_pos_create_failed(bigint,jsonb) from public, anon, authenticated;
grant execute on function booking.checkoutx_pos_create_failed(bigint,jsonb) to service_role;
revoke all on function booking.checkoutx_refund_claim(bigint) from public, anon, authenticated;
grant execute on function booking.checkoutx_refund_claim(bigint) to service_role;
revoke all on function booking.checkoutx_refund_complete(bigint,jsonb) from public, anon, authenticated;
grant execute on function booking.checkoutx_refund_complete(bigint,jsonb) to service_role;
revoke all on function booking.checkoutx_refund_fail(bigint,jsonb) from public, anon, authenticated;
grant execute on function booking.checkoutx_refund_fail(bigint,jsonb) to service_role;
revoke all on function booking.admin_pos_tenders() from public, anon;
grant execute on function booking.admin_pos_tenders() to authenticated, service_role;

do $g$
begin
  if booking._checkoutx_mode() <> 'off' then raise exception 'booking_286: checkoutx-tilan pitää olla off'; end if;
  if not exists (select 1 from booking.pos_tenders where code = 'checkoutx' and handler = 'checkoutx') then raise exception 'booking_286: pos_tenders checkoutx puuttuu'; end if;
end $g$;
