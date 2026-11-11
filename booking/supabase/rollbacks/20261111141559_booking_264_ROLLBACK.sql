-- booking_264 full rollback: ONLY before first use. Never unarchive or hide review data implicitly.
-- Entire file MUST run in one transaction. Gate waits for in-flight archive before checking data.
set local lock_timeout = '5s';
select pg_advisory_xact_lock(hashtextextended('booking:archive:264',0));
do $data$
begin
  if exists (select 1 from information_schema.columns where table_schema='booking' and table_name='email_outbox' and column_name='archive_claim_uncertain') then
    if exists (select 1 from booking.email_outbox where archive_claim_uncertain) then
      raise exception 'rollback booking_264: epävarmaa lähetyshistoriaa on; forward-fix vaaditaan, merkitystä ei saa hukata';
    end if;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='booking' and table_name='orders' and column_name='archived_at') then
    if exists (select 1 from booking.orders where archived_at is not null) then
      raise exception 'rollback booking_264: arkistoituja tilauksia on; forward-fix vaaditaan, ei muutoksia';
    end if;
  end if;
  if to_regclass('booking.archived_late_payment_acks') is not null then
    if exists (select 1 from booking.archived_late_payment_acks) then
      raise exception 'rollback booking_264: käsittelykuittauksia on; ei muutoksia';
    end if;
  end if;
end $data$;
-- Only unused installation reaches DDL. Drain app/worker traffic before schema rollback.
lock table booking.orders in access exclusive mode;
lock table booking.email_outbox in access exclusive mode;
do $lock_ack$ begin
  if to_regclass('booking.archived_late_payment_acks') is not null then
    lock table booking.archived_late_payment_acks in access exclusive mode;
  end if;
end $lock_ack$;
-- Recheck under table locks too: fail closed even for direct administrative SQL outside the archive protocol.
do $data_locked$
begin
  if exists (select 1 from information_schema.columns where table_schema='booking' and table_name='email_outbox' and column_name='archive_claim_uncertain') then
    if exists (select 1 from booking.email_outbox where archive_claim_uncertain) then
      raise exception 'rollback booking_264: epävarmaa lähetyshistoriaa on; forward-fix vaaditaan, merkitystä ei saa hukata';
    end if;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='booking' and table_name='orders' and column_name='archived_at') then
    if exists (select 1 from booking.orders where archived_at is not null) then
      raise exception 'rollback booking_264: arkistoituja tilauksia on; forward-fix vaaditaan, ei muutoksia';
    end if;
  end if;
  if to_regclass('booking.archived_late_payment_acks') is not null then
    if exists (select 1 from booking.archived_late_payment_acks) then
      raise exception 'rollback booking_264: käsittelykuittauksia on; ei muutoksia';
    end if;
  end if;
end $data_locked$;
do $pre$
declare
  r record; v text; bad text := '';
begin
  for r in select * from (values
      ('booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])', array['c50fa63ab94d0046d6a3ccf85a005f0b', '7a546ff24b41e6ffe7f22e3a43a282fc'], false),
      ('booking.email_outbox_claim_base_132(integer)',array['0b10986533285645d8592449a90a1e0c','c865d1b3d8d6620ff5935c077b7e16a2'],false),
      ('booking.email_outbox_claim_base_146(integer)',array['5bb547fa6a5f9e715ebbb39e6b479d3e'],false),
      ('booking.email_outbox_claim_base_215(integer)',array['2c76d9c30a28f78e8bb84cce0ff61d77'],false),
      ('booking.email_outbox_mark(bigint,text,text,text)',array['2ba0222fdfee71942fb09053bd7ea803'],false),
      ('booking.email_outbox_claim(integer)',array['5e8125c1da473685b7a7adbb40966250','e46ae5ebd9fb813a087b7f05c40949b8'],false),
      ('booking.admin_review_list()',array['8c7ddb15580659e9daa3e72f43718f14','fca45e305e1036d462ef28c7473de150'],false),
      ('booking._archived_late_payment_review_rows()',array['035d2f18a860cd62a757187ef3e64a71'],true),
      ('booking.admin_ack_archived_late_payment(bigint,text)',array['f3ad2e3c42ea2178fcf297e5c4bbf2eb'],true),
      ('booking._order_delete_blockers(bigint)', array['21b2feb3e469c6d1cc44cca480657bdb'], true),
      ('booking.admin_order_delete_check(bigint)', array['acbc37244b1975ecd0aa9b02c39707df'], true),
      ('booking.admin_delete_unpaid_order(bigint,text)', array['ba36be22eaadfc8bdef59b089ad5d629'], true),
      ('booking._email_outbox_archived_bi()', array['63515bcb6f2b85f003fc3e3125c37f73'], true)
    ) t(sig, ok, may_be_absent)
  loop
    if to_regprocedure(r.sig) is null then
      if not r.may_be_absent then bad := bad || format(E'\n  %s puuttuu', r.sig); end if;
      continue;
    end if;
    v := md5(pg_get_functiondef(to_regprocedure(r.sig)));
    if not (v = any (r.ok)) then
      bad := bad || format(E'\n  %s md5 %s (odotettu %s)', r.sig, v, array_to_string(r.ok, ' / '));
    end if;
  end loop;
  if exists (select 1 from pg_trigger t where t.tgrelid='booking.email_outbox'::regclass and t.tgname='email_outbox_archived_bi'
      and md5(pg_get_triggerdef(t.oid)||t.tgenabled::text) <> 'e8a1a32402444a91417fd625c6a79478') then
    bad := bad || E'\n  trigger email_outbox_archived_bi määrittely/tila poikkeaa';
  end if;
  if to_regprocedure('booking.admin_delete_unpaid_order(bigint,text)') is not null
     and not exists (select 1 from pg_trigger where tgrelid='booking.email_outbox'::regclass and tgname='email_outbox_archived_bi') then
    bad := bad || E'\n  trigger email_outbox_archived_bi puuttuu';
  end if;
  if to_regprocedure('booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text)') is not null then
    bad := bad || E'\n  admin_list_orders 12 argumentin versio on olemassa (booking_277 puuttuu)';
  end if;
  if bad <> '' then
    raise exception 'rollback booking_264: tuntematon versio, ei muutoksia:%', bad;
  end if;
end $pre$;

CREATE OR REPLACE FUNCTION booking.email_outbox_claim_base_132(p_limit integer DEFAULT 20)
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
          'instructions', case when e.kind = 'order_confirmation' then booking._order_short_instructions(o.id, coalesce(nullif(e.locale, ''), o.locale, 'fi')) else '[]'::jsonb end,
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
      'product_message', case when e.kind = 'product_message' then booking._product_message_mail(e.id) end,
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


CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(
    case when z.item->>'kind' = 'payment_link_reminder' then
      (case when exists (
          select 1 from booking.email_outbox e
          join booking.payments p on p.id = e.payment_id
          join booking.orders o on o.id = e.order_id
         where e.id = (z.item->>'id')::bigint
           and p.status = 'pending' and p.provider <> 'manual' and p.external_source is null and o.external_source is null
           and (p.link_expires_at is null or p.link_expires_at > now()))
        then z.item
        else z.item || jsonb_build_object('payment', (coalesce(z.item->'payment', '{}'::jsonb) - 'link_url'))
       end)
      || coalesce((select jsonb_build_object('payment_reminder', jsonb_build_object(
            'n', e.payload -> 'reminder_no', 'kind', e.payload ->> 'reminder_kind',
            'cancel_if_unpaid', coalesce((e.payload ->> 'cancel_if_unpaid')::boolean, false),
            'due_at', e.payload -> 'due_at'))
          from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    else case when z.item->>'kind' = 'order_confirmation' then
      z.item || coalesce((
        select jsonb_build_object('order', coalesce(z.item->'order', '{}'::jsonb) || jsonb_build_object(
          'deposit', true,
          'training', jsonb_build_object(
            'course_price', tp.course_price, 'addons_total', tp.addons_total, 'total', tp.total,
            'deposit_paid', tp.deposit_paid, 'remaining', tp.remaining, 'addons', tp.addons,
            'segments', tp.segments)))
          from booking.email_outbox e
          join booking.training_participants tp on tp.order_id = e.order_id
         where e.id = (z.item->>'id')::bigint
         order by tp.id limit 1
      ), '{}'::jsonb)
    else z.item end end
  order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_215(p_limit)) with ordinality as z(item, ord);
$function$;

-- admin_list_orders: palautus booking_277-määritelmään (funktiorunko tavu-identtinen 20261111144714_booking_277_admin_list_orders_payment_filters.sql; oikeudet ja kommentti säilyvät CREATE OR REPLACE -lauseessa)
CREATE OR REPLACE FUNCTION booking.admin_list_orders(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_payment_status text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_native boolean DEFAULT NULL::boolean, p_date_field text DEFAULT 'created'::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_sort text DEFAULT 'created_desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_payment_filter text DEFAULT 'paid'::text, p_payment_filters text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_num bigint;
  v_like text;
  v_total int;
  v_rows jsonb;
  v_lim int := coalesce(p_limit, 50);
  v_off int := greatest(coalesce(p_offset, 0), 0);
  v_pf text := coalesce(nullif(btrim(p_payment_filter), ''), 'paid');
  v_pfs text[];
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('created_desc','created_asc','order_no_desc','order_no_asc','total_desc','total_asc','start_desc','start_asc','paid_desc','paid_asc','unpaid_desc') then
    perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if coalesce(p_date_field, 'created') not in ('created','start') then perform booking._err('invalid_param', 'p_date_field: created|start'); end if;
  if v_pf not in ('paid','unpaid','all','refunded','cancelled','invoiced') then
    perform booking._err('invalid_param', 'p_payment_filter: paid|unpaid|all|refunded|cancelled|invoiced'); end if;
  -- booking_277: monivalinta. Ei-tyhjä p_payment_filters ohittaa p_payment_filter-arvon; tilat yhdistetään OR-ehdolla.
  -- NULL tai tyhjä taulukko = vanha käytös (yksi p_payment_filter, oletus paid).
  if p_payment_filters is not null and cardinality(p_payment_filters) > 0 then
    select array_agg(distinct coalesce(btrim(x), '')) into v_pfs from unnest(p_payment_filters) as u(x);
    if exists (select 1 from unnest(v_pfs) as u(x) where x not in ('paid','unpaid','all','refunded','cancelled','invoiced')) then
      perform booking._err('invalid_param', 'p_payment_filters: paid|unpaid|all|refunded|cancelled|invoiced'); end if;
  else
    v_pfs := array[v_pf];
  end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select o.id, o.order_no, o.johku_order_no, o.created_at, o.status, o.payment_status, o.source_channel, (o.external_source is null) as is_native, o.total_gross,
           pp.paid, pp.refunded, pp.pc, pp.lp, rr.fs, rr.le, rr.cnt, rcc.rc,
           inv.id as invoice_id, inv.invoice_no, inv.status as invoice_status, inv.kind as invoice_kind,
           case when o.status in ('cancelled','expired','draft') then 0 else greatest(o.total_gross - (pp.paid - pp.refunded), 0) end as unpaid,
           c.id as cid, c.name as cname, c.company as ccompany, o.customer_kind
      from booking.orders o
      left join booking.customers c on c.id = o.customer_id
      left join lateral (select min(r.starts_at) fs, max(r.ends_at) le, count(*) cnt from booking.reservations r where r.order_id = o.id and r.hidden_at is null) rr on true
      left join lateral (select coalesce(sum(p.amount) filter (where p.status in ('paid','partially_refunded','refunded')), 0) paid, coalesce(sum(p.refunded_amount), 0) refunded,
                                count(*) filter (where p.status in ('paid','partially_refunded','refunded')) pc, max(p.paid_at) lp
                           from booking.payments p where p.order_id = o.id) pp on true
      left join lateral (select count(*) rc from booking.receipts x where x.order_id = o.id) rcc on true
      left join lateral (
        select i.id,
               i.invoice_no,
               case
                 when i.status = 'sent' and i.due_date < (timezone('Europe/Helsinki', now()))::date
                 then 'overdue'
                 else i.status
               end as status,
               i.kind
          from booking.invoices i
         where i.order_id = o.id
         order by case when i.status = 'voided' then 1 else 0 end,
                  i.created_at desc,
                  i.id desc
         limit 1
      ) inv on true
     where (p_status is null or o.status = p_status)
       and (p_payment_status is null or o.payment_status = p_payment_status)
       and (p_source is null or o.source_channel = p_source)
       and (p_native is null or (o.external_source is null) = p_native)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or o.johku_order_no = v_num))
            or (v_num is null and (c.name ilike v_like or c.email ilike v_like or c.phone ilike v_like or c.company ilike v_like)))
       and (p_from is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end >= p_from)
       and (p_to   is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end <= p_to)
       and ('all' = any(v_pfs)
            or ('paid' = any(v_pfs) and o.payment_status in ('paid','partially_refunded')
                and o.status not in ('cancelled','expired')
                and (case when pp.pc > 0 then pp.paid - pp.refunded
                          when o.payment_status in ('paid','partially_refunded') then o.total_gross
                          else 0 end) > 0.004)
            or ('unpaid' = any(v_pfs) and o.payment_status in ('unpaid','pending','failed','partially_paid')
                and o.status not in ('cancelled','expired'))
            or ('refunded' = any(v_pfs) and o.payment_status in ('refunded','partially_refunded'))
            or ('cancelled' = any(v_pfs) and o.status in ('cancelled','expired'))
            or ('invoiced' = any(v_pfs) and o.payment_status = 'invoiced' and o.status not in ('cancelled','expired')))
  ), page as (
    select b.*, row_number() over (order by
        case when p_sort = 'created_asc' then b.created_at end asc, case when p_sort = 'created_desc' then b.created_at end desc,
        case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc,
        case when p_sort = 'total_asc' then b.total_gross end asc, case when p_sort = 'total_desc' then b.total_gross end desc,
        case when p_sort = 'start_asc' then b.fs end asc nulls last, case when p_sort = 'start_desc' then b.fs end desc nulls last,
        case when p_sort = 'paid_asc' then b.lp end asc nulls last, case when p_sort = 'paid_desc' then b.lp end desc nulls last,
        case when p_sort = 'unpaid_desc' then b.unpaid end desc, b.id desc) as rn
      from base b
  )
  select (select count(*) from base),
         coalesce(jsonb_agg(jsonb_build_object('order_id', p.id, 'order_no', p.order_no, 'johku_order_no', p.johku_order_no, 'created_at', p.created_at, 'status', p.status,
           'payment_status', p.payment_status, 'source_channel', p.source_channel, 'is_native', p.is_native, 'total', p.total_gross, 'paid', p.paid, 'refunded', p.refunded,
           'unpaid', p.unpaid, 'customer_id', p.cid, 'customer_name', p.cname, 'customer_company', p.ccompany, 'customer_kind', p.customer_kind, 'first_start', p.fs, 'last_end', p.le,
           'reservation_count', p.cnt, 'payment_count', p.pc, 'last_paid_at', p.lp, 'receipt_count', p.rc,
           'invoice_id', p.invoice_id, 'invoice_no', p.invoice_no, 'invoice_status', p.invoice_status, 'invoice_kind', p.invoice_kind) order by p.rn), '[]'::jsonb)
    into v_total, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_review_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'therapist_conflicts', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', c.reservation_id, 'leg_id', c.leg_id, 'starts_at', c.claim_start, 'ends_at', c.claim_end, 'skill', c.skill) order by c.claim_start)
        from booking.v_claims c where c.role = 'therapist' and not c.is_override and booking._res_active(c.status, c.hold_expires_at) and c.claim_end > now()
         and booking._therapist_slack(c.skill, c.claim_start, c.claim_end, c.persons, c.session_key, c.leg_id, c.reservation_id) < 0), '[]'::jsonb),
    'block_conflicts', coalesce((select jsonb_agg(jsonb_build_object(
            'reservation_id', p.reservation_id, 'leg_id', p.leg_id, 'resource_id', p.resource_id, 'block_id', p.block_id,
            'closure_event_id', p.closure_event_id, 'starts_at', p.claim_start, 'ends_at', p.claim_end,
            'block_reason', p.block_reason, 'closure_reason', p.closure_reason, 'calendar_name', p.calendar_name) order by p.claim_start)
        from booking._block_conflict_pairs() p
       where not exists (
         select 1 from booking.closure_conflict_acks a
          where a.reservation_id = p.reservation_id and a.block_id = p.block_id
            and a.revoked_at is null and a.block_signature = p.block_signature)), '[]'::jsonb),
    'acked_block_conflicts', coalesce((select jsonb_agg(jsonb_build_object(
            'reservation_id', p.reservation_id, 'leg_id', p.leg_id, 'resource_id', p.resource_id, 'block_id', p.block_id,
            'closure_event_id', p.closure_event_id, 'starts_at', p.claim_start, 'ends_at', p.claim_end,
            'block_reason', p.block_reason, 'closure_reason', p.closure_reason, 'calendar_name', p.calendar_name,
            'ack_id', a.id, 'ack_reason', a.ack_reason, 'acked_by_label', a.acked_by_label, 'acked_at', a.acked_at) order by p.claim_start)
        from booking._block_conflict_pairs() p
        join booking.closure_conflict_acks a
          on a.reservation_id = p.reservation_id and a.block_id = p.block_id
         and a.revoked_at is null and a.block_signature = p.block_signature), '[]'::jsonb),
    'overrides', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'reason', r.override_reason, 'starts_at', r.starts_at) order by r.starts_at)
        from booking.reservations r where r.override_reason is not null and r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'orphan_addons', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'starts_at', r.starts_at) order by r.starts_at)
        from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and cardinality(pc.requires_parent_product_ids) > 0
        left join booking.reservations pr on pr.id = r.parent_reservation_id
       where r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at) and r.override_reason is null
         and (pr.id is null or not booking._res_active(pr.status, pr.hold_expires_at))), '[]'::jsonb),
    'missing_therapist', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'product_id', r.product_id,
              'product_name', coalesce(p.name, ''), 'persons', r.persons, 'order_no', o.order_no, 'source', coalesce(r.external_source, 'native'),
              'days_to_start', ((r.starts_at at time zone 'Europe/Helsinki')::date - (now() at time zone 'Europe/Helsinki')::date)) order by r.starts_at)
        from booking.reservations r join booking.orders o on o.id = r.order_id left join kb.products p on p.id = r.product_id
       where r.therapist_missing and r.therapist_exception_at is null and r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at)
         and not exists (select 1 from booking.reservation_legs l where l.reservation_id = r.id and l.role = 'therapist')), '[]'::jsonb));
end $function$;

drop function if exists booking.admin_ack_archived_late_payment(bigint,text);
drop function if exists booking._archived_late_payment_review_rows();
drop table if exists booking.archived_late_payment_acks;
drop trigger if exists email_outbox_archived_bi on booking.email_outbox;
drop function if exists booking._email_outbox_archived_bi();
drop function if exists booking.admin_delete_unpaid_order(bigint, text);
drop function if exists booking.admin_order_delete_check(bigint);
drop function if exists booking._order_delete_blockers(bigint);

drop index if exists booking.orders_archived_264_idx;
drop index if exists booking.audit_late_paid_264_idx;
do $cols$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'orders' and column_name = 'archived_at') then
    if exists (select 1 from booking.orders where archived_at is not null) then
      raise exception 'rollback booking_264: arkistoituja tilauksia on; ei muutoksia';
    end if;
    alter table booking.orders drop constraint if exists orders_archived_cancelled;
    alter table booking.orders drop constraint if exists orders_archive_reason_len;
    alter table booking.orders drop column archived_at, drop column archived_by, drop column archive_reason;
  end if;
end $cols$;

alter table booking.email_outbox drop column if exists archive_claim_uncertain;
notify pgrst, 'reload schema';
