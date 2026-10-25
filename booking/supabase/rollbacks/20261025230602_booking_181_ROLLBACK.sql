-- booking_181 ROLLBACK (migraatio 20261025230602_booking_181_ritual_start_times.sql).
-- Palauttaa booking._ritual_addon_starts(timestamptz,timestamptz) tuotannon määrittelyksi täsmälleen (md5 622d94213b88d532b415e9d548785019).
-- Jo tehdyt varaukset ennallaan. Vartija: md5 on oltava booking_181:n tai tuotannon; muuten mitään ei muuteta. Oikeudet ennallaan.
set local lock_timeout = '5s';

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef('booking._ritual_addon_starts(timestamptz,timestamptz)'::regprocedure));
  if v not in ('acbdc2afdf6412c547067aec78f03414', '622d94213b88d532b415e9d548785019') then
    raise exception 'booking_181 rollback: _ritual_addon_starts md5 % ei ole booking_181:n eikä tuotannon; mitään ei muutettu', v;
  end if;
end $g$;

CREATE OR REPLACE FUNCTION booking._ritual_addon_starts(p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS SETOF timestamp with time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c jsonb := booking._ritual_addon_cfg(); v_b int; v_f int; v_s int; t timestamptz; v_out timestamptz[] := '{}';
begin
  if p_start is null or p_end is null or p_end <= p_start then return; end if;
  v_b := nullif(c ->> 'before_min', '')::int; v_f := nullif(c ->> 'first_after_min', '')::int; v_s := nullif(c ->> 'step_min', '')::int;
  if v_b is not null and v_b > 0 then v_out := v_out || (p_start - make_interval(mins => v_b)); end if;
  if coalesce((c ->> 'at_start')::boolean, false) then v_out := v_out || p_start; end if;
  if v_f is not null and v_f >= 0 then
    t := p_start + make_interval(mins => v_f);
    while t < p_end and cardinality(v_out) < 48 loop
      v_out := v_out || t;
      exit when coalesce(v_s, 0) <= 0;
      t := t + make_interval(mins => v_s);
    end loop;
  end if;
  if coalesce((c ->> 'at_end')::boolean, false) then v_out := v_out || p_end; end if;
  return query select distinct u from unnest(v_out) u order by 1;
end $function$
;
