-- LOCAL EMPTY DATABASE ONLY. Minimal dependencies to exercise booking_259 without live data.
-- This is NOT a production migration or a substitute for the full DEV regression suite.
create role anon; create role authenticated; create role service_role;
create schema auth; create schema booking; create schema kb;
grant usage on schema booking,auth to anon,authenticated,service_role;
create function auth.uid() returns uuid language sql stable as $$ select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$;

create function booking._jwt_role() returns text language sql stable as $$ select nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role' $$;
create table auth.users(id uuid primary key,email text);
create table booking.staff(user_id uuid primary key,email text,name text, role text, active boolean default true);
create function booking._err(code text,msg text) returns void language plpgsql as $$ begin raise exception using errcode='BK001',message=msg,detail=code; end $$;
create function booking._require_permission(p_permission text) returns void language plpgsql security definer set search_path='' as $$ begin
 if not exists(select 1 from booking.staff where user_id=auth.uid() and role in ('manager','admin') and active) then perform booking._err('forbidden','Forbidden'); end if;
end $$;
create table booking.customers(id bigint generated always as identity primary key,name text,email text,language text,marketing_consent boolean default false,anonymized_at timestamptz,unsubscribe_token uuid default gen_random_uuid());
create table booking.orders(id bigint generated always as identity primary key,customer_id bigint references booking.customers,status text default 'confirmed',payment_status text default 'paid',locale text,created_at timestamptz default now());
create table kb.products(id bigint generated always as identity primary key,business_id bigint,slug text,name text,category text);
create table booking.product_config(product_id bigint primary key references kb.products,sale_kind text);
create table booking.resources(id bigint primary key);
insert into booking.resources values(1);
create table booking.reservations(id bigint generated always as identity primary key,order_id bigint references booking.orders,product_id bigint references kb.products,status text,hidden_at timestamptz,space_id bigint,mode text,persons integer,starts_at timestamptz,ends_at timestamptz);
create table booking.gift_cards(id bigint generated always as identity primary key,issuer text default 'own',code text,initial_amount numeric,balance numeric,purchase_order_id bigint references booking.orders,buyer_customer_id bigint references booking.customers,status text,complimentary boolean default false,created_at timestamptz default now());
create table booking.email_outbox(id bigint generated always as identity primary key,kind text not null,locale text,dedupe_key text unique,payload jsonb,locked_at timestamptz,last_error text,status text default 'pending',constraint email_outbox_kind_check check(kind in ('event_message','order_confirmation')));
create table booking.settings(key text primary key,value jsonb);
create function booking._setting(p_key text) returns jsonb language sql stable as $$select value from booking.settings where key=p_key$$;
create function booking._valid_email(p_email text) returns boolean language sql immutable as $$select coalesce(p_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$',false)$$;
create table booking.integration_config(key text primary key,mode text);
insert into booking.settings values('site_base_url','"https://saunotus.fi"'),('order_page_path','"/tilaus/"');
insert into booking.integration_config values('resend','dry_run');
insert into kb.products(name,category) values('Training','training'),('Treatment','treatment'),('Event','event'),('Session','public_sauna');
insert into booking.product_config select id,case when category='public_sauna' then 'public_shift' else 'other' end from kb.products;
