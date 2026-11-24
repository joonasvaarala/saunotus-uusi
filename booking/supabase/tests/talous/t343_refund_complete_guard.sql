begin;
-- t343: hyvityksen valmistuminen ja hyvityskuitit (booking_343, 24.11.2026).
-- Vaatii migraation 343 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback. Montonio mockattu: eteneminen
-- montonio_refund_claim/stamp/complete-funktioilla. Tapaus "maksu 1213": 18 € kesken + 162 € valmis, jonka kuitti (−180 €) kattaa molemmat.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t343_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t343_r values (coalesce(p_ok, false), p_label) $$;
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
-- tilaus maksettuna Montoniolla (kuten t305): palauttaa tilauksen ja maksun
create function pg_temp.mk(p_adm uuid, p_rule bigint, p_date date, p_persons int, p_email text, out o_id bigint, out p_id bigint) language plpgsql as $$
declare a jsonb; v_unpaid numeric;
begin
  perform test.reset_rl();
  a := test.pub_book(p_rule, p_date, p_persons, p_email);
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  o_id := (test.ord((a ->> 'token')::uuid)).id;
  select (booking._order_balance(o_id) ->> 'unpaid')::numeric into v_unpaid;
  perform test.login(p_adm);
  perform booking.admin_record_payment(o_id, 'card_terminal', v_unpaid, null, null);
  perform test.logout();
  update booking.payments set provider = 'montonio', method = 'montonio', raw = '{"order_uuid":"x","env":"test"}'::jsonb
   where order_id = o_id and method = 'card_terminal' and gift_card_id is null returning id into p_id;
end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 20);
  u_adm uuid := test.mk_staff('adm@t343.example', 'admin');
  v jsonb; o1 bigint; p1 bigint; o2 bigint; p2 bigint; o3 bigint; p3 bigint;
  a1 numeric; l1 bigint; r68 bigint; r69 bigint; h69 bigint; rb1 bigint; rb2 bigint; rc1 bigint;
  e0 int; n0 int;
begin
  update booking.settings set value = '1000'::jsonb where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'montonio';

  -- apufunktio: rivien skaalaus summaan
  v := booking._refund_scaled_lines('[{"payment_line_id":1,"amount":100},{"payment_line_id":2,"amount":80,"persons":2}]'::jsonb, 162);
  perform pg_temp.ck((select sum((e ->> 'amount')::numeric) from jsonb_array_elements(v) e) = 162
                     and (select (e ->> 'amount')::numeric from jsonb_array_elements(v) e where (e ->> 'payment_line_id') = '2') = 72
                     and not exists (select 1 from jsonb_array_elements(v) e where e ? 'persons'), 'S0: rivit skaalataan 162 €:oon (90 + 72) ' || v::text);
  perform pg_temp.ck(booking._refund_scaled_lines('[{"payment_line_id":1,"amount":18}]'::jsonb, 18) = '[{"payment_line_id":1,"amount":18}]'::jsonb, 'S0b: täsmäävät rivit ennallaan');

  -- tilaus 1 (vastaa maksua 1213): yksi maksurivi
  select * into o1, p1 from pg_temp.mk(u_adm, v_rule, d, 3, 'a@t343.example');
  select amount into a1 from booking.payments where id = p1;
  select id into l1 from booking.payment_lines where payment_id = p1 order by amount_gross desc limit 1;
  perform pg_temp.ck((select count(*) from booking.payment_lines where payment_id = p1) = 1 and a1 > 18, 'A0: yksirivinen maksu ' || a1);

  -- hyvitys "68": 18 € kesken (processing)
  v := pg_temp.run('user', format('select booking.admin_refund(%s, 18, %L)', p1, 'Alekoodi'), u_adm);
  r68 := (v ->> 'refund_id')::bigint;
  perform booking.montonio_refund_claim(r68, 1);
  perform booking.montonio_refund_stamp(r68, 'rf-t343-68', 'PENDING', '{"status":"PENDING"}'::jsonb);
  perform pg_temp.ck((select status = 'processing' and lines = jsonb_build_array(jsonb_build_object('payment_line_id', l1, 'amount', 18)) from booking.refunds where id = r68), 'A1: 18 € processing ' || v::text);

  -- juurisyy: loppusumma hyvitetään kesken olevan hyvityksen aikana → rivit = summa (ennen: koko rivi 180 €)
  v := pg_temp.run('user', format('select booking.admin_refund(%s, %s, %L)', p1, a1 - 18, 'Olikin lahjakortti'), u_adm);
  r69 := (v ->> 'refund_id')::bigint;
  perform pg_temp.ck(r69 is not null and (select sum((e ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(f.lines) e where f.id = r69) = a1 - 18,
                     'A2: loppuhyvityksen rivit = summa ' || v::text);

  -- vartija: rivien summa ≠ summa, ja rivin ylitys kesken olevat mukaan lukien
  v := pg_temp.run('service', format('insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines) values (%s, %s, 10, %L, %L, %L, %L) returning to_jsonb(id)',
                   p1, o1, 'x', 'requested', 'manual', jsonb_build_array(jsonb_build_object('payment_line_id', l1, 'amount', 12))));
  perform pg_temp.ck(v ? 'err' and v ->> 'msg' ilike '%rivien summa%', 'G1: rivien summa ≠ summa hylätään ' || v::text);
  v := pg_temp.run('service', format('insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines) values (%s, %s, 1, %L, %L, %L, %L) returning to_jsonb(id)',
                   p1, o1, 'x', 'requested', 'manual', jsonb_build_array(jsonb_build_object('payment_line_id', l1, 'amount', 1))));
  perform pg_temp.ck(v ? 'err' and v ->> 'err' ilike '%amount_exceeds_refundable%' or v ->> 'msg' ilike '%ylittää%', 'G2: rivin ylitys (kesken olevat mukana) hylätään ' || v::text);

  -- tuotannon tila (maksu 1213, rivi 1037, hyvitykset 68/69, kuitti H-2026-000006): 69 valmis, rivi = koko rivi, kuitti −koko maksu.
  -- Ennen booking_343:a 68:n valmistuminen kaatui payment_lines_check-virheeseen (webhook 503, Montonio yrittää uudelleen).
  update booking.refunds set status = 'done', provider_status = 'refunded', done_at = now(),
         lines = jsonb_build_array(jsonb_build_object('payment_line_id', l1, 'amount', a1)) where id = r69;
  update booking.payment_lines set refunded_gross = a1 where id = l1;
  update booking.payments set refunded_amount = a1 - 18, status = 'partially_refunded' where id = p1;
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, refund_id, issued_at, total_gross, snapshot, text_body)
  values ('H-2099-000343', 'refund_receipt', 'H', 2099, 343, o1, p1, r69, now(), -a1, jsonb_build_object('document', 'refund_receipt', 'lines', '[]'::jsonb, 'vat', '[]'::jsonb), 't343') returning id into h69;

  -- 68 valmistuu: refunded_amount = maksu (ei yli), rivi ei nouse, ei kuittia, ei viestiä, viittaus kattavaan kuittiin
  select count(*) into e0 from booking.email_outbox where kind = 'refund_receipt';
  select count(*) into n0 from booking.receipts where payment_id = p1;
  v := booking.montonio_refund_complete(r68, 'rf-t343-68', '{"refundStatus":"SUCCESSFUL"}'::jsonb);
  perform pg_temp.ck((select status = 'done' and covered_by_receipt_id = h69 from booking.refunds where id = r68), 'B1: 68 valmis, katettu kuitilla ' || v::text);
  perform pg_temp.ck((select refunded_amount = a1 and status = 'refunded' from booking.payments where id = p1), 'B2: refunded_amount = maksun summa');
  perform pg_temp.ck((select refunded_gross = a1 from booking.payment_lines where id = l1), 'B3: maksurivi ei ylity');
  perform pg_temp.ck((select count(*) from booking.receipts where payment_id = p1) = n0, 'B4: ei uutta hyvityskuittia');
  perform pg_temp.ck((select count(*) from booking.email_outbox where kind = 'refund_receipt') = e0, 'B5: ei kuittiviestiä');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where table_name = 'refunds' and row_pk = r68::text and action = 'REFUND_RECEIPT_COVERED'), 'B6: audit REFUND_RECEIPT_COVERED');
  v := booking.montonio_refund_complete(r68, 'rf-t343-68', '{"refundStatus":"SUCCESSFUL"}'::jsonb);
  perform pg_temp.ck((v ->> 'already')::boolean, 'B7: toistuva ilmoitus ei muuta mitään ' || v::text);

  -- tilaus 2: tavallinen osahyvitys → kuitti ja viesti; ennalta linkitetty hyvitys → ei kuittia
  select * into o2, p2 from pg_temp.mk(u_adm, v_rule, d, 2, 'b@t343.example');
  v := pg_temp.run('user', format('select booking.admin_refund(%s, 20, %L)', p2, 'Osahyvitys'), u_adm);
  rb1 := (v ->> 'refund_id')::bigint;
  perform booking.montonio_refund_claim(rb1, 1);
  perform booking.montonio_refund_stamp(rb1, 'rf-t343-b1', 'PENDING', null);
  select count(*) into e0 from booking.email_outbox where kind = 'refund_receipt';
  v := booking.montonio_refund_complete(rb1, 'rf-t343-b1', '{"refundStatus":"SUCCESSFUL"}'::jsonb);
  select id into rc1 from booking.receipts where refund_id = rb1;
  perform pg_temp.ck(rc1 is not null and (select total_gross = -20 from booking.receipts where id = rc1)
                     and (select covered_by_receipt_id is null from booking.refunds where id = rb1), 'C1: tavallinen hyvitys → kuitti −20 € ' || v::text);
  perform pg_temp.ck((select count(*) from booking.email_outbox where kind = 'refund_receipt') = e0 + 1, 'C2: tavallinen hyvitys → kuittiviesti jonoon');
  v := pg_temp.run('user', format('select booking.admin_refund(%s, 10, %L)', p2, 'Toinen osa'), u_adm);
  rb2 := (v ->> 'refund_id')::bigint;
  perform booking.montonio_refund_claim(rb2, 1);
  perform booking.montonio_refund_stamp(rb2, 'rf-t343-b2', 'PENDING', null);
  update booking.refunds set covered_by_receipt_id = rc1 where id = rb2;   -- Bottiavustuksen linkitys (vrt. 68 → H-2026-000006)
  select count(*) into e0 from booking.email_outbox where kind = 'refund_receipt';
  v := booking.montonio_refund_complete(rb2, 'rf-t343-b2', '{"refundStatus":"SUCCESSFUL"}'::jsonb);
  perform pg_temp.ck((select status = 'done' from booking.refunds where id = rb2) and not exists (select 1 from booking.receipts where refund_id = rb2)
                     and (select count(*) from booking.email_outbox where kind = 'refund_receipt') = e0
                     and (select refunded_amount = 30 from booking.payments where id = p2), 'C3: linkitetty hyvitys → ei kuittia eikä viestiä, refunded 30 ' || v::text);

  -- tilaus 3: maksu ylittyisi → needs_review, ei tilamuutosta
  select * into o3, p3 from pg_temp.mk(u_adm, v_rule, d, 2, 'c@t343.example');
  v := pg_temp.run('user', format('select booking.admin_refund(%s, 10, %L)', p3, 'Ylitys'), u_adm);
  rb1 := (v ->> 'refund_id')::bigint;
  perform booking.montonio_refund_claim(rb1, 1);
  perform booking.montonio_refund_stamp(rb1, 'rf-t343-c1', 'PENDING', null);
  update booking.payments set refunded_amount = amount - 5, status = 'partially_refunded' where id = p3;   -- muualta kirjattu hyvitys
  select count(*) into e0 from booking.email_outbox where kind = 'refund_receipt';
  v := booking.montonio_refund_complete(rb1, 'rf-t343-c1', '{"refundStatus":"SUCCESSFUL"}'::jsonb);
  perform pg_temp.ck((v ->> 'needs_review')::boolean and (select status = 'processing' and provider_status = 'needs_review' and raw #>> '{review,reason}' = 'payment_over_refunded' from booking.refunds where id = rb1)
                     and (select refunded_amount = amount - 5 from booking.payments where id = p3)
                     and not exists (select 1 from booking.receipts where refund_id = rb1)
                     and (select count(*) from booking.email_outbox where kind = 'refund_receipt') = e0, 'D1: ylitys → needs_review, ei kuittia ' || v::text);
  perform pg_temp.ck(exists (select 1 from booking.audit_log where row_pk = rb1::text and action = 'MONTONIO_REFUND_NEEDS_REVIEW'), 'D2: audit MONTONIO_REFUND_NEEDS_REVIEW');
  v := booking.montonio_refund_claim(rb1, 1);
  perform pg_temp.ck(jsonb_array_length(v -> 'claimed') = 0, 'D3: claim ei ota needs_review-riviä ' || v::text);
  v := booking.montonio_refund_fail(rb1, '{"status":"REJECTED"}'::jsonb);
  perform pg_temp.ck((v ->> 'unchanged')::boolean and (select status = 'processing' from booking.refunds where id = rb1), 'D4: fail ei muuta needs_review-riviä ' || v::text);

  -- montonio_refund_info: vain service_role
  v := pg_temp.run('service', format('select booking.montonio_refund_info(%s)', r68));
  perform pg_temp.ck((v ->> 'found')::boolean and v ->> 'provider_refund_id' = 'rf-t343-68' and v ->> 'order_uuid' = 'x', 'E1: info service_role ' || v::text);
  v := pg_temp.run('anon', format('select booking.montonio_refund_info(%s)', r68), null, '10.34.3.1');
  perform pg_temp.ck(v ? 'err', 'E2: anon ei voi ajaa ' || v::text);
  v := pg_temp.run('user', format('select booking.montonio_refund_info(%s)', r68), u_adm);
  perform pg_temp.ck(v ? 'err', 'E3: authenticated ei voi ajaa ' || v::text);
end $t$;
select 'RESULT ' || case when ok then 'ok' else 'NOT OK' end || ' - ' || label from t343_r;
select 'SUMMARY ' || count(*) filter (where not ok) || ' failed / ' || count(*) from t343_r;
rollback;
