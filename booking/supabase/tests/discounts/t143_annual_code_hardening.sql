-- t143: vuosikortti- ja alennuskoodien kovennus (booking_143, paketti 10 jatko).
-- Koodit: 10 merkin satunnainen vuosikorttikoodi (ei 0/O/1/I/L), yksilöllisyys, vanhat koodit ennallaan.
-- Rate limit ilman IP:tä (sähköposti, puhelin, henkilökohtainen kortti, yhteinen IP-ton raja); yhteiset koodit ilman koodikohtaista rajaa.
-- Väärä kortin omistaja → sama geneerinen virhe kuin tuntemattomalla koodilla. Vuosikorttivarauksen alennus = alkuperäinen hinta.
-- Peruutus (asiakas, hallinta, hyvitys, kassan mitätöinti, vanheneminen) palauttaa käyttökerran ja palautus ottaa sen takaisin.
-- Kaikki data on feikkiä (@example.test). Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN.
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t143_r(ok boolean, label text) on commit drop;
grant all on t143_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t143_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql; return 'NO ERROR'; exception when others then get stacked diagnostics v = pg_exception_detail; return coalesce(nullif(v, ''), sqlerrm); end $$;
create function pg_temp.book(p_rule bigint, p_date date, p_persons int, p_email text, p_code text, p_phone text default null,
  p_ip text default null) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(p_ip);
  j := booking.public_create_booking_code(p_rule, p_date, p_persons, 'Testi Asiakas', p_email,
         coalesce(p_phone, '040' || lpad((abs(hashtext(p_email)) % 10000000)::text, 7, '0')), false, 'fi', null, 'private', null, null, p_code);
  perform test.logout(); return j; end $$;
create function pg_temp.prev(p_code text, p_rule bigint, p_date date, p_persons int, p_email text default null, p_phone text default null, p_ip text default null)
returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(p_ip); j := booking.public_check_code(p_code, p_rule, p_date, p_persons, null, p_email, p_phone); perform test.logout(); return j; end $$;
create function pg_temp.oid_(p_res jsonb) returns bigint language sql as $$ select id from booking.orders where public_token = (p_res ->> 'token')::uuid $$;
create function pg_temp.used(p_code text) returns int language sql as $$ select used_count from booking.discount_codes where code = p_code $$;
create function pg_temp.res_(p_order bigint) returns bigint language sql as $$ select id from booking.reservations where order_id = p_order order by id limit 1 $$;
do $t$
declare
  v_adm uuid := test.mk_staff('adm143@example.test', 'admin');
  r_men bigint := 1;          -- Miesten sauna ma (tuote 2, yleinen)
  r_women bigint := 2;        -- Naisten sauna ti (tuote 3, yleinen)
  r_peat bigint := 4;         -- Turvetorstai (tuote 5, ei vuosikorttia)
  d_mon date := test.next_dow(1, 3); d_tue date := test.next_dow(2, 3); d_thu date := test.next_dow(4, 3);
  d_mon2 date := test.next_dow(1, 3) + 7;
  v_today date := (now() at time zone 'Europe/Helsinki')::date;
  j jsonb; j2 jsonb; v_code text; v_code2 text; v_o bigint; v_o2 bigint; v_r bigint; v_cust bigint; v_cust2 bigint; v_n int; v_ok boolean;
  v_codes text[] := '{}'; v_c text;
  v_price2 numeric := (select price from kb.products where id = 2); v_price43 numeric := (select price from kb.products where id = 43);
  v_full1 numeric := (select total from booking._rule_price(1, 1)); v_full_w numeric := (select total from booking._rule_price(2, 1));
  v_sale jsonb := (select value from booking.settings where key = 'annual_card_sale_enabled');
begin
  perform test.reset_rl();
  -- ===== Tekniset =====
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._code_rate_ok(text,text,text,text)', 'execute')
    and not has_function_privilege('authenticated', 'booking._code_rate_ok(text,text,text,text)', 'execute')
    and not has_function_privilege('anon', 'booking._generate_annual_card_code()', 'execute')
    and not has_function_privilege('anon', 'booking._annual_res_discount_trg()', 'execute')
    and not has_function_privilege('anon', 'booking._discount_reclaim_trg()', 'execute'), 'T1: uudet sisäiset funktiot eivät anonille');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_check_code(text,bigint,date,integer,jsonb,text,text)', 'execute')
    and has_function_privilege('anon', 'booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text)', 'execute')
    and not has_function_privilege('anon', 'booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)', 'execute'), 'T2: julkiset oikeudet ennallaan');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc p where p.pronamespace = 'booking'::regnamespace
    and p.proname in ('_generate_annual_card_code', '_code_rate_ok', 'public_preview_code', 'public_check_code', 'public_create_booking_code',
                      '_annual_res_discount_trg', '_discount_release_trg', '_discount_reclaim_trg')), 'T3: security definer, search_path tyhjä');
  perform pg_temp.ck(exists (select 1 from pg_trigger where tgname = 'reservations_annual_discount' and tgrelid = 'booking.reservations'::regclass)
    and exists (select 1 from pg_trigger where tgname = 'orders_discount_release' and tgrelid = 'booking.orders'::regclass)
    and exists (select 1 from pg_trigger where tgname = 'orders_discount_reclaim' and tgrelid = 'booking.orders'::regclass), 'T4: triggerit');
  perform pg_temp.ck((select count(*) from booking.discount_codes) = 0 and (select count(*) from booking.annual_cards) = 0, 'T5: migraatio ei luo koodeja eikä kortteja');

  -- ===== 1) Koodin muoto ja satunnaisuus =====
  for i in 1..300 loop v_codes := v_codes || booking._generate_annual_card_code(); end loop;
  perform pg_temp.ck((select bool_and(c ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$') from unnest(v_codes) c), 'G1: 10 merkkiä sallitusta aakkostosta');
  perform pg_temp.ck((select bool_and(c !~ '[01OIL]') from unnest(v_codes) c), 'G2: ei 0/O/1/I/L');
  perform pg_temp.ck((select count(distinct c) from unnest(v_codes) c) = 300, 'G3: 300 koodia, kaikki eri');
  perform pg_temp.ck((select count(distinct ch) from unnest(v_codes) c, regexp_split_to_table(c, '') ch) = 31
    and (select max(n) from (select count(*) n from unnest(v_codes) c, regexp_split_to_table(c, '') ch group by ch) x) < 200,
    'G4: kaikki 31 merkkiä käytössä, ei vinoumaa');
  v_cust := booking._upsert_customer('Kortti Asiakas', 'kortti143@example.test', '040 111 2223', false, 'test', 'fi', 'v1');
  v_cust2 := booking._upsert_customer('Toinen Kortti', 'kortti143b@example.test', '040 333 4445', false, 'test', 'fi', 'v1');
  perform test.login(v_adm);
  j := booking.admin_create_annual_card(v_cust, v_today, v_today + 364, null, 'testi');
  v_code := j ->> 'code';
  perform pg_temp.ck(v_code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$', 'G6: hallinnan luoma kortti saa satunnaiskoodin: ' || coalesce(v_code, j::text));
  j := booking.admin_create_annual_card(v_cust2, v_today, v_today + 364, ' oma-kortti43 ', null);
  v_code2 := j ->> 'code';
  perform pg_temp.ck(v_code2 = 'OMA-KORTTI43', 'G7: oma (vanhanmuotoinen) koodi hyväksytään edelleen ennallaan');
  perform pg_temp.ck(pg_temp.err(format($$select booking.admin_create_annual_card(%s, %L, %L, %L)$$, v_cust2, v_today + 400, v_today + 700, v_code)) = 'code_exists',
    'G8: sama koodi toiselle kortille hylätään');
  j := booking.admin_save_discount_code(null, '{"code":"KAMPANJA43","kind":"percent","value":"10","usage_type":"permanent"}');
  j := booking.admin_save_discount_code(null, '{"code":"KERTA43","kind":"percent","value":"20","usage_type":"single"}');
  j := booking.admin_save_discount_code(null, '{"code":"KAKSI43","kind":"fixed","value":"5","usage_type":"multi","max_uses":"2"}');
  j := booking.admin_save_discount_code(null, '{"code":"VUOSI43","is_annual_card_code":true,"kind":"percent","value":"100"}');
  perform test.logout();
  perform pg_temp.ck((select code from booking.annual_cards where customer_id = v_cust) = v_code
    and (select code from booking.annual_cards where customer_id = v_cust2) = 'OMA-KORTTI43', 'G9: tallennetut koodit ennallaan');

  -- ===== 1) Väärä omistaja → sama virhe kuin tuntematon koodi =====
  perform test.reset_rl();
  j := pg_temp.prev('EIOLEMASSA9', r_men, d_mon, 1, 'joku143@example.test');
  j2 := pg_temp.prev(v_code, r_men, d_mon, 1, 'joku143@example.test');
  perform pg_temp.ck(j ->> 'code' = 'invalid_code' and j2 = j, 'L1: esikatselu, väärä sähköposti = tuntematon koodi (sama vastaus): ' || j2::text);
  perform pg_temp.ck(pg_temp.prev(v_code, r_peat, d_thu, 1, 'joku143@example.test') = pg_temp.prev('EIOLEMASSA9', r_peat, d_thu, 1, 'joku143@example.test'),
    'L2: väärä omistaja + väärä tuote → silti invalid_code (ei paljasta korttia)');
  perform pg_temp.ck(pg_temp.prev(v_code, r_men, d_mon, 1, null, '0409998887') ->> 'code' = 'invalid_code', 'L3: väärä puhelin → invalid_code');
  perform pg_temp.ck(pg_temp.prev(v_code, r_men, d_mon, 1, 'kortti143@example.test') ->> 'type' = 'annual_card'
    and pg_temp.prev(v_code, r_men, d_mon, 1, 'muu143@example.test', '+358 40 111 2223') ->> 'type' = 'annual_card', 'L4: oikea omistaja (sähköposti tai puhelin) → vuosikortti');
  perform pg_temp.ck((pg_temp.prev(v_code, r_men, d_mon, 1) ->> 'ok')::boolean, 'L5: ilman yhteystietoja esikatselu toimii (UI ennallaan)');
  update booking.annual_cards set active = false where code = 'OMA-KORTTI43';
  perform pg_temp.ck(pg_temp.prev('OMA-KORTTI43', r_men, d_mon, 1, 'joku143@example.test') ->> 'code' = 'invalid_code'
    and pg_temp.prev('OMA-KORTTI43', r_men, d_mon, 1, 'kortti143b@example.test') ->> 'code' = 'annual_card_inactive', 'L6: ei-voimassa oleva kortti: vieraalle invalid_code, omistajalle syy');
  v_n := (select count(*) from booking.orders);
  j := pg_temp.book(r_men, d_mon, 1, 'joku143@example.test', v_code, '0409998887');
  j2 := pg_temp.book(r_men, d_mon, 1, 'joku143@example.test', 'EIOLEMASSA9', '0409998887');
  perform pg_temp.ck(j ->> 'code' = 'invalid_code' and j = j2 and (select count(*) from booking.orders) = v_n, 'L7: varaus vieraalla → invalid_code, ei tilausta: ' || j::text);
  j := pg_temp.book(r_peat, d_thu, 1, 'joku143@example.test', 'OMA-KORTTI43', '0409998887');
  perform pg_temp.ck(j ->> 'code' = 'invalid_code', 'L8: varaus vieraalla, ei-voimassa kortti ja väärä tuote → invalid_code');
  update booking.annual_cards set active = true where code = 'OMA-KORTTI43';

  -- ===== 1) Rate limit ilman IP:tä =====
  perform test.reset_rl();
  for i in 1..20 loop j := pg_temp.prev('ARVAUS' || i, r_men, d_mon, 1, 'arvaaja143@example.test'); end loop;
  perform pg_temp.ck(pg_temp.prev('ARVAUS21', r_men, d_mon, 1, 'arvaaja143@example.test') ->> 'code' = 'rate_limited'
    and pg_temp.prev('ARVAUS21', r_men, d_mon, 1, 'ARVAAJA143@example.test ') ->> 'code' = 'rate_limited', 'R1: ilman IP:tä sähköpostikohtainen raja 20 / 10 min');
  perform pg_temp.ck((pg_temp.prev('KAMPANJA43', r_men, d_mon, 1, 'toinen143@example.test') ->> 'ok')::boolean, 'R2: raja ei koske muita sähköposteja');
  perform test.reset_rl();
  for i in 1..20 loop j := pg_temp.prev('ARVAUS' || i, r_men, d_mon, 1, 'a' || i || '@example.test', '040 777 0000'); end loop;
  perform pg_temp.ck(pg_temp.prev('ARVAUS21', r_men, d_mon, 1, 'b@example.test', '+358407770000') ->> 'code' = 'rate_limited', 'R3: puhelinkohtainen raja');
  perform test.reset_rl();
  for i in 1..20 loop j := pg_temp.prev(v_code, r_men, d_mon, 1, 'vieras' || i || '@example.test'); end loop;
  perform pg_temp.ck(pg_temp.prev(v_code, r_men, d_mon, 1, 'kortti143@example.test') ->> 'code' = 'rate_limited'
    and pg_temp.book(r_men, d_mon, 1, 'kortti143@example.test', v_code) ->> 'code' = 'rate_limited', 'R4: henkilökohtaisen kortin koodikohtainen raja (vaihtuvat sähköpostit)');
  perform pg_temp.ck(not exists (select 1 from booking.rate_limit_hits where bucket like '%' || v_code || '%'), 'R5: korttikoodi ei näy selväkielisenä rajauksessa');
  perform test.reset_rl();
  for i in 1..30 loop j := pg_temp.prev('KAMPANJA43', r_men, d_mon, 1, 'asiakas' || i || '@example.test', null, '198.51.100.' || i); end loop;
  perform pg_temp.ck((j ->> 'ok')::boolean, 'R6: yhteisellä koodilla ei koodikohtaista rajaa (30 asiakasta)');
  perform test.reset_rl();
  for i in 1..200 loop j := pg_temp.prev('ARVAUS' || i, r_men, d_mon, 1); end loop;
  perform pg_temp.ck((j ->> 'code') = 'invalid_code' and pg_temp.prev('ARVAUS201', r_men, d_mon, 1) ->> 'code' = 'rate_limited'
    and (pg_temp.prev('KAMPANJA43', r_men, d_mon, 1, null, null, '203.0.113.7') ->> 'ok')::boolean, 'R7: ilman IP:tä ja yhteystietoja yhteinen raja 200 / 10 min; IP:llinen ei kärsi');
  perform test.reset_rl();
  for i in 1..20 loop j := pg_temp.prev('ARVAUS' || i, r_men, d_mon, 1, null, null, '203.0.113.42'); end loop;
  perform pg_temp.ck(pg_temp.prev('ARVAUS21', r_men, d_mon, 1, null, null, '203.0.113.42') ->> 'code' = 'rate_limited', 'R8: IP-raja 20 / 10 min ennallaan');
  perform test.reset_rl();
  for i in 1..20 loop j := pg_temp.book(r_men, d_mon, 1, 'varaaja143@example.test', 'ARVAUS' || i, '0405550000'); end loop;
  perform pg_temp.ck(j ->> 'code' = 'invalid_code' and pg_temp.book(r_men, d_mon, 1, 'varaaja143@example.test', 'KAMPANJA43', '0405550000') ->> 'code' = 'rate_limited',
    'R9: varaus koodilla: raja toimii ilman IP:tä');
  perform test.reset_rl();

  -- ===== 2) Vuosikorttivarauksen alennus = alkuperäinen hinta =====
  j := pg_temp.book(r_men, d_mon, 1, 'kortti143@example.test', v_code, '0401112223');
  v_o := pg_temp.oid_(j);
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'total')::numeric = 0 and j ->> 'code_type' = 'annual_card', 'D1: henkilökohtainen kortti 0 €: ' || j::text);
  perform pg_temp.ck((select unit_price_gross = 0 and line_total_gross = 0 and line_vat = 0 and discount_amount = v_full1 and discount_code_id is null
                        from booking.order_items where order_id = v_o and kind = 'reservation')
    and (select total_gross from booking.orders where id = v_o) = 0 and (j ->> 'discount')::numeric = v_full1, 'D2: rivin alennus = vuoron alkuperäinen hinta ' || v_full1);
  perform test.login(v_adm);
  perform booking.admin_change_booking(pg_temp.res_(v_o), r_men, d_mon2, null);
  perform test.logout();
  perform pg_temp.ck((select discount_amount = v_full1 and line_total_gross = 0 from booking.order_items where order_id = v_o and kind = 'reservation')
    and (select total_gross from booking.orders where id = v_o) = 0, 'D3: päivän muutos: alennus säilyy, summa 0 €');
  perform test.login(v_adm);
  perform booking.admin_cancel_reservation(pg_temp.res_(v_o), 'testi');
  j := booking.admin_create_annual_card_booking(v_cust2, r_women, d_tue, 'testi');
  perform test.logout();
  v_o2 := (j ->> 'order_id')::bigint;
  perform pg_temp.ck((select discount_amount = v_full_w and line_total_gross = 0 from booking.order_items where order_id = v_o2 and kind = 'reservation'),
    'D4: hallinnan vuosikorttivaraus: alennus = alkuperäinen hinta ' || v_full_w || ' / ' || j::text);
  j := pg_temp.book(r_women, d_tue, 1, 'yhteinen143@example.test', 'VUOSI43', '0406660000');
  perform pg_temp.ck((select discount_amount from booking.order_items where order_id = pg_temp.oid_(j) and kind = 'reservation') = v_full_w, 'D5: yhteinen vuosikorttikoodi ennallaan (alennus täysi)');
  perform pg_temp.ck((select price from kb.products where id = 2) = v_price2 and (select total from booking._rule_price(1, 1)) = v_full1
    and (select price from kb.products where id = 43) = v_price43, 'D6: hinnat ennallaan');

  -- ===== 3) Peruutus palauttaa käyttökerran =====
  -- peruttu vuosikorttivaraus vapauttaa kortin (raja laskee vain voimassa olevat)
  j := pg_temp.book(r_women, d_tue, 1, 'kortti143@example.test', v_code, '0401112223');
  perform pg_temp.ck((j ->> 'ok')::boolean, 'C1: henkilökohtainen kortti vapautuu peruutuksen jälkeen: ' || j::text);
  -- vahvistettu (maksamaton, pay later) tilaus, hallinta perii
  j := pg_temp.book(r_men, d_mon, 2, 'kerta143@example.test', 'KERTA43');
  v_o := pg_temp.oid_(j);
  perform pg_temp.ck((j ->> 'ok')::boolean and (select status from booking.orders where id = v_o) = 'confirmed' and pg_temp.used('KERTA43') = 1, 'C2: kertakoodi käytetty, tilaus vahvistettu');
  perform test.login(v_adm);
  perform booking.admin_cancel_reservation(pg_temp.res_(v_o), 'testi');
  perform test.logout();
  perform pg_temp.ck((select status from booking.orders where id = v_o) = 'cancelled' and pg_temp.used('KERTA43') = 0, 'C3: hallinnan peruutus palauttaa käyttökerran');
  -- palautus ottaa käyttökerran takaisin
  perform test.login(v_adm);
  perform booking.admin_set_reservation_status(pg_temp.res_(v_o), 'confirmed', 'testi');
  perform test.logout();
  perform pg_temp.ck((select status from booking.orders where id = v_o) <> 'cancelled' and pg_temp.used('KERTA43') = 1, 'C4: palautus ottaa käyttökerran takaisin');
  perform test.login(v_adm);
  perform booking.admin_set_reservation_status(pg_temp.res_(v_o), 'cancelled', 'testi');
  perform test.logout();
  j := pg_temp.book(r_men, d_mon, 1, 'kerta143b@example.test', 'KERTA43');
  perform pg_temp.ck((j ->> 'ok')::boolean and pg_temp.used('KERTA43') = 1, 'C5: peruttu kertakoodi kelpaa uudelleen');
  -- maksettu tilaus: hyvitys + peruutus
  j := pg_temp.book(r_men, d_mon, 1, 'kaksi143@example.test', 'KAKSI43');
  v_o := pg_temp.oid_(j);
  j := pg_temp.book(r_men, d_mon, 1, 'kaksi143b@example.test', 'KAKSI43');
  perform pg_temp.ck(pg_temp.used('KAKSI43') = 2 and pg_temp.book(r_men, d_mon, 1, 'kaksi143c@example.test', 'KAKSI43') ->> 'code' = 'code_used_up', 'C6: kaksi käyttöä täynnä');
  perform test.login(v_adm);
  perform booking.admin_record_payment(v_o, 'card_terminal', (select total_gross from booking.orders where id = v_o), 'testi', null);
  j2 := booking.admin_refund_order((select id from booking.payments where order_id = v_o and status = 'paid' order by id limit 1),
          (select total_gross from booking.orders where id = v_o), 'testi', null, true);
  perform test.logout();
  perform pg_temp.ck((select status from booking.orders where id = v_o) = 'cancelled' and pg_temp.used('KAKSI43') = 1, 'C7: maksetun tilauksen hyvitys + peruutus palauttaa käyttökerran: ' || j2::text);
  perform pg_temp.ck((pg_temp.book(r_men, d_mon, 1, 'kaksi143c@example.test', 'KAKSI43') ->> 'ok')::boolean and pg_temp.used('KAKSI43') = 2, 'C8: vapautunut käyttö kelpaa');
  -- asiakkaan peruutus (pito) ja vanheneminen → peruttu: vain yksi palautus
  perform test.login(v_adm);
  j := booking.admin_save_discount_code(null, '{"code":"PITO43","kind":"percent","value":"10","usage_type":"multi","max_uses":"5"}');
  perform test.logout();
  j := pg_temp.book(r_women, d_tue, 1, 'pito143@example.test', 'PITO43');
  v_o := pg_temp.oid_(j);
  update booking.orders set status = 'pending' where id = v_o;
  update booking.orders set status = 'expired' where id = v_o;
  update booking.orders set status = 'cancelled' where id = v_o;
  perform pg_temp.ck(pg_temp.used('PITO43') = 0, 'C9: pending → expired → cancelled palauttaa käyttökerran kerran');
  j := pg_temp.book(r_women, d_tue, 1, 'pito143b@example.test', 'PITO43');
  v_o := pg_temp.oid_(j);
  update booking.orders set status = 'pending' where id = v_o;
  update booking.reservations set status = 'pending', hold_expires_at = now() + interval '15 minutes' where order_id = v_o;   -- maksamaton pito (asiakas voi perua)
  perform test.anon();
  j2 := booking.public_cancel_booking((j ->> 'token')::uuid);
  perform test.logout();
  perform pg_temp.ck((select status from booking.orders where id = v_o) = 'cancelled' and pg_temp.used('PITO43') = 0, 'C10: asiakkaan peruutus palauttaa käyttökerran: ' || j2::text);
  -- mikä tahansa polku, joka vie vahvistetun tilauksen tilaan cancelled (esim. hyvitys ilman varauksia)
  j := pg_temp.book(r_women, d_tue, 1, 'suora143@example.test', 'PITO43');
  v_o := pg_temp.oid_(j);
  update booking.orders set status = 'cancelled' where id = v_o;
  perform pg_temp.ck(pg_temp.used('PITO43') = 0, 'C11: vahvistettu → cancelled (suora tilan muutos) palauttaa käyttökerran');
  -- yhteinen vuosikorttikoodi: peruutus palauttaa käyttökerran ja vapauttaa rajan
  j := pg_temp.book(r_men, d_mon, 1, 'yhteinen143@example.test', 'VUOSI43', '0406660000');
  perform pg_temp.ck(j ->> 'code' = 'annual_card_limit', 'C12: yhteiskoodi: yksi tuleva varaus');
  v_n := pg_temp.used('VUOSI43');
  v_o := (select o.id from booking.orders o join booking.customers c on c.id = o.customer_id where c.email = 'yhteinen143@example.test' and o.status <> 'cancelled' order by o.id desc limit 1);
  perform test.login(v_adm);
  perform booking.admin_cancel_reservation(pg_temp.res_(v_o), 'testi');
  perform test.logout();
  perform pg_temp.ck(pg_temp.used('VUOSI43') = v_n - 1 and (pg_temp.book(r_men, d_mon, 1, 'yhteinen143@example.test', 'VUOSI43', '0406660000') ->> 'ok')::boolean
    and pg_temp.used('VUOSI43') = v_n, 'C13: yhteiskoodi: peruutus palauttaa käyttökerran ja vapauttaa rajan');
  perform pg_temp.ck(not exists (select 1 from booking.discount_codes where used_count < 0), 'C14: käyttökerrat eivät mene negatiivisiksi');

  -- ===== EI muutettu: tuotteen 43 maksu kassalla luo kortin asetuksesta riippumatta =====
  perform pg_temp.ck(v_sale = 'false'::jsonb, 'S1: verkkomyynti pois');
  perform pg_temp.ck(position('annual_card_sale_enabled' in pg_get_functiondef('booking._annual_card_from_order(bigint)'::regprocedure)) = 0,
    'S2: _annual_card_from_order ennallaan (ei asetustarkistusta, odottaa päätöstä)');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t143_r where ok), (select count(*) from t143_r where not ok),
    coalesce((select string_agg(label, ' | ') from t143_r where not ok), 'ALL OK');
end $t$;
