-- booking_172: yritysasiakkaat löytyvät hallinnan asiakashausta (Uusi varaus ja Uusi lasku).
-- VÄLIAIKAINEN versio 20261025010500: EI ajettu tuotantoon. Bottiavustus ajaa (apply_migration nimellä booking_172_company_customer_search)
-- ja nimeää tiedoston tuotannon version mukaan. Ei public-skeemaa. Ei muuta dataa (vain funktioita).
--
-- Virhe (Joonas 25.10.): haku löytää henkilöasiakkaat, mutta yritysasiakkaat eivät näy Uusi varaus- eikä Uusi lasku -haussa.
-- Juurisyy: Johku-tuonnissa yritystilauksen yritystiedot (yritys, y-tunnus, osoite, verkkolasku) ovat vain tilauksella (orders.billing);
--   asiakasrekisterin rivi (booking.customers) on yhteyshenkilö, customer_kind = private, company/business_id tyhjiä.
--   Tuotanto 25.10.2026 (SELECT, vain määrät): 220 yritystilausta (219 Johku), 151 eri yritystä (105 y-tunnuksella, 51 verkkolaskutiedoilla),
--   mutta booking.customers: 4 yritysasiakasta (company täytetty 4, y-tunnus 2); 211/220 yritystilauksen asiakasrivillä ei yritystä.
--   admin_list_customers ja admin_search_invoice_customers hakevat vain booking.customers (+ invoice_customers) → yritystä ei löydy nimellä eikä y-tunnuksella.
-- Korjaus (ei datamuutoksia, rekisteri ennallaan):
--   uusi booking._order_company_hits(text,int): yritykset tilausten laskutustiedoista, yksi rivi / yritys (y-tunnus tai nimi), uusimman tilauksen tiedot;
--     haku yrityksen nimellä, y-tunnuksella (myös ilman väliviivaa / osanumeroilla), yhteyshenkilöllä ja sähköpostilla. Ei anon/authenticated-oikeuksia.
--   uusi booking.admin_search_customers(text,int) (Uusi varaus -haku, _require_staff): rekisterin asiakkaat (source customer) +
--     tilausten yritykset (source orders), jotka eivät jo ole osumissa (sama y-tunnus / nimi).
--   booking.admin_search_invoice_customers(text,int): + tilausten yritykset (source booking, origin orders) laskutusasiakkaiden jälkeen,
--     ennen henkilöitä. Paluumuoto ennallaan (jsonb-taulukko, samat kentät).
--   admin_list_customers ennallaan (Asiakkaat-näkymä, pikahaku).
--
-- Vartija: korvattavan funktion md5(pg_get_functiondef) on oltava tuotannon (luettu sxbofnuisemspgquoxyv 25.10.2026) tai jo tämän migraation;
-- uudet funktiot eivät saa olla olemassa muulla sisällöllä. Muuten ajo keskeytyy eikä mitään muuteta. Uudelleenajettava.
--   booking.admin_search_invoice_customers(text,integer): 3d8de7f0154e173583efa97a04616ea7 -> 0b6a95a0bb492fe96632c719ff72e42c
--   uusi booking._order_company_hits(text,integer): 007c407a3fb71e6ee9098796ca34f57c
--   uusi booking.admin_search_customers(text,integer): 6ab4f8a588a792ca3af0614a20ceb659
-- Rollback: rollbacks/20261025010500_booking_172_ROLLBACK.sql. Testi: tests/customers/t172_company_customer_search.sql (paikallinen PG17).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking.admin_search_invoice_customers(text,integer)'::regprocedure));
  if v not in ('3d8de7f0154e173583efa97a04616ea7', '0b6a95a0bb492fe96632c719ff72e42c') then ok := false; msg := msg || ' admin_search_invoice_customers=' || v; end if;
  if to_regprocedure('booking._order_company_hits(text,integer)') is not null then
    v := md5(pg_get_functiondef('booking._order_company_hits(text,integer)'::regprocedure));
    if v <> '007c407a3fb71e6ee9098796ca34f57c' then ok := false; msg := msg || ' _order_company_hits=' || v; end if;
  end if;
  if to_regprocedure('booking.admin_search_customers(text,integer)') is not null then
    v := md5(pg_get_functiondef('booking.admin_search_customers(text,integer)'::regprocedure));
    if v <> '6ab4f8a588a792ca3af0614a20ceb659' then ok := false; msg := msg || ' admin_search_customers=' || v; end if;
  end if;
  if not ok then raise exception 'booking_172: funktioiden md5 ei ole tuotannon eikä booking_172:n (%); mitään ei muutettu', msg; end if;
end $g$;

-- ===== uusi: booking._order_company_hits(text, integer): yritykset tilausten laskutustiedoista (orders.billing), yksi rivi / yritys
create or replace function booking._order_company_hits(p_search text, p_limit integer default 10)
returns table(company_key text, customer_id bigint, company text, business_id text, contact_name text, email text, phone text,
              street text, zip text, city text, country text, einvoice_address text, einvoice_operator text,
              orders_count bigint, last_order_at timestamp with time zone)
language plpgsql stable security definer set search_path = '' as $f$
#variable_conflict use_column
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_like text; v_digits text; v_norm text;
  v_lim int := least(greatest(coalesce(p_limit, 10), 1), 50);
begin
  if v_s is null or char_length(v_s) < 2 then return; end if;
  v_like := lower('%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%');
  v_digits := nullif(regexp_replace(v_s, '\D', '', 'g'), '');
  v_norm := booking._norm_business_id(v_s);
  if v_norm is not null and not booking._business_id_ok(v_norm) then v_norm := null; end if;
  return query
  with b as (
    select o.id as oid, o.created_at as ts, o.customer_id as cid, o.billing as bl,
           btrim(o.billing ->> 'company') as co,
           booking._norm_business_id(nullif(btrim(coalesce(o.billing ->> 'business_id', '')), '')) as bid,
           c.name as cname, c.email as cemail, c.phone as cphone
      from booking.orders o
      join booking.customer_kinds k on k.code = o.customer_kind and k.is_company
      join booking.customers c on c.id = o.customer_id and c.anonymized_at is null
     where jsonb_typeof(o.billing) = 'object'
       and char_length(btrim(coalesce(o.billing ->> 'company', ''))) >= 2
  ), kb as (
    select b.*, case when b.bid is not null and booking._business_id_ok(b.bid) then b.bid else 'n:' || lower(b.co) end as ckey from b
  ), hit as (
    select distinct kb.ckey from kb
     where lower(kb.co) like v_like escape '\'
        or lower(coalesce(kb.bl ->> 'business_id', '')) like v_like escape '\'
        or (v_norm is not null and kb.bid = v_norm)
        or (v_digits is not null and char_length(v_digits) >= 2 and regexp_replace(coalesce(kb.bid, ''), '\D', '', 'g') like '%' || v_digits || '%')
        or lower(coalesce(kb.bl ->> 'contact_name', '')) like v_like escape '\'
        or lower(coalesce(kb.bl ->> 'name', '')) like v_like escape '\'
        or lower(coalesce(kb.cname, '')) like v_like escape '\'
        or lower(coalesce(kb.bl ->> 'contact_email', '')) like v_like escape '\'
        or lower(coalesce(kb.bl ->> 'email', '')) like v_like escape '\'
        or lower(coalesce(kb.cemail, '')) like v_like escape '\'
  ), agg as (
    select kb.ckey, count(*) as cnt, max(kb.ts) as last_ts from kb join hit on hit.ckey = kb.ckey group by kb.ckey
  ), latest as (
    select distinct on (kb.ckey) kb.* from kb join hit on hit.ckey = kb.ckey order by kb.ckey, kb.ts desc, kb.oid desc
  )
  select l.ckey, l.cid, l.co,
         case when l.ckey like 'n:%' then nullif(btrim(coalesce(l.bl ->> 'business_id', '')), '') else l.bid end,
         coalesce(nullif(btrim(coalesce(l.bl ->> 'contact_name', '')), ''), nullif(btrim(coalesce(l.bl ->> 'name', '')), ''), nullif(btrim(coalesce(l.cname, '')), '')),
         coalesce(nullif(btrim(coalesce(l.bl ->> 'contact_email', '')), ''), nullif(btrim(coalesce(l.bl ->> 'email', '')), ''), nullif(btrim(coalesce(l.cemail, '')), '')),
         coalesce(nullif(btrim(coalesce(l.bl ->> 'contact_phone', '')), ''), nullif(btrim(coalesce(l.cphone, '')), '')),
         coalesce(nullif(btrim(coalesce(l.bl ->> 'street', '')), ''), nullif(btrim(coalesce(l.bl ->> 'address', '')), '')),
         nullif(btrim(coalesce(l.bl ->> 'zip', '')), ''),
         nullif(btrim(coalesce(l.bl ->> 'city', '')), ''),
         nullif(upper(btrim(coalesce(l.bl ->> 'country', ''))), ''),
         nullif(upper(regexp_replace(coalesce(l.bl ->> 'einvoice_address', ''), '\s', '', 'g')), ''),
         nullif(upper(regexp_replace(coalesce(l.bl ->> 'einvoice_operator', ''), '\s', '', 'g')), ''),
         a.cnt, a.last_ts
    from latest l join agg a on a.ckey = l.ckey
   order by a.last_ts desc, l.ckey
   limit v_lim;
end $f$;
comment on function booking._order_company_hits(text, integer) is 'booking_172: yritysasiakkaat tilausten laskutustiedoista (Johku-tuonti: yhteyshenkilö on asiakasrekisterissä yksityisenä, yritys vain orders.billing). Haku: yrityksen nimi, y-tunnus, yhteyshenkilö, sähköposti.';
revoke all on function booking._order_company_hits(text, integer) from public, anon, authenticated;

-- ===== uusi: booking.admin_search_customers(text, integer): Uusi varaus -haku (henkilöt + yritykset rekisteristä ja tilauksilta)
create or replace function booking.admin_search_customers(p_search text default null, p_limit integer default 8)
returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_like text; v_digits text; v_norm text;
  v_lim int := least(greatest(coalesce(p_limit, 8), 1), 20);
begin
  perform booking._require_staff();
  if v_s is null or char_length(v_s) < 2 then return '[]'::jsonb; end if;
  v_like := lower('%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%');
  v_digits := nullif(regexp_replace(v_s, '\D', '', 'g'), '');
  v_norm := booking._norm_business_id(v_s);
  if v_norm is not null and not booking._business_id_ok(v_norm) then v_norm := null; end if;
  return coalesce((
    with cust as (
      select 0 as sort, c.created_at as ts, c.id as sid,
             booking._norm_business_id(c.business_id) as nbid, lower(nullif(btrim(c.company), '')) as lco,
             jsonb_build_object(
               'source', 'customer', 'id', c.id, 'customer_id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone,
               'company', c.company, 'business_id', c.business_id, 'customer_kind', c.customer_kind, 'customer_type', c.customer_type,
               'street', nullif(btrim(c.address), ''), 'zip', nullif(btrim(c.zip), ''), 'city', nullif(btrim(c.city), ''), 'country', c.country,
               'einvoice_address', c.einvoice_address, 'einvoice_operator', c.einvoice_operator, 'invoice_reference', c.invoice_reference
             ) as row
        from booking.customers c
       where c.anonymized_at is null
         and (lower(c.name) like v_like escape '\'
              or lower(coalesce(c.email, '')) like v_like escape '\'
              or lower(coalesce(c.phone, '')) like v_like escape '\'
              or lower(coalesce(c.company, '')) like v_like escape '\'
              or lower(coalesce(c.business_id, '')) like v_like escape '\'
              or (v_norm is not null and booking._norm_business_id(c.business_id) = v_norm)
              or (v_digits is not null and char_length(v_digits) >= 2
                  and regexp_replace(coalesce(c.business_id, ''), '\D', '', 'g') like '%' || v_digits || '%'))
       order by c.created_at desc, c.id desc
       limit v_lim
    ),
    comp as (
      select 1 as sort, h.last_order_at as ts, h.customer_id as sid,
             jsonb_build_object(
               'source', 'orders', 'id', null, 'customer_id', h.customer_id, 'name', h.contact_name, 'email', h.email, 'phone', h.phone,
               'company', h.company, 'business_id', h.business_id, 'customer_kind', 'company', 'customer_type', null,
               'street', h.street, 'zip', h.zip, 'city', h.city, 'country', h.country,
               'einvoice_address', h.einvoice_address, 'einvoice_operator', h.einvoice_operator,
               'orders_count', h.orders_count, 'last_order_at', h.last_order_at
             ) as row
        from booking._order_company_hits(v_s, v_lim) h
       where not exists (
         select 1 from cust x
          where (h.business_id is not null and x.nbid is not null and x.nbid = booking._norm_business_id(h.business_id))
             or (x.lco is not null and x.lco = lower(h.company))
       )
    )
    select jsonb_agg(u.row order by u.sort, u.ts desc, u.sid)
      from (select sort, ts, sid, row from cust union all select sort, ts, sid, row from comp) u
  ), '[]'::jsonb);
end $f$;
comment on function booking.admin_search_customers(text, integer) is 'booking_172: Uusi varaus -asiakashaku. Rekisterin asiakkaat (source customer) + yritykset aiempien tilausten laskutustiedoista (source orders). Yritys: nimi, y-tunnus, yhteyshenkilö, sähköposti.';
revoke all on function booking.admin_search_customers(text, integer) from public, anon;
grant execute on function booking.admin_search_customers(text, integer) to authenticated, service_role;

-- ===== korvattava: booking.admin_search_invoice_customers(text, integer): + yritykset tilausten laskutustiedoista (source booking, origin orders)
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
    bk as (
      select c.id, coalesce(nullif(btrim(c.company), ''), c.name) as sort_name,
             booking._norm_business_id(c.business_id) as nbid, lower(nullif(btrim(c.company), '')) as lco,
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
    ),
    -- booking_172: yritykset aiempien tilausten laskutustiedoista (Johku-tuonnissa yritys on vain orders.billing-kentässä)
    ord as (
      select 1 as sort, h.company as sort_name, h.customer_id as sort_id,
             jsonb_build_object(
               'source', 'booking',
               'origin', 'orders',
               'id', null,
               'customer_id', h.customer_id,
               'company_name', h.company,
               'contact_name', h.contact_name,
               'business_id', h.business_id,
               'email', h.email,
               'phone', h.phone,
               'street', h.street,
               'zip', h.zip,
               'city', h.city,
               'country', h.country,
               'einvoice_address', h.einvoice_address,
               'einvoice_operator', h.einvoice_operator,
               'buyer_reference', null
             ) as row
        from booking._order_company_hits(v_s, v_lim) h
       where not exists (
               select 1 from inv i
                where (h.business_id is not null and nullif(i.row ->> 'business_id', '') is not null
                       and booking._norm_business_id(i.row ->> 'business_id') = booking._norm_business_id(h.business_id))
                   or lower(btrim(i.row ->> 'company_name')) = lower(h.company)
             )
         and not exists (
               select 1 from bk x
                where (h.business_id is not null and x.nbid is not null and x.nbid = booking._norm_business_id(h.business_id))
                   or (x.lco is not null and x.lco = lower(h.company))
             )
       order by h.last_order_at desc, h.company_key
       limit (select greatest(v_lim - count(*)::int, 0) from inv)
    ),
    book as (
      select 2 as sort, bk.sort_name, bk.id as sort_id, bk.row
        from bk
       order by bk.sort_name, bk.id
       limit (select greatest(v_lim - (select count(*)::int from inv) - (select count(*)::int from ord), 0))
    )
    select jsonb_agg(u.row order by u.sort, u.sort_name, u.sort_id)
      from (
        select * from inv
        union all
        select * from ord
        union all
        select * from book
      ) u
  ), '[]'::jsonb);
end $function$
;
