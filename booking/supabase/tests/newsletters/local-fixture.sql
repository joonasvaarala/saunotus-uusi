-- LOCAL EMPTY DATABASE ONLY. Minimal dependencies to exercise booking_259 without live data.
-- This is NOT a production migration or a substitute for the full DEV regression suite.
create role anon; create role authenticated; create role service_role;
create schema auth; create schema booking; create schema kb; create schema extensions;
create extension pgcrypto with schema extensions;
grant usage on schema booking,auth to anon,authenticated,service_role;
create function auth.uid() returns uuid language sql stable as $$ select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$;

create function booking._jwt_role() returns text language sql stable as $$ select nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role' $$;
create table auth.users(id uuid primary key,email text);
create table booking.staff(user_id uuid primary key,email text,name text, role text, active boolean default true);
create function booking._err(code text,msg text) returns void language plpgsql as $$ begin raise exception using errcode='BK001',message=msg,detail=code; end $$;
create function booking._require_permission(p_permission text) returns void language plpgsql security definer set search_path='' as $$ begin
 if not exists(select 1 from booking.staff where user_id=auth.uid() and role in ('manager','admin') and active) then perform booking._err('forbidden','Forbidden'); end if;
end $$;
create table booking.customers(id bigint generated always as identity primary key,name text,email text,language text,marketing_consent boolean not null default false,marketing_consent_at timestamptz,marketing_consent_source text,marketing_unsubscribed_at timestamptz,anonymized_at timestamptz,unsubscribe_token uuid default gen_random_uuid(),constraint customers_consent_has_time check(not marketing_consent or marketing_consent_at is not null),constraint customers_language_check check(language in ('fi','en','sv')),constraint customers_name_len check(length(name) between 1 and 200));
create table booking.orders(id bigint generated always as identity primary key,customer_id bigint references booking.customers,status text default 'confirmed',payment_status text default 'paid',locale text,created_at timestamptz default now());
create table kb.products(id bigint generated always as identity primary key,business_id bigint,slug text,name text,category text);
create table booking.product_config(product_id bigint primary key references kb.products,sale_kind text);
create table booking.resources(id bigint primary key);
insert into booking.resources values(1);
create table booking.schedule_rules(id bigint generated always as identity primary key,product_id bigint references kb.products,label text,mode text,space_id bigint,weekdays smallint[],start_time time,duration_minutes integer,kind text default 'regular',training_segment_only boolean default false,cancelled_at timestamptz,valid_from date,valid_to date, constraint schedule_rules_event_shape check(kind<>'event' or(valid_from is not null and valid_to=valid_from and weekdays=array[extract(isodow from valid_from)::smallint])));
create table booking.training_segments(option_rule_id bigint references booking.schedule_rules,position integer,segment_rule_id bigint references booking.schedule_rules,primary key(option_rule_id,position));
create table booking.reservations(id bigint generated always as identity primary key,order_id bigint references booking.orders,product_id bigint references kb.products,rule_id bigint references booking.schedule_rules,status text,checkin_at timestamptz,checkout_at timestamptz,hidden_at timestamptz,space_id bigint,mode text,persons integer,starts_at timestamptz,ends_at timestamptz,constraint reservations_time_ok check(ends_at>starts_at),constraint reservations_status_check check(status in ('pending','confirmed','cancelled','expired','completed','no_show')));
create table booking.training_participant_details(reservation_id bigint primary key references booking.reservations,present boolean not null default false);
create table booking.gift_cards(id bigint generated always as identity primary key,issuer text default 'own',source text not null default 'native',accounting_origin text not null default 'native',code text not null unique,initial_amount numeric,balance numeric,purchase_order_id bigint references booking.orders,buyer_customer_id bigint references booking.customers,status text,complimentary boolean default false,created_at timestamptz default now(),
 constraint gift_cards_code_format check(code ~ '^[A-Z0-9]{12}$'),
 constraint gift_cards_native_hh check(source<>'native' or code like 'HH%'),
 constraint gift_cards_source_check check(source in ('native','johku')),
 constraint gift_cards_origin_check check(source<>'johku' or (accounting_origin='johku' and issuer='johku')),
 constraint gift_cards_balance_check check(balance>=0),constraint gift_cards_initial_amount_check check(initial_amount>=0));
create table booking.email_outbox(id bigint generated always as identity primary key,kind text not null,order_id bigint references booking.orders,locale text,dedupe_key text unique,payload jsonb,locked_at timestamptz,last_error text,status text default 'pending',constraint email_outbox_status_check check(status in ('pending','sending','sent','failed','dead','skipped','dry_run')),constraint email_outbox_kind_check check(kind in ('event_message','order_confirmation','product_message')));
create table booking.settings(key text primary key,value jsonb);
create function booking._setting(p_key text) returns jsonb language sql stable as $$select value from booking.settings where key=p_key$$;
create function booking._valid_email(p_email text) returns boolean language sql immutable as $$select coalesce(p_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$',false)$$;
create table booking.integration_config(key text primary key,mode text);
insert into booking.settings values('site_base_url','"https://saunotus.fi"'),('order_page_path','"/tilaus/"');
insert into booking.integration_config values('resend','dry_run');
insert into kb.products(name,category) values('Training','training'),('Treatment','treatment'),('Event','event'),('Session','public_sauna');
insert into booking.product_config select id,case when category='public_sauna' then 'public_shift' else 'other' end from kb.products;

-- Actual shared RPC contract copied verbatim from booking_121, disposable fixture ONLY.
create table booking.messages(id bigint generated always as identity primary key,name text,category text,active boolean default false);
create function booking.public_marketing_unsubscribe(p_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c booking.customers;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into c from booking.customers where unsubscribe_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if c.marketing_consent or c.marketing_unsubscribed_at is null then
    update booking.customers set
      marketing_consent = false,
      marketing_unsubscribed_at = coalesce(marketing_unsubscribed_at, now()),
      marketing_consent_source = case when marketing_consent then 'product_message_unsubscribe' else marketing_consent_source end
     where id = c.id;
  end if;
  update booking.email_outbox e set status = 'skipped', last_error = 'unsubscribed'
   where e.kind = 'product_message'
     and e.status in ('pending', 'failed')
     and e.order_id in (select o.id from booking.orders o where o.customer_id = c.id)
     and exists (
       select 1 from booking.messages m
        where m.category = 'after_marketing'
          and m.id = nullif(e.payload ->> 'message_id', '')::bigint);
  return jsonb_build_object('ok', true);
end $$;

comment on function booking.public_marketing_unsubscribe(uuid) is
  'Jälkimarkkinoinnin peruutus. customers.marketing_consent = false, marketing_unsubscribed_at täyttyy, jonossa olevat after_marketing-rivit skipped/unsubscribed. Ohje ja palautepyyntö eivät muutu.';
revoke all on function booking.public_marketing_unsubscribe(uuid) from public;
grant execute on function booking.public_marketing_unsubscribe(uuid) to anon, authenticated, service_role;
