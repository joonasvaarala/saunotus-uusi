-- booking_172 ROLLBACK: palauttaa booking.admin_search_invoice_customers tuotannon määrittelyyn (md5 3d8de7f0154e173583efa97a04616ea7)
-- ja poistaa booking.admin_search_customers sekä booking._order_company_hits. Ei datamuutoksia. Uudelleenajettava.
-- Vartija: nykyinen md5 on oltava booking_172:n (0b6a95a0bb492fe96632c719ff72e42c) tai jo tuotannon; muuten keskeytyy.
set local lock_timeout = '5s';

do $g$
declare v text := md5(pg_get_functiondef('booking.admin_search_invoice_customers(text,integer)'::regprocedure));
begin
  if v not in ('0b6a95a0bb492fe96632c719ff72e42c', '3d8de7f0154e173583efa97a04616ea7') then
    raise exception 'booking_172 rollback: admin_search_invoice_customers md5 % ei ole booking_172:n eikä tuotannon; mitään ei muutettu', v;
  end if;
end $g$;

drop function if exists booking.admin_search_customers(text, integer);

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

drop function if exists booking._order_company_hits(text, integer);
