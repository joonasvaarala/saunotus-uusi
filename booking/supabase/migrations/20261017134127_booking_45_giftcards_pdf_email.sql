-- booking_45_giftcards_pdf_email (17.10.2026) – lahjakortit vaihe 2: PDF-data, sähköpostitapahtumat, items.label_en
-- 1) gift_card_packages.items: label_en (+ lisäosarivin label/label_en) – additiivinen
-- 2) svc_get_gift_card_pdf_data(token): palvelinpuolen (service_role) kortin sisältö PDF:lle ilman IP-rate limitiä; public_get_gift_card käyttää samaa (rate limit säilyy)
-- 3) email_outbox.kind: gift_card_buyer, gift_card_recipient; email_outbox_claim: to/to_name payloadista, gift_cards-lohko (ei koodeja), recipient-viestissä ei tilausta
-- 4) _gc_enqueue_email + _gc_activate_order (ostajan viesti + saajan viestit kun osto maksettu) + trigger maksuttomalle myönnölle
-- Resend on dry_run/off -> mitään ei lähde; rivit syntyvät 'pending' (dry_run) tai 'skipped' (off) kuten kuittiviesteillä.

-- ---------- 1) items.label_en ----------
update booking.gift_card_packages p set items = coalesce((
  select jsonb_agg(case
      when it ->> 'label' = 'Yleinen vuoro' then it || '{"label_en":"General session"}'::jsonb
      when it ->> 'label' = 'Saunahoito' then it || '{"label_en":"Sauna treatment"}'::jsonb
      when it ->> 'label' = 'Saunotus' then it || '{"label_en":"Ritual sauna bathing"}'::jsonb
      when it ->> 'addon_code' = 'turvenaamio_jalkakylpy' then it || '{"label":"Turvenaamio ja jalkakylpy","label_en":"Peat mask and foot bath"}'::jsonb
      else it end order by ord) from jsonb_array_elements(p.items) with ordinality t(it, ord)), '[]'::jsonb)
 where jsonb_array_length(p.items) > 0;

-- ---------- 2) PDF-data ----------
create or replace function booking.svc_get_gift_card_pdf_data(p_public_token uuid) returns jsonb
language plpgsql stable security definer set search_path to ''
as $$
declare g booking.gift_cards; v_red boolean;
begin
  select * into g from booking.gift_cards where public_token = p_public_token and p_public_token is not null;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Korttia ei löydy'); end if;
  if g.status not in ('active', 'used', 'expired') then return jsonb_build_object('ok', false, 'code', 'not_ready', 'message', 'Kortti aktivoituu kun tilaus on maksettu'); end if;
  v_red := booking._gc_flag('gift_cards.redeem_enabled') and (g.source <> 'johku' or booking._gc_flag('gift_cards.johku_cards_redeemable'));
  return jsonb_build_object('ok', true, 'code', booking.gift_code_fmt(g.code), 'status', case when g.status = 'active' and g.valid_to < booking._gc_today() then 'expired' else g.status end,
    'kind', g.kind, 'package_code', g.package_code,
    'package', (select jsonb_build_object('name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en, 'persons', p.persons, 'items', p.items, 'is_open', p.is_open)
                  from booking.gift_card_packages p where p.code = g.package_code),
    'initial_amount', g.initial_amount, 'balance', g.balance, 'currency', g.currency, 'valid_from', g.valid_from, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name,
    'greeting', g.greeting, 'buyer_name', g.buyer_name, 'locale', g.locale, 'issued_at', coalesce(g.activated_at, g.created_at), 'source', g.source,
    'redeemable_now', v_red, 'seller', booking._seller());
end $$;

create or replace function booking.public_get_gift_card(p_public_token uuid) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_ip text := coalesce(booking._client_ip(), 'unknown');
begin
  if not booking._rate_limit('gcget:' || v_ip, 60, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  return booking.svc_get_gift_card_pdf_data(p_public_token);
end $$;

-- ---------- 3) email_outbox ----------
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
            'locale', g.locale, 'status', g.status) order by g.id), '[]'::jsonb)
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


-- ---------- 4) viestien luonti ----------
create or replace function booking._gc_enqueue_email(p_kind text, p_order bigint, p_card_ids bigint[], p_to text, p_to_name text, p_locale text, p_dedupe text) returns boolean
language plpgsql security definer set search_path to ''
as $$
declare v_mode text; v_n int;
begin
  if p_to is null or not booking._valid_email(lower(btrim(p_to))) or coalesce(cardinality(p_card_ids), 0) = 0 then return false; end if;
  select mode into v_mode from booking.integration_config where key = 'resend';
  insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload)
  values (p_kind, p_order, case when p_locale in ('fi', 'en', 'sv') then p_locale else 'fi' end, p_dedupe, case when coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end,
          jsonb_build_object('card_ids', to_jsonb(p_card_ids), 'to_email', lower(btrim(p_to)), 'to_name', nullif(btrim(coalesce(p_to_name, '')), '')))
  on conflict (dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

create or replace function booking._gc_activate_order(p_order bigint) returns int
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_n int := 0; v_today date := booking._gc_today(); v_ids bigint[] := '{}'; v_first booking.gift_cards;
begin
  for g in select * from booking.gift_cards where purchase_order_id = p_order and status = 'pending_payment' order by id for update loop
    update booking.gift_cards set status = 'active', balance = initial_amount, valid_from = v_today, valid_to = (v_today + make_interval(months => g.valid_months))::date,
           activated_at = now(), balance_verified = true, balance_verified_at = now(), balance_source = 'native' where id = g.id;
    insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, created_by, note)
    values (g.id, p_order, g.initial_amount, g.initial_amount, 'purchase', auth.uid(), 'Ostotilaus maksettu');
    v_n := v_n + 1; v_ids := v_ids || g.id;
    if v_first.id is null then v_first := g; end if;
    if g.recipient_email is not null then
      perform booking._gc_enqueue_email('gift_card_recipient', null, array[g.id], g.recipient_email, g.recipient_name, g.locale, 'gcrecip:' || g.id);
    end if;
  end loop;
  if v_n > 0 then
    perform booking._gc_enqueue_email('gift_card_buyer', p_order, v_ids, coalesce(v_first.buyer_email, (select c.email from booking.orders o join booking.customers c on c.id = o.customer_id where o.id = p_order)),
                                      coalesce(v_first.buyer_name, (select c.name from booking.orders o join booking.customers c on c.id = o.customer_id where o.id = p_order)), v_first.locale, 'gcbuyer:' || p_order);
  end if;
  return v_n;
end $$;

-- maksuton myöntö (ei tilausta): saajalle viesti jos saajan sähköposti annettu; myöntäjälle/ostajalle jos ostajan sähköposti annettu
create or replace function booking._gc_issue_email_trg() returns trigger language plpgsql security definer set search_path to ''
as $$ begin
  if new.recipient_email is not null then
    perform booking._gc_enqueue_email('gift_card_recipient', null, array[new.id], new.recipient_email, new.recipient_name, new.locale, 'gcrecip:' || new.id);
  end if;
  if new.buyer_email is not null then
    perform booking._gc_enqueue_email('gift_card_buyer', null, array[new.id], new.buyer_email, new.buyer_name, new.locale, 'gcbuyer:card:' || new.id);
  end if;
  return null;
end $$;
create trigger gift_cards_issue_email after insert on booking.gift_cards
  for each row when (new.status = 'active' and new.purchase_order_id is null and new.source = 'native') execute function booking._gc_issue_email_trg();

-- ---------- oikeudet ----------
revoke all on function booking.svc_get_gift_card_pdf_data(uuid) from public, anon, authenticated;
grant execute on function booking.svc_get_gift_card_pdf_data(uuid) to service_role;
revoke all on function booking._gc_enqueue_email(text, bigint, bigint[], text, text, text, text) from public, anon, authenticated;
revoke all on function booking._gc_issue_email_trg() from public, anon, authenticated;
grant execute on function booking.public_get_gift_card(uuid) to anon, authenticated;
