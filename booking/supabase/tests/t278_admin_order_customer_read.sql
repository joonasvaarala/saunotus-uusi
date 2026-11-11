-- t278: tilausnäkymän ja asiakasnäkymän lukufunktiot (booking_278). Paikallinen Postgres migraatioiden ja
-- fixtures/10_test_helpers.sql jälkeen:
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=1 -f t278_admin_order_customer_read.sql
-- Yksi transaktio; lopussa rollback kumoaa kaiken. Ei tuotantoon.
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '120s';
set local lock_timeout = '3s';
\ir ../migrations/20261111160000_booking_278_admin_order_customer_read.sql

create function pg_temp.ck(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAIL: %', label; end if;
  raise notice 'PASS: %', label;
end $$;

do $test$
declare
  u_staff uuid := test.mk_staff('t278-staff@example.test', 'staff');
  v_space bigint := (select id from booking.resources order by id limit 1);
  v_cu bigint; v_cu2 bigint; v_o bigint; v_o2 bigint; v_o3 bigint; v_r1 bigint; v_r2 bigint; v_r3 bigint;
  v_it1 bigint; v_p1 bigint; v_p2 bigint; v_p3 bigint; v_gc bigint; v_vc bigint; v_ic bigint;
  j jsonb; h jsonb; keys_before int; ok boolean;
begin
  -- Oikeudet
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_order_history(bigint, integer)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_order_history(bigint, integer)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_order_lookup(bigint)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_order_lookup(bigint)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_get_order(bigint)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_get_customer(bigint)', 'execute'), 'R1: anon ei, authenticated kyllä');
  perform pg_temp.ck((select bool_and(p.prosecdef and p.proconfig @> array['search_path=""'] and p.provolatile = 's')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'booking' and p.proname in ('admin_get_order','admin_get_customer','admin_order_history','admin_order_lookup')),
    'R2: SECURITY DEFINER, search_path tyhjä, STABLE (ei kirjoita)');

  -- Testidata suoraan tauluihin (triggerit pois vain asetuksen ajaksi)
  set local session_replication_role = replica;
  insert into booking.customers (name, email, phone, language, notes)
    values ('T278 Asiakas', 't278@example.test', '+358400000278', 'fi', 'asiakkaan muistiinpano') returning id into v_cu;
  insert into booking.customers (name) values ('T278 Tyhjä') returning id into v_cu2;
  insert into booking.orders (order_no, customer_id, status, payment_status, total_gross, locale, source_channel, internal_note, created_at)
    values (927801, v_cu, 'confirmed', 'partially_paid', 200.00, 'en', 'web', 'järjestelmä: luotu', now() - interval '3 days') returning id into v_o;
  insert into booking.order_items (order_id, kind, product_name, quantity, unit_price_gross, line_total_gross, vat_rate)
    values (v_o, 'reservation', 'Yleinen vuoro', 1, 100, 100, 13.5) returning id into v_it1;
  insert into booking.reservations (order_id, order_item_id, space_id, mode, starts_at, ends_at, persons, status, notes)
    values (v_o, v_it1, v_space, 'shared', now() + interval '2 days', now() + interval '2 days 2 hours', 2, 'confirmed', 'Tuo pyyhkeet') returning id into v_r1;
  insert into booking.reservations (order_id, space_id, mode, starts_at, ends_at, persons, status, checkin_at)
    values (v_o, v_space, 'shared', now() - interval '10 days', now() - interval '10 days' + interval '2 hours', 2, 'completed', now() - interval '10 days') returning id into v_r2;
  insert into booking.reservations (order_id, space_id, mode, starts_at, ends_at, persons, status)
    values (v_o, v_space, 'shared', now() - interval '20 days', now() - interval '20 days' + interval '2 hours', 1, 'no_show') returning id into v_r3;
  -- maksut: montonio 120 (20 hyvitetty + 10 käsittelyssä), lahjakortti 50, kumppani 40
  insert into booking.payments (order_id, method, provider, status, amount, refunded_amount, paid_at)
    values (v_o, 'montonio', 'montonio', 'partially_refunded', 120, 20, now() - interval '3 days') returning id into v_p1;
  insert into booking.refunds (payment_id, order_id, amount, status) values (v_p1, v_o, 20, 'done'), (v_p1, v_o, 10, 'requested');
  insert into booking.gift_cards (code, initial_amount, balance, buyer_customer_id, status, kind, valid_to)
    values ('HHT278GI9876', 100, 50, v_cu, 'active', 'value', current_date + 300) returning id into v_gc;
  insert into booking.payments (order_id, method, provider, status, amount, gift_card_id, paid_at)
    values (v_o, 'gift_card', 'manual', 'paid', 50, v_gc, now() - interval '3 days') returning id into v_p2;
  insert into booking.gift_card_ledger (gift_card_id, order_id, payment_id, delta, balance_after, reason) values (v_gc, v_o, v_p2, -50, 50, 'redemption');
  insert into booking.payments (order_id, method, provider, status, amount, paid_at)
    values (v_o, 'partner_voucher_elamyslahjat', 'manual', 'paid', 40, now() - interval '3 days') returning id into v_p3;
  insert into booking.voucher_claims (order_id, reservation_id, code, source, status, problem_code, resolved_at, resolved_by)
    values (v_o, v_r1, 'ABCD12345678', 'elamyslahjat', 'problem', 'already_used', now(), 'bot') returning id into v_vc;
  insert into booking.invoice_customers (company_name) values ('T278 Oy') returning id into v_ic;
  insert into booking.invoices (kind, status, customer_id, order_id, invoice_date, due_date, seller_snapshot, customer_snapshot, invoice_no, seq, series, sent_at)
    values ('debit', 'sent', v_ic, v_o, current_date - 1, current_date + 13, '{}'::jsonb, '{}'::jsonb, 'L278001', 278001,
            (select series from booking.invoice_counters order by series limit 1), now() - interval '1 day');
  -- toinen tilaus: peruttu ja maksettu → ylisuoritus = maksettu
  insert into booking.orders (order_no, customer_id, status, payment_status, total_gross, locale, source_channel)
    values (927802, v_cu, 'cancelled', 'paid', 60.00, 'fi', 'admin') returning id into v_o2;
  insert into booking.payments (order_id, method, provider, status, amount, paid_at) values (v_o2, 'cash', 'manual', 'paid', 60, now());
  -- kolmas: maksamaton tuleva
  insert into booking.orders (order_no, customer_id, status, payment_status, total_gross, locale, source_channel)
    values (927803, v_cu, 'confirmed', 'unpaid', 30.00, 'fi', 'admin') returning id into v_o3;
  insert into booking.reservations (order_id, space_id, mode, starts_at, ends_at, persons, status)
    values (v_o3, v_space, 'shared', now() + interval '9 days', now() + interval '9 days 2 hours', 1, 'confirmed');
  -- audit-rivit: varauksen tila + muistiinpano (sisältö ei saa näkyä), tilauksen pelkkä updated_at (ei näy)
  insert into booking.audit_log (at, actor, actor_role, table_name, row_pk, action, old_data, new_data) values
    (now() - interval '2 days', u_staff, 'authenticated', 'reservations', v_r1::text, 'UPDATE',
       jsonb_build_object('status','pending','notes','vanha salaisuus','persons',3,'updated_at','x'),
       jsonb_build_object('status','confirmed','notes','Tuo pyyhkeet','persons',2,'updated_at','y')),
    (now() - interval '1 day', null, 'service_role', 'orders', v_o::text, 'UPDATE',
       jsonb_build_object('updated_at','a'), jsonb_build_object('updated_at','b')),
    (now() - interval '1 day', null, null, 'booking.voucher_claims', v_vc::text, 'VOUCHER_REDEEMED',
       null, jsonb_build_object('by','bot','amount',40)),
    (now() - interval '5 days', null, null, 'orders', '999999999', 'UPDATE',
       jsonb_build_object('status','a'), jsonb_build_object('status','b'));
  set local session_replication_role = origin;

  -- Ilman kirjautumista: kielletty
  begin perform booking.admin_order_history(v_o); ok := false; exception when others then ok := sqlerrm ~* 'oikeuks'; end;
  perform pg_temp.ck(ok, 'R3: historia vaatii henkilökunnan');
  begin perform booking.admin_order_lookup(927801); ok := false; exception when others then ok := sqlerrm ~* 'oikeuks'; end;
  perform pg_temp.ck(ok, 'R4: lookup vaatii henkilökunnan');

  perform test.login(u_staff);
  -- A
  j := booking.admin_get_order(v_o);
  perform pg_temp.ck(j ? 'order_no' and j ? 'balance' and j ? 'payments' and j ? 'reservations' and j ? 'items' and j ? 'emails'
    and j ? 'requests' and j ? 'invoice_locked' and j ? 'invoice_no' and j ? 'can_add' and j ? 'staff_can_add', 'A1: vanhat avaimet ennallaan');
  perform pg_temp.ck(j ->> 'locale' = 'en', 'A2: locale');
  perform pg_temp.ck(j #>> '{invoice,invoice_no}' = 'L278001' and j #>> '{invoice,status}' = 'sent'
    and (j #>> '{invoice,due_date}')::date = current_date + 13 and j #> '{invoice,sent_at}' is not null and (j ->> 'invoice_locked')::boolean,
    'A3: lasku: numero, tila, eräpäivä, lähetysaika; lukko');
  -- net_paid = (120+50+40) - 20 = 190 < 200 → ei ylisuoritusta
  perform pg_temp.ck((j ->> 'overpaid')::numeric = 0, 'A4: overpaid 0 kun maksettu < summa');
  perform pg_temp.ck(jsonb_array_length(j -> 'refundable_by_payment') = 1
    and (j #>> '{refundable_by_payment,0,payment_id}')::bigint = v_p1
    and (j #>> '{refundable_by_payment,0,refundable}')::numeric = 90,
    'A5: hyvitettävissä vain Montonio 120-20-10 = 90 (lahjakortti ja kumppani pois)');
  perform pg_temp.ck(j #>> '{voucher_claims,0,problem_code}' = 'already_used' and j #>> '{voucher_claims,0,code_masked}' = '…5678'
    and not (j -> 'voucher_claims' -> 0 ? 'code') and position('ABCD1234' in j::text) = 0, 'A6: kumppanikoodi maskattu, ongelmakoodi');
  perform pg_temp.ck(jsonb_array_length(j -> 'reservation_meta') = 3 and (j -> 'reservation_meta') @> jsonb_build_array(jsonb_build_object('id', v_r2))
    and (select bool_and(x ? 'space_code' and x ? 'rule_id') from jsonb_array_elements(j -> 'reservation_meta') x), 'A7: reservation_meta');
  perform pg_temp.ck(j -> 'reservations' -> 0 ? 'notes', 'A8: varausten notes edelleen mukana');
  perform pg_temp.ck((booking.admin_get_order(v_o2) ->> 'overpaid')::numeric = 60, 'A9: peruttu+maksettu → overpaid = maksettu');
  perform pg_temp.ck(booking.admin_get_order(v_o3) -> 'invoice' = 'null'::jsonb and booking.admin_get_order(v_o3) ->> 'locale' = 'fi', 'A10: ei laskua → null');
  -- H
  j := booking.admin_get_customer(v_cu);
  perform pg_temp.ck(j ? 'orders' and j ? 'annual_cards' and j ->> 'notes' = 'asiakkaan muistiinpano' and not (j ? 'unsubscribe_token'), 'H1: vanhat kentät ennallaan');
  -- avoin: o (200-190=10) + o3 30 = 40; o2 peruttu ei mukana
  perform pg_temp.ck((j ->> 'open_balance')::numeric = 40 and (j ->> 'open_orders')::int = 2, 'H2: avoin saldo ja maksamattomat tilaukset');
  perform pg_temp.ck((j #>> '{stats,visits}')::int = 1 and (j #>> '{stats,upcoming}')::int = 2 and (j #>> '{stats,no_show}')::int = 1
    and (j #>> '{stats,orders}')::int = 3 and j #> '{stats,last_visit}' is not null and j #> '{stats,next_at}' is not null, 'H3: käynnit, tulevat, ei saapunut');
  perform pg_temp.ck((j #>> '{gift_cards,bought_count}')::int = 1 and (j #>> '{gift_cards,bought_total}')::numeric = 100
    and j #>> '{gift_cards,bought,0,code_masked}' = '****-****-9876' and position('HHT278GI' in j::text) = 0
    and (j #>> '{gift_cards,redeemed_count}')::int = 1, 'H4: lahjakortit maskattuna');
  j := booking.admin_get_customer(v_cu2);
  perform pg_temp.ck((j ->> 'open_balance')::numeric = 0 and (j #>> '{stats,visits}')::int = 0 and jsonb_array_length(j #> '{gift_cards,bought}') = 0, 'H5: tyhjä asiakas');
  -- J
  h := booking.admin_order_history(v_o);
  perform pg_temp.ck(jsonb_array_length(h -> 'events') = 2, 'J1: pelkkä updated_at-muutos ja vieraan tilauksen rivi eivät näy');
  perform pg_temp.ck(h #>> '{events,1,actor_kind}' = 'staff' and h #>> '{events,1,table}' = 'reservations'
    and (h #> '{events,1,changes}') @> '[{"field":"status","from":"pending","to":"confirmed"}]'::jsonb
    and (h #> '{events,1,changes}') @> '[{"field":"notes","from":null,"to":null}]'::jsonb, 'J2: tila arvoineen, muistiinpanosta vain kentän nimi');
  perform pg_temp.ck(position('salaisuus' in h::text) = 0 and position('pyyhkeet' in h::text) = 0 and position('updated_at' in h::text) = 0, 'J3: ei muistiinpanon sisältöä');
  perform pg_temp.ck(h #>> '{events,0,table}' = 'voucher_claims' and h #>> '{events,0,action}' = 'VOUCHER_REDEEMED' and h #>> '{events,0,actor_kind}' = 'system', 'J4: kumppanilunastus, järjestelmä');
  perform pg_temp.ck(jsonb_array_length(booking.admin_order_history(v_o, 1) -> 'events') = 1, 'J5: p_limit');
  begin perform booking.admin_order_history(-1); ok := false; exception when others then ok := sqlerrm ~* 'löydy'; end;
  perform pg_temp.ck(ok, 'J6: tuntematon tilaus');
  -- lookup
  perform pg_temp.ck((booking.admin_order_lookup(927801) ->> 'order_id')::bigint = v_o, 'L1: tilausnumero → id');
  begin perform booking.admin_order_lookup(1); ok := false; exception when others then ok := sqlerrm ~* 'löydy'; end;
  perform pg_temp.ck(ok, 'L2: tuntematon numero');
  perform test.logout();
  -- Ei datamuutoksia: funktiot ovat STABLE (R2) eivätkä kirjoita audit_logiin
  perform pg_temp.ck((select count(*) from booking.audit_log where at > now() - interval '1 second' and table_name in ('orders','reservations')) = 0, 'D1: luku ei kirjoita');
end $test$;


-- Rollback palauttaa PRODin rungot sellaisinaan (md5 11.11.2026) ja poistaa uudet funktiot.
\ir ../rollbacks/20261111160000_booking_278_ROLLBACK.sql
do $rb$
begin
  perform pg_temp.ck(md5(pg_get_functiondef('booking.admin_get_order(bigint)'::regprocedure)) = '588767e4dd1967267df8d12501aa6898', 'RB1: admin_get_order = PROD ennen 278:aa');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.admin_get_customer(bigint)'::regprocedure)) = '5b4d0d7a45c9be9ed3ffd340255d688a', 'RB2: admin_get_customer = PROD ennen 278:aa');
  perform pg_temp.ck(to_regprocedure('booking.admin_order_history(bigint, integer)') is null and to_regprocedure('booking.admin_order_lookup(bigint)') is null, 'RB3: uudet funktiot poistettu');
  perform pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_get_order(bigint)', 'execute') and not has_function_privilege('anon', 'booking.admin_get_order(bigint)', 'execute'), 'RB4: oikeudet ennallaan');
end $rb$;

rollback;
