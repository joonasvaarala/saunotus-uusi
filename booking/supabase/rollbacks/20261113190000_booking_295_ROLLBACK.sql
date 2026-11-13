-- booking_295 ROLLBACK: poistaa SumUp-maksutavan ja palauttaa admin_pos_tenders()-funktion booking_286-muotoon (md5 864bc26d1e42f6cb36eaf06da46dd6e6).
-- Huom: palautus tuo CheckoutX:n takaisin Pikakassan maksutapalistaan, kun checkoutx-tila on test (booking_286:n käyttäytyminen).
-- Pysähtyy, jos sumup-maksuja tai -hyvityksiä on kirjattu (ne kuuluvat kirjanpitoon; siirrä ensin käsin harkiten).
set local lock_timeout = '5s';

do $g$
begin
  if exists (select 1 from booking.payments where provider = 'sumup' or method = 'sumup') then
    raise exception 'booking_295 rollback: sumup-maksuja on kirjattu (%). Ei muutoksia.', (select count(*) from booking.payments where provider = 'sumup' or method = 'sumup');
  end if;
  if exists (select 1 from booking.refunds where provider = 'sumup') then
    raise exception 'booking_295 rollback: sumup-hyvityksiä on kirjattu. Ei muutoksia.';
  end if;
end $g$;

CREATE OR REPLACE FUNCTION booking.admin_pos_tenders()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_base text := rtrim(coalesce(booking._setting('site_base_url', to_jsonb(''::text)) #>> '{}', ''), '/');
        v_cx text := booking._checkoutx_mode();
begin
  perform booking._require_permission('pos.use');
  return jsonb_build_object(
    'montonio_mode', booking._montonio_mode(),
    'mobilepay_mode', booking._mobilepay_mode(),
    'vismapay_mode', coalesce((select mode from booking.integration_config where key = 'vismapay'), 'off'),
    'checkoutx_mode', v_cx,
    'site_base_url', v_base,
    'drinks_path', booking._drinks_path('fi'),
    'drinks_path_en', booking._drinks_path('en'),
    'tenders', coalesce((select jsonb_agg(jsonb_build_object(
        'code', t.code, 'handler', t.handler, 'channels', to_jsonb(t.channels), 'active', t.active,
        'sort_order', t.sort_order, 'unavailable_reason', t.unavailable_reason) order by t.sort_order, t.code)
      from booking.pos_tenders t
     where t.handler <> 'checkoutx' or v_cx = 'test'), '[]'::jsonb));
end $function$
;
revoke all on function booking.admin_pos_tenders() from public, anon;
grant execute on function booking.admin_pos_tenders() to authenticated, service_role;

drop function if exists booking.sumup_refund_fail(bigint,jsonb);
drop function if exists booking.sumup_refund_complete(bigint,jsonb);
drop function if exists booking.sumup_refund_claim(bigint);
drop function if exists booking.sumup_pos_create_failed(bigint,jsonb);
drop function if exists booking.sumup_pos_apply(bigint,text,text,text,numeric,jsonb);
drop function if exists booking.sumup_pos_lookup_ref(text);
drop function if exists booking.sumup_pos_lookup(bigint);
drop function if exists booking._sumup_lookup_json(booking.payments);
drop function if exists booking.sumup_pos_started(bigint,text);
drop function if exists booking.sumup_pos_prepare(bigint,text,uuid);
drop function if exists booking.sumup_reader_save(text,text,uuid);
drop function if exists booking.admin_sumup_reader_set_default(text);
drop function if exists booking.admin_sumup_reader_remove(text);
drop function if exists booking.admin_set_sumup_mode(text,text);
drop function if exists booking.admin_get_sumup_status();
drop trigger if exists integration_config_sumup_guard on booking.integration_config;
drop function if exists booking._sumup_guard_trg();
drop function if exists booking._sumup_mode();
drop table if exists booking.sumup_readers;

delete from booking.pos_tenders where code = 'sumup';
delete from booking.payment_methods where code = 'sumup';
delete from booking.integration_config where key = 'sumup';

alter table booking.integration_config drop constraint if exists integration_config_sumup_modes;
-- key_check ja test_only_online: poistetaan 'sumup' nykyisestä listasta (säilyttää muut avaimet)
do $c$
declare d_key text; d_test text;
begin
  select pg_get_constraintdef(oid) into d_key from pg_constraint where conrelid = 'booking.integration_config'::regclass and conname = 'integration_config_key_check';
  select pg_get_constraintdef(oid) into d_test from pg_constraint where conrelid = 'booking.integration_config'::regclass and conname = 'integration_config_test_only_online';
  execute 'alter table booking.integration_config drop constraint integration_config_key_check';
  execute 'alter table booking.integration_config add constraint integration_config_key_check ' || replace(d_key, ', ''sumup''::text', '');
  execute 'alter table booking.integration_config drop constraint integration_config_test_only_online';
  execute 'alter table booking.integration_config add constraint integration_config_test_only_online ' || replace(d_test, ', ''sumup''::text', '');
end $c$;

do $g$
begin
  if md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_tenders()'))) <> '864bc26d1e42f6cb36eaf06da46dd6e6' then
    raise exception 'booking_295 rollback: admin_pos_tenders md5 ei palautunut booking_286-muotoon';
  end if;
end $g$;
