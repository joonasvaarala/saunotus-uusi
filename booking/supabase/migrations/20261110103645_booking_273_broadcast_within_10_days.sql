-- booking_273 (Joonas 10.11.2026 klo 12.34, pt1567u): alle 10 vrk vuoroon -> suoraan kaikille.
-- Raja on asetus shift_offer.broadcast_within (oletus 10 days; arvo voi olla myös roolikohtainen olio {"heater":"10 days"}).
-- Korvaa all_by_before 3 vrk -säännön ja alle 2 vrk -portaan (käytetään suurempaa: greatest(all_by_before, broadcast_within)).
insert into booking.settings (key, value, updated_at)
values ('shift_offer.broadcast_within', '"10 days"'::jsonb, now())
on conflict (key) do update set value = excluded.value, updated_at = now();

CREATE OR REPLACE FUNCTION public.shift_offer_all_by_at(p_role text, p_shift_starts timestamp with time zone)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s public.shift_offer_settings%rowtype;
  v timestamp;
  v_cfg jsonb; v_bw interval; v_before interval;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  if not found then raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002'; end if;
  -- booking_273: kaikille-raja = suurempi asetuksista all_by_before ja shift_offer.broadcast_within
  v_cfg := booking.shift_offer_cfg('broadcast_within');
  begin
    v_bw := case when jsonb_typeof(v_cfg) = 'object' then (v_cfg ->> p_role)::interval
                 when v_cfg is not null then (v_cfg #>> '{}')::interval end;
  exception when others then v_bw := null;
  end;
  v_before := greatest(s.all_by_before, coalesce(v_bw, s.all_by_before));
  v := (p_shift_starts - v_before) at time zone s.timezone;
  if s.all_by_quiet = 'previous_evening' then
    if v::time >= s.quiet_start then
      v := v::date + s.quiet_start;
    elsif v::time < s.quiet_end then
      v := (v::date - 1) + s.quiet_start;
    end if;
    return v at time zone s.timezone;
  end if;
  -- exact: ei iltasiirtoa, mutta hetki ei saa jäädä hiljaiseen aikaan
  return public.shift_add_active_time(v at time zone s.timezone, interval '0', p_role);
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_wait(p_role text, p_shift_starts timestamp with time zone, p_now timestamp with time zone DEFAULT now(), p_last_round boolean DEFAULT false)
 RETURNS TABLE(tier_id bigint, direct_to_all boolean, wait interval, deadline_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s public.shift_offer_settings%rowtype;
  t public.shift_offer_response_tiers%rowtype;
  t2 public.shift_offer_response_tiers%rowtype;
  v_wait interval; v_dl timestamptz; v_all_by timestamptz; v_near interval;
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
  -- booking_272: porras, jonka sisällä kierros myös päättyy (alku + porrasväli + vastausaika <= vuoron alku).
  -- Jos mikään ei täytä ehtoa, käytetään lyhintä ei-suoraa porrasta.
  v_near := booking.shift_offer_cfg_interval('tier_end_within_max_lead', null, interval '14 days');
  if v_near is not null and t.min_lead < v_near then
  select x.* into t2 from public.shift_offer_response_tiers x
   where (x.role_type = p_role or x.role_type is null) and not x.direct_to_all and x.min_lead <= t.min_lead
     and p_now + x.min_lead + case when p_last_round then coalesce(x.wait_last_round, x.wait) else x.wait end <= p_shift_starts
   order by x.min_lead desc, (x.role_type is not null) desc limit 1;
  if not found then
    select x.* into t2 from public.shift_offer_response_tiers x
     where (x.role_type = p_role or x.role_type is null) and not x.direct_to_all and x.min_lead <= t.min_lead
     order by x.min_lead asc, (x.role_type is not null) desc limit 1;
  end if;
  if found then t := t2; end if;
  end if;
  v_wait := case when p_last_round then coalesce(t.wait_last_round, t.wait) else t.wait end;
  v_dl := public.shift_add_active_time(p_now, v_wait, p_role);
  -- booking_273: mikään kierros (myös viimeinen ei-kaikille-kierros) ei veny kaikille-rajan yli
  v_dl := least(v_dl, v_all_by);
  return query select t.id, false, v_wait, v_dl;
end $function$;
