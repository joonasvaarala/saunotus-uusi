-- =============================================================================
-- booking_140_day_notes_bulletins.sql (paketti 04: päivän muistiinpanot ja tiedotteet)
-- =============================================================================
-- Kirjoittaa vain booking-skeemaan. public-skeemaa (work_shifts, shift_assignments, staff, calendar_sources) vain luetaan.
--  1) admin_day_shifts(date): perusrooli (ei shifts.view_all) näkee päivän vuorot vain, jos hänellä itsellään on aktiivinen
--     vuoro samana Helsingin kalenteripäivänä. Peruttuja vuoromerkintöjä (shift_assignments.status ei assigned/confirmed)
--     ei enää näytetä nimenä. Sama palautusrakenne ja oikeudet kuin booking_27:ssä.
--  2) admin_next_own_shift_date(date): seuraava päivä, jolla kirjautuneella on oma aktiivinen vuoro (tai null).
--  3) admin_set_reservation_note(bigint, text): varauksen sisäinen muistiinpano (reservations.notes, enintään 1000 merkkiä).
--     Oikeus bookings.manage (sama kuin muilla varausmuutoksilla).
--  4) Uudet taulut booking.day_notes (päivän muistiinpanot) ja booking.staff_bulletins (ajastetut henkilöstötiedotteet):
--     RLS päällä, ei suoria oikeuksia authenticated/anon-rooleille, käyttö vain security definer -RPC:illä, audit-triggeri.
--  5) admin_list_day_notes / admin_save_day_note / admin_delete_day_note / admin_save_bulletin / admin_delete_bulletin.
--  6) admin_day_bundle(date): booking_133:n versio sellaisenaan (rooli, oikeudet, tuotteet, maksutavat, resurssit, näkymä,
--     9 argumentin admin_list_reservations, työvuorot, lisäpalvelut, hoitovalinnat, extras, sivutekstit) + 'notes_bundle'.
-- Uudelleenajettava (if not exists / drop trigger if exists). Ei datamuutoksia olemassa oleviin tauluihin.
-- Rollback: rollbacks/20261024084144_booking_140_ROLLBACK.sql (palauttaa booking_27:n admin_day_shifts- ja booking_133:n
-- admin_day_bundle-funktiot täsmälleen ja poistaa uudet funktiot ja taulut; HUOM: poistaa myös tallennetut muistiinpanot/tiedotteet).
-- =============================================================================

set local lock_timeout = '5s';

-- 1) päivän työvuorot
create or replace function booking.admin_day_shifts(p_date date)
returns table (shift_id uuid, starts_at timestamptz, ends_at timestamptz, role_type text, calendar_name text, staffing_status text, staff_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_me uuid;
begin
  perform booking._require_staff();
  if p_date is null then perform booking._err('invalid_range', 'Virheellinen päivä'); end if;
  v_from := p_date::timestamp at time zone 'Europe/Helsinki';
  v_to := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
  if not booking.has_permission('shifts.view_all') then
    select s.public_staff_id into v_me from booking.staff s where s.user_id = auth.uid() and s.active;
    if v_me is null then return; end if;
    if not exists (
      select 1 from public.work_shifts w
      join public.shift_assignments a on a.shift_id = w.id
      where w.status = 'active' and a.staff_id = v_me
        and a.status in ('assigned', 'confirmed')
        and w.starts_at < v_to and w.ends_at > v_from
    ) then return; end if;
  end if;
  return query
    select w.id, w.starts_at, w.ends_at, w.role_type::text,
           cs.calendar_name::text, w.staffing_status::text, ps.name::text
    from public.work_shifts w
    left join public.calendar_sources cs on cs.id = w.calendar_source_id
    left join public.shift_assignments a on a.shift_id = w.id and a.status in ('assigned', 'confirmed')
    left join public.staff ps on ps.id = a.staff_id
    where w.status = 'active' and w.starts_at < v_to and w.ends_at > v_from
    order by w.starts_at, w.id, ps.name;
end $$;
revoke all on function booking.admin_day_shifts(date) from public, anon, authenticated;
grant execute on function booking.admin_day_shifts(date) to authenticated, service_role;

-- 2) seuraava oma vuoro (oletus: tämä päivä Helsingin aikaa)
create or replace function booking.admin_next_own_shift_date(p_from_date date default null)
returns date language plpgsql stable security definer set search_path = '' as $$
declare v_me uuid; v_from date; v_result date;
begin
  perform booking._require_staff();
  v_from := coalesce(p_from_date, (now() at time zone 'Europe/Helsinki')::date);
  select s.public_staff_id into v_me from booking.staff s where s.user_id = auth.uid() and s.active;
  if v_me is null then return null; end if;
  select min(greatest((w.starts_at at time zone 'Europe/Helsinki')::date, v_from))
  into v_result
  from public.work_shifts w
  join public.shift_assignments a on a.shift_id = w.id
  where w.status = 'active' and a.staff_id = v_me
    and a.status in ('assigned', 'confirmed')
    and w.ends_at > (v_from::timestamp at time zone 'Europe/Helsinki');
  return v_result;
end $$;
revoke all on function booking.admin_next_own_shift_date(date) from public, anon, authenticated;
grant execute on function booking.admin_next_own_shift_date(date) to authenticated, service_role;

-- 3) varauksen muistiinpano
create or replace function booking.admin_set_reservation_note(p_reservation_id bigint, p_notes text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  perform booking._require_permission('bookings.manage');
  if p_reservation_id is null or char_length(coalesce(v_notes, '')) > 1000 then
    perform booking._err('invalid_note', 'Muistiinpanossa saa olla enintään 1000 merkkiä');
  end if;
  update booking.reservations set notes = v_notes where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  return jsonb_build_object('ok', true, 'reservation_id', p_reservation_id, 'notes', v_notes);
end $$;
revoke all on function booking.admin_set_reservation_note(bigint, text) from public, anon, authenticated;
grant execute on function booking.admin_set_reservation_note(bigint, text) to authenticated, service_role;

-- 4) taulut
create table if not exists booking.day_notes (
  id bigint generated always as identity primary key,
  note_date date not null,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  author_name text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table booking.day_notes is 'Päivänäkymän sisäiset muistiinpanot (booking_140). Ei suoria oikeuksia; käyttö admin_*_day_note-RPC:illä.';
create index if not exists day_notes_date_idx on booking.day_notes(note_date, created_at, id);
drop trigger if exists day_notes_updated on booking.day_notes;
create trigger day_notes_updated before update on booking.day_notes for each row execute function booking.set_updated_at();
alter table booking.day_notes enable row level security;
revoke all on booking.day_notes from public, anon, authenticated;
grant all on booking.day_notes to service_role;
drop trigger if exists audit_trg on booking.day_notes;
select booking._add_audit('booking.day_notes'::regclass);

create table if not exists booking.staff_bulletins (
  id bigint generated always as identity primary key,
  start_date date not null,
  end_date date not null check (end_date >= start_date),
  body text not null check (char_length(btrim(body)) between 1 and 4000),
  author_name text not null,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table booking.staff_bulletins is 'Ajastetut henkilöstötiedotteet päivänäkymään (booking_140). Ei suoria oikeuksia; käyttö admin_*_bulletin-RPC:illä.';
create index if not exists staff_bulletins_dates_idx on booking.staff_bulletins(start_date, end_date) where active;
drop trigger if exists staff_bulletins_updated on booking.staff_bulletins;
create trigger staff_bulletins_updated before update on booking.staff_bulletins for each row execute function booking.set_updated_at();
alter table booking.staff_bulletins enable row level security;
revoke all on booking.staff_bulletins from public, anon, authenticated;
grant all on booking.staff_bulletins to service_role;
drop trigger if exists audit_trg on booking.staff_bulletins;
select booking._add_audit('booking.staff_bulletins'::regclass);

-- 5) RPC:t
create or replace function booking.admin_list_day_notes(p_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  if p_date is null then perform booking._err('invalid_date', 'Päivä puuttuu'); end if;
  return jsonb_build_object(
    'day_notes', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at, n.id)
      from booking.day_notes n where n.note_date = p_date), '[]'::jsonb),
    'bulletins', coalesce((select jsonb_agg(to_jsonb(b) order by b.start_date, b.id)
      from booking.staff_bulletins b where b.active and p_date between b.start_date and b.end_date), '[]'::jsonb)
  );
end $$;
revoke all on function booking.admin_list_day_notes(date) from public, anon, authenticated;
grant execute on function booking.admin_list_day_notes(date) to authenticated, service_role;

create or replace function booking.admin_save_day_note(p_date date, p_body text, p_id bigint default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_name text; v_body text := btrim(coalesce(p_body, '')); v_row booking.day_notes;
begin
  perform booking._require_staff();
  if p_date is null or char_length(v_body) not between 1 and 2000 then perform booking._err('invalid_note', 'Virheellinen päivä tai muistiinpano'); end if;
  select s.name into v_name from booking.staff s where s.user_id = auth.uid() and s.active;
  if p_id is null then
    insert into booking.day_notes(note_date, body, author_name, created_by)
    values (p_date, v_body, coalesce(v_name, 'Henkilöstö'), auth.uid()) returning * into v_row;
  else
    update booking.day_notes set body = v_body
    where id = p_id and note_date = p_date
      and (created_by = auth.uid() or booking.has_permission('shifts.view_all') or booking.has_permission('settings.edit'))
    returning * into v_row;
    if not found then perform booking._err('forbidden', 'Muistiinpanoa ei löydy tai ei muokkausoikeutta'); end if;
  end if;
  return jsonb_build_object('ok', true, 'note', to_jsonb(v_row));
end $$;
revoke all on function booking.admin_save_day_note(date, text, bigint) from public, anon, authenticated;
grant execute on function booking.admin_save_day_note(date, text, bigint) to authenticated, service_role;

create or replace function booking.admin_delete_day_note(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  delete from booking.day_notes n where n.id = p_id
    and (n.created_by = auth.uid() or booking.has_permission('shifts.view_all') or booking.has_permission('settings.edit'));
  if not found then perform booking._err('forbidden', 'Muistiinpanoa ei löydy tai ei poisto-oikeutta'); end if;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;
revoke all on function booking.admin_delete_day_note(bigint) from public, anon, authenticated;
grant execute on function booking.admin_delete_day_note(bigint) to authenticated, service_role;

create or replace function booking.admin_save_bulletin(p_id bigint, p_start_date date, p_end_date date, p_body text, p_active boolean default true)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_name text; v_body text := btrim(coalesce(p_body, '')); v_row booking.staff_bulletins;
begin
  perform booking._require_permission('shifts.view_all');
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date
     or char_length(v_body) not between 1 and 4000 then
    perform booking._err('invalid_bulletin', 'Tarkista tiedotteen päivämäärät ja teksti');
  end if;
  select s.name into v_name from booking.staff s where s.user_id = auth.uid() and s.active;
  if p_id is null then
    insert into booking.staff_bulletins(start_date, end_date, body, author_name, active, created_by)
    values (p_start_date, p_end_date, v_body, coalesce(v_name, 'Henkilöstö'), coalesce(p_active, true), auth.uid()) returning * into v_row;
  else
    update booking.staff_bulletins
      set start_date = p_start_date, end_date = p_end_date, body = v_body, active = coalesce(p_active, true)
    where id = p_id returning * into v_row;
    if not found then perform booking._err('not_found', 'Tiedotetta ei löydy'); end if;
  end if;
  return jsonb_build_object('ok', true, 'bulletin', to_jsonb(v_row));
end $$;
revoke all on function booking.admin_save_bulletin(bigint, date, date, text, boolean) from public, anon, authenticated;
grant execute on function booking.admin_save_bulletin(bigint, date, date, text, boolean) to authenticated, service_role;

create or replace function booking.admin_delete_bulletin(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  perform booking._require_permission('shifts.view_all');
  delete from booking.staff_bulletins where id = p_id;
  if not found then perform booking._err('not_found', 'Tiedotetta ei löydy'); end if;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;
revoke all on function booking.admin_delete_bulletin(bigint) from public, anon, authenticated;
grant execute on function booking.admin_delete_bulletin(bigint) to authenticated, service_role;

-- 6) päivänippu: booking_133:n runko sellaisenaan + notes_bundle
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
    'site_texts', booking.public_get_site_texts(null),
    'notes_bundle', booking.admin_list_day_notes(p_date)
  );
end $fn$;
revoke all on function booking.admin_day_bundle(date) from public, anon, authenticated;
grant execute on function booking.admin_day_bundle(date) to authenticated, service_role;

comment on function booking.admin_day_bundle(date) is
  'Hallinta, vain luku: ensilatauksen ja päivänäkymän data yhdellä kutsulla (rooli, oikeudet, tuotteet, maksutavat, resurssit, näkymä, admin_list_reservations, työvuorot, lisäpalvelut, hoitovalinnat, tapahtumat/tuotto, sivutekstit, päivän muistiinpanot ja tiedotteet booking_140).';
