-- =============================================================================
-- booking_146: vuosikortin koodi sähköpostiin ja näkyviin kassalla.
-- 1) Uusi sähköpostityyppi annual_card_code (email_outbox_kind_check = booking_132:n lista + annual_card_code).
-- 2) Kun maksetusta tuotteen 43 (season_card) tilauksesta syntyy vuosikortti (booking._annual_card_from_order,
--    sama polku verkkotilaukselle ja hallinnan kassalle / maksun kirjaukselle), annual_cards-rivin AFTER INSERT
--    -trigger jonottaa viestin booking._enqueue_email-funktiolla. dedupe_key = 'annual_card_code:<kortin id>' →
--    viesti jonotetaan vain kerran per kortti. Asiakkaalla ei kelvollista sähköpostia → ei jonoa (kassa näyttää huomautuksen).
--    Hallinnassa käsin luotu kortti (purchase_order_id null) ei ole myynti → ei viestiä. Vanhoille korteille ei lähetetä jälkikäteen.
--    Jonotuksen virhe ei kaada kortin myöntämistä eikä maksun kirjausta: virhe audit_logiin.
-- 3) email_outbox_claim: booking_132:n claim säilyy sellaisenaan (nimetään email_outbox_claim_base_146) ja wrapper
--    lisää annual_card_code-riville lohkon annual_card {code, valid_from, valid_to, active, revoked, booking_url}.
--    booking_url = site_base_url + '/varaa/' (fi) tai '/en/book/' (en), kuten jonotuslistan viesteissä.
-- 4) admin_annual_card_for_order(order_id): kassa / tilauksen tiedot näyttävät koodin, voimassaolon ja sähköpostin tilan.
--    Oikeus payments.manage tai annual_cards.manage.
-- Ei muuta hintoja, ALV:tä, kortin myöntämissääntöjä (booking_142/143), lähetystilaa (off / dry_run / live) eikä public-skeemaa.
-- Edge: booking/supabase/functions/send-emails (templates.ts, texts.ts, index.ts) – uusi pohja annual_card_code.
-- Uudelleenajettava: create or replace / drop if exists / vartioitu nimenvaihto.
-- Rollback: ../rollbacks/20261024185000_booking_146_ROLLBACK.sql
-- =============================================================================
set local lock_timeout = '5s';

alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem', 'business_quote_ack', 'business_quote_notify', 'invoice_pdf', 'product_message', 'waitlist_spot_freed', 'annual_card_code'));

-- ---------------------------------------------------------------- 2) jonotus kortin syntyessä
create or replace function booking._annual_card_email_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.purchase_order_id is null then return new; end if;
  begin
    perform booking._enqueue_email('annual_card_code', new.purchase_order_id, null, null,
                                   'annual_card_code:' || new.id::text, jsonb_build_object('card_id', new.id));
  exception when others then   -- viesti ei saa kaataa kortin myöntämistä eikä maksun kirjausta
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (null, booking._jwt_role(), 'annual_cards', new.id::text, 'annual_card_email_failed', null,
            jsonb_build_object('order_id', new.purchase_order_id, 'error', sqlerrm));
  end;
  return new;
end $$;
drop trigger if exists annual_cards_email on booking.annual_cards;
create trigger annual_cards_email after insert on booking.annual_cards
  for each row when (new.purchase_order_id is not null) execute function booking._annual_card_email_trg();

-- ---------------------------------------------------------------- 3) claim-wrapper
do $$
begin
  if to_regprocedure('booking.email_outbox_claim_base_146(integer)') is null then
    alter function booking.email_outbox_claim(integer) rename to email_outbox_claim_base_146;
  end if;
end $$;
revoke all on function booking.email_outbox_claim_base_146(integer) from public, anon, authenticated;

create or replace function booking._annual_card_mail(p_outbox_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('card_id', a.id, 'code', a.code, 'valid_from', a.valid_from, 'valid_to', a.valid_to,
           'active', a.active, 'revoked', a.revoked_at is not null,
           'booking_url', rtrim(coalesce(booking._setting('site_base_url') #>> '{}', ''), '/')
                          || case when e.locale = 'en' then '/en/book/' else '/varaa/' end)
    from booking.email_outbox e
    join booking.annual_cards a on a.id = case when e.payload ->> 'card_id' ~ '^[0-9]+$' then (e.payload ->> 'card_id')::bigint end
   where e.id = p_outbox_id;
$$;

create or replace function booking.email_outbox_claim(p_limit integer default 20) returns jsonb
language sql volatile security definer set search_path = '' as $$
  select coalesce(jsonb_agg(case when z.item->>'kind' = 'annual_card_code'
    then z.item || jsonb_build_object('annual_card', booking._annual_card_mail((z.item->>'id')::bigint))
    else z.item end order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_146(p_limit)) with ordinality as z(item, ord);
$$;

-- ---------------------------------------------------------------- 4) kassan / tilauksen näkymä
-- email_status: pending | sending | sent | dry_run | skipped | failed | dead | no_email (ei kelvollista osoitetta) | not_queued (kortti ennen booking_146:ta)
create or replace function booking.admin_annual_card_for_order(p_order_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; a booking.annual_cards; c booking.customers; e booking.email_outbox; v_has boolean; v_status text;
begin
  if not (booking.has_permission('payments.manage') or booking.has_permission('annual_cards.manage')) then
    perform booking._require_permission('payments.manage');
  end if;
  select * into o from booking.orders where id = p_order_id;
  if o.id is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_has := exists (select 1 from booking.order_items oi join kb.products p on p.id = oi.product_id
                    where oi.order_id = o.id and p.category = 'season_card');
  select * into a from booking.annual_cards where purchase_order_id = o.id;
  select * into c from booking.customers where id = coalesce(a.customer_id, o.customer_id);
  if a.id is null then
    return jsonb_build_object('ok', true, 'has_season_card', v_has, 'card', null, 'payment_status', o.payment_status,
                              'has_customer', o.customer_id is not null);
  end if;
  select * into e from booking.email_outbox where dedupe_key = 'annual_card_code:' || a.id::text;
  v_status := case when e.id is not null then e.status
                   when c.email is null or not booking._valid_email(c.email) then 'no_email'
                   else 'not_queued' end;
  return jsonb_build_object('ok', true, 'has_season_card', v_has, 'payment_status', o.payment_status, 'has_customer', true,
    'card', jsonb_build_object('id', a.id, 'code', a.code, 'valid_from', a.valid_from, 'valid_to', a.valid_to,
                               'active', a.active, 'revoked', a.revoked_at is not null),
    'email', jsonb_build_object('status', v_status, 'to', case when c.email is not null and booking._valid_email(c.email) then c.email end,
                                'sent_at', e.sent_at, 'queued_at', e.created_at));
end $$;

revoke all on function booking._annual_card_email_trg() from public, anon, authenticated;
revoke all on function booking._annual_card_mail(bigint) from public, anon, authenticated;
revoke all on function booking.email_outbox_claim(integer) from public, anon, authenticated;
revoke all on function booking.admin_annual_card_for_order(bigint) from public, anon;
grant execute on function booking.email_outbox_claim(integer) to service_role;
grant execute on function booking.admin_annual_card_for_order(bigint) to authenticated, service_role;
