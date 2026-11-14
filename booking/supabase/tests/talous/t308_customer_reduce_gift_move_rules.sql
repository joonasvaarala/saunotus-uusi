begin;
-- t308: booking_308 – (1) asiakkaan oma pienennys osin lahjakortilla/koodilla maksetussa tilauksessa (vain rahaosuus hyvitetään),
--        (2) siirto vain kerran myös yksityisvuoroille + oma siirto ≥ 7 vrk ennen, (3) botin siirto on asiakkaan ainoa siirto,
--        (4) admin_cancel_reservation "Hyvitä osa" rajataan rahaosuuteen.
-- Vaatii migraatiot 282–284 + 307 + 308 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback.
-- VAIN paikalliseen kertakäyttökantaan: avaa partial_refunds_enabled-lipun ja muuttaa fixture-dataa transaktion sisällä. Ei koskaan DEV/PROD-kantaan.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t308_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t308_r values (coalesce(p_ok, false), p_label) $$;
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
  u_adm uuid := test.mk_staff('adm@t308.example', 'admin');
  v jsonb; o bigint; t uuid; r bigint; v_bal numeric; v_s timestamptz; v_ono bigint;
begin
  select product_id into v_prod from booking.schedule_rules where id = v_rule;
  update booking.settings set value = 'true'::jsonb where key in ('partial_refunds_enabled', 'customer_auto_partial_refund_enabled', 'gift_cards.redeem_enabled');
  update booking.settings set value = '1000'::jsonb where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'montonio';
  update booking.product_config set cancellation_tier = 'general' where product_id = v_prod;
  perform pg_temp.ck((select price from kb.products where id = v_prod) = 29, 'esiehto: hinta 29 €/hlö (3 hlö = 87 €)');
  perform pg_temp.ck((select value from booking.settings where key = 'customer_move_min_days_private') = '7'::jsonb
                     and (select is_public from booking.settings where key = 'customer_move_min_days_private'), 'S0: asetus customer_move_min_days_private = 7 (julkinen)');

  -- ===== (1) lahjakortti 60 + Montonio 27, asiakas pienentää 3 → 2 (erotus 29, rahaosuus 27) =====
  select * into o, t from pg_temp.mk(u_adm, v_rule, d, 'a@t308.example', 60, 'HHGCT3080001');
  v_bal := (select balance from booking.gift_cards where code = 'HHGCT3080001');
  v := pg_temp.anon_('10.8.0.1', format('select booking.public_change_preview(%L, null, null, 2)', t));
  perform pg_temp.ck((v #>> '{auto_refund,allowed}')::boolean and (v #>> '{auto_refund,amount}')::numeric = 27
                     and (v #>> '{auto_refund,non_refundable}')::numeric = 2, 'R1: esikatselu sallii, hyvitys 27 €, ei hyvitetä 2 € ' || v::text);
  v := pg_temp.anon_('10.8.0.1', format('select booking.public_change_booking(%L, null, null, 2, 27)', t));
  perform pg_temp.ck((v ->> 'ok')::boolean and (test.res(t)).persons = 2, 'R2: pienennys tehty (odotettu hyvitys 27) ' || v::text);
  perform pg_temp.ck((select coalesce(sum(amount), 0) from booking.refunds where order_id = o) = 27
                     and not exists (select 1 from booking.refunds f join booking.payments p on p.id = f.payment_id where f.order_id = o and (p.gift_card_id is not null or p.method = 'gift_card')),
                     'R3: hyvitysrivit 27 € vain Montonio-maksulle');
  perform pg_temp.ck((select balance from booking.gift_cards where code = 'HHGCT3080001') = v_bal, 'R4: lahjakortin saldo ennallaan');

  -- pieni rahaosuus: lahjakortti 80 + Montonio 7 → hyvitys 7
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 7, 'b@t308.example', 80, 'HHGCT3080002');
  v := pg_temp.anon_('10.8.0.2', format('select booking.public_change_preview(%L, null, null, 2)', t));
  perform pg_temp.ck((v #>> '{auto_refund,amount}')::numeric = 7 and (v #>> '{auto_refund,non_refundable}')::numeric = 22, 'R5: rahaosuus 7 → hyvitys 7, 22 € jää ' || v::text);
  -- kokonaan lahjakortilla → henkilökunnalle (payment_method)
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 14, 'c@t308.example', 87, 'HHGCT3080003');
  v := pg_temp.anon_('10.8.0.3', format('select booking.public_change_preview(%L, null, null, 2)', t));
  perform pg_temp.ck(not (v #>> '{auto_refund,allowed}')::boolean and v #>> '{auto_refund,reason}' = 'payment_method', 'R6: kokonaan lahjakortilla → payment_method ' || v::text);
  -- kumppanikoodi 60 + Montonio 27
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 21, 'd@t308.example', 0, null, 60);
  v := pg_temp.anon_('10.8.0.4', format('select booking.public_change_booking(%L, null, null, 2, 27)', t));
  perform pg_temp.ck((v ->> 'ok')::boolean and (select coalesce(sum(amount), 0) from booking.refunds where order_id = o) = 27, 'R7: kumppanikoodi + Montonio → 27 € ' || v::text);
  -- pelkkä Montonio ennallaan: hyvitys = erotus, non_refundable 0
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 28, 'e@t308.example', 0, null);
  v := pg_temp.anon_('10.8.0.5', format('select booking.public_change_preview(%L, null, null, 2)', t));
  perform pg_temp.ck((v #>> '{auto_refund,amount}')::numeric = 29 and (v #>> '{auto_refund,non_refundable}')::numeric = 0, 'R8: pelkkä Montonio → 29 €, ei leikkausta ' || v::text);
  -- käteinen/pääte mukana → ennallaan payment_method
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 35, 'f@t308.example', 30, 'HHGCT3080004');
  update booking.payments set provider = 'manual', method = 'card_terminal' where order_id = o and gift_card_id is null and method = 'montonio';
  v := pg_temp.anon_('10.8.0.6', format('select booking.public_change_preview(%L, null, null, 2)', t));
  perform pg_temp.ck(v #>> '{auto_refund,reason}' = 'payment_method', 'R9: lahjakortti + pääte → payment_method ' || v::text);

  -- ===== (4) admin_cancel_reservation Hyvitä osa =====
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 42, 'g@t308.example', 60, 'HHGCT3080005');
  r := (test.res(t)).id;
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, %L, true, %L, true, false, 50)', r, 'testi', 'testi'));
  perform pg_temp.ck(v ->> 'err' is null and (v ->> 'refunded_total')::numeric = 27 and (v ->> 'refund_capped')::boolean, 'C1: Hyvitä osa 50 € → rajattu rahaosuuteen 27 € ' || v::text);
  select * into o, t from pg_temp.mk(u_adm, v_rule, d + 49, 'h@t308.example', 0, null);
  r := (test.res(t)).id;
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, %L, true, %L, null, false, 90)', r, 'testi', 'testi'));
  perform pg_temp.ck(v ->> 'err' = 'amount_exceeds_refundable' and (test.res(t)).status = 'confirmed', 'C2: ilman lahjakorttiosuutta ylisuuri → virhe, ei peruutusta ' || v::text);
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, %L, true, %L, null, false, 40)', r, 'testi', 'testi'));
  perform pg_temp.ck(v ->> 'err' is null and (v ->> 'refunded_total')::numeric = 40 and not (v ->> 'refund_capped')::boolean, 'C3: osahyvitys 40 € ennallaan ' || v::text);

  -- ===== (2) yksityisvuoro: siirto vain kerran + ≥ 7 vrk =====
  update booking.product_config set cancellation_tier = 'private_event' where product_id = v_prod;
  perform test.reset_rl();
  t := (test.pub_book(v_rule, d + 35, 2, 'p@t308.example') ->> 'token')::uuid;
  r := (test.res(t)).id;
  v := pg_temp.anon_('10.8.1.1', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 42));
  perform pg_temp.ck((v ->> 'ok')::boolean and test.hel_date((test.res(t)).starts_at) = d + 42, 'P1: yksityisvuoron ensimmäinen siirto ' || v::text);
  v := pg_temp.anon_('10.8.1.1', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 49));
  perform pg_temp.ck(v ->> 'code' = 'already_moved' and test.hel_date((test.res(t)).starts_at) = d + 42, 'P2: yksityisvuoron toinen siirto estetty ' || v::text);
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', r, v_rule, d + 49));
  perform pg_temp.ck(v ->> 'err' is null and test.hel_date((test.res(t)).starts_at) = d + 49, 'P3: henkilökunta voi siirtää ' || v::text);
  -- alle 7 vrk ennen alkuperäistä alkua → move_too_late_private
  t := (test.pub_book(v_rule, d + 35, 2, 'q@t308.example') ->> 'token')::uuid;
  r := (test.res(t)).id;
  update booking.reservations set starts_at = now() + interval '6 days', ends_at = now() + interval '6 days 2 hours' where id = r;
  v := pg_temp.anon_('10.8.1.2', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 42));
  perform pg_temp.ck(v ->> 'code' = 'move_too_late_private' and v ->> 'message' like '%7 vrk%', 'P4: alle 7 vrk → move_too_late_private ' || v::text);
  v := pg_temp.su_(format('select booking._change_booking_core(%s, %s, %L, null, true, 48, null, %L, false)', r, v_rule, d + 42, 'CUSTOMER_CHANGE'));
  perform pg_temp.ck(v ->> 'err' = 'move_too_late_private', 'P5: ydin valvoo myös suoraan ' || v::text);
  v := pg_temp.anon_('10.8.1.2', format('select booking.public_change_booking(%L, null, null, 3)', t));
  perform pg_temp.ck(coalesce(v ->> 'code', '') <> 'move_too_late_private', 'P6: henkilömäärän muutos ei ole siirto (ei move_too_late_private) ' || v::text);
  update booking.reservations set starts_at = now() + interval '8 days', ends_at = now() + interval '8 days 2 hours' where id = r;
  v := pg_temp.anon_('10.8.1.2', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 42));
  perform pg_temp.ck(coalesce(v ->> 'code', '') <> 'move_too_late_private', 'P7: 8 vrk ennen → ei aikarajaa ' || v::text);
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', r, v_rule, d + 56));
  perform pg_temp.ck(v ->> 'err' is null, 'P8: henkilökunta ei sidottu 7 vrk:n rajaan ' || v::text);
  -- yleinen vuoro: ei 7 vrk:n rajaa
  update booking.product_config set cancellation_tier = 'general' where product_id = v_prod;
  t := (test.pub_book(v_rule, d + 35, 2, 'r@t308.example') ->> 'token')::uuid;
  update booking.reservations set starts_at = now() + interval '6 days', ends_at = now() + interval '6 days 2 hours' where id = (test.res(t)).id;
  v := pg_temp.anon_('10.8.1.3', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 42));
  perform pg_temp.ck(coalesce(v ->> 'code', '') <> 'move_too_late_private', 'P9: yleinen vuoro: ei 7 vrk:n rajaa ' || v::text);

  -- ===== (3) botin siirto = asiakkaan ainoa siirto =====
  t := (test.pub_book(v_rule, d + 35, 2, 's@t308.example') ->> 'token')::uuid;
  r := (test.res(t)).id; v_s := (test.res(t)).starts_at; v_ono := (test.ord(t)).order_no;
  v := pg_temp.su_(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, v_s + interval '7 days', 'asiakas pyysi'));
  perform pg_temp.ck(v ->> 'err' is null and (test.res(t)).starts_at = v_s + interval '7 days', 'B1: botin ensimmäinen siirto onnistuu ' || v::text);
  v := pg_temp.anon_('10.8.2.1', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 56));
  perform pg_temp.ck(v ->> 'code' = 'already_moved', 'B2: botin siirron jälkeen asiakkaan oma siirto estetty ' || v::text);
  v := pg_temp.su_(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, v_s + interval '14 days', 'toinen'));
  perform pg_temp.ck(v ->> 'err' = 'already_moved', 'B3: botin toinen siirto estetty ' || v::text);
  v := pg_temp.su_(format('select booking.svc_move_reservation_to_rule(%s, %s, %s, %L::timestamptz, %L, %L)', v_ono, r, v_rule, v_s + interval '14 days', 'toinen', 'testi'));
  perform pg_temp.ck(v ->> 'err' = 'already_moved', 'B4: svc_move_reservation_to_rule (esikatselu) estetty ' || v::text);
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', r, v_rule, d + 56));
  perform pg_temp.ck(v ->> 'err' is null, 'B5: henkilökunta voi siirtää botin siirron jälkeen ' || v::text);
  -- asiakkaan oma siirto → botti ei enää siirrä
  t := (test.pub_book(v_rule, d + 35, 2, 'u@t308.example') ->> 'token')::uuid;
  v := pg_temp.anon_('10.8.2.2', format('select booking.public_change_booking(%L, %s, %L, null)', t, v_rule, d + 42));
  v_s := (test.res(t)).starts_at; v_ono := (test.ord(t)).order_no;
  v := pg_temp.su_(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, v_s + interval '7 days', 'asiakas pyysi'));
  perform pg_temp.ck(v ->> 'err' = 'already_moved', 'B6: asiakkaan oman siirron jälkeen botin siirto estetty ' || v::text);
  -- luokittelematon tuote: botti siirtää vapaasti
  update booking.product_config set cancellation_tier = null where product_id = v_prod;
  v := pg_temp.su_(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, v_s + interval '7 days', 'asiakas pyysi'));
  perform pg_temp.ck(v ->> 'err' is null, 'B7: luokittelematon tuote: ei kertarajaa ' || v::text);
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._customer_move_blocked(bigint)', 'execute')
                     and not has_function_privilege('authenticated', 'booking._customer_move_blocked(bigint)', 'execute'), 'S1: apufunktio ei anon/authenticated');
end $t$;
select 'RESULT ' || case when ok then 'ok' else 'NOT OK' end || ' - ' || label from t308_r;
select 'SUMMARY ' || count(*) filter (where not ok) || ' failed / ' || count(*) from t308_r;
rollback;
