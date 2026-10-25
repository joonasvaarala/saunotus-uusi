-- WhatsApp-itsepalvelu saapuville viesteille. EI ajettu tuotantoon. EI deployta. EI lähetä viestejä.
-- Jokainen saapuva viesti tallennetaan public.whatsapp_messages-tauluun (direction inbound), myös tuntematon numero (staff_id null).
-- Tuntemattomalle numerolle ei lähde vastausta. Työvuoro-Tapio poimii rivit, joissa direction = inbound ja handled_at is null.
-- Itsepalveluvastaukset vaativat shift_offer_engine_settings.whatsapp_inbound_enabled = true (oletus false).
-- Tarjousmallien lähetys säilyy entisissä kytkimissä (whatsapp_enabled, whatsapp_dry_run, allowlist).

alter table public.shift_offer_engine_settings
  add column if not exists whatsapp_inbound_enabled boolean not null default false;

comment on column public.shift_offer_engine_settings.whatsapp_inbound_enabled is
  'Saapuvien WhatsApp-viestien itsepalveluvastaukset. false (oletus): viestit tallennetaan, mutta vastausta ei lähetetä. true: puhelinnumerosta tunnistettu henkilöstö saa vuorovastaukset. Tuntemattomalle numerolle ei vastata koskaan. Ei vaikuta tarjousmallien lähetykseen.';

-- Tuotannossa taulu on jo olemassa. Uusi kanta saa saman rungon ja sen jälkeen lisäsarakkeet.
create table if not exists public.whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid references public.staff(id) on delete set null,
  shift_id uuid references public.work_shifts(id) on delete set null,
  direction text not null check (direction in ('inbound', 'outbound')),
  provider_message_id text unique,
  template_name text,
  message_text text,
  status text,
  sent_at timestamptz,
  received_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.whatsapp_messages
  add column if not exists phone_e164 text,
  add column if not exists handled_at timestamptz,
  add column if not exists handled_by text,
  add column if not exists message_type text,
  add column if not exists button_id text,
  add column if not exists intent text;

comment on column public.whatsapp_messages.handled_at is
  'NULL ja direction = inbound: Työvuoro-Tapio voi poimia viestin. Itsepalvelu asettaa ajan, kun vastaus on lähetetty. Tuntematon numero jää NULL:ksi, koska sille ei vastata.';
comment on column public.whatsapp_messages.phone_e164 is
  'Lähettäjän tai vastaanottajan numero E.164-muodossa. Ei tulosteta lokeihin.';
comment on column public.whatsapp_messages.intent is
  'Itsepalvelun tunnistama komento (op). Ei sisällä viestin vapaata tekstiä.';

create index if not exists whatsapp_messages_unhandled_idx
  on public.whatsapp_messages (received_at)
  where direction = 'inbound' and handled_at is null;

create table if not exists public.whatsapp_staff_context (
  staff_id uuid primary key references public.staff(id) on delete cascade,
  shift_ids uuid[] not null default '{}',
  offer_ids uuid[] not null default '{}',
  expires_at timestamptz not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.whatsapp_pending_actions (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  kind text not null check (kind in ('assign', 'unassign', 'change_time', 'cancel')),
  shift_id uuid not null references public.work_shifts(id) on delete cascade,
  target_staff_id uuid references public.staff(id) on delete set null,
  new_starts timestamptz,
  new_ends timestamptz,
  summary text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  result jsonb
);

create index if not exists whatsapp_pending_open_idx
  on public.whatsapp_pending_actions (staff_id, created_at desc)
  where consumed_at is null;

comment on table public.whatsapp_pending_actions is
  'WhatsApp-muutos, jota ei ole vielä vahvistettu. shift_apply_change ajetaan vasta confirm-kutsussa.';

alter table public.whatsapp_messages enable row level security;
alter table public.whatsapp_staff_context enable row level security;
alter table public.whatsapp_pending_actions enable row level security;

revoke all on table public.whatsapp_messages, public.whatsapp_staff_context, public.whatsapp_pending_actions
  from public, anon, authenticated;
grant select, insert, update, delete on table public.whatsapp_messages, public.whatsapp_staff_context, public.whatsapp_pending_actions
  to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'backup_reader') then
    execute 'grant select on public.whatsapp_messages, public.whatsapp_staff_context, public.whatsapp_pending_actions to backup_reader';
  end if;
end $$;

-- ---------- apurit ----------

create or replace function public._whatsapp_reply(p_body text, p_buttons jsonb default '[]'::jsonb, p_shift uuid default null)
returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'reply_body', rtrim(p_body, E'\n') || E'\n–Tapio',
    'buttons', coalesce(p_buttons, '[]'::jsonb),
    'shift_id', p_shift,
    'suppressed', false)
$$;

create or replace function public._whatsapp_silent()
returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('reply_body', null, 'buttons', '[]'::jsonb, 'shift_id', null, 'suppressed', true)
$$;

create or replace function public._whatsapp_clean(p_text text)
returns text
language sql immutable set search_path = '' as $$
  select left(btrim(regexp_replace(coalesce(p_text, ''), '[[:space:]]+', ' ', 'g')), 80)
$$;

create or replace function public._whatsapp_role(p_role text)
returns text
language sql immutable set search_path = '' as $$
  select case p_role
    when 'heater' then 'lämmitysvuoro'
    when 'reception' then 'vastaanottovuoro'
    when 'therapist' then 'hoitajavuoro'
    else 'vuoro' end
$$;

create or replace function public._whatsapp_when(p_starts timestamptz, p_ends timestamptz)
returns text
language sql immutable set search_path = '' as $$
  select case extract(isodow from (p_starts at time zone 'Europe/Helsinki'))
           when 1 then 'ma' when 2 then 'ti' when 3 then 'ke' when 4 then 'to'
           when 5 then 'pe' when 6 then 'la' else 'su' end
    || ' ' || to_char(p_starts at time zone 'Europe/Helsinki', 'DD.MM.YYYY')
    || ' klo ' || to_char(p_starts at time zone 'Europe/Helsinki', 'HH24:MI')
    || '–' || to_char(p_ends at time zone 'Europe/Helsinki', 'HH24:MI')
$$;

-- Hallinnan oikeudet: shifts.view_all (admin, ylläpitäjä/manager) näkee muut.
-- Muokkaus vain booking.staff.role admin tai manager. Pelkkä puhelinnumero ilman hallintaroolia = omat vuorot.
-- Ilman booking.staff-riviä aktiivinen public.staff näkee omat vuoronsa ja voi hyväksyä oman tarjouksensa.
create or replace function public._whatsapp_actor_access(p_staff uuid)
returns table (view_own boolean, view_all boolean, can_edit boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_role text;
begin
  if p_staff is null or not exists (select 1 from public.staff s where s.id = p_staff and s.active) then
    return query select false, false, false;
    return;
  end if;
  select b.role into v_role
    from booking.staff b
   where b.public_staff_id = p_staff and b.active
   order by case b.role when 'admin' then 0 when 'manager' then 1 else 2 end
   limit 1;
  if v_role is null then
    return query select true, false, false;
    return;
  end if;
  return query select
    exists (select 1 from booking.role_permissions rp where rp.role_code = v_role and rp.permission in ('shifts.view', 'shifts.view_all')),
    exists (select 1 from booking.role_permissions rp where rp.role_code = v_role and rp.permission = 'shifts.view_all'),
    v_role in ('admin', 'manager');
end $$;

create or replace function public._whatsapp_save_context(p_staff uuid, p_shifts uuid[], p_offers uuid[], p_mode text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.whatsapp_staff_context as c (staff_id, shift_ids, offer_ids, expires_at)
  values (p_staff, coalesce(p_shifts, '{}'), coalesce(p_offers, '{}'), now() + interval '12 hours')
  on conflict (staff_id) do update set
    shift_ids = case when p_mode in ('shifts', 'both') then excluded.shift_ids else c.shift_ids end,
    offer_ids = case when p_mode in ('offers', 'both') then excluded.offer_ids else c.offer_ids end,
    expires_at = excluded.expires_at,
    updated_at = now();
end $$;

create or replace function public._whatsapp_open_offers(p_staff uuid)
returns table (offer_id uuid, role_type text, starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select o.id, o.role_type,
         coalesce(o.window_starts_at, w.starts_at),
         coalesce(o.window_ends_at, w.ends_at)
    from public.shift_offer_recipients rec
    join public.shift_offers o on o.id = rec.offer_id
    join public.work_shifts w on w.id = o.shift_id
   where rec.staff_id = p_staff
     and rec.status in ('pending', 'snoozed')
     and o.status in ('active', 'paused', 'escalated')
     and (rec.deadline_at is null or rec.deadline_at > now())
     and coalesce(o.window_ends_at, w.ends_at) > now()
   order by 3, o.id
   limit 10
$$;

create or replace function public._whatsapp_match_staff(p_name text)
returns table (id uuid, name text)
language sql stable security definer set search_path = '' as $$
  select s.id, s.name
    from public.staff s
   where s.active
     and char_length(btrim(coalesce(p_name, ''))) >= 2
     and (
       lower(btrim(s.name)) = lower(btrim(p_name))
       or lower(split_part(btrim(s.name), ' ', 1)) = lower(btrim(p_name))
       or lower(btrim(s.name)) like replace(replace(replace(lower(btrim(p_name)), '\', '\\'), '%', '\%'), '_', '\_') || '%' escape '\'
     )
   order by s.name
   limit 6
$$;

-- ---------- tallennus (toimii vaikka itsepalvelu on pois) ----------

create or replace function public.whatsapp_store_inbound(
  p_wamid text,
  p_from text,
  p_received_at timestamptz,
  p_message_type text,
  p_text text,
  p_button_id text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_phone text;
  v_stored text;
  v_ids uuid[];
  v_staff uuid;
  v_id uuid;
  v_dup boolean := false;
  v_handled boolean := false;
  v_enabled boolean;
  v_wamid text := nullif(left(btrim(coalesce(p_wamid, '')), 200), '');
  v_type text := left(coalesce(nullif(btrim(p_message_type), ''), 'unknown'), 32);
  v_text text := left(p_text, 4000);
  v_button text := left(nullif(btrim(p_button_id), ''), 256);
  v_at timestamptz := coalesce(p_received_at, now());
  v_existing_staff uuid;
  v_existing_phone text;
begin
  v_phone := public.shift_offer_phone_e164(p_from);
  if v_phone is not null then
    v_stored := v_phone;
    select array_agg(s.id order by s.id) into v_ids
      from public.staff s
     where s.active and public.shift_offer_phone_e164(s.phone_e164) = v_phone;
    if v_ids is not null and cardinality(v_ids) = 1 then
      v_staff := v_ids[1];
    end if;
  elsif btrim(coalesce(p_from, '')) ~ '^[0-9]{6,20}$' then
    v_stored := left('+' || btrim(p_from), 20);
  end if;

  if v_wamid is not null then
    insert into public.whatsapp_messages (
      staff_id, direction, provider_message_id, message_text, status, received_at, phone_e164, message_type, button_id)
    values (v_staff, 'inbound', v_wamid, v_text, 'received', v_at, v_stored, v_type, v_button)
    on conflict (provider_message_id) do nothing
    returning id into v_id;
    if v_id is null then
      v_dup := true;
      select m.id, m.handled_at is not null, m.staff_id, m.phone_e164
        into v_id, v_handled, v_existing_staff, v_existing_phone
        from public.whatsapp_messages m
       where m.provider_message_id = v_wamid;
      v_staff := coalesce(v_existing_staff, v_staff);
      v_stored := coalesce(v_existing_phone, v_stored);
    end if;
  else
    insert into public.whatsapp_messages (
      staff_id, direction, message_text, status, received_at, phone_e164, message_type, button_id)
    values (v_staff, 'inbound', v_text, 'received', v_at, v_stored, v_type, v_button)
    returning id into v_id;
  end if;

  select coalesce(e.whatsapp_inbound_enabled, false) into v_enabled
    from public.shift_offer_engine_settings e where e.id;

  return jsonb_build_object(
    'ok', true,
    'id', v_id,
    'duplicate', v_dup,
    'handled', v_handled,
    'inbound_enabled', coalesce(v_enabled, false),
    'staff_id', v_staff,
    'reply_to', v_stored);
end $$;

create or replace function public.whatsapp_mark_handled(p_message_id uuid, p_by text, p_intent text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.whatsapp_messages
     set handled_at = coalesce(handled_at, now()),
         handled_by = coalesce(handled_by, left(nullif(btrim(p_by), ''), 80)),
         status = 'handled',
         intent = coalesce(intent, left(nullif(btrim(p_intent), ''), 40))
   where id = p_message_id and direction = 'inbound';
end $$;

create or replace function public.whatsapp_store_outbound(
  p_staff_id uuid, p_phone text, p_text text, p_wamid text, p_shift_id uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_wamid text := nullif(left(btrim(coalesce(p_wamid, '')), 200), '');
begin
  insert into public.whatsapp_messages (
    staff_id, shift_id, direction, provider_message_id, message_text, status, sent_at,
    phone_e164, message_type, handled_at, handled_by)
  values (
    p_staff_id, p_shift_id, 'outbound', v_wamid, left(p_text, 4000), 'sent', now(),
    left(p_phone, 20), 'session', now(), 'shift-offer-engine')
  on conflict (provider_message_id) do nothing
  returning id into v_id;
  return v_id;
end $$;

-- ---------- itsepalvelu ----------

create or replace function public.whatsapp_inbound_act(p_message_id uuid, p_intent jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_staff uuid;
  v_own boolean;
  v_all boolean;
  v_edit boolean;
  v_op text;
  v_body text := '';
  v_n int := 0;
  v_ids uuid[] := '{}';
  v_offer_ids uuid[] := '{}';
  v_buttons jsonb := '[]'::jsonb;
  v_shift uuid;
  v_offer uuid;
  v_index int;
  v_name text;
  v_summary text;
  v_who text;
  v_target uuid;
  v_target_name text;
  v_matches int;
  v_action uuid;
  v_kind text;
  v_starts timestamptz;
  v_ends timestamptz;
  v_res jsonb;
  v_pending public.whatsapp_pending_actions%rowtype;
  v_offer_n int;
  v_line text;
  r record;
  q record;
begin
  if not coalesce((select e.whatsapp_inbound_enabled from public.shift_offer_engine_settings e where e.id), false) then
    return public._whatsapp_silent();
  end if;
  select m.staff_id into v_staff
    from public.whatsapp_messages m
   where m.id = p_message_id and m.direction = 'inbound';
  if v_staff is null then
    return public._whatsapp_silent();
  end if;

  select a.view_own, a.view_all, a.can_edit into v_own, v_all, v_edit
    from public._whatsapp_actor_access(v_staff) a;
  v_op := coalesce(p_intent->>'op', 'unknown');

  if v_op = 'help' then
    v_body := E'Hei, tässä Tapio.\nKirjoita vuorot, niin näytän tulevat vuorosi.\nAvoimeen tarjoukseen: hyväksy tai en ota.';
    if v_edit then
      v_body := v_body || E'\nKaikkien vuorot: kaikki vuorot\nYhden henkilön vuorot: vuorot Maija\nMuutos vahvistetaan erikseen: peru 2, anna 2 Maija, pois 2 Maija, aika 2 25.10.2026 16:00-20:00';
    end if;
    return public._whatsapp_reply(v_body);
  end if;

  if v_op = 'own_shifts' then
    if not coalesce(v_own, false) then
      return public._whatsapp_reply('Sinulla ei ole oikeutta katsoa vuoroja.');
    end if;
    for r in
      select w.id, w.role_type, w.starts_at, w.ends_at
        from public.shift_assignments sa
        join public.work_shifts w on w.id = sa.shift_id
       where sa.staff_id = v_staff
         and sa.status in ('assigned', 'confirmed')
         and w.status = 'active'
         and w.ends_at > now()
         and w.starts_at < now() + interval '62 days'
       order by w.starts_at, w.id
       limit 12
    loop
      v_n := v_n + 1;
      v_ids := v_ids || r.id;
      v_body := v_body || v_n::text || '. ' || public._whatsapp_when(r.starts_at, r.ends_at) || ' ' || public._whatsapp_role(r.role_type) || E'\n';
    end loop;
    if v_n = 0 then
      v_body := E'Tulevia vuoroja ei ole.\n';
    else
      v_body := E'Tulevat vuorosi:\n' || v_body;
    end if;
    v_offer_n := 0;
    for q in select * from public._whatsapp_open_offers(v_staff) loop
      v_offer_n := v_offer_n + 1;
      v_offer_ids := v_offer_ids || q.offer_id;
      if v_offer_n = 1 then
        v_body := v_body || E'\nAvoin tarjous:\n';
      end if;
      v_body := v_body || v_offer_n::text || '. ' || public._whatsapp_when(q.starts_at, q.ends_at) || ' ' || public._whatsapp_role(q.role_type) || E'\n';
    end loop;
    if v_offer_n = 1 then
      v_buttons := jsonb_build_array(
        jsonb_build_object('id', 'a:' || v_offer_ids[1]::text, 'title', 'Hyväksy'),
        jsonb_build_object('id', 'd:' || v_offer_ids[1]::text, 'title', 'En ota'));
    elsif v_offer_n > 1 then
      v_body := v_body || E'Kirjoita hyväksy ja numero.\n';
      v_buttons := '[]'::jsonb;
      for v_n in 1..least(v_offer_n, 3) loop
        v_buttons := v_buttons || jsonb_build_array(jsonb_build_object('id', 'a:' || v_offer_ids[v_n]::text, 'title', 'Hyväksy ' || v_n::text));
      end loop;
    end if;
    perform public._whatsapp_save_context(v_staff, v_ids, v_offer_ids, 'both');
    return public._whatsapp_reply(v_body, v_buttons);
  end if;

  if v_op in ('all_shifts', 'person_shifts') then
    if not coalesce(v_all, false) then
      if coalesce(v_own, false) then
        return public._whatsapp_reply('Näet vain omat vuorosi. Kirjoita vuorot.');
      end if;
      return public._whatsapp_reply('Sinulla ei ole oikeutta katsoa vuoroja.');
    end if;
    v_target := null;
    if v_op = 'person_shifts' then
      v_name := public._whatsapp_clean(p_intent->>'name');
      select count(*) into v_matches from public._whatsapp_match_staff(v_name);
      if v_matches = 0 then
        return public._whatsapp_reply('En löytänyt työntekijää tällä nimellä.');
      end if;
      if v_matches > 1 then
        select string_agg(public._whatsapp_clean(s.name), ', ' order by s.name) into v_who
          from public._whatsapp_match_staff(v_name) s;
        return public._whatsapp_reply('Useita työntekijöitä: ' || coalesce(v_who, '') || '. Tarkenna nimeä.');
      end if;
      select s.id, public._whatsapp_clean(s.name) into v_target, v_target_name
        from public._whatsapp_match_staff(v_name) s;
    end if;
    for r in
      select w.id, w.role_type, w.starts_at, w.ends_at,
             coalesce((
               select string_agg(public._whatsapp_clean(s.name), ', ' order by s.name)
                 from public.shift_assignments sa
                 join public.staff s on s.id = sa.staff_id
                where sa.shift_id = w.id and sa.status in ('assigned', 'confirmed')
             ), 'ei tekijää') as who
        from public.work_shifts w
       where w.status = 'active'
         and w.ends_at > now()
         and w.starts_at < now() + interval '62 days'
         and (v_target is null or exists (
               select 1 from public.shift_assignments sa
                where sa.shift_id = w.id and sa.staff_id = v_target and sa.status in ('assigned', 'confirmed')))
       order by w.starts_at, w.role_type, w.id
       limit 12
    loop
      v_n := v_n + 1;
      v_ids := v_ids || r.id;
      v_line := v_n::text || '. ' || public._whatsapp_when(r.starts_at, r.ends_at) || ' ' || public._whatsapp_role(r.role_type);
      if v_op = 'all_shifts' then
        v_line := v_line || ' – ' || r.who;
      end if;
      v_body := v_body || v_line || E'\n';
    end loop;
    if v_op = 'person_shifts' then
      v_body := case when v_n = 0
        then v_target_name || E' ei ole tulevia vuoroja.\n'
        else v_target_name || E' tulevat vuorot:\n' || v_body end;
    else
      v_body := case when v_n = 0 then E'Tulevia vuoroja ei ole.\n' else E'Tulevat vuorot:\n' || v_body end;
    end if;
    perform public._whatsapp_save_context(v_staff, v_ids, null, 'shifts');
    return public._whatsapp_reply(v_body);
  end if;

  if v_op in ('accept', 'decline') then
    begin
      v_offer := nullif(p_intent->>'offer_id', '')::uuid;
    exception when invalid_text_representation then
      return public._whatsapp_reply('Tätä tarjousta ei ole sinulle.');
    end;
    if v_offer is null and nullif(p_intent->>'index', '') is not null then
      begin
        v_index := (p_intent->>'index')::int;
      exception when invalid_text_representation then
        v_index := null;
      end;
      select c.offer_ids into v_offer_ids
        from public.whatsapp_staff_context c
       where c.staff_id = v_staff and c.expires_at > now();
      if v_index is null or v_offer_ids is null or v_index < 1 or v_index > coalesce(cardinality(v_offer_ids), 0) then
        return public._whatsapp_reply('En löytänyt tarjousta tällä numerolla. Kirjoita vuorot.');
      end if;
      v_offer := v_offer_ids[v_index];
    end if;
    if v_offer is null then
      select coalesce(array_agg(o.offer_id order by o.starts_at, o.offer_id), '{}') into v_offer_ids
        from public._whatsapp_open_offers(v_staff) o;
      v_offer_n := coalesce(cardinality(v_offer_ids), 0);
      if v_offer_n = 0 then
        return public._whatsapp_reply('Sinulla ei ole avointa vuorotarjousta.');
      end if;
      if v_offer_n > 1 then
        v_body := E'Sinulla on useita tarjouksia:\n';
        v_n := 0;
        for q in select * from public._whatsapp_open_offers(v_staff) loop
          v_n := v_n + 1;
          v_body := v_body || v_n::text || '. ' || public._whatsapp_when(q.starts_at, q.ends_at) || ' ' || public._whatsapp_role(q.role_type) || E'\n';
        end loop;
        v_body := v_body || 'Kirjoita hyväksy ja numero.';
        perform public._whatsapp_save_context(v_staff, null, v_offer_ids, 'offers');
        v_buttons := '[]'::jsonb;
        for v_n in 1..least(v_offer_n, 3) loop
          v_buttons := v_buttons || jsonb_build_array(jsonb_build_object(
            'id', case when v_op = 'decline' then 'd:' else 'a:' end || v_offer_ids[v_n]::text,
            'title', case when v_op = 'decline' then 'En ota ' else 'Hyväksy ' end || v_n::text));
        end loop;
        return public._whatsapp_reply(v_body, v_buttons);
      end if;
      v_offer := v_offer_ids[1];
    end if;
    if not exists (
      select 1 from public.shift_offer_recipients rec
       where rec.offer_id = v_offer and rec.staff_id = v_staff
    ) then
      return public._whatsapp_reply('Tätä tarjousta ei ole sinulle.');
    end if;
    v_res := public.shift_offer_respond(v_offer, v_staff, case when v_op = 'decline' then 'decline' else 'accept' end,
                                         null, true, 'whatsapp');
    if v_res->>'result' = 'accepted' then
      for r in
        select distinct x.val::uuid as staff_id
          from jsonb_array_elements_text(coalesce(v_res->'notify_filled_staff_ids', '[]'::jsonb)) as x(val)
      loop
        perform public.shift_offer_queue_message(
          v_offer, null, r.staff_id, 'filled',
          public.shift_offer_compose('filled', r.staff_id, v_offer,
            (select o.role_type from public.shift_offers o where o.id = v_offer),
            (select w.starts_at from public.work_shifts w join public.shift_offers o on o.shift_id = w.id where o.id = v_offer),
            (select w.ends_at from public.work_shifts w join public.shift_offers o on o.shift_id = w.id where o.id = v_offer),
            null, null),
          'offer:' || v_offer::text || ':staff:' || r.staff_id::text || ':filled');
        update public.shift_offer_recipients set filled_notified_at = now()
         where offer_id = v_offer and staff_id = r.staff_id and filled_notified_at is null;
      end loop;
      select public._whatsapp_when(coalesce(o.window_starts_at, w.starts_at), coalesce(o.window_ends_at, w.ends_at))
             || ' ' || public._whatsapp_role(o.role_type), o.shift_id
        into v_summary, v_shift
        from public.shift_offers o
        join public.work_shifts w on w.id = o.shift_id
       where o.id = v_offer;
      return public._whatsapp_reply('Vuoro on sinun: ' || coalesce(v_summary, 'vuoro') || '.', '[]'::jsonb, v_shift);
    end if;
    if v_res->>'result' = 'declined' then
      return public._whatsapp_reply('Tarjous on hylätty.');
    end if;
    if v_res->>'result' in ('already_filled', 'already_taken') then
      return public._whatsapp_reply('Vuoro ehdittiin jo täyttää.');
    end if;
    if v_res->>'result' = 'already_yours' then
      return public._whatsapp_reply('Vuoro on jo sinun.');
    end if;
    if v_res->>'result' = 'not_recipient' then
      return public._whatsapp_reply('Tätä tarjousta ei ole sinulle.');
    end if;
    return public._whatsapp_reply('Tähän tarjoukseen ei voi enää vastata.');
  end if;

  if v_op in ('prepare_cancel', 'prepare_assign', 'prepare_unassign', 'prepare_time') then
    if not coalesce(v_edit, false) then
      return public._whatsapp_reply('Vain ylläpitäjä voi muuttaa vuoroja.');
    end if;
    if not public._shift_db_first_enabled() then
      return public._whatsapp_reply('Vuorojen muokkaus ei ole juuri nyt käytössä.');
    end if;
    begin
      v_index := (p_intent->>'index')::int;
    exception when invalid_text_representation then
      v_index := null;
    end;
    select c.shift_ids into v_ids
      from public.whatsapp_staff_context c
     where c.staff_id = v_staff and c.expires_at > now();
    if v_index is null or v_ids is null or v_index < 1 or v_index > coalesce(cardinality(v_ids), 0) then
      return public._whatsapp_reply('Numero ei ole viimeisimmällä listalla. Kirjoita kaikki vuorot ja yritä uudelleen.');
    end if;
    v_shift := v_ids[v_index];
    select public._whatsapp_role(w.role_type) || ' ' || public._whatsapp_when(w.starts_at, w.ends_at)
           || ' (' || coalesce((
             select string_agg(public._whatsapp_clean(s.name), ', ' order by s.name)
               from public.shift_assignments sa
               join public.staff s on s.id = sa.staff_id
              where sa.shift_id = w.id and sa.status in ('assigned', 'confirmed')
           ), 'ei tekijää') || ')'
      into v_summary
      from public.work_shifts w
     where w.id = v_shift and w.status = 'active' and w.ends_at > now();
    if v_summary is null then
      return public._whatsapp_reply('Vuoroa ei voi muokata. Listaa vuorot uudelleen.');
    end if;
    v_target := null;
    v_starts := null;
    v_ends := null;
    if v_op = 'prepare_cancel' then
      v_kind := 'cancel';
      v_body := 'Vahvistatko peruutuksen: ' || v_summary || '?';
    elsif v_op in ('prepare_assign', 'prepare_unassign') then
      v_kind := case when v_op = 'prepare_assign' then 'assign' else 'unassign' end;
      v_name := public._whatsapp_clean(p_intent->>'name');
      select count(*) into v_matches from public._whatsapp_match_staff(v_name);
      if v_matches = 0 then
        return public._whatsapp_reply('En löytänyt työntekijää tällä nimellä.');
      end if;
      if v_matches > 1 then
        select string_agg(public._whatsapp_clean(s.name), ', ' order by s.name) into v_who
          from public._whatsapp_match_staff(v_name) s;
        return public._whatsapp_reply('Useita työntekijöitä: ' || coalesce(v_who, '') || '. Tarkenna nimeä.');
      end if;
      select s.id, public._whatsapp_clean(s.name) into v_target, v_target_name
        from public._whatsapp_match_staff(v_name) s;
      v_body := case when v_kind = 'assign'
        then 'Vahvistatko: laitan ' || v_target_name || ' vuoroon ' || v_summary || '?'
        else 'Vahvistatko: poistan henkilön ' || v_target_name || ' vuorosta ' || v_summary || '?' end;
    else
      v_kind := 'change_time';
      begin
        v_starts := (to_date(p_intent->>'date', 'FMDD.FMMM.YYYY') + (p_intent->>'start')::time) at time zone 'Europe/Helsinki';
        v_ends := (to_date(p_intent->>'date', 'FMDD.FMMM.YYYY') + (p_intent->>'end')::time) at time zone 'Europe/Helsinki';
      exception when others then
        return public._whatsapp_reply('Aika ei kelpaa. Käytä muotoa 25.10.2026 16:00-20:00.');
      end;
      if v_ends <= v_starts then
        return public._whatsapp_reply('Loppuajan pitää olla alun jälkeen.');
      end if;
      v_body := 'Vahvistatko siirron: ' || v_summary || ' → ' || public._whatsapp_when(v_starts, v_ends) || '?';
    end if;
    begin
      perform public._shift_validate_change(v_kind, v_shift, v_target, null, v_starts, v_ends);
    exception when others then
      return public._whatsapp_reply('Muutos ei kelpaa: ' || public._whatsapp_clean(sqlerrm));
    end;
    update public.whatsapp_pending_actions
       set consumed_at = now(), result = jsonb_build_object('replaced', true)
     where staff_id = v_staff and consumed_at is null;
    insert into public.whatsapp_pending_actions (staff_id, kind, shift_id, target_staff_id, new_starts, new_ends, summary, expires_at)
    values (v_staff, v_kind, v_shift, v_target, v_starts, v_ends, v_summary, now() + interval '15 minutes')
    returning id into v_action;
    v_buttons := jsonb_build_array(
      jsonb_build_object('id', 'y:' || v_action::text, 'title', 'Vahvista'),
      jsonb_build_object('id', 'n:' || v_action::text, 'title', 'Peruuta'));
    return public._whatsapp_reply(v_body, v_buttons, v_shift);
  end if;

  if v_op = 'confirm' then
    begin
      v_action := nullif(p_intent->>'action_id', '')::uuid;
    exception when invalid_text_representation then
      v_action := null;
    end;
    if v_action is not null and not coalesce(v_edit, false) then
      return public._whatsapp_reply('Vain ylläpitäjä voi muuttaa vuoroja.');
    end if;
    if v_action is null and coalesce(v_edit, false) then
      select p.id into v_action
        from public.whatsapp_pending_actions p
       where p.staff_id = v_staff and p.consumed_at is null and p.expires_at > now()
       order by p.created_at desc
       limit 1;
    end if;
    if v_action is null then
      select coalesce(array_agg(o.offer_id order by o.starts_at, o.offer_id), '{}') into v_offer_ids
        from public._whatsapp_open_offers(v_staff) o;
      if coalesce(cardinality(v_offer_ids), 0) = 1 then
        return public.whatsapp_inbound_act(p_message_id, jsonb_build_object('op', 'accept', 'offer_id', v_offer_ids[1]));
      end if;
      return public._whatsapp_reply('Ei ole vahvistettavaa muutosta. Avoimeen tarjoukseen kirjoita hyväksy.');
    end if;
    if not coalesce(v_edit, false) or not public._shift_db_first_enabled() then
      return public._whatsapp_reply('Vain ylläpitäjä voi muuttaa vuoroja.');
    end if;
    select * into v_pending
      from public.whatsapp_pending_actions p
     where p.id = v_action and p.staff_id = v_staff and p.consumed_at is null
     for update;
    if not found or v_pending.expires_at <= now() then
      return public._whatsapp_reply('Vahvistus ei ole enää voimassa. Pyydä muutos uudelleen.');
    end if;
    begin
      v_res := public.shift_apply_change(
        v_pending.kind, v_pending.shift_id, v_pending.target_staff_id, null,
        v_pending.new_starts, v_pending.new_ends, 'hallinta', 'whatsapp', v_staff, 'WhatsApp-vahvistus', null);
      update public.whatsapp_pending_actions
         set consumed_at = now(), result = v_res
       where id = v_pending.id;
    exception when others then
      update public.whatsapp_pending_actions
         set consumed_at = now(), result = jsonb_build_object('error', sqlstate)
       where id = v_pending.id;
      return public._whatsapp_reply('Muutos ei onnistunut: ' || public._whatsapp_clean(sqlerrm));
    end;
    v_body := case v_pending.kind
      when 'cancel' then 'Peruin vuoron: '
      when 'assign' then 'Kirjasin henkilön vuoroon: '
      when 'unassign' then 'Poistin henkilön vuorosta: '
      when 'change_time' then 'Siirsin vuoron: '
      else 'Muutos tehty: ' end || v_pending.summary || '.';
    return public._whatsapp_reply(v_body, '[]'::jsonb, v_pending.shift_id);
  end if;

  if v_op = 'abort' then
    if not coalesce(v_edit, false) then
      return public._whatsapp_reply('Ei ole peruttavaa vahvistusta.');
    end if;
    begin
      v_action := nullif(p_intent->>'action_id', '')::uuid;
    exception when invalid_text_representation then
      v_action := null;
    end;
    if v_action is null then
      select p.id into v_action
        from public.whatsapp_pending_actions p
       where p.staff_id = v_staff and p.consumed_at is null and p.expires_at > now()
       order by p.created_at desc
       limit 1;
    end if;
    update public.whatsapp_pending_actions
       set consumed_at = now(), result = jsonb_build_object('aborted', true)
     where id = v_action and staff_id = v_staff and consumed_at is null;
    if not found then
      return public._whatsapp_reply('Ei ole peruttavaa vahvistusta.');
    end if;
    return public._whatsapp_reply('Muutosta ei tehty.');
  end if;

  return public._whatsapp_reply('En ymmärtänyt. Kirjoita apua, niin kerron komennot.');
end $$;

revoke all on function
  public._whatsapp_reply(text, jsonb, uuid),
  public._whatsapp_silent(),
  public._whatsapp_clean(text),
  public._whatsapp_role(text),
  public._whatsapp_when(timestamptz, timestamptz),
  public._whatsapp_actor_access(uuid),
  public._whatsapp_save_context(uuid, uuid[], uuid[], text),
  public._whatsapp_open_offers(uuid),
  public._whatsapp_match_staff(text),
  public.whatsapp_store_inbound(text, text, timestamptz, text, text, text),
  public.whatsapp_mark_handled(uuid, text, text),
  public.whatsapp_store_outbound(uuid, text, text, text, uuid),
  public.whatsapp_inbound_act(uuid, jsonb)
  from public, anon, authenticated;

grant execute on function
  public.whatsapp_store_inbound(text, text, timestamptz, text, text, text),
  public.whatsapp_mark_handled(uuid, text, text),
  public.whatsapp_store_outbound(uuid, text, text, text, uuid),
  public.whatsapp_inbound_act(uuid, jsonb)
  to service_role;
