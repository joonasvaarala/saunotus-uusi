-- booking_342 ROLLBACK: palauttaa booking_341:n svc_call_button_press ja configin
update booking.call_button_presses set call_status = 'repeat' where call_status = 'buffered';
alter table booking.call_button_presses drop constraint if exists call_button_presses_call_status_check;
alter table booking.call_button_presses add constraint call_button_presses_call_status_check
  check (call_status in ('pending','calling','answered','no_answer','busy','failed','completed',
                         'disabled','no_recipient','repeat','ignored','unknown_device'));
update booking.settings
   set value = (value - 'call_buffer_seconds')
               || jsonb_build_object('trigger_events', jsonb_build_array('single_push','double_push','triple_push','long_push')),
       description = 'booking_341: hälytysnapin reititys. fallback_staff_id = public.staff.id (Otto), route_order = vuororoolien prioriteetti, soitot vain vuoron aikana (shift_end_extension: 19.00 päättyvä vastaanotto +15 min), dedup_seconds = sama MAC+pid, yksi soitto per painallus.'
 where key = 'call_button.config';

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

revoke all on function booking.svc_call_button_press(text, integer, text, text) from public, anon, authenticated;
grant execute on function booking.svc_call_button_press(text, integer, text, text) to service_role;
