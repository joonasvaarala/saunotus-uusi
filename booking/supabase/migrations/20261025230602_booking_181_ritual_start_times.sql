-- booking_181: saunotusrituaali alkaa vain klo 16.00, 16.30 tai 17.00 (Europe/Helsinki) myös yleisen vuoron lisäpalveluna.
-- VÄLIAIKAINEN versio 20261026100000 (Bottiavustus ajaa tuotantoon ja nimeää tuotantoversioksi ennen mergeä). Ei public-skeemaa.
-- Hinnat, ALV, slugit, URLit ja asetukset ennallaan; vain yksi funktio muuttuu.
--
-- Nykytila (tuotanto sxbofnuisemspgquoxyv, luettu 26.10.2026):
--   * Paketti kb 7 (Saunarituaali ja savusaunavuoro) ja pelkkä rituaali kb 8 (Saunotusrituaali): product_config.time_window_class = 'ritual'
--     → booking.time_window_rules (ritual, weekday/weekend).allowed_starts = {16:00,16:30,17:00}. Data, jota käyttävät
--     _time_window_violation (saatavuus _treatment_availability_core, myös upsell _upsell_day_slots), _treatment_slot_check
--     (verkkovaraus, upsell-liitos) ja trigger reservations_time_window (kaikki varaukset). Paketin rituaali alkaa paketin alussa
--     (therapist_offset_min 0), joten paketin alku = rituaalin alku. Näihin ei tarvita muutosta.
--   * Rituaali lisäpalveluna (booking_166, asetus ritual_addon, tuote kb 8): ajat tulevat funktiosta _ritual_addon_starts(vuoron alku, loppu)
--     (alku − 30, alku, alku + 30, + 90 …, loppu) eivätkä noudata allowed_starts-listaa (esim. vuoro 14.00 → 13.30, 14.00, 14.30, 15.30, 16.00).
--     Samaa funktiota käyttävät public_ritual_addon (kaupan ajat), _ritual_addon_attach (varaus) ja _ritual_addon_start_ok
--     (reservations_time_window-poikkeus), joten muutos tähän yhteen funktioon riittää: näytetyt ja varattavat ajat sekä trigger.
--
-- Oikeudet (CREATE OR REPLACE säilyttää: vain service_role) ennallaan.
-- Muutos: _ritual_addon_starts poimii ehdokkaat rituaalituotteen (asetus ritual_addon.product_id) aikaluokan allowed_starts-listasta
-- (sama data kuin paketilla ja pelkällä rituaalilla) vuoron päivältä ja pitää ne, jotka osuvat vuoron ikkunaan
-- [alku − before_min, loppu) (+ loppu, jos at_end). Prod-asetuksella (before_min 30, at_end true) la–su-vuorot:
--   14.00 → 16.00 · 14.30 → 16.00, 16.30 · 15.00, 16.00 → 16.00, 16.30, 17.00 · 16.30 → 16.00, 16.30, 17.00 · 17.00 → 16.30, 17.00 ·
--   tunnin vuorot 14.00 ja 18.00 → ei aikoja (lisäpalvelu piiloutuu, kuten kun aikoja ei ole).
-- Jos luokalla ei ole allowed_starts-listaa, vanha sääntö (asetuksen kentät) ennallaan.
--
-- Vartija: md5(pg_get_functiondef) = tuotanto 622d94213b88d532b415e9d548785019 tai jo tämä migraatio (acbdc2afdf6412c547067aec78f03414); lisäksi tuotannon data
-- (allowed_starts, kb 7/8 aikaluokka, asetuksen tuote) on tarkistettava. Muuten keskeytys eikä mitään muuteta. Uudelleenajettava.
-- Rollback: rollbacks/20261026100000_booking_181_ROLLBACK.sql. Testi: tests/t181_ritual_start_times.sql (PG17, fixtures/10_test_helpers.sql).
set local lock_timeout = '5s';

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef('booking._ritual_addon_starts(timestamptz,timestamptz)'::regprocedure));
  if v not in ('622d94213b88d532b415e9d548785019', 'acbdc2afdf6412c547067aec78f03414') then
    raise exception 'booking_181: _ritual_addon_starts md5 % ei vastaa tuotantoa; mitään ei muutettu', v;
  end if;
  if (select count(*) from booking.time_window_rules where class = 'ritual' and day_type in ('weekday', 'weekend')
        and allowed_starts = array['16:00', '16:30', '17:00']::time[]) <> 2 then
    raise exception 'booking_181: time_window_rules (ritual).allowed_starts ei ole {16:00,16:30,17:00}; mitään ei muutettu';
  end if;
  if (select count(*) from booking.product_config where product_id in (7, 8) and time_window_class = 'ritual') <> 2 then
    raise exception 'booking_181: kb 7 / kb 8 aikaluokka ei ole ritual; mitään ei muutettu';
  end if;
  if (select value ->> 'product_id' from booking.settings where key = 'ritual_addon') is distinct from '8' then
    raise exception 'booking_181: asetuksen ritual_addon.product_id ei ole 8; mitään ei muutettu';
  end if;
end $g$;

CREATE OR REPLACE FUNCTION booking._ritual_addon_starts(p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS SETOF timestamp with time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c jsonb := booking._ritual_addon_cfg(); v_b int; v_f int; v_s int; t timestamptz; v_out timestamptz[] := '{}';
  v_d date; v_allowed time[];
begin
  if p_start is null or p_end is null or p_end <= p_start then return; end if;
  v_b := nullif(c ->> 'before_min', '')::int; v_f := nullif(c ->> 'first_after_min', '')::int; v_s := nullif(c ->> 'step_min', '')::int;
  -- booking_181: rituaalin sallitut alkuajat (time_window_rules.allowed_starts, sama kuin paketilla kb 7 ja rituaalilla kb 8) vuoron ikkunassa
  -- [alku − before_min, loppu), loppu mukaan jos at_end. Ei listaa → vanha sääntö alla.
  v_d := (p_start at time zone booking._tz())::date;
  select w.allowed_starts into v_allowed
    from booking.product_config pc join booking.time_window_rules w on w.class = pc.time_window_class
   where pc.product_id = nullif(c ->> 'product_id', '')::bigint
     and w.day_type = case when extract(isodow from v_d) >= 6 then 'weekend' else 'weekday' end;
  if v_allowed is not null then
    return query select distinct x.u from (select (v_d + a) at time zone booking._tz() as u from unnest(v_allowed) a) x
      where x.u >= p_start - make_interval(mins => greatest(coalesce(v_b, 0), 0))
        and (x.u < p_end or (x.u = p_end and coalesce((c ->> 'at_end')::boolean, false)))
      order by 1;
    return;
  end if;
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
end $function$;
