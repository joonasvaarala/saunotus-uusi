-- booking_272: lähellä olevilla vuoroilla (porras alle 14 vrk, asetus shift_offer.tier_end_within_max_lead)
-- kierroksen pituus valitaan niin, että kierros päättyy vielä oman porrasvälinsä sisällä.
-- Jos porrasvälin vastausaika veisi kierroksen yli rajan (esim. 7 vrk 22 h ennen vuoroa + 24 h -> alle 7 vrk),
-- käytetään seuraavaa lyhyempää porrasta (6 h). "Suoraan kaikille" valitaan edelleen pelkän alkuun jäljellä olevan ajan perusteella.
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
  if not p_last_round then v_dl := least(v_dl, v_all_by); end if;
  return query select t.id, false, v_wait, v_dl;
end $function$;
