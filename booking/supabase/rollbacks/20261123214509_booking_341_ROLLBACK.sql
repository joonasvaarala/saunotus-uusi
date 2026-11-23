-- booking_341 ROLLBACK: palauttaa booking_340:n funktiot ja configin
update booking.settings
   set value = (value - 'shift_end_extension')
               || jsonb_build_object('grace_minutes', 30, 'repeat_cooldown_seconds', 120, 'max_attempts', 3, 'escalate', true),
       description = 'booking_340: hälytysnapin reititys. fallback_staff_id = public.staff.id (Otto), route_order = vuororoolien prioriteetti, grace_minutes = juuri päättyneet vuorot, dedup_seconds = sama MAC+pid, repeat_cooldown_seconds = uusi painallus ilman uutta soittoa.'
 where key = 'call_button.config';

create or replace function booking._call_button_route(p_at timestamptz default now())
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_cfg jsonb := booking._setting('call_button.config', '{}'::jsonb);
  v_order jsonb := coalesce(v_cfg -> 'route_order', '["heater","reception","therapist"]'::jsonb);
  v_grace int := coalesce((v_cfg ->> 'grace_minutes')::int, 30);
  v_fallback uuid := nullif(v_cfg ->> 'fallback_staff_id', '')::uuid;
  v_at timestamptz := coalesce(p_at, now());
  v_now jsonb;
  v_grace_rows jsonb;
  v_fb jsonb;
  v_chain jsonb := '[]'::jsonb;
  v_primary jsonb;
  v_open text[];
  r jsonb;
begin
  -- käynnissä olevat vuorot
  select coalesce(jsonb_agg(x.j order by x.prio, x.starts_at, x.name), '[]'::jsonb)
    into v_now
    from (
      select jsonb_build_object(
               'staff_id', s.id, 'name', s.name, 'role', w.role_type, 'shift_id', w.id,
               'shift_start', to_char(w.starts_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
               'shift_end', to_char(w.ends_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
               'source', 'on_shift', 'callable', s.phone_e164 is not null and btrim(s.phone_e164) <> '') j,
             o.ord prio, w.starts_at, s.name
        from public.work_shifts w
        join jsonb_array_elements_text(v_order) with ordinality o(role, ord) on o.role = w.role_type
        join public.shift_assignments a on a.shift_id = w.id and a.status = 'assigned'
        join public.staff s on s.id = a.staff_id and s.active
       where w.status = 'active' and w.cancelled_at is null
         and w.starts_at <= v_at and w.ends_at > v_at
    ) x;

  -- käynnissä olevat vuorot ilman tekijää (tieto reitityksen selitykseen)
  select array_agg(distinct w.role_type) into v_open
    from public.work_shifts w
   where w.status = 'active' and w.cancelled_at is null
     and w.starts_at <= v_at and w.ends_at > v_at
     and not exists (select 1 from public.shift_assignments a join public.staff s on s.id = a.staff_id and s.active
                      where a.shift_id = w.id and a.status = 'assigned');

  -- juuri päättyneet vuorot (vain jos käynnissä olevista ei löydy soitettavaa)
  select coalesce(jsonb_agg(x.j order by x.ends_at desc, x.prio, x.name), '[]'::jsonb)
    into v_grace_rows
    from (
      select jsonb_build_object(
               'staff_id', s.id, 'name', s.name, 'role', w.role_type, 'shift_id', w.id,
               'shift_start', to_char(w.starts_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
               'shift_end', to_char(w.ends_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
               'source', 'grace', 'callable', s.phone_e164 is not null and btrim(s.phone_e164) <> '') j,
             o.ord prio, w.ends_at, s.name
        from public.work_shifts w
        join jsonb_array_elements_text(v_order) with ordinality o(role, ord) on o.role = w.role_type
        join public.shift_assignments a on a.shift_id = w.id and a.status = 'assigned'
        join public.staff s on s.id = a.staff_id and s.active
       where w.status = 'active' and w.cancelled_at is null
         and v_grace > 0
         and w.ends_at <= v_at and w.ends_at > v_at - make_interval(mins => v_grace)
    ) x;

  -- ketju: on_shift (+ grace jos on_shift ei sisällä soitettavaa), sama henkilö vain kerran
  for r in select e from jsonb_array_elements(v_now) e
           union all
           select e from jsonb_array_elements(v_grace_rows) e
            where not exists (select 1 from jsonb_array_elements(v_now) n where (n ->> 'callable')::boolean)
  loop
    if not exists (select 1 from jsonb_array_elements(v_chain) c where c ->> 'staff_id' = r ->> 'staff_id') then
      v_chain := v_chain || jsonb_build_array(r);
    end if;
  end loop;

  if v_fallback is not null then
    select jsonb_build_object('staff_id', s.id, 'name', s.name, 'role', 'fallback', 'shift_id', null,
                              'source', 'fallback', 'callable', s.phone_e164 is not null and btrim(s.phone_e164) <> '')
      into v_fb
      from public.staff s where s.id = v_fallback and s.active;
    if v_fb is not null and not exists (select 1 from jsonb_array_elements(v_chain) c where c ->> 'staff_id' = v_fb ->> 'staff_id') then
      v_chain := v_chain || jsonb_build_array(v_fb);
    end if;
  end if;

  select c into v_primary from jsonb_array_elements(v_chain) with ordinality t(c, n)
   where (c ->> 'callable')::boolean order by n limit 1;

  return jsonb_build_object(
    'at', to_char(v_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI:SS'),
    'primary', v_primary,
    'chain', v_chain,
    'unstaffed_roles', to_jsonb(coalesce(v_open, '{}'::text[])),
    'fallback_configured', v_fallback is not null
  );
end
$function$;

create or replace function booking.svc_call_button_press(p_mac text, p_pid integer, p_gateway text, p_event text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_cfg jsonb := booking._setting('call_button.config', '{}'::jsonb);
  v_enabled boolean := coalesce((booking._setting('call_button_enabled', 'false'::jsonb))::text = 'true', false);
  v_dedup int := coalesce((v_cfg ->> 'dedup_seconds')::int, 15);
  v_cool int := coalesce((v_cfg ->> 'repeat_cooldown_seconds')::int, 120);
  v_unk int := coalesce((v_cfg ->> 'unknown_log_minutes')::int, 10);
  v_events jsonb := coalesce(v_cfg -> 'trigger_events', '["single_push","double_push","triple_push","long_push"]'::jsonb);
  v_tpl text := coalesce(v_cfg ->> 'message_template', 'Hälytys: asiakas pyytää apua, paikka %s.');
  v_mac text := lower(btrim(coalesce(p_mac, '')));
  v_gw text := nullif(left(btrim(coalesce(p_gateway, '')), 100), '');
  v_event text := nullif(lower(left(btrim(coalesce(p_event, '')), 40)), '');
  d booking.call_button_devices;
  v_prev booking.call_button_presses;
  v_route jsonb;
  v_primary jsonb;
  v_phone text;
  v_mask text;
  v_status text;
  v_call boolean := false;
  v_id bigint;
  v_detail text;
  v_msg text;
begin
  begin
    if v_mac !~ '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' then
      perform booking._err('invalid_mac', 'p_mac muodossa aa:bb:cc:dd:ee:ff');
    end if;
    if p_pid is not null and (p_pid < 0 or p_pid > 65535) then
      perform booking._err('invalid_pid', 'p_pid 0–65535');
    end if;

    -- sama MAC sarjoittain (kaksi vastaanotinta voi lähettää saman painalluksen yhtä aikaa)
    perform pg_advisory_xact_lock(hashtext('call_button:' || v_mac));

    select * into d from booking.call_button_devices where mac = v_mac;

    -- tuntematon laite: kirjataan harvakseltaan (MACin löytämiseksi), ei soittoa
    if d.id is null or not d.active then
      select * into v_prev from booking.call_button_presses
       where mac = v_mac and call_status = 'unknown_device'
         and pressed_at > now() - make_interval(mins => v_unk)
       order by pressed_at desc limit 1;
      if v_prev.id is not null then
        update booking.call_button_presses
           set dedup_count = dedup_count + 1,
               dedup_gateways = case when v_gw is null or v_gw = any(dedup_gateways) then dedup_gateways else dedup_gateways || v_gw end,
               updated_at = now()
         where id = v_prev.id;
        v_id := v_prev.id;
      else
        insert into booking.call_button_presses(device_id, mac, gateway, pid, event, call_status, error)
        values (d.id, v_mac, v_gw, p_pid, v_event, 'unknown_device',
                case when d.id is null then 'MAC ei ole call_button_devices-taulussa' else 'laite ei ole aktiivinen' end)
        returning id into v_id;
        insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
        values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'call_button_presses', v_id::text,
                'CALL_BUTTON_UNKNOWN', null,
                jsonb_build_object('mac', v_mac, 'gateway', v_gw, 'pid', p_pid, 'event', v_event));
      end if;
      return jsonb_build_object('ok', false, 'code', 'unknown_device',
                                'message', 'Nappia ei ole rekisteröity tai se ei ole aktiivinen', 'press_id', v_id, 'call', false);
    end if;

    -- dedup: sama MAC + pid lyhyessä ikkunassa (toinen vastaanotin)
    if p_pid is not null then
      select * into v_prev from booking.call_button_presses
       where mac = v_mac and pid = p_pid
         and pressed_at > now() - make_interval(secs => v_dedup)
       order by pressed_at desc limit 1;
      if v_prev.id is not null then
        update booking.call_button_presses
           set dedup_count = dedup_count + 1,
               dedup_gateways = case when v_gw is null or v_gw = any(dedup_gateways) or v_gw = gateway
                                     then dedup_gateways else dedup_gateways || v_gw end,
               updated_at = now()
         where id = v_prev.id;
        return jsonb_build_object('ok', true, 'duplicate', true, 'call', false, 'press_id', v_prev.id,
                                  'place_name', d.place_name, 'call_status', v_prev.call_status);
      end if;
    end if;

    v_route := booking._call_button_route(now());
    v_primary := v_route -> 'primary';

    if v_event is not null and not (v_events ? v_event) then
      v_status := 'ignored';
    else
      -- uusi painallus kesken olevan hälytyksen aikana: kirjataan, ei uutta soittoa
      select * into v_prev from booking.call_button_presses
       where device_id = d.id and repeat_of is null
         and call_status in ('pending','calling','answered','no_answer','busy','failed','completed')
         and pressed_at > now() - make_interval(secs => v_cool)
       order by pressed_at desc limit 1;
      if v_prev.id is not null then
        v_status := 'repeat';
      elsif v_primary is null then
        v_status := 'no_recipient';
      elsif not v_enabled then
        v_status := 'disabled';
      else
        v_status := 'pending';
        v_call := true;
      end if;
    end if;

    if v_primary is not null then
      select s.phone_e164 into v_phone from public.staff s where s.id = (v_primary ->> 'staff_id')::uuid;
      v_mask := case when v_phone is null then null
                     else left(v_phone, 4) || '…' || right(v_phone, 2) end;
    end if;

    insert into booking.call_button_presses(device_id, mac, gateway, pid, event, routed_staff_id, routed_role,
                                            routed_shift_id, phone_masked, chain, attempt_no, call_status, repeat_of)
    values (d.id, v_mac, v_gw, p_pid, v_event,
            (v_primary ->> 'staff_id')::uuid, v_primary ->> 'role', nullif(v_primary ->> 'shift_id', '')::uuid,
            v_mask, coalesce(v_route -> 'chain', '[]'::jsonb), case when v_call then 1 else 0 end, v_status,
            case when v_status = 'repeat' then v_prev.id end)
    returning id into v_id;

    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'call_button_presses', v_id::text,
            'CALL_BUTTON_PRESS', null,
            jsonb_build_object('device', d.name, 'mac', v_mac, 'gateway', v_gw, 'pid', p_pid, 'event', v_event,
                               'call_status', v_status, 'call', v_call, 'enabled', v_enabled,
                               'routed_staff_id', v_primary ->> 'staff_id', 'routed_role', v_primary ->> 'role',
                               'phone_masked', v_mask, 'repeat_of', case when v_status = 'repeat' then v_prev.id end,
                               'unstaffed_roles', v_route -> 'unstaffed_roles'));

    return jsonb_build_object(
      'ok', true,
      'duplicate', false,
      'call', v_call,
      'call_status', v_status,
      'press_id', v_id,
      'repeat_of', case when v_status = 'repeat' then v_prev.id end,
      'device', d.name,
      'place_name', d.place_name,
      'message', format(v_tpl, d.place_name),
      'staff_id', v_primary ->> 'staff_id',
      'staff_name', v_primary ->> 'name',
      'role', v_primary ->> 'role',
      'phone', case when v_call then v_phone end,
      'phone_masked', v_mask,
      'attempt_no', case when v_call then 1 else 0 end
    );
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(nullif(v_detail, ''), 'error'), 'message', v_msg, 'call', false);
  end;
end
$function$;

create or replace function booking.svc_call_button_result(p_press_id bigint, p_status text, p_provider_call_id text, p_error text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_cfg jsonb := booking._setting('call_button.config', '{}'::jsonb);
  v_enabled boolean := coalesce((booking._setting('call_button_enabled', 'false'::jsonb))::text = 'true', false);
  v_max int := coalesce((v_cfg ->> 'max_attempts')::int, 3);
  v_escalate boolean := coalesce((v_cfg ->> 'escalate')::boolean, true);
  v_tpl text := coalesce(v_cfg ->> 'message_template', 'Hälytys: asiakas pyytää apua, paikka %s.');
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_pcid text := nullif(left(btrim(coalesce(p_provider_call_id, '')), 200), '');
  v_err text := nullif(left(btrim(coalesce(p_error, '')), 1000), '');
  p booking.call_button_presses;
  v_place text;
  v_next jsonb;
  v_phone text;
  v_mask text;
  v_detail text;
  v_msg text;
begin
  begin
    if v_status not in ('calling','answered','no_answer','busy','failed','completed') then
      perform booking._err('invalid_status', 'p_status: calling, answered, no_answer, busy, failed tai completed');
    end if;
    select * into p from booking.call_button_presses where id = p_press_id for update;
    if p.id is null then perform booking._err('not_found', 'Painallusta ei löydy'); end if;
    if p.attempt_no < 1 then perform booking._err('not_calling', 'Tälle painallukselle ei ole soittoa (' || p.call_status || ')'); end if;
    select place_name into v_place from booking.call_button_devices where id = p.device_id;

    -- vanha/myöhässä tullut tulos (eri soitto-id kuin nykyisellä yrityksellä) kirjataan vain historiaan
    if v_pcid is not null and v_pcid is distinct from p.provider_call_id
       and exists (select 1 from jsonb_array_elements(p.attempts) a
                    where a ->> 'provider_call_id' = v_pcid and (a ->> 'attempt_no')::int < p.attempt_no) then
      update booking.call_button_presses
         set attempts = attempts || jsonb_build_array(jsonb_build_object('at', now(), 'status', v_status,
                          'provider_call_id', v_pcid, 'error', v_err, 'late', true)),
             updated_at = now()
       where id = p.id;
      return jsonb_build_object('ok', true, 'press_id', p.id, 'call_status', p.call_status, 'late', true, 'next', null);
    end if;

    update booking.call_button_presses
       set call_status = v_status,
           provider_call_id = coalesce(v_pcid, provider_call_id),
           error = case when v_err is not null then v_err when v_status in ('answered','completed') then null else error end,
           attempts = attempts || jsonb_build_array(jsonb_build_object(
                        'at', now(), 'attempt_no', attempt_no, 'staff_id', routed_staff_id, 'role', routed_role,
                        'status', v_status, 'provider_call_id', coalesce(v_pcid, provider_call_id), 'error', v_err)),
           updated_at = now()
     where id = p.id
     returning * into p;

    -- eskalointi: seuraava soitettava ketjusta, jolle ei vielä soitettu
    if v_status in ('no_answer','busy','failed') and v_escalate and v_enabled and p.attempt_no < v_max then
      select c into v_next
        from jsonb_array_elements(p.chain) with ordinality t(c, n)
       where (c ->> 'callable')::boolean
         and (c ->> 'staff_id') <> coalesce(p.routed_staff_id::text, '')
         and not exists (select 1 from jsonb_array_elements(p.attempts) a where a ->> 'staff_id' = c ->> 'staff_id')
       order by n limit 1;
      if v_next is not null then
        select s.phone_e164 into v_phone from public.staff s where s.id = (v_next ->> 'staff_id')::uuid and s.active;
        if v_phone is null then
          v_next := null;
        else
          v_mask := left(v_phone, 4) || '…' || right(v_phone, 2);
          update booking.call_button_presses
             set attempt_no = attempt_no + 1,
                 routed_staff_id = (v_next ->> 'staff_id')::uuid,
                 routed_role = v_next ->> 'role',
                 routed_shift_id = nullif(v_next ->> 'shift_id', '')::uuid,
                 phone_masked = v_mask,
                 provider_call_id = null,
                 call_status = 'pending',
                 updated_at = now()
           where id = p.id
           returning * into p;
        end if;
      end if;
    end if;

    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'call_button_presses', p.id::text,
            'CALL_BUTTON_RESULT', null,
            jsonb_build_object('status', v_status, 'provider_call_id', v_pcid, 'error', v_err,
                               'attempt_no', p.attempt_no, 'call_status', p.call_status,
                               'next_staff_id', v_next ->> 'staff_id', 'next_role', v_next ->> 'role',
                               'next_phone_masked', v_mask));

    return jsonb_build_object(
      'ok', true,
      'press_id', p.id,
      'call_status', p.call_status,
      'attempt_no', p.attempt_no,
      'next', case when v_next is null then null else jsonb_build_object(
                'staff_id', v_next ->> 'staff_id', 'staff_name', v_next ->> 'name', 'role', v_next ->> 'role',
                'phone', v_phone, 'phone_masked', v_mask, 'attempt_no', p.attempt_no,
                'place_name', v_place, 'message', format(v_tpl, v_place)) end
    );
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(nullif(v_detail, ''), 'error'), 'message', v_msg);
  end;
end
$function$;

