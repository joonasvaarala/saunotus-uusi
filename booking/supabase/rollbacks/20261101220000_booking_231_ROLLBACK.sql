-- Rollback booking_231: admin_list_voucher_claims palaa booking_48-versioon (ei varauskenttiä eikä value_cardia listassa).
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function booking.admin_list_voucher_claims(p_status text default null, p_search text default null, p_limit integer default 100, p_offset integer default 0, p_sort text default 'oldest_open')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_norm text; v_total int; v_rows jsonb; v_sort text := coalesce(nullif(btrim(p_sort), ''), 'oldest_open');
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  if p_status is not null and p_status not in ('open', 'processing', 'redeemed', 'problem', 'cancelled', 'expired', 'active', 'needs_review') then perform booking._err('invalid_status', 'Tuntematon tila'); end if;
  if v_sort not in ('oldest_open', 'newest') then perform booking._err('invalid_sort', 'Järjestys: oldest_open tai newest'); end if;
  v_norm := case when v_s is null then null else booking.gift_code_norm(v_s) end;
  with f as (
    select c.id, c.status, c.created_at from booking.voucher_claims c join booking.orders o on o.id = c.order_id
     where (p_status is null or (p_status = 'active' and c.status in ('open', 'processing', 'problem')) or (p_status = 'needs_review' and c.needs_review) or (p_status not in ('active', 'needs_review') and c.status = p_status))
       and (v_s is null or c.customer_name ilike '%' || v_s || '%' or c.customer_email ilike '%' || v_s || '%' or o.order_no::text = v_s or c.id::text = v_s
            or (char_length(v_norm) >= 4 and c.code like '%' || v_norm || '%'))
  ), pg as (
    select id from f order by (status in ('open', 'processing', 'problem')) desc,
           case when v_sort = 'oldest_open' and status in ('open', 'processing', 'problem') then created_at end asc nulls last, created_at desc, id desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500) offset greatest(coalesce(p_offset, 0), 0)
  )
  select (select count(*) from f), coalesce((select jsonb_agg(booking._vc_json(c, false) order by (c.status in ('open', 'processing', 'problem')) desc,
           case when v_sort = 'oldest_open' and c.status in ('open', 'processing', 'problem') then c.created_at end asc nulls last, c.created_at desc, c.id desc)
           from booking.voucher_claims c where c.id in (select id from pg)), '[]'::jsonb)
    into v_total, v_rows;
  return jsonb_build_object('ok', true, 'total', v_total, 'sort', v_sort, 'claims', v_rows);
end $$;

revoke all on function booking.admin_list_voucher_claims(text, text, integer, integer, text) from public, anon, authenticated;
grant execute on function booking.admin_list_voucher_claims(text, text, integer, integer, text) to service_role, authenticated;

comment on function booking.admin_list_voucher_claims(text, text, integer, integer, text) is
  'booking_48: lunastuspyyntöjen lista. Koodi maskattuna.';
