-- booking_341_call_button_shift_end
-- Joonas 23.11.2026 t1922u: ei 30 min jälkiaikaa; soitot loppuvat vuoron päättyessä. Poikkeus: vastaanottovuoro,
--   joka päättyy klo 19.00 (Europe/Helsinki), saa soittoja 19.15 asti. 19.15 päättyvä vuoro ei saa lisäaikaa.
-- Joonas 23.11.2026 t1923u: yksi soitto per painallus, ei eskalointia; uusi painallus = aina uusi soitto
--   (120 s toistoraja pois). Vain saman painalluksen dedup (MAC+pid, 15 s) jää.
-- call_button_enabled pysyy false. Ei soittoja, ei lähetyksiä.

update booking.settings
   set value = (value - 'grace_minutes' - 'repeat_cooldown_seconds')
               || jsonb_build_object('max_attempts', 1, 'escalate', false,
                                     'shift_end_extension', jsonb_build_object('role', 'reception', 'end_local', '19:00', 'minutes', 15)),
       description = 'booking_341: hälytysnapin reititys. fallback_staff_id = public.staff.id (Otto), route_order = vuororoolien prioriteetti, soitot vain vuoron aikana (shift_end_extension: 19.00 päättyvä vastaanotto +15 min), dedup_seconds = sama MAC+pid, yksi soitto per painallus.'
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
  v_ext_role text := coalesce(v_cfg #>> '{shift_end_extension,role}', 'reception');
  v_ext_end time := coalesce((v_cfg #>> '{shift_end_extension,end_local}')::time, time '19:00');
  v_ext_min int := coalesce((v_cfg #>> '{shift_end_extension,minutes}')::int, 0);
  v_fallback uuid := nullif(v_cfg ->> 'fallback_staff_id', '')::uuid;
  v_at timestamptz := coalesce(p_at, now());
  v_now jsonb;
  v_fb jsonb;
  v_chain jsonb := '[]'::jsonb;
  v_primary jsonb;
  v_open text[];
  r jsonb;
begin
  -- Joonas t1922u: soitot loppuvat vuoron päättyessä. Poikkeus: vastaanottovuoro, joka päättyy klo 19.00
  -- (Europe/Helsinki), saa soittoja vielä 15 min (shift_end_extension). 19.15 päättyvä vuoro ei saa lisäaikaa.
  with s as (
    select w.*,
           case when v_ext_min > 0 and w.role_type = v_ext_role
                     and (w.ends_at at time zone booking._tz())::time = v_ext_end
                then w.ends_at + make_interval(mins => v_ext_min) else w.ends_at end as eff_end
      from public.work_shifts w
     where w.status = 'active' and w.cancelled_at is null
       and w.starts_at <= v_at and w.ends_at > v_at - interval '1 day'
  ), live as (
    select * from s where s.starts_at <= v_at and s.eff_end > v_at
  )
  select coalesce((select jsonb_agg(x.j order by x.prio, x.starts_at, x.name)
                     from (select jsonb_build_object(
                                    'staff_id', st.id, 'name', st.name, 'role', l.role_type, 'shift_id', l.id,
                                    'shift_start', to_char(l.starts_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
                                    'shift_end', to_char(l.ends_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
                                    'source', case when l.ends_at <= v_at then 'extension' else 'on_shift' end,
                                    'callable', st.phone_e164 is not null and btrim(st.phone_e164) <> '') j,
                                  o.ord prio, l.starts_at, st.name
                             from live l
                             join jsonb_array_elements_text(v_order) with ordinality o(role, ord) on o.role = l.role_type
                             join public.shift_assignments a on a.shift_id = l.id and a.status = 'assigned'
                             join public.staff st on st.id = a.staff_id and st.active) x), '[]'::jsonb),
         (select array_agg(distinct l.role_type) from live l
           where not exists (select 1 from public.shift_assignments a join public.staff st on st.id = a.staff_id and st.active
                              where a.shift_id = l.id and a.status = 'assigned'))
    into v_now, v_open;

  for r in select e from jsonb_array_elements(v_now) with ordinality t(e, n) order by n
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
      -- Joonas t1923u: jokainen uusi painallus = uusi soitto (vain saman painalluksen MAC+pid-dedup)
      if v_primary is null then
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
            null::bigint)
    returning id into v_id;

    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'call_button_presses', v_id::text,
            'CALL_BUTTON_PRESS', null,
            jsonb_build_object('device', d.name, 'mac', v_mac, 'gateway', v_gw, 'pid', p_pid, 'event', v_event,
                               'call_status', v_status, 'call', v_call, 'enabled', v_enabled,
                               'routed_staff_id', v_primary ->> 'staff_id', 'routed_role', v_primary ->> 'role',
                               'phone_masked', v_mask, 'repeat_of', null::bigint,
                               'unstaffed_roles', v_route -> 'unstaffed_roles'));

    return jsonb_build_object(
      'ok', true,
      'duplicate', false,
      'call', v_call,
      'call_status', v_status,
      'press_id', v_id,
      'repeat_of', null::bigint,
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
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_pcid text := nullif(left(btrim(coalesce(p_provider_call_id, '')), 200), '');
  v_err text := nullif(left(btrim(coalesce(p_error, '')), 1000), '');
  p booking.call_button_presses;
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

    -- vanha/myöhässä tullut tulos (eri soitto-id kuin nykyisellä yrityksellä) kirjataan vain historiaan
    if v_pcid is not null and v_pcid is distinct from p.provider_call_id
       and exists (select 1 from jsonb_array_elements(p.attempts) a
                    where a ->> 'provider_call_id' = v_pcid and (a ->> 'attempt_no')::int < p.attempt_no) then
      update booking.call_button_presses
         set attempts = attempts || jsonb_build_array(jsonb_build_object('at', now(), 'status', v_status,
                          'provider_call_id', v_pcid, 'error', v_err, 'late', true)),
             updated_at = now()
       where id = p.id;
      return jsonb_build_object('ok', true, 'press_id', p.id, 'call_status', p.call_status, 'late', true);
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

    -- Joonas t1923u: yksi soitto per painallus, ei eskalointia.

    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'call_button_presses', p.id::text,
            'CALL_BUTTON_RESULT', null,
            jsonb_build_object('status', v_status, 'provider_call_id', v_pcid, 'error', v_err,
                               'attempt_no', p.attempt_no, 'call_status', p.call_status));

    return jsonb_build_object(
      'ok', true,
      'press_id', p.id,
      'call_status', p.call_status,
      'attempt_no', p.attempt_no
    );
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(nullif(v_detail, ''), 'error'), 'message', v_msg);
  end;
end
$function$;

revoke all on function booking._call_button_route(timestamptz) from public, anon, authenticated;
revoke all on function booking.svc_call_button_press(text, integer, text, text) from public, anon, authenticated;
revoke all on function booking.svc_call_button_result(bigint, text, text, text) from public, anon, authenticated;
grant execute on function booking._call_button_route(timestamptz) to service_role;
grant execute on function booking.svc_call_button_press(text, integer, text, text) to service_role;
grant execute on function booking.svc_call_button_result(bigint, text, text, text) to service_role;
