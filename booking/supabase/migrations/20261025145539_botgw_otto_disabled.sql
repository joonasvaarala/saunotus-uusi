-- HISTORY-SYNC: tämä migraatio on jo ajettu tuotannossa (Supabase sxbofnuisemspgquoxyv) 25.10.2026, versio 20261025145539 (botgw_otto_disabled).
-- Applied in production, DO NOT RERUN. Lisätty repoon jälkikäteen, jotta repopohjainen rakennus luo botgw-skeeman (edge-funktio bot-gateway).
-- Alla olevat lauseet ovat tavu tavulta tuotannon supabase_migrations.schema_migrations.statements[1] (md5 b67031f885e3e854ff707a2e75774c19). Älä aja uudelleen tuotantoon.
-- botgw_otto_disabled: Oton botin kapea yhdyskäytävä (DB-puoli), POIS PÄÄLTÄ.
-- Puhtaasti lisäävä: uusi skeema botgw, 2 taulua, 2 funktiota + public.botgw_call -kääre.
-- Ei grantteja anon/authenticated -rooleille. Ei avainta (key_hash null), active=false.
-- Kutsuja: tuleva edge-funktio bot-gateway (service_role), joka laskee sha256(x-bot-key)
-- ja välittää vain tiivisteen. Henkilö (staff_id) tulee aina avainriviltä, ei kutsujalta.

create schema if not exists botgw;
revoke all on schema botgw from public, anon, authenticated;
grant usage on schema botgw to service_role;

create table if not exists botgw.bot_clients (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,
  staff_id      uuid not null references public.staff(id) on delete restrict,
  key_hash      text unique check (key_hash is null or key_hash ~ '^[0-9a-f]{64}$'),
  scopes        text[] not null default '{}',
  active        boolean not null default false,
  note          text,
  created_at    timestamptz not null default now(),
  issued_at     timestamptz,
  last_used_at  timestamptz,
  constraint bot_clients_active_needs_key check (not active or key_hash is not null),
  constraint bot_clients_scopes_known check (scopes <@ array['me','shifts.read','offers.respond','inbox.read','backlog.read','backlog.write']::text[])
);
create table if not exists botgw.inbox_ack (
  client_id  uuid not null references botgw.bot_clients(id) on delete cascade,
  message_id bigint not null references public.shift_offer_messages(id) on delete cascade,
  acked_at   timestamptz not null default now(),
  primary key (client_id, message_id)
);
create table if not exists botgw.call_log (
  id bigint generated always as identity primary key,
  client_id uuid references botgw.bot_clients(id) on delete set null,
  action text not null, ok boolean not null, error text,
  at timestamptz not null default now()
);
alter table botgw.bot_clients enable row level security;
alter table botgw.inbox_ack  enable row level security;
alter table botgw.call_log   enable row level security;
revoke all on all tables in schema botgw from public, anon, authenticated;
grant select, insert, update, delete on all tables in schema botgw to service_role;

-- Oton rivi valmiiksi, POIS PÄÄLTÄ, ei avainta.
-- Tyhjä kanta: Oton staff-riviä ei ole. Tuotannossa rivi on, ja on conflict do nothing pitää ajon ennallaan.
insert into botgw.bot_clients (name, staff_id, scopes, active, note)
select 'otto-grok-bot', '2975633f-c53f-48d6-8a38-41cae0be5a83',
        array['me','shifts.read','offers.respond','inbox.read','backlog.read','backlog.write'], false,
        'Oton Grok Bot. Avain annetaan vain Joonaksen hyväksynnällä suojatulla lomakkeella.'
 where exists (select 1 from public.staff where id = '2975633f-c53f-48d6-8a38-41cae0be5a83')
on conflict (name) do nothing;

-- Sisäinen: tunnista asiakas tiivisteellä ja vaadi scope.
create or replace function botgw._client(p_key_hash text, p_scope text)
returns botgw.bot_clients
language plpgsql security definer set search_path to ''
as $f$
declare c botgw.bot_clients;
begin
  if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  select b.* into c from botgw.bot_clients b
    join public.staff s on s.id = b.staff_id and s.active
   where b.key_hash = p_key_hash and b.active;
  if c.id is null then raise exception 'unauthorized' using errcode = '42501'; end if;
  if not (p_scope = any (c.scopes)) then raise exception 'forbidden:%', p_scope using errcode = '42501'; end if;
  update botgw.bot_clients set last_used_at = now() where id = c.id;
  return c;
end $f$;

-- Muokattava = omistajaton tai Otto (staff) on omistaja.
create or replace function botgw._backlog_editable(p_item bigint, p_staff uuid)
returns boolean language sql stable security definer set search_path to ''
as $f$
  select not exists (select 1 from kb.backlog_owners o where o.item_id = p_item)
      or exists (select 1 from kb.backlog_owners o where o.item_id = p_item and o.staff_id = p_staff)
$f$;

create or replace function botgw.call(p_key_hash text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path to ''
as $f$
declare
  c botgw.bot_clients;
  a jsonb := coalesce(p_args, '{}'::jsonb);
  v jsonb; v_id bigint; v_from date; v_to date; v_cat text; v_pos int; v_offer uuid;
  v_scope text := case p_action
    when 'me' then 'me'
    when 'my_shifts' then 'shifts.read'
    when 'offers_open' then 'offers.respond'
    when 'offer_respond' then 'offers.respond'
    when 'inbox' then 'inbox.read'
    when 'inbox_ack' then 'inbox.read'
    when 'backlog_list' then 'backlog.read'
    when 'backlog_update' then 'backlog.write'
    when 'backlog_add' then 'backlog.write'
    else null end;
begin
  if v_scope is null then raise exception 'unknown_action' using errcode = '22023'; end if;
  c := botgw._client(p_key_hash, v_scope);

  if p_action = 'me' then
    select jsonb_build_object('name', s.name, 'scopes', c.scopes,
             'roles', coalesce((select jsonb_agg(r.role_type order by r.role_type) from public.staff_roles r
                                 where r.staff_id = s.id and r.active), '[]'::jsonb))
      into v from public.staff s where s.id = c.staff_id;

  elsif p_action = 'my_shifts' then
    v_from := coalesce((a->>'from')::date, (now() at time zone 'Europe/Helsinki')::date);
    v_to   := coalesce((a->>'to')::date, v_from + 90);
    if v_to < v_from or v_to - v_from > 400 then raise exception 'bad_range' using errcode = '22023'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('shift_id', w.id, 'role', w.role_type,
             'starts', to_char(w.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
             'ends',   to_char(w.ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI')) order by w.starts_at), '[]'::jsonb)
      into v
      from public.shift_assignments sa join public.work_shifts w on w.id = sa.shift_id
     where sa.staff_id = c.staff_id and sa.status = 'assigned' and w.status = 'active'
       and w.starts_at >= (v_from::timestamp at time zone 'Europe/Helsinki')
       and w.starts_at <  ((v_to + 1)::timestamp at time zone 'Europe/Helsinki');

  elsif p_action = 'offers_open' then
    select coalesce(jsonb_agg(jsonb_build_object('offer_id', x.offer_id, 'role', x.role_type,
             'starts', to_char(x.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
             'ends',   to_char(x.ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'))), '[]'::jsonb)
      into v from public._whatsapp_open_offers(c.staff_id) x;

  elsif p_action = 'offer_respond' then
    v_offer := (a->>'offer_id')::uuid;
    if v_offer is null or not exists (select 1 from public.shift_offer_recipients r
                                       where r.offer_id = v_offer and r.staff_id = c.staff_id) then
      v := jsonb_build_object('result', 'not_recipient');
    else
      v := public.shift_offer_respond(v_offer, c.staff_id, a->>'response', (a->>'snooze_until')::timestamptz, true, 'bot:' || c.name);
    end if;

  elsif p_action = 'inbox' then
    select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'offer_id', m.offer_id,
             'body', m.body, 'created_at', m.created_at) order by m.id), '[]'::jsonb)
      into v
      from (select m.* from public.shift_offer_messages m
             where m.staff_id = c.staff_id and m.channel = 'bot' and m.status = 'bot_channel'
               and m.created_at > now() - interval '30 days'
               and not exists (select 1 from botgw.inbox_ack k where k.client_id = c.id and k.message_id = m.id)
             order by m.id limit 50) m;

  elsif p_action = 'inbox_ack' then
    insert into botgw.inbox_ack (client_id, message_id)
    select c.id, m.id from public.shift_offer_messages m
     where m.staff_id = c.staff_id and m.channel = 'bot'
       and m.id in (select (jsonb_array_elements_text(coalesce(a->'ids', '[]'::jsonb)))::bigint)
    on conflict do nothing;
    get diagnostics v_id = row_count;
    v := jsonb_build_object('acked', v_id);

  elsif p_action = 'backlog_list' then
    select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'category', o.category_name, 'position', o.position,
             'kind', o.kind, 'status', o.status, 'title', o.title, 'description', o.description, 'due_date', o.due_date,
             'owners', o.owners, 'tasks_done', o.tasks_done, 'tasks_total', o.tasks_total,
             'editable', botgw._backlog_editable(o.id, c.staff_id))
             order by o.category_sort nulls last, o.position, o.id), '[]'::jsonb)
      into v
      from kb.backlog_overview o
     where o.status <> 'done'
       and (coalesce((a->>'all')::boolean, false) or botgw._backlog_editable(o.id, c.staff_id));

  elsif p_action = 'backlog_update' then
    v_id := (a->>'item_id')::bigint;
    if v_id is null or not exists (select 1 from kb.feature_backlog f where f.id = v_id) then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
    if not botgw._backlog_editable(v_id, c.staff_id) then
      raise exception 'not_editable' using errcode = '42501';
    end if;
    if a ? 'status' then
      update kb.feature_backlog set status = a->>'status' where id = v_id;
    end if;
    if nullif(btrim(a->>'note'), '') is not null then
      insert into kb.backlog_notes (item_id, kind, body, created_by)
      values (v_id, 'note', left(btrim(a->>'note'), 2000), 'bot:' || c.name);
    end if;
    if a ? 'task_id' and a ? 'task_done' then
      update kb.backlog_tasks set done = (a->>'task_done')::boolean
       where id = (a->>'task_id')::bigint and item_id = v_id;
    end if;
    v := jsonb_build_object('ok', true, 'item_id', v_id);

  elsif p_action = 'backlog_add' then
    if nullif(btrim(a->>'title'), '') is null then raise exception 'title_required' using errcode = '22023'; end if;
    v_cat := a->>'category';
    if v_cat is null or not exists (select 1 from kb.backlog_categories k where k.key = v_cat) then
      raise exception 'bad_category' using errcode = '22023';
    end if;
    select coalesce(max(f.position), 0) + 1 into v_pos from kb.feature_backlog f where f.category = v_cat;
    insert into kb.feature_backlog (position, title, description, category, kind, status, needs_approval, owner_bot, decided_by)
    values (v_pos, left(btrim(a->>'title'), 300), left(a->>'description', 4000), v_cat,
            coalesce(a->>'kind', 'fix'), 'queued', true, 'Otto', 'Otto')
    returning id into v_id;
    insert into kb.backlog_owners (item_id, owner_key, owner_type, staff_id)
    values (v_id, c.staff_id::text, 'staff', c.staff_id);
    v := jsonb_build_object('ok', true, 'item_id', v_id, 'position', v_pos);
  end if;

  insert into botgw.call_log (client_id, action, ok) values (c.id, p_action, true);
  return jsonb_build_object('ok', true, 'data', v);
end $f$;

-- PostgREST-kääre public-skeemassa: VAIN service_role (edge-funktio).
create or replace function public.botgw_call(p_key_hash text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path to ''
as $f$ select botgw.call(p_key_hash, p_action, p_args) $f$;

revoke all on function botgw._client(text, text) from public, anon, authenticated;
revoke all on function botgw._backlog_editable(bigint, uuid) from public, anon, authenticated;
revoke all on function botgw.call(text, text, jsonb) from public, anon, authenticated;
revoke all on function public.botgw_call(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.botgw_call(text, text, jsonb) to service_role;
grant execute on function botgw.call(text, text, jsonb) to service_role;

comment on schema botgw is 'Bottien kapea yhdyskäytävä (Oton Grok Bot). Pois päältä kunnes Joonas hyväksyy avaimen.';
