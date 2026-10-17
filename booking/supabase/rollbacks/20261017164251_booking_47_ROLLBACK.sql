-- ============================================================
-- booking_47_ROLLBACK: kumppanilahjakorttien lunastuspyynnöt pois, takaisin booking_46-tilaan.
-- HUOM: poistaa taulun voucher_claims (pyynnöt menetetään). Jo kirjatut partner_voucher-maksut (payments) jäävät; ne eivät ole enää poissuljettuja kirjanpidosta
-- (ennen booking_47:ää partner_voucher-maksu tuotti kuitin kuten muut käsin kirjatut maksutavat). Aja vain jos pyyntöjä ei ole käytetty tai ne on käsitelty.
-- ============================================================
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'booking_voucher_claims_housekeeping';
  end if;
exception when others then raise notice 'cron-poisto ohitettu: %', sqlerrm;
end $$;
drop trigger if exists orders_vc_close on booking.orders;
drop function if exists booking._vc_orders_trg();
drop function if exists booking.voucher_claims_housekeeping();
drop function if exists booking.svc_notify_voucher_claim_problems();
drop function if exists booking.svc_resolve_voucher_claim(bigint, text, text, text, numeric, text);
drop function if exists booking.svc_list_open_voucher_claims(integer, boolean);
drop function if exists booking.admin_voucher_claim_stats(date, date);
drop function if exists booking.admin_resolve_voucher_claim(bigint, text, text, text, numeric, text);
drop function if exists booking.admin_get_voucher_claim(bigint);
drop function if exists booking.admin_list_voucher_claims(text, text, integer, integer);
drop function if exists booking.public_get_order_voucher_claims(uuid);
drop function if exists booking.public_submit_voucher_claim(uuid, text, text, bigint);
drop function if exists booking.public_resolve_gift_code(text);
drop function if exists booking._vc_resolve(bigint, text, text, text, numeric, text, text);
drop function if exists booking._vc_notify_problem(bigint);
drop function if exists booking._vc_pay(booking.orders, booking.voucher_claims, numeric);
drop function if exists booking._vc_json(booking.voucher_claims, boolean);
drop function if exists booking._vc_extend_hold(bigint, timestamptz);
drop function if exists booking._vc_hold_hours();
drop function if exists booking._vc_source_label(text);
drop function if exists booking._vc_guess(text);
drop function if exists booking._vc_sources();
drop function if exists booking._vc_mask(text);
drop table if exists booking.voucher_claims;
drop function if exists booking._vc_audit_trg();
delete from booking.email_outbox where kind in ('voucher_claim_received', 'voucher_claim_problem');
alter table booking.email_outbox drop constraint email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient'));
CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ids bigint[]; v_site text := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op text := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
        v_pp text := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/'); v_res jsonb;
begin
  update booking.email_outbox set status = 'pending', locked_at = null where status = 'sending' and locked_at < now() - interval '10 minutes';
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from booking.email_outbox where status in ('pending','failed') and next_attempt_at <= now() order by id limit greatest(least(coalesce(p_limit, 20), 50), 1) for update skip locked) q;
  update booking.email_outbox set status = 'sending', locked_at = now(), attempts = attempts + 1 where id = any (v_ids);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'kind', e.kind, 'locale', e.locale, 'attempts', e.attempts, 'max_attempts', e.max_attempts, 'to', coalesce(nullif(e.payload ->> 'to_email', ''), c.email), 'to_name', coalesce(nullif(e.payload ->> 'to_name', ''), c.name),
      'order', case when o.id is null or e.kind = 'gift_card_recipient' then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status) order by r.starts_at)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb)) end,
      'gift_cards', case when e.kind like 'gift_card\_%' then (select coalesce(jsonb_agg(jsonb_build_object('public_token', g.public_token, 'package_code', g.package_code, 'package_name', pk.name, 'package_name_en', pk.name_en,
            'kind', g.kind, 'amount', g.initial_amount, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'greeting', g.greeting, 'buyer_name', g.buyer_name, 'persons', pk.persons,
            'locale', g.locale, 'status', g.status, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'),
            'deliver_at', booking._gc_deliver_ts(g.deliver_on, g.deliver_time), 'delivered_at', g.delivered_at,
            'recipient_email', case when e.kind = 'gift_card_buyer' then g.recipient_email end, 'cover_message', case when e.kind = 'gift_card_recipient' then g.cover_message end) order by g.id), '[]'::jsonb)
          from booking.gift_cards g left join booking.gift_card_packages pk on pk.code = g.package_code
         where g.id in (select (x)::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'card_ids', '[]'::jsonb)) x)) end,
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
   where e.id = any (v_ids);
  return v_res;
end $function$;
CREATE OR REPLACE FUNCTION booking._acct_excluded(p_order_id bigint, p_payment_id bigint DEFAULT NULL::bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select booking._is_johku_row(p_order_id, p_payment_id)
      or coalesce((select true from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id
                    where p.id = p_payment_id and (g.accounting_origin = 'johku' or g.vat_treatment = 'at_sale')), false)
$function$;
delete from booking.settings where key in ('voucher_claims.enabled', 'voucher_claims.problem_emails_enabled', 'voucher_claims.partner_voucher_accounted', 'voucher_claims.hold_hours', 'voucher_claims.max_per_order', 'voucher_claims.max_attempts');
