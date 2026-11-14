begin;
-- t305: jumiin jääneiden hyvitysten hälytys henkilökunnalle (booking_305_refund_stuck_alerts, 14.11.2026).
-- Pohja: Bottiavustuksen DEV-testi /workspace/yoajo-migr/yotyo-14-11/305/t305_test.sql; pg_temp-roolinvaihdot korvattu
-- fixtures/10_test_helpers.sql:n test.*-funktioilla (login/anon/service/logout, pub_book, ord, mk_staff, rule, next_dow, reset_rl).
-- Vaatii migraatiot 282–284 + 305 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback.
-- Montonio on mockattu: hyvitysrivi jää requested-tilaan; eteneminen simuloidaan montonio_refund_claim/stamp/complete/fail-funktioilla.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t305_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t305_r values (coalesce(p_ok, false), p_label) $$;
-- ajaa SQL:n annetulla roolilla (test.login / test.anon / test.service) ja palauttaa virheen jsonb:nä
create function pg_temp.run(p_who text, p_sql text, p_user uuid default null, p_ip text default null) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.reset_rl();
  case p_who when 'anon' then perform test.anon(p_ip); when 'service' then perform test.service(); else perform test.login(p_user); end case;
  begin execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
-- tilaus: n henkilöä, maksettu kokonaan Montoniolla (kirjataan korttimaksuna ja muutetaan Montonio-riviksi kuten t284)
create function pg_temp.mk(p_adm uuid, p_rule bigint, p_date date, p_persons int, p_email text, out o_id bigint, out tok uuid) language plpgsql as $$
declare a jsonb; v_unpaid numeric;
begin
  perform test.reset_rl();
  a := test.pub_book(p_rule, p_date, p_persons, p_email);
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  tok := (a ->> 'token')::uuid; o_id := (test.ord(tok)).id;
  select (booking._order_balance(o_id) ->> 'unpaid')::numeric into v_unpaid;
  perform test.login(p_adm);
  perform booking.admin_record_payment(o_id, 'card_terminal', v_unpaid, null, null);
  perform test.logout();
  update booking.payments set provider = 'montonio', method = 'montonio', raw = '{"order_uuid":"x","env":"test"}'::jsonb
   where order_id = o_id and method = 'card_terminal' and gift_card_id is null;
end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); v_prod bigint; d date := test.next_dow(1, 20);
  u_adm uuid := test.mk_staff('adm@t305.example', 'admin');
  v jsonb; oA bigint; tA uuid; oB bigint; tB uuid; oC bigint; tC uuid; r1 bigint; r2 bigint; r3 bigint;
  e0 int; h0 text; h1 text;
begin
  select product_id into v_prod from booking.schedule_rules where id = v_rule;
  update booking.settings set value = 'true'::jsonb where key in ('customer_auto_partial_refund_enabled', 'partial_refunds_enabled');
  update booking.settings set value = '1000'::jsonb where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'montonio';
  update booking.product_config set cancellation_tier = 'general' where product_id = v_prod;

  -- asetukset ja cron
  perform pg_temp.ck((select value from booking.settings where key = 'refund_stuck_requested_hours') = '24'::jsonb
                 and (select value from booking.settings where key = 'refund_stuck_customer_hours') = '2'::jsonb
                 and (select value from booking.settings where key = 'refund_stuck_processing_hours') = '48'::jsonb, 'A0: kynnykset 24 / 2 / 48 h');
  perform pg_temp.ck(exists (select 1 from cron.job where jobname = 'booking_refunds_stuck_sweep' and schedule = '13,43 * * * *' and command = 'select booking.refunds_stuck_sweep()'), 'A1: cron-ajo 13,43');

  -- kolme hyvitystä: A asiakkaan oma pienennys, B ja C henkilökunnan muutos
  select * into oA, tA from pg_temp.mk(u_adm, v_rule, d, 3, 's1@t305.example');
  select * into oB, tB from pg_temp.mk(u_adm, v_rule, d, 3, 's2@t305.example');
  select * into oC, tC from pg_temp.mk(u_adm, v_rule, d, 3, 's3@t305.example');
  v := pg_temp.run('anon', format('select booking.public_change_booking(%L, null, null, 2, 29)', tA), null, '10.30.5.1');
  select id into r1 from booking.refunds where order_id = oA;
  perform pg_temp.ck(r1 is not null and (select created_by is null and reason = 'customer_reduce' and status = 'requested' from booking.refunds where id = r1), 'B1: asiakkaan pienennys → requested-hyvitys ' || v::text);
  v := pg_temp.run('user', format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, 29, %L, false)', (select id from booking.reservations where order_id = oB), 't305'), u_adm);
  select id into r2 from booking.refunds where order_id = oB;
  v := pg_temp.run('user', format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, 29, %L, false)', (select id from booking.reservations where order_id = oC), 't305'), u_adm);
  select id into r3 from booking.refunds where order_id = oC;
  perform pg_temp.ck(r2 is not null and r3 is not null and (select bool_and(created_by is not null and status = 'requested') from booking.refunds where id in (r2, r3)), 'B2: henkilökunnan muutos → requested-hyvitykset ' || v::text);

  select count(*) into e0 from booking.email_outbox;
  -- s0: tuoreet hyvitykset eivät hälytä
  v := booking.refunds_stuck_sweep();
  perform pg_temp.ck((v ->> 'alerts_queued')::int = 0, 'S0: tuoreet hyvitykset eivät hälytä ' || v::text);
  -- s1: asiakkaan ja henkilökunnan hyvitys 3 h vanhoja → vain asiakkaan (kynnys 2 h)
  update booking.refunds set created_at = now() - interval '3 hours', updated_at = now() - interval '3 hours' where id in (r1, r2);
  v := booking.refunds_stuck_sweep();
  perform pg_temp.ck((v ->> 'alerts_queued')::int = 1 and exists (select 1 from booking.notifications_outbox where topic = 'refund_stuck' and ref_id = r1 and target = 'tapio' and ref_table = 'refunds' and status = 'new'),
                     'S1: asiakkaan hyvitys 3 h → 1 hälytys Tapiolle ' || v::text);
  perform pg_temp.ck((select (payload ->> 'customer_initiated')::boolean and payload ->> 'message' like 'Hyvitys #' || r1 || '%Asiakkaan oma pienennys%' from booking.notifications_outbox where topic = 'refund_stuck' and ref_id = r1),
                     'S1b: viesti kertoo asiakkaan pienennyksestä');
  -- s2: henkilökunnan 25 h → hälytys; s3: toisto ei tuplaa, sweep ei muuta refunds-taulua eikä lähetä sähköpostia
  update booking.refunds set created_at = now() - interval '25 hours', updated_at = now() - interval '25 hours' where id = r2;
  select md5(string_agg(f::text, '|' order by f.id)) into h0 from booking.refunds f;
  v := booking.refunds_stuck_sweep();
  perform pg_temp.ck((v ->> 'alerts_queued')::int = 1 and exists (select 1 from booking.notifications_outbox where topic = 'refund_stuck' and ref_id = r2), 'S2: henkilökunnan hyvitys 25 h → 1 hälytys ' || v::text);
  v := booking.refunds_stuck_sweep();
  perform pg_temp.ck((v ->> 'alerts_queued')::int = 0 and (select count(*) from booking.notifications_outbox where topic = 'refund_stuck') = 2, 'S3: ei tuplahälytyksiä ' || v::text);
  select md5(string_agg(f::text, '|' order by f.id)) into h1 from booking.refunds f;
  perform pg_temp.ck(h0 is not distinct from h1, 'S3b: sweep ei muuta refunds-taulua');
  perform pg_temp.ck((select count(*) from booking.email_outbox) = e0, 'S3c: sweep ei luo sähköpostia');
  -- Tapio näkee hälytykset
  v := pg_temp.run('service', $q$select booking.notifications_pull('tapio', 'new', 50)$q$);
  perform pg_temp.ck(jsonb_array_length(v -> 'items') >= 2, 'S3d: notifications_pull (service_role) palauttaa hälytykset ' || left(v::text, 300));

  -- s4: r1 valmistuu → ratkeaa; r2 epäonnistuu → requested-hälytys ratkeaa ja failed-hälytys syntyy
  perform test.service();
  perform booking.montonio_refund_claim(r1, 1);
  perform booking.montonio_refund_stamp(r1, 'rf-t305-1', 'PENDING', '{"status":"PENDING"}'::jsonb);
  perform booking.montonio_refund_complete(r1, 'rf-t305-1', '{"refundStatus":"SUCCESSFUL"}'::jsonb);
  perform booking.montonio_refund_claim(r2, 1);
  perform booking.montonio_refund_fail(r2, '{"status":"REJECTED"}'::jsonb);
  perform test.logout();
  v := booking.refunds_stuck_sweep();
  perform pg_temp.ck((select status = 'resolved' and resolved_reason = 'refund_done' from booking.notifications_outbox where topic = 'refund_stuck' and ref_id = r1),
                     'S4: valmis hyvitys ratkaisee hälytyksen ' || v::text);
  perform pg_temp.ck(exists (select 1 from booking.notifications_outbox where topic = 'refund_stuck' and ref_id = r2 and status = 'resolved' and resolved_reason = 'refund_failed')
                 and exists (select 1 from booking.notifications_outbox where topic = 'refund_stuck' and ref_id = r2 and status = 'new' and payload ->> 'refund_status' = 'failed'),
                     'S4b: epäonnistunut → vanha ratkeaa, uusi failed-hälytys');
  -- s5: r3 processing 49 h (Montonio ei vahvista)
  perform test.service();
  perform booking.montonio_refund_claim(r3, 1);
  perform booking.montonio_refund_stamp(r3, 'rf-t305-3', 'PENDING', null);
  perform test.logout();
  update booking.refunds set updated_at = now() - interval '49 hours' where id = r3;
  v := booking.refunds_stuck_sweep();
  perform pg_temp.ck(exists (select 1 from booking.notifications_outbox where topic = 'refund_stuck' and ref_id = r3 and payload ->> 'refund_status' = 'processing'), 'S5: processing 49 h → hälytys ' || v::text);
  -- s6: Tapio kuittaa
  v := pg_temp.run('service', format('select to_jsonb(booking.notifications_ack(%L::bigint[], %L))', array(select id from booking.notifications_outbox where topic = 'refund_stuck' and status = 'new'), 'tapio'));
  perform pg_temp.ck(not exists (select 1 from booking.notifications_outbox where topic = 'refund_stuck' and status = 'new'), 'S6: kuittaus (service_role) ' || v::text);

  -- oikeudet: anon ja authenticated eivät voi ajaa, service_role voi
  v := pg_temp.run('anon', 'select booking.refunds_stuck_sweep()', null, '10.30.5.2');
  perform pg_temp.ck(v ? 'err', 'P1: anon ei voi ajaa ' || v::text);
  v := pg_temp.run('user', 'select booking.refunds_stuck_sweep()', u_adm);
  perform pg_temp.ck(v ? 'err', 'P2: authenticated (admin) ei voi ajaa ' || v::text);
  v := pg_temp.run('service', 'select booking.refunds_stuck_sweep()');
  perform pg_temp.ck(not (v ? 'err') and (v ->> 'ok')::boolean, 'P3: service_role voi ajaa ' || v::text);
end $t$;
select 'RESULT ' || case when ok then 'ok' else 'NOT OK' end || ' - ' || label from t305_r;
select 'SUMMARY ' || count(*) filter (where not ok) || ' failed / ' || count(*) from t305_r;
rollback;
