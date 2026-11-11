-- LOCAL ONLY – EI DEV/PROD. booking_264 unpaid_order_delete (maksamattoman tilauksen poisto = arkistointi).
-- Ajo: cd booking/supabase/tests/checkout && psql -X -d <paikallinen testikanta, jossa fixtures/10_test_helpers> -f t264_unpaid_order_delete.sql
-- Yksi transaktio, lopussa tahallinen TESTRESULT-poikkeus + rollback. Rinnakkaisuus: t264_race.py (erilliset yhteydet).
\set ON_ERROR_STOP on
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
\ir ../../migrations/20261111141559_booking_264_unpaid_order_delete.sql
create temp table t264_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t264_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.mk(p_start timestamptz, p_email text) returns jsonb language plpgsql as $$
declare v jsonb; s timestamptz;
begin
  perform test.reset_rl();
  -- p_start on vain vihje; otetaan ensimmäinen tällä hetkellä vapaa aika (aiemmat testivaraukset huomioiden)
  for d in 0..12 loop
    select q.starts_at into s from booking.public_treatment_availability(11, current_date + 3 + d * 7, current_date + 9 + d * 7, 2) q
     where q.status = 'available' order by q.starts_at limit 1;
    exit when s is not null;
  end loop;
  v := booking.public_create_treatment_booking(11, s, 2, 'Testi Asiakas', p_email, '+358401234567', false, 'fi', null, 'private', null, null);
  if coalesce(v ->> 'ok', '') <> 'true' then raise exception 'TESTRESULT_ABORT mk % %: %', s, p_email, v; end if;
  return v;
end $$;
create function pg_temp.oid(p_tok uuid) returns bigint language sql as $$ select id from booking.orders where public_token = p_tok $$;
create function pg_temp.codes(p_b jsonb) returns text[] language sql as $$ select coalesce(array_agg(e ->> 'code' order by e ->> 'code'), '{}') from jsonb_array_elements(p_b) e $$;
-- BK001-virheen koodi (detail) tai 'no_error'
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  execute p_sql; return 'no_error';
exception when others then get stacked diagnostics d = pg_exception_detail; return sqlstate || ':' || coalesce(d, sqlerrm);
end $$;
-- booking_228 _booking_calendar_desired elig-ehto (r.hidden_at null, r confirmed/completed/no_show, o confirmed/completed, payment_status ei pending/failed)
create function pg_temp.cal_elig(p_o bigint) returns boolean language sql as $$
  select exists (select 1 from booking.reservations r join booking.orders o on o.id = r.order_id
                  where r.order_id = p_o and r.hidden_at is null and r.status in ('confirmed', 'completed', 'no_show')
                    and o.status in ('confirmed', 'completed') and o.payment_status not in ('pending', 'failed')) $$;
create function pg_temp.snap(p_o bigint) returns jsonb language sql as $$
  select jsonb_build_object(
    'o', (select to_jsonb(x) - 'updated_at' from booking.orders x where x.id = p_o),
    'r', (select jsonb_agg(to_jsonb(x) - 'updated_at' order by x.id) from booking.reservations x where x.order_id = p_o),
    'p', (select jsonb_agg(to_jsonb(x) - 'updated_at' order by x.id) from booking.payments x where x.order_id = p_o),
    'm', (select jsonb_agg(to_jsonb(x) - 'updated_at' order by x.id) from booking.email_outbox x where x.order_id = p_o),
    'a', (select count(*) from booking.audit_log where table_name = 'orders' and row_pk = p_o::text and action = 'ORDER_DELETED_UNPAID')) $$;
create function pg_temp.list(p_filter text, p_search text default null) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform test.login(test.mk_staff('admin@t264.example', 'admin'));
  v := booking.admin_list_orders(p_search => p_search, p_limit => 200, p_payment_filter => p_filter);
  perform test.logout();
  return v;
end $$;
-- booking_277: monivalinta p_payment_filters
create function pg_temp.mlisted(p_filters text[], p_o bigint) returns boolean language plpgsql as $$
declare v jsonb;
begin
  perform test.login(test.mk_staff('admin@t264.example', 'admin'));
  v := booking.admin_list_orders(p_limit => 200, p_payment_filters => p_filters);
  perform test.logout();
  return exists (select 1 from jsonb_array_elements(v -> 'rows') e where (e ->> 'order_id')::bigint = p_o);
end $$;
create function pg_temp.listed(p_filter text, p_o bigint, p_search text default null) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(pg_temp.list(p_filter, p_search) -> 'rows') e where (e ->> 'order_id')::bigint = p_o) $$;

-- booking_264 jono: julkinen vuorovaraus (säännöllinen vuoro, valinnainen rituaali) eri päivälle kuin edelliset; palauttaa {ok, token, ...}
create function pg_temp.mk_session(p_nth int, p_ritual boolean) returns jsonb language plpgsql as $$
declare k record; v jsonb; n int := 0; v_add jsonb;
begin
  for k in select sr.id rid, d::date dd, (booking.public_ritual_addon(sr.id, d::date, 2) -> 'times' -> 0 ->> 'starts_at') rs
             from booking.schedule_rules sr, generate_series(current_date + 3, current_date + 60, interval '1 day') d
            where (booking.public_ritual_addon(sr.id, d::date, 2) ->> 'available')::boolean is true
              and not exists (select 1 from booking.reservations r where r.rule_id = sr.id
                                and (r.starts_at at time zone 'Europe/Helsinki')::date = d::date)   -- vuoro, jota testi ei ole vielä käyttänyt
              and not exists (select 1 from booking.waitlist_entries w where w.rule_id = sr.id and w.session_date = d::date)
            order by d, sr.id
  loop
    n := n + 1;
    continue when n < p_nth;
    perform test.reset_rl();
    v_add := case when p_ritual then jsonb_build_array(jsonb_build_object('ritual_start', k.rs, 'quantity', 2, 'price', 1, 'unit_price', 0)) end;
    v := booking.public_create_booking(k.rid, k.dd, 2, 'Jono Testi', 'jono' || p_nth || '@t264.example', '0401234567', false, 'fi', null, 'private', null, v_add);
    if coalesce((v ->> 'ok')::boolean, false) then return v; end if;
  end loop;
  raise exception 't264 mk_session: ei vuoroa (%)', v;
end $$;
-- jonottaja täsmälleen varauksen vuoroon (sama sääntö/päivä/tila/aika), 1 hlö
create function pg_temp.wl(p_res bigint, p_email text) returns bigint language sql as $$
  insert into booking.waitlist_entries(product_id, rule_id, session_date, starts_at, ends_at, space_id, persons, customer_name, customer_email)
  select r.product_id, r.rule_id, (r.starts_at at time zone 'Europe/Helsinki')::date, r.starts_at, r.ends_at, r.space_id, 1, 'T264 jonottaja', p_email
    from booking.reservations r where r.id = p_res returning id $$;
create function pg_temp.wl_state(p_id bigint) returns text language sql as $$
  select w.status || ':' || (select count(*) from booking.email_outbox e where e.kind = 'waitlist_spot_freed' and e.status = 'pending'
                               and e.payload::text like '%' || w.customer_email || '%')
    from booking.waitlist_entries w where w.id = p_id $$;

do $t$
declare
  r jsonb; r2 jsonb; tok uuid; o bigint; ono bigint; a1 text; amt numeric; pid bigint; st text; ltok uuid;
  v_review jsonb; v_slots timestamptz[]; r_s record; i int := 0; res1 bigint; v_snap jsonb; v_cnt int; wid bigint; v_base text;
  u_admin uuid; u_staff uuid; u_mgr uuid; u_text uuid; o2 bigint; tok2 uuid; c_id bigint;
begin
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t264"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = coalesce(booking.integration_config.settings, '{}'::jsonb) || '{"approved_by":"t264"}'::jsonb;
  for r_s in select q.starts_at from (
      select * from booking.public_treatment_availability(11, current_date + 3, current_date + 16, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 17, current_date + 30, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 31, current_date + 44, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 45, current_date + 58, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 59, current_date + 72, 2)) q
     where q.status = 'available' order by q.starts_at loop
    if v_slots is null or r_s.starts_at >= v_slots[cardinality(v_slots)] + interval '2 hours' then v_slots := array_append(v_slots, r_s.starts_at); end if;
  end loop;
  if v_slots is null or cardinality(v_slots) < 19 then raise exception 'TESTRESULT_ABORT vapaita hoitoaikoja %', coalesce(cardinality(v_slots), 0); end if;
  u_admin := test.mk_staff('admin@t264.example', 'admin');
  u_mgr := test.mk_staff('mgr@t264.example', 'manager');
  u_staff := test.mk_staff('staff@t264.example', 'staff');
  -- fixture (LOCAL): henkilöstörooli ilman bookings.manage/payments.manage
  insert into booking.roles(code, label, is_staff, sort_order, active) values ('t264_viewer', 't264', true, 99, true);
  u_text := test.mk_staff('viewer@t264.example', 't264_viewer');

  -- ===== S rakenne / muuttumattomat funktiot / oikeudet
  perform pg_temp.ck(md5(pg_get_functiondef('booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure)) = 'b35618b8cd17fa9e7c5902719d0804a2'
      and md5(pg_get_functiondef('booking.montonio_payment_apply(text,text,numeric,jsonb)'::regprocedure)) = 'ef052d2d9baa94bbe8cc4a9e1784d0ed'
      and md5(pg_get_functiondef('booking.montonio_payment_prepare(uuid,uuid,text)'::regprocedure)) = '438ba5857d711f4686e3665bacd0eb18',
      'S1 payment_mark_paid (263), montonio_payment_apply/prepare ennallaan');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking._order_delete_blockers(bigint)', 'execute')
      and not has_function_privilege('anon', 'booking._order_delete_blockers(bigint)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_delete_unpaid_order(bigint,text)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_order_delete_check(bigint)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_delete_unpaid_order(bigint,text)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_order_delete_check(bigint)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])', 'execute')
      and not has_function_privilege('anon', 'booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])', 'execute'),
      'S2 ACL: sisäinen estefunktio ei kutsuttavissa, admin-RPC:t vain authenticated');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig = array['search_path=""']) from pg_proc
                       where oid in ('booking._order_delete_blockers(bigint)'::regprocedure, 'booking.admin_order_delete_check(bigint)'::regprocedure,
                                     'booking.admin_delete_unpaid_order(bigint,text)'::regprocedure))
      and position('nowait' in lower(pg_get_functiondef('booking.admin_delete_unpaid_order(bigint,text)'::regprocedure))) = 0
      and position('_refresh_order_payment' in pg_get_functiondef('booking.admin_delete_unpaid_order(bigint,text)'::regprocedure)) = 0,
      'S3 SECURITY DEFINER + search_path, ei NOWAITia, ei _refresh_order_payment');

  -- ===== A pending-pito + Montonio-istunto: estää kunnes Montonio vahvistaa päättymisen; sitten poisto
  i := i + 1; r := pg_temp.mk(v_slots[i], 'a@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select order_no into ono from booking.orders where id = o;
  select id into res1 from booking.reservations where order_id = o order by id limit 1;
  perform test.login(u_staff);
  r := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck((r ->> 'deletable')::boolean and (r ->> 'can_delete')::boolean and r -> 'blockers' = '[]'::jsonb
      and (r #>> '{effects,reservations}')::int = 1, 'A0 uusi maksamaton tilaus ilman maksuyritystä: poistettavissa ' || left(r::text, 160));
  perform test.service();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric; pid := (r ->> 'payment_id')::bigint;
  perform test.logout();
  perform test.login(u_admin);
  r := booking.admin_order_delete_check(o);
  r2 := booking.admin_delete_unpaid_order(o, 'testi');
  perform test.logout();
  perform pg_temp.ck(not (r ->> 'deletable')::boolean and pg_temp.codes(r -> 'blockers') = array['provider_session_unresolved']
      and r #>> '{blockers,0,sessions,0,ref}' = a1 and not (r #>> '{blockers,0,sessions,0,checkable}')::boolean and r ->> 'verify_order_token' is null
      and r2 ->> 'ok' = 'false' and r2 ->> 'code' = 'provider_session_unresolved',
      'A1 aloitettu Montonio-yritys (ennen HTTP-vastausta) estää ' || left(r2::text, 120));
  perform test.service();
  perform booking.montonio_payment_event(a1, 'CREATED', 'https://pay.montonio.com/session/t264', 'uuid-t264-a', '{}'::jsonb);
  perform test.logout();
  perform test.login(u_admin);
  r := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck(not (r ->> 'deletable')::boolean and (r #>> '{blockers,0,sessions,0,checkable}')::boolean and (r ->> 'verify_order_token')::uuid = tok,
      'A2 avattu istunto estää; tilan tarkistus (reconcile) tarjotaan ' || left(r::text, 200));
  -- Montonio vahvistaa: ABANDONED → applyVerified → outcome cancelled
  perform test.service();
  r := booking.montonio_payment_apply(a1, 'cancelled', null, jsonb_build_object('paymentStatus', 'ABANDONED'));
  perform test.logout();
  perform test.login(u_admin);
  r := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck((r ->> 'deletable')::boolean and (select outcome from booking.montonio_attempts where order_number = a1) = 'cancelled',
      'A3 vahvistettu ABANDONED: poistettavissa ' || left(r::text, 160));
  -- toinen yritys samalle tilaukselle → taas esto
  perform test.service();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  perform test.logout();
  perform test.login(u_admin);
  r2 := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and not (r2 ->> 'deletable')::boolean and pg_temp.codes(r2 -> 'blockers') = array['provider_session_unresolved'],
      'A4 uusi yritys estää uudelleen ' || left(r::text, 80));
  perform test.service();
  perform booking.montonio_payment_apply(r ->> 'order_number', 'cancelled', null, jsonb_build_object('paymentStatus', 'VOIDED'));
  perform test.logout();
  insert into booking.email_outbox(kind, order_id, dedupe_key, status, payload)
  values ('payment_link_reminder', o, 't264-a-' || o, 'pending', '{}'::jsonb);
  perform pg_temp.ck(pg_temp.listed('all', o) and pg_temp.listed('unpaid', o) and booking._res_active((select status from booking.reservations where id = res1), (select hold_expires_at from booking.reservations where id = res1)),
      'A5 ennen poistoa: listalla, varaus aktiivinen');
  perform test.login(u_staff);
  r := booking.admin_delete_unpaid_order(o, '  asiakas ei maksanut  ');
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and (select status = 'cancelled' and payment_status = 'unpaid' and archived_at is not null and archived_by = u_staff
                                               and archive_reason = 'asiakas ei maksanut' and internal_note like '%Poistettu maksamattomana: asiakas ei maksanut%'
                                               and external_meta -> 'booking_264' ->> 'prev_status' is not null from booking.orders where id = o),
      'A6 tilaus cancelled + arkistoitu + merkintä ' || left(r::text, 160));
  perform pg_temp.ck(not exists (select 1 from booking.reservations where order_id = o and status <> 'cancelled')
      and (select cancel_reason from booking.reservations where id = res1) = 'order_deleted_unpaid'
      and not exists (select 1 from booking.reservations x where x.order_id = o and booking._res_active(x.status, x.hold_expires_at)),
      'A7 varaukset cancelled, ei aktiivista kapasiteettia');
  perform pg_temp.ck(not exists (select 1 from booking.payments where order_id = o and status = 'pending')
      and not exists (select 1 from booking.email_outbox where order_id = o and status = 'pending')
      and exists (select 1 from booking.email_outbox where order_id = o and kind = 'payment_link_reminder' and status = 'skipped' and last_error like 'booking_264:%')
      and not exists (select 1 from booking.email_outbox where order_id = o and kind <> 'payment_link_reminder' and created_at >= (select archived_at from booking.orders where id = o)),
      'A8 ei pending-maksuja, jonossa olleet viestit skipped, ei uusia asiakasviestejä');
  perform pg_temp.ck((select count(*) from booking.audit_log where table_name = 'orders' and row_pk = o::text and action = 'ORDER_DELETED_UNPAID'
                        and actor = u_staff and old_data -> 'reservations' is not null) = 1, 'A9 audit kerran');
  perform pg_temp.ck(not pg_temp.listed('all', o) and not pg_temp.listed('unpaid', o) and not pg_temp.listed('cancelled', o)
      and pg_temp.listed('archived', o) and pg_temp.listed('all', o, ono::text)
      and (select (e ->> 'archived_at') is not null and not (e ->> 'archived_late_paid')::boolean from jsonb_array_elements(pg_temp.list('archived') -> 'rows') e where (e ->> 'order_id')::bigint = o),
      'A10 listat: piilossa all/unpaid/cancelled, näkyy archived + tarkka numerohaku');
  -- booking_270-yhteensopivuus: laskukentät säilyvät riveillä, invoiced-suodatin toimii, arkistoitu ei näy invoiced-listalla
  perform pg_temp.ck((select bool_and(e ? 'invoice_id' and e ? 'invoice_no' and e ? 'invoice_status' and e ? 'invoice_kind' and e ? 'archived_at' and e ? 'archived_late_paid')
                        from jsonb_array_elements(pg_temp.list('all', ono::text) -> 'rows') e)
      and jsonb_typeof(pg_temp.list('invoiced') -> 'rows') = 'array' and not pg_temp.listed('invoiced', o)
      and (select bool_and(e ? 'invoice_status') from jsonb_array_elements(pg_temp.list('archived') -> 'rows') e),
      'A10b booking_270 laskukentät + invoiced-suodatin säilyvät, arkistoitu ei invoiced-listalla');
  -- booking_277-yhteensopivuus: monivalinta (OR). Arkistoitu piilossa ilman 'archived'-valintaa, näkyy kun se on mukana.
  perform pg_temp.ck(not pg_temp.mlisted(array['paid','unpaid'], o) and not pg_temp.mlisted(array['unpaid','cancelled','invoiced'], o)
      and not pg_temp.mlisted(array['all'], o)
      and pg_temp.mlisted(array['unpaid','archived'], o) and pg_temp.mlisted(array['archived'], o),
      'A10c p_payment_filters: arkistoitu vain archived-valinnalla');
  perform test.login(u_admin);
  st := pg_temp.err($q$ select booking.admin_list_orders(p_payment_filters => array['paid','nope']) $q$);
  perform test.logout();
  perform pg_temp.ck(st like '%invalid_param%' or st like '%p_payment_filters%', 'A10d p_payment_filters hylkää tuntemattoman tilan ' || coalesce(st, ''));
  v_snap := pg_temp.snap(o);
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, 'toinen');
  r2 := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck((r ->> 'already')::boolean and pg_temp.snap(o) = v_snap and (r2 ->> 'archived')::boolean and not (r2 ->> 'deletable')::boolean,
      'A11 uusinta idempotentti, ei muutoksia ' || left(r::text, 100));
  -- maksun avaus poiston jälkeen estyy
  perform test.service();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and (select count(*) from booking.montonio_attempts m join booking.payments p on p.id = m.payment_id where p.order_id = o) = 2,
      'A12 poiston jälkeen maksua ei voi aloittaa ' || left(r::text, 100));
  -- myöhäinen maksu vanhalle (ABANDONED-merkitylle) yritykselle: booking_263-polku, näkyy listoilla
  perform test.service();
  r := booking.montonio_payment_apply(a1, 'paid', amt, jsonb_build_object('uuid', 'uuid-t264-a', 'paymentStatus', 'PAID'));
  perform test.logout();
  perform pg_temp.ck((r ->> 'order_cancelled')::boolean and (select status = 'cancelled' and archived_at is not null and internal_note like '%MAKSU PERUTULLE TILAUKSELLE%' from booking.orders where id = o)
      and (select status from booking.payments where id = pid) = 'paid' and (select count(*) from booking.receipts where payment_id = pid) = 1
      and not exists (select 1 from booking.reservations where order_id = o and status <> 'cancelled')
      and not exists (select 1 from booking.email_outbox where order_id = o and kind in ('receipt', 'order_confirmation') and status in ('pending', 'sending', 'sent')),
      'A13 myöhäinen maksu: 263-polku, kuitti kirjanpitoon, tilaus pysyy perutuksi+arkistoiduksi ' || left(r::text, 140));
  perform pg_temp.ck(pg_temp.listed('all', o) and pg_temp.listed('archived', o)
      and (select (e ->> 'archived_late_paid')::boolean from jsonb_array_elements(pg_temp.list('all') -> 'rows') e where (e ->> 'order_id')::bigint = o),
      'A14 myöhäinen maksu näkyy myös tavallisella listalla (archived_late_paid)');
  update booking.audit_log set at=now()-interval '1 day' where action='LATE_PAID_CANCELLED_ORDER' and row_pk=pid::text;
  perform test.login(u_admin); r := booking.admin_review_list(); perform test.logout();
  perform pg_temp.ck((select count(*) from jsonb_array_elements(r -> 'archived_late_payments') x where (x ->> 'payment_id')::bigint = pid) = 1, 'Q1 Tarkista contains one late payment even if callback transaction predates archive');
  perform test.login(u_text); v_review := booking.admin_review_list(); perform test.logout();
  perform pg_temp.ck(jsonb_array_length(v_review -> 'archived_late_payments')=0, 'Q1b weaker staff sees no financial late-payment data');
  perform booking.payment_mark_paid('montonio', a1, amt, '{}'::jsonb);
  perform test.login(u_admin); r := booking.admin_review_list(); perform test.logout();
  perform pg_temp.ck(jsonb_array_length(r -> 'archived_late_payments') = 1 and (select count(*) from booking.receipts where payment_id = pid) = 1, 'Q2 duplicate callback creates neither task nor receipt twice');
  perform test.login(u_admin);
  st := pg_temp.err(format('select booking.admin_ack_archived_late_payment(%s,%L)',pid,'x'));
  perform test.logout();
  perform pg_temp.ck(st like 'BK001:%', 'Q3 acknowledgment requires explanation');
  perform test.login(u_admin);
  r := booking.admin_ack_archived_late_payment(pid, 'Tarkistettu ja käsitelty paikallisessa testissä');
  r2 := booking.admin_ack_archived_late_payment(pid, 'Uusinta ei muuta alkuperäistä');
  v_review := booking.admin_review_list();
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and r2 ->> 'already' = 'true'
    and (select count(*) from booking.archived_late_payment_acks where payment_id=pid) = 1
    and (select count(*) from booking.audit_log where action='ARCHIVED_LATE_PAYMENT_ACKNOWLEDGED' and row_pk=pid::text)=1
    and jsonb_array_length(v_review -> 'archived_late_payments')=0, 'Q4 acknowledgment persistent idempotent removes task');
  perform test.login(u_text);
  st := pg_temp.err(format('select booking.admin_ack_archived_late_payment(%s,%L)',pid,'Ei oikeutta'));
  perform test.logout();
  perform pg_temp.ck(st like 'BK001:%', 'Q5 acknowledgment requires payments.manage');
  perform test.login(u_text); select count(*) into v_cnt from booking.archived_late_payment_acks; perform test.logout();
  perform pg_temp.ck(v_cnt=0,'Q5b weaker staff cannot read financial acknowledgment notes');
  perform test.login(u_admin);
  r := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck((r ->> 'late_paid')::boolean, 'A15 tarkistus: late_paid');
  perform pg_temp.ck(pg_temp.err(format('update booking.orders set status = %L where id = %s', 'confirmed', o)) like '23514:%',
      'A16 arkistoitua ei voi herättää (check-rajoite)');

  -- ===== B vahvistettu (pay_later/manuaalinen) maksamaton varaus + kalenterivienti
  i := i + 1; r := pg_temp.mk(v_slots[i], 'b@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select order_no into ono from booking.orders where id = o;
  -- fixture (LOCAL): tilaus vahvistettu, maksu paikan päällä (pending manuaalinen)
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o;
  update booking.order_items set hold_expires_at = null where order_id = o;
  update booking.orders set status = 'confirmed', confirmed_at = now() where id = o;
  insert into booking.payments(order_id, method, amount, status) values (o, 'pay_later', (select total_gross from booking.orders where id = o), 'pending') returning id into pid;
  update booking.orders set payment_status = 'unpaid' where id = o;
  perform pg_temp.ck(pg_temp.cal_elig(o) and position('o.payment_status not in (''pending'', ''failed'')' in pg_get_functiondef('booking._booking_calendar_desired()'::regprocedure)) > 0,
      'B0 ennen poistoa varaus täyttää kalenteriviennin ehdon');
  perform test.login(u_mgr);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and not exists (select 1 from booking.reservations where order_id = o and status <> 'cancelled')
      and (select status from booking.payments where id = pid) = 'cancelled'
      and (select reminders_handled_at is not null and raw -> 'booking_264' ->> 'prev_status' = 'pending' from booking.payments where id = pid)
      and (select status = 'cancelled' and payment_status = 'unpaid' and archive_reason is null from booking.orders where id = o),
      'B1 confirmed+pending pay_later: varaukset ja maksurivi perutaan ' || left(r::text, 120));
  perform pg_temp.ck(not pg_temp.cal_elig(o), 'B2 poiston jälkeen ei kalenterivientiehtoa täyttävää varausta (tapahtuma poistuu seuraavassa synkassa)');

  -- ===== P oikeudet
  i := i + 1; r := pg_temp.mk(v_slots[i], 'p@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  v_snap := pg_temp.snap(o);
  perform test.login(u_text);
  st := pg_temp.err(format('select booking.admin_delete_unpaid_order(%s, null)', o));
  perform test.logout();
  perform pg_temp.ck(st like 'BK001:%' and st not like '%no_error%' and pg_temp.snap(o) = v_snap, 'P1 henkilöstörooli ilman bookings/payments.manage: kielletty ' || st);
  perform test.login(test.mk_user('nobody@t264.example'));
  st := pg_temp.err(format('select booking.admin_order_delete_check(%s)', o));
  r := null;
  perform test.logout();
  perform pg_temp.ck(st like 'BK001:%', 'P2 ei-henkilökunta: tarkistus kielletty ' || st);
  perform test.anon();
  st := pg_temp.err(format('select booking.admin_delete_unpaid_order(%s, null)', o));
  perform test.logout();
  perform pg_temp.ck(st like '42501:%' and pg_temp.snap(o) = v_snap, 'P3 anon: ei suoritusoikeutta ' || st);
  delete from booking.role_permissions where role_code = 'staff' and permission = 'payments.manage';
  perform test.login(u_staff);
  st := pg_temp.err(format('select booking.admin_delete_unpaid_order(%s, null)', o));
  r := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck(st like 'BK001:%' and not (r ->> 'can_delete')::boolean and pg_temp.snap(o) = v_snap, 'P4 bookings.manage ilman payments.manage: kielletty ' || st);
  insert into booking.role_permissions(role_code, permission) values ('staff', 'payments.manage');
  perform test.login(u_admin);
  st := pg_temp.err(format('select booking.admin_delete_unpaid_order(%s, %L)', o, repeat('x', 501)));
  perform test.logout();
  perform pg_temp.ck(st like 'BK001:%invalid_param%' and pg_temp.snap(o) = v_snap, 'P5 liian pitkä syy hylätään ' || st);

  -- ===== X esteet: jokainen estää eikä muuta mitään
  -- X1 maksettu
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x1@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  perform test.service();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  perform booking.montonio_payment_apply(r ->> 'order_number', 'paid', (r ->> 'amount')::numeric, '{}'::jsonb);
  perform test.logout();
  v_snap := pg_temp.snap(o);
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['payment_status', 'receipts', 'settled_payment']
      and not (pg_temp.codes(r -> 'blockers') && array['provider_session_unresolved']) and pg_temp.snap(o) = v_snap,
      'X1 maksettu: estetty, ei muutoksia ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X2 osamaksu (vahvistettu tilaus, yksi maksu paid ja toinen pending)
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x2@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, amount, status, paid_at) values (o, 'cash', 1, 'paid', now());
  insert into booking.payments(order_id, method, amount, status) values (o, 'pay_later', 1, 'pending');
  update booking.orders set payment_status = 'partially_paid' where id = o;
  v_snap := pg_temp.snap(o);
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['payment_status', 'settled_payment'] and pg_temp.snap(o) = v_snap,
      'X2 osamaksu: estetty ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X3 hyvitetty maksu / hyvitysrivi
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x3@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, amount, status, paid_at, refunded_amount) values (o, 'cash', 5, 'refunded', now(), 5) returning id into pid;
  insert into booking.refunds(payment_id, order_id, amount, status) values (pid, o, 5, 'done');
  update booking.orders set payment_status = 'unpaid' where id = o;
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['refunds', 'settled_payment'],
      'X3 hyvitys: estetty ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X4 laskumaksu
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x4@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, amount, status) values (o, 'invoice', 5, 'pending');
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['invoice'], 'X4 lasku: estetty ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X5 lahjakorttimaksu
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x5@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  -- fixture (LOCAL): pelkkä maksurivi ilman lahjakorttia (validointitriggeri ohitetaan)
  set local session_replication_role = replica;
  insert into booking.payments(order_id, method, amount, status) values (o, 'gift_card', 5, 'pending');
  set local session_replication_role = origin;
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['gift_card'], 'X5 lahjakortti: estetty ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X6 vuosikortin osto
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x6@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select customer_id into c_id from booking.orders where id = o;
  insert into booking.annual_cards(customer_id, valid_from, valid_to, code, purchase_order_id) values (c_id, current_date, current_date + 365, 'T264-' || o, o);
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['annual_card'], 'X6 vuosikortti: estetty ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X7 kumppanilahjakortin lunastus auki
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x7@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.voucher_claims(order_id, code, source, status) values (o, 'T264X7', 'partner_other', 'open');
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['voucher_claim'], 'X7 lunastus: estetty ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X8 alkanut varaus
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x8@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  set local session_replication_role = replica;
  update booking.reservations set starts_at = now() - interval '10 minutes', ends_at = now() + interval '50 minutes' where order_id = o;
  set local session_replication_role = origin;
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['reservation_started'], 'X8 alkanut: estetty ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X9 Johku-tilaus
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x9@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  update booking.orders set external_source = 'johku', external_id = 't264-' || o where id = o;
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['external_order'], 'X9 ulkoinen: estetty ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X10 Visma Pay -viite (myös failed) / MobilePay pending viite / Montonio-viite ilman yritysriviä
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x10@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, provider, provider_ref, amount, status) values (o, 'visma_pay', 'visma_pay', 't264-visma', 5, 'failed');
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') = array['provider_session_unresolved'] and r #>> '{blockers,0,sessions,0,provider}' = 'visma_pay',
      'X10a visma failed-viite estää ' || left(r::text, 100));
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x10b@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, provider, provider_ref, amount, status) values (o, 'mobilepay', 'mobilepay', 't264-mp', 5, 'pending');
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and r #>> '{blockers,0,sessions,0,provider}' = 'mobilepay', 'X10b mobilepay pending-viite estää');
  -- X10c (booking_264 korjaus 2): paikallisesti cancelled/failed MobilePay-viite EI todista veloittamattomuutta → estää, ei muutoksia
  update booking.payments set status = 'cancelled' where order_id = o and provider = 'mobilepay';
  v_snap := pg_temp.snap(o);
  perform test.login(u_admin);
  r2 := booking.admin_order_delete_check(o);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(not (r2 ->> 'deletable')::boolean and r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') = array['provider_session_unresolved']
      and r #>> '{blockers,0,sessions,0,provider}' = 'mobilepay' and r #>> '{blockers,0,sessions,0,payment_status}' = 'cancelled'
      and pg_temp.snap(o) = v_snap, 'X10c mobilepay cancelled-viite estää eikä muuta mitään ' || left(r::text, 120));
  update booking.payments set status = 'failed' where order_id = o and provider = 'mobilepay';
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and r #>> '{blockers,0,sessions,0,payment_status}' = 'failed', 'X10c2 mobilepay failed-viite estää');
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x10c3@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, provider, amount, status, raw) values (o, 'mobilepay', 'mobilepay', 5, 'cancelled', '{"mobilepay": {"last_state": "ABORTED"}}');
  perform test.login(u_admin);
  r := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck(not (r ->> 'deletable')::boolean and r #>> '{blockers,0,sessions,0,provider}' = 'mobilepay',
      'X10c3 mobilepay raw-viite ilman provider_refiä (myös ABORTED-merkintä) estää');
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x10c4@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, provider, amount, status) values (o, 'mobilepay', 'mobilepay', 5, 'cancelled');
  perform test.login(u_admin);
  r := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck((r ->> 'deletable')::boolean, 'X10c4 mobilepay-rivi ilman mitään viitettä (ei koskaan lähetetty MobilePaylle) ei estä');
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x10d@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, provider, provider_ref, amount, status) values (o, 'montonio', 'montonio', 'sauna-t264-noatt', 5, 'cancelled');
  insert into booking.payments(order_id, method, provider, provider_ref, amount, status) values (o, 'montonio', 'montonio', 'dryrun-t264', 5, 'cancelled');
  perform pg_temp.ck((select count(*) from booking.montonio_attempts where order_number = 'sauna-t264-noatt') = 1, 'X10d0 viitteen asetus luo yritysrivin (trigger)');
  -- fixture (LOCAL): yritysrivi puuttuu (puolustava tapaus)
  delete from booking.montonio_attempts where order_number = 'sauna-t264-noatt';
  perform test.login(u_admin);
  r := booking.admin_order_delete_check(o);
  perform test.logout();
  perform pg_temp.ck(not (r ->> 'deletable')::boolean and jsonb_array_length(r #> '{blockers,0,sessions}') = 1 and (r #>> '{blockers,0,sessions,0,no_attempt_row}')::boolean,
      'X10d Montonio-viite ilman yritysriviä estää, dryrun ei ' || (r -> 'blockers')::text);
  -- X11 linkitetty lapsivaraus toisessa tilauksessa
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x11@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  i := i + 1; r := pg_temp.mk(v_slots[i], 'x11b@t264.example'); tok2 := (r ->> 'token')::uuid; o2 := pg_temp.oid(tok2);
  set local session_replication_role = replica;
  update booking.reservations set parent_reservation_id = (select min(id) from booking.reservations where order_id = o) where order_id = o2;
  set local session_replication_role = origin;
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') @> array['linked_reservations'], 'X11 lapsivaraus: estetty ' || array_to_string(pg_temp.codes(r -> 'blockers'), ','));
  -- X12 kirjanpitojono / kuitti / koulutus esteet ilman fixtureja: tarkistetaan että funktio viittaa tauluihin
  perform pg_temp.ck(pg_get_functiondef('booking._order_delete_blockers(bigint)'::regprocedure) ~ 'booking\.accounting_outbox'
      and pg_get_functiondef('booking._order_delete_blockers(bigint)'::regprocedure) ~ 'booking\.training_participants'
      and pg_get_functiondef('booking._order_delete_blockers(bigint)'::regprocedure) ~ 'booking\.gift_card_ledger'
      and pg_get_functiondef('booking._order_delete_blockers(bigint)'::regprocedure) ~ 'booking\.vc_difference_payments', 'X12 estefunktio kattaa kirjanpito/koulutus/lahjakortti/erotusmaksu');

  -- ===== L maksulinkki: poiston jälkeen linkki ei avaa maksua
  i := i + 1; r := pg_temp.mk(v_slots[i], 'l@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  ltok := gen_random_uuid();
  insert into booking.payments(order_id, method, provider, amount, status, link_token, link_expires_at, link_sent_at)
  values (o, 'montonio', 'montonio', (select total_gross from booking.orders where id = o), 'pending', ltok, now() + interval '7 days', now()) returning id into pid;
  perform test.login(u_admin);
  r := booking.admin_order_delete_check(o);
  r2 := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform test.service();
  r := booking.montonio_payment_prepare(null, ltok, 'paymentInitiation');
  perform test.logout();
  perform pg_temp.ck(r2 ->> 'ok' = 'true' and r ->> 'ok' = 'false' and (select status from booking.payments where id = pid) = 'cancelled'
      and not exists (select 1 from booking.montonio_attempts where payment_id = pid), 'L1 linkki ei avaa maksua poiston jälkeen ' || left(r::text, 100));
  perform pg_temp.ck(not booking._plr_is_tracked(pid) or (select reminders_handled_at is not null from booking.payments where id = pid), 'L2 muistutukset käsitelty');

  -- ===== R jo peruttu (asiakas perui) maksamaton tilaus arkistoidaan, peruutusaika säilyy
  i := i + 1; r := pg_temp.mk(v_slots[i], 'r@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select order_no into ono from booking.orders where id = o;
  perform test.service();
  perform booking.svc_cancel_reservation(ono, 't264 asiakas perui');
  perform test.logout();
  select count(*) into v_cnt from booking.orders where status = 'cancelled' and archived_at is null;
  perform pg_temp.ck(pg_temp.listed('cancelled', o), 'R0 peruttu näkyy cancelled-listalla ennen arkistointia');
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and (select archived_at is not null and cancelled_at <= archived_at and external_meta #>> '{booking_264,prev_status}' = 'cancelled' from booking.orders where id = o)
      and (select count(*) from booking.orders where status = 'cancelled' and archived_at is null) = v_cnt - 1,
      'R1 peruttu arkistoitu; muut perutut koskemattomia ' || left(r::text, 100));


  -- ===== E sähköposti: claim/send-vs-archive (yhden istunnon osat; rinnakkaisosuus t264_race.py)
  i := i + 1; r := pg_temp.mk(v_slots[i], 'e1@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.email_outbox(kind, order_id, dedupe_key, status, locked_at, attempts) values ('order_change', o, 't264-e1-sending', 'sending', now(), 1);
  v_snap := pg_temp.snap(o);
  perform test.login(u_admin);
  r2 := booking.admin_order_delete_check(o);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(not (r2 ->> 'deletable')::boolean and r ->> 'ok' = 'false' and pg_temp.codes(r -> 'blockers') = array['email_sending'] and pg_temp.snap(o) = v_snap,
      'E1 sending-rivi estää poiston (fail closed), ei muutoksia ' || left(r::text, 100));
  update booking.email_outbox set status = 'sent', sent_at = now() where order_id = o and dedupe_key = 't264-e1-sending';
  -- Only never-claimed attempts=0 may be skipped here. Real first failed/dead claims are E9/E10 race regressions.
  insert into booking.email_outbox(kind, order_id, dedupe_key, status, attempts, next_attempt_at) values ('payment_link', o, 't264-e1-failed', 'failed', 0, now() + interval '5 minutes');
  perform test.login(u_admin);
  r2 := booking.admin_order_delete_check(o);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck((r2 #>> '{effects,queued_emails}')::int >= 1 and r ->> 'ok' = 'true'
      and (select status from booking.email_outbox where dedupe_key = 't264-e1-failed') = 'skipped'
      and (select status from booking.email_outbox where dedupe_key = 't264-e1-sending') = 'sent',
      'E2 normal sent ei estä; vain koskaan claimaamaton failed/attempts0 → skipped ' || left(r::text, 100));
  insert into booking.email_outbox(kind, order_id, dedupe_key) values ('payment_link_reminder', o, 't264-e3-after');
  insert into booking.email_outbox(kind, order_id, dedupe_key) values ('order_confirmation', o, 't264-e3-conf');
  insert into booking.email_outbox(kind, order_id, dedupe_key) values ('event_message', o, 't264-e3-event');
  perform pg_temp.ck((select status from booking.email_outbox where dedupe_key = 't264-e3-after') = 'skipped'
      and (select status from booking.email_outbox where dedupe_key = 't264-e3-conf') = 'skipped'
      and (select last_error from booking.email_outbox where dedupe_key = 't264-e3-after') like 'booking_264:%'
      and (select status from booking.email_outbox where dedupe_key = 't264-e3-event') = 'pending',
      'E3 arkistoinnin jälkeen lisätty automaattinen asiakasviesti → skipped; muut lajit koskemattomia');
  perform test.service();
  perform booking.email_outbox_claim(50);
  perform test.logout();
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = o and kind <> 'event_message' and status in ('pending', 'sending', 'failed'))
      and (select status from booking.email_outbox where dedupe_key = 't264-e3-event') = 'sending',
      'E4 claim ei ota arkistoidun tilauksen skipped-rivejä');
  update booking.email_outbox set status = 'skipped' where dedupe_key = 't264-e3-event';
  i := i + 1; r := pg_temp.mk(v_slots[i], 'e5@t264.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.email_outbox(kind, order_id, dedupe_key) values ('payment_link_reminder', o, 't264-e5-normal');
  perform pg_temp.ck((select status from booking.email_outbox where dedupe_key = 't264-e5-normal') = 'pending', 'E5 arkistoimaton tilaus: trigger ei koske');
  update booking.email_outbox set status = 'skipped' where dedupe_key = 't264-e5-normal';

  -- ===== W jono: NORMAALI jonoilmoitus säilyy (Joonas 8.11.2026 klo 19.10 "Saa ilmoittaa jonottajille normaalisti"); ei estettä, ei vaimennusta
  -- W0 vertailu: tavallinen asiakasperuutus (svc_cancel_reservation) samanlaisessa vuorossa → jonottaja notified + waitlist_spot_freed
  r := pg_temp.mk_session(1, false); o := pg_temp.oid((r ->> 'token')::uuid);
  wid := pg_temp.wl((select min(id) from booking.reservations where order_id = o), 't264-w0@t264.example');
  perform pg_temp.ck(pg_temp.wl_state(wid) = 'waiting:0', 'W0a jonottaja odottaa ennen peruutusta');
  select order_no into ono from booking.orders where id = o;
  perform test.service(); perform booking.svc_cancel_reservation(ono, 't264 vertailu'); perform test.logout();
  v_base := pg_temp.wl_state(wid);
  perform pg_temp.ck(v_base = 'notified:1', 'W0 vertailu: tavallinen peruutus ilmoittaa jonottajalle ' || coalesce(v_base, 'null'));
  -- W1 poisto (arkistointi): sama lopputulos kuin tavallisessa peruutuksessa, poisto ei esty
  r := pg_temp.mk_session(1, false); o := pg_temp.oid((r ->> 'token')::uuid);
  wid := pg_temp.wl((select min(id) from booking.reservations where order_id = o), 't264-w1@t264.example');
  perform test.login(u_admin);
  r2 := booking.admin_order_delete_check(o);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck((r2 ->> 'deletable')::boolean and r ->> 'ok' = 'true' and pg_temp.wl_state(wid) = v_base,
      'W1 poisto ei esty jonottajasta ja jonottaja saa normaalin ilmoituksen kuten peruutuksessa ' || coalesce(pg_temp.wl_state(wid), 'null'));
  -- W2 vanhentunut pending-pito (hold_expires_at mennyt, ei vielä _expire_holds-ajoa) → poisto → normaali vapautumispolku
  r := pg_temp.mk_session(1, false); o := pg_temp.oid((r ->> 'token')::uuid);
  set local session_replication_role = replica;   -- LOCAL fixture: pito vanhentuneeksi ilman triggereitä
  update booking.reservations set status = 'pending', hold_expires_at = now() - interval '1 minute' where order_id = o;
  set local session_replication_role = origin;
  wid := pg_temp.wl((select min(id) from booking.reservations where order_id = o), 't264-w2@t264.example');
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and not exists (select 1 from booking.reservations where order_id = o and status <> 'cancelled')
      and pg_temp.wl_state(wid) = 'notified:1', 'W2 vanhentunut pending-pito: poisto ilmoittaa jonottajalle normaalisti ' || coalesce(pg_temp.wl_state(wid), 'null') || ' ' || left(r::text, 80));
  -- W3 rituaali (lapsivaraus samassa tilauksessa): molemmat perutaan, jonottaja saa normaalin ilmoituksen, poisto ei esty
  r := pg_temp.mk_session(1, true); o := pg_temp.oid((r ->> 'token')::uuid);
  perform pg_temp.ck((select count(*) from booking.reservations where order_id = o and parent_reservation_id is not null and product_id = 8) = 1, 'W3a rituaalin lapsivaraus samassa tilauksessa');
  wid := pg_temp.wl((select id from booking.reservations where order_id = o and parent_reservation_id is null), 't264-w3@t264.example');
  perform test.login(u_admin);
  r := booking.admin_delete_unpaid_order(o, null);
  perform test.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and jsonb_array_length(r -> 'cancelled_reservation_ids') = 2
      and not exists (select 1 from booking.reservations where order_id = o and status <> 'cancelled') and pg_temp.wl_state(wid) = 'notified:1',
      'W3 rituaali: vuoro + rituaali perutaan, jonottaja saa normaalin ilmoituksen ' || coalesce(pg_temp.wl_state(wid), 'null') || ' ' || left(r::text, 120));
  -- W4 sweep toimii ennallaan arkistointien jälkeen (ei virhettä, ei tuplailmoitusta jo ilmoitetuille)
  select count(*) into v_cnt from booking.email_outbox where kind = 'waitlist_spot_freed';
  perform test.service(); perform booking.waitlist_sweep(); perform test.logout();
  perform pg_temp.ck((select count(*) from booking.email_outbox where kind = 'waitlist_spot_freed') = v_cnt and pg_temp.wl_state(wid) = 'notified:1',
      'W4 waitlist_sweep ajautuu normaalisti, ei tuplailmoitusta');

  -- Histories must survive a change of provider.
  update booking.reservations set status='cancelled',cancel_reason='synthetic_fixture_cleanup' where order_id=o and status='pending';
  i := i + 1; r := pg_temp.mk(v_slots[i], 'history@t264.example'); o := pg_temp.oid((r ->> 'token')::uuid);
  insert into booking.payments(order_id,method,provider,amount,status,raw) values(o,'montonio','montonio',5,'pending','{"mobilepay":{"reference":"old-mp"}}') returning id into pid;
  perform test.login(u_admin); r := booking.admin_delete_unpaid_order(o,null); perform test.logout();
  perform pg_temp.ck(r ->> 'ok'='false' and pg_temp.codes(r -> 'blockers') @> array['provider_session_unresolved'], 'H1 raw MobilePay blocks after provider change');
  update booking.payments set raw='{}',provider='manual',provider_ref='legacy-unknown-reference' where id=pid;
  perform test.login(u_admin); r := booking.admin_delete_unpaid_order(o,null); perform test.logout();
  perform pg_temp.ck(r ->> 'ok'='false' and pg_temp.codes(r -> 'blockers') @> array['provider_session_unresolved'], 'H2 unknown non-dryrun reference fails closed');
  update booking.payments set provider='montonio',provider_ref='sauna-t264-contradiction' where id=pid;
  update booking.montonio_attempts set outcome='paid' where payment_id=pid;
  perform test.login(u_admin); r := booking.admin_delete_unpaid_order(o,null); perform test.logout();
  perform pg_temp.ck(r ->> 'ok'='false' and pg_temp.codes(r -> 'blockers') @> array['provider_session_unresolved'], 'H3 paid attempt with pending payment blocks');
  update booking.montonio_attempts set outcome='cancelled' where payment_id=pid;
  insert into booking.vismapay_attempts(order_number,payment_id,attempt,env) values('sauna-t264-old-visma',pid,1,'test');
  perform test.login(u_admin); r := booking.admin_delete_unpaid_order(o,null); perform test.logout();
  perform pg_temp.ck(r ->> 'ok'='false' and pg_temp.codes(r -> 'blockers') @> array['provider_session_unresolved'], 'H4 historical Visma attempt blocks regardless of current provider');

  update booking.reservations set status='cancelled',cancel_reason='synthetic_fixture_cleanup' where order_id=o and status='pending';
  i := i + 1; r := pg_temp.mk(v_slots[i],'lease@t264.example'); o := pg_temp.oid((r ->> 'token')::uuid);
  insert into booking.email_outbox(kind,order_id,dedupe_key,status,attempts,locked_at) values('order_change',o,'t264-lease','sending',1,now()-interval '20 minutes') returning id into pid;
  update booking.email_outbox set status='pending',locked_at=null where id=pid;
  update booking.email_outbox set status='sent',attempts=2 where id=pid;
  perform test.login(u_admin); r := booking.admin_delete_unpaid_order(o,null); perform test.logout();
  perform pg_temp.ck(r ->> 'ok'='false' and pg_temp.codes(r -> 'blockers') @> array['email_claim_uncertain']
    and (select archive_claim_uncertain from booking.email_outbox where id=pid), 'L2 reclaimed lease blocks after later sent status');
  insert into booking.email_outbox(kind,order_id,dedupe_key,status,attempts) values('order_change',o,'t264-insert-first-failed','failed',1);
  insert into booking.email_outbox(kind,order_id,dedupe_key,status,attempts) values('order_change',o,'t264-insert-first-dead','dead',1);
  perform pg_temp.ck((select bool_and(archive_claim_uncertain) from booking.email_outbox where dedupe_key in ('t264-insert-first-failed','t264-insert-first-dead')), 'L4 imported first failed/dead claim history also uncertain');
  update booking.email_outbox set archive_claim_uncertain=false where id=pid;
  perform pg_temp.ck((select archive_claim_uncertain from booking.email_outbox where id=pid), 'L3 uncertainty cannot be cleared by reset');

  update booking.reservations set status='cancelled',cancel_reason='synthetic_fixture_cleanup' where order_id=o and status='pending';
  i := i + 1; r := pg_temp.mk(v_slots[i],'reactivation@t264.example'); o := pg_temp.oid((r ->> 'token')::uuid);
  insert into booking.payments(order_id,method,provider,amount,status) values(o,'montonio','montonio',5,'pending') returning id into pid;
  perform test.login(u_admin); r := booking.admin_delete_unpaid_order(o,null); perform test.logout();
  perform pg_temp.ck(r ->> 'ok'='true','E6 archive fixture for reactivation');
  insert into booking.email_outbox(kind,order_id,payment_id,dedupe_key,status) values('payment_link',o,pid,'t264-reactivation','failed') returning id into wid;
  perform pg_temp.ck((select status='skipped' from booking.email_outbox where id=wid),'E7 failed INSERT with both FKs skipped');
  foreach st in array array['pending','failed','sending'] loop
    update booking.email_outbox set status=st where id=wid;
    perform pg_temp.ck((select status='skipped' from booking.email_outbox where id=wid),'E8 reactivation '||st||' skipped');
  end loop;

  insert into booking.email_outbox(kind,payment_id,dedupe_key,status) values('payment_link',pid,'t264-payment-only','pending') returning id into wid;
  perform pg_temp.ck((select status='skipped' from booking.email_outbox where id=wid),'E9 payment-only INSERT guarded');

  -- Synthetic LOCAL legacy cross-order expired pending child; never hosted.
  update booking.reservations set status='cancelled',cancel_reason='synthetic_fixture_cleanup' where order_id=o and status='pending';
  i := i + 1; r := pg_temp.mk(v_slots[i],'parent@t264.example'); o := pg_temp.oid((r ->> 'token')::uuid);
  update booking.reservations set status='cancelled',cancel_reason='synthetic_fixture_cleanup' where order_id=o and status='pending';
  i := i + 1; r := pg_temp.mk(v_slots[i],'foreign-child@t264.example'); o2 := pg_temp.oid((r ->> 'token')::uuid);
  select id into res1 from booking.reservations where order_id=o limit 1;
  set local session_replication_role=replica;
  update booking.reservations set parent_reservation_id=res1,hold_expires_at=now()-interval '1 minute' where order_id=o2;
  set local session_replication_role=origin;
  v_snap := pg_temp.snap(o2);
  perform test.login(u_admin); r := booking.admin_delete_unpaid_order(o,null); perform test.logout();
  perform pg_temp.ck(r ->> 'ok'='false' and pg_temp.codes(r -> 'blockers') @> array['linked_reservations'] and pg_temp.snap(o2)=v_snap,'X11 expired pending foreign child blocks without mutation');
  raise exception 'TESTRESULT pass=% fail=% %', (select count(*) from t264_r where ok), (select count(*) from t264_r where not ok),
    coalesce((select string_agg(label, ' | ') from t264_r where not ok), '');
end $t$;
rollback;
