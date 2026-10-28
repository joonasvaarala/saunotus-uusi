-- t197: booking_197. Kahden tilauksen kuitit eivät sekoitu, eikä nollattu laskuri uusi numeroa tai PDF-avainta.
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t197_receipt_pdf_identity.sql
-- migraatioiden ja booking/supabase/tests/fixtures/10_test_helpers.sql:n jälkeen.
-- Yksi transaktio, lopussa RAISE 'TESTRESULT pass=N fail=M' ja ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t197.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t197.log', coalesce(current_setting('t197.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.state(p_sql text) returns text language plpgsql as $$
declare s text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics s = returned_sqlstate;
  return s;
end $$;
create function pg_temp.issue(p_cu bigint, p_total numeric, p_name text) returns bigint language plpgsql as $$
declare o bigint; it bigint; p bigint; r bigint;
begin
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
  values (p_cu, 'confirmed', 'unpaid', p_total, 'admin', 'fi') returning id into o;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o, p_name, 'product', 1, p_total, p_total, 25.5) returning id into it;
  insert into booking.payments(order_id, method, status, amount, provider)
  values (o, 'card_terminal', 'pending', p_total, 'manual') returning id into p;
  insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
  values (p, it, p_name, 'product', 1, p_total, 25.5);
  update booking.payments set status = 'paid', paid_at = now() where id = p;
  select id into r from booking.receipts where payment_id = p and kind = 'receipt';
  if r is null then raise exception 't197 receipt missing for payment %', p; end if;
  return r;
end $$;

do $t$
declare
  run text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
  cu bigint;
  a bigint; b bigint; c bigint;
  ra booking.receipts; rb booking.receipts; rc booking.receipts;
  oa booking.orders; ob booking.orders;
  ka text; kb text; kc text;
  ja jsonb; jb jsonb; g jsonb;
  v_series text; v_year int; v_max int;
  pay_x bigint;
  log text; np int; nf int;
begin
  insert into booking.customers(name, email) values ('T197 Testi', 't197-' || run || '@example.invalid') returning id into cu;
  a := pg_temp.issue(cu, 63, 'Yleinen vuoro 2 hlö + pyyhe');
  b := pg_temp.issue(cu, 49, 'Yleinen vuoro + saunotusrituaali');
  select * into ra from booking.receipts where id = a;
  select * into rb from booking.receipts where id = b;
  select * into oa from booking.orders where id = ra.order_id;
  select * into ob from booking.orders where id = rb.order_id;
  ka := booking.receipt_pdf_object_key(ra.public_token, ra.snapshot);
  kb := booking.receipt_pdf_object_key(rb.public_token, rb.snapshot);

  perform pg_temp.ck(a <> b and ra.order_id <> rb.order_id and ra.total_gross = 63 and rb.total_gross = 49, 'A1 eri tilaukset 63 € ja 49 €');
  perform pg_temp.ck(ra.receipt_no <> rb.receipt_no and ra.public_token <> rb.public_token, 'A2 eri kuittinumerot ja tokenit');
  perform pg_temp.ck(ka <> kb and ka = lower(ra.public_token::text) || '/' || booking.receipt_snapshot_hash(ra.snapshot) || '.pdf', 'A3 PDF-avain on token + tiiviste');
  perform pg_temp.ck(kb = lower(rb.public_token::text) || '/' || booking.receipt_snapshot_hash(rb.snapshot) || '.pdf', 'A4 B:n avain on B:n token + tiiviste');
  perform pg_temp.ck(ka <> ra.receipt_no || '.pdf' and kb <> rb.receipt_no || '.pdf' and position('/' in ka) > 0 and position(ra.receipt_no in ka) = 0 and position(rb.receipt_no in kb) = 0, 'A5 avain ei ole kuittinumero.pdf');
  perform pg_temp.ck(booking.receipt_pdf_object_key('11111111-1111-4111-8111-111111111111', ra.snapshot)
                  <> booking.receipt_pdf_object_key('22222222-2222-4222-8222-222222222222', ra.snapshot), 'A6 sama snapshot, eri token → eri tiedosto');

  perform test.anon();
  g := booking.public_get_receipt(oa.public_token, ra.receipt_no);
  perform pg_temp.ck(g ->> 'ok' = 'true' and (g ->> 'public_token')::uuid = ra.public_token and (g -> 'snapshot' ->> 'total_gross')::numeric = 63
                      and (g -> 'snapshot' ->> 'order_no') = oa.order_no::text
                      and (g -> 'snapshot' -> 'lines' -> 0 ->> 'description') = 'Yleinen vuoro 2 hlö + pyyhe', 'B1 tilaus A saa oman 63 € kuitin');
  g := booking.public_get_receipt(oa.public_token, rb.receipt_no);
  perform pg_temp.ck(g ->> 'ok' = 'false' and g ->> 'code' = 'receipt_not_found' and g -> 'snapshot' is null, 'B2 tilaus A ei saa B:n kuittia');
  g := booking.public_get_receipt(ob.public_token, ra.receipt_no);
  perform pg_temp.ck(g ->> 'ok' = 'false' and g ->> 'code' = 'receipt_not_found', 'B3 tilaus B ei saa A:n kuittia');
  g := booking.public_get_receipt(ob.public_token, rb.receipt_no);
  perform pg_temp.ck(g ->> 'ok' = 'true' and (g ->> 'public_token')::uuid = rb.public_token and (g -> 'snapshot' ->> 'total_gross')::numeric = 49
                      and (g -> 'snapshot' -> 'lines' -> 0 ->> 'description') = 'Yleinen vuoro + saunotusrituaali', 'B4 tilaus B saa oman 49 € kuitin');
  perform test.logout();

  perform test.service();
  ja := booking.receipt_by_token(ra.public_token);
  jb := booking.receipt_by_token(rb.public_token);
  perform test.logout();
  perform pg_temp.ck((ja ->> 'order_public_token')::uuid = oa.public_token and ja ->> 'pdf_object_key' = ka
                      and ja ->> 'receipt_no' = ra.receipt_no and (ja -> 'snapshot' ->> 'total_gross')::numeric = 63, 'C1 token A → A:n avain ja 63 €');
  perform pg_temp.ck((jb ->> 'order_public_token')::uuid = ob.public_token and jb ->> 'pdf_object_key' = kb
                      and (jb -> 'snapshot' ->> 'total_gross')::numeric = 49 and ja ->> 'pdf_object_key' <> jb ->> 'pdf_object_key', 'C2 token B → B:n avain ja 49 €');

  perform test.service();
  perform pg_temp.ck(test.code(format('do $x$ begin perform booking.receipt_set_pdf(%s, %L); end $x$', a, ra.receipt_no || '.pdf')) = 'receipt_pdf_path', 'D1 kuittinumeropolku hylätään');
  perform pg_temp.ck(test.code(format('do $x$ begin perform booking.receipt_set_pdf(%s, %L); end $x$', a, kb)) = 'receipt_pdf_path', 'D2 B:n polkua ei voi kirjata A:lle');
  perform pg_temp.ck(test.code(format('do $x$ begin perform booking.receipt_set_pdf(%s, %L); end $x$', a, ka)) = 'ok', 'D3 A:n oma polku kelpaa');
  perform test.logout();
  perform pg_temp.ck((select pdf_path = ka and pdf_path is distinct from kb from booking.receipts where id = a), 'D4 A:n pdf_path on A:n avain');

  v_series := ra.series; v_year := ra.year;
  select max(seq) into v_max from booking.receipts where series = v_series and year = v_year;
  update booking.receipt_counters set last_seq = 0 where series = v_series and year = v_year;
  c := pg_temp.issue(cu, 77, 'Kolmas tilaus laskurin nollauksen jälkeen');
  select * into rc from booking.receipts where id = c;
  kc := booking.receipt_pdf_object_key(rc.public_token, rc.snapshot);
  perform pg_temp.ck(rc.seq > v_max and rc.receipt_no <> ra.receipt_no and rc.receipt_no <> rb.receipt_no, 'E1 nollattu laskuri ei uusi numeroa');
  perform pg_temp.ck(kc <> ka and kc <> kb and kc <> rc.receipt_no || '.pdf' and position(rc.receipt_no in kc) = 0, 'E2 kolmannen kuitin tiedosto on oma');
  perform pg_temp.ck((select last_seq >= rc.seq from booking.receipt_counters where series = v_series and year = v_year), 'E3 laskuri on vähintään uusi seq');
  perform test.service();
  ja := booking.receipt_by_token(ra.public_token);
  perform test.logout();
  perform pg_temp.ck(ja ->> 'pdf_object_key' = ka and (ja -> 'snapshot' ->> 'total_gross')::numeric = 63 and ja ->> 'receipt_no' = ra.receipt_no, 'E4 A:n kuitti ennallaan nollauksen jälkeen');

  insert into booking.payments(order_id, method, status, amount, provider)
  values (rb.order_id, 'card_terminal', 'pending', 1, 'manual') returning id into pay_x;
  perform pg_temp.ck(pg_temp.state(format(
    'insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, total_gross, snapshot, text_body) values (%L, %L, %L, %s, %s, %s, %s, 1, %L::jsonb, %L)',
    ra.receipt_no, 'receipt', ra.series, ra.year, v_max + 50, ra.order_id, pay_x, ra.snapshot::text, 't197 dup')) = '23505', 'F1 sama kuittinumero ei tallennu');

  log := current_setting('t197.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end
$t$;
rollback;
