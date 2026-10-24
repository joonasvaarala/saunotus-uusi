-- =============================================================================
-- ROLLBACK booking_140: palauttaa admin_day_bundle-funktion booking_133:n tilaan ja admin_day_shifts-funktion
-- booking_27:n tilaan (runko, kommentti ja oikeudet kopioitu sellaisenaan), poistaa booking_140:n uudet RPC:t
-- sekä taulut booking.day_notes ja booking.staff_bulletins.
-- HUOM: poistaa tauluihin tallennetut päivän muistiinpanot ja tiedotteet (ota tarvittaessa talteen ensin).
-- reservations.notes-sarakkeeseen tallennetut varausmuistiinpanot säilyvät (sarake on ollut olemassa jo ennen).
-- Uudelleenajettava (drop ... if exists).
-- =============================================================================

set local lock_timeout = '5s';

-- booking_133 (sellaisenaan)
create or replace function booking.admin_day_bundle(p_date date)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_from timestamptz := (p_date::timestamp at time zone booking._tz());
  v_to timestamptz := ((p_date + 1)::timestamp at time zone booking._tz());
begin
  perform booking._require_staff();
  if p_date is null then perform booking._err('invalid_date', 'Päivä puuttuu'); end if;
  return jsonb_build_object(
    'date', p_date,
    'role', booking.current_staff_role(),
    'permissions', booking.admin_my_permissions(),
    'products', booking.admin_list_products(),
    'payment_methods', coalesce((select jsonb_agg(to_jsonb(pm) order by pm.sort_order, pm.code)
       from (select code, label, is_manual, active, sort_order from booking.payment_methods) pm), '[]'::jsonb),
    'resources', coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from booking.resources r), '[]'::jsonb),
    'view', booking.admin_day_view(p_date),
    'reservations', coalesce((select jsonb_agg(to_jsonb(x) order by x.starts_at desc, x.reservation_id desc)
       from booking.admin_list_reservations(v_from, v_to, null, null, null, 200, 0, null, null) x), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.shift_id, s.staff_name nulls last)
       from booking.admin_day_shifts(p_date) s), '[]'::jsonb),
    'addons', booking.admin_list_addons(),
    'options', booking.admin_list_product_options(null),
    'extras', booking.admin_day_extras(p_date),
    'site_texts', booking.public_get_site_texts(null)
  );
end $fn$;
revoke all on function booking.admin_day_bundle(date) from public, anon, authenticated;
grant execute on function booking.admin_day_bundle(date) to authenticated, service_role;

comment on function booking.admin_day_bundle(date) is
  'Hallinta, vain luku: ensilatauksen ja päivänäkymän data yhdellä kutsulla (rooli, oikeudet, tuotteet, maksutavat, resurssit, näkymä, admin_list_reservations, työvuorot, lisäpalvelut, hoitovalinnat, tapahtumat/tuotto, sivutekstit).';

-- booking_27 (sellaisenaan)
create or replace function booking.admin_day_shifts(p_date date)
returns table (shift_id uuid, starts_at timestamptz, ends_at timestamptz, role_type text, calendar_name text, staffing_status text, staff_name text)
language plpgsql stable security definer set search_path = '' as $$
declare v_from timestamptz; v_to timestamptz;
begin
  perform booking._require_staff();
  if p_date is null then perform booking._err('invalid_range', 'Virheellinen päivä'); end if;
  v_from := p_date::timestamp at time zone 'Europe/Helsinki';
  v_to := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
  return query
    select ws.id, ws.starts_at, ws.ends_at, ws.role_type::text, cs.calendar_name::text, ws.staffing_status::text, ps.name::text
      from public.work_shifts ws
      left join public.calendar_sources cs on cs.id = ws.calendar_source_id
      left join public.shift_assignments sa on sa.shift_id = ws.id
      left join public.staff ps on ps.id = sa.staff_id
     where ws.status = 'active' and ws.starts_at < v_to and ws.ends_at > v_from
     order by ws.starts_at, ws.id, ps.name;
end $$;
revoke all on function booking.admin_day_shifts(date) from public, anon, authenticated;
grant execute on function booking.admin_day_shifts(date) to authenticated;
grant execute on function booking.admin_day_shifts(date) to service_role;

-- Poista uudet funktiot ennen taulujen poistoa.
drop function if exists booking.admin_delete_bulletin(bigint);
drop function if exists booking.admin_save_bulletin(bigint, date, date, text, boolean);
drop function if exists booking.admin_delete_day_note(bigint);
drop function if exists booking.admin_save_day_note(date, text, bigint);
drop function if exists booking.admin_list_day_notes(date);
drop function if exists booking.admin_set_reservation_note(bigint, text);
drop function if exists booking.admin_next_own_shift_date(date);
drop table if exists booking.staff_bulletins;
drop table if exists booking.day_notes;
