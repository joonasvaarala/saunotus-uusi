-- booking_272 ROLLBACK: palauttaa public.shift_offer_wait edelliseen migraatiohistorian määritelmään:
-- PROD 20261022003917 shift_offer_engine. Aja booking_273-rollbackin jälkeen, jos molemmat perutaan.
create or replace function public.shift_offer_wait(p_role text, p_shift_starts timestamptz, p_now timestamptz default now(), p_last_round boolean default false)
returns table (tier_id bigint, direct_to_all boolean, wait interval, deadline_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  s public.shift_offer_settings%rowtype;
  t public.shift_offer_response_tiers%rowtype;
  v_wait interval; v_dl timestamptz; v_all_by timestamptz;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  if not found then raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002'; end if;
  v_all_by := public.shift_offer_all_by_at(p_role, p_shift_starts);
  select x.* into t from public.shift_offer_response_tiers x
   where (x.role_type = p_role or x.role_type is null) and p_now + x.min_lead <= p_shift_starts
   order by x.min_lead desc, (x.role_type is not null) desc limit 1;
  if not found or t.direct_to_all or v_all_by <= p_now then
    return query select t.id, true, null::interval, null::timestamptz; return;
  end if;
  v_wait := case when p_last_round then coalesce(t.wait_last_round, t.wait) else t.wait end;
  v_dl := public.shift_add_active_time(p_now, v_wait, p_role);
  if not p_last_round then v_dl := least(v_dl, v_all_by); end if;
  return query select t.id, false, v_wait, v_dl;
end $$;
