-- LOCAL ONLY – EI DEV/PROD. Numeroimaton late_paid_cancelled_order-luonnos (payment_mark_paid perutulle tilaukselle).
-- Ajo: cd booking/supabase/tests/checkout && psql -X -d <paikallinen testikanta> -f t_late_paid_cancelled_order.sql
-- Yksi transaktio, lopussa tahallinen TESTRESULT-poikkeus + rollback. Rinnakkaisuus: ../late_paid_race.py (erilliset yhteydet, baseline vs fix).
\set ON_ERROR_STOP on
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
\ir ../../unnumbered/late_paid_cancelled_order.sql
create temp table tlp_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into tlp_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.mk(p_start timestamptz, p_email text) returns jsonb language sql as $$
  select booking.public_create_treatment_booking(11, p_start, 2, 'Testi Asiakas', p_email, '+358401234567', false, 'fi', null, 'private', null, null) $$;
create function pg_temp.oid(p_tok uuid) returns bigint language sql as $$ select id from booking.orders where public_token = p_tok $$;
create function pg_temp.svc() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"service_role"}', true); execute 'set local role service_role'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.mails(p_o bigint, p_kind text) returns int language sql as $$
  select count(*)::int from booking.email_outbox where order_id = p_o and kind = p_kind and status in ('pending', 'sending', 'sent', 'dry_run') $$;

do $t$
declare
  r jsonb; r2 jsonb; tok uuid; o bigint; ono bigint; a1 text; a2 text; amt numeric; pid bigint; d text; st text;
  v_slots timestamptz[]; r_s record; v_cancel_at timestamptz; v_res_snap jsonb; v_claims0 bigint; v_res0 bigint; v_aud int; v_note text;
  ares bigint; aitem bigint; ahold timestamptz; mres bigint; rhold timestamptz; v_conf timestamptz;
begin
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"tlp"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = coalesce(booking.integration_config.settings, '{}'::jsonb) || '{"approved_by":"tlp"}'::jsonb;
  for r_s in select q.starts_at from (
      select * from booking.public_treatment_availability(11, current_date + 3, current_date + 16, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 17, current_date + 30, 2)) q
     where q.status = 'available' order by q.starts_at loop
    if v_slots is null or r_s.starts_at >= v_slots[cardinality(v_slots)] + interval '5 hours' then v_slots := array_append(v_slots, r_s.starts_at); end if;
  end loop;
  if v_slots is null or cardinality(v_slots) < 12 then raise exception 'TESTRESULT_ABORT vapaita hoitoaikoja %', coalesce(cardinality(v_slots), 0); end if;

  perform pg_temp.ck(md5(pg_get_functiondef('booking.montonio_payment_apply(text,text,numeric,jsonb)'::regprocedure)) = 'ef052d2d9baa94bbe8cc4a9e1784d0ed'
      and md5(pg_get_functiondef('booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure)) = '2f8a7e56ae9bb4e29f4025f91e7ea706',
      'S1 montonio/vismapay_payment_apply ennallaan');
  perform pg_temp.ck((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure)
      and has_function_privilege('service_role', 'booking.payment_mark_paid(text,text,numeric,jsonb)', 'execute')
      and not has_function_privilege('anon', 'booking.payment_mark_paid(text,text,numeric,jsonb)', 'execute')
      and not has_function_privilege('authenticated', 'booking.payment_mark_paid(text,text,numeric,jsonb)', 'execute'), 'S2 SECURITY DEFINER, search_path, ACL ennallaan');

  -- ===== A peruttu tilaus + myöhäinen Montonio paid
  r := pg_temp.mk(v_slots[1], 'a@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select order_no into ono from booking.orders where id = o;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric; pid := (r ->> 'payment_id')::bigint;
  perform booking.montonio_payment_event(a1, 'CREATED', 'https://pay.montonio.com/session/tlp', 'uuid-tlp-a', '{}'::jsonb);
  r2 := booking.svc_cancel_reservation(ono, 'tlp asiakas perui');
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and (select status from booking.orders where id = o) = 'cancelled', 'A0 tilaus peruttu ennen maksua ' || left(r::text, 80));
  select cancelled_at into v_cancel_at from booking.orders where id = o;
  select jsonb_agg(to_jsonb(x) - 'updated_at' order by x.id) into v_res_snap from booking.reservations x where x.order_id = o;
  select count(*) into v_res0 from booking.reservations;
  select count(*) into v_claims0 from booking.voucher_claims;
  perform pg_temp.svc();
  r := booking.montonio_payment_apply(a1, 'paid', amt, jsonb_build_object('uuid', 'uuid-tlp-a', 'paymentStatus', 'PAID'));
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'outcome' = 'paid' and (r ->> 'needs_manual_review')::boolean and (r ->> 'order_cancelled')::boolean, 'A1 tulos needs_manual_review + order_cancelled ' || left(r::text, 120));
  perform pg_temp.ck((select status = 'cancelled' and cancelled_at = v_cancel_at and confirmed_at is null from booking.orders where id = o), 'A2 tilaus pysyy cancelled, cancelled_at säilyy, ei confirmed_at');
  perform pg_temp.ck((select jsonb_agg(to_jsonb(x) - 'updated_at' order by x.id) from booking.reservations x where x.order_id = o) = v_res_snap
      and not exists (select 1 from booking.reservations where order_id = o and status <> 'cancelled'), 'A3 varaukset ennallaan (cancelled)');
  perform pg_temp.ck((select count(*) from booking.reservations) = v_res0 and (select count(*) from booking.voucher_claims) = v_claims0, 'A4 ei uusia varauksia eikä claimeja');
  perform pg_temp.ck((select status = 'paid' and amount = amt and paid_at is not null from booking.payments where id = pid)
      and (select count(*) from booking.payments where order_id = o and status = 'paid') = 1
      and (select payment_status from booking.orders where id = o) = 'paid', 'A5 maksu kirjattu kerran oikealla summalla, payment_status paid');
  perform pg_temp.ck((select count(*) from booking.receipts where payment_id = pid and kind = 'receipt') = 1, 'A6 kuitti kirjanpitoon kerran');
  perform pg_temp.ck(pg_temp.mails(o, 'order_confirmation') = 0 and pg_temp.mails(o, 'receipt') = 0
      and exists (select 1 from booking.email_outbox where order_id = o and kind = 'receipt' and status = 'skipped'), 'A7 ei tilausvahvistusta eikä kuittisähköpostia (receipt skipped)');
  perform pg_temp.ck(not exists (select 1 from booking.refunds where order_id = o), 'A8 ei automaattista palautusta');
  select internal_note into v_note from booking.orders where id = o;
  perform pg_temp.ck(v_note like '%MAKSU PERUTULLE TILAUKSELLE%' and (select count(*) from booking.audit_log where table_name = 'payments' and row_pk = pid::text and action = 'LATE_PAID_CANCELLED_ORDER') = 1,
      'A9 tarkistusmerkintä + audit kerran');
  -- duplikaatti-callback
  perform pg_temp.svc();
  r := booking.montonio_payment_apply(a1, 'paid', amt, jsonb_build_object('uuid', 'uuid-tlp-a', 'paymentStatus', 'PAID'));
  r2 := booking.payment_mark_paid('montonio', a1, amt, null);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'already')::boolean and (r2 ->> 'already')::boolean
      and (select count(*) from booking.receipts where order_id = o) = 1
      and (select count(*) from booking.email_outbox where order_id = o and kind in ('receipt', 'order_confirmation')) = 1
      and (select internal_note from booking.orders where id = o) = v_note
      and (select count(*) from booking.audit_log where row_pk = pid::text and action = 'LATE_PAID_CANCELLED_ORDER') = 1
      and (select status from booking.orders where id = o) = 'cancelled', 'A10 duplikaatti: ei tuplamaksua, kuittia, viestiä eikä merkintää');

  -- ===== B summaero perutulla tilauksella: ei kirjausta
  r := pg_temp.mk(v_slots[2], 'b@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select order_no into ono from booking.orders where id = o;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric; pid := (r ->> 'payment_id')::bigint;
  perform booking.svc_cancel_reservation(ono, 'tlp b');
  r := booking.montonio_payment_apply(a1, 'paid', amt + 1, '{}'::jsonb);
  begin
    perform booking.payment_mark_paid('montonio', a1, amt + 1, null); st := 'no_error';
  exception when others then get stacked diagnostics d = pg_exception_detail; st := sqlstate || ':' || coalesce(d, '');
  end;
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'code' = 'amount_mismatch' and st like 'BK001:%amount_mismatch%'
      and (select status from booking.payments where id = pid) = 'pending' and (select status from booking.orders where id = o) = 'cancelled'
      and not exists (select 1 from booking.receipts where order_id = o), 'B1 summaero: ei maksua, tilaus cancelled ' || st);

  -- ===== C normaali polku (pending pito → paid → confirmed)
  r := pg_temp.mk(v_slots[3], 'c@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric; pid := (r ->> 'payment_id')::bigint;
  r := booking.montonio_payment_apply(a1, 'paid', amt, '{}'::jsonb);
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and r -> 'needs_manual_review' is null and r -> 'order_cancelled' is null, 'C1 normaali tulos ' || left(r::text, 100));
  perform pg_temp.ck((select status = 'confirmed' and confirmed_at is not null and payment_status = 'paid' from booking.orders where id = o)
      and not exists (select 1 from booking.reservations where order_id = o and status <> 'confirmed'), 'C2 tilaus ja varaukset confirmed');
  perform pg_temp.ck(pg_temp.mails(o, 'order_confirmation') = 1, 'C3 tilausvahvistus jonossa ' || pg_temp.mails(o, 'order_confirmation'));
  perform pg_temp.ck((select count(*) from booking.receipts where payment_id = pid) = 1
      and (select string_agg(kind || '=' || status, ',' order by id) from booking.email_outbox where order_id = o) = 'receipt=skipped,order_confirmation=pending', 'C4 kuitti kerran, viestit kuten ennen (baseline receipt=skipped,order_confirmation=pending): ' || coalesce((select string_agg(kind || '=' || status, ',' order by id) from booking.email_outbox where order_id = o), '-'));
  perform pg_temp.ck(coalesce((select internal_note from booking.orders where id = o), '') not like '%PERUTULLE%', 'C5 ei tarkistusmerkintää');

  -- ===== D vanha yritys: peruttu tilaus, myöhäinen a1 paid, sitten a2 paid → duplicate
  r := pg_temp.mk(v_slots[4], 'd@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select order_no into ono from booking.orders where id = o;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric; pid := (r ->> 'payment_id')::bigint;
  perform pg_temp.logout();
  alter table booking.payments disable trigger payments_updated;
  update booking.payments set updated_at = now() - interval '3 minutes' where id = pid;
  alter table booking.payments enable trigger payments_updated;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a2 := r ->> 'order_number';
  perform booking.svc_cancel_reservation(ono, 'tlp d');
  r := booking.montonio_payment_apply(a1, 'paid', amt, '{}'::jsonb);
  r2 := booking.montonio_payment_apply(a2, 'paid', amt, '{}'::jsonb);
  perform pg_temp.logout();
  perform pg_temp.ck(a2 ~ '-a2$' and (r ->> 'order_cancelled')::boolean and r2 ->> 'code' = 'duplicate_paid'
      and (select count(*) from booking.payments where order_id = o and status = 'paid') = 1
      and (select count(*) from booking.receipts where order_id = o) = 1
      and (select status from booking.orders where id = o) = 'cancelled'
      and not exists (select 1 from booking.reservations where order_id = o and status <> 'cancelled')
      and pg_temp.mails(o, 'order_confirmation') = 0 and pg_temp.mails(o, 'receipt') = 0, 'D1 vanha yritys + duplikaatti: yksi maksu/kuitti, cancelled ' || left(r2::text, 80));

  -- ===== E muut palveluntarjoajat suoraan payment_mark_paid (visma_pay, mobilepay)
  r := pg_temp.mk(v_slots[5], 'e@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select order_no into ono from booking.orders where id = o;
  insert into booking.payments(order_id, method, provider, provider_ref, amount, status)
  values (o, 'visma_pay', 'visma_pay', 'tlp-visma-e', (select total_gross from booking.orders where id = o), 'pending') returning id into pid;
  perform pg_temp.svc();
  perform booking.svc_cancel_reservation(ono, 'tlp e');
  r := booking.payment_mark_paid('visma_pay', 'tlp-visma-e', null, null);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'order_cancelled')::boolean and (select status from booking.payments where id = pid) = 'paid'
      and (select status from booking.orders where id = o) = 'cancelled' and pg_temp.mails(o, 'order_confirmation') = 0, 'E1 visma_pay peruttu: kirjataan, ei herää');
  r := pg_temp.mk(v_slots[6], 'f@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, provider, provider_ref, amount, status)
  values (o, 'mobilepay', 'mobilepay', 'tlp-mp-f', (select total_gross from booking.orders where id = o), 'pending') returning id into pid;
  perform pg_temp.svc();
  r := booking.payment_mark_paid('mobilepay', 'tlp-mp-f', null, null);
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and r -> 'order_cancelled' is null and (select status from booking.orders where id = o) = 'confirmed'
      and not exists (select 1 from booking.reservations where order_id = o and status <> 'confirmed') and pg_temp.mails(o, 'order_confirmation') = 1, 'E2 mobilepay ei-peruttu: vahvistuu kuten ennen ' || left(r::text, 80));

  -- ===== F järjestys paid → cancel: maksettu tilaus perutaan normaalisti, maksu säilyy
  perform pg_temp.svc();
  select order_no into ono from booking.orders where id = o;
  perform booking.svc_cancel_reservation(ono, 'tlp f');
  perform pg_temp.logout();
  perform pg_temp.ck((select status from booking.orders where id = o) = 'cancelled' and (select status from booking.payments where id = pid) = 'paid'
      and not exists (select 1 from booking.reservations where order_id = o and status <> 'cancelled'), 'F1 paid→cancel: cancelled, maksu säilyy');

  -- ===== H peruttu tilaus + maksamaton pending-lisäys (rivipito): maksu ei vahvista lisäystä eikä pura pitoa (_refresh_order_payment ohitetaan)
  r := pg_temp.mk(v_slots[7], 'h@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  r := booking.montonio_payment_apply(r ->> 'order_number', 'paid', (r ->> 'amount')::numeric, '{}'::jsonb);
  perform pg_temp.logout();
  select id into mres from booking.reservations where order_id = o order by id limit 1;
  r := booking.public_add_to_order(tok, jsonb_build_array(jsonb_build_object('type', 'reservation', 'product_id', 11, 'persons', 1, 'start', v_slots[8])));
  select rv.id, rv.order_item_id, i.hold_expires_at into ares, aitem, ahold
    from booking.reservations rv join booking.order_items i on i.id = rv.order_item_id where rv.order_id = o and rv.id <> mres order by rv.id desc limit 1;
  perform pg_temp.svc();
  r2 := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r2 ->> 'order_number'; amt := (r2 ->> 'amount')::numeric; pid := (r2 ->> 'payment_id')::bigint;
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and ares is not null and ahold is not null and (select status from booking.reservations where id = ares) = 'pending' and a1 is not null,
      'H0 vahvistettu tilaus + pending-lisäys pidolla + lisäyksen maksu ' || left(r::text, 60) || ' ' || left(r2::text, 60));
  select hold_expires_at into rhold from booking.reservations where id = ares;
  -- fixture (LOCAL): tilaus perutaan suoraan, lisäys jää pending + pito (puolustava tapaus)
  update booking.reservations set status = 'cancelled', cancelled_at = now(), cancel_reason = 'tlp-h' where id = mres;
  update booking.orders set status = 'cancelled', cancelled_at = now() where id = o;
  select cancelled_at, confirmed_at into v_cancel_at, v_conf from booking.orders where id = o;
  perform pg_temp.svc();
  r := booking.montonio_payment_apply(a1, 'paid', amt, '{}'::jsonb);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'order_cancelled')::boolean and (select status from booking.orders where id = o) = 'cancelled', 'H1 tilaus pysyy cancelled ' || left(r::text, 100));
  perform pg_temp.ck((select status = 'pending' and hold_expires_at is not null from booking.reservations where id = ares)
      and (select hold_expires_at from booking.order_items where id = aitem) = ahold
      and (select hold_expires_at from booking.reservations where id = ares) = rhold
      and (select cancelled_at = v_cancel_at and confirmed_at is not distinct from v_conf from booking.orders where id = o), 'H2 pending-lisäys ei vahvistu, rivipito ennallaan');
  perform pg_temp.ck((select status from booking.payments where id = pid) = 'paid' and (select count(*) from booking.receipts where payment_id = pid) = 1
      and (select payment_status from booking.orders where id = o) = 'paid', 'H3 lisäyksen maksu kirjattu kerran, payment_status paid');

  -- ===== I email.receipt_auto_send = true: normaali polku jonottaa kuitin (pending), perutulla se merkitään skipped tämän korjauksen toimesta
  update booking.settings set value = 'true'::jsonb where key = 'email.receipt_auto_send';
  r := pg_temp.mk(v_slots[9], 'i@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select order_no into ono from booking.orders where id = o;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r ->> 'order_number'; amt := (r ->> 'amount')::numeric; pid := (r ->> 'payment_id')::bigint;
  perform booking.svc_cancel_reservation(ono, 'tlp i');
  r := booking.montonio_payment_apply(a1, 'paid', amt, '{}'::jsonb);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'order_cancelled')::boolean
      and (select count(*) from booking.email_outbox where payment_id = pid and kind = 'receipt' and status = 'skipped' and last_error like 'late_paid_cancelled_order:%') = 1
      and pg_temp.mails(o, 'receipt') = 0 and pg_temp.mails(o, 'order_confirmation') = 0, 'I1 auto_send=true: perutun kuittiviesti skipped (late_paid_cancelled_order)');
  r := pg_temp.mk(v_slots[10], 'i2@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  r := booking.montonio_payment_apply(r ->> 'order_number', 'paid', (r ->> 'amount')::numeric, '{}'::jsonb);
  perform pg_temp.logout();
  perform pg_temp.ck(pg_temp.mails(o, 'receipt') = 1 and pg_temp.mails(o, 'order_confirmation') = 1, 'I2 auto_send=true: normaali polku jonottaa kuitin + vahvistuksen kuten ennen');

  -- ===== K osittainen monivarausperuutus (svc, yksi varaus): tilaus ei peruttu → baseline-polku; peruttu varaus pysyy peruttuna
  r := pg_temp.mk(v_slots[11], 'k@tlp.example'); tok := (r ->> 'token')::uuid; o := pg_temp.oid(tok);
  select order_no into ono from booking.orders where id = o;
  perform pg_temp.svc();
  r := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  r := booking.montonio_payment_apply(r ->> 'order_number', 'paid', (r ->> 'amount')::numeric, '{}'::jsonb);
  perform pg_temp.logout();
  select id into mres from booking.reservations where order_id = o order by id limit 1;
  r := booking.public_add_to_order(tok, jsonb_build_array(jsonb_build_object('type', 'reservation', 'product_id', 11, 'persons', 1, 'start', v_slots[12])));
  select rv.id into ares from booking.reservations rv where rv.order_id = o and rv.id <> mres order by rv.id desc limit 1;
  perform pg_temp.svc();
  r2 := booking.montonio_payment_prepare(tok, null, 'paymentInitiation');
  a1 := r2 ->> 'order_number'; amt := (r2 ->> 'amount')::numeric; pid := (r2 ->> 'payment_id')::bigint;
  perform booking.svc_cancel_reservation(ono, 'tlp k osittainen', ares);
  r := booking.montonio_payment_apply(a1, 'paid', amt, '{}'::jsonb);
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and r -> 'order_cancelled' is null and (select status from booking.orders where id = o) = 'confirmed'
      and (select status from booking.reservations where id = mres) = 'confirmed' and (select status from booking.reservations where id = ares) = 'cancelled'
      and (select status from booking.payments where id = pid) = 'paid'
      and (select count(*) from booking.audit_log where row_pk = pid::text and action = 'LATE_PAID_CANCELLED_ORDER') = 0,
      'K1 osittainen peruutus: baseline-polku, peruttu varaus ei herää ' || left(r::text, 80));

  -- ===== J lukitus kuten baseline: ei NOWAITia, tilauslukko (FOR NO KEY UPDATE) vasta maksun UPDATEn (kuitti-triggerit) jälkeen
  perform pg_temp.ck(position('nowait' in lower(pg_get_functiondef('booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure))) = 0
      and pg_get_functiondef('booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure) ~ 'update booking\.payments set status = ''paid''[^;]*;\s+--[^\n]*\n\s+select o\.status into v_ostatus from booking\.orders o where o\.id = pay\.order_id for no key update;',
      'J1 ei NOWAITia; tilaus lukitaan maksun UPDATEn jälkeen FOR NO KEY UPDATE');

  raise exception 'TESTRESULT pass=% fail=% %', (select count(*) from tlp_r where ok), (select count(*) from tlp_r where not ok),
    coalesce((select string_agg(label, ' | ') from tlp_r where not ok), '');
end $t$;
rollback;
