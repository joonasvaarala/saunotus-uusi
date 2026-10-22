-- shift_offer_functions: sääntöjen luku + vastausaika + atominen vastaus (ensimmäinen hyväksyjä voittaa).
-- Vaatii 20261022020000_shift_offer_rules.sql. Kaikki SECURITY DEFINER + search_path = '', EXECUTE vain service_rolelle.

create or replace function public.shift_week_parity(p_date date) returns text
language sql immutable set search_path = '' as $$
  select case when extract(week from p_date)::int % 2 = 0 then 'even' else 'odd' end
$$;

-- Vakiotekijä päivälle. owner_kind: staff | closed | none (ei sääntöä). follow_role ratkaistaan (1 taso).
create or replace function public.shift_default_owner(p_role text, p_date date)
returns table (owner_kind text, staff_id uuid, staff_name text, rule_id bigint, week_parity text, via_role text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_wd  smallint := extract(isodow from p_date)::smallint;
  v_par text := public.shift_week_parity(p_date);
  r     public.shift_default_owners%rowtype;
begin
  select o.* into r from public.shift_default_owners o
   where o.role_type = p_role and o.weekday = v_wd and o.week_parity in ('any', v_par)
     and p_date >= o.valid_from and (o.valid_to is null or p_date <= o.valid_to)
   order by (o.week_parity <> 'any') desc, o.priority desc, o.valid_from desc, o.id desc
   limit 1;
  if not found then
    return query select 'none'::text, null::uuid, null::text, null::bigint, v_par, null::text; return;
  end if;
  if r.owner_kind = 'follow_role' then
    return query select f.owner_kind, f.staff_id, f.staff_name, r.id, v_par, r.follow_role_type
      from public.shift_default_owner(r.follow_role_type, p_date) f;
    return;
  end if;
  return query select r.owner_kind, r.staff_id, s.name, r.id, v_par, null::text
    from (select 1) x left join public.staff s on s.id = r.staff_id;
end $$;

-- Onko henkilöllä rajoitus (ei koskaan tarjota) roolille/päivälle
create or replace function public.shift_staff_restricted(p_role text, p_staff_id uuid, p_date date) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.shift_staff_restrictions x
    where x.role_type = p_role and x.staff_id = p_staff_id
      and (x.weekdays is null or extract(isodow from p_date)::smallint = any (x.weekdays))
      and x.week_parity in ('any', public.shift_week_parity(p_date))
      and p_date >= x.valid_from and (x.valid_to is null or p_date <= x.valid_to))
$$;

-- Kierroksen ehdokkaat. Ohittaa: vakiotekijän, rajoitukset, ei-aktiiviset, roolittomat.
-- p_starts/p_ends annettuna lisäksi: staff_unavailability-päällekkäisyys ja päällekkäinen vuoro (sama rooli tai conflicting_roles).
-- rotation: kaikki ehdokkaat aakkosjärjestyksessä alkaen osoittimen jälkeisestä (moottori ottaa group_size kerrallaan).
create or replace function public.shift_offer_candidates(
  p_role text, p_date date, p_round_no int, p_scenario text default 'vacant_shift',
  p_starts timestamptz default null, p_ends timestamptz default null)
returns table (staff_id uuid, staff_name text, round_kind text, sort_order int)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_wd    smallint := extract(isodow from p_date)::smallint;
  v_par   text := public.shift_week_parity(p_date);
  v_round public.shift_offer_rounds%rowtype;
  v_owner uuid;
  v_kind  text;
  v_set   public.shift_offer_settings%rowtype;
begin
  select o.staff_id, o.owner_kind into v_owner, v_kind from public.shift_default_owner(p_role, p_date) o;
  if v_kind in ('closed','not_offered') then return; end if;   -- suljettu päivä / pe vastaanotto: ei koskaan ehdokkaita
  select * into v_set from public.shift_offer_settings s where s.role_type = p_role;
  select r.* into v_round from public.shift_offer_rounds r
   where r.role_type = p_role and r.scenario = p_scenario and r.round_no = p_round_no and v_wd = any (r.weekdays)
     and p_date >= r.valid_from and (r.valid_to is null or p_date <= r.valid_to)
   order by r.valid_from desc limit 1;
  if not found then return; end if;

  return query
  with rounds as (
    select r.* from public.shift_offer_rounds r
     where r.role_type = p_role and r.scenario = p_scenario and v_wd = any (r.weekdays)
       and p_date >= r.valid_from and (r.valid_to is null or p_date <= r.valid_to)),
  named_all as (   -- kaikkien nimettyjen kierrosten jäsenet (pariteetti huomioiden)
    select m.staff_id, r.kind from rounds r join public.shift_offer_round_members m on m.round_id = r.id
     where r.kind in ('named','named_last') and m.week_parity in ('any', v_par)),
  pool as (
    select m.staff_id, m.sort_order::int as so from public.shift_offer_round_members m
     where v_round.kind in ('named','named_last') and m.round_id = v_round.id and m.week_parity in ('any', v_par)
    union all
    select rr.staff_id, 0 from public.staff_roles rr
     where v_round.kind in ('rotation','all') and rr.role_type = p_role and rr.active
       and rr.staff_id not in (select n.staff_id from named_all n where v_round.kind = 'all' and n.kind = 'named_last'
                               union all select n.staff_id from named_all n where v_round.kind = 'rotation')),
  ok as (
    select p.staff_id, s.name, p.so from pool p
      join public.staff s on s.id = p.staff_id and s.active
     where exists (select 1 from public.staff_roles rr where rr.staff_id = p.staff_id and rr.role_type = p_role and rr.active)
       and p.staff_id is distinct from v_owner
       and not public.shift_staff_restricted(p_role, p.staff_id, p_date)
       and (p_starts is null or not exists (select 1 from public.staff_unavailability u
              where u.staff_id = p.staff_id and u.starts_at < coalesce(p_ends, p_starts + interval '1 minute') and u.ends_at > p_starts))
       and (p_starts is null or not exists (select 1 from public.shift_assignments a join public.work_shifts w on w.id = a.shift_id
              where a.staff_id = p.staff_id and a.status in ('assigned','confirmed') and w.status = 'active'
                and ((w.role_type = p_role
                      and w.starts_at < coalesce(p_ends, p_starts + interval '1 minute')
                      and coalesce(w.ends_at, w.starts_at + interval '1 minute') > p_starts)
                  or (w.role_type = any (coalesce(v_set.conflicting_roles, '{}')) and v_wd = any (v_set.conflict_weekdays)
                      and not exists (select 1 from jsonb_array_elements(coalesce(v_set.conflict_exemptions, '[]'::jsonb)) e
                                       where (e->>'staff_id')::uuid = p.staff_id
                                         and (e->'weekdays' is null or e->'weekdays' @> to_jsonb(v_wd::int)))
                      and case when v_set.conflict_same_day
                               then (w.starts_at at time zone v_set.timezone)::date = (p_starts at time zone v_set.timezone)::date
                               else w.starts_at < coalesce(p_ends, p_starts + interval '1 minute')
                                    and coalesce(w.ends_at, w.starts_at + interval '1 minute') > p_starts end)))))
  select ok.staff_id, ok.name, v_round.kind,
         case when v_round.kind = 'rotation'
              then (row_number() over (order by (ok.name <= coalesce((select s2.name from public.staff s2 where s2.id = v_set.rotation_last_staff_id), '')), ok.name))::int
              else ok.so end
    from ok
   order by 4, 2;
end $$;

-- Takaraja = alku + vastausaika. quiet_mode = shift_deadline (oletus, Joonas 22.10.): kalenteriaika (paikallinen seinäkello),
-- ja jos takaraja osuu välille [quiet_start, quiet_end) eli 21:00–07:59, se siirtyy seuraavaan klo 8:aan. pause = vanha yöpysäytys.
create or replace function public.shift_add_active_time(p_from timestamptz, p_dur interval, p_role text)
returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare
  s      public.shift_offer_settings%rowtype;
  v_cur  timestamp; v_left interval := p_dur; v_qs timestamp; v_qe timestamp; v_end timestamp;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  if not found then raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002'; end if;
  v_cur := p_from at time zone s.timezone;
  if s.quiet_mode = 'shift_deadline' then
    v_end := v_cur + p_dur;   -- paikallinen seinäkello: ke 12:00 + 7 vrk = seur. ke 12:00 myös kesäajan vaihtuessa
    if v_end::time >= s.quiet_start then v_end := (v_end::date + 1) + s.quiet_end;
    elsif v_end::time < s.quiet_end then v_end := v_end::date + s.quiet_end; end if;
    return v_end at time zone s.timezone;
  end if;
  for i in 1..1000 loop   -- pause
    if v_cur::time >= s.quiet_start then v_cur := (v_cur::date + 1) + s.quiet_end;
    elsif v_cur::time < s.quiet_end then v_cur := v_cur::date + s.quiet_end; end if;
    v_qs := v_cur::date + s.quiet_start;
    if v_cur + v_left <= v_qs then return (v_cur + v_left) at time zone s.timezone; end if;
    v_left := v_left - (v_qs - v_cur);
    v_cur := v_qs;
  end loop;
  raise exception 'shift_add_active_time: liian pitkä kesto %', p_dur;
end $$;

-- Vastausaika ja takaraja kierrokselle. direct_to_all = lähetä heti kaikille (alle porras / alle all_by_before).
create or replace function public.shift_offer_wait(p_role text, p_shift_starts timestamptz, p_now timestamptz default now(), p_last_round boolean default false)
returns table (tier_id bigint, direct_to_all boolean, wait interval, deadline_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  s public.shift_offer_settings%rowtype;
  t public.shift_offer_response_tiers%rowtype;
  v_wait interval; v_dl timestamptz;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  if not found then raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002'; end if;
  select x.* into t from public.shift_offer_response_tiers x
   where (x.role_type = p_role or x.role_type is null) and p_now + x.min_lead <= p_shift_starts
   order by x.min_lead desc, (x.role_type is not null) desc limit 1;
  if not found or t.direct_to_all or p_shift_starts - s.all_by_before <= p_now then
    return query select t.id, true, null::interval, null::timestamptz; return;
  end if;
  v_wait := case when p_last_round then coalesce(t.wait_last_round, t.wait) else t.wait end;
  v_dl := public.shift_add_active_time(p_now, v_wait, p_role);
  if not p_last_round then v_dl := least(v_dl, p_shift_starts - s.all_by_before); end if;
  return query select t.id, false, v_wait, v_dl;
end $$;

-- Sääntö 9: tarvitseeko palvelu (closure_calendars.code) sulun päivälle annetulla hoitajalla (null = vakiohoitaja).
create or replace function public.shift_service_closure_needed(p_service text, p_date date, p_therapist uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_wd smallint := extract(isodow from p_date)::smallint;
  v_ov text; v_kind text; v_staff uuid;
begin
  select o.mode into v_ov from public.shift_service_date_overrides o where o.service_code = p_service and o.on_date = p_date;
  if v_ov = 'open'   then return jsonb_build_object('needs_closure', false, 'reason', 'date_override_open'); end if;
  if v_ov = 'closed' then return jsonb_build_object('needs_closure', true,  'reason', 'date_override_closed'); end if;
  select d.owner_kind, d.staff_id into v_kind, v_staff from public.shift_default_owner('therapist', p_date) d;
  if p_therapist is null and v_kind = 'closed' then
    return jsonb_build_object('needs_closure', true, 'reason', 'therapist_closed');
  end if;
  v_staff := coalesce(p_therapist, v_staff);
  if not exists (select 1 from public.shift_service_allowed_therapists a where a.service_code = p_service and a.weekday = v_wd
                   and p_date >= a.valid_from and (a.valid_to is null or p_date <= a.valid_to)) then
    return jsonb_build_object('needs_closure', false, 'reason', 'no_rule');
  end if;
  if v_staff is not null and exists (select 1 from public.shift_service_allowed_therapists a where a.service_code = p_service and a.weekday = v_wd
                   and a.staff_id = v_staff and p_date >= a.valid_from and (a.valid_to is null or p_date <= a.valid_to)) then
    return jsonb_build_object('needs_closure', false, 'reason', 'allowed_therapist', 'therapist', v_staff);
  end if;
  return jsonb_build_object('needs_closure', true, 'reason', case when v_staff is null then 'no_therapist' else 'therapist_not_allowed' end, 'therapist', v_staff);
end $$;

-- ATOMINEN VASTAUS: accept | decline | snooze. Tarjousrivi lukitaan (FOR UPDATE) -> rinnakkaiset vastaukset sarjoittuvat;
-- lisäksi uniikki indeksi (yksi 'accepted' / tarjous). Ensimmäinen hyväksyjä voittaa, muut -> filled_other (ilmoitettavat palautetaan).
-- p_apply: vacant_shift-hyväksyntä kirjataan heti shift_apply_change(assign, source offer_engine); virhe talteen, hyväksyntä pysyy.
create or replace function public.shift_offer_respond(
  p_offer_id uuid, p_staff_id uuid, p_response text,
  p_snooze_until timestamptz default null, p_apply boolean default true, p_actor text default 'tyovuoro-tapio')
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  o   public.shift_offers%rowtype;
  r   public.shift_offer_recipients%rowtype;
  s   public.shift_offer_settings%rowtype;
  v_starts timestamptz; v_until timestamptz; v_res jsonb; v_notify jsonb; v_open int;
begin
  if p_response is null or p_response not in ('accept','decline','snooze') then
    raise exception 'Tuntematon vastaus % (accept, decline, snooze)', p_response using errcode = '22023';
  end if;
  select * into o from public.shift_offers x where x.id = p_offer_id for update;
  if not found then raise exception 'Tarjousta ei löytynyt' using errcode = 'P0002'; end if;
  select * into r from public.shift_offer_recipients x where x.offer_id = p_offer_id and x.staff_id = p_staff_id for update;
  if not found or r.status in ('queued','withdrawn') then
    return jsonb_build_object('result', 'not_recipient');
  end if;

  if o.status = 'filled' then
    if o.accepted_staff_id = p_staff_id then return jsonb_build_object('result', 'already_yours'); end if;
    if r.status in ('pending','snoozed','declined') and p_response = 'accept' then
      update public.shift_offer_recipients set status = 'filled_other', snooze_until = null, responded_at = coalesce(responded_at, now())
       where id = r.id;
    end if;
    return jsonb_build_object('result', 'already_filled', 'winner_staff_id', o.accepted_staff_id, 'accepted_at', o.accepted_at);
  end if;
  if o.status not in ('active','paused','escalated') then
    return jsonb_build_object('result', 'offer_closed', 'offer_status', o.status);
  end if;

  if p_response = 'accept' then
    if r.status not in ('pending','snoozed','declined') then
      return jsonb_build_object('result', 'invalid_state', 'recipient_status', r.status);
    end if;
    update public.shift_offer_recipients set status = 'accepted', responded_at = now(), snooze_until = null where id = r.id;
    with x as (
      update public.shift_offer_recipients set status = case when sent_at is null then 'withdrawn' else 'filled_other' end,
             snooze_until = null
       where offer_id = o.id and id <> r.id and status in ('queued','pending','snoozed')
      returning staff_id, sent_at)
    select coalesce(jsonb_agg(staff_id), '[]'::jsonb) into v_notify from x where sent_at is not null;
    -- myös aiemmin kieltäytyneet, joille tarjous lähti, saavat "täytetty"-tiedon
    v_notify := v_notify || coalesce((select jsonb_agg(x.staff_id) from public.shift_offer_recipients x
                  where x.offer_id = o.id and x.status = 'declined' and x.sent_at is not null), '[]'::jsonb);
    update public.shift_offers set status = 'filled', accepted_staff_id = p_staff_id, accepted_recipient_id = r.id,
           accepted_at = now(), next_action_at = null, updated_at = now() where id = o.id;
    if p_apply and o.scenario = 'vacant_shift' then
      begin
        v_res := public.shift_apply_change('assign', o.shift_id, p_staff_id, null, null, null, 'offer_engine', p_actor, p_staff_id,
                                           'Tarjous ' || o.id::text, null);
        update public.shift_offers set assignment_result = v_res where id = o.id;
      exception when others then
        update public.shift_offers set assignment_error = sqlstate || ': ' || sqlerrm where id = o.id;
        v_res := jsonb_build_object('error', sqlstate || ': ' || sqlerrm);
      end;
    end if;
    return jsonb_build_object('result', 'accepted', 'offer_id', o.id, 'shift_id', o.shift_id, 'staff_id', p_staff_id,
                              'notify_filled_staff_ids', v_notify, 'assignment', v_res);
  end if;

  if p_response = 'decline' then
    if r.status not in ('pending','snoozed') then
      return jsonb_build_object('result', 'invalid_state', 'recipient_status', r.status);
    end if;
    update public.shift_offer_recipients set status = 'declined', responded_at = now(), snooze_until = null where id = r.id;
    select count(*) into v_open from public.shift_offer_recipients x
     where x.offer_id = o.id and x.round_no = o.current_round_no and x.status in ('pending','snoozed');
    update public.shift_offers set updated_at = now() where id = o.id;
    return jsonb_build_object('result', 'declined', 'round_all_declined', v_open = 0,
      'any_open', exists (select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.status in ('pending','snoozed')));
  end if;

  -- snooze ("Palaan asiaan <pvm>")
  select * into s from public.shift_offer_settings x where x.role_type = o.role_type;
  if not (coalesce(s.snooze_any_recipient, false) or p_staff_id = any (coalesce(s.snooze_staff_ids, '{}'))) then
    return jsonb_build_object('result', 'snooze_not_allowed', 'reason', 'staff');
  end if;
  if r.status not in ('pending','snoozed') or p_snooze_until is null or p_snooze_until <= now() then
    return jsonb_build_object('result', 'invalid_state', 'recipient_status', r.status);
  end if;
  select coalesce(o.window_starts_at, w.starts_at) into v_starts from public.work_shifts w where w.id = o.shift_id;
  v_until := least(p_snooze_until, v_starts - s.snooze_min_left);
  if v_until <= now() then return jsonb_build_object('result', 'snooze_not_allowed', 'reason', 'too_close'); end if;
  update public.shift_offer_recipients set status = 'snoozed', snooze_until = v_until, responded_at = now() where id = r.id;
  return jsonb_build_object('result', 'snoozed', 'snooze_until', v_until, 'shortened', v_until < p_snooze_until);
end $$;

-- Tyhjä vuoro kaikkien kierrosten jälkeen (Joonas 22.10. klo 2.41): kysytään exhausted_ask_staff_id:ltä enintään exhausted_ask_count kertaa,
-- kerran / exhausted_ask_interval (1 vrk), tiiviimmin lähellä vuoroa: väli = jäljellä oleva aika jaettuna jäljellä olevilla kysymyksillä + 1,
-- kuitenkin vähintään exhausted_ask_min_interval. Kysymykset vain klo 8–21 (yöhön osuva siirtyy klo 8). Kaikki kysytty ilman vastausta
-- -> close (jos auto_close_enabled), muuten wait_owner. Sulku viimeistään vuoron alkaessa.
create or replace function public.shift_exhausted_next_step(
  p_role text, p_shift_starts timestamptz, p_asks_done int, p_last_ask_at timestamptz default null, p_now timestamptz default now())
returns table (action text, due_at timestamptz, ask_no int)
language plpgsql stable security definer set search_path = '' as $$
declare
  s public.shift_offer_settings%rowtype;
  v_base timestamptz; v_left int; v_gap interval; v_at timestamptz;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  if not found then raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002'; end if;
  v_left := s.exhausted_ask_count - coalesce(p_asks_done, 0);
  if coalesce(p_asks_done, 0) = 0 then
    v_at := public.shift_add_active_time(p_now, interval '0', p_role);   -- heti (tai klo 8)
    return query select 'ask'::text, least(v_at, p_shift_starts), 1; return;
  end if;
  v_base := coalesce(p_last_ask_at, p_now);
  v_gap := greatest(s.exhausted_ask_min_interval, least(s.exhausted_ask_interval, (p_shift_starts - v_base) / (greatest(v_left, 0) + 1)));
  if v_left <= 0 then
    v_gap := coalesce(s.auto_close_after, v_gap);
    v_at := least(public.shift_add_active_time(v_base, v_gap, p_role), p_shift_starts);
    return query select case when s.auto_close_enabled then 'close' else 'wait_owner' end, v_at, null::int; return;
  end if;
  v_at := least(public.shift_add_active_time(v_base, v_gap, p_role), p_shift_starts);
  return query select 'ask'::text, v_at, coalesce(p_asks_done, 0) + 1;
end $$;

-- Saako roolille/päivälle tarjota ollenkaan: ei, jos vakiotekijäsääntö on closed (esim. hoidot pe, parittomat ma)
-- tai not_offered (pe vastaanotto = vuoron lämmittäjä tai tapahtuman vetäjä, Joonas 22.10. klo 2.37).
create or replace function public.shift_offer_allowed(p_role text, p_date date) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select o.owner_kind not in ('closed','not_offered') from public.shift_default_owner(p_role, p_date) o), true)
$$;

-- KOVA TAKUU: tarjousta ei voi luoda päivälle, jolle ei tarjota (shift_offer_allowed = false). Päivä = vuoron/ikkunan Helsingin päivä.
create or replace function public.shift_offers_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_tz text; v_at timestamptz; v_date date;
begin
  select s.timezone into v_tz from public.shift_offer_settings s where s.role_type = new.role_type;
  select coalesce(new.window_starts_at, w.starts_at) into v_at from public.work_shifts w where w.id = new.shift_id;
  v_date := (coalesce(v_at, new.window_starts_at) at time zone coalesce(v_tz, 'Europe/Helsinki'))::date;
  if v_date is not null and not public.shift_offer_allowed(new.role_type, v_date) then
    raise exception 'Roolille % ei tarjota päivälle % (vakiotekijäsääntö closed/not_offered)', new.role_type, v_date
      using errcode = 'P0001', hint = 'Perjantain vastaanotto ja suljetut hoitopäivät eivät kuulu tarjousmoottorille.';
  end if;
  return new;
end $$;
drop trigger if exists shift_offers_guard_trg on public.shift_offers;
create trigger shift_offers_guard_trg before insert or update of shift_id, role_type, window_starts_at on public.shift_offers
  for each row execute function public.shift_offers_guard();

revoke all on function public.shift_offers_guard(), public.shift_offer_allowed(text, date),
  public.shift_exhausted_next_step(text, timestamptz, int, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.shift_offers_guard(), public.shift_offer_allowed(text, date), public.shift_exhausted_next_step(text, timestamptz, int, timestamptz, timestamptz) to service_role;

revoke all on function public.shift_week_parity(date), public.shift_default_owner(text, date), public.shift_staff_restricted(text, uuid, date),
  public.shift_offer_candidates(text, date, int, text, timestamptz, timestamptz), public.shift_add_active_time(timestamptz, interval, text),
  public.shift_offer_wait(text, timestamptz, timestamptz, boolean), public.shift_service_closure_needed(text, date, uuid),
  public.shift_offer_respond(uuid, uuid, text, timestamptz, boolean, text)
  from public, anon, authenticated;
grant execute on function public.shift_week_parity(date), public.shift_default_owner(text, date), public.shift_staff_restricted(text, uuid, date),
  public.shift_offer_candidates(text, date, int, text, timestamptz, timestamptz), public.shift_add_active_time(timestamptz, interval, text),
  public.shift_offer_wait(text, timestamptz, timestamptz, boolean), public.shift_service_closure_needed(text, date, uuid),
  public.shift_offer_respond(uuid, uuid, text, timestamptz, boolean, text)
  to service_role;
