-- ============================================================
-- booking_45_ROLLBACK: lahjakorttien PDF-data/sähköpostitapahtumat pois, takaisin booking_44-tilaan
-- (poistaa gift_card_*-sähköpostirivit email_outboxista; ne eivät ole kirjanpitodataa)
-- ============================================================
drop trigger if exists gift_cards_issue_email on booking.gift_cards;
drop function if exists booking._gc_issue_email_trg();
delete from booking.email_outbox where kind in ('gift_card_buyer', 'gift_card_recipient');
alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change'));
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
      'id', e.id, 'kind', e.kind, 'locale', e.locale, 'attempts', e.attempts, 'max_attempts', e.max_attempts, 'to', c.email, 'to_name', c.name,
      'order', case when o.id is null then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status) order by r.starts_at)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb)) end,
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
   where e.id = any (v_ids);
  return v_res;
end $function$;

create or replace function booking._gc_activate_order(p_order bigint) returns int
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_n int := 0; v_today date := booking._gc_today();
begin
  for g in select * from booking.gift_cards where purchase_order_id = p_order and status = 'pending_payment' order by id for update loop
    update booking.gift_cards set status = 'active', balance = initial_amount, valid_from = v_today, valid_to = (v_today + make_interval(months => g.valid_months))::date,
           activated_at = now(), balance_verified = true, balance_verified_at = now(), balance_source = 'native' where id = g.id;
    insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, created_by, note)
    values (g.id, p_order, g.initial_amount, g.initial_amount, 'purchase', auth.uid(), 'Ostotilaus maksettu');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
create or replace function booking.public_get_gift_card(p_public_token uuid) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_ip text := coalesce(booking._client_ip(), 'unknown');
begin
  if not booking._rate_limit('gcget:' || v_ip, 60, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into g from booking.gift_cards where public_token = p_public_token and p_public_token is not null;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Korttia ei löydy'); end if;
  if g.status not in ('active', 'used', 'expired') then return jsonb_build_object('ok', false, 'code', 'not_ready', 'message', 'Kortti aktivoituu kun tilaus on maksettu'); end if;
  return jsonb_build_object('ok', true, 'code', booking.gift_code_fmt(g.code), 'status', case when g.status = 'active' and g.valid_to < booking._gc_today() then 'expired' else g.status end,
    'kind', g.kind, 'package_code', g.package_code,
    'package', (select jsonb_build_object('name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en, 'persons', p.persons, 'items', p.items)
                  from booking.gift_card_packages p where p.code = g.package_code),
    'initial_amount', g.initial_amount, 'balance', g.balance, 'currency', g.currency, 'valid_from', g.valid_from, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name,
    'greeting', g.greeting, 'buyer_name', g.buyer_name, 'locale', g.locale, 'issued_at', coalesce(g.activated_at, g.created_at), 'source', g.source,
    'seller', booking._seller());
end $$;
drop function if exists booking._gc_enqueue_email(text, bigint, bigint[], text, text, text, text);
drop function if exists booking.svc_get_gift_card_pdf_data(uuid);
update booking.gift_card_packages set items = '[{"label":"Yleinen vuoro","persons":2,"kb_product_id":1}]'::jsonb where code = 'entry_2';
update booking.gift_card_packages set items = '[{"label":"Yleinen vuoro","persons":2,"kb_product_id":1},{"persons":2,"addon_code":"turvenaamio_jalkakylpy"}]'::jsonb where code = 'peat_mask_2';
update booking.gift_card_packages set items = '[{"label":"Yleinen vuoro","persons":2,"kb_product_id":1},{"label":"Saunahoito","persons":2,"kb_product_id":10}]'::jsonb where code = 'sauna_treatment_2';
update booking.gift_card_packages set items = '[{"label":"Yleinen vuoro","persons":2,"kb_product_id":1},{"label":"Saunotus","persons":2,"kb_product_id":11}]'::jsonb where code = 'saunotus_2';
