-- booking_178: peruttu / keskeytetty Visma Pay -maksu EI kuluta maksulinkkiä (omistaja Joonas 25.10.2026 "Kyllä"). Asiakas voi yrittää uudelleen samalla
-- /maksa/?p=<link_token> -linkillä. Edge-funktiot ennallaan (vismapay-start/-return/-notify kutsuvat samoja RPC:itä samoilla parametreilla).
--   * Maksulinkki = payments.link_expires_at - created_at > 2 h (admin/sähköposti/pikakassa ≥ 1 vrk; verkkokaupan checkout 60 min, dry_run 30 min → ei linkki).
--   * vismapay_payment_apply: linkkimaksun cancelled/failed pitää rivin pending-tilassa, kun linkki ei ole vanhentunut, korvattu (uudempi ei-peruttu maksu samalle
--     tilaukselle), tilauksella on maksettavaa ja linkin summa ≤ maksamatta. Vanha Visma-token, ohjausosoite ja link_url tyhjennetään → vismapay_payment_prepare
--     luo seuraavalla painalluksella uuden yrityksen (-a<n+1>). Audit VISMAPAY_CANCELLED_RETRYABLE / VISMAPAY_FAILED_RETRYABLE. Muuten kuten ennen
--     (payment_mark_failed → cancelled, audit VISMAPAY_<X> + retry_blocked-syy). Verkkokaupan tavallinen maksu: ennallaan.
--   * Tuplamaksusuoja: uusi taulu booking.vismapay_attempts (jokainen Visma-tilausnumero → maksurivi, trigger payments_vismapay_attempt). Myöhästynyt paid
--     vanhalle yritykselle löytää saman maksurivin (FOR UPDATE), kirjataan kerran (provider_ref → maksanut yritys, audit VISMAPAY_LATE_PAID). Jos rivi on jo
--     maksettu toisella yrityksellä: EI toista maksua, vaan needs_review/duplicate_paid + TUPLAVELOITUS-merkintä tilaukselle + audit VISMAPAY_DUPLICATE_PAID
--     (hyvitys käsin Visma-portaalista). Hyvitetyn rivin uusi paid ei enää palauta tilaa paid-tilaan (already).
--   * vismapay_payment_lookup: tuntematon provider_ref → haku vismapay_attempts-taulusta (env yrityksen mukaan), lisäkenttä current.
--   * public_payment_link_info: peruttu yritys → status open + last_attempt (cancelled/failed); summa > maksamatta → replaced/link_stale.
--   muutetut funktiot (tuotanto ennen → booking_178):
--     booking.vismapay_payment_apply(text,text,numeric,jsonb): e5ae519184809a5bc47202a4cd6e787d -> 03fbbd2486b2c22dfa02d7ec84da626f
--     booking.vismapay_payment_lookup(text): 413368e58d3f85eb437814ee836ccf1f -> ddec24e2970bde7ff4dc6c6ecc3a63ac
--     booking.public_payment_link_info(uuid): 1fb6153b39daa6f1055c93cac7cb4563 -> 647c556562046c75b7e7e33703c050a0
--   uudet: taulu booking.vismapay_attempts (RLS, staff_read, authenticated SELECT, service_role ALL), booking._vismapay_attempt_trg(): 8553fa9e304740124b64dd361439820a,
--          trigger payments_vismapay_attempt (after insert or update of provider_ref on booking.payments), backfill nykyisistä sauna-… -tunnisteista.
--   riippuvuudet, ei muuteta (tuotanto = vaadittu, luettu sxbofnuisemspgquoxyv 25.10.2026 SELECTillä):
--     booking.vismapay_payment_prepare(uuid,uuid) 703c03c301f5a3008192cdbe65e559e2
--     booking.vismapay_payment_event(text,text,text,text,jsonb) e6834eb7c9da8a0a8c531706eb6692fc
--     booking.vismapay_order_refs(uuid) 79c7bbe4e02a4411d3ccdc821b662013
--     booking.payment_mark_paid(text,text,numeric,jsonb) 8ceb0a7dea60d37e3ea6a17cec0e4c25
--     booking.payment_mark_failed(text,text,text,jsonb) 2dfe2d2c0757157be90484d60cef8046
--     booking.payment_attach_provider_ref(bigint,text,text,jsonb) c83ea8d965b9ecb52e0eab200c103dac
--     booking._order_balance(bigint) a6b31f93559de53d75a52d8a285f1170
--     booking._create_link_payment(bigint,integer,text) 533ac9af831c0c11e1f504e377a17827
--     booking._vismapay_mode() 6d7d56a83470d01e954a78e8767e8366
--     booking._order_rl(text,uuid,integer,integer) ec6bf13a3694e5bf9034a80123857246
--     booking._rate_limit(text,integer,interval) 7c8076d29d82d72db797066fd44d06c1
--     booking._client_ip() 8c8e7d145566db576d33037a941ce81f
--     booking._setting(text,jsonb) 70fcfa245e9e7d070dae7a6c1e90ce4d
--     booking.is_staff() 40d8b86aa41ab71f29ef4e6c5257aa77
-- Rollback: rollbacks/20261025115820_booking_178_ROLLBACK.sql. Testi: tests/checkout/t178_paylink_retry.sql (BEGIN … ROLLBACK).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_apply(text,text,numeric,jsonb)')));
  if v is null or v <> 'e5ae519184809a5bc47202a4cd6e787d' then ok := false; msg := msg || ' vismapay_payment_apply=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_lookup(text)')));
  if v is null or v <> '413368e58d3f85eb437814ee836ccf1f' then ok := false; msg := msg || ' vismapay_payment_lookup=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_link_info(uuid)')));
  if v is null or v <> '1fb6153b39daa6f1055c93cac7cb4563' then ok := false; msg := msg || ' public_payment_link_info=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_prepare(uuid,uuid)')));
  if v is null or v <> '703c03c301f5a3008192cdbe65e559e2' then ok := false; msg := msg || ' vismapay_payment_prepare=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_event(text,text,text,text,jsonb)')));
  if v is null or v <> 'e6834eb7c9da8a0a8c531706eb6692fc' then ok := false; msg := msg || ' vismapay_payment_event=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_order_refs(uuid)')));
  if v is null or v <> '79c7bbe4e02a4411d3ccdc821b662013' then ok := false; msg := msg || ' vismapay_order_refs=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_mark_paid(text,text,numeric,jsonb)')));
  if v is null or v <> '8ceb0a7dea60d37e3ea6a17cec0e4c25' then ok := false; msg := msg || ' payment_mark_paid=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_mark_failed(text,text,text,jsonb)')));
  if v is null or v <> '2dfe2d2c0757157be90484d60cef8046' then ok := false; msg := msg || ' payment_mark_failed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_attach_provider_ref(bigint,text,text,jsonb)')));
  if v is null or v <> 'c83ea8d965b9ecb52e0eab200c103dac' then ok := false; msg := msg || ' payment_attach_provider_ref=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_balance(bigint)')));
  if v is null or v <> 'a6b31f93559de53d75a52d8a285f1170' then ok := false; msg := msg || ' _order_balance=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_link_payment(bigint,integer,text)')));
  if v is null or v <> '533ac9af831c0c11e1f504e377a17827' then ok := false; msg := msg || ' _create_link_payment=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vismapay_mode()')));
  if v is null or v <> '6d7d56a83470d01e954a78e8767e8366' then ok := false; msg := msg || ' _vismapay_mode=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_rl(text,uuid,integer,integer)')));
  if v is null or v <> 'ec6bf13a3694e5bf9034a80123857246' then ok := false; msg := msg || ' _order_rl=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._rate_limit(text,integer,interval)')));
  if v is null or v <> '7c8076d29d82d72db797066fd44d06c1' then ok := false; msg := msg || ' _rate_limit=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._client_ip()')));
  if v is null or v <> '8c8e7d145566db576d33037a941ce81f' then ok := false; msg := msg || ' _client_ip=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._setting(text,jsonb)')));
  if v is null or v <> '70fcfa245e9e7d070dae7a6c1e90ce4d' then ok := false; msg := msg || ' _setting=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.is_staff()')));
  if v is null or v <> '40d8b86aa41ab71f29ef4e6c5257aa77' then ok := false; msg := msg || ' is_staff=' || coalesce(v, 'puuttuu'); end if;
  if to_regclass('booking.vismapay_attempts') is not null or to_regprocedure('booking._vismapay_attempt_trg()') is not null then ok := false; msg := msg || ' vismapay_attempts/_vismapay_attempt_trg on jo olemassa'; end if;
  if exists (select 1 from pg_trigger where tgrelid = 'booking.payments'::regclass and tgname = 'payments_vismapay_attempt') then ok := false; msg := msg || ' trigger payments_vismapay_attempt on jo olemassa'; end if;
  if not exists (select 1 from pg_indexes where schemaname = 'booking' and tablename = 'payments' and indexname = 'payments_provider_ref_uq') then ok := false; msg := msg || ' payments_provider_ref_uq puuttuu'; end if;
  if (select string_agg(column_name, ',' order by column_name) from information_schema.columns where table_schema = 'booking' and table_name = 'payments'
        and column_name in ('provider', 'provider_ref', 'provider_status', 'status', 'amount', 'link_url', 'link_token', 'link_expires_at', 'raw', 'created_at', 'updated_at', 'paid_at'))
     is distinct from 'amount,created_at,link_expires_at,link_token,link_url,paid_at,provider,provider_ref,provider_status,raw,status,updated_at' then ok := false; msg := msg || ' payments-sarakkeet'; end if;
  if (select data_type from information_schema.columns where table_schema = 'booking' and table_name = 'orders' and column_name = 'internal_note') is distinct from 'text' then ok := false; msg := msg || ' orders.internal_note'; end if;
  if exists (select 1 from booking.payments where provider = 'visma_pay' and provider_ref is not null and provider_ref !~ '^sauna-[a-z0-9_-]+$') then ok := false; msg := msg || ' visma_pay provider_ref ei sauna-muotoa'; end if;
  if not ok then raise exception 'booking_178: tuotannon määrittelyt eivät vastaa odotettua:%. Ei muutoksia.', msg; end if;
end $g$;

create table booking.vismapay_attempts (
  order_number  text primary key check (order_number ~ '^sauna-[a-z0-9_-]+$'),
  payment_id    bigint not null references booking.payments(id) on delete cascade,
  attempt       integer,
  env           text,
  created_at    timestamptz not null default now(),
  superseded_at timestamptz,
  outcome       text check (outcome in ('paid', 'failed', 'cancelled', 'duplicate_paid')),
  outcome_at    timestamptz
);
comment on table booking.vismapay_attempts is 'booking_178: jokainen Visma Payhin lähetetty tilausnumero (ORDER_NUMBER = payments.provider_ref yrityshetkellä). Myöhästynyt paluu/ilmoitus vanhalle yritykselle löytää maksurivin tämän kautta. Ei henkilötietoja.';
create index vismapay_attempts_payment_idx on booking.vismapay_attempts(payment_id);
alter table booking.vismapay_attempts enable row level security;
revoke all on table booking.vismapay_attempts from public, anon, authenticated;
grant select on table booking.vismapay_attempts to authenticated;
grant all on table booking.vismapay_attempts to service_role;
create policy staff_read on booking.vismapay_attempts for select to authenticated using ((select booking.is_staff()));

create function booking._vismapay_attempt_trg()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
-- booking_178: kirjaa jokaisen Visma Pay -tilausnumeron (provider_ref sauna-…) maksuriville ja merkitsee edellisen yrityksen korvatuksi.
begin
  if new.provider = 'visma_pay' and new.provider_ref ~ '^sauna-[a-z0-9_-]+$'
     and (tg_op = 'INSERT' or new.provider_ref is distinct from old.provider_ref) then
    insert into booking.vismapay_attempts(order_number, payment_id, attempt, env)
    values (new.provider_ref, new.id,
            case when coalesce(new.raw ->> 'attempt', '') ~ '^\d{1,6}$' then (new.raw ->> 'attempt')::int end,
            nullif(new.raw ->> 'env', ''))
    on conflict (order_number) do update set superseded_at = null
     where booking.vismapay_attempts.payment_id = excluded.payment_id;
    update booking.vismapay_attempts set superseded_at = now()
     where payment_id = new.id and order_number <> new.provider_ref and superseded_at is null;
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION booking.vismapay_payment_lookup(p_order_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_178: löytää maksun myös vanhan yrityksen tilausnumerolla (booking.vismapay_attempts), jotta myöhästynyt paluu/ilmoitus käsitellään.
declare pay booking.payments; o booking.orders; v_env text;
begin
  if p_order_number is null or p_order_number !~ '^sauna-[a-z0-9_-]+$' then
    return jsonb_build_object('found', false);
  end if;
  select * into pay from booking.payments where provider = 'visma_pay' and provider_ref = p_order_number;
  if not found then
    select p.* into pay from booking.vismapay_attempts a join booking.payments p on p.id = a.payment_id
     where a.order_number = p_order_number and p.provider = 'visma_pay';
    if not found then return jsonb_build_object('found', false); end if;
  end if;
  select a.env into v_env from booking.vismapay_attempts a where a.order_number = p_order_number;
  select * into o from booking.orders where id = pay.order_id;
  return jsonb_build_object(
    'found', true, 'payment_id', pay.id, 'status', pay.status, 'amount', pay.amount,
    'amount_minor', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'env', coalesce(v_env, pay.raw ->> 'env', 'test'), 'order_token', o.public_token, 'order_no', o.order_no,
    'current', pay.provider_ref is not distinct from p_order_number,
    'site_base_url', booking._setting('site_base_url', 'null'::jsonb) #>> '{}',
    'order_page_path', coalesce(booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}', '/tilaus/'));
end $function$;

CREATE OR REPLACE FUNCTION booking.vismapay_payment_apply(p_order_number text, p_outcome text, p_amount numeric DEFAULT NULL::numeric, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_178: (1) maksulinkki (link_expires_at - created_at > 2 h, eli _create_link_payment) EI kulu peruttuun/hylättyyn Visma-yritykseen: maksu jää
-- pending-tilaan, vanha Visma-token/ohjausosoite poistetaan (vismapay_payment_prepare luo seuraavalla painalluksella uuden yrityksen -a<n+1>), kun linkki on
-- voimassa, ei korvattu ja tilauksella on maksettavaa (summa ≤ maksamatta). Muuten ja verkkokaupan tavallisessa maksussa kuten ennen (cancelled/failed).
-- (2) vanhan yrityksen tilausnumero löytyy booking.vismapay_attempts-taulusta: myöhästynyt "maksettu" kirjataan samalle maksuriville täsmälleen kerran
-- (provider_ref vaihdetaan maksaneeseen yritykseen, jotta hyvitys osuu oikeaan Visma-tilaukseen); jos rivi on jo maksettu toisella yrityksellä, maksua ei
-- kirjata toista kertaa vaan tilaukselle merkitään TUPLAVELOITUS tarkistettavaksi (outcome needs_review, code duplicate_paid). Vanhan yrityksen
-- peruutus/hylkäys ei muuta maksua.
declare
  pay booking.payments; att booking.vismapay_attempts;
  v_raw jsonb := coalesce(p_raw, '{}'::jsonb); v_res jsonb; v_current boolean; v_unpaid numeric; v_why text; v_prev text;
begin
  if p_order_number is null or p_order_number !~ '^sauna-[a-z0-9_-]+$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  if p_outcome is null or p_outcome not in ('paid', 'failed', 'cancelled', 'pending', 'authorized', 'needs_review') then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  select * into pay from booking.payments where provider = 'visma_pay' and provider_ref = p_order_number for update;
  if not found then
    select * into att from booking.vismapay_attempts where order_number = p_order_number;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    select * into pay from booking.payments where id = att.payment_id and provider = 'visma_pay' for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  end if;
  select * into att from booking.vismapay_attempts where order_number = p_order_number for update;
  v_current := pay.provider_ref is not distinct from p_order_number;

  if pay.status in ('paid', 'partially_refunded', 'refunded') then
    if p_outcome = 'paid' and not v_current then
      -- sama maksurivi on jo maksettu toisella Visma-yrityksellä → ei toista kirjausta; rahat palautetaan käsin
      if att.outcome is distinct from 'duplicate_paid' then
        update booking.vismapay_attempts set outcome = 'duplicate_paid', outcome_at = now() where order_number = p_order_number;
        update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'VISMA PAY: TUPLAVELOITUS – maksu ' || coalesce(pay.provider_ref, '?')
               || ' on jo kirjattu, myös ' || p_order_number || ' maksettiin. Palauta ' || p_order_number || ' Visma Payn hallinnasta.' where id = pay.order_id;
        insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
        values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_DUPLICATE_PAID',
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
      update booking.vismapay_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
    end if;
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
    if not v_current then
      -- myöhästynyt maksu vanhalle yritykselle: rivi siirretään maksaneeseen tilausnumeroon (uudempi yritys merkitään korvatuksi triggerissä)
      v_prev := pay.provider_ref;
      update booking.payments
         set provider_ref = p_order_number,
             link_url = case when link_url like 'https://www.vismapay.com/%' then null else link_url end,
             raw = (coalesce(raw, '{}'::jsonb) - 'token' - 'redirect_url' - 'token_valid_until') || jsonb_build_object('last_state', 'late_paid', 'replaced_ref', v_prev)
       where id = pay.id;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_LATE_PAID', jsonb_build_object('order_number', p_order_number, 'superseded', v_prev, 'status_before', pay.status));
    end if;
    v_res := booking.payment_mark_paid('visma_pay', p_order_number, pay.amount, v_raw || jsonb_build_object('source', v_raw -> 'source'));
    update booking.vismapay_attempts set outcome = 'paid', outcome_at = now() where order_number = p_order_number;
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
    if not v_current then
      -- vanha yritys peruttu/hylätty: maksu (ja sen uudempi yritys) ennallaan
      if att.order_number is not null and att.outcome is null then
        update booking.vismapay_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
        insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
        values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_ATTEMPT_' || upper(p_outcome), v_raw || jsonb_build_object('order_number', p_order_number, 'current', pay.provider_ref));
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
    if pay.link_expires_at is null or pay.link_expires_at - pay.created_at <= interval '2 hours' then v_why := 'not_link';
    elsif pay.link_expires_at <= now() then v_why := 'link_expired';
    elsif exists (select 1 from booking.payments x where x.order_id = pay.order_id and x.id > pay.id and x.status not in ('cancelled', 'failed')) then v_why := 'replaced';
    elsif v_unpaid <= 0.004 then v_why := 'nothing_to_pay';
    elsif pay.amount > v_unpaid + 0.004 then v_why := 'link_stale';
    end if;
    if v_why is null then
      update booking.payments
         set provider_status = p_outcome,
             link_url = case when link_url like 'https://www.vismapay.com/%' then null else link_url end,
             raw = (coalesce(raw, '{}'::jsonb) - 'token' - 'redirect_url' - 'token_valid_until')
                   || jsonb_build_object('last_state', p_outcome, 'retryable', true, 'detail', v_raw - 'customer' - 'email')
       where id = pay.id;
      update booking.vismapay_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_' || upper(p_outcome) || '_RETRYABLE',
              v_raw || jsonb_build_object('order_number', p_order_number, 'attempt', att.attempt, 'link_expires_at', pay.link_expires_at));
      return jsonb_build_object('ok', true, 'outcome', p_outcome, 'retryable', true);
    end if;
    perform booking.payment_mark_failed('visma_pay', p_order_number, p_outcome, v_raw);
    update booking.vismapay_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_' || upper(p_outcome),
            case when v_why = 'not_link' then v_raw else v_raw || jsonb_build_object('retry_blocked', v_why) end);
    return jsonb_build_object('ok', true, 'outcome', p_outcome) || case when v_why = 'not_link' then '{}'::jsonb else jsonb_build_object('retryable', false, 'reason', v_why) end;
  else
    if not v_current then
      return jsonb_build_object('ok', true, 'unchanged', true, 'stale', true, 'outcome', p_outcome);
    end if;
    update booking.payments set provider_status = p_outcome, raw = coalesce(raw, '{}'::jsonb) || v_raw where id = pay.id and status = 'pending';
    return jsonb_build_object('ok', true, 'outcome', p_outcome);
  end if;
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
  v_mode := booking._vismapay_mode();

  if pay.status in ('paid', 'partially_refunded', 'refunded') then
    v_status := 'paid'; v_reason := 'link_paid';
  elsif pay.status <> 'pending' then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    elsif pay.link_expires_at is not null and pay.link_expires_at < now() then v_status := 'expired'; v_reason := 'link_expired';
    elsif pay.amount > v_unpaid + 0.004 then v_status := 'replaced'; v_reason := 'link_stale';
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
    'last_attempt', case when v_status = 'open' and pay.provider_status in ('cancelled', 'failed') then pay.provider_status end,
    'items', v_items);
end $function$;

revoke all on function booking._vismapay_attempt_trg() from public, anon, authenticated;
create trigger payments_vismapay_attempt after insert or update of provider_ref on booking.payments
  for each row when (new.provider = 'visma_pay' and new.provider_ref is not null) execute function booking._vismapay_attempt_trg();
insert into booking.vismapay_attempts(order_number, payment_id, attempt, env, created_at, outcome, outcome_at)
select p.provider_ref, p.id,
       case when coalesce(p.raw ->> 'attempt', '') ~ '^\d{1,6}$' then (p.raw ->> 'attempt')::int end,
       nullif(p.raw ->> 'env', ''), p.updated_at,
       case when p.status in ('paid', 'partially_refunded', 'refunded') then 'paid' when p.status in ('failed', 'cancelled') and p.provider_status in ('failed', 'cancelled') then p.provider_status end,
       case when p.status in ('paid', 'partially_refunded', 'refunded') then p.paid_at when p.status in ('failed', 'cancelled') and p.provider_status in ('failed', 'cancelled') then p.updated_at end
  from booking.payments p
 where p.provider = 'visma_pay' and p.provider_ref ~ '^sauna-[a-z0-9_-]+$'
on conflict (order_number) do nothing;

revoke all on function booking.vismapay_payment_apply(text,text,numeric,jsonb) from public, anon, authenticated;
grant execute on function booking.vismapay_payment_apply(text,text,numeric,jsonb) to service_role;
revoke all on function booking.vismapay_payment_lookup(text) from public, anon, authenticated;
grant execute on function booking.vismapay_payment_lookup(text) to service_role;
revoke all on function booking.public_payment_link_info(uuid) from public;
grant execute on function booking.public_payment_link_info(uuid) to anon, authenticated, service_role;

do $v$
begin
  if md5(pg_get_functiondef('booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure)) <> '03fbbd2486b2c22dfa02d7ec84da626f' then raise exception 'booking_178: vismapay_payment_apply md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.vismapay_payment_lookup(text)'::regprocedure)) <> 'ddec24e2970bde7ff4dc6c6ecc3a63ac' then raise exception 'booking_178: vismapay_payment_lookup md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.public_payment_link_info(uuid)'::regprocedure)) <> '647c556562046c75b7e7e33703c050a0' then raise exception 'booking_178: public_payment_link_info md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking._vismapay_attempt_trg()'::regprocedure)) <> '8553fa9e304740124b64dd361439820a' then raise exception 'booking_178: _vismapay_attempt_trg md5 ei vastaa odotettua'; end if;
  if exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid in ('booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure, 'booking.vismapay_payment_lookup(text)'::regprocedure, 'booking.public_payment_link_info(uuid)'::regprocedure, 'booking._vismapay_attempt_trg()'::regprocedure) and a.grantee = 0) then raise exception 'booking_178: PUBLIC-oikeus jäi'; end if;
  if has_function_privilege('anon', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute') or has_function_privilege('authenticated', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute') or not has_function_privilege('service_role', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute')
     or has_function_privilege('anon', 'booking.vismapay_payment_lookup(text)', 'execute') or has_function_privilege('authenticated', 'booking.vismapay_payment_lookup(text)', 'execute') or not has_function_privilege('service_role', 'booking.vismapay_payment_lookup(text)', 'execute')
     or not has_function_privilege('anon', 'booking.public_payment_link_info(uuid)', 'execute') then raise exception 'booking_178: funktio-oikeudet väärin'; end if;
  if not (select relrowsecurity from pg_class where oid = 'booking.vismapay_attempts'::regclass) or has_table_privilege('anon', 'booking.vismapay_attempts', 'select')
     or has_table_privilege('authenticated', 'booking.vismapay_attempts', 'insert') then raise exception 'booking_178: vismapay_attempts-oikeudet väärin'; end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'booking.payments'::regclass and tgname = 'payments_vismapay_attempt' and tgenabled = 'O') then raise exception 'booking_178: trigger puuttuu'; end if;
  if (select count(*) from booking.vismapay_attempts) <> (select count(*) from booking.payments where provider = 'visma_pay' and provider_ref ~ '^sauna-[a-z0-9_-]+$') then raise exception 'booking_178: backfill ei täsmää'; end if;
end $v$;
