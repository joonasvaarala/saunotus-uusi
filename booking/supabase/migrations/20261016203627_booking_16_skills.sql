-- APPLIED 2026-10-16 klo 23.36 (Europe/Helsinki): versio 20261016203627 (booking_16_skills) via apply_migration; sama SQL kuin tässä tiedostossa (sisältää pseudonyymit staff-UUID:t, ei nimiä).
-- 16_skills (Joonas hyväksyi ajon chatissa 16.10.2026; schema booking; public.* ja kb.* vain luku)
-- Sisältö (DESIGN_resources_v2.md B4, §0d/§0e):
--  * skills (yleinen, saunotus, laura, morsiussauna) + staff_skill_overrides (staff_id = public.staff.id, EI FK public-skeemaan)
--    Oletus: skills.default_all=true -> kaikki aktiiviset saunottajat (public.staff_roles role_type='therapist' & active); false -> vain override allowed=true.
--    yleinen = kaikki hoidot/rituaalit/seremoniat (+ kb 30/31 synttäri/turve: "kaikki saunottajat"); saunotus = kb 11/12/13-15/23: vain 2 nimettyä (Joonas);
--    laura = tapahtumat kb 9/32/33/34 (+koulutukset): vain 1 nimetty; morsiussauna = kb 29: kaikki paitsi 2 nimettyä (override allowed=false).
--  * product_config.required_skill FK + seed (required_skill, therapists_needed=1, therapist_offset_min, therapist_minutes) mallin mukaan.
--  * funktiot: booking.therapist_skills(), booking.therapist_on_duty(p_from,p_to) (lukee public.work_shifts/shift_assignments/staff VAIN LUKU),
--    admin_list_therapists(), admin_set_staff_skill(staff_id, skill, allowed|null) (oikeus resources.edit; null = palauta oletus).
--    therapist_skills/therapist_on_duty: vain service_role + muut SECURITY DEFINER -funktiot (ei authenticated/anon).
--  * EI mukana: _therapist_slack, v_therapist_conflicts (tarvitsevat reservation_legs -> booking_17), addons-lisäsarakkeet/pyyhe (ei pyydetty).
--  * RLS + staff_read ((select booking.is_staff())), audit_trg, set_updated_at uusille tauluille.
-- Idempotentti: create ... if not exists, ON CONFLICT DO NOTHING, drop trigger if exists, create or replace.
set local search_path = booking, extensions, public;

create table if not exists booking.skills (
  code text primary key,
  label text not null,
  default_all boolean not null default false,     -- true: kaikki aktiiviset saunottajat oletuksena (override allowed=false poistaa)
  active boolean not null default true,
  sort_order integer not null default 100,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists booking.staff_skill_overrides (
  id bigint generated always as identity primary key,
  staff_id uuid not null,                          -- public.staff.id (ei FK: public-skeemaan ei kosketa)
  skill text not null references booking.skills(code),
  allowed boolean not null,                        -- false = poistettu oletuksesta, true = lisätty
  note text,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_skill_overrides_uq unique (staff_id, skill)
);
create index if not exists staff_skill_overrides_staff_idx on booking.staff_skill_overrides (staff_id);

insert into booking.skills (code, label, default_all, sort_order, notes) values
  ('yleinen',      'Yleinen (hoidot, rituaalit, seremoniat)',      true,  10, 'Kaikki aktiiviset saunottajat. Kb 30/31 (synttäri/turve): kaikki saunottajat.'),
  ('saunotus',     'Saunotus ja syväsaunotus',                      false, 20, 'Vain nimetyt (Joonas): kb 11, 12 sekä vanhat perinnesaunotus/-vihdonta kb 13, 14, 15, 23.'),
  ('laura',        'Erityistilaisuudet (Laura)',                    false, 30, 'Tapahtumat kb 9, 32, 33, 34 ja koulutukset: vain nimetty henkilö.'),
  ('morsiussauna', 'Morsiussauna',                                  true,  40, 'Kb 29: kaikki saunottajat paitsi kaksi nimettyä (override allowed=false).')
on conflict (code) do nothing;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'product_config_required_skill_fkey' and conrelid = 'booking.product_config'::regclass) then
    alter table booking.product_config add constraint product_config_required_skill_fkey foreign key (required_skill) references booking.skills(code);
  end if;
end $$;

-- nimetyt poikkeukset (staff_id:t luettu public.staff-taulusta 16.10.2026; vain luku). Jos jokin id puuttuu, migraatio keskeytyy.
insert into booking.staff_skill_overrides (staff_id, skill, allowed, note)
select v.staff_id, v.skill, v.allowed, 'seed 16.10.2026 (Joonaksen päätös)'
  from (values
  ('040e1780-554c-4842-bc7d-b53053de9e5f'::uuid, 'saunotus', true),
  ('5ab2ba62-97b2-4712-b500-a47a898036a5'::uuid, 'saunotus', true),
  ('040e1780-554c-4842-bc7d-b53053de9e5f'::uuid, 'laura', true),
  ('d88e26c4-1830-42e1-86f5-ae63e8653b86'::uuid, 'morsiussauna', false),
  ('5ab2ba62-97b2-4712-b500-a47a898036a5'::uuid, 'morsiussauna', false)
  ) v(staff_id, skill, allowed)
  join public.staff ps on ps.id = v.staff_id
on conflict (staff_id, skill) do nothing;
do $$
begin
  if (select count(*) from booking.staff_skill_overrides) < 5 then
    raise exception 'staff_skill_overrides seed incomplete: nimetty saunottaja puuttuu public.staff-taulusta';
  end if;
end $$;

-- tuotteiden saunottajatarve (model_v2.plan): kb, taito, lukumäärä, offset, minuutit (null = koko ikkuna)
update booking.product_config pc
   set required_skill = v.skill, therapists_needed = v.n, therapist_offset_min = v.off, therapist_minutes = v.mins
  from (values
  (7, 'yleinen', 1, 0, 20),
  (8, 'yleinen', 1, 0, 20),
  (9, 'laura', 1, 0, null),
  (10, 'yleinen', 1, 0, null),
  (11, 'saunotus', 1, 0, null),
  (12, 'saunotus', 1, 0, null),
  (13, 'saunotus', 1, 0, null),
  (14, 'saunotus', 1, 0, null),
  (15, 'saunotus', 1, 0, null),
  (16, 'yleinen', 1, 0, null),
  (17, 'yleinen', 1, 0, null),
  (18, 'yleinen', 1, 0, null),
  (19, 'yleinen', 1, 0, null),
  (20, 'yleinen', 1, 0, null),
  (21, 'yleinen', 1, 0, null),
  (22, 'yleinen', 1, 0, null),
  (23, 'saunotus', 1, 0, null),
  (24, 'yleinen', 1, 0, null),
  (27, 'yleinen', 1, 0, 60),
  (28, 'yleinen', 1, 0, null),
  (29, 'morsiussauna', 1, 0, null),
  (30, 'yleinen', 1, 0, 60),
  (31, 'yleinen', 1, 0, 60),
  (32, 'laura', 1, 0, null),
  (33, 'laura', 1, 0, null),
  (34, 'laura', 1, 0, null)
  ) v(id, skill, n, off, mins)
 where pc.product_id = v.id and pc.required_skill is null;

-- ---------- funktiot ----------
create or replace function booking.therapist_skills()
 returns table(staff_id uuid, skill text)
 language sql stable security definer set search_path to ''
as $fn$
  select distinct s.id, k.code
    from public.staff s
    join public.staff_roles r on r.staff_id = s.id and r.role_type = 'therapist' and r.active
   cross join booking.skills k
   where s.active and k.active
     and coalesce((select o.allowed from booking.staff_skill_overrides o where o.staff_id = s.id and o.skill = k.code), k.default_all)
$fn$;

create or replace function booking.therapist_on_duty(p_from timestamptz, p_to timestamptz)
 returns table(shift_id uuid, staff_id uuid, starts_at timestamptz, ends_at timestamptz, skills text[])
 language sql stable security definer set search_path to ''
as $fn$
  select ws.id, sa.staff_id, ws.starts_at, ws.ends_at,
         coalesce((select array_agg(ts.skill order by ts.skill) from booking.therapist_skills() ts where ts.staff_id = sa.staff_id), '{}'::text[])
    from public.work_shifts ws
    join public.shift_assignments sa on sa.shift_id = ws.id and sa.status in ('assigned','confirmed')
    join public.staff ps on ps.id = sa.staff_id and ps.active
   where ws.role_type = 'therapist' and ws.status = 'active' and ws.staffing_status = 'assigned'
     and ws.starts_at < p_to and ws.ends_at > p_from
$fn$;

create or replace function booking.admin_list_therapists()
 returns jsonb
 language plpgsql stable security definer set search_path to ''
as $fn$
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'skills', coalesce((select jsonb_agg(jsonb_build_object('code', k.code, 'label', k.label, 'default_all', k.default_all) order by k.sort_order, k.code)
                          from booking.skills k where k.active), '[]'::jsonb),
    'therapists', coalesce((
      select jsonb_agg(jsonb_build_object(
               'staff_id', s.id, 'name', s.name,
               'skills', coalesce((select jsonb_agg(ts.skill order by ts.skill) from booking.therapist_skills() ts where ts.staff_id = s.id), '[]'::jsonb),
               'overrides', coalesce((select jsonb_object_agg(o.skill, o.allowed) from booking.staff_skill_overrides o where o.staff_id = s.id), '{}'::jsonb)
             ) order by s.name)
        from public.staff s
       where s.active and exists (select 1 from public.staff_roles r where r.staff_id = s.id and r.role_type = 'therapist' and r.active)), '[]'::jsonb));
end $fn$;

create or replace function booking.admin_set_staff_skill(p_staff_id uuid, p_skill text, p_allowed boolean, p_note text default null)
 returns jsonb
 language plpgsql security definer set search_path to ''
as $fn$
begin
  perform booking._require_permission('resources.edit');
  if not exists (select 1 from booking.skills k where k.code = p_skill and k.active) then
    perform booking._err('not_found', 'Taitoa ei löydy');
  end if;
  if not exists (select 1 from public.staff s join public.staff_roles r on r.staff_id = s.id and r.role_type = 'therapist' and r.active
                  where s.id = p_staff_id and s.active) then
    perform booking._err('not_found', 'Saunottajaa ei löydy');
  end if;
  if p_allowed is null then
    delete from booking.staff_skill_overrides where staff_id = p_staff_id and skill = p_skill;   -- palauta oletus
  else
    insert into booking.staff_skill_overrides (staff_id, skill, allowed, note, updated_by)
    values (p_staff_id, p_skill, p_allowed, p_note, auth.uid())
    on conflict (staff_id, skill) do update set allowed = excluded.allowed, note = coalesce(excluded.note, booking.staff_skill_overrides.note),
                                                updated_by = excluded.updated_by, updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $fn$;

-- funktio-oikeudet (oletus-ACL antaisi anon/authenticated-suorituksen: poistetaan)
revoke all on function booking.therapist_skills() from public, anon, authenticated;
revoke all on function booking.therapist_on_duty(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function booking.admin_list_therapists() from public, anon;
revoke all on function booking.admin_set_staff_skill(uuid, text, boolean, text) from public, anon;
grant execute on function booking.therapist_skills() to service_role;
grant execute on function booking.therapist_on_duty(timestamptz, timestamptz) to service_role;
grant execute on function booking.admin_list_therapists() to authenticated, service_role;
grant execute on function booking.admin_set_staff_skill(uuid, text, boolean, text) to authenticated, service_role;

-- ---------- RLS, oikeudet, audit, updated_at ----------
do $$
declare t text;
begin
  foreach t in array array['skills', 'staff_skill_overrides'] loop
    execute format('alter table booking.%I enable row level security', t);
    execute format('revoke all on booking.%I from public, anon, authenticated', t);
    execute format('grant select on booking.%I to authenticated', t);
    execute format('grant all on booking.%I to service_role', t);
    execute format('drop policy if exists staff_read on booking.%I', t);
    execute format('create policy staff_read on booking.%I for select to authenticated using ((select booking.is_staff()))', t);
    execute format('drop trigger if exists %I on booking.%I', t || '_updated', t);
    execute format('create trigger %I before update on booking.%I for each row execute function booking.set_updated_at()', t || '_updated', t);
    execute format('drop trigger if exists audit_trg on booking.%I', t);
    perform booking._add_audit(('booking.' || t)::regclass);
  end loop;
end $$;
revoke all on sequence booking.staff_skill_overrides_id_seq from public, anon, authenticated;
grant all on sequence booking.staff_skill_overrides_id_seq to service_role;
