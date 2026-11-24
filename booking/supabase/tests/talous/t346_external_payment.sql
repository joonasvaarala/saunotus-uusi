begin;
-- t346: ulkoisen maksun merkintä kirjaa maksun ja kuitin (booking_346, K4). Vaatii migraation 346 + fixtures/10_test_helpers.sql. Lopuksi rollback.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t346_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t346_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  perform test.service(); execute p_sql; perform test.logout(); return null;
exception when others then get stacked diagnostics d = pg_exception_detail; perform test.logout(); return coalesce(nullif(d, ''), sqlstate);
end $$;
-- vahvistettu, maksamaton varaus (kuten sähköpostitse tehty): palauttaa order_no
create function pg_temp.mk(p_rule bigint, p_date date, p_persons int, p_email text) returns bigint language plpgsql as $$
declare a jsonb; o booking.orders;
begin
  perform test.reset_rl();
  a := test.pub_book(p_rule, p_date, p_persons, p_email);
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  o := test.ord((a ->> 'token')::uuid);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id;
  update booking.orders set status = 'confirmed', confirmed_at = now() where id = o.id;
  update booking.payments set status = 'cancelled' where order_id = o.id and status = 'pending';
  return o.order_no;
end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 20); v_today date := (now() at time zone 'Europe/Helsinki')::date;
  n1 bigint; n2 bigint; n3 bigint; o1 booking.orders; v jsonb; e text; v_tot numeric; p booking.payments;
begin
  update booking.settings set value = '1000'::jsonb where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
  n1 := pg_temp.mk(v_rule, d, 3, 'k4a@t346.example');
  select * into o1 from booking.orders where order_no = n1; v_tot := o1.total_gross;
  perform pg_temp.ck(v_tot > 0 and o1.payment_status <> 'paid', 'A0: vahvistettu maksamaton tilaus ' || v_tot || ' ' || o1.payment_status);

  -- vanha kutsu ja puuttuvat tiedot
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L)', n1, 'pankkisiirto')) = 'external_payment_details_required', 'B1: vanha kutsu → external_payment_details_required');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, %L)', n1, 'pankkisiirto', 'botti')) = 'external_payment_details_required', 'B2: vanha 3 parametria → external_payment_details_required');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, null, %L, %L)', n1, 'x', v_today, 'bank_transfer')) = 'invalid_amount', 'B3: summa puuttuu → invalid_amount');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, 0, %L, %L)', n1, 'x', v_today, 'bank_transfer')) = 'invalid_amount', 'B4: 0 € → invalid_amount');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, 10, null, %L)', n1, 'x', 'bank_transfer')) = 'paid_on_required', 'B5: päivä puuttuu');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, 10, %L, %L)', n1, 'x', v_today + 1, 'bank_transfer')) = 'invalid_paid_on', 'B6: tuleva päivä');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, 10, %L, null)', n1, 'x', v_today)) = 'invalid_payment_method', 'B7: maksutapa puuttuu');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, 10, %L, %L)', n1, 'x', v_today, 'invoice')) = 'invalid_payment_method', 'B8: lasku ei käy');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, 10, %L, %L)', n1, 'x', v_today, 'cash')) = 'invalid_payment_method', 'B9: käteinen ei käy');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, %s, %L, %L)', n1, 'x', v_tot + 1, v_today, 'bank_transfer')) = 'amount_exceeds_unpaid', 'B10: yli maksamattoman');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, null, 10, %L, %L)', n1, v_today, 'bank_transfer')) = 'note_required', 'B11: syy puuttuu');

  -- onnistuu: payments-rivi, maksurivit, kuitti, ei sähköpostia
  perform test.service();
  v := booking.svc_mark_order_paid_external(n1, 'Pankkisiirto 20.11., viite 1234', v_tot, v_today - 4, 'bank_transfer', 'testi');
  perform test.logout();
  select * into p from booking.payments where id = (v ->> 'payment_id')::bigint;
  perform pg_temp.ck(p.status = 'paid' and p.amount = v_tot and p.method = 'bank_transfer' and p.provider = 'manual'
                     and (p.paid_at at time zone 'Europe/Helsinki')::date = v_today - 4, 'C1: maksurivi paid, summa, tapa, maksupäivä ' || v::text);
  perform pg_temp.ck((select sum(amount_gross) from booking.payment_lines where payment_id = p.id) = v_tot, 'C2: maksurivit = summa');
  perform pg_temp.ck(v ->> 'receipt_no' is not null and exists (select 1 from booking.receipts r where r.payment_id = p.id and r.kind = 'receipt'), 'C3: kuitti syntyi ' || coalesce(v ->> 'receipt_no', '-'));
  perform pg_temp.ck((select payment_status from booking.orders where order_no = n1) = 'paid', 'C4: tilaus paid');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox x where x.payment_id = p.id and x.status = 'pending'), 'C5: ei lähtevää asiakasviestiä');
  perform pg_temp.ck((select internal_note from booking.orders where order_no = n1) like '%ulkoinen maksu%bank_transfer%maksu #' || p.id || ']%', 'C6: sisäinen muistiinpano');
  perform pg_temp.ck(exists (select 1 from booking.audit_log a where a.action = 'SVC_MARK_ORDER_PAID_EXTERNAL' and a.new_data ->> 'payment_id' = p.id::text), 'C7: audit');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, 1, %L, %L)', n1, 'x', v_today, 'bank_transfer')) = 'already_paid', 'C8: jo maksettu');

  -- osamaksu
  n2 := pg_temp.mk(v_rule, d, 2, 'k4b@t346.example');
  perform test.service();
  v := booking.svc_mark_order_paid_external(n2, 'MobilePay osa', 10, v_today, 'mobilepay');
  perform test.logout();
  perform pg_temp.ck((select payment_status from booking.orders where order_no = n2) <> 'paid' and ((v -> 'balance' ->> 'unpaid')::numeric) > 0, 'D1: osamaksu, tilaus ei paid ' || (v -> 'balance')::text);

  -- 0 € tilaus estetty
  n3 := pg_temp.mk(v_rule, d, 1, 'k4c@t346.example');
  update booking.orders set total_gross = 0 where order_no = n3;
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L, 10, %L, %L)', n3, 'x', v_today, 'bank_transfer')) = 'nothing_to_pay', 'E1: 0 € tilaus → nothing_to_pay');

  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking.svc_mark_order_paid_external(bigint,text,numeric,date,text,text)', 'execute')
                     and not has_function_privilege('anon', 'booking.svc_mark_order_paid_external(bigint,text,numeric,date,text,text)', 'execute')
                     and has_function_privilege('service_role', 'booking.svc_mark_order_paid_external(bigint,text,numeric,date,text,text)', 'execute'), 'F1: vain service_role');
end $t$;
select ok, label from t346_r;
select count(*) filter (where ok) || '/' || count(*) as tulos from t346_r;
rollback;
