-- =====================================================================
-- booking 07: RLS kaikille tauluille + oikeudet minimiin
--  * anon: EI pääsyä tauluihin; vain julkiset public_*-funktiot (SECURITY DEFINER).
--  * authenticated: SELECT vain jos booking.is_staff() (RLS); kirjoitukset ainoastaan admin_*-funktioiden kautta.
--  * service_role: kaikki (Edge Functions: maksut, sähköpostit, ajastukset).
-- =====================================================================
set local search_path = booking, extensions, public;

do $$
declare t text;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'booking' and c.relkind = 'r' loop
    execute format('alter table booking.%I enable row level security', t);
  end loop;
end $$;

-- Nollaa oikeudet
revoke all on all tables in schema booking from public, anon, authenticated;
revoke all on all sequences in schema booking from public, anon, authenticated;
revoke all on all functions in schema booking from public, anon, authenticated;

-- Staff saa lukea (RLS-politiikat); kirjoitus vain funktioiden kautta
do $$
declare t text;
begin
  for t in select unnest(array[
    'customers','orders','order_items','reservations','payments','payment_methods','gift_cards','gift_card_ledger',
    'discount_codes','marketing_segments','marketing_segment_members','campaigns','campaign_sends','marketing_consent_events',
    'space_blocks','resources','schedule_rules','schedule_rule_pools','product_config','settings']) loop
    execute format('grant select on booking.%I to authenticated', t);
    execute format('create policy staff_read on booking.%I for select to authenticated using (booking.is_staff())', t);
  end loop;
end $$;

-- henkilöstö: jokainen näkee oman rivinsä, admin kaikki
grant select on booking.staff to authenticated;
create policy staff_self_read on booking.staff for select to authenticated using (user_id = auth.uid() or booking.is_admin());
-- audit-loki: vain admin
grant select on booking.audit_log to authenticated;
create policy audit_admin_read on booking.audit_log for select to authenticated using (booking.is_admin());
-- rate_limit_hits: RLS päällä, ei politiikkoja, ei oikeuksia (vain SECURITY DEFINER -funktiot)

-- service_role: täydet oikeudet (ohittaa RLS:n Supabasessa)
grant all on all tables in schema booking to service_role;
grant all on all sequences in schema booking to service_role;
grant execute on all functions in schema booking to service_role;

-- ---------- funktio-oikeudet ----------
-- Julkinen rajapinta (anon + kirjautunut)
grant execute on function
  booking.public_settings(), booking.public_catalog(), booking.public_availability(bigint, date, date),
  booking.public_create_booking(bigint, date, integer, text, text, text, boolean, text, text),
  booking.public_get_booking(uuid), booking.public_cancel_booking(uuid)
  to anon, authenticated;
-- RLS-politiikoissa käytettävät apufunktiot
grant execute on function booking.is_staff(), booking.is_admin(), booking.current_staff_role() to authenticated;
-- Hallinnan funktiot (tarkistavat staff/admin-roolin sisäisesti)
grant execute on function
  booking.admin_list_products(), booking.admin_update_product(bigint, jsonb), booking.admin_update_price_variant(bigint, jsonb),
  booking.admin_update_product_config(bigint, jsonb), booking.admin_set_setting(text, jsonb), booking.admin_update_resource(bigint, jsonb),
  booking.admin_list_staff(), booking.admin_upsert_staff(uuid, text, text, boolean),
  booking.admin_create_block(bigint, timestamptz, timestamptz, text), booking.admin_delete_block(bigint),
  booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer),
  booking.admin_day_view(date),
  booking.admin_create_booking(bigint, date, integer, bigint, jsonb, text, boolean, text, timestamptz, timestamptz, numeric, text),
  booking.admin_record_payment(bigint, text, numeric, text), booking.admin_create_payment_link(bigint),
  booking.admin_set_reservation_status(bigint, text, text),
  booking.admin_list_customers(text, integer, integer), booking.admin_get_customer(bigint), booking.admin_update_customer(bigint, jsonb)
  to authenticated;
-- Maksuadapteri, ajastus: vain service_role (ei anon/authenticated)
revoke all on function booking.payment_prepare(bigint), booking.payment_attach_provider_ref(bigint, text, text, jsonb),
  booking.payment_mark_paid(text, text, numeric, jsonb), booking.payment_mark_failed(text, text, text, jsonb),
  booking.expire_holds() from public, anon, authenticated;
