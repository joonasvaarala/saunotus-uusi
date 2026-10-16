-- =====================================================================
-- booking 07: RLS kaikille tauluille + oikeudet minimiin
--  * anon: EI pääsyä tauluihin; vain julkiset public_*-funktiot (SECURITY DEFINER).
--  * authenticated: SELECT vain jos booking.is_staff() (RLS; henkilöstörooli admin/manager/staff + aktiivinen rivi booking.staff);
--    kirjoitukset ainoastaan admin_*-funktioiden kautta, jotka tarkistavat OIKEUDEN (has_permission). Pelkkä Auth-tunnus tai
--    asiakkaaksi linkitetty tunnus (customers.auth_user_id) ei anna mitään oikeuksia.
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
    'space_blocks','resources','schedule_rules','schedule_rule_pools','product_config','settings',
    'roles','role_permissions','annual_cards']) loop
    execute format('grant select on booking.%I to authenticated', t);
    execute format('create policy staff_read on booking.%I for select to authenticated using (booking.is_staff())', t);
  end loop;
end $$;

-- henkilöstö: jokainen näkee oman rivinsä; kaikki rivit vain oikeudella staff.manage (admin). Kirjoitus vain admin_upsert_staff.
grant select on booking.staff to authenticated;
create policy staff_self_read on booking.staff for select to authenticated using (user_id = auth.uid() or booking.has_permission('staff.manage'));
-- audit-loki: vain oikeudella audit.read (admin)
grant select on booking.audit_log to authenticated;
create policy audit_admin_read on booking.audit_log for select to authenticated using (booking.has_permission('audit.read'));
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
  booking.public_get_booking(uuid), booking.public_cancel_booking(uuid),
  booking.public_change_booking(uuid, bigint, date, integer)
  to anon, authenticated;
-- RLS-politiikoissa käytettävät apufunktiot
grant execute on function booking.is_staff(), booking.is_admin(), booking.current_staff_role(), booking.has_permission(text) to authenticated;
-- Hallinnan funktiot (tarkistavat oikeuden sisäisesti: _require_staff / _require_permission)
grant execute on function
  booking.admin_list_products(), booking.admin_update_product(bigint, jsonb), booking.admin_update_price_variant(bigint, jsonb),
  booking.admin_update_product_config(bigint, jsonb), booking.admin_set_setting(text, jsonb), booking.admin_update_resource(bigint, jsonb),
  booking.admin_list_staff(), booking.admin_upsert_staff(uuid, text, text, boolean, uuid),
  booking.admin_set_staff_role(uuid, text), booking.admin_list_public_staff(), booking.admin_link_public_staff(uuid, uuid),
  booking.admin_upcoming_shifts(timestamptz, timestamptz),
  booking.admin_create_block(bigint, timestamptz, timestamptz, text), booking.admin_delete_block(bigint),
  booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer),
  booking.admin_day_view(date),
  booking.admin_create_booking(bigint, date, integer, bigint, jsonb, text, boolean, text, timestamptz, timestamptz, numeric, text),
  booking.admin_record_payment(bigint, text, numeric, text), booking.admin_create_payment_link(bigint),
  booking.admin_set_reservation_status(bigint, text, text),
  booking.admin_list_customers(text, integer, integer), booking.admin_get_customer(bigint), booking.admin_update_customer(bigint, jsonb),
  booking.admin_my_permissions(), booking.admin_list_roles(), booking.admin_update_schedule_rule(bigint, jsonb),
  booking.admin_change_booking(bigint, bigint, date, integer),
  booking.admin_grant_annual_card(bigint, date, date, text), booking.admin_update_annual_card(bigint, jsonb),
  booking.admin_revoke_annual_card(bigint, boolean), booking.admin_list_annual_cards(bigint, boolean),
  booking.admin_create_annual_card_booking(bigint, bigint, date, text)
  to authenticated;
-- Edge Function admin-users: svc_*-funktiot ja sisäiset apufunktiot (_check_public_staff…, _uid_has_permission) EIVÄT ole authenticated/anon-käytössä:
-- ylempi 'revoke all on all functions' poisti oikeudet, eikä niille anneta grantia (service_role sai oikeuden riviltä 50).
-- Maksuadapteri, ajastus: vain service_role (ei anon/authenticated)
revoke all on function booking.payment_prepare(bigint), booking.payment_attach_provider_ref(bigint, text, text, jsonb),
  booking.payment_mark_paid(text, text, numeric, jsonb), booking.payment_mark_failed(text, text, text, jsonb),
  booking.expire_holds() from public, anon, authenticated;
