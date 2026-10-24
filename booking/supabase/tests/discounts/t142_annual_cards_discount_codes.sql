-- t142: vuosikortit ja alennuskoodit (booking_142, paketti 10).
-- Hallinta: koodien luonti/normalisointi/generointi, oikeudet, yhteinen vuosikorttikoodi, vuosikortin koodi.
-- Kassa: esikatselu ja varaus koodilla (hinta palvelimelta), ALV-jako riveille, käyttökerrat, rajaukset,
-- vuosikorttivaraus (0 €, yksi tuleva varaus, omistajan tunnistus), alennuksen säilyminen muutoksessa,
-- vuosikortin verkko-osto (oletuksena pois, kortti vasta maksusta, jatkokortti) ja rate limit.
-- Kaikki data on feikkiä (@example.test). Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN.
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t142_r(ok boolean, label text) on commit drop;
grant all on t142_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t142_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql; return 'NO ERROR'; exception when others then get stacked diagnostics v = pg_exception_detail; return coalesce(nullif(v, ''), sqlerrm); end $$;
create function pg_temp.book(p_rule bigint, p_date date, p_persons int, p_email text, p_code text, p_addons jsonb default null,
  p_phone text default '0401234567', p_kind text default 'private', p_ip text default null) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(p_ip);
  j := booking.public_create_booking_code(p_rule, p_date, p_persons, 'Testi Asiakas', p_email, p_phone, false, 'fi', null, p_kind,
         case when p_kind = 'company' then '{"name":"Testi Oy","business_id":"1234567-1"}'::jsonb end, p_addons, p_code);
  perform test.logout(); return j; end $$;
create function pg_temp.prev(p_code text, p_rule bigint, p_date date, p_persons int, p_addons jsonb default null, p_email text default null, p_ip text default null)
returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(p_ip); j := booking.public_check_code(p_code, p_rule, p_date, p_persons, p_addons, p_email, null); perform test.logout(); return j; end $$;
create function pg_temp.oid_(p_res jsonb) returns bigint language sql as $$ select id from booking.orders where public_token = (p_res ->> 'token')::uuid $$;
do $t$
declare
  v_adm uuid := test.mk_staff('adm142@example.test', 'admin');
  v_staff uuid := test.mk_staff('staff142@example.test', 'staff');
  r_men bigint := 1;          -- Miesten sauna ma (tuote 2, yleinen)
  r_women bigint := 2;        -- Naisten sauna ti (tuote 3, yleinen)
  r_peat bigint := 4;         -- Turvetorstai (tuote 5, ei vuosikorttia)
  r_priv bigint := 19;        -- Oma savusaunavuoro (yksityinen)
  d_mon date := test.next_dow(1, 3); d_tue date := test.next_dow(2, 3); d_thu date := test.next_dow(4, 3); d_fri date := test.next_dow(5, 3);
  v_today date := (now() at time zone 'Europe/Helsinki')::date;
  j jsonb; j2 jsonb; v_id bigint; v_code text; v_o bigint; v_full numeric; v_cust bigint; v_cust2 bigint; v_card booking.annual_cards; v_n int;
  v_price43 numeric := (select price from kb.products where id = 43);
begin
  -- ===== Tekniset =====
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_check_code(text,bigint,date,integer,jsonb,text,text)', 'execute')
    and has_function_privilege('anon', 'booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text)', 'execute')
    and has_function_privilege('anon', 'booking.public_annual_card_offer()', 'execute')
    and has_function_privilege('anon', 'booking.public_buy_annual_card(text,text,text,boolean,text)', 'execute')
    and has_function_privilege('anon', 'booking.public_annual_card_purchase_code(uuid)', 'execute'), 'T1: julkiset RPC:t anonille');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)', 'execute')
    and not has_function_privilege('anon', 'booking._discount_split(booking.discount_codes,jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'booking._annual_card_from_order(bigint)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_save_discount_code(bigint,jsonb)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_create_annual_card(bigint,date,date,text,text)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_list_discount_codes()', 'execute'), 'T2: sisäiset ja hallinnan funktiot eivät anonille');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc p where p.pronamespace = 'booking'::regnamespace
    and p.proname in ('public_check_code', 'public_preview_code', 'public_create_booking_code', 'public_annual_card_offer', 'public_buy_annual_card',
      'public_annual_card_purchase_code', 'admin_list_discount_codes', 'admin_save_discount_code', 'admin_delete_discount_code',
      'admin_list_annual_cards_details', 'admin_create_annual_card', '_annual_card_from_order', '_discount_split')), 'T3: security definer, search_path tyhjä');
  perform pg_temp.ck((select count(*) from booking.discount_codes) = 0 and (select count(*) from booking.annual_cards) = 0, 'T4: migraatio ei luo koodeja eikä kortteja');
  perform pg_temp.ck((select value from booking.settings where key = 'annual_card_sale_enabled') = 'false'::jsonb, 'T5: vuosikortin verkkomyynti oletuksena pois');
  perform pg_temp.ck((select count(*) from pg_proc where proname = 'public_create_booking' and pronamespace = 'booking'::regnamespace) = 1, 'T6: public_create_booking ennallaan (ei ylikuormitusta)');

  -- ===== Hallinta =====
  v_cust := booking._upsert_customer('Kortti Asiakas', 'kortti142@example.test', '040 111 2222', false, 'test', 'fi', 'v1');
  v_cust2 := booking._upsert_customer('Toinen Kortti', 'kortti142b@example.test', '040 333 4444', false, 'test', 'fi', 'v1');
  perform test.login(v_staff);
  perform pg_temp.ck(pg_temp.err($$select booking.admin_save_discount_code(null, '{"code":"X1Y2Z3","kind":"percent","value":"10"}')$$) = 'forbidden'
    or pg_temp.err($$select booking.admin_save_discount_code(null, '{"code":"X1Y2Z3","kind":"percent","value":"10"}')$$) like '%oikeu%', 'A1: perusrooli ei saa luoda koodeja');
  perform test.logout();
  perform test.login(v_adm);
  j := booking.admin_save_discount_code(null, '{"code":" kesa20 ","kind":"percent","value":"20","usage_type":"single","target_scope":"order"}');
  perform pg_temp.ck(j ->> 'code' = 'KESA20' and (select max_uses from booking.discount_codes where code = 'KESA20') = 1, 'A2: koodi isoilla, kertakäyttö max_uses=1');
  j := booking.admin_save_discount_code(null, '{"code":"","kind":"fixed","value":"10","usage_type":"multi","max_uses":"5"}');
  perform pg_temp.ck(j ->> 'code' ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$', 'A3: tyhjä koodi → generoitu 6 merkkiä: ' || (j ->> 'code'));
  perform pg_temp.ck(pg_temp.err($$select booking.admin_save_discount_code(null, '{"code":"YLI100","kind":"percent","value":"150"}')$$) = 'invalid_value', 'A4: prosentti yli 100 hylätään');
  perform pg_temp.ck(pg_temp.err($$select booking.admin_save_discount_code(null, '{"code":"Kesa20","kind":"percent","value":"5"}')$$) = 'code_exists', 'A5: sama koodi eri kirjoitusasulla hylätään');
  perform pg_temp.ck(pg_temp.err($$select booking.admin_save_discount_code(null, '{"code":"TUOTE","kind":"percent","value":"5","target_scope":"product","product_ids":[]}')$$) = 'invalid_products', 'A6: tuotekohdistus vaatii tuotteet');
  j := booking.admin_save_discount_code(null, '{"code":"naiset15","kind":"percent","value":"15","usage_type":"permanent","target_scope":"product","product_ids":[3]}');
  j := booking.admin_save_discount_code(null, '{"code":"VANHA","kind":"percent","value":"10","usage_type":"permanent","valid_to":"2020-01-31"}');
  j := booking.admin_save_discount_code(null, '{"code":"TULEVA","kind":"percent","value":"10","usage_type":"permanent","valid_from":"2099-01-01"}');
  j := booking.admin_save_discount_code(null, '{"code":"POIS","kind":"percent","value":"10","usage_type":"permanent","active":false}');
  j := booking.admin_save_discount_code(null, '{"code":"ILMAINEN","kind":"percent","value":"100","usage_type":"permanent"}');
  j := booking.admin_save_discount_code(null, '{"code":"KYMPPI","kind":"fixed","value":"10","usage_type":"permanent"}');
  j := booking.admin_save_discount_code(null, '{"code":"vuosi-testi","is_annual_card_code":true,"kind":"fixed","value":"1"}');
  perform pg_temp.ck((select kind = 'percent' and value = 100 and usage_type = 'permanent' and target_scope = 'product' and product_ids = '{1,2,3,4,6}'::bigint[]
                        from booking.discount_codes where code = 'VUOSI-TESTI'), 'A7: yhteinen vuosikorttikoodi: 100 %, pysyvä, tuotteet 1,2,3,4,6');
  j := booking.admin_create_annual_card(v_cust, v_today, v_today + 364, null, 'testi');
  -- booking_143: generoitu koodi on 10 satunnaismerkkiä (ennen SANA+numero), ks. t143
  perform pg_temp.ck(j ->> 'code' ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$', 'A8: vuosikortin koodi generoitu (booking_143: 10 satunnaismerkkiä): ' || (j ->> 'code'));
  v_code := j ->> 'code';
  perform pg_temp.ck(pg_temp.err(format($$select booking.admin_create_annual_card(%s, %L, %L, 'KESA20')$$, v_cust2, v_today, v_today + 30)) = 'code_exists', 'A9: alennuskoodia ei voi käyttää vuosikortin koodina');
  perform pg_temp.ck(pg_temp.err(format($$select booking.admin_save_discount_code(null, '{"code":"%s","kind":"percent","value":"5"}')$$, v_code)) = 'code_exists', 'A10: vuosikortin koodia ei voi käyttää alennuskoodina');
  perform pg_temp.ck(pg_temp.err(format($$select booking.admin_create_annual_card(%s, %L, %L)$$, v_cust, v_today + 10, v_today + 40)) = 'annual_card_overlap', 'A11: päällekkäinen kortti hylätään');
  j := booking.admin_create_annual_card(v_cust2, v_today, v_today + 364, ' oma-kortti7 ', null);
  perform pg_temp.ck(j ->> 'code' = 'OMA-KORTTI7', 'A12: oma koodi normalisoidaan');
  perform pg_temp.ck(jsonb_array_length(booking.admin_list_discount_codes()) = 9 and jsonb_array_length(booking.admin_list_annual_cards_details()) = 2
    and (booking.admin_list_annual_cards_details() -> 0 ->> 'code') is not null, 'A13: listaukset');
  perform test.logout();

  -- ===== Kassa: alennuskoodi =====
  select total into v_full from booking._rule_price(r_men, 2);
  j := pg_temp.prev('kesa20', r_men, d_mon, 2);
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'subtotal')::numeric = v_full and (j ->> 'discount')::numeric = round(v_full * 0.2, 2)
    and (j ->> 'total')::numeric = v_full - round(v_full * 0.2, 2), 'P1: esikatselu laskee hinnan palvelimella: ');
  j := pg_temp.prev('EIOLE', r_men, d_mon, 2);
  perform pg_temp.ck(j ->> 'code' = 'invalid_code', 'P2: tuntematon koodi');
  perform pg_temp.ck(pg_temp.prev('VANHA', r_men, d_mon, 1) ->> 'code' = 'code_expired' and pg_temp.prev('TULEVA', r_men, d_mon, 1) ->> 'code' = 'code_not_started'
    and pg_temp.prev('POIS', r_men, d_mon, 1) ->> 'code' = 'code_inactive', 'P3: vanhentunut / ei alkanut / pois käytöstä');
  perform pg_temp.ck(pg_temp.prev('NAISET15', r_men, d_mon, 1) ->> 'code' = 'code_not_applicable' and (pg_temp.prev('NAISET15', r_women, d_tue, 1) ->> 'ok')::boolean,
    'P4: tuotekohdistettu koodi vain valitulle tuotteelle');

  v_n := (select count(*) from booking.orders);
  j := pg_temp.book(r_men, d_mon, 2, 'ale142@example.test', 'kesa20');
  v_o := pg_temp.oid_(j);
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'total')::numeric = v_full - round(v_full * 0.2, 2) and (j ->> 'discount')::numeric = round(v_full * 0.2, 2), 'P5: varaus koodilla: ');
  perform pg_temp.ck((select unit_price_gross = v_full and discount_amount = round(v_full * 0.2, 2) and line_total_gross = v_full - round(v_full * 0.2, 2)
                        and discount_code_id is not null and vat_rate = 25.5
                        and line_vat = round((v_full - round(v_full * 0.2, 2)) * 25.5 / 125.5, 2)
                        from booking.order_items where order_id = v_o and kind = 'reservation'), 'P6: rivi: yksikköhinta ennallaan, alennus riville, ALV alennetusta summasta');
  perform pg_temp.ck((select total_gross from booking.orders where id = v_o) = v_full - round(v_full * 0.2, 2)
    and (select amount from booking.payments where order_id = v_o and status = 'pending') = v_full - round(v_full * 0.2, 2)
    and (select used_count from booking.discount_codes where code = 'KESA20') = 1, 'P7: tilauksen summa, avoin maksu ja käyttökerta');
  perform pg_temp.ck((select price from kb.products where id = 2) = (select price from kb.products where id = 2) and (select total from booking._rule_price(r_men, 2)) = v_full, 'P8: tuotteen hinta ei muutu');
  j := pg_temp.book(r_men, d_mon, 1, 'ale142b@example.test', 'KESA20');
  perform pg_temp.ck(j ->> 'code' = 'code_used_up', 'P9: kertakäyttöinen koodi käytetty');
  j := pg_temp.book(r_men, d_mon, 1, 'ale142c@example.test', 'NAISET15');
  perform pg_temp.ck(j ->> 'code' = 'code_not_applicable' and (select count(*) from booking.orders) = v_n + 1, 'P10: koodi ei koske tuotetta → ei tilausta');
  j := pg_temp.book(r_men, d_mon, 1, 'ale142d@example.test', '');
  perform pg_temp.ck((j ->> 'ok')::boolean and (select discount_code_id is null and total_gross = (select total from booking._rule_price(r_men, 1)) from booking.orders where id = pg_temp.oid_(j)),
    'P11: tyhjä koodi → tavallinen varaus');

  -- ALV: euromääräinen koodi jaetaan riveille suhteessa, kukin rivi pitää oman ALV-kantansa
  update booking.addons set vat_rate = 13.5 where id = 2;
  j := pg_temp.book(r_men, d_mon, 2, 'alv142@example.test', 'KYMPPI', '[{"id":2,"quantity":2}]');
  v_o := pg_temp.oid_(j);
  perform pg_temp.ck((j ->> 'ok')::boolean and (select sum(discount_amount) from booking.order_items where order_id = v_o) = 10
    and (select total_gross from booking.orders where id = v_o) = v_full + 26 - 10, 'V1: 10 € jaettu riveille, summa ' || coalesce(j ->> 'total', j::text));
  perform pg_temp.ck((select bool_and(line_vat = round(line_total_gross * vat_rate / (100 + vat_rate), 2) and discount_amount > 0) from booking.order_items where order_id = v_o)
    and (select discount_amount from booking.order_items where order_id = v_o and kind = 'addon') = round(10 * 26 / (v_full + 26), 2), 'V2: alennus suhteessa, ALV per rivi oma kanta');
  perform test.login(v_adm);
  j2 := booking.admin_record_payment(v_o, 'card_terminal', v_full + 16, 'testi', null);
  perform test.logout();
  perform pg_temp.ck((select round(sum(pl.amount_gross), 2) from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id where p.order_id = v_o and p.status = 'paid') = v_full + 16
    and exists (select 1 from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id where p.order_id = v_o and pl.vat_rate = 13.5
                and pl.amount_gross = 26 - round(10 * 26 / (v_full + 26), 2)), 'V3: maksurivit alennetuista summista omilla ALV-kannoilla');

  -- 100 %: ei maksettavaa → vahvistettu ja maksettu 0 €
  j := pg_temp.book(r_women, d_tue, 1, 'free142@example.test', 'ilmainen');
  v_o := pg_temp.oid_(j);
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'total')::numeric = 0 and j ->> 'status' = 'confirmed'
    and (select payment_status = 'paid' and total_gross = 0 from booking.orders where id = v_o)
    and not exists (select 1 from booking.payments where order_id = v_o and status = 'pending'), 'P12: 100 % → vahvistettu, maksettu 0 €');

  -- alennus säilyy hallinnan muutoksessa (prosentti uudesta summasta)
  j := pg_temp.book(r_women, d_tue, 2, 'muutos142@example.test', 'naiset15');
  v_o := pg_temp.oid_(j);
  perform test.login(v_adm);
  perform booking.admin_change_booking((select id from booking.reservations where order_id = v_o), null, null, 3);
  perform test.logout();
  perform pg_temp.ck((select discount_amount = round((select total from booking._rule_price(r_women, 3)) * 0.15, 2)
       and line_total_gross = (select total from booking._rule_price(r_women, 3)) - round((select total from booking._rule_price(r_women, 3)) * 0.15, 2)
       from booking.order_items where order_id = v_o and kind = 'reservation')
    and (select total_gross from booking.orders where id = v_o) = (select line_total_gross from booking.order_items where order_id = v_o and kind = 'reservation'),
    'P13: henkilömäärän muutos: 15 % lasketaan uudesta hinnasta');

  -- maksamatta vanhentunut pito palauttaa käyttökerran
  perform test.login(v_adm);
  j := booking.admin_save_discount_code(null, '{"code":"PITO1","kind":"percent","value":"10","usage_type":"single"}');
  perform test.logout();
  j := pg_temp.book(r_women, d_tue, 1, 'pito142@example.test', 'PITO1');
  v_o := pg_temp.oid_(j);
  update booking.orders set status = 'pending' where id = v_o;
  update booking.orders set status = 'cancelled' where id = v_o;
  perform pg_temp.ck((select used_count from booking.discount_codes where code = 'PITO1') = 0, 'P14: peruttu maksamaton pito palauttaa käyttökerran');

  -- ===== Kassa: vuosikortti =====
  perform pg_temp.ck((pg_temp.prev(v_code, r_men, d_mon, 1, null, 'kortti142@example.test') ->> 'type') = 'annual_card'
    and (pg_temp.prev(v_code, r_men, d_mon, 1, null, 'kortti142@example.test') ->> 'total')::numeric = 0, 'K1: esikatselu vuosikortille 0 €');
  -- booking_143: väärä omistaja → sama geneerinen virhe kuin tuntemattomalla koodilla (ennen annual_card_customer_mismatch)
  perform pg_temp.ck(pg_temp.prev(v_code, r_men, d_mon, 1, null, 'joku@example.test') ->> 'code' = 'invalid_code', 'K2: väärä sähköposti → invalid_code');
  perform pg_temp.ck(pg_temp.book(r_peat, d_thu, 1, 'k3a142@example.test', v_code, null, '0401112222') ->> 'code' = 'annual_card_product'
    and pg_temp.book(r_priv, d_mon, 1, 'k3b142@example.test', v_code, null, '0401112222') ->> 'code' = 'annual_card_product', 'K3: Turvetorstai ja yksityisvuoro eivät käy');
  perform pg_temp.ck(pg_temp.book(r_men, d_mon, 2, 'k4a142@example.test', v_code, null, '0401112222') ->> 'code' = 'annual_card_persons'
    and pg_temp.book(r_men, d_mon, 1, 'k4b142@example.test', v_code, '[{"id":3,"quantity":1}]', '0401112222') ->> 'code' = 'annual_card_no_addons'
    and pg_temp.book(r_men, d_mon, 1, 'k4c142@example.test', v_code, null, '0401112222', 'company') ->> 'code' = 'annual_card_private_only', 'K4: henkilömäärä, lisäpalvelu, yritys');
  j := pg_temp.book(r_men, d_mon, 1, 'muu142@example.test', lower(v_code), null, '+358 40 111 2222');
  v_o := pg_temp.oid_(j);
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'total')::numeric = 0 and j ->> 'status' = 'confirmed' and j ->> 'code_type' = 'annual_card', 'K5: vuosikorttivaraus (tunnistus puhelinnumerolla +358)');
  perform pg_temp.ck((select annual_card_id from booking.reservations where order_id = v_o) = (select id from booking.annual_cards where code = v_code)
    and (select customer_id from booking.orders where id = v_o) = v_cust
    and exists (select 1 from booking.payments where order_id = v_o and method = 'annual_card' and status = 'paid' and amount = 0)
    and (select payment_status from booking.orders where id = v_o) = 'paid', 'K6: kortin asiakas, annual_card-maksu 0 €, maksettu');
  perform pg_temp.ck(pg_temp.book(r_women, d_tue, 1, 'kortti142@example.test', v_code) ->> 'code' = 'annual_card_limit', 'K7: vain yksi tuleva vuosikorttivaraus');
  update booking.annual_cards set active = false where code = 'OMA-KORTTI7';
  perform pg_temp.ck(pg_temp.book(r_men, d_mon, 1, 'kortti142b@example.test', 'OMA-KORTTI7') ->> 'code' = 'annual_card_inactive', 'K8: peruttu kortti');

  -- yhteinen vuosikorttikoodi
  j := pg_temp.book(r_women, d_tue, 1, 'yhteinen142@example.test', 'VUOSI-TESTI', null, '0405556666');
  v_o := pg_temp.oid_(j);
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'total')::numeric = 0 and j ->> 'code_type' = 'annual_code'
    and (select discount_code_id from booking.orders where id = v_o) = (select id from booking.discount_codes where code = 'VUOSI-TESTI')
    and (select discount_amount from booking.order_items where order_id = v_o and kind = 'reservation') = (select total from booking._rule_price(r_women, 1)), 'K9: yhteinen koodi: 0 €, alennus kirjattu');
  perform pg_temp.ck(pg_temp.book(r_men, d_mon, 1, 'yhteinen142@example.test', 'VUOSI-TESTI') ->> 'code' = 'annual_card_limit'
    and pg_temp.book(r_men, d_mon, 1, 'toinen142@example.test', 'VUOSI-TESTI', null, '+358405556666') ->> 'code' = 'annual_card_limit', 'K10: raja sähköpostilla ja puhelimella');
  perform test.login(v_adm);
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_change_booking(%s, null, null, 2)', (select id from booking.reservations where order_id = v_o))) = 'annual_card_persons', 'K11: yhteiskoodivarauksen henkilömäärää ei voi kasvattaa');
  perform booking.admin_save_discount_code((select id from booking.discount_codes where code = 'VUOSI-TESTI'), '{"code":"VUOSI-TESTI","is_annual_card_code":true,"kind":"percent","value":"100","valid_to":"2020-12-31"}');
  perform test.logout();
  perform pg_temp.ck(pg_temp.book(r_men, d_mon, 1, 'kolmas142@example.test', 'VUOSI-TESTI') ->> 'code' = 'code_expired', 'K12: vanhentunut yhteiskoodi');

  -- ===== Vuosikortin verkko-osto =====
  perform test.anon();
  perform pg_temp.ck(not (booking.public_annual_card_offer() ->> 'available')::boolean
    and booking.public_buy_annual_card('Osto Asiakas', 'osto142@example.test', '0407778888') ->> 'code' = 'sale_disabled', 'O1: myynti oletuksena pois');
  perform test.logout();
  update booking.settings set value = 'true'::jsonb where key = 'annual_card_sale_enabled';
  perform test.anon();
  j := booking.public_annual_card_offer();
  perform pg_temp.ck((j ->> 'available')::boolean and (j ->> 'price')::numeric = v_price43 and (j ->> 'product_id')::bigint = 43, 'O2: tarjous kb.products-hinnasta: ');
  j := booking.public_buy_annual_card('Osto Asiakas', 'kortti142@example.test', '0401112222');
  perform test.logout();
  v_o := pg_temp.oid_(j);
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'total')::numeric = v_price43
    and (select product_id = 43 and unit_price_gross = v_price43 and vat_rate = (select vat_rate from kb.products where id = 43) from booking.order_items where order_id = v_o)
    and exists (select 1 from booking.payments where order_id = v_o and status = 'pending' and amount = v_price43), 'O3: tilaus 1 × vuosikortti, avoin maksu');
  perform test.anon();
  j2 := booking.public_annual_card_purchase_code((j ->> 'token')::uuid);
  perform test.logout();
  perform pg_temp.ck((j2 ->> 'has_card')::boolean and j2 ->> 'code' is null and not exists (select 1 from booking.annual_cards where purchase_order_id = v_o), 'O4: ei korttia ennen maksua');
  perform test.login(v_adm);
  j2 := booking.admin_record_payment(v_o, 'card_terminal', v_price43, 'testi', null);
  perform test.logout();
  select * into v_card from booking.annual_cards where purchase_order_id = v_o;
  perform pg_temp.ck(v_card.id is not null and v_card.customer_id = v_cust and v_card.valid_from = v_today + 365 and v_card.valid_to = (v_today + 365 + interval '1 year' - interval '1 day')::date,
    'O5: maksu myöntää jatkokortin nykyisen jälkeen: ' || coalesce(v_card.valid_from::text, 'null'));
  perform test.anon();
  j2 := booking.public_annual_card_purchase_code((j ->> 'token')::uuid);
  perform test.logout();
  perform pg_temp.ck(j2 ->> 'code' = v_card.code, 'O6: tilaussivu näyttää koodin maksun jälkeen');
  perform test.anon();
  j := booking.public_buy_annual_card('Uusi Ostaja', 'uusi142@example.test', '0409990000');
  perform test.logout();
  v_o := pg_temp.oid_(j);
  update booking.payments set status = 'paid', paid_at = now() where order_id = v_o and status = 'pending';
  update booking.orders set payment_status = 'paid' where id = v_o;
  perform pg_temp.ck((select valid_from = v_today and valid_to = (v_today + interval '1 year' - interval '1 day')::date from booking.annual_cards where purchase_order_id = v_o)
    and (select count(*) from booking.annual_cards where purchase_order_id = v_o) = 1, 'O7: uusi asiakas: kortti tästä päivästä vuodeksi');
  update booking.orders set payment_status = 'pending' where id = v_o;
  update booking.orders set payment_status = 'paid' where id = v_o;
  perform pg_temp.ck((select count(*) from booking.annual_cards where purchase_order_id = v_o) = 1, 'O8: ei tuplakorttia');
  perform pg_temp.ck((select price from kb.products where id = 43) = v_price43, 'O9: vuosikortin hinta ennallaan');

  -- ===== Rate limit ja poisto =====
  for i in 1..20 loop j := pg_temp.prev('ARVAUS' || i, r_men, d_mon, 1, null, null, '203.0.113.42'); end loop;
  perform pg_temp.ck(pg_temp.prev('ARVAUS21', r_men, d_mon, 1, null, null, '203.0.113.42') ->> 'code' = 'rate_limited', 'R1: koodien arvaus rajoitettu (20 / 10 min / IP)');
  perform test.login(v_adm);
  j := booking.admin_delete_discount_code((select id from booking.discount_codes where code = 'KESA20'));
  perform pg_temp.ck((j ->> 'deactivated')::boolean
    and not (select active from booking.discount_codes where code = 'KESA20'), 'R2: käytetty koodi vain poistetaan käytöstä ');
  j := booking.admin_delete_discount_code((select id from booking.discount_codes where code = 'TULEVA'));
  perform pg_temp.ck((j ->> 'deleted')::boolean
    and not exists (select 1 from booking.discount_codes where code = 'TULEVA'), 'R3: käyttämätön koodi poistetaan');
  perform test.logout();

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t142_r where ok), (select count(*) from t142_r where not ok),
    coalesce((select string_agg(label, ' | ') from t142_r where not ok), 'ALL OK');
end $t$;
