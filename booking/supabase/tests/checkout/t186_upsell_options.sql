-- t186: booking_186 ehdotuksiin mukaan pakollinen tuotevalinta (Saunahoito, tuote 10).
-- Ajo: migraation ja booking/supabase/tests/fixtures/10_test_helpers.sql:n JÄLKEEN, PG17 Tapio-dev.
--   psql -X -v ON_ERROR_STOP=0 -f booking/supabase/tests/fixtures/10_test_helpers.sql -f booking/supabase/tests/checkout/t186_upsell_options.sql
-- Odotettu tulos: ERROR: TESTRESULT pass=N fail=0 :: ALL OK
-- Yksi transaktio. Lopun poikkeus kumoaa testivarausten, ehdotusrivin ja laskun. Ei tuotantoon.
-- Ei muuta hintoja, ALV:tä, maksutilalogiikkaa eikä laskulukkoa: lähetetty veloituslasku estää lisäyksen.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '180s';

create temp table t186_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t186_r values (coalesce(p_ok, false), p_label) $$;

do $t$
declare
  v_def text; v_today date; v_day date; v_i int; v_main timestamptz; v_extra timestamptz;
  v_row jsonb; v_opt jsonb; v_honey bigint; v_made jsonb; v_tok uuid; v_oid bigint; v_sid uuid;
  v_n int; v_n2 int; v_total numeric; v_total2 numeric; v_result jsonb; v_res bigint; v_price numeric;
  v_detail text; v_raised boolean; v_cust bigint; v_seq int; v_inv bigint; v_pay text;
begin
  v_def := pg_get_functiondef('booking._upsell_options(bigint[],bigint[],date,integer,integer)'::regprocedure);
  perform pg_temp.ck(v_def not like '%not coalesce(pc.option_required%', 'A1 option_required-suodatin poistettu');
  perform pg_temp.ck(v_def like '%price_delta%' and v_def like '%''options''%' and v_def like '%option_label_en%', 'A2 payloadissa valinnat ja price_delta');
  perform pg_temp.ck(to_regprocedure('booking._upsell_attach_reservation(bigint,bigint,timestamptz,integer,date)') is null, 'A3 vanha 5-argumenttinen liitos poistettu');
  perform pg_temp.ck(to_regprocedure('booking._upsell_attach_reservation(bigint,bigint,timestamptz,integer,date,bigint)') is not null, 'A4 liitos ottaa option id:n');
  v_def := pg_get_functiondef('booking._upsell_attach_reservation(bigint,bigint,timestamptz,integer,date,bigint)'::regprocedure);
  perform pg_temp.ck(v_def like '%p_option_id%' and v_def like '%p_option_code%' and v_def like '%_order_invoice_locked%' is false, 'A5 liitos välittää valinnan, lukko on varausaskeleessa');
  perform pg_temp.ck(v_def like '%invalid_option%' and v_def not like '%public_treatment_availability%', 'A6 väärä valinta hylätään, julkista rajaa ei kuluteta');
  v_def := pg_get_functiondef('booking.public_upsell_checkout_attach(uuid,jsonb,uuid)'::regprocedure);
  perform pg_temp.ck(v_def like '%option_id%' and v_def like '%option_required%' and v_def like '%invalid_option%' and v_def like '%order_invoiced%', 'A7 kassa palauttaa valinta- ja laskuvirheet');
  perform pg_temp.ck(v_def like '%payment_status%' and v_def like '%discount_code_id%', 'A8 maksutila ja alennusennuste ennallaan');
  perform pg_temp.ck(pg_get_functiondef('booking.public_upsell_add(uuid,jsonb,uuid,bigint)'::regprocedure) like '%_order_invoice_locked%', 'A9 tilaussivun lisäys lukitsee laskutetun');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._upsell_attach_reservation(bigint,bigint,timestamptz,integer,date,bigint)', 'EXECUTE'), 'A10 liitosydin ei anonille');
  perform pg_temp.ck(not has_function_privilege('public', 'booking._upsell_options(bigint[],bigint[],date,integer,integer)', 'EXECUTE'), 'A11 sisäinen haku ei publicille');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_upsell_checkout_attach(uuid,jsonb,uuid)', 'EXECUTE'), 'A12 kassaliitos yhä julkinen');
  perform pg_temp.ck((
    select bool_and(p.prosecdef and coalesce(p.proconfig, '{}')::text like '%search_path=%')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (('booking', '_upsell_options'), ('booking', 'public_upsell_checkout_attach'))
        or (n.nspname = 'booking' and p.proname = '_upsell_attach_reservation' and pg_get_function_identity_arguments(p.oid) like '%bigint')), 'A13 security definer ja search_path');
  perform pg_temp.ck((select count(*) from booking.product_options where product_id = 10 and active) = 4
    and (select option_required from booking.product_config where product_id = 10), 'A14 Saunahoito: neljä valintaa, pakollinen');
  select id into v_honey from booking.product_options where product_id = 10 and code = 'hunajahoito' and active;
  perform pg_temp.ck(v_honey is not null, 'A15 hunajahoito');

  v_today := (now() at time zone booking._tz())::date;
  v_day := null; v_main := null; v_extra := null;
  for v_i in 0..13 loop
    v_day := v_today + v_i;
    select min(q.starts_at) into v_extra from booking._upsell_day_slots(10, v_day, 1) q
     where q.starts_at > now() + make_interval(mins => booking._upsell_cutoff() + 30);
    if v_extra is null then continue; end if;
    select min(q.starts_at) into v_main from booking._upsell_day_slots(11, v_day, 1) q
     where q.starts_at > now() + make_interval(mins => booking._upsell_cutoff() + 30) and q.starts_at <> v_extra;
    exit when v_main is not null;
  end loop;
  perform pg_temp.ck(v_main is not null and v_extra is not null, 'B0 yhteinen päivä tuotteille 10 ja 11');

  if v_extra is not null then
    delete from booking.product_suggestions where product_id = 11;
    insert into booking.product_suggestions(product_id, suggested_product_id, position, enabled) values (11, 10, 1, true);
    v_row := booking._upsell_options(array[11]::bigint[], array[11]::bigint[], (v_extra at time zone booking._tz())::date, 1, 9);
    select e into v_opt from jsonb_array_elements(v_row -> 'products') e where (e ->> 'product_id')::bigint = 10;
    perform pg_temp.ck(v_opt is not null and (v_opt ->> 'option_required')::boolean and v_opt ->> 'option_label' = 'Valitse hoito', 'B1 Saunahoito mukana ehdotuksissa');
    if v_opt is null then
      perform pg_temp.ck(false, 'B2 valintoja ei tullut');
      perform pg_temp.ck(false, 'B3 aikoja ei tullut');
    else
      perform pg_temp.ck(jsonb_array_length(v_opt -> 'options') = 4
        and (select e ->> 'code' from jsonb_array_elements(v_opt -> 'options') e where (e ->> 'id')::bigint = v_honey) = 'hunajahoito'
        and (select e ->> 'name' from jsonb_array_elements(v_opt -> 'options') e where (e ->> 'code') = 'hunajahoito') = 'Hunajahoito'
        and (select e ->> 'name_en' from jsonb_array_elements(v_opt -> 'options') e where (e ->> 'code') = 'hunajahoito') = 'Honey treatment'
        and (select bool_and(e -> 'price_delta' = 'null'::jsonb) from jsonb_array_elements(v_opt -> 'options') e), 'B2 neljä valintaa, nimet FI/EN, ei hintaeroa');
      perform pg_temp.ck(jsonb_array_length(v_opt -> 'slots') > 0, 'B3 aikoja mukana');
    end if;
  end if;

  if v_main is not null and v_extra is not null and v_honey is not null then
    delete from booking.rate_limit_hits;
    v_made := booking.public_create_treatment_booking(11, v_main, 1, 'T186 Valinta', 't186-opt@example.test', '+358401860011', false, 'fi', null, 'private', null, null, null);
    v_tok := (v_made ->> 'token')::uuid;
    select id, total_gross, payment_status into v_oid, v_total, v_pay from booking.orders where public_token = v_tok;
    perform pg_temp.ck(coalesce((v_made ->> 'ok')::boolean, false) and v_oid is not null and v_pay = 'unpaid', 'C0 perusvaraus (' || coalesce(v_made ->> 'code', '') || ')');
    if v_oid is not null then
      select min(q.starts_at) into v_extra from booking._upsell_day_slots(10, (v_main at time zone booking._tz())::date, 1) q
       where q.starts_at > now() + make_interval(mins => booking._upsell_cutoff() + 30);
      select count(*) into v_n from booking.reservations where order_id = v_oid;
      v_sid := gen_random_uuid();
      if v_extra is null then
        perform pg_temp.ck(false, 'C1 Saunahoidolle ei jäänyt aikaa');
      else
        v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 10, 'persons', 1, 'start', v_extra)), v_sid);
        select count(*) into v_n2 from booking.reservations where order_id = v_oid;
        select total_gross, payment_status into v_total2, v_pay from booking.orders where id = v_oid;
        perform pg_temp.ck(v_result ->> 'code' = 'option_required' and v_n2 = v_n and v_total2 = v_total and v_pay = 'unpaid', 'C1 ilman valintaa option_required, tilaus ennallaan');
        v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 10, 'persons', 1, 'start', v_extra, 'option_id', v_honey + 1000000)), v_sid);
        select count(*) into v_n2 from booking.reservations where order_id = v_oid;
        perform pg_temp.ck(v_result ->> 'code' = 'invalid_option' and v_n2 = v_n, 'C2 väärä valinta invalid_option');
        v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 10, 'persons', 1, 'start', v_extra, 'option_id', v_honey)), v_sid);
        select id into v_res from booking.reservations where order_id = v_oid and product_id = 10 and booking._res_active(status, hold_expires_at);
        select price into v_price from kb.products where id = 10;
        select total_gross, payment_status into v_total2, v_pay from booking.orders where id = v_oid;
        perform pg_temp.ck(v_result ->> 'ok' = 'true' and (v_result ->> 'added_count')::int = 1 and v_res is not null
          and (select product_option_id from booking.reservations where id = v_res) = v_honey, 'C3 valinta tallentuu varaukselle');
        perform pg_temp.ck(v_pay = 'unpaid' and v_total2 = v_total + v_price
          and (select unit_price_gross from booking.order_items where id = (select order_item_id from booking.reservations where id = v_res)) = v_price, 'C4 hinta on tuotteen hinta, maksutila unpaid');
      end if;
    end if;

    delete from booking.rate_limit_hits;
    select min(q.starts_at) into v_main from booking._upsell_day_slots(11, (v_extra at time zone booking._tz())::date, 1) q
     where q.starts_at > now() + make_interval(mins => booking._upsell_cutoff() + 30)
       and not exists (select 1 from booking.reservations r where r.product_id = 11 and r.starts_at = q.starts_at and booking._res_active(r.status, r.hold_expires_at));
    if v_main is null then
      for v_i in 0..13 loop
        v_day := v_today + v_i;
        select min(q.starts_at) into v_main from booking._upsell_day_slots(11, v_day, 1) q
         where q.starts_at > now() + make_interval(mins => booking._upsell_cutoff() + 30);
        exit when v_main is not null;
      end loop;
    end if;
    if v_main is null then
      perform pg_temp.ck(false, 'D0 laskutestin aikaa ei löytynyt');
    else
      v_made := booking.public_create_treatment_booking(11, v_main, 1, 'T186 Lasku', 't186-inv@example.test', '+358401860012', false, 'fi', null, 'private', null, null, null);
      v_tok := (v_made ->> 'token')::uuid;
      select id into v_oid from booking.orders where public_token = v_tok;
      perform pg_temp.ck(coalesce((v_made ->> 'ok')::boolean, false) and v_oid is not null, 'D0 laskutestin varaus (' || coalesce(v_made ->> 'code', '') || ')');
      if v_oid is not null then
        update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = v_oid and status = 'pending';
        update booking.orders set status = 'confirmed' where id = v_oid and status = 'pending';
        insert into booking.invoice_customers(company_name, email) values ('T186 Lasku Oy', 't186-lasku@example.test') returning id into v_cust;
        insert into booking.invoice_counters(series, last_seq) values ('L', 0) on conflict (series) do nothing;
        update booking.invoice_counters set last_seq = last_seq + 1 where series = 'L' returning last_seq into v_seq;
        insert into booking.invoices(customer_id, order_id, kind, status, invoice_date, due_date, seller_snapshot, customer_snapshot, series, seq, invoice_no, sent_at, total_net, total_vat, total_gross)
        values (v_cust, v_oid, 'debit', 'sent', (now() at time zone booking._tz())::date, (now() at time zone booking._tz())::date + 14,
                '{"name":"T186"}'::jsonb, '{"name":"T186 Lasku Oy"}'::jsonb, 'L', v_seq, 'T186-' || v_seq, now(), 0, 0, 0)
        returning id into v_inv;
        perform pg_temp.ck(booking._order_invoice_locked(v_oid) and (select payment_status from booking.orders where id = v_oid) = 'unpaid', 'D1 lähetetty veloituslasku lukitsee, maksutila unpaid');
        select count(*) into v_n from booking.reservations where order_id = v_oid;
        select total_gross into v_total from booking.orders where id = v_oid;
        v_day := (v_main at time zone booking._tz())::date;
        select min(q.starts_at) into v_extra from booking._upsell_day_slots(10, v_day, 1) q
         where q.starts_at > now() + make_interval(mins => booking._upsell_cutoff() + 30);
        v_raised := false; v_detail := null;
        if v_extra is not null then
          begin
            perform booking._upsell_attach_reservation(v_oid, 10, v_extra, 1, v_day, v_honey);
          exception when sqlstate 'BK001' then
            get stacked diagnostics v_detail = pg_exception_detail;
            v_raised := true;
          end;
        end if;
        select count(*) into v_n2 from booking.reservations where order_id = v_oid;
        select total_gross into v_total2 from booking.orders where id = v_oid;
        perform pg_temp.ck(v_raised and v_detail = 'order_invoiced' and v_n2 = v_n and v_total2 = v_total, 'D2 liitosydin: order_invoiced, riviä ei lisätä (' || coalesce(v_detail, 'ei poikkeusta') || ')');
        v_result := booking.public_upsell_add(v_tok, jsonb_build_object('type', 'reservation', 'product_id', 10, 'persons', 1, 'start', coalesce(v_extra, v_main), 'option_code', 'hunajahoito'), gen_random_uuid(), 11);
        select count(*) into v_n2 from booking.reservations where order_id = v_oid;
        perform pg_temp.ck(v_result ->> 'code' = 'order_invoiced' and v_n2 = v_n, 'D3 tilaussivun lisäys: order_invoiced');
        if v_extra is not null then
          v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 10, 'persons', 1, 'start', v_extra, 'option_id', v_honey)), gen_random_uuid());
          select count(*) into v_n2 from booking.reservations where order_id = v_oid;
          select total_gross, payment_status into v_total2, v_pay from booking.orders where id = v_oid;
          perform pg_temp.ck(v_result ->> 'code' = 'order_invoiced' and v_result ->> 'code' is distinct from 'slot_unavailable' and v_n2 = v_n and v_total2 = v_total and v_pay = 'unpaid', 'D4 kassa ei peitä laskulukkoa slot_unavailableksi');
        end if;
        perform pg_temp.ck(v_inv is not null and (select status from booking.invoices where id = v_inv) = 'sent', 'D5 lasku pysyy lähetettynä');
      end if;
    end if;
  end if;

  raise exception 'TESTRESULT pass=% fail=% :: %',
    (select count(*) from t186_r where ok),
    (select count(*) from t186_r where not ok),
    coalesce((select string_agg(label, ' | ' order by label) from t186_r where not ok), 'ALL OK');
end $t$;
rollback;
