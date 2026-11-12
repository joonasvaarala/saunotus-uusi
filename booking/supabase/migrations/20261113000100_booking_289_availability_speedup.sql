-- booking_289: saatavuushaun nopeutus (ei muutoksia saatavuussääntöihin).
-- Löydös: booking.public_availability sisälsi
--     left join lateral (select _training_option_seats_left(s.rule_id) where exists (select 1 from training_segments ...)) cap on true
-- Planner ajaa lateral-alikyselyn tulosfunktion jokaiselle vuororiville ENNEN exists-ehtoa (EXPLAIN: Result loops = rivien määrä,
-- ~1 ms / rivi), vaikka vain koulutusvaihtoehtovuoroilla on training_segments-rivejä. CASE takaa laiskan arvioinnin: funktio
-- kutsutaan vain, kun exists on tosi. Muulloin left_n on null kuten ennenkin -> tulos täsmälleen sama (t289_availability_equivalence.sql).
-- Sama allekirjoitus, create or replace; muu runko on booking_269:n mukainen. Rollback: rollbacks/20261113000100_booking_289_ROLLBACK.sql
set local lock_timeout = '5s';

do $$
begin
  if md5(pg_get_functiondef('booking.public_availability(bigint,date,date)'::regprocedure)) <> 'aa5fc3442cb7141eb4a2a05f92b580dd' then
    raise exception 'booking_289: booking.public_availability poikkeaa booking_269:n määrityksestä (md5 %). Ei muutoksia.',
      md5(pg_get_functiondef('booking.public_availability(bigint,date,date)'::regprocedure));
  end if;
end $$;

CREATE OR REPLACE FUNCTION booking.public_availability(p_product_id bigint, p_from date, p_to date)
 RETURNS TABLE(rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_horizon integer;
begin
  if p_product_id is null or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 92 päivää)');
  end if;
  if not exists (select 1 from booking.product_config pc join kb.products p on p.id = pc.product_id
                  where pc.product_id = p_product_id and pc.bookable and pc.lifecycle = 'current'
                    and (
                      ('shop' = any (booking._channels_effective(pc.channels, p.category)) and pc.shop_visible)
                      or 'link' = any (booking._channels_effective(pc.channels, p.category))
                    )) then
    return;
  end if;
  v_horizon := case when exists (
      select 1 from kb.products p
      join booking.product_config pc on pc.product_id = p.id
      where p.id = p_product_id
        and (p.category = 'training' or 'link' = any (booking._channels_effective(pc.channels, p.category))))
    then 400
    else (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int end;
  return query
    select s.rule_id, s.label, s.mode, s.session_date, s.starts_at, s.ends_at,
           case when s.status = 'closed' then 'closed'
                when s.status = 'available'
                     and pc.required_skill is not null
                     and booking._therapist_slack(
                           pc.required_skill,
                           s.starts_at + make_interval(mins => coalesce(pc.therapist_offset_min, 0)),
                           least(
                             s.ends_at,
                             case
                               when pc.therapist_minutes is null then s.ends_at
                               else s.starts_at + make_interval(mins => coalesce(pc.therapist_offset_min, 0) + pc.therapist_minutes)
                             end
                           ),
                           coalesce(pc.therapists_needed, 1)
                         ) < 0 then 'unavailable'
                when s.mode = 'exclusive' and s.status = 'unavailable'
                     and booking._waitlist_private_taken(s.rule_id, s.starts_at, s.ends_at) then 'full'
                when cap.left_n is not null and (cap.left_n <= 0 or (s.status = 'available' and cap.left_n < coalesce(s.min_persons, 1))) then 'full'
                else s.status end,
           case when cap.left_n is null then s.remaining else least(s.remaining, cap.left_n) end,
           s.min_persons, s.max_persons, s.price_mode, s.unit_price, s.base_price, s.included_persons, s.extra_person_price,
           s.label_en
      from booking._sessions(greatest(p_from, (now() at time zone booking._tz())::date),
                             least(p_to, (now() at time zone booking._tz())::date + v_horizon),
                             p_product_id, true) s
      join booking.schedule_rules rr on rr.id = s.rule_id
      join booking.product_config pc on pc.product_id = s.product_id
      left join lateral (
        select case when exists (select 1 from booking.training_segments ts where ts.option_rule_id = s.rule_id)
                    then booking._training_option_seats_left(s.rule_id) end as left_n
      ) cap on true
     where s.status <> 'closed'
       and not rr.training_segment_only;
end
$function$;
