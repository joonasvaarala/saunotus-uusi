insert into booking.settings(key, value) values ('email.receipt_auto_send', 'false'::jsonb) on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION booking._enqueue_email(p_kind text, p_order_id bigint, p_receipt_id bigint, p_payment_id bigint, p_dedupe text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare v_mode text; v_loc text; v_email text; v_n int; v_skip boolean := false;
begin
  select o.locale, c.email into v_loc, v_email from booking.orders o left join booking.customers c on c.id = o.customer_id where o.id = p_order_id;
  if v_email is null or not booking._valid_email(v_email) then return false; end if;
  select mode into v_mode from booking.integration_config where key = 'resend';
  -- booking_191 (Joonas 26.10 & 28.10.2026): ei erillistä automaattista kuittisähköpostia varauksista; kuitti luodaan silti kirjanpitoon
  if p_kind = 'receipt' and p_dedupe like 'receipt:%'
     and coalesce((select (s.value)::text from booking.settings s where s.key = 'email.receipt_auto_send'), 'false') <> 'true' then
    v_skip := true;
  end if;
  insert into booking.email_outbox(kind, order_id, receipt_id, payment_id, locale, dedupe_key, status, payload, last_error)
  values (p_kind, p_order_id, p_receipt_id, p_payment_id, coalesce(v_loc, 'fi'), p_dedupe,
          case when v_skip or coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end, coalesce(p_payload, '{}'::jsonb),
          case when v_skip then 'receipt_auto_send disabled' else null end)
  on conflict (dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n > 0 and not v_skip;
end $function$;
