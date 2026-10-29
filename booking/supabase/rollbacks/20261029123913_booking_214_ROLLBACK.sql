-- ROLLBACK booking_214: palauttaa saatavuuden ja henkilökunnan lippujen määritykset booking_213-tilaan (PROD 29.10.2026 ennen 20261029123913).
-- HUOM: palauttaa myös NULL-vuodon (suljetut hoitoajat näkyvät kirjautuneelle henkilökunnalle vapaina). Aja vain jos booking_214 aiheuttaa vakavan ongelman.

CREATE OR REPLACE FUNCTION booking._staff_overbook()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select current_setting('booking.allow_overbook', true) = 'on' and coalesce(booking.is_admin(), false)
$function$;

CREATE OR REPLACE FUNCTION booking._staff_off_schedule()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select current_setting('booking.allow_off_schedule', true) = 'on' and coalesce(booking.has_permission('bookings.manage'), false)
$function$;

CREATE OR REPLACE FUNCTION booking._treatment_availability_core(p_product_id bigint, p_from date, p_to date, p_persons integer, p_admin boolean, p_override boolean)
 RETURNS TABLE(product_id bigint, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, duration_minutes integer, status text, persons integer, total numeric, price_type text, base_price numeric, included_persons integer, extra_person_price numeric, unit_price numeric, therapist_missing boolean, needs_override boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  pc booking.product_config; p kb.products; v_horizon integer := coalesce((booking._setting('public_treatment_horizon_days', '14'::jsonb) #>> '{}')::int, 14);
  v_lead integer := case when p_admin then 0 else coalesce((booking._setting('public_treatment_min_lead_minutes', '120'::jsonb) #>> '{}')::int, 120) end;
  v_today date := (now() at time zone booking._tz())::date; d date; t time; v_s timestamptz; v_e timestamptz; v_dur integer; v_total numeric; v_to date; v_st text; v_need boolean;
  v_day_ok boolean; v_win text;
begin
  select * into pc from booking.product_config x where x.product_id = p_product_id;
  if not found or pc.lifecycle <> 'current' then return; end if;
  if not p_admin and not (pc.public_slots and pc.bookable and pc.shop_visible) then return; end if;
  select * into p from kb.products x where x.id = p_product_id and x.active;
  if not found then return; end if;
  if p_persons is null or p_persons < greatest(coalesce(pc.min_persons, 1), 1) or p_persons > booking._treatment_max_persons(p_product_id) then return; end if;
  v_dur := coalesce(pc.duration_minutes, p.duration_minutes);
  v_total := booking._treatment_price(p_product_id, p_persons);
  v_to := case when p_admin then p_to else least(p_to, v_today + v_horizon) end;
  d := greatest(p_from, v_today);
  while d <= v_to loop
    v_day_ok := (pc.public_weekdays is null or extract(isodow from d)::smallint = any (pc.public_weekdays)) and booking._public_shift_day_open(d);
    if v_day_ok or (p_admin and p_override) then
      for t in select (g.m * interval '30 minutes')::time from generate_series(case when p_admin and p_override then 16 else 24 end, case when p_admin and p_override then 47 else 46 end) g(m) loop
        v_s := (d + t) at time zone booking._tz();
        v_e := v_s + make_interval(mins => v_dur);
        continue when v_s < now() + make_interval(mins => v_lead);
        v_win := booking._time_window_violation(p_product_id, v_s, v_e);
        v_need := (not v_day_ok) or v_win is not null;
        continue when v_need and not (p_admin and p_override);
        v_st := booking._treatment_plan_status(p_product_id, v_s, v_e, p_persons);
        continue when v_st is null;
        product_id := p_product_id; session_date := d; starts_at := v_s; ends_at := v_e; duration_minutes := v_dur; status := 'available'; persons := p_persons; total := v_total;
        price_type := p.price_type; base_price := p.price; included_persons := p.included_persons; extra_person_price := p.extra_person_price;
        unit_price := case when p.price_type = 'per_person' then p.price end;
        therapist_missing := (v_st = 'therapist_missing'); needs_override := v_need;
        return next;
      end loop;
    end if;
    d := d + 1;
  end loop;
  return;
end $function$;

drop function if exists booking._public_treatment_slot_status(bigint, timestamptz, integer);
