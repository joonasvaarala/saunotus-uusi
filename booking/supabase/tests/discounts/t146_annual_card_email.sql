-- t146: vuosikortin koodi sähköpostiin ja kassalle (booking_146).
-- Maksettu tuotteen 43 tilaus → kortti → yksi annual_card_code-viesti per kortti (dedupe), claim palauttaa koodin,
-- voimassaolon ja varauskalenterin linkin (fi /varaa/, en /en/book/); ei sähköpostia → ei viestiä, kassa näkee no_email;
-- käsin luotu kortti ei lähetä viestiä; lähetys pois (off) → skipped; oikeudet; hinnat ennallaan.
-- Kaikki data on feikkiä (@example.test). Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN.
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t146_r(ok boolean, label text) on commit drop;
grant all on t146_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t146_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql; return 'NO ERROR'; exception when others then get stacked diagnostics v = pg_exception_detail; return coalesce(nullif(v, ''), sqlerrm); end $$;
create function pg_temp.buy(p_name text, p_email text, p_phone text) returns bigint language plpgsql as $$
declare j jsonb; begin perform test.anon(); j := booking.public_buy_annual_card(p_name, p_email, p_phone); perform test.logout();
  if not coalesce((j ->> 'ok')::boolean, false) then raise exception 'osto epäonnistui: %', j; end if;
  return (select id from booking.orders where public_token = (j ->> 'token')::uuid); end $$;
do $t$
declare
  v_adm uuid := test.mk_staff('adm146@example.test', 'admin');
  v_staff uuid := test.mk_staff('staff146@example.test', 'staff');
  v_ed uuid := test.mk_user('asiakas146@example.test');
  v_price43 numeric := (select price from kb.products where id = 43);
  v_mode text := (select mode from booking.integration_config where key = 'resend');
  j jsonb; v_o bigint; v_o2 bigint; v_o3 bigint; v_card booking.annual_cards; e booking.email_outbox; v_n int; v_cust bigint; v_item jsonb;
begin
  update booking.settings set value = 'true'::jsonb where key = 'annual_card_sale_enabled';
  insert into booking.settings(key, value) values ('site_base_url', '"https://uusi.saunotus.example/"'::jsonb)
    on conflict (key) do update set value = excluded.value;
  update booking.integration_config set mode = 'dry_run' where key = 'resend';

  -- ===== rakenne ja oikeudet =====
  perform pg_temp.ck(pg_get_constraintdef((select oid from pg_constraint where conname = 'email_outbox_kind_check'))
      ~ 'annual_card_code' and pg_get_constraintdef((select oid from pg_constraint where conname = 'email_outbox_kind_check')) ~ 'waitlist_spot_freed', 'T1: kind-rajoite: annual_card_code + vanhat lajit');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_annual_card_for_order(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking.email_outbox_claim(integer)', 'execute')
    and not has_function_privilege('authenticated', 'booking.email_outbox_claim_base_146(integer)', 'execute')
    and not has_function_privilege('authenticated', 'booking._annual_card_mail(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking._annual_card_email_trg()', 'execute')
    and has_function_privilege('service_role', 'booking.email_outbox_claim(integer)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_annual_card_for_order(bigint)', 'execute'), 'T2: oikeudet');
  perform pg_temp.ck((select bool_and(p.prosecdef and p.proconfig @> array['search_path=""']) from pg_proc p
     where p.pronamespace = 'booking'::regnamespace and p.proname in ('admin_annual_card_for_order', '_annual_card_mail', '_annual_card_email_trg', 'email_outbox_claim')), 'T3: security definer, search_path tyhjä');

  -- ===== verkko-osto → maksu kassalla → kortti + viesti =====
  v_o := pg_temp.buy('Osto Asiakas', 'osto146@example.test', '0401112222');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = v_o and kind = 'annual_card_code'), 'E1: ei viestiä ennen maksua');
  perform test.login(v_staff);
  j := booking.admin_annual_card_for_order(v_o);
  perform pg_temp.ck((j ->> 'has_season_card')::boolean and j -> 'card' = 'null'::jsonb, 'E2: kassa: kortti tulossa, ei vielä koodia');
  j := booking.admin_record_payment(v_o, 'card_terminal', v_price43, 'kassa', null);
  perform test.logout();
  select * into v_card from booking.annual_cards where purchase_order_id = v_o;
  select * into e from booking.email_outbox where order_id = v_o and kind = 'annual_card_code';
  perform pg_temp.ck(v_card.id is not null and e.id is not null and e.dedupe_key = 'annual_card_code:' || v_card.id
    and e.status = 'pending' and e.locale = 'fi' and (e.payload ->> 'card_id')::bigint = v_card.id
    and e.payload::text !~ v_card.code, 'E3: maksu → kortti ja yksi jonossa oleva viesti (koodi ei payloadissa)');
  perform test.login(v_staff);
  j := booking.admin_annual_card_for_order(v_o);
  perform test.logout();
  perform pg_temp.ck(j #>> '{card,code}' = v_card.code and (j #>> '{card,valid_from}')::date = v_card.valid_from and (j #>> '{card,valid_to}')::date = v_card.valid_to
    and j #>> '{email,status}' = 'pending' and j #>> '{email,to}' = 'osto146@example.test', 'E4: kassa näkee koodin, voimassaolon ja sähköpostin tilan: ' || j::text);
  -- tila vaihtelee → ei toista viestiä
  update booking.orders set payment_status = 'pending' where id = v_o;
  update booking.orders set payment_status = 'paid' where id = v_o;
  perform booking._annual_card_from_order(v_o);
  perform pg_temp.ck((select count(*) from booking.email_outbox where kind = 'annual_card_code' and order_id = v_o) = 1, 'E5: vain yksi viesti per kortti');

  -- ===== claim =====
  update booking.email_outbox set next_attempt_at = now() - interval '1 minute' where kind = 'annual_card_code';
  j := booking.email_outbox_claim(50);
  select x into v_item from jsonb_array_elements(j) x where (x ->> 'id')::bigint = e.id;
  perform pg_temp.ck(v_item #>> '{annual_card,code}' = v_card.code and (v_item #>> '{annual_card,valid_to}')::date = v_card.valid_to
    and v_item #>> '{annual_card,booking_url}' = 'https://uusi.saunotus.example/varaa/' and (v_item #>> '{annual_card,active}')::boolean
    and v_item ->> 'to' = 'osto146@example.test' and v_item #>> '{order,order_no}' is not null, 'E6: claim: koodi, voimassaolo, kalenterilinkki: ' || coalesce(v_item::text, 'null'));
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(j) x where x ->> 'kind' <> 'annual_card_code' and x ? 'annual_card'), 'E7: muut viestit ennallaan');
  perform booking.email_outbox_mark(e.id, 'dry_run', null, 'dry_run: testi');
  perform test.login(v_staff);
  perform pg_temp.ck(booking.admin_annual_card_for_order(v_o) #>> '{email,status}' = 'dry_run', 'E8: kassa: dry_run-tila näkyy');
  perform test.logout();

  -- ===== englanti =====
  v_o2 := pg_temp.buy('English Buyer', 'en146@example.test', '0401113333');
  update booking.orders set locale = 'en' where id = v_o2;
  perform test.login(v_adm);
  j := booking.admin_record_payment(v_o2, 'card_terminal', v_price43, 'kassa', null);
  perform test.logout();
  select * into e from booking.email_outbox where order_id = v_o2 and kind = 'annual_card_code';
  update booking.email_outbox set next_attempt_at = now() - interval '1 minute' where id = e.id;
  j := booking.email_outbox_claim(50);
  select x into v_item from jsonb_array_elements(j) x where (x ->> 'id')::bigint = e.id;
  perform pg_temp.ck(e.locale = 'en' and v_item #>> '{annual_card,booking_url}' = 'https://uusi.saunotus.example/en/book/', 'E9: EN-viesti ja /en/book/');

  -- ===== ei sähköpostia =====
  v_o3 := pg_temp.buy('Puhelin Asiakas', 'puh146@example.test', '0401114444');
  update booking.customers set email = null where id = (select customer_id from booking.orders where id = v_o3);
  perform test.login(v_staff);
  j := booking.admin_record_payment(v_o3, 'card_terminal', v_price43, 'kassa', null);
  j := booking.admin_annual_card_for_order(v_o3);
  perform test.logout();
  perform pg_temp.ck(j #>> '{card,code}' is not null and j #>> '{email,status}' = 'no_email' and j #>> '{email,to}' is null
    and not exists (select 1 from booking.email_outbox where order_id = v_o3 and kind = 'annual_card_code'), 'E10: ei sähköpostia → kortti syntyy, ei viestiä, kassa näkee no_email');

  -- ===== lähetys pois → skipped =====
  update booking.integration_config set mode = 'off' where key = 'resend';
  v_o3 := pg_temp.buy('Off Asiakas', 'off146@example.test', '0401115555');
  update booking.payments set status = 'paid', paid_at = now() where order_id = v_o3 and status = 'pending';
  update booking.orders set payment_status = 'paid' where id = v_o3;
  perform test.login(v_staff);
  j := booking.admin_annual_card_for_order(v_o3);
  perform test.logout();
  perform pg_temp.ck(j #>> '{email,status}' = 'skipped', 'E11: verkkomaksu (suora maksu) ja lähetys pois → skipped');
  update booking.integration_config set mode = 'dry_run' where key = 'resend';

  -- ===== käsin luotu kortti =====
  insert into booking.customers(name, email) values ('Käsin Kortti', 'kasin146@example.test') returning id into v_cust;
  perform test.login(v_adm);
  j := booking.admin_create_annual_card(v_cust, current_date, current_date + 30, null, 'testi');
  perform test.logout();
  -- booking_154 muutti tämän: hallinnasta myönnetty kortti saa yhden oman viestin (tilaukseton rivi, source admin); t154 testaa tarkemmin.
  if to_regprocedure('booking._annual_card_admin_to(bigint)') is null then
    perform pg_temp.ck(not exists (select 1 from booking.email_outbox e2 where e2.dedupe_key = 'annual_card_code:' || (select id from booking.annual_cards where customer_id = v_cust)),
      'E12: hallinnassa käsin luotu kortti ei lähetä viestiä (ennen booking_154)');
  else
    perform pg_temp.ck((select count(*) from booking.email_outbox e2 where e2.dedupe_key = 'annual_card_code:' || (select id from booking.annual_cards where customer_id = v_cust)
      and e2.order_id is null and e2.payload ->> 'source' = 'admin') = 1, 'E12: hallinnassa käsin luotu kortti → yksi tilaukseton viesti (booking_154)');
  end if;

  -- ===== oikeudet ja tilaus ilman korttia =====
  perform test.login(v_ed);
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_annual_card_for_order(%s)', v_o)) <> 'NO ERROR', 'P1: kirjautunut ei-henkilökunta → virhe');
  perform test.logout();
  perform test.anon();
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_annual_card_for_order(%s)', v_o)) <> 'NO ERROR', 'P2: anon → virhe');
  perform test.logout();
  v_o2 := (select id from booking.orders where id not in (select order_id from booking.order_items oi join kb.products p on p.id = oi.product_id where p.category = 'season_card') order by id limit 1);
  perform test.login(v_adm);
  j := booking.admin_annual_card_for_order(coalesce(v_o2, -1));
  perform pg_temp.ck(coalesce(not (j ->> 'has_season_card')::boolean and j -> 'card' = 'null'::jsonb, j ->> 'code' = 'not_found'), 'P3: tilaus ilman vuosikorttia → ei korttia');
  perform pg_temp.ck(booking.admin_annual_card_for_order(-1) ->> 'code' = 'not_found', 'P4: tuntematon tilaus');
  perform test.logout();

  -- ===== jonotuksen virhe ei kaada maksua eikä kortin myöntämistä (testin sisäinen korvaus; DO-lohko kumotaan lopuksi) =====
  v_o3 := pg_temp.buy('Virhe Asiakas', 'virhe146@example.test', '0401116666');
  execute $f$create or replace function booking._enqueue_email(p_kind text, p_order_id bigint, p_receipt_id bigint, p_payment_id bigint, p_dedupe text, p_payload jsonb default '{}'::jsonb)
    returns boolean language plpgsql security definer set search_path = '' as $b$ begin if p_kind = 'annual_card_code' then raise exception 'testivirhe'; end if; return false; end $b$$f$;
  perform test.login(v_staff);
  j := booking.admin_record_payment(v_o3, 'card_terminal', v_price43, 'kassa', null);
  perform test.logout();
  perform pg_temp.ck((select payment_status from booking.orders where id = v_o3) = 'paid' and exists (select 1 from booking.annual_cards where purchase_order_id = v_o3)
    and exists (select 1 from booking.audit_log where action = 'annual_card_email_failed' and new_data ->> 'order_id' = v_o3::text), 'E13: viestin virhe → maksu ja kortti säilyvät, virhe audit-lokiin');

  perform pg_temp.ck((select price from kb.products where id = 43) = v_price43, 'S1: vuosikortin hinta ennallaan');
  perform pg_temp.ck(position('annual_card_sale_enabled' in pg_get_functiondef('booking._annual_card_from_order(bigint)'::regprocedure)) = 0,
    'S2: _annual_card_from_order ennallaan (kassan myynti luo kortin asetuksesta riippumatta)');
  update booking.integration_config set mode = v_mode where key = 'resend';

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t146_r where ok), (select count(*) from t146_r where not ok),
    coalesce((select string_agg(label, ' | ') from t146_r where not ok), 'ALL OK');
end $t$;
