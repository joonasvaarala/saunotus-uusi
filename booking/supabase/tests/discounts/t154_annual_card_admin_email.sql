-- t154: hallinnasta myönnetyn vuosikortin koodi sähköpostiin (booking_154).
-- Myönnetty kortti → yksi tilaukseton annual_card_code-rivi (dedupe annual_card_code:<id>, payload ilman henkilötietoja),
-- claim antaa vastaanottajan kortin asiakkaalta ja source 'admin'; päivitys / uudelleenaktivointi / koodin vaihto → ei uutta riviä;
-- peruttu / ei käytössä / kooditon / ei sähköpostia / "älä lähetä" → ei riviä; ostettu kortti → vain vanha polku (yksi rivi tilauksella);
-- olemassa olevat kortit (pre154) → ei rivejä; lähetys pois → skipped; oikeudet.
-- Kaikki data on feikkiä (@example.test). Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN
-- (pre154_existing_cards.sql ajetaan ennen booking_154-migraatiota; ilman sitä P-testit ohitetaan ja merkitään).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t154_r(ok boolean, label text) on commit drop;
grant all on t154_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t154_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql; return 'NO ERROR'; exception when others then get stacked diagnostics v = pg_exception_detail; return coalesce(nullif(v, ''), sqlerrm); end $$;
create function pg_temp.n(p_card bigint) returns int language sql as $$ select count(*)::int from booking.email_outbox where dedupe_key = 'annual_card_code:' || p_card $$;
do $t$
declare
  v_adm uuid := test.mk_staff('adm154@example.test', 'admin');
  v_staff uuid := test.mk_staff('staff154@example.test', 'staff');
  v_ed uuid := test.mk_user('asiakas154@example.test');
  v_mode text := (select mode from booking.integration_config where key = 'resend');
  v_price43 numeric := (select price from kb.products where id = 43);
  j jsonb; v_c1 bigint; v_c2 bigint; v_c3 bigint; v_c4 bigint; v_c5 bigint; v_c6 bigint; v_id bigint; v_o bigint;
  e booking.email_outbox; v_item jsonb; v_card booking.annual_cards; v_pre bigint; v_code text;
begin
  update booking.settings set value = 'true'::jsonb where key = 'annual_card_sale_enabled';
  insert into booking.settings(key, value) values ('site_base_url', '"https://uusi.saunotus.example/"'::jsonb)
    on conflict (key) do update set value = excluded.value;
  update booking.integration_config set mode = 'dry_run' where key = 'resend';
  insert into booking.customers(name, email) values ('Myönnetty Asiakas', 'myonnetty154@example.test') returning id into v_c1;
  insert into booking.customers(name, email, language) values ('Granted Customer', 'granted154@example.test', 'en') returning id into v_c2;
  insert into booking.customers(name, email) values ('Ei Lähetystä', 'eilah154@example.test') returning id into v_c3;
  insert into booking.customers(name, phone) values ('Puhelin Vain', '0401540154') returning id into v_c4;
  insert into booking.customers(name, email) values ('Viisi Param', 'viisi154@example.test') returning id into v_c5;
  insert into booking.customers(name, email) values ('Suora Lisäys', 'suora154@example.test') returning id into v_c6;

  -- ===== rakenne ja oikeudet =====
  perform pg_temp.ck(to_regprocedure('booking.admin_create_annual_card(bigint,date,date,text,text,boolean)') is not null
    and has_function_privilege('authenticated', 'booking.admin_create_annual_card(bigint,date,date,text,text,boolean)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_create_annual_card(bigint,date,date,text,text,boolean)', 'execute')
    and not has_function_privilege('authenticated', 'booking._annual_card_admin_to(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking.email_outbox_claim(integer)', 'execute')
    and has_function_privilege('service_role', 'booking.email_outbox_claim(integer)', 'execute'), 'T1: oikeudet');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.admin_create_annual_card(bigint,date,date,text,text)'::regprocedure)) = 'b80c1d146fc6b57ea99bb1635f8814ca'
    and md5(pg_get_functiondef('booking._enqueue_email(text,bigint,bigint,bigint,text,jsonb)'::regprocedure)) = 'e2eee7206bd6006ed93a81b1cdeecb32'
    and md5(pg_get_functiondef('booking.admin_annual_card_for_order(bigint)'::regprocedure)) = 'bcb6357539f043c779c7dab808a4618c', 'T2: 5-param. myöntö ja admin_annual_card_for_order ennallaan, _enqueue_email = booking_191');
  perform pg_temp.ck((select pg_get_triggerdef(oid) from pg_trigger where tgname = 'annual_cards_email' and tgrelid = 'booking.annual_cards'::regclass)
    ~* 'AFTER INSERT ON booking.annual_cards FOR EACH ROW EXECUTE', 'T3: trigger AFTER INSERT (ei UPDATE), ilman ostoehtoa');

  -- ===== olemassa olevat kortit (pre154) =====
  v_pre := (select id from booking.annual_cards where notes = 'pre154' order by id limit 1);
  if v_pre is null then
    perform pg_temp.ck(true, 'P0: pre154 ei ajettu → P-testit ohitettu');
  else
    perform pg_temp.ck(pg_temp.n(v_pre) = 0, 'P1: migraatio ei luo riviä olemassa olevalle kortille');
    update booking.annual_cards set notes = 'pre154 muokattu', valid_to = valid_to + 1 where id = v_pre;
    update booking.annual_cards set active = false where id = v_pre;
    update booking.annual_cards set active = true where id = v_pre;
    perform pg_temp.ck(pg_temp.n(v_pre) = 0, 'P2: olemassa olevan kortin päivitys / uudelleenaktivointi → ei riviä');
  end if;
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox e2 join booking.annual_cards a on e2.dedupe_key = 'annual_card_code:' || a.id
      where a.created_at < now() - interval '1 second' and a.purchase_order_id is null), 'P3: ei rivejä aiemmin luoduille hallinnan korteille');

  -- ===== myöntö, lähetä = kyllä =====
  perform test.login(v_adm);
  j := booking.admin_create_annual_card(v_c1, current_date, current_date + 364, null, 'testi', true);
  perform test.logout();
  v_id := (j ->> 'id')::bigint;
  select * into e from booking.email_outbox where dedupe_key = 'annual_card_code:' || v_id;
  perform pg_temp.ck(pg_temp.n(v_id) = 1 and e.kind = 'annual_card_code' and e.order_id is null and e.status = 'pending' and e.locale = 'fi'
    and e.payload = jsonb_build_object('card_id', v_id, 'source', 'admin'), 'A1: myönnetty kortti → yksi tilaukseton rivi, payload ilman henkilötietoja: ' || coalesce(row_to_json(e)::text, 'null'));
  perform pg_temp.ck(j #>> '{email,status}' = 'pending' and j ->> 'code' is not null, 'A2: vastaus kertoo sähköpostin tilan: ' || j::text);
  perform pg_temp.ck(e.payload::text !~ 'myonnetty154' and e.payload::text !~ (j ->> 'code'), 'A3: ei sähköpostia eikä koodia payloadissa');
  -- päivitykset → ei uutta riviä
  v_code := j ->> 'code';
  update booking.annual_cards set notes = 'muokattu', valid_to = valid_to + 1 where id = v_id;
  update booking.annual_cards set active = false, revoked_at = now() where id = v_id;
  update booking.annual_cards set active = true, revoked_at = null where id = v_id;
  update booking.annual_cards set code = 'VKUUSI1540' where id = v_id;
  perform pg_temp.ck(pg_temp.n(v_id) = 1 and (select count(*) from booking.email_outbox where kind = 'annual_card_code' and payload ->> 'card_id' = v_id::text) = 1,
    'A4: päivitys, peruminen, uudelleenaktivointi ja koodin vaihto → ei uutta riviä');
  -- claim: vastaanottaja kortin asiakkaalta, nykyinen koodi, source admin
  update booking.email_outbox set next_attempt_at = now() - interval '1 minute' where kind = 'annual_card_code';
  j := booking.email_outbox_claim(50);
  select x into v_item from jsonb_array_elements(j) x where (x ->> 'id')::bigint = e.id;
  perform pg_temp.ck(v_item ->> 'to' = 'myonnetty154@example.test' and v_item ->> 'to_name' = 'Myönnetty Asiakas'
    and v_item #>> '{annual_card,code}' = 'VKUUSI1540' and v_item #>> '{annual_card,source}' = 'admin'
    and (v_item #>> '{annual_card,active}')::boolean and not (v_item #>> '{annual_card,revoked}')::boolean
    and v_item #>> '{annual_card,booking_url}' = 'https://uusi.saunotus.example/varaa/', 'A5: claim: vastaanottaja kortin asiakkaalta, nykyinen koodi: ' || coalesce(v_item::text, 'null'));
  perform booking.email_outbox_mark(e.id, 'dry_run', null, 'dry_run: testi');
  update booking.annual_cards set code = 'VKTOINEN15' where id = v_id;
  perform pg_temp.ck(pg_temp.n(v_id) = 1 and (select status from booking.email_outbox where id = e.id) = 'dry_run', 'A6: lähetyksen jälkeen koodin vaihto → ei uutta viestiä');

  -- ===== EN-asiakas =====
  perform test.login(v_adm);
  j := booking.admin_create_annual_card(v_c2, current_date, current_date + 364, null, null, true);
  perform test.logout();
  select * into e from booking.email_outbox where dedupe_key = 'annual_card_code:' || (j ->> 'id');
  update booking.email_outbox set next_attempt_at = now() - interval '1 minute' where id = e.id;
  v_item := (select x from jsonb_array_elements(booking.email_outbox_claim(50)) x where (x ->> 'id')::bigint = e.id);
  perform pg_temp.ck(e.locale = 'en' and v_item #>> '{annual_card,booking_url}' = 'https://uusi.saunotus.example/en/book/' and v_item ->> 'to' = 'granted154@example.test', 'A7: EN-asiakas → en, /en/book/');

  -- ===== ei lähetystä =====
  perform test.login(v_adm);
  j := booking.admin_create_annual_card(v_c3, current_date, current_date + 364, null, null, false);
  perform pg_temp.ck(pg_temp.n((j ->> 'id')::bigint) = 0 and j #>> '{email,status}' = 'not_requested', 'N1: "Lähetä koodi asiakkaalle" pois → ei riviä');
  perform pg_temp.ck(coalesce(current_setting('booking.annual_card_email', true), '') = '', 'N2: ohitusasetus nollattu kutsun jälkeen');
  j := booking.admin_create_annual_card(v_c4, current_date, current_date + 364, null, null, true);
  perform pg_temp.ck(pg_temp.n((j ->> 'id')::bigint) = 0 and j #>> '{email,status}' = 'no_email', 'N3: ei sähköpostia → ei riviä, no_email');
  -- 5-parametrinen kutsu (vanha UI / asiakaskortti) → oletuksena lähetys
  j := booking.admin_create_annual_card(v_c5, current_date, current_date + 364, null, null);
  perform test.logout();
  perform pg_temp.ck(pg_temp.n((j ->> 'id')::bigint) = 1 and not (j ? 'email'), 'N4: 5-parametrinen myöntö → yksi rivi, vastaus ennallaan');
  -- suorat lisäykset: ei käytössä, peruttu, kooditon
  insert into booking.annual_cards(customer_id, valid_from, valid_to, active) values (v_c6, current_date, current_date + 364, false) returning id into v_id;
  perform pg_temp.ck(pg_temp.n(v_id) = 0, 'N5: ei käytössä → ei riviä');
  update booking.annual_cards set active = true where id = v_id;
  perform pg_temp.ck(pg_temp.n(v_id) = 0, 'N6: myöhempi aktivointi → ei riviä');
  delete from booking.annual_cards where id = v_id;
  insert into booking.annual_cards(customer_id, valid_from, valid_to, active, revoked_at) values (v_c6, current_date - 400, current_date - 40, false, now()) returning id into v_id;
  perform pg_temp.ck(pg_temp.n(v_id) = 0, 'N7: peruttu → ei riviä');
  -- kooditonta korttia ei voi tallentaa (code not null + booking142_card_code_format); trigger tarkistaa silti koodin
  alter table booking.annual_cards disable trigger annual_cards_code;
  perform pg_temp.ck(pg_temp.err(format('insert into booking.annual_cards(customer_id, valid_from, valid_to, code) values (%s, current_date + 400, current_date + 700, null)', v_c6)) <> 'NO ERROR'
    and pg_temp.err(format('insert into booking.annual_cards(customer_id, valid_from, valid_to, code) values (%s, current_date + 400, current_date + 700, %L)', v_c6, '  ')) <> 'NO ERROR'
    and position('btrim(coalesce(new.code, '''')) = ''''' in pg_get_functiondef('booking._annual_card_email_trg()'::regprocedure)) > 0, 'N8: kooditon kortti → ei tallennu, triggerissä koodin tarkistus');
  alter table booking.annual_cards enable trigger annual_cards_code;
  -- claim: peruttu jonossa oleva → annual_card.revoked (send-emails ohittaa)
  insert into booking.customers(name, email) values ('Peruttu Jonossa', 'peruttu154@example.test') returning id into v_c6;
  perform test.login(v_adm);
  j := booking.admin_create_annual_card(v_c6, current_date, current_date + 364, null, null, true);
  perform booking.admin_revoke_annual_card((j ->> 'id')::bigint, false);
  perform test.logout();
  select * into e from booking.email_outbox where dedupe_key = 'annual_card_code:' || (j ->> 'id');
  update booking.email_outbox set next_attempt_at = now() - interval '1 minute' where id = e.id;
  v_item := (select x from jsonb_array_elements(booking.email_outbox_claim(50)) x where (x ->> 'id')::bigint = e.id);
  perform pg_temp.ck((v_item #>> '{annual_card,revoked}')::boolean, 'N9: peruttu ennen lähetystä → claim kertoo revoked (send-emails ohittaa)');

  -- ===== lähetys pois → skipped =====
  update booking.integration_config set mode = 'off' where key = 'resend';
  insert into booking.customers(name, email) values ('Off Asiakas', 'off154@example.test') returning id into v_c6;
  perform test.login(v_adm);
  j := booking.admin_create_annual_card(v_c6, current_date, current_date + 364, null, null, true);
  perform test.logout();
  perform pg_temp.ck(j #>> '{email,status}' = 'skipped' and (select status from booking.email_outbox where dedupe_key = 'annual_card_code:' || (j ->> 'id')) = 'skipped', 'O1: lähetys pois → skipped');
  update booking.integration_config set mode = 'dry_run' where key = 'resend';

  -- ===== ostettu kortti: vain vanha polku =====
  perform test.anon(); j := booking.public_buy_annual_card('Osto Asiakas', 'osto154@example.test', '0401541111'); perform test.logout();
  v_o := (select id from booking.orders where public_token = (j ->> 'token')::uuid);
  perform test.login(v_staff);
  j := booking.admin_record_payment(v_o, 'card_terminal', v_price43, 'kassa', null);
  perform test.logout();
  select * into v_card from booking.annual_cards where purchase_order_id = v_o;
  select * into e from booking.email_outbox where dedupe_key = 'annual_card_code:' || v_card.id;
  perform pg_temp.ck(pg_temp.n(v_card.id) = 1 and e.order_id = v_o and e.payload = jsonb_build_object('card_id', v_card.id)
    and (select count(*) from booking.email_outbox where kind = 'annual_card_code' and payload ->> 'card_id' = v_card.id::text) = 1, 'B1: ostettu kortti → yksi rivi tilauksella (vanha polku), ei toista');
  update booking.email_outbox set next_attempt_at = now() - interval '1 minute' where id = e.id;
  v_item := (select x from jsonb_array_elements(booking.email_outbox_claim(50)) x where (x ->> 'id')::bigint = e.id);
  perform pg_temp.ck(v_item ->> 'to' = 'osto154@example.test' and v_item #>> '{annual_card,source}' = 'purchase' and v_item #>> '{order,order_no}' is not null, 'B2: ostetun kortin claim ennallaan (vastaanottaja tilaukselta)');
  perform pg_temp.ck(booking._annual_card_admin_to(e.id) is null, 'B3: ostetun kortin riville ei hallinnan vastaanottajaa');

  -- ===== oikeudet =====
  perform test.login(v_ed);
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_create_annual_card(%s, current_date, current_date + 1, null, null, true)', v_c3)) <> 'NO ERROR', 'R1: ei-henkilökunta → virhe');
  perform test.logout();
  -- jonotuksen virhe ei kaada myöntämistä
  insert into booking.customers(name, email) values ('Virhe Asiakas', 'virhe154@example.test') returning id into v_c6;
  execute $f$create or replace function booking._valid_email(p text) returns boolean language plpgsql as $b$ begin raise exception 'testivirhe'; end $b$$f$;
  perform test.login(v_adm);
  j := booking.admin_create_annual_card(v_c6, current_date, current_date + 364, null, null);
  perform test.logout();
  perform pg_temp.ck(exists (select 1 from booking.annual_cards where id = (j ->> 'id')::bigint)
    and exists (select 1 from booking.audit_log where action = 'annual_card_email_failed' and row_pk = j ->> 'id' and new_data ->> 'source' = 'admin'), 'R2: jonotuksen virhe → kortti syntyy, virhe audit-lokiin');

  update booking.integration_config set mode = v_mode where key = 'resend';
  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t154_r where ok), (select count(*) from t154_r where not ok),
    coalesce((select string_agg(label, ' | ') from t154_r where not ok), 'ALL OK');
end $t$;
