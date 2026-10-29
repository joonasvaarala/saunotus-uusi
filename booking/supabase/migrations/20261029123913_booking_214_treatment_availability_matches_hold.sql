-- booking_214: hoitojen saatavuus näyttää vain ajat, jotka pito (public_create_treatment_booking) myös hyväksyy.
--
-- Bugi (Joonas 29.10.2026): testisivulla Saunahoito/Hunajahoito la 31.10. klo 13.00 ja 13.30 näkyivät vapaina, vaikka hoidot on suljettu
-- (closure_events 'hoidot' → space_blocks saunottaja). Pito hylkäsi: "Valittu aika ei ole enää vapaana". Sama perinnesaunotuksessa
-- (Saunotus/Syväsaunotus) päivinä, joina 'perinnesaunotus'-kalenteri on kiinni (space_blocks perinnesaunotus_ryhma).
--
-- Juurisyy: booking._staff_off_schedule() ja booking._staff_overbook() palauttivat NULL eivätkä false, kun
--   * GUC booking.allow_off_schedule / booking.allow_overbook ei ollut koskaan asetettu tietokantayhteydessä (current_setting(..., true) → NULL), ja
--   * kutsujalla oli henkilökunnan oikeus (bookings.manage / admin) — eli kun henkilökunta on kirjautuneena samassa selaimessa kuin verkkokauppa.
--   _check_claim: "if not p_override and not v_os and exists(sulku)" → not NULL = NULL → ehto ei toteudu → SULKU OHITETAAN.
--   Saatavuushaku (public_treatment_availability → _treatment_availability_core → _treatment_plan_status → _plan_legs → _check_claim) ei nollannut
--   lippuja, joten se näytti suljetut ajat (saunottaja-sulku → no_therapist → "therapist_missing" → näytetään vapaana).
--   Pito (public_create_treatment_booking → _treatment_slot_check) kutsuu _clear_staff_overrides() → liput 'off' → sulku tarkistetaan → slot_unavailable.
--   Anonyymi asiakas: has_permission() = false → NULL AND false = false → sulku tarkistetaan → ei bugia oikeille asiakkaille.
--
-- Korjaus:
--   1) Liput palauttavat aina true/false (coalesce) → sulku/kapasiteetti tarkistetaan aina, ellei henkilökunta ole erikseen virittänyt ylitystä
--      (_arm_staff_overrides). Korjaa saman NULL-vuodon myös _resolve_session-, reservations_stamp_overrides- ja reservations_time_window-poluissa.
--   2) Yhteinen apufunktio booking._public_treatment_slot_status(): täsmälleen pidon tarkistukset (_treatment_slot_check: tuoteliput, henkilömäärä,
--      30 min ruudukko, minimi-ilmoitusaika, varausikkuna, viikonpäivä + yleisen vuoron päivä auki, hoitoaikaikkuna/20:00-sääntö, rituaalin alkuajat)
--      + sama resurssisuunnittelu kuin pidossa (_plan_legs, saunottajan/tilojen sulut, varaukset, kapasiteetti). Julkinen saatavuus käyttää tätä
--      jokaiselle ajalle, joten saatavuus ja pito eivät voi enää erota.
--   3) _treatment_availability_core nollaa henkilökunnan liput alussa. Hallinnan ylityshaku (p_admin and p_override) näyttää suljetun ajan
--      vain needs_override = true -merkinnällä (aiemmin se näkyi satunnaisesti ilman merkintää NULL-vuodon takia).

create or replace function booking._staff_overbook()
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  select coalesce(current_setting('booking.allow_overbook', true), '') = 'on' and coalesce(booking.is_admin(), false)
$function$;

create or replace function booking._staff_off_schedule()
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  select coalesce(current_setting('booking.allow_off_schedule', true), '') = 'on' and coalesce(booking.has_permission('bookings.manage'), false)
$function$;

-- Yhteinen julkisen hoitoajan tarkistus: NULL = ei varattavissa; 'ok' / 'therapist_missing' = pito hyväksyy ajan.
create or replace function booking._public_treatment_slot_status(p_product bigint, p_start timestamptz, p_persons integer)
 returns text
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_end timestamptz;
begin
  begin
    v_end := booking._treatment_slot_check(p_product, p_start, p_persons, true);   -- samat esitarkistukset kuin pidossa; nollaa henkilökunnan liput
  exception when sqlstate 'BK001' then
    return null;
  end;
  return booking._treatment_plan_status(p_product, p_start, v_end, p_persons);     -- sama _plan_legs kuin _create_legs_booking
end $function$;

revoke all on function booking._public_treatment_slot_status(bigint, timestamptz, integer) from public, anon, authenticated;

create or replace function booking._treatment_availability_core(p_product_id bigint, p_from date, p_to date, p_persons integer, p_admin boolean, p_override boolean)
 returns table(product_id bigint, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, duration_minutes integer, status text, persons integer, total numeric, price_type text, base_price numeric, included_persons integer, extra_person_price numeric, unit_price numeric, therapist_missing boolean, needs_override boolean)
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  pc booking.product_config; p kb.products; v_horizon integer := coalesce((booking._setting('public_treatment_horizon_days', '14'::jsonb) #>> '{}')::int, 14);
  v_lead integer := case when p_admin then 0 else coalesce((booking._setting('public_treatment_min_lead_minutes', '120'::jsonb) #>> '{}')::int, 120) end;
  v_today date := (now() at time zone booking._tz())::date; d date; t time; v_s timestamptz; v_e timestamptz; v_dur integer; v_total numeric; v_to date; v_st text; v_need boolean;
  v_day_ok boolean; v_win text;
begin
  -- booking_214: saatavuus ei koskaan peri henkilökunnan ylityslippuja (eikä NULL-tilaa); ylitys ilmaistaan vain p_override-parametrilla.
  perform booking._clear_staff_overrides();
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
        if p_admin then
          v_st := booking._treatment_plan_status(p_product_id, v_s, v_e, p_persons);
          if v_st is null and p_override then
            -- ylityshaku: suljettu aika näytetään vain ylitystä vaativana (luonti vaatii p_override + perustelun)
            perform set_config('booking.allow_off_schedule', 'on', true);
            v_st := booking._treatment_plan_status(p_product_id, v_s, v_e, p_persons);
            perform booking._clear_staff_overrides();
            if v_st is not null then v_need := true; end if;
          end if;
        else
          -- julkinen: täsmälleen samat säännöt kuin pidossa (public_create_treatment_booking)
          v_st := booking._public_treatment_slot_status(p_product_id, v_s, p_persons);
        end if;
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
