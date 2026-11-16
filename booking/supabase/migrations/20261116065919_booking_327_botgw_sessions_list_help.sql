-- booking_327: botgw sessions_list (vain luku) ja help (t1811u + Koodarin pyyntö 16.11.2026).
-- Ennakkoehto: botgw.call md5 = 59cbd540a8775b841c566b4f73b507e9 (booking_321),
--              bot_clients_scopes_known md5 = 21afc1fc9a63a356d1c3eb07ea279376.
-- Muutos botgw.call-funktioon pidetään pienenä: kaksi uutta haaraa, scope-kartta,
-- sessions.close implikoi sessions_list-luvun. Ei muutosta kirjoitusrajoihin.
-- sessions_list ei palauta asiakkaiden nimiä, sähköposteja, puhelimia, tilausnumeroita,
-- varaus-id:itä eikä hinta- tai maksutietoja.
-- Rollback: /workspace/migraatiot/booking_327_ROLLBACK.sql
set local lock_timeout = '5s';

do $pre$
begin
  if md5(pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure)) <> '59cbd540a8775b841c566b4f73b507e9' then
    raise exception 'booking_327: botgw.call ei ole odotettu versio (md5 59cbd540a8775b841c566b4f73b507e9); ei ajeta';
  end if;
  if (select md5(pg_get_constraintdef(oid)) from pg_constraint
       where conrelid = 'botgw.bot_clients'::regclass and conname = 'bot_clients_scopes_known')
     is distinct from '21afc1fc9a63a356d1c3eb07ea279376' then
    raise exception 'booking_327: bot_clients_scopes_known ei ole odotettu (md5 21afc1fc9a63a356d1c3eb07ea279376); ei ajeta';
  end if;
end $pre$;

-- ---- sessions_list: vain luku ------------------------------------------------

CREATE OR REPLACE FUNCTION botgw._sessions_list(p_args jsonb, p_client botgw.bot_clients)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  a jsonb := coalesce(p_args, '{}'::jsonb);
  v_from date;
  v_to date;
  v_space_id bigint;
  v_product_id bigint;
  v_out jsonb;
begin
  if nullif(btrim(coalesce(a->>'date', '')), '') is not null then
    begin
      v_from := (a->>'date')::date;
    exception when others then
      raise exception 'bad_range: date virheellinen' using errcode = '22023';
    end;
    v_to := v_from;
    if (nullif(btrim(coalesce(a->>'from','')), '') is not null
        and (a->>'from')::date is distinct from v_from)
       or (nullif(btrim(coalesce(a->>'to','')), '') is not null
        and (a->>'to')::date is distinct from v_to) then
      raise exception 'bad_range: anna joko date tai from/to' using errcode = '22023';
    end if;
  else
    begin
      v_from := nullif(btrim(coalesce(a->>'from','')), '')::date;
      v_to   := nullif(btrim(coalesce(a->>'to','')), '')::date;
    exception when others then
      raise exception 'bad_range: from/to virheellinen' using errcode = '22023';
    end;
    if v_from is null and v_to is null then
      v_from := (now() at time zone booking._tz())::date;
      v_to := v_from;
    elsif v_from is null or v_to is null then
      raise exception 'bad_range: from ja to vaaditaan yhdessä, tai date' using errcode = '22023';
    end if;
  end if;
  if v_to < v_from or (v_to - v_from) > 30 then
    raise exception 'bad_range: enintään 31 päivää' using errcode = '22023';
  end if;

  begin
    v_product_id := nullif(btrim(coalesce(a->>'product_id','')), '')::bigint;
  exception when others then
    raise exception 'bad_param: product_id' using errcode = '22023';
  end;
  begin
    v_space_id := nullif(btrim(coalesce(a->>'space_id','')), '')::bigint;
  exception when others then
    raise exception 'bad_param: space_id' using errcode = '22023';
  end;
  if v_space_id is null and nullif(btrim(coalesce(a->>'space','')), '') is not null then
    select r.id into v_space_id from booking.resources r where r.code = btrim(a->>'space');
    if v_space_id is null then
      raise exception 'not_found: space' using errcode = 'P0002';
    end if;
  end if;

  select coalesce(jsonb_agg(x.item order by (x.item->>'starts_at'), (x.item->>'space'), (x.item->>'rule_id')::bigint), '[]'::jsonb)
    into v_out
    from (
      select jsonb_strip_nulls(jsonb_build_object(
               'rule_id', s.rule_id,
               'date', s.session_date,
               'product_id', s.product_id,
               'product', s.product_name,
               'space_id', s.space_id,
               'space', s.space_code,
               'starts_at', to_char(s.starts_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
               'ends_at',   to_char(s.ends_at   at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
               'capacity', s.capacity,
               'reservation_count', occ.reservation_count,
               'booked_persons', occ.booked_persons,
               'has_reservations', occ.reservation_count > 0,
               'closed', blk.closed,
               'block_id', blk.own_block_id,
               'can_close', (occ.reservation_count = 0 and not blk.closed)
             )) as item
        from (
          select r.id as rule_id,
                 r.product_id,
                 p.name as product_name,
                 r.space_id,
                 res.code as space_code,
                 d.d::date as session_date,
                 ((d.d + r.start_time) at time zone booking._tz()) as starts_at,
                 ((d.d + r.start_time + make_interval(mins => r.duration_minutes)) at time zone booking._tz()) as ends_at,
                 r.max_persons as capacity
            from booking.schedule_rules r
            join kb.products p on p.id = r.product_id and p.active
            join booking.resources res on res.id = r.space_id
            cross join lateral generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') as d(d)
           where r.active and r.cancelled_at is null
             and extract(isodow from d.d)::smallint = any (r.weekdays)
             and (r.valid_from is null or d.d::date >= r.valid_from)
             and (r.valid_to is null or d.d::date <= r.valid_to)
             and (v_product_id is null or r.product_id = v_product_id)
             and (v_space_id is null or r.space_id = v_space_id)
        ) s
        cross join lateral (
          select count(*)::int as reservation_count,
                 coalesce(sum(q.persons), 0)::int as booked_persons
            from (
              select c.reservation_id, max(c.persons) as persons
                from booking.v_claims c
               where c.resource_id = s.space_id
                 and booking._res_active(c.status, c.hold_expires_at)
                 and tstzrange(c.claim_start, c.claim_end, '[)') && tstzrange(s.starts_at, s.ends_at, '[)')
               group by c.reservation_id
            ) q
        ) occ
        cross join lateral (
          select coalesce(bool_or(b.id is not null), false) as closed,
                 min(b.id) filter (where b.created_by is not distinct from p_client.staff_id) as own_block_id
            from booking.space_blocks b
           where b.space_id = s.space_id
             and b.active
             and tstzrange(b.starts_at, b.ends_at, '[)') && tstzrange(s.starts_at, s.ends_at, '[)')
        ) blk
    ) x;

  return jsonb_build_object(
    'ok', true,
    'from', v_from,
    'to', v_to,
    'sessions', coalesce(v_out, '[]'::jsonb)
  );
end
$function$;

COMMENT ON FUNCTION botgw._sessions_list(jsonb, botgw.bot_clients) IS
  'booking_327: sessions_list, vain luku. Ei PII:tä, ei hintoja eikä tilausnumeroita.';

-- ---- help: avaimen sallitut toiminnot, ei salaisuuksia ----------------------

CREATE OR REPLACE FUNCTION botgw._action_help(p_client botgw.bot_clients)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_all jsonb;
  v_actions jsonb;
begin
  v_all := $c$[
    {"action":"me","scope":"me","write":false,"params":{}},
    {"action":"help","scope":"me","write":false,"params":{},
     "summary":"Palauttaa tämän avaimen sallitut toiminnot ja parametrit, ilman salaisuuksia."},
    {"action":"my_shifts","scope":"shifts.read","write":false,"params":{"from":"date?","to":"date?"}},
    {"action":"offers_open","scope":"offers.respond","write":false,"params":{}},
    {"action":"offer_respond","scope":"offers.respond","write":true,
     "params":{"offer_id":"uuid","response":"text","snooze_until":"timestamptz?"}},
    {"action":"inbox","scope":"inbox.read","write":false,"params":{}},
    {"action":"inbox_ack","scope":"inbox.read","write":true,"params":{}},
    {"action":"backlog_list","scope":"backlog.read","write":false,"params":{"all":"boolean?"}},
    {"action":"backlog_update","scope":"backlog.write","write":true,
     "params":{"item_id":"bigint","status":"text?","note":"text?","task_id":"bigint?","task_done":"boolean?"}},
    {"action":"backlog_add","scope":"backlog.write","write":true,
     "params":{"title":"text","description":"text?","category":"text?","kind":"text?"}},
    {"action":"backlog_claim","scope":"backlog.write","write":true,"params":{"item_id":"bigint","note":"text?"}},
    {"action":"backlog_task_add","scope":"backlog.write","write":true,
     "params":{"item_id":"bigint","title":"text","due_date":"date?"}},
    {"action":"shifts_list","scope":"shifts.read_all","write":false,
     "params":{"from":"date?","to":"date?","role":"text?","staff_id":"uuid?","include_cancelled":"boolean?"}},
    {"action":"shift_history","scope":"shifts.read_all","write":false,"params":{"shift_id":"uuid"}},
    {"action":"shift_change","scope":"shifts.manage","write":true,
     "params":{"action":"create|assign|unassign|change_time|cancel","shift_id":"uuid?","staff_id":"uuid?","role":"text?","starts":"timestamptz?","ends":"timestamptz?","note":"text?"}},
    {"action":"shift_reassign","scope":"shifts.manage","write":true,
     "params":{"shift_id":"uuid","from_staff_id":"uuid","to_staff_id":"uuid","note":"text?"}},
    {"action":"staff_list","scope":"staff.read","write":false,"params":{"include_inactive":"boolean?"}},
    {"action":"unavailability_list","scope":"staff.read","write":false,"params":{"from":"date?","to":"date?","staff_id":"uuid?"}},
    {"action":"staff_create","scope":"staff.manage","write":true,
     "params":{"name":"text","calendar_name":"text?","email":"text?","phone":"text?","notes":"text?","active":"boolean?"}},
    {"action":"staff_update","scope":"staff.manage","write":true,
     "params":{"staff_id":"uuid","name":"text?","calendar_name":"text?","email":"text?","phone":"text?","notes":"text?","active":"boolean?"}},
    {"action":"staff_role_set","scope":"staff.manage","write":true,"params":{"staff_id":"uuid","role":"text","active":"boolean"}},
    {"action":"unavailability_add","scope":"unavailability.manage","write":true,
     "params":{"staff_id":"uuid?","starts":"timestamptz","ends":"timestamptz"}},
    {"action":"unavailability_update","scope":"unavailability.manage","write":true,
     "params":{"id":"uuid","staff_id":"uuid?","starts":"timestamptz?","ends":"timestamptz?"}},
    {"action":"unavailability_delete","scope":"unavailability.manage","write":true,"params":{"id":"uuid"}},
    {"action":"own_absence_sync","scope":"unavailability.manage","write":true,"params":{"from":"date","to":"date"}},
    {"action":"own_shift_release","scope":"shifts.manage","write":true,
     "params":{"shift_id":"uuid","absence_id":"uuid?","confirmed":"boolean?","reason":"text?"}},
    {"action":"proposal_add","scope":"proposals.write","write":true,
     "params":{"title":"text","body":"text","area":"text?","proposed_change":"jsonb?"}},
    {"action":"proposal_list","scope":"proposals.write","write":false,"params":{}},
    {"action":"newsletter_list","scope":"newsletter.draft","write":false,"params":{"state":"text?"}},
    {"action":"newsletter_get","scope":"newsletter.draft","write":false,"params":{"id":"bigint"}},
    {"action":"newsletter_save","scope":"newsletter.draft","write":true,"params":{"id":"bigint?","version":"int?"}},
    {"action":"session_close","scope":"sessions.close","write":true,
     "params":{"space_id":"bigint?","space":"text?","starts_at":"timestamptz?","ends_at":"timestamptz?","rule_id":"bigint?","date":"date?","reason":"text"},
     "summary":"Käsisulku. Hylätään, jos vuorolla on varauksia (has_reservations, reservation_count). Ei avausta eikä poistoa."},
    {"action":"sessions_list","scope":"sessions.read","write":false,
     "implied_by":["sessions.close"],
     "params":{"date":"date?","from":"date?","to":"date?","space_id":"bigint?","space":"text?","product_id":"bigint?"},
     "summary":"Vain luku, enintään 31 päivää. Palauttaa session_close-tunnisteet, kapasiteetin, varausten ja henkilöiden määrän, sulun ja can_close. Ei asiakas- eikä maksutietoja."}
  ]$c$::jsonb;

  select coalesce(jsonb_agg(e.el order by e.ord), '[]'::jsonb)
    into v_actions
    from jsonb_array_elements(v_all) with ordinality as e(el, ord)
   where (e.el->>'scope') = any (p_client.scopes)
      or (e.el->>'action' = 'sessions_list'
          and (p_client.scopes && array['sessions.read','sessions.close']));

  return jsonb_build_object(
    'ok', true,
    'name', p_client.name,
    'scopes', to_jsonb(p_client.scopes),
    'actions', v_actions
  );
end
$function$;

COMMENT ON FUNCTION botgw._action_help(botgw.bot_clients) IS
  'booking_327: help. Palauttaa kutsuvan avaimen sallitut toiminnot ja parametrit, ilman salaisuuksia.';

REVOKE ALL ON FUNCTION botgw._sessions_list(jsonb, botgw.bot_clients) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION botgw._action_help(botgw.bot_clients) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION botgw._sessions_list(jsonb, botgw.bot_clients) TO service_role;
GRANT EXECUTE ON FUNCTION botgw._action_help(botgw.bot_clients) TO service_role;

CREATE OR REPLACE FUNCTION botgw.call(p_key_hash text, p_action text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c botgw.bot_clients;
  a jsonb := coalesce(p_args, '{}'::jsonb);
  v jsonb; v_id bigint; v_from date; v_to date; v_cat text; v_pos int; v_offer uuid;
  v_req uuid; v_tt text; v_tid text; v_det jsonb;
  v_shift uuid; v_staff uuid; v_staff2 uuid; v_role text; v_s timestamptz; v_e timestamptz;
  v_old jsonb; v_new jsonb; v_uid uuid; v_txt text; v_n int; v_actor text; v_task bigint;
  v_ev jsonb; v_add int := 0; v_upd int := 0; v_del int := 0; v_refs text[] := '{}'::text[];
  v_s2 timestamptz; v_e2 timestamptz; v_ws timestamptz; v_we timestamptz;
  v_nl booking.newsletters; v_data jsonb; v_space_id bigint;
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
    when 'own_absence_sync' then 'unavailability.manage'
    when 'own_shift_release' then 'shifts.manage'
    when 'proposal_add' then 'proposals.write'
    when 'proposal_list' then 'proposals.write'
    when 'newsletter_list' then 'newsletter.draft'
    when 'newsletter_get' then 'newsletter.draft'
    when 'newsletter_save' then 'newsletter.draft'
    when 'session_close' then 'sessions.close'
    when 'sessions_list' then 'sessions.read'
    when 'help' then 'me'
    else null end;
  v_write boolean;
begin
  if v_scope is null then raise exception 'unknown_action' using errcode = '22023'; end if;
  if p_action = 'sessions_list' then
    begin
      c := botgw._client(p_key_hash, 'sessions.read');
    exception
      when sqlstate '42501' then
        c := botgw._client(p_key_hash, 'sessions.close');
    end;
  else
    c := botgw._client(p_key_hash, v_scope);
  end if;
  v_actor := 'bot:' || c.name;
  v_write := p_action in ('offer_respond','backlog_update','backlog_add','backlog_claim','backlog_task_add','shift_change','shift_reassign','staff_create',
                          'staff_update','staff_role_set','unavailability_add','unavailability_update','unavailability_delete','own_absence_sync','own_shift_release','proposal_add','newsletter_save','session_close');

  -- Rajoitukset (lasketaan call_logista: onnistuneet + edge-funktion kirjaamat epäonnistuneet)
  select count(*) into v_n from botgw.call_log l where l.client_id = c.id and l.at > now() - interval '1 minute';
  if v_n >= 120 then raise exception 'rate_limited' using errcode = 'BG429'; end if;
  if v_write then
    select count(*) into v_n from botgw.call_log l where l.client_id = c.id and l.at > now() - interval '1 minute'
       and l.action in ('offer_respond','backlog_update','backlog_add','backlog_claim','backlog_task_add','shift_change','shift_reassign','staff_create',
                        'staff_update','staff_role_set','unavailability_add','unavailability_update','unavailability_delete','own_absence_sync','own_shift_release','proposal_add','newsletter_save','session_close');
    if v_n >= 20 then raise exception 'rate_limited' using errcode = 'BG429'; end if;
    select count(*) into v_n from botgw.call_log l where l.client_id = c.id and l.at > now() - interval '1 day'
       and l.action in ('shift_change','shift_reassign','staff_create','staff_update','staff_role_set',
                        'unavailability_add','unavailability_update','unavailability_delete','own_absence_sync','own_shift_release','newsletter_save','session_close');
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

  -- ===== Oton oma kalenteri -> esteet (Joonaksen toive 25.10.2026 klo 18.03) =====
  -- Vain kutsujan omat rivit, source 'otto_bot', tunnisteena kalenteritapahtuman ref (external_ref).
  -- events = koko totuus aikavälille [from, to]: puuttuvat otto_bot-rivit poistetaan välin tulevalta osalta.
  -- Ei koske personal_calendar-, sauna_calendar- eikä muiden lähteiden riveihin.
  elsif p_action = 'own_absence_sync' then
    v_from := (a->>'from')::date; v_to := (a->>'to')::date;
    if v_from is null or v_to is null then raise exception 'from ja to vaaditaan' using errcode = '22023'; end if;
    if v_to < v_from or v_to - v_from > 120 then raise exception 'Aikaväli enintään 120 päivää' using errcode = '22023'; end if;
    if jsonb_typeof(coalesce(a->'events', '[]'::jsonb)) <> 'array' then raise exception 'events pitää olla lista' using errcode = '22023'; end if;
    if jsonb_array_length(coalesce(a->'events', '[]'::jsonb)) > 300 then raise exception 'Enintään 300 tapahtumaa kerralla' using errcode = '22023'; end if;
    v_ws := greatest((v_from::timestamp at time zone 'Europe/Helsinki'), now());
    v_we := ((v_to + 1)::timestamp at time zone 'Europe/Helsinki');
    for v_ev in select x from jsonb_array_elements(coalesce(a->'events', '[]'::jsonb)) x loop
      v_txt := left(nullif(btrim(v_ev->>'ref'), ''), 200);
      v_s2 := botgw._ts(v_ev->>'starts'); v_e2 := botgw._ts(v_ev->>'ends');
      if v_txt is null or v_s2 is null or v_e2 is null or v_e2 <= v_s2 then
        raise exception 'Virheellinen tapahtuma: ref, starts ja ends vaaditaan, lopun pitää olla alun jälkeen' using errcode = '22023';
      end if;
      if v_e2 - v_s2 > interval '31 days' then raise exception 'Tapahtuma voi olla enintään 31 vrk' using errcode = '22023'; end if;
      if v_s2 > now() + interval '400 days' then raise exception 'Enintään 400 päivää eteenpäin' using errcode = '22023'; end if;
      if v_txt = any(v_refs) then raise exception 'Sama ref kahdesti' using errcode = '22023'; end if;
      v_refs := v_refs || v_txt;
      continue when v_e2 <= now();
      v_old := null;
      select to_jsonb(u) into v_old from public.staff_unavailability u
       where u.staff_id = c.staff_id and u.source = 'otto_bot' and u.external_ref = v_txt;
      if v_old is null then
        insert into public.staff_unavailability (staff_id, starts_at, ends_at, source, external_ref, created_by)
        values (c.staff_id, v_s2, v_e2, 'otto_bot', v_txt, v_actor);
        v_add := v_add + 1;
      elsif (v_old->>'starts_at')::timestamptz is distinct from v_s2 or (v_old->>'ends_at')::timestamptz is distinct from v_e2 then
        update public.staff_unavailability set starts_at = v_s2, ends_at = v_e2, updated_at = now()
         where id = (v_old->>'id')::uuid;
        v_upd := v_upd + 1;
      end if;
    end loop;
    delete from public.staff_unavailability u
     where u.staff_id = c.staff_id and u.source = 'otto_bot'
       and u.ends_at > v_ws and u.starts_at < v_we
       and not (coalesce(u.external_ref, '') = any(v_refs));
    get diagnostics v_del = row_count;
    v := jsonb_build_object('ok', true, 'added', v_add, 'updated', v_upd, 'removed', v_del);
    if v_add + v_upd + v_del > 0 then
      perform botgw._audit(c, 'own_absence_sync', 'staff_unavailability', c.staff_id::text, null,
                           v || jsonb_build_object('from', v_from, 'to', v_to));
    end if;
    v_tt := 'staff_unavailability'; v_tid := c.staff_id::text;
    v_det := jsonb_build_object('added', v_add, 'updated', v_upd, 'removed', v_del, 'from', v_from, 'to', v_to);

  -- ===== Oman vuoron vapautus päällekkäisen oman tapahtuman takia (Joonaksen toive 25.10.2026 klo 18.03) =====
  -- Vain Oton oma vuoro, vain jos Oton oma este (absence_id) menee aidosti päällekkäin vuoron kanssa.
  -- Alle 12 h ennen alkua vain confirmed=true (Otto vahvistanut). Alkanutta vuoroa ei vapauteta.
  -- Otto poistetaan ilman korvaajaa -> vuoro avautuu (shift_open_events) ja tarjousmoottori voi tarjota sitä.
  elsif p_action = 'own_shift_release' then
    v_shift := botgw._uuid(a->>'shift_id');
    v_uid := botgw._uuid(a->>'absence_id');
    v_txt := left(nullif(btrim(a->>'reason'), ''), 300);
    if v_shift is null or v_uid is null or v_txt is null then
      raise exception 'shift_id, absence_id ja reason vaaditaan' using errcode = '22023';
    end if;
    select w.starts_at, w.ends_at into v_s, v_e
      from public.work_shifts w join public.shift_assignments sa on sa.shift_id = w.id
     where w.id = v_shift and w.status = 'active' and sa.staff_id = c.staff_id and sa.status in ('assigned','confirmed');
    if not found then raise exception 'Et ole tässä vuorossa tai vuoro on peruttu' using errcode = '22023'; end if;
    if v_s <= now() then raise exception 'Vuoro on jo alkanut; sitä ei vapauteta botilla' using errcode = '22023'; end if;
    if v_s < now() + interval '12 hours' and not coalesce((a->>'confirmed')::boolean, false) then
      raise exception 'confirm_required: vuoro alkaa alle 12 tunnin päästä; kysy Otolta vahvistus ja lähetä confirmed: true' using errcode = '22023';
    end if;
    if not exists (select 1 from public.staff_unavailability u
                    where u.id = v_uid and u.staff_id = c.staff_id and u.starts_at < v_e and u.ends_at > v_s) then
      raise exception 'Päällekkäisyyttä ei löytynyt: absence_id ei ole oma este, joka menee vuoron kanssa päällekkäin' using errcode = '22023';
    end if;
    v := public.shift_apply_change('unassign', v_shift, c.staff_id, null, null, null, 'staff_bot', v_actor, c.staff_id,
                                   left('Vapautettu: päällekkäinen oma tapahtuma. ' || v_txt, 500), v_req);
    perform botgw._audit(c, 'own_shift_release', 'work_shift', v_shift::text,
                         jsonb_build_object('starts_at', v_s, 'ends_at', v_e, 'staff_id', c.staff_id),
                         jsonb_build_object('absence_id', v_uid, 'reason', v_txt, 'confirmed', coalesce((a->>'confirmed')::boolean, false)));
    v_tt := 'shift'; v_tid := v_shift::text;
    v_det := jsonb_build_object('absence_id', v_uid, 'reason', left(v_txt, 200),
                                'hours_ahead', round((extract(epoch from (v_s - now())) / 3600)::numeric, 1));

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
  -- ===== Uutiskirjeet (booking_315, scope newsletter.draft): vain luonnokset. =====
  -- Ei lähetystä, ajastusta, esikatselu-/testilähetystä eikä lippuja: admin_newsletter_dispatch ja asetukset eivät ole saatavilla.
  -- suggested_send_at ei ole botin muokattavissa (säilyy ennallaan, uudella luonnoksella tyhjä).
  elsif p_action = 'newsletter_list' then
    if a->>'state' is not null and (a->>'state') not in ('draft','previewed','sent') then raise exception 'bad_state' using errcode = '22023'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'state', n.state, 'version', n.version, 'editable', n.state = 'draft',
             'subject_fi', n.subject_fi, 'subject_en', n.subject_en, 'segment', n.segment, 'language', n.language,
             'suggested_send_at', n.suggested_send_at, 'created_at', n.created_at, 'updated_at', n.updated_at)
             order by n.updated_at desc, n.id desc), '[]'::jsonb)
      into v
      from (select * from booking.newsletters x where a->>'state' is null or x.state = a->>'state'
             order by x.updated_at desc, x.id desc limit 100) n;

  elsif p_action = 'newsletter_get' then
    v_id := (a->>'id')::bigint;
    if v_id is null then raise exception 'id vaaditaan' using errcode = '22023'; end if;
    select jsonb_build_object('id', n.id, 'state', n.state, 'version', n.version, 'editable', n.state = 'draft',
             'subject_fi', n.subject_fi, 'subject_en', n.subject_en, 'body_fi', n.body_fi, 'body_en', n.body_en,
             'style', n.style, 'segment', n.segment, 'language', n.language, 'suggested_send_at', n.suggested_send_at,
             'created_at', n.created_at, 'updated_at', n.updated_at)
      into v from booking.newsletters n where n.id = v_id;
    if v is null then raise exception 'not_found' using errcode = 'P0002'; end if;

  elsif p_action = 'newsletter_save' then
    for v_txt in select jsonb_object_keys(a) loop
      if v_txt not in ('id','version','request_id','subject_fi','subject_en','body_fi','body_en','style','segment','language') then
        raise exception 'field_not_editable: %', left(v_txt, 40) using errcode = '42501';
      end if;
    end loop;
    v_data := a - 'id' - 'version' - 'request_id';
    v_id := (a->>'id')::bigint;
    if v_id is not null then
      if a->>'version' is null then raise exception 'version vaaditaan muokattaessa' using errcode = '22023'; end if;
      select * into v_nl from booking.newsletters n where n.id = v_id for update;
      if v_nl.id is null then raise exception 'not_found' using errcode = 'P0002'; end if;
      if v_nl.state <> 'draft' then
        raise exception 'not_editable: vain luonnosta voi muokata (tila %)', v_nl.state using errcode = '42501';
      end if;
      if (a->>'version')::int is distinct from v_nl.version then
        raise exception 'version_conflict: luonnos on muuttunut (versio %), hae se uudelleen', v_nl.version using errcode = '22023';
      end if;
      if v_data = '{}'::jsonb then raise exception 'Ei tallennettavaa' using errcode = '22023'; end if;
      v_old := to_jsonb(v_nl) - 'preview_signature' - 'preview_token';
      v_data := jsonb_build_object('subject_fi', v_nl.subject_fi, 'subject_en', v_nl.subject_en, 'body_fi', v_nl.body_fi,
                  'body_en', v_nl.body_en, 'style', v_nl.style, 'segment', v_nl.segment, 'language', v_nl.language,
                  'suggested_send_at', v_nl.suggested_send_at) || v_data;
    end if;
    begin
      v_new := booking._newsletter_save(v_id, v_data, case when v_id is null then null else (a->>'version')::int end);
    exception
      when sqlstate 'BK001' then
        raise exception 'version_conflict: luonnos muuttui tai on jo lähetetty, hae se uudelleen' using errcode = '22023';
      when sqlstate 'P0001' then
        raise exception 'invalid_newsletter: %', left(sqlerrm, 100) using errcode = '22023';
    end;
    v_id := (v_new->>'id')::bigint;
    perform botgw._audit(c, 'newsletter_save', 'newsletter', v_id::text, v_old, v_new);
    v := jsonb_build_object('ok', true, 'id', v_id, 'state', v_new->>'state', 'version', (v_new->>'version')::int,
           'created', v_old is null, 'updated_at', v_new->'updated_at');
    v_tt := 'newsletter'; v_tid := v_id::text;

  -- ===== Vuorolista ja ohje (booking_327): vain luku =====
  elsif p_action = 'sessions_list' then
    v := botgw._sessions_list(a, c);
    v_tt := 'sessions';
    v_det := jsonb_build_object('from', v->>'from', 'to', v->>'to',
                                'count', jsonb_array_length(coalesce(v->'sessions', '[]'::jsonb)));
  elsif p_action = 'help' then
    v := botgw._action_help(c);
  -- ===== Vuorojen sulku (booking_321, scope sessions.close): vain käsisulku. Ei poistoa eikä avaamista. =====
  elsif p_action = 'session_close' then
    v_space_id := (a->>'space_id')::bigint;
    if v_space_id is null and nullif(btrim(coalesce(a->>'space','')), '') is not null then
      select r.id into v_space_id from booking.resources r where r.code = btrim(a->>'space');
      if v_space_id is null then raise exception 'not_found: space' using errcode = 'P0002'; end if;
    end if;
    v_s := botgw._ts(a->>'starts_at');
    v_e := botgw._ts(a->>'ends_at');
    if a->>'rule_id' is not null then
      v_id := (a->>'rule_id')::bigint;
      if v_id is null then raise exception 'rule_id virheellinen' using errcode = '22023'; end if;
      if a->>'date' is null then raise exception 'date vaaditaan rule_id:n kanssa' using errcode = '22023'; end if;
      select sr.space_id,
             coalesce(v_s, ((a->>'date')::date + sr.start_time) at time zone 'Europe/Helsinki'),
             coalesce(v_e, ((a->>'date')::date + sr.start_time) at time zone 'Europe/Helsinki'
                            + make_interval(mins => sr.duration_minutes))
        into v_space_id, v_s, v_e
        from booking.schedule_rules sr
       where sr.id = v_id;
      if not found then raise exception 'not_found: rule' using errcode = 'P0002'; end if;
    end if;
    v := booking.svc_create_space_block(v_space_id, v_s, v_e, a->>'reason', v_actor, c.staff_id);
    if coalesce((v->>'ok')::boolean, false) then
      perform botgw._audit(c, 'session_close', 'space_block', v->>'id', null, v);
      v_tt := 'space_block'; v_tid := v->>'id';
    else
      insert into botgw.call_log (client_id, action, ok, request_id, target_type, target_id, detail)
      values (c.id, p_action, false, v_req, 'space_block', null, v);
      return v || case when v_req is not null then jsonb_build_object('request_id', v_req) else '{}'::jsonb end;
    end if;
  end if;

  insert into botgw.call_log (client_id, action, ok, request_id, target_type, target_id, detail)
  values (c.id, p_action, true, v_req, v_tt, v_tid, v_det);
  return jsonb_build_object('ok', true, 'data', v) || case when v_req is not null then jsonb_build_object('request_id', v_req) else '{}'::jsonb end;
end $function$;


alter table botgw.bot_clients drop constraint bot_clients_scopes_known;
alter table botgw.bot_clients add constraint bot_clients_scopes_known
  check (scopes <@ array['me', 'shifts.read', 'offers.respond', 'inbox.read', 'backlog.read', 'backlog.write', 'shifts.read_all', 'shifts.manage', 'staff.read', 'staff.manage', 'unavailability.manage', 'proposals.write', 'newsletter.draft', 'sessions.close', 'sessions.read']);

-- Anna sessions.read kaikille avaimille, joilla on jo sessions.close (mm. otto-grok-bot PRODissa).
update botgw.bot_clients
   set scopes = array_append(scopes, 'sessions.read')
 where 'sessions.close' = any (scopes)
   and not ('sessions.read' = any (scopes));

insert into kb.bot_permissions (botti, botti_id, toimenpide, ehdot, hyvaksyja, hyvaksynta_viite, paivamaara, voimassa)
select
  'Oton Grok Bot (botgw otto-grok-bot)',
  null,
  'Vuorolistan luku bot-gatewayn kautta (scope sessions.read, toiminto sessions_list) sekä help (avaimen sallitut toiminnot ja parametrit, ilman salaisuuksia). sessions.close implikoi sessions_list-luvun.',
  'Vain luku. sessions_list: päivä tai aikaväli enintään 31 päivää, vapaaehtoinen tila (space_id/space) tai tuote (product_id). Palauttaa session_close-tunnisteet (rule_id, date, space_id, space, starts_at, ends_at), tuotteen, tilan, kapasiteetin, varausten määrän, varattujen henkilöiden määrän, has_reservations, onko vuoro suljettu (block_id vain jos saman botin sulku) ja can_close. Ei asiakkaiden nimiä, sähköposteja, puhelimia, tilausnumeroita, varaus-id:itä eikä hinta- tai maksutietoja. help ei palauta avaimia eikä muita salaisuuksia. Alkuperäinen sulkulupa t1811u (15.11.2026); lukuoikeus lisätty Koodarin pyynnöstä 16.11.2026, koska botti yritti toimintoja sessions_list ja help.',
  'Joonas Vaarala',
  't1811u',
  date '2026-11-16',
  true
 where not exists (
   select 1 from kb.bot_permissions p
    where p.hyvaksynta_viite = 't1811u'
      and p.botti = 'Oton Grok Bot (botgw otto-grok-bot)'
      and p.toimenpide ilike '%sessions_list%'
 );

do $post$
begin
  if to_regprocedure('botgw._sessions_list(jsonb,botgw.bot_clients)') is null
     or to_regprocedure('botgw._action_help(botgw.bot_clients)') is null then
    raise exception 'booking_327: apufunktiot puuttuvat';
  end if;
  if position('sessions_list' in pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure)) = 0
     or position('when ''help'' then' in pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure)) = 0 then
    raise exception 'booking_327: botgw.call ei sisällä sessions_list/help-haaroja';
  end if;
  if not exists (
    select 1 from kb.bot_permissions p
     where p.hyvaksynta_viite = 't1811u' and p.toimenpide ilike '%sessions_list%' and p.voimassa
  ) then
    raise exception 'booking_327: bot_permissions-rivi puuttuu';
  end if;
end $post$;
