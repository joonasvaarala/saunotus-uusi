-- booking_93_invoice_email_dispatch
-- Sähköpostijono: kind invoice_pdf. email_outbox_claim on booking_102 sellaisenaan plus invoice-lohko.
-- Lajitarkistus pitää business_quote_ack / business_quote_notify ja lisää invoice_pdf.
-- Rollback: rollbacks/20261019011700_booking_93_ROLLBACK.sql

set local lock_timeout = '5s';

alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem', 'business_quote_ack', 'business_quote_notify', 'invoice_pdf'));

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
      'reply_to', case when e.kind = 'business_quote_notify' then coalesce(nullif(btrim(e.payload ->> 'reply_to'), ''), nullif(btrim(q.email), '')) end,
      'quote', case when e.kind in ('business_quote_ack', 'business_quote_notify') then jsonb_strip_nulls(jsonb_build_object(
          'id', coalesce(q.id, case when e.payload ->> 'quote_id' ~ '^[0-9]+$' then (e.payload ->> 'quote_id')::bigint end),
          'company_name', coalesce(nullif(btrim(e.payload ->> 'company_name'), ''), q.company_name),
          'contact_name', coalesce(nullif(btrim(e.payload ->> 'contact_name'), ''), q.contact_name),
          'email', coalesce(nullif(btrim(e.payload ->> 'email'), ''), q.email),
          'phone', coalesce(nullif(btrim(e.payload ->> 'phone'), ''), q.phone),
          'persons', coalesce(nullif(e.payload ->> 'persons', '')::int, q.persons),
          'offerings', coalesce(e.payload -> 'offerings', to_jsonb(q.offerings)),
          'offering_other', coalesce(nullif(btrim(e.payload ->> 'offering_other'), ''), q.offering_other),
          'preferred_when', coalesce(nullif(btrim(e.payload ->> 'preferred_when'), ''), q.preferred_when),
          'message', coalesce(nullif(btrim(e.payload ->> 'message'), ''), q.message),
          'locale', coalesce(nullif(btrim(e.payload ->> 'locale'), ''), q.locale),
          'created_at', coalesce(nullif(e.payload ->> 'created_at', ''), to_jsonb(q.created_at) #>> '{}')
        )) end,
      'order', case when o.id is null or e.kind = 'gift_card_recipient' then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status, 'option', booking._option_json(r.product_option_id)) order by r.starts_at)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb)) end,
      'gift_cards', case when e.kind like 'gift_card\_%' then (select coalesce(jsonb_agg(jsonb_build_object('public_token', g.public_token, 'package_code', g.package_code, 'package_name', pk.name, 'package_name_en', pk.name_en,
            'kind', g.kind, 'amount', g.initial_amount, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'greeting', g.greeting, 'buyer_name', g.buyer_name, 'persons', pk.persons,
            'locale', g.locale, 'status', g.status, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'),
            'deliver_at', booking._gc_deliver_ts(g.deliver_on, g.deliver_time), 'delivered_at', g.delivered_at,
            'recipient_email', case when e.kind = 'gift_card_buyer' then g.recipient_email end, 'cover_message', case when e.kind = 'gift_card_recipient' then g.cover_message end) order by g.id), '[]'::jsonb)
          from booking.gift_cards g left join booking.gift_card_packages pk on pk.code = g.package_code
         where g.id in (select (x)::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'card_ids', '[]'::jsonb)) x)) end,
      'voucher_claim', case when e.kind like 'voucher\_claim\_%' then (select jsonb_build_object('claim_id', vc.id, 'status', vc.status, 'source', vc.source, 'code_masked', booking._vc_mask(vc.code), 'problem_code', vc.problem_code,
            'hold_until', vc.hold_until, 'created_at', vc.created_at, 'customer_name', vc.customer_name) from booking.voucher_claims vc where vc.id = (e.payload ->> 'claim_id')::bigint) end,
      'invoice', case when e.kind = 'invoice_pdf' then (select jsonb_build_object('id', inv.id, 'invoice_no', inv.invoice_no, 'public_token', inv.public_token, 'total', inv.total_gross, 'due_date', inv.due_date, 'reference_no', inv.reference_no, 'status', inv.status) from booking.invoices inv where inv.id = nullif(e.payload ->> 'invoice_id', '')::bigint) end,
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
    left join booking.business_quote_requests q
      on e.kind in ('business_quote_ack', 'business_quote_notify')
     and q.id = case when e.payload ->> 'quote_id' ~ '^[0-9]+$' then (e.payload ->> 'quote_id')::bigint end
   where e.id = any (v_ids);
  return v_res;
end $function$;

