-- HISTORY-SYNC: tämä migraatio on jo ajettu tuotannossa (Supabase sxbofnuisemspgquoxyv) 25.10.2026, versio 20261025160316 (botgw_otto_backlog_claim).
-- Applied in production, DO NOT RERUN. Lisätty repoon jälkikäteen (edge-funktio bot-gateway v2). Peruutus: booking/supabase/rollbacks/20261025160316_botgw_otto_backlog_claim_ROLLBACK.sql.
-- Alla olevat lauseet ovat tavu tavulta tuotannon supabase_migrations.schema_migrations.statements[1] (md5 bc83a6c4565ce2ea503b29e5a458c590). Älä aja uudelleen tuotantoon.
-- Migraatio botgw_otto_backlog_claim (25.10.2026)
-- Joonaksen päätös 25.10.2026 klo 17.58: Otto saa merkitä Joonaksen (tai omistajattomia) to-do-kohtia itselleen,
-- jolloin ne poistuvat Joonaksen listalta. Otto ei voi poistaa mitään eikä muokata muiden kohtia.
-- Puhtaasti lisäävä:
--  * uusi taulu botgw.backlog_claims (kuka otti, milloin, keneltä)
--  * uusi apufunktio botgw._backlog_claimable
--  * botgw.call korvataan: vanhat toiminnot täsmälleen ennallaan; lisätään backlog_claim ja backlog_task_add,
--    backlog_listin riveille lisäkenttä 'claimable'.
-- Ei kytke mitään päälle: Oton rivi pysyy active=false ilman avainta.

create table if not exists botgw.backlog_claims (
  id bigint generated always as identity primary key,
  claimed_at timestamptz not null default now(),
  item_id bigint not null,
  client_id uuid not null references botgw.bot_clients(id),
  staff_id uuid not null,
  previous_owners jsonb not null default '[]'::jsonb,
  previous_owner_bot text,
  note text check (note is null or length(note) <= 1000),
  request_id uuid
);
create index if not exists backlog_claims_item_idx on botgw.backlog_claims (item_id, claimed_at desc);
alter table botgw.backlog_claims enable row level security;
revoke all on table botgw.backlog_claims from public, anon, authenticated;
grant select on table botgw.backlog_claims to service_role;
comment on table botgw.backlog_claims is 'Oton botin backlog-kohtien ottamiset omalle listalle (Joonaksen päätös 25.10.2026 klo 17.58). Vain lisäyksiä.';

create or replace function botgw._backlog_claimable(p_item bigint, p_staff uuid)
returns boolean language sql stable security definer set search_path to '' as $f$
  select exists (select 1 from kb.feature_backlog f where f.id = p_item and f.status <> 'done')
     and not exists (select 1 from kb.backlog_owners o where o.item_id = p_item and o.owner_type <> 'joonas')
     and not exists (select 1 from kb.backlog_owners o where o.item_id = p_item and o.staff_id = p_staff)
$f$;
revoke all on function botgw._backlog_claimable(bigint, uuid) from public, anon, authenticated;

create or replace function botgw.call(p_key_hash text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path to ''
as $f$
declare
  c botgw.bot_clients;
  a jsonb := coalesce(p_args, '{}'::jsonb);
  v jsonb; v_id bigint; v_from date; v_to date; v_cat text; v_pos int; v_offer uuid;
  v_req uuid; v_tt text; v_tid text; v_det jsonb;
  v_shift uuid; v_staff uuid; v_staff2 uuid; v_role text; v_s timestamptz; v_e timestamptz;
  v_old jsonb; v_new jsonb; v_uid uuid; v_txt text; v_n int; v_actor text; v_task bigint;
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
    when 'backlog_claim' then 'backlog.write'
    when 'backlog_task_add' then 'backlog.write'
    when 'shifts_list' then 'shifts.read_all'
    when 'shift_history' then 'shifts.read_all'
    when 'shift_change' then 'shifts.manage'
    when 'shift_reassign' then 'shifts.manage'
    when 'staff_list' then 'staff.read'
    when 'unavailability_list' then 'staff.read'
    when 'staff_create' then 'staff.manage'
    when 'staff_update' then 'staff.manage'
    when 'staff_role_set' then 'staff.manage'
    when 'unavailability_add' then 'unavailability.manage'
    when 'unavailability_update' then 'unavailability.manage'
    when 'unavailability_delete' then 'unavailability.manage'
    when 'proposal_add' then 'proposals.write'
    when 'proposal_list' then 'proposals.write'
    else null end;
  v_write boolean;
begin
  if v_scope is null then raise exception 'unknown_action' using errcode = '22023'; end if;
  c := botgw._client(p_key_hash, v_scope);
  v_actor := 'bot:' || c.name;
  v_write := p_action in ('offer_respond','backlog_update','backlog_add','backlog_claim','backlog_task_add','shift_change','shift_reassign','staff_create',
                          'staff_update','staff_role_set','unavailability_add','unavailability_update','unavailability_delete','proposal_add');

  -- Rajoitukset (lasketaan call_logista: onnistuneet + edge-funktion kirjaamat epäonnistuneet)
  select count(*) into v_n from botgw.call_log l where l.client_id = c.id and l.at > now() - interval '1 minute';
  if v_n >= 120 then raise exception 'rate_limited' using errcode = 'BG429'; end if;
  if v_write then
    select count(*) into v_n from botgw.call_log l where l.client_id = c.id and l.at > now() - interval '1 minute'
       and l.action in ('offer_respond','backlog_update','backlog_add','backlog_claim','backlog_task_add','shift_change','shift_reassign','staff_create',
                        'staff_update','staff_role_set','unavailability_add','unavailability_update','unavailability_delete','proposal_add');
    if v_n >= 20 then raise exception 'rate_limited' using errcode = 'BG429'; end if;
    select count(*) into v_n from botgw.call_log l where l.client_id = c.id and l.at > now() - interval '1 day'
       and l.action in ('shift_change','shift_reassign','staff_create','staff_update','staff_role_set',
                        'unavailability_add','unavailability_update','unavailability_delete');
    if v_n >= 300 then raise exception 'rate_limited' using errcode = 'BG429'; end if;
    if p_action = 'proposal_add' then
      select count(*) into v_n from botgw.logic_proposals p where p.client_id = c.id and p.created_at > now() - interval '1 day';
      if v_n >= 10 then raise exception 'rate_limited' using errcode = 'BG429'; end if;
    end if;
    -- Idempotenssi: sama request_id onnistuneena jo kerran -> ei tehdä uudestaan
    v_req := botgw._uuid(a->>'request_id');
    if v_req is not null and exists (select 1 from botgw.call_log l where l.client_id = c.id and l.request_id = v_req and l.ok) then
      return jsonb_build_object('ok', true, 'duplicate', true, 'request_id', v_req);
    end if;
  end if;
  v_req := coalesce(v_req, case when v_write then gen_random_uuid() end);

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
    v_tt := 'offer'; v_tid := v_offer::text;

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
             'editable', botgw._backlog_editable(o.id, c.staff_id),
             'claimable', botgw._backlog_claimable(o.id, c.staff_id))
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
    v_tt := 'backlog'; v_tid := v_id::text;

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
    v_tt := 'backlog'; v_tid := v_id::text;

  -- ===== Backlog: kohdan ottaminen omalle listalle (Joonaksen päätös 25.10.2026 klo 17.58) =====
  -- Sallittu vain aktiiviselle kohdalle, jonka omistaja on Joonas tai jolla ei ole omistajaa.
  -- Joonaksen omistajarivi korvataan Oton rivillä -> kohta poistuu Joonaksen listalta (kb.backlog_for_owner('joonas')).
  -- Mitään ei poisteta; muiden (Koodari, Bottiavustus, muut henkilöt) kohtiin ei kosketa.
  elsif p_action = 'backlog_claim' then
    v_id := (a->>'item_id')::bigint;
    if v_id is null then raise exception 'not_found' using errcode = 'P0002'; end if;
    perform 1 from kb.feature_backlog f where f.id = v_id for update;
    if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
    if exists (select 1 from kb.backlog_owners o where o.item_id = v_id and o.staff_id = c.staff_id)
       and not exists (select 1 from kb.backlog_owners o where o.item_id = v_id and o.staff_id is distinct from c.staff_id) then
      v := jsonb_build_object('ok', true, 'item_id', v_id, 'result', 'already_own');
    else
      if not botgw._backlog_claimable(v_id, c.staff_id) then
        raise exception 'not_claimable' using errcode = '42501';
      end if;
      select coalesce(jsonb_agg(jsonb_build_object('owner_key', o.owner_key, 'owner_type', o.owner_type, 'staff_id', o.staff_id)
                                order by o.owner_key), '[]'::jsonb)
        into v_old from kb.backlog_owners o where o.item_id = v_id;
      select f.owner_bot into v_txt from kb.feature_backlog f where f.id = v_id;
      delete from kb.backlog_owners o where o.item_id = v_id and o.owner_type = 'joonas';
      insert into kb.backlog_owners (item_id, owner_key, owner_type, staff_id)
      values (v_id, c.staff_id::text, 'staff', c.staff_id)
      on conflict (item_id, owner_key) do nothing;
      update kb.feature_backlog set owner_bot = 'Otto' where id = v_id;
      v_new := jsonb_build_array(jsonb_build_object('owner_key', c.staff_id::text, 'owner_type', 'staff', 'staff_id', c.staff_id));
      insert into botgw.backlog_claims (item_id, client_id, staff_id, previous_owners, previous_owner_bot, note, request_id)
      values (v_id, c.id, c.staff_id, v_old, v_txt, left(nullif(btrim(a->>'note'), ''), 1000), v_req);
      insert into kb.change_log (table_name, row_id, action, actor, old_data, new_data)
      values ('backlog_owners', v_id, 'claim', v_actor,
              jsonb_build_object('owners', v_old, 'owner_bot', v_txt),
              jsonb_build_object('owners', v_new, 'owner_bot', 'Otto', 'request_id', v_req));
      insert into kb.backlog_notes (item_id, kind, body, created_by)
      values (v_id, 'note',
              'Otto otti kohdan omalle listalleen ' || to_char(now() at time zone 'Europe/Helsinki', 'DD.MM.YYYY "klo" HH24.MI')
              || ' (Oton botti).' || coalesce(' Huom: ' || left(nullif(btrim(a->>'note'), ''), 1000), ''),
              v_actor);
      perform botgw._audit(c, 'backlog_claim', 'backlog_item', v_id::text,
                           jsonb_build_object('owners', v_old, 'owner_bot', v_txt),
                           jsonb_build_object('owners', v_new, 'owner_bot', 'Otto'));
      v := jsonb_build_object('ok', true, 'item_id', v_id, 'result', 'claimed', 'previous_owners', v_old);
    end if;
    v_tt := 'backlog'; v_tid := v_id::text; v_det := jsonb_build_object('claim', coalesce(v->>'result', '?'));

  -- ===== Backlog: tehtävän lisääminen omaan kohtaan (vain Oton omat kohdat) =====
  elsif p_action = 'backlog_task_add' then
    v_id := (a->>'item_id')::bigint;
    if v_id is null or not exists (select 1 from kb.feature_backlog f where f.id = v_id) then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
    if not exists (select 1 from kb.backlog_owners o where o.item_id = v_id and o.staff_id = c.staff_id) then
      raise exception 'not_editable' using errcode = '42501';
    end if;
    if nullif(btrim(a->>'title'), '') is null then raise exception 'title_required' using errcode = '22023'; end if;
    select coalesce(max(t.position), 0) + 1 into v_pos from kb.backlog_tasks t where t.item_id = v_id;
    insert into kb.backlog_tasks (item_id, title, position, due_date)
    values (v_id, left(btrim(a->>'title'), 300), v_pos, (a->>'due_date')::date)
    returning id into v_task;
    v := jsonb_build_object('ok', true, 'item_id', v_id, 'task_id', v_task, 'position', v_pos);
    v_tt := 'backlog'; v_tid := v_id::text; v_det := jsonb_build_object('task_id', v_task);

  -- ===== Vuorot: kaikkien henkilöiden vuorot =====
  elsif p_action = 'shifts_list' then
    v_from := coalesce((a->>'from')::date, (now() at time zone 'Europe/Helsinki')::date);
    v_to   := coalesce((a->>'to')::date, v_from + 31);
    if v_to < v_from or v_to - v_from > 400 then raise exception 'bad_range' using errcode = '22023'; end if;
    v_role := nullif(a->>'role', '');
    if v_role is not null and v_role not in ('heater','reception','therapist') then raise exception 'bad_role' using errcode = '22023'; end if;
    v_staff := botgw._uuid(a->>'staff_id');
    select coalesce(jsonb_agg(jsonb_build_object('shift_id', w.id, 'role', w.role_type,
             'starts', to_char(w.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
             'ends',   to_char(w.ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
             'status', w.status, 'staffing_status', w.staffing_status,
             'staff', coalesce(x.staff, '[]'::jsonb), 'calendar_sync', case when w.db_version > w.pushed_version then 'pending' else 'synced' end)
             order by w.starts_at, w.role_type), '[]'::jsonb)
      into v
      from public.work_shifts w
      left join lateral (select jsonb_agg(jsonb_build_object('staff_id', s.id, 'name', s.name) order by s.name) staff
                           from public.shift_assignments sa join public.staff s on s.id = sa.staff_id
                          where sa.shift_id = w.id and sa.status in ('assigned','confirmed')) x on true
     where w.starts_at >= (v_from::timestamp at time zone 'Europe/Helsinki')
       and w.starts_at <  ((v_to + 1)::timestamp at time zone 'Europe/Helsinki')
       and (coalesce((a->>'include_cancelled')::boolean, false) or w.status = 'active')
       and (v_role is null or w.role_type = v_role)
       and (v_staff is null or exists (select 1 from public.shift_assignments sa where sa.shift_id = w.id
                                        and sa.staff_id = v_staff and sa.status in ('assigned','confirmed')));

  elsif p_action = 'shift_history' then
    v_shift := botgw._uuid(a->>'shift_id');
    if v_shift is null then raise exception 'shift_id_required' using errcode = '22023'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('at', to_char(l.changed_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
             'source', l.source, 'actor', l.actor, 'action', l.action, 'staff_id', l.staff_id,
             'old', l.old_data, 'new', l.new_data) order by l.changed_at desc), '[]'::jsonb)
      into v from (select * from public.shift_change_log l where l.shift_id = v_shift order by l.changed_at desc limit 100) l;

  elsif p_action = 'shift_change' then
    -- action: create | assign | unassign | change_time | cancel ("poista vuoro" = cancel)
    v_shift := botgw._uuid(a->>'shift_id');
    v_staff := botgw._uuid(a->>'staff_id');
    v_s := botgw._ts(a->>'starts'); v_e := botgw._ts(a->>'ends');
    v := public.shift_apply_change(a->>'action', v_shift, v_staff, nullif(a->>'role', ''), v_s, v_e,
                                   'staff_bot', v_actor, c.staff_id, left(a->>'note', 500), v_req);
    v_tt := 'shift'; v_tid := v->>'shift_id';
    v_det := jsonb_build_object('action', a->>'action', 'staff_id', v_staff, 'starts', v_s, 'ends', v_e);

  elsif p_action = 'shift_reassign' then
    -- Vaihda tekijä: ensin uusi sisään, sitten vanha pois -> vuoro ei hetkeksikään avoin (ei turhaa tarjousta).
    v_shift  := botgw._uuid(a->>'shift_id');
    v_staff  := botgw._uuid(a->>'from_staff_id');
    v_staff2 := botgw._uuid(a->>'to_staff_id');
    if v_shift is null or v_staff is null or v_staff2 is null then
      raise exception 'shift_id, from_staff_id ja to_staff_id vaaditaan' using errcode = '22023';
    end if;
    if v_staff = v_staff2 then raise exception 'Sama henkilö' using errcode = '22023'; end if;
    -- tarkista ennen muutoksia, että vanha on vuorossa
    perform public._shift_validate_change('unassign', v_shift, v_staff, null, null, null);
    perform public.shift_apply_change('assign', v_shift, v_staff2, null, null, null, 'staff_bot', v_actor, c.staff_id, left(a->>'note', 500), v_req);
    v := public.shift_apply_change('unassign', v_shift, v_staff, null, null, null, 'staff_bot', v_actor, c.staff_id, left(a->>'note', 500), v_req);
    v_tt := 'shift'; v_tid := v_shift::text;
    v_det := jsonb_build_object('from_staff_id', v_staff, 'to_staff_id', v_staff2);

  -- ===== Henkilöstö =====
  elsif p_action = 'staff_list' then
    select coalesce(jsonb_agg(jsonb_build_object('staff_id', s.id, 'name', s.name, 'calendar_name', s.calendar_name,
             'phone', s.phone_e164, 'email', s.email, 'active', s.active, 'notes', s.notes,
             'whatsapp_enabled', s.whatsapp_enabled, 'bot_channel', s.bot_channel,
             'roles', coalesce((select jsonb_agg(jsonb_build_object('role', r.role_type, 'active', r.active) order by r.role_type)
                                  from public.staff_roles r where r.staff_id = s.id), '[]'::jsonb))
             order by s.active desc, s.name), '[]'::jsonb)
      into v from public.staff s
     where coalesce((a->>'include_inactive')::boolean, false) or s.active;

  elsif p_action in ('staff_create','staff_update') then
    if p_action = 'staff_update' then
      v_staff := botgw._uuid(a->>'staff_id');
      select to_jsonb(s) - 'created_at' - 'updated_at' into v_old from public.staff s where s.id = v_staff;
      if v_old is null then raise exception 'not_found' using errcode = 'P0002'; end if;
    end if;
    -- Muokattavat sarakkeet: name, calendar_name, phone, email, active, notes.
    -- EI: id, whatsapp_enabled, bot_channel (viestikanava/suostumus = Joonaksen päätös), aikaleimat.
    if a ?| array['whatsapp_enabled','bot_channel','id','staff_page_token'] then
      raise exception 'field_not_editable' using errcode = '42501';
    end if;
    if a ? 'name' and nullif(btrim(a->>'name'), '') is null then raise exception 'name_required' using errcode = '22023'; end if;
    if a ? 'name' and length(btrim(a->>'name')) > 100 then raise exception 'name_too_long' using errcode = '22023'; end if;
    if a ? 'calendar_name' then
      v_txt := btrim(a->>'calendar_name');
      if v_txt is null or v_txt = '' or length(v_txt) > 50 or v_txt ~ '[&?\-]' then
        raise exception 'bad_calendar_name' using errcode = '22023';
      end if;
      if exists (select 1 from public.staff s where lower(s.calendar_name) = lower(v_txt) and s.id is distinct from v_staff) then
        raise exception 'calendar_name_taken' using errcode = '22023';
      end if;
      if p_action = 'staff_update' and v_txt <> (v_old->>'calendar_name') and exists (
           select 1 from public.shift_assignments sa join public.work_shifts w on w.id = sa.shift_id
            where sa.staff_id = v_staff and sa.status in ('assigned','confirmed') and w.status = 'active' and w.ends_at > now()) then
        raise exception 'calendar_name_in_use: henkilöllä on tulevia vuoroja; kalenterinimen vaihto vaatii Joonaksen' using errcode = '22023';
      end if;
    end if;
    if a ? 'phone' and nullif(btrim(a->>'phone'), '') is not null and public.shift_offer_phone_e164(a->>'phone') is null then
      raise exception 'bad_phone' using errcode = '22023';
    end if;
    if a ? 'email' and nullif(btrim(a->>'email'), '') is not null and btrim(a->>'email') !~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then
      raise exception 'bad_email' using errcode = '22023';
    end if;
    if a ? 'notes' and length(a->>'notes') > 1000 then raise exception 'notes_too_long' using errcode = '22023'; end if;
    if p_action = 'staff_update' and a ? 'active' and not (a->>'active')::boolean and v_staff = c.staff_id then
      raise exception 'cannot_deactivate_self' using errcode = '22023';
    end if;

    if p_action = 'staff_create' then
      if nullif(btrim(a->>'name'), '') is null or nullif(btrim(a->>'calendar_name'), '') is null then
        raise exception 'name ja calendar_name vaaditaan' using errcode = '22023';
      end if;
      insert into public.staff (name, calendar_name, phone_e164, email, notes, active)
      values (btrim(a->>'name'), btrim(a->>'calendar_name'), public.shift_offer_phone_e164(a->>'phone'),
              nullif(lower(btrim(a->>'email')), ''), nullif(btrim(a->>'notes'), ''), true)
      returning id into v_staff;
      insert into public.staff_roles (staff_id, role_type, active)
      select v_staff, r, true from jsonb_array_elements_text(coalesce(a->'roles', '[]'::jsonb)) r
       where r in ('heater','reception','therapist')
      on conflict (staff_id, role_type) do nothing;
    else
      update public.staff s set
        name          = case when a ? 'name' then btrim(a->>'name') else s.name end,
        calendar_name = case when a ? 'calendar_name' then btrim(a->>'calendar_name') else s.calendar_name end,
        phone_e164    = case when a ? 'phone' then public.shift_offer_phone_e164(a->>'phone') else s.phone_e164 end,
        email         = case when a ? 'email' then nullif(lower(btrim(a->>'email')), '') else s.email end,
        notes         = case when a ? 'notes' then nullif(btrim(a->>'notes'), '') else s.notes end,
        active        = case when a ? 'active' then (a->>'active')::boolean else s.active end
       where s.id = v_staff;
    end if;
    select to_jsonb(s) - 'created_at' - 'updated_at' into v_new from public.staff s where s.id = v_staff;
    perform botgw._audit(c, p_action, 'staff', v_staff::text, v_old, v_new);
    select count(*) into v_n from public.shift_assignments sa join public.work_shifts w on w.id = sa.shift_id
     where sa.staff_id = v_staff and sa.status in ('assigned','confirmed') and w.status = 'active' and w.ends_at > now();
    v := jsonb_build_object('ok', true, 'staff_id', v_staff, 'future_shifts', v_n);
    v_tt := 'staff'; v_tid := v_staff::text; v_det := jsonb_build_object('fields', (select jsonb_agg(k) from jsonb_object_keys(a) k where k <> 'request_id'));

  elsif p_action = 'staff_role_set' then
    v_staff := botgw._uuid(a->>'staff_id'); v_role := a->>'role';
    if v_staff is null or not exists (select 1 from public.staff s where s.id = v_staff) then raise exception 'not_found' using errcode = 'P0002'; end if;
    if v_role is null or v_role not in ('heater','reception','therapist') then raise exception 'bad_role' using errcode = '22023'; end if;
    if not (a ? 'active') then raise exception 'active_required' using errcode = '22023'; end if;
    select to_jsonb(r) into v_old from public.staff_roles r where r.staff_id = v_staff and r.role_type = v_role;
    insert into public.staff_roles (staff_id, role_type, active) values (v_staff, v_role, (a->>'active')::boolean)
    on conflict (staff_id, role_type) do update set active = excluded.active;
    select to_jsonb(r) into v_new from public.staff_roles r where r.staff_id = v_staff and r.role_type = v_role;
    perform botgw._audit(c, 'staff_role_set', 'staff_roles', v_staff::text || ':' || v_role, v_old, v_new);
    v := jsonb_build_object('ok', true, 'staff_id', v_staff, 'role', v_role, 'active', (a->>'active')::boolean);
    v_tt := 'staff_roles'; v_tid := v_staff::text || ':' || v_role;

  -- ===== Poissaolot / esteet =====
  elsif p_action = 'unavailability_list' then
    v_from := coalesce((a->>'from')::date, (now() at time zone 'Europe/Helsinki')::date);
    v_to   := coalesce((a->>'to')::date, v_from + 90);
    if v_to < v_from or v_to - v_from > 400 then raise exception 'bad_range' using errcode = '22023'; end if;
    v_staff := botgw._uuid(a->>'staff_id');
    select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'staff_id', u.staff_id, 'name', s.name,
             'starts', to_char(u.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
             'ends',   to_char(u.ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
             'source', u.source, 'editable', u.source not in ('personal_calendar','sauna_calendar'))
             order by u.starts_at, s.name), '[]'::jsonb)
      into v from public.staff_unavailability u join public.staff s on s.id = u.staff_id
     where u.ends_at > (v_from::timestamp at time zone 'Europe/Helsinki')
       and u.starts_at < ((v_to + 1)::timestamp at time zone 'Europe/Helsinki')
       and (v_staff is null or u.staff_id = v_staff);

  elsif p_action in ('unavailability_add','unavailability_update') then
    v_s := botgw._ts(a->>'starts'); v_e := botgw._ts(a->>'ends');
    if v_s is null or v_e is null then raise exception 'Alku ja loppu vaaditaan' using errcode = '22023'; end if;
    if v_e <= v_s then raise exception 'Lopun pitää olla alun jälkeen' using errcode = '22023'; end if;
    if v_e <= now() then raise exception 'Este on kokonaan menneisyydessä' using errcode = '22023'; end if;
    if v_e > now() + interval '400 days' then raise exception 'Enintään 400 päivää eteenpäin' using errcode = '22023'; end if;
    if p_action = 'unavailability_add' then
      v_staff := botgw._uuid(a->>'staff_id');
      if v_staff is null or not exists (select 1 from public.staff s where s.id = v_staff and s.active) then
        raise exception 'Henkilöä ei löytynyt tai hän ei ole aktiivinen' using errcode = '22023';
      end if;
      insert into public.staff_unavailability (staff_id, starts_at, ends_at, source, external_ref, created_by)
      values (v_staff, v_s, v_e, 'staff_bot', null, v_actor)
      returning id into v_uid;
    else
      v_uid := botgw._uuid(a->>'id');
      select to_jsonb(u) into v_old from public.staff_unavailability u where u.id = v_uid;
      if v_old is null then raise exception 'not_found' using errcode = 'P0002'; end if;
      if v_old->>'source' in ('personal_calendar','sauna_calendar') then
        raise exception 'calendar_managed: tämä este tulee kalenterista, muuta se kalenterissa' using errcode = '42501';
      end if;
      update public.staff_unavailability set starts_at = v_s, ends_at = v_e, updated_at = now() where id = v_uid;
    end if;
    select to_jsonb(u) into v_new from public.staff_unavailability u where u.id = v_uid;
    perform botgw._audit(c, p_action, 'staff_unavailability', v_uid::text, v_old, v_new);
    v := jsonb_build_object('ok', true, 'id', v_uid);
    v_tt := 'staff_unavailability'; v_tid := v_uid::text;

  elsif p_action = 'unavailability_delete' then
    v_uid := botgw._uuid(a->>'id');
    select to_jsonb(u) into v_old from public.staff_unavailability u where u.id = v_uid;
    if v_old is null then raise exception 'not_found' using errcode = 'P0002'; end if;
    if v_old->>'source' in ('personal_calendar','sauna_calendar') then
      raise exception 'calendar_managed: tämä este tulee kalenterista, poista se kalenterista' using errcode = '42501';
    end if;
    delete from public.staff_unavailability where id = v_uid;
    perform botgw._audit(c, 'unavailability_delete', 'staff_unavailability', v_uid::text, v_old, null);
    v := jsonb_build_object('ok', true, 'id', v_uid);
    v_tt := 'staff_unavailability'; v_tid := v_uid::text;

  -- ===== Logiikkaehdotukset (vain ehdotus; Joonas päättää) =====
  elsif p_action = 'proposal_add' then
    if nullif(btrim(a->>'title'), '') is null or nullif(btrim(a->>'body'), '') is null then
      raise exception 'title ja body vaaditaan' using errcode = '22023';
    end if;
    if coalesce(a->>'area', 'other') not in ('notifications','shift_offers','other') then raise exception 'bad_area' using errcode = '22023'; end if;
    if a ? 'proposed_change' and jsonb_typeof(a->'proposed_change') <> 'object' then raise exception 'proposed_change_must_be_object' using errcode = '22023'; end if;
    insert into botgw.logic_proposals (client_id, source_bot, actor, actor_staff_id, area, title, body, proposed_change)
    values (c.id, c.name, (select s.name from public.staff s where s.id = c.staff_id), c.staff_id,
            coalesce(a->>'area', 'other'), left(btrim(a->>'title'), 200), left(btrim(a->>'body'), 4000),
            coalesce(a->'proposed_change', '{}'::jsonb))
    returning id into v_id;
    v := jsonb_build_object('ok', true, 'proposal_id', v_id, 'status', 'pending');
    v_tt := 'logic_proposal'; v_tid := v_id::text;

  elsif p_action = 'proposal_list' then
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'created_at', p.created_at, 'area', p.area, 'title', p.title,
             'status', p.status, 'decided_by', p.decided_by, 'decided_at', p.decided_at, 'decision_note', p.decision_note)
             order by p.id desc), '[]'::jsonb)
      into v from (select * from botgw.logic_proposals p where p.client_id = c.id order by p.id desc limit 50) p;
  end if;

  insert into botgw.call_log (client_id, action, ok, request_id, target_type, target_id, detail)
  values (c.id, p_action, true, v_req, v_tt, v_tid, v_det);
  return jsonb_build_object('ok', true, 'data', v) || case when v_req is not null then jsonb_build_object('request_id', v_req) else '{}'::jsonb end;
end $f$;

revoke all on function botgw.call(text, text, jsonb) from public, anon, authenticated;
grant execute on function botgw.call(text, text, jsonb) to service_role;
