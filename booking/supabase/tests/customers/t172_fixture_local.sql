-- t172-pohja paikalliseen PG17:ään (ei tuotantoon!): minimitaulut + tuotannon tarkat funktiomäärittelyt (luettu SELECTillä sxbofnuisemspgquoxyv 25.10.2026, md5 = tuotanto).
-- Ajo: psql -f t172_fixture_local.sql && psql -1 -f ../../migrations/20261025010500_booking_172_company_customer_search.sql && psql -f t172_company_customer_search.sql
drop schema if exists booking cascade;
create schema booking;
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin; exception when duplicate_object then null; end $$;
create table booking.customer_kinds(code text primary key, is_company boolean not null, active boolean default true);
insert into booking.customer_kinds values ('private', false, true), ('company', true, true);
create table booking.customers(id bigserial primary key, name text not null, email text, phone text, company text, address text, zip text, city text, country text default 'FI',
  customer_type text default 'customer', customer_kind text default 'private' references booking.customer_kinds, business_id text, einvoice_address text, einvoice_operator text,
  invoice_reference text, external_source text, anonymized_at timestamptz, created_at timestamptz default now());
create table booking.orders(id bigserial primary key, customer_id bigint references booking.customers, customer_kind text default 'private', billing jsonb, invoice_reference text,
  external_source text, status text default 'confirmed', created_at timestamptz default now());
create table booking.invoice_customers(id bigserial primary key, customer_id bigint, company_name text not null, contact_name text, business_id text, vat_id text, email text, phone text,
  street text, zip text, city text, country text default 'FI', einvoice_address text, einvoice_operator text, buyer_reference text);
create function booking.is_staff() returns boolean language sql stable as $$ select coalesce(current_setting('t.staff', true), '') = '1' $$;
create function booking.has_permission(p text) returns boolean language sql stable as $$ select p = any(string_to_array(coalesce(current_setting('t.perm', true), ''), ',')) $$;
create function booking._err(p_code text, p_msg text) returns void language plpgsql as $$ begin raise exception using errcode = 'BK001', message = p_msg, detail = p_code; end $$;
CREATE OR REPLACE FUNCTION booking._norm_business_id(p_id text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare s text := regexp_replace(coalesce(p_id, ''), '\s', '', 'g');
begin
  s := regexp_replace(s, '^(FI|fi)(\d{8})$', '\2');                  -- ALV-tunnus FI12345678 → 12345678
  if s ~ '^\d{8}$' then return substr(s, 1, 7) || '-' || substr(s, 8, 1); end if;
  if s ~ '^\d{6}-\d$' then return '0' || s; end if;
  return nullif(s, '');
end $function$;
CREATE OR REPLACE FUNCTION booking._business_id_ok(p_id text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare s text := booking._norm_business_id(p_id); w int[] := array[7,9,10,5,8,4,2]; v_sum int := 0; r int; i int;
begin
  if s is null or s !~ '^\d{7}-\d$' then return false; end if;
  for i in 1..7 loop v_sum := v_sum + substr(s, i, 1)::int * w[i]; end loop;
  r := v_sum % 11;
  if r = 1 then return false; end if;
  return (case when r = 0 then 0 else 11 - r end) = substr(s, 9, 1)::int;
end $function$;
CREATE OR REPLACE FUNCTION booking._require_staff()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
end $function$;
CREATE OR REPLACE FUNCTION booking._require_permission(p_permission text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  if not booking.has_permission(p_permission) then
    perform booking._err('forbidden', 'Ei oikeutta tähän toimintoon (' || p_permission || ')');
  end if;
end $function$;
CREATE OR REPLACE FUNCTION booking._invoice_customer_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', c.id, 'customer_id', c.customer_id, 'name', c.company_name, 'company_name', c.company_name,
    'contact_name', c.contact_name, 'business_id', c.business_id, 'vat_id', c.vat_id,
    'email', c.email, 'phone', c.phone, 'street', c.street, 'zip', c.zip, 'city', c.city, 'country', c.country,
    'einvoice_address', c.einvoice_address, 'einvoice_operator', c.einvoice_operator, 'buyer_reference', c.buyer_reference,
    'address', nullif(concat_ws(', ', nullif(btrim(c.street), ''), nullif(concat_ws(' ', nullif(btrim(c.zip), ''), nullif(btrim(c.city), '')), '')), ''))
  from booking.invoice_customers c where c.id = p_id
$function$;
CREATE OR REPLACE FUNCTION booking.admin_list_customers(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(id bigint, name text, email text, phone text, company text, city text, marketing_consent boolean, marketing_consent_at timestamp with time zone, created_at timestamp with time zone, orders_count bigint, last_visit timestamp with time zone, total_count bigint, customer_type text, customer_kind text, business_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select c.id, c.name, c.email, c.phone, c.company, c.city, c.marketing_consent, c.marketing_consent_at, c.created_at,
           (select count(*) from booking.orders o where o.customer_id = c.id and o.status in ('pending','confirmed','completed')),
           (select max(r.starts_at) from booking.reservations r join booking.orders o on o.id = r.order_id
             where o.customer_id = c.id and r.status in ('confirmed','completed')),
           count(*) over (), c.customer_type, c.customer_kind, c.business_id
      from booking.customers c
     where c.anonymized_at is null
       and (q is null or c.name ilike '%' || q || '%' or c.email ilike '%' || q || '%' or c.phone ilike '%' || q || '%' or c.company ilike '%' || q || '%'
            or c.business_id ilike '%' || q || '%')
     order by c.created_at desc, c.id desc
     limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $function$;
CREATE OR REPLACE FUNCTION booking.admin_search_invoice_customers(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_like text;
  v_digits text;
  v_norm text;
  v_lim int := least(greatest(coalesce(p_limit, 10), 1), 20);
begin
  perform booking._require_permission('invoices.manage');
  if v_s is null or char_length(v_s) < 2 then return '[]'::jsonb; end if;
  v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  v_digits := nullif(regexp_replace(v_s, '\D', '', 'g'), '');
  v_norm := booking._norm_business_id(v_s);
  if v_norm is not null and not booking._business_id_ok(v_norm) then v_norm := null; end if;
  return coalesce((
    with inv as (
      select 0 as sort, c.company_name as sort_name, c.id as sort_id,
             booking._invoice_customer_json(c.id) || jsonb_build_object('source', 'invoice') as row
        from booking.invoice_customers c
       where lower(c.company_name) like lower(v_like) escape '\'
          or lower(coalesce(c.contact_name, '')) like lower(v_like) escape '\'
          or lower(coalesce(c.email, '')) like lower(v_like) escape '\'
          or lower(coalesce(c.business_id, '')) like lower(v_like) escape '\'
          or (v_norm is not null and booking._norm_business_id(c.business_id) = v_norm)
          or (v_digits is not null and char_length(v_digits) >= 2
              and regexp_replace(coalesce(c.business_id, ''), '\D', '', 'g') like '%' || v_digits || '%')
       order by c.company_name, c.id
       limit v_lim
    ),
    book as (
      select 1 as sort, coalesce(nullif(btrim(c.company), ''), c.name) as sort_name, c.id as sort_id,
             jsonb_build_object(
               'source', 'booking',
               'id', null,
               'customer_id', c.id,
               'company_name', coalesce(nullif(btrim(c.company), ''), btrim(c.name)),
               'contact_name', case when nullif(btrim(c.company), '') is not null then nullif(btrim(c.name), '') else null end,
               'business_id', c.business_id,
               'email', c.email,
               'phone', c.phone,
               'street', nullif(btrim(c.address), ''),
               'zip', nullif(btrim(c.zip), ''),
               'city', nullif(btrim(c.city), ''),
               'einvoice_address', c.einvoice_address,
               'einvoice_operator', c.einvoice_operator,
               'buyer_reference', c.invoice_reference
             ) as row
        from booking.customers c
       where c.anonymized_at is null
         and (
           lower(c.name) like lower(v_like) escape '\'
           or lower(coalesce(c.email, '')) like lower(v_like) escape '\'
           or lower(coalesce(c.phone, '')) like lower(v_like) escape '\'
           or lower(coalesce(c.company, '')) like lower(v_like) escape '\'
           or lower(coalesce(c.business_id, '')) like lower(v_like) escape '\'
           or (v_norm is not null and booking._norm_business_id(c.business_id) = v_norm)
           or (v_digits is not null and char_length(v_digits) >= 2
               and regexp_replace(coalesce(c.business_id, ''), '\D', '', 'g') like '%' || v_digits || '%')
         )
         and not exists (
           select 1 from inv i
            where (i.row ->> 'customer_id')::bigint = c.id
               or (
                 nullif(i.row ->> 'business_id', '') is not null
                 and booking._norm_business_id(c.business_id) is not null
                 and booking._norm_business_id(i.row ->> 'business_id') = booking._norm_business_id(c.business_id)
               )
         )
       order by 2, c.id
       limit (select greatest(v_lim - count(*)::int, 0) from inv)
    )
    select jsonb_agg(u.row order by u.sort, u.sort_name, u.sort_id)
      from (
        select * from inv
        union all
        select * from book
      ) u
  ), '[]'::jsonb);
end $function$;
