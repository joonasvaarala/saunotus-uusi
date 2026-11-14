-- booking_292: asiakkaan peruutus- ja siirtopyynnöt hälytysjonossa Asiakaspalvelulle (Joonas 13.11.2026 klo 12.53 Työvuoro-Tapion kautta)
CREATE OR REPLACE FUNCTION booking._notify_staff(p_topic text, p_req_id bigint, p_payload jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into booking.notifications_outbox(topic, target, ref_table, ref_id, dedupe_key, payload)
  values (p_topic, 'asiakaspalvelu', 'order_requests', p_req_id, p_topic || ':' || p_req_id, coalesce(p_payload, '{}'::jsonb)) on conflict (dedupe_key) do nothing
$function$;
comment on function booking._notify_staff(text,bigint,jsonb) is 'Asiakkaan pyynnöt (order_requests: peruutus, siirto) -> notifications_outbox target asiakaspalvelu. Henkilökunnan hälytykset (voucher_claim_problem, therapist_missing) eri reittiä target tapio.';
