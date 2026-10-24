-- ROLLBACK booking_145_giftcard_list_search. Palauttaa booking_44:n tilan täsmälleen.
-- * admin_list_gift_cards booking_44:n määrittelynä (pg_get_functiondef booking_143:n jälkeisestä kannasta; sama prosrc-md5 kuin
--   tuotannossa 24.10.2026). Oikeudet ennallaan (create or replace säilyttää ne).
-- * Poistaa apufunktion _gc_product_name.
-- Data: ei datamuutoksia. Voidaan ajaa useasti.
set local lock_timeout = '5s';

CREATE OR REPLACE FUNCTION booking.admin_list_gift_cards(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_kind text DEFAULT NULL::text, p_package text DEFAULT NULL::text, p_vat_treatment text DEFAULT NULL::text, p_unverified boolean DEFAULT NULL::boolean, p_expiring_days integer DEFAULT NULL::integer, p_has_balance boolean DEFAULT NULL::boolean, p_sort text DEFAULT 'created_desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_norm text; v_res jsonb; v_today date := booking._gc_today(); v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  if coalesce(p_sort, 'created_desc') not in ('created_desc', 'created_asc', 'valid_to_asc', 'valid_to_desc', 'balance_desc', 'balance_asc', 'initial_desc', 'initial_asc') then perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if p_status is not null and p_status not in ('active', 'used', 'expired', 'cancelled', 'pending_verification', 'pending_payment') then perform booking._err('invalid_param', 'Virheellinen tila'); end if;
  v_norm := booking.gift_code_norm(v_s);
  with f as (
    select g.* from booking.gift_cards g
     where (v_s is null or (char_length(v_norm) >= 4 and g.code like '%' || v_norm || '%')
            or g.buyer_name ilike '%' || v_s || '%' or g.buyer_email ilike '%' || v_s || '%' or g.recipient_name ilike '%' || v_s || '%' or g.recipient_email ilike '%' || v_s || '%'
            or (v_s ~ '^\d{1,10}$' and exists (select 1 from booking.orders o where o.id = g.purchase_order_id and (o.order_no = v_s::bigint or o.johku_order_no = v_s::bigint))))
       and (p_status is null or case when p_status = 'expired' then (g.status = 'expired' or (g.status = 'active' and g.valid_to < v_today)) when p_status = 'active' then g.status = 'active' and (g.valid_to is null or g.valid_to >= v_today) else g.status = p_status end)
       and (p_source is null or g.source = p_source) and (p_kind is null or g.kind = p_kind) and (p_package is null or g.package_code = p_package)
       and (p_vat_treatment is null or g.vat_treatment = p_vat_treatment) and (p_unverified is null or g.balance_verified = not p_unverified)
       and (p_expiring_days is null or (g.status = 'active' and g.valid_to between v_today and v_today + p_expiring_days))
       and (p_has_balance is null or (g.balance > 0) = p_has_balance)
  ), s as (
    select count(*) c, coalesce(sum(balance), 0) sb, coalesce(sum(initial_amount), 0) si,
           coalesce(sum(balance) filter (where status = 'active' and (valid_to is null or valid_to >= v_today)), 0) sr from f
  ), r as (
    select f.*, row_number() over (order by
        (case when p_sort = 'valid_to_asc' then f.valid_to end) asc nulls last, (case when p_sort = 'valid_to_desc' then f.valid_to end) desc nulls last,
        (case when p_sort = 'balance_desc' then f.balance end) desc, (case when p_sort = 'balance_asc' then f.balance end) asc,
        (case when p_sort = 'initial_desc' then f.initial_amount end) desc, (case when p_sort = 'initial_asc' then f.initial_amount end) asc,
        (case when p_sort = 'created_asc' then f.created_at end) asc, f.created_at desc, f.id desc) rn from f
  )
  select jsonb_build_object('total', s.c, 'sum_balance', s.sb, 'sum_initial', s.si, 'sum_balance_redeemable', s.sr,
      'rows', coalesce((select jsonb_agg(booking._gc_card_json(g2, true) order by r.rn) from r join booking.gift_cards g2 on g2.id = r.id where r.rn > v_off and r.rn <= v_off + v_lim), '[]'::jsonb))
    into v_res from s;
  return v_res;
end $function$
;

drop function if exists booking._gc_product_name(booking.gift_cards);
