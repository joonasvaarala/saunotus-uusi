-- booking_286 ajettu: DEV 20261111211855, PROD 20261111211923 (migrations/20261111211923_booking_286_checkoutx_pos.sql, tavu-identtinen ajetun kanssa; sen otsakkeen rollback-viite 20261111203000 on ajoa edeltävä nimi tälle tiedostolle).
-- booking_286 ROLLBACK: poistaa Pikakassan CheckoutX-maksutavan ja palauttaa admin_pos_tenders()-funktion booking_189-muotoon (md5 443e6462ede3ec9d3118d08be43759fa).
-- Pysähtyy, jos checkoutx-maksuja tai -hyvityksiä on kirjattu (ne kuuluvat kirjanpitoon; poista/siirrä ensin käsin harkiten).
set local lock_timeout = '5s';

do $g$
begin
  if exists (select 1 from booking.payments where provider = 'checkoutx' or method = 'checkoutx') then
    raise exception 'booking_286 rollback: checkoutx-maksuja on kirjattu (%). Ei muutoksia.', (select count(*) from booking.payments where provider = 'checkoutx' or method = 'checkoutx');
  end if;
  if exists (select 1 from booking.refunds where provider = 'checkoutx') then
    raise exception 'booking_286 rollback: checkoutx-hyvityksiä on kirjattu. Ei muutoksia.';
  end if;
end $g$;

CREATE OR REPLACE FUNCTION booking.admin_pos_tenders()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_base text := rtrim(coalesce(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', ''), '/');
begin
  perform booking._require_permission('pos.use');
  return jsonb_build_object(
    'montonio_mode', booking._montonio_mode(),
    'mobilepay_mode', booking._mobilepay_mode(),
    'vismapay_mode', coalesce((select mode from booking.integration_config where key = 'vismapay'), 'off'),
    'site_base_url', v_base,
    'drinks_path', booking._drinks_path('fi'),
    'drinks_path_en', booking._drinks_path('en'),
    'tenders', coalesce((select jsonb_agg(jsonb_build_object(
        'code', t.code, 'handler', t.handler, 'channels', to_jsonb(t.channels), 'active', t.active,
        'sort_order', t.sort_order, 'unavailable_reason', t.unavailable_reason) order by t.sort_order, t.code)
      from booking.pos_tenders t), '[]'::jsonb));
end $function$


;
revoke all on function booking.admin_pos_tenders() from public, anon;
grant execute on function booking.admin_pos_tenders() to authenticated, service_role;

drop function if exists booking.checkoutx_refund_fail(bigint,jsonb);
drop function if exists booking.checkoutx_refund_complete(bigint,jsonb);
drop function if exists booking.checkoutx_refund_claim(bigint);
drop function if exists booking.checkoutx_pos_create_failed(bigint,jsonb);
drop function if exists booking.checkoutx_pos_apply(bigint,text,text,jsonb);
drop function if exists booking.checkoutx_pos_lookup(bigint);
drop function if exists booking.checkoutx_pos_created(bigint,text,text);
drop function if exists booking.checkoutx_pos_prepare(bigint,text,uuid);
drop function if exists booking.checkoutx_terminal_save(text,text,uuid);
drop function if exists booking.admin_checkoutx_terminal_remove(text);
drop function if exists booking.admin_set_checkoutx_mode(text,text);
drop function if exists booking.admin_get_checkoutx_status();
drop trigger if exists integration_config_checkoutx_guard on booking.integration_config;
drop function if exists booking._checkoutx_guard_trg();
drop function if exists booking._checkoutx_mode();
drop table if exists booking.checkoutx_terminals;

delete from booking.pos_tenders where code = 'checkoutx';
delete from booking.payment_methods where code = 'checkoutx';
delete from booking.integration_config where key = 'checkoutx';

alter table booking.integration_config drop constraint if exists integration_config_checkoutx_no_live;
alter table booking.integration_config drop constraint if exists integration_config_test_only_online;
alter table booking.integration_config add constraint integration_config_test_only_online
  check (mode <> 'test' or key in ('mobilepay', 'vismapay', 'montonio'));
alter table booking.integration_config drop constraint if exists integration_config_key_check;
alter table booking.integration_config add constraint integration_config_key_check
  check (key in ('resend', 'vismapay', 'procountor', 'mobilepay', 'booking_calendar', 'montonio'));

do $g$
begin
  if md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_tenders()'))) <> '443e6462ede3ec9d3118d08be43759fa' then
    raise exception 'booking_286 rollback: admin_pos_tenders md5 ei palautunut booking_189-muotoon';
  end if;
end $g$;
