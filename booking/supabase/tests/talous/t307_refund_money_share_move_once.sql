begin;
-- t307: booking_307 – (2) hyvitys lahjakortti-/kumppaniosuuden tilauksessa leikataan rahaosuuteen (ei amount_exceeds_refundable),
--        (4) yleisen vuoron siirto vain kerran (asiakas), henkilökunta saa ohittaa.
-- Vaatii migraatiot 282–284 + 307 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback.
-- VAIN paikalliseen kertakäyttökantaan: avaa partial_refunds_enabled-lipun ja muuttaa fixture-dataa transaktion sisällä. Ei koskaan DEV/PROD-kantaan.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t307_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t307_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.login(p_user);
  begin execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
-- asiakkaan (anon) kutsu
create function pg_temp.anon_(p_ip text, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform test.anon(p_ip);
  begin execute p_sql into v;
  exception when others then v := jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
-- sisäinen funktio suoraan (ei kirjautumista; sisäiset funktiot eivät ole authenticatedin kutsuttavissa)
create function pg_temp.su_(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  begin execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  return v;
end $$;
-- tilaus 3 hlö: p_gc € lahjakortilla, p_partner € kumppanikoodilla, loput Montoniolla (verkkomaksu)
create function pg_temp.mk(p_adm uuid, p_rule bigint, p_date date, p_email text, p_gc numeric, p_code text, p_partner numeric default 0, out o_id bigint, out tok uuid) language plpgsql as $$
declare a jsonb; v_unpaid numeric;
begin
  perform test.reset_rl();
  a := test.pub_book(p_rule, p_date, 3, p_email);
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  tok := (a ->> 'token')::uuid; o_id := (test.ord(tok)).id;
  if p_gc > 0 then
    insert into booking.gift_cards(code, initial_amount, balance, valid_to, status) values (p_code, p_gc, p_gc, current_date + 200, 'active');
    perform booking._apply_gift_core(o_id, p_code, 'card_terminal', true, 'Testi');
  end if;
  if p_partner > 0 then
    perform test.login(p_adm); perform booking.admin_record_payment(o_id, 'partner_voucher_elamyslahjat', p_partner, null, null); perform test.logout();
  end if;
  select (booking._order_balance(o_id) ->> 'unpaid')::numeric into v_unpaid;
  if v_unpaid > 0 then
    perform test.login(p_adm); perform booking.admin_record_payment(o_id, 'card_terminal', v_unpaid, null, null); perform test.logout();
  end if;
  update booking.payments set provider = 'montonio', method = 'montonio', raw = '{"order_uuid":"x","env":"test"}'::jsonb
   where order_id = o_id and method = 'card_terminal' and gift_card_id is null;
end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); v_prod bigint; d date := test.next_dow(1, 20);
  u_adm uuid := test.mk_staff('adm@t307.example', 'admin');
  v jsonb; o bigint; t uuid; r bigint; v_bal numeric; v_n int;
begin
  select product_id into v_prod from booking.schedule_rules where id = v_rule;
  update booking.settings set value = 'true'::jsonb where key in ('partial_refunds_enabled', 'gift_cards.redeem_enabled');
  update booking.settings set value = '1000'::jsonb where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'montonio';
  perform pg_temp.ck((select price from kb.products where id = v_prod) = 29, 'esiehto: hinta 29 €/hlö (3 hlö = 87 €)');

  -- ===== (2) hyvitys: lahjakortti 60 + Montonio 27, pienennys 3 → 2 (erotus 29) =====
  select * into o, t from pg_temp.mk(u_adm, v_rule, d, 'a@t307.example', 60, 'HHGCT3070001');
  r := (test.res(t)).id;
  v_bal := (select balance from booking.gift_cards where code = 'HHGCT3070001');
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, 29, %L, false)', r, 'testi'));
  perform pg_temp.ck(v ->> 'err' is null and (v ->> 'ok')::boolean, 'A1: pyydetty 29 € ei kaadu (ennen: amount_exceeds_refundable) ' || v::text);
  perform pg_temp.ck((v ->> 'refunded_total')::numeric = 27 and (v ->> 'refund_capped')::boolean and (v ->> 'refund_requested')::numeric = 29, 'A2: hyvitetään vain rahaosuus 27 € (capped) ');
  perform pg_temp.ck((v ->> 'non_refundable_amount')::numeric = 2, 'A3: lahjakorttiosuuden ylisuoritus 2 € jää hyvittämättä (non_refundable_amount) ' || coalesce(v ->> 'non_refundable_amount', 'null'));
  perform pg_temp.ck((select persons from booking.reservations where id = r) = 2 and (select total_gross from booking.orders where id = o) = 58, 'A4: muutos tehty (2 hlö, 58 €)');
  perform pg_temp.ck((select coalesce(sum(amount), 0) from booking.refunds where order_id = o) = 27
                     and not exists (select 1 from booking.refunds f join booking.payments p on p.id = f.payment_id where f.order_id = o and (p.gift_card_id is not null or p.method = 'gift_card')),
                     'A5: hyvitysrivit vain Montonio-maksulle, ei lahjakorttimaksulle');
  perform pg_temp.ck((select balance from booking.gift_cards where code = 'HHGCT3070001') = v_bal, 'A6: lahjakortin saldoa ei palautettu (ei päätöstä)');

  -- ===== kokonaan lahjakortilla (rahaosuus 0): muutos tehdään, hyvitys 0 € ilman virhettä =====
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 7, 'b@t307.example', 87, 'HHGCT3070002');
  r := (test.res(t)).id;
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, 29, null, false)', r));
  perform pg_temp.ck(v ->> 'err' is null and (v ->> 'refunded_total')::numeric = 0 and v ->> 'refund_skipped' = 'no_money_share', 'B1: rahaosuus 0 → hyvitys 0 €, refund_skipped=no_money_share ' || v::text);
  perform pg_temp.ck((select persons from booking.reservations where id = r) = 2 and not exists (select 1 from booking.refunds where order_id = o), 'B2: muutos tehty, ei hyvitysrivejä');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'ADMIN_CHANGE_REFUND' and row_pk = r::text and new_data ->> 'refund_skipped' = 'no_money_share'), 'B3: audit kirjaa ohituksen');

  -- ===== kumppanikoodi 60 + Montonio 27 =====
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 14, 'c@t307.example', 0, null, 60);
  r := (test.res(t)).id;
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, 29, null, false)', r));
  perform pg_temp.ck(v ->> 'err' is null and (v ->> 'refunded_total')::numeric = 27, 'C1: kumppanikoodi + Montonio → hyvitys 27 € ' || v::text);

  -- ===== ennallaan: pelkkä Montonio, liian suuri summa → virhe ja muutos kumoutuu =====
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 21, 'd@t307.example', 0, null);
  r := (test.res(t)).id;
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, 30, null, false)', r));
  perform pg_temp.ck(v ->> 'err' = 'amount_exceeds_refundable' and (select persons from booking.reservations where id = r) = 3, 'D1: ilman lahjakorttiosuutta ylisuuri summa → amount_exceeds_refundable, ei muutosta ' || v::text);
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, 29, null, false)', r));
  perform pg_temp.ck((v ->> 'refunded_total')::numeric = 29 and not (v ->> 'refund_capped')::boolean, 'D2: oikea summa → 29 €, ei leikkausta');
  -- koko tilauksen peruutustila ennallaan (virhe, ei leikkausta)
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 28, 'e@t307.example', 30, 'HHGCT3070003');
  v := pg_temp.su_(format('select booking._refund_allocate(%s, 87, null, null, null, true)', o));
  perform pg_temp.ck(v ->> 'err' = 'amount_exceeds_refundable', 'D3: p_cancel_mode: ylisuuri summa → virhe kuten ennen');
  -- ylisuorituksen hyvitys (admin_refund_overpayment) lahjakorttiosuudella: summa leikataan
  update booking.orders set total_gross = 58 where id = o;   -- simuloitu ylisuoritus 29 € (lahjakortti 30 + raha 57)
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 40, null, null, false)', o));
  perform pg_temp.ck(v ->> 'err' is null and (v ->> 'refunded_total')::numeric = 29, 'D4: admin_refund_overpayment 40 € → leikattu 29 € ' || v::text);

  -- ===== (4) siirto vain kerran =====
  update booking.product_config set cancellation_tier = 'general' where product_id = v_prod;
  perform test.reset_rl();
  t := (test.pub_book(v_rule, d + 35, 2, 'm@t307.example') ->> 'token')::uuid;
  r := (test.res(t)).id;
  v := pg_temp.anon_('10.7.0.1', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 42));
  perform pg_temp.ck((v ->> 'ok')::boolean and test.hel_date((test.res(t)).starts_at) = d + 42, 'M1: ensimmäinen siirto onnistuu ' || v::text);
  v := pg_temp.anon_('10.7.0.1', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 49));
  perform pg_temp.ck(v ->> 'code' = 'already_moved' and test.hel_date((test.res(t)).starts_at) = d + 42, 'M2: toinen siirto estetty (already_moved), varaus ennallaan ' || v::text);
  v := pg_temp.anon_('10.7.0.1', format('select booking.public_change_booking(%L, null, null, 3)', t));
  perform pg_temp.ck((v ->> 'ok')::boolean and (test.res(t)).persons = 3, 'M3: henkilömäärän muutos siirron jälkeen sallittu (ei siirto) ' || v::text);
  v := pg_temp.anon_('10.7.0.1', format('select booking.public_change_booking(%L, %s, %L, 2)', t, v_rule, d + 42));
  perform pg_temp.ck((v ->> 'ok')::boolean and (test.res(t)).persons = 2, 'M4: sama vuoro valittuna + henkilömäärä → ei siirto, sallittu ' || v::text);
  -- ydin valvoo myös suoraan (ohitetaan public-esitarkistus)
  v := pg_temp.su_(format('select booking._change_booking_core(%s, %s, %L, null, true, 48, null, %L, false)', r, v_rule, d + 49, 'CUSTOMER_CHANGE'));
  perform pg_temp.ck(v ->> 'err' = 'already_moved', 'M5: _change_booking_core estää asiakaspolun toisen siirron ' || v::text);
  -- henkilökunta saa ohittaa
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', r, v_rule, d + 49));
  perform pg_temp.ck(v ->> 'err' is null and test.hel_date((test.res(t)).starts_at) = d + 49, 'M6: henkilökunta voi siirtää uudelleen ' || v::text);
  -- henkilökunnan siirto ei kuluta asiakkaan siirtoa
  t := (test.pub_book(v_rule, d + 35, 2, 'n@t307.example') ->> 'token')::uuid;
  r := (test.res(t)).id;
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', r, v_rule, d + 42));
  v := pg_temp.anon_('10.7.0.2', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 49));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'M7: henkilökunnan siirron jälkeen asiakkaan oma (ensimmäinen) siirto sallittu ' || v::text);
  -- private_event: ehdoissa ei kertarajaa → toinen siirto sallittu
  update booking.product_config set cancellation_tier = 'private_event' where product_id = v_prod;
  t := (test.pub_book(v_rule, d + 35, 2, 'p@t307.example') ->> 'token')::uuid;
  v := pg_temp.anon_('10.7.0.3', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 42));
  v := pg_temp.anon_('10.7.0.3', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 49));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'M8: private_event: toinen siirto sallittu (sääntö koskee yleisiä vuoroja) ' || v::text);
  update booking.product_config set cancellation_tier = null where product_id = v_prod;
  t := (test.pub_book(v_rule, d + 35, 2, 'q@t307.example') ->> 'token')::uuid;
  v := pg_temp.anon_('10.7.0.4', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 42));
  v := pg_temp.anon_('10.7.0.4', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 49));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'M9: luokittelematon tuote: ei kertarajaa ' || v::text);
  perform pg_temp.ck(case when to_regprocedure('booking._customer_move_blocked(bigint)') is null then false else
                       not has_function_privilege('anon', 'booking._customer_move_blocked(bigint)', 'execute')
                       and not has_function_privilege('authenticated', 'booking._customer_move_blocked(bigint)', 'execute') end, 'S1: apufunktio ei ole anon/authenticated-kutsuttavissa');
end $t$;
select 'RESULT ' || case when ok then 'ok' else 'NOT OK' end || ' - ' || label from t307_r;
select 'SUMMARY ' || count(*) filter (where not ok) || ' failed / ' || count(*) from t307_r;
rollback;
