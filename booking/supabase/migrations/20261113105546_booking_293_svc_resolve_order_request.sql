-- booking_293: Asiakaspalvelu kuittaa asiakkaan pyynnön (order_requests) käsitellyksi. Vain tilan merkintä:
-- ei peru varauksia, ei koske maksuihin eikä lähetä viestejä (toimet tehdään erikseen olemassa olevilla svc-toiminnoilla).
CREATE OR REPLACE FUNCTION booking.svc_resolve_order_request(p_request_id bigint, p_resolution text, p_note text, p_actor text DEFAULT 'Asiakaspalvelu')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q booking.order_requests; v_status text;
begin
  if p_resolution is null or p_resolution not in ('handled', 'rejected') then perform booking._err('invalid_param', 'p_resolution: handled|rejected'); end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then perform booking._err('invalid_param', 'p_note pakollinen (mitä tehtiin)'); end if;
  if nullif(btrim(coalesce(p_actor, '')), '') is null then perform booking._err('invalid_param', 'p_actor pakollinen'); end if;
  select * into q from booking.order_requests where id = p_request_id for update;
  if not found then perform booking._err('not_found', 'Pyyntöä ei löydy'); end if;
  if q.status <> 'open' then perform booking._err('request_closed', 'Pyyntö on jo käsitelty'); end if;
  v_status := p_resolution;
  update booking.order_requests
     set status = v_status, handled_at = now(),
         note = left(btrim(p_note) || ' [' || btrim(p_actor) || ']', 2000)
   where id = q.id;
  return jsonb_build_object('ok', true, 'request_id', q.id, 'order_id', q.order_id, 'kind', q.kind, 'status', v_status,
    'order_no', (select order_no from booking.orders where id = q.order_id));
end $function$;
revoke all on function booking.svc_resolve_order_request(bigint,text,text,text) from public, anon, authenticated;
grant execute on function booking.svc_resolve_order_request(bigint,text,text,text) to service_role;
comment on function booking.svc_resolve_order_request(bigint,text,text,text) is 'Asiakaspalvelu: merkitsee order_requests-pyynnön käsitellyksi (handled) tai hylätyksi (rejected). Ei sivuvaikutuksia. booking_293, 13.11.2026.';
