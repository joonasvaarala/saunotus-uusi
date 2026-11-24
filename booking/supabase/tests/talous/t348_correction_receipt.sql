begin;
-- t348: oikaisukuitti (K1 loppuosa) ja hyvityskuittien summaraja. booking_348, 25.11.2026.
-- Vaatii migraatiot 346, 347 ja 348 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t348_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t348_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  execute p_sql; return null;
exception when others then get stacked diagnostics d = pg_exception_detail; return coalesce(nullif(d, ''), sqlstate);
end $$;
create function pg_temp.svc_err(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  perform test.service(); execute p_sql; perform test.logout(); return null;
exception when others then get stacked diagnostics d = pg_exception_detail; perform test.logout(); return coalesce(nullif(d, ''), sqlstate);
end $$;
create function pg_temp.vat(p_rep jsonb, p_key text, p_rate numeric, p_f text) returns numeric language sql as $$
  select coalesce((select (e ->> p_f)::numeric from jsonb_array_elements(p_rep -> p_key) e where (e ->> 'rate')::numeric = p_rate), 0) $$;
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
  u_adm uuid := test.mk_staff('adm@t348.example', 'admin'); u_st uuid := test.mk_staff('st@t348.example', 'staff');
  n1 bigint; o1 booking.orders; v jsonb; v_e text; p booking.payments; r1 booking.receipts; c1 booking.receipts; h1 booking.receipts; c2 booking.receipts;
  rep0 jsonb; rep1 jsonb; rep2 jsonb; l1 jsonb; g1 numeric; rate0 numeric; rate1 numeric; snap0 text; n_rc int; b jsonb; tx jsonb; csv jsonb;
begin
  update booking.settings set value = '1000'::jsonb where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
  n1 := pg_temp.mk(v_rule, d, 2, 'k1@t348.example');
  select * into o1 from booking.orders where order_no = n1;
  perform test.service();
  v := booking.svc_mark_order_paid_external(n1, 'Pankkisiirto, testi', o1.total_gross, v_today, 'bank_transfer', 'testi');
  perform test.logout();
  select * into p from booking.payments where id = (v ->> 'payment_id')::bigint;
  select * into r1 from booking.receipts where payment_id = p.id and kind = 'receipt';
  l1 := r1.snapshot -> 'lines' -> 0; g1 := (l1 ->> 'line_gross')::numeric; rate0 := (l1 ->> 'vat_rate')::numeric;
  rate1 := case when rate0 = 13.5 then 25.5 else 13.5 end;
  snap0 := md5(r1.snapshot::text || r1.text_body || r1.total_gross::text);
  perform pg_temp.ck(r1.id is not null and g1 > 0, 'A0: myyntikuitti ' || coalesce(r1.receipt_no, '-') || ' rivi ' || coalesce(l1::text, '-'));
  rep0 := booking._report_json(v_today, v_today, true, true);

  -- B: esikatselu ei luo kuittia
  select count(*) into n_rc from booking.receipts;
  perform test.service();
  v := booking.svc_issue_correction_receipt(r1.id, array[1], jsonb_build_array(jsonb_build_object('from_line', 1, 'vat_rate', rate1)), 'Väärä ALV-kanta', 'testi', true);
  perform test.logout();
  perform pg_temp.ck((v ->> 'dry_run')::boolean and (v ->> 'total_gross')::numeric = 0 and (select count(*) from booking.receipts) = n_rc, 'B1: dry run, summa 0, ei kuittia ' || (v - 'snapshot')::text);

  -- C: oikaisu ALV-kannasta
  perform test.service();
  v := booking.svc_issue_correction_receipt(r1.id, array[1], jsonb_build_array(jsonb_build_object('from_line', 1, 'vat_rate', rate1)), 'Väärä ALV-kanta', 'testi');
  perform test.logout();
  select * into c1 from booking.receipts where id = (v ->> 'receipt_id')::bigint;
  perform pg_temp.ck(c1.kind = 'correction' and c1.original_receipt_id = r1.id and c1.refund_id is null and c1.total_gross = 0 and c1.payment_id = p.id, 'C1: oikaisukuitti viittaa alkuperäiseen, summa 0');
  perform pg_temp.ck(c1.receipt_no like 'O-%' and c1.series = 'O', 'C2: sarja O ' || c1.receipt_no);
  perform pg_temp.ck((select md5(snapshot::text || text_body || total_gross::text) from booking.receipts where id = r1.id) = snap0, 'C3: alkuperäinen kuitti ennallaan');
  perform pg_temp.ck(jsonb_array_length(c1.snapshot -> 'lines') = 2
                     and (c1.snapshot -> 'lines' -> 0 ->> 'line_gross')::numeric = -g1 and (c1.snapshot -> 'lines' -> 0 ->> 'vat_rate')::numeric = rate0
                     and (c1.snapshot -> 'lines' -> 1 ->> 'line_gross')::numeric = g1 and (c1.snapshot -> 'lines' -> 1 ->> 'vat_rate')::numeric = rate1
                     and (c1.snapshot -> 'lines' -> 0 ->> 'quantity')::numeric = -(l1 ->> 'quantity')::numeric, 'C4: kumoava ja korjattu rivi');
  perform pg_temp.ck(c1.text_body like '%OIKAISUKUITTI ' || c1.receipt_no || '%' and c1.text_body like '%Alkuperäinen kuitti: ' || r1.receipt_no || '%' and c1.text_body like '%Oikaisun syy: Väärä ALV-kanta%' and c1.text_body like '%Muutos (ei maksua)%', 'C5: tekstikuitti');
  perform pg_temp.ck(c1.snapshot ->> 'document' = 'correction_receipt' and c1.snapshot ->> 'corrects' = 'receipt' and c1.snapshot -> 'reverses' = '[1]'::jsonb, 'C6: snapshot');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'RECEIPT_CORRECTION' and row_pk = c1.id::text), 'C7: audit');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox x where x.payment_id = p.id and x.kind not in ('receipt') and x.created_at >= c1.issued_at), 'C8: ei asiakasviestiä');
  perform pg_temp.ck(pg_temp.err(format('update booking.receipts set total_gross = 1 where id = %s', c1.id)) = 'receipt_immutable', 'C9: oikaisukuitti on muuttumaton');

  -- D: virheet
  perform pg_temp.ck(pg_temp.svc_err(format('select booking.svc_issue_correction_receipt(%s, array[1], null, %L)', r1.id, 'Uudestaan')) = 'line_already_corrected', 'D1: sama rivi kahdesti');
  perform pg_temp.ck(pg_temp.svc_err(format('select booking.svc_issue_correction_receipt(%s, array[1], null, %L)', c1.id, 'Oikaisun oikaisu')) = 'invalid_param', 'D2: oikaisua ei oikaista');
  perform pg_temp.ck(pg_temp.svc_err(format('select booking.svc_issue_correction_receipt(%s, null, %L::jsonb, %L)', r1.id, '[{"description":"Lisä","quantity":1,"unit_gross":1000,"vat_rate":25.5}]', 'Liikaa')) = 'invalid_correction', 'D3: yli maksetun');
  perform pg_temp.ck(pg_temp.svc_err(format('select booking.svc_issue_correction_receipt(%s, array[9], null, %L)', r1.id, 'Väärä rivi')) = 'invalid_param', 'D4: rivinumero');
  perform pg_temp.ck(pg_temp.svc_err(format('select booking.svc_issue_correction_receipt(%s, null, null, %L)', r1.id, 'Tyhjä')) = 'invalid_param', 'D5: ei rivejä');
  perform pg_temp.ck(pg_temp.svc_err(format('select booking.svc_issue_correction_receipt(%s, array[1], null, %L)', r1.id, 'x')) = 'invalid_param', 'D6: syy puuttuu');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking.svc_issue_correction_receipt(bigint,integer[],jsonb,text,text,boolean)', 'execute')
                     and not has_function_privilege('anon', 'booking.admin_issue_correction_receipt(bigint,integer[],jsonb,text,boolean)', 'execute')
                     and not has_function_privilege('authenticated', 'booking._issue_correction_receipt(bigint,integer[],jsonb,text,text,boolean)', 'execute'), 'D7: oikeudet');
  perform test.login(u_st);
  v_e := pg_temp.err(format('select booking.admin_issue_correction_receipt(%s, null, %L::jsonb, %L, true)', r1.id, '[{"description":"Lisä","quantity":1,"unit_gross":0,"vat_rate":25.5}]', 'Henkilökunta'));
  perform test.logout();
  perform pg_temp.ck(v_e = 'forbidden', 'D8: henkilökunta ilman payments.refund → forbidden (' || coalesce(v_e, 'ok') || ')');
  perform test.login(u_adm);
  v_e := pg_temp.err(format('select booking.admin_issue_correction_receipt(%s, null, %L::jsonb, %L, true)', r1.id, '[{"description":"Lisä","quantity":1,"unit_gross":0,"vat_rate":25.5}]', 'Ylläpitäjä'));
  perform test.logout();
  perform pg_temp.ck(v_e is null, 'D9: ylläpitäjä voi esikatsella (' || coalesce(v_e, 'ok') || ')');

  -- E: raportti etumerkillä
  rep1 := booking._report_json(v_today, v_today, true, true);
  perform pg_temp.ck((rep1 #>> '{totals,gross}')::numeric = (rep0 #>> '{totals,gross}')::numeric and (rep1 #>> '{totals,receipts}')::int = (rep0 #>> '{totals,receipts}')::int
                     and (rep1 #>> '{totals,correction_receipts}')::int = 1, 'E1: brutto ja kuittimäärä ennallaan, oikaisuja 1');
  perform pg_temp.ck(pg_temp.vat(rep1, 'by_vat', rate0, 'gross') = pg_temp.vat(rep0, 'by_vat', rate0, 'gross') - g1
                     and pg_temp.vat(rep1, 'by_vat', rate1, 'gross') = pg_temp.vat(rep0, 'by_vat', rate1, 'gross') + g1, 'E2: by_vat siirtyy kannalta toiselle');
  perform pg_temp.ck(pg_temp.vat(rep1, 'by_vat_sales', rate1, 'gross') = pg_temp.vat(rep0, 'by_vat_sales', rate1, 'gross') + g1, 'E3: by_vat_sales');
  perform pg_temp.ck((rep1 #>> '{reconciliation,difference}')::numeric = (rep0 #>> '{reconciliation,difference}')::numeric
                     and (rep1 #>> '{reconciliation,methods_difference}')::numeric = (rep0 #>> '{reconciliation,methods_difference}')::numeric, 'E4: täsmäytys ennallaan');
  perform pg_temp.ck((rep1 #>> '{totals,vat_after_refunds}')::numeric = (rep0 #>> '{totals,vat_after_refunds}')::numeric - round(g1 * rate0 / (100 + rate0), 2) + round(g1 * rate1 / (100 + rate1), 2), 'E5: ALV muuttuu oikaisun verran');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(rep1 -> 'receipts') x where x ->> 'receipt_no' = c1.receipt_no and x ->> 'kind' = 'correction' and x ->> 'corrects' = 'receipt'), 'E6: kuittilistassa kind correction');
  perform pg_temp.ck((select (x ->> 'payments')::int from jsonb_array_elements(rep1 -> 'by_method') x where x ->> 'method' = 'bank_transfer') = (select (x ->> 'payments')::int from jsonb_array_elements(rep0 -> 'by_method') x where x ->> 'method' = 'bank_transfer'), 'E7: maksujen määrä ennallaan');
  tx := booking._report_tx(v_today, v_today);
  perform pg_temp.ck((select count(*) from jsonb_array_elements(tx) x where x ->> 'voucher' = c1.receipt_no and x ->> 'doc_kind' = 'correction' and x ->> 'kind' = 'sale') = 2
                     and (select sum((x ->> 'gross')::numeric) from jsonb_array_elements(tx) x where x ->> 'voucher' = c1.receipt_no) = 0, 'E8: tapahtumaraportissa 2 oikaisuriviä (laji sale, summa 0)');
  perform test.login(u_adm);
  csv := to_jsonb(booking.admin_report_csv(v_today, v_today, 'vat'));
  perform test.logout();
  perform pg_temp.ck(csv::text like '%' || c1.receipt_no || '%oikaisu%', 'E9: ALV-CSV: tyyppi oikaisu');
  perform test.login(u_adm);
  csv := to_jsonb(booking.admin_report_csv(v_today, v_today, 'transactions'));
  perform test.logout();
  perform pg_temp.ck(csv::text like '%' || c1.receipt_no || '%oikaisu%', 'E9b: tapahtuma-CSV: tyyppi oikaisu');
  b := booking._procountor_daily_build(v_today, rep1, '{"vat_status":1}'::jsonb);
  perform pg_temp.ck(b #>> '{request,name}' like '%oikaisut ' || c1.receipt_no || '%' and b #>> '{receipt_range,corrections_from}' = c1.receipt_no, 'E10: päivätositteen nimessä oikaisut ' || coalesce(b #>> '{request,name}', 'null'));
  b := booking._procountor_daily_build(v_today, jsonb_build_object('totals', jsonb_build_object('receipts', 0, 'refund_receipts', 0, 'correction_receipts', 1), 'by_vat', '[]'::jsonb, 'by_method', '[]'::jsonb), '{"vat_status":1}'::jsonb);
  perform pg_temp.ck(not coalesce((b ->> 'empty')::boolean, true), 'E11: pelkkä oikaisu ei ole tyhjä päivä');

  -- G: hyvityskuitit ja raja
  perform test.login(u_adm);
  v := booking.admin_refund(p.id, 10, 'Osa palautetaan', null, true);
  perform test.logout();
  select * into h1 from booking.receipts where payment_id = p.id and kind = 'refund_receipt';
  select * into p from booking.payments where id = p.id;
  perform pg_temp.ck(h1.id is not null and h1.total_gross = -10 and p.refunded_amount = 10, 'G1: hyvityskuitti −10, refunded 10 ' || coalesce(v::text, ''));
  perform pg_temp.ck(pg_temp.svc_err(format('select booking.svc_issue_correction_receipt(%s, null, %L::jsonb, %L)', h1.id,
                       jsonb_build_array(jsonb_build_object('from_line', 1, 'quantity', 1, 'unit_gross', -5))::text, 'Lisähyvitys')) = 'refund_receipts_exceed_refunded', 'G2: hyvityskuittien summa > refunded_amount estetään');
  perform pg_temp.ck(pg_temp.err(format($q$insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, refund_id, original_receipt_id, total_gross, snapshot, text_body)
                       values ('H-T348-1', 'refund_receipt', 'HT', 2099, 1, %s, %s, %s, %s, -1, '{}'::jsonb, 'x')$q$, o1.id, p.id, (select refund_id from booking.receipts where id = h1.id), r1.id)) = 'refund_receipts_exceed_refunded', 'G3: suora lisäys estetään');
  rep1 := booking._report_json(v_today, v_today, true, true);
  perform test.service();
  v := booking.svc_issue_correction_receipt(h1.id, array[1], null, 'Hyvitys kirjattiin väärin', 'testi');
  perform test.logout();
  select * into c2 from booking.receipts where id = (v ->> 'receipt_id')::bigint;
  perform pg_temp.ck(c2.total_gross = 10 and c2.snapshot ->> 'corrects' = 'refund_receipt', 'G4: hyvityskuitin kumoava oikaisu +10');
  rep2 := booking._report_json(v_today, v_today, true, true);
  perform pg_temp.ck((rep2 #>> '{totals,refunds_gross}')::numeric = (rep1 #>> '{totals,refunds_gross}')::numeric + 10, 'G5: hyvitykset pienenevät 10 € ' || (rep1 #>> '{totals,refunds_gross}') || ' → ' || (rep2 #>> '{totals,refunds_gross}'));
  perform pg_temp.ck(coalesce((select sum((e ->> 'gross')::numeric) from jsonb_array_elements(rep2 -> 'by_vat_refunds') e), 0) = coalesce((select sum((e ->> 'gross')::numeric) from jsonb_array_elements(rep1 -> 'by_vat_refunds') e), 0) - 10
                     and coalesce((select sum((e ->> 'gross')::numeric) from jsonb_array_elements(rep1 -> 'by_vat_refunds') e), 0) = 10, 'G6: by_vat_refunds positiivinen ja pienenee oikaisulla (ei abs)');
  perform pg_temp.ck(coalesce((select sum((e ->> 'gross')::numeric) from jsonb_array_elements(rep2 -> 'refunds_by_product') e), 0) = 0
                     and coalesce((select sum((e ->> 'quantity')::numeric) from jsonb_array_elements(rep2 -> 'refunds_by_product') e), 0) = 0, 'G7: refunds_by_product nollautuu');
  perform pg_temp.ck(pg_temp.svc_err(format('select booking.svc_issue_correction_receipt(%s, null, %L::jsonb, %L)', h1.id,
                       jsonb_build_array(jsonb_build_object('from_line', 1, 'quantity', -1))::text, 'Positiivinen')) = 'invalid_correction', 'G8: hyvityskuitin summa ei voi olla positiivinen');
  perform test.service();
  v := booking.svc_issue_correction_receipt(h1.id, null, jsonb_build_array(jsonb_build_object('from_line', 1)), 'Hyvitys takaisin oikein', 'testi');
  perform test.logout();
  perform pg_temp.ck((v ->> 'total_gross')::numeric = -10, 'G9: uusi hyvitysrivi enintään refunded_amount sallitaan');
end $t$;
do $r$
declare n int; f text;
begin
  select count(*), string_agg(label, ' | ') filter (where not ok) into n, f from t348_r;
  raise notice 'TESTRESULT pass=% fail=% %', n - (select count(*) from t348_r where not ok), (select count(*) from t348_r where not ok), coalesce(f, ':: ALL OK');
end $r$;
rollback;
