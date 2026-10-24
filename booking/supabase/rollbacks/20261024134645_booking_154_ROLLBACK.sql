-- =============================================================================
-- ROLLBACK booking_154 → palauttaa booking_146:n määritelmät (tuotannon md5 2026-10-24):
--   _annual_card_email_trg()   a93b1f1180257ee8647c54b420df5749
--   _annual_card_mail(bigint)  270c3d03eff0b36c8f1992129d965b5a
--   email_outbox_claim(integer) 1eb05f67aecff0034f9178eb0e2160eb
--   trigger annual_cards_email: after insert ... when (new.purchase_order_id is not null)
-- Poistaa booking._annual_card_admin_to(bigint) ja 6-parametrisen admin_create_annual_card-ylikuormituksen
-- (5-parametrinen b80c1d146fc6b57ea99bb1635f8814ca ei muuttunut).
-- Outbox-rivejä ei poisteta. Jos jonossa on vielä hallinnan kortin rivi (order_id null), sillä ei rollbackin jälkeen ole
-- vastaanottajaa → send-emails ohittaa sen ("ei kelvollista vastaanottajaa"). Hallinnan UI: palauta myös edellinen
-- discounts.js / customers.js (kutsu ilman p_send_email toimii, mutta 6-parametrinen kutsu ei).
-- =============================================================================
set local lock_timeout = '5s';

drop function if exists booking.admin_create_annual_card(bigint, date, date, text, text, boolean);

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

drop function if exists booking._annual_card_admin_to(bigint);

revoke all on function booking._annual_card_email_trg() from public, anon, authenticated;
revoke all on function booking._annual_card_mail(bigint) from public, anon, authenticated;
revoke all on function booking.email_outbox_claim(integer) from public, anon, authenticated;
grant execute on function booking.email_outbox_claim(integer) to service_role;
