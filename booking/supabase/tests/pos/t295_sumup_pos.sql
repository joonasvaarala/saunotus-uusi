-- t295: Pikakassan korttipääte (SumUp Solo, Cloud API, booking_295). Rollback-transaktio: lopuksi tahallinen poikkeus TESTRESULT.
-- Kattaa: oletuksena off (maksutapa piilossa, Edge-RPC:t kieltäytyvät), CheckoutX piilossa aina, oikeudet, tilan kytkentä
-- (test/live vaativat approved_by, live vain admin, dry_run estetty), lukijan tallennus, valmistelu, maksettu vain rajapintavahvistuksella
-- (p_confirmed_by='api', summa täsmää), hylätty/peruttu → uusi yritys, hyvityksen claim/complete/fail, osittainen hyvitys-kytkin.
-- Ei CI:ssä (Pages-työnkulussa ei ole Postgresia). Ajetaan psql:llä VAIN paikallisessa/DEV-kannassa migraation 295 jälkeen:
--   psql -v ON_ERROR_STOP=0 -f t295_sumup_pos.sql   (lopputulos: poikkeus "TESTRESULT pass=N fail=M")
-- TÄTÄ EI OLE AJETTU tässä ympäristössä (ei Postgresia, ei DEV-yhteyttä).
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t295.log', '', true);
create function public.t295_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t295.log', coalesce(current_setting('t295.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t295_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t295_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t295_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_admin uuid := gen_random_uuid();
  u_mgr uuid := gen_random_uuid();
  u_staff uuid := gen_random_uuid();
  p_prod bigint;
  items jsonb;
  res jsonb;
  oid bigint;
  pid bigint;
  pid2 bigint;
  rid bigint;
  v_montonio text;
  v_cx text;
  log text;
  npass int;
  nfail int;
  n_other int;
begin
  select mode into v_montonio from booking.integration_config where key = 'montonio';
  select mode into v_cx from booking.integration_config where key = 'checkoutx';

  -- G: oikeudet
  perform public.t295_ck(not has_function_privilege('authenticated', 'booking.sumup_pos_prepare(bigint,text,uuid)', 'execute'), 'G1 authenticated ei prepare');
  perform public.t295_ck(not has_function_privilege('anon', 'booking.sumup_pos_apply(bigint,text,text,text,numeric,jsonb)', 'execute'), 'G2 anon ei apply');
  perform public.t295_ck(not has_function_privilege('authenticated', 'booking.sumup_pos_apply(bigint,text,text,text,numeric,jsonb)', 'execute'), 'G3 authenticated ei apply');
  perform public.t295_ck(not has_function_privilege('authenticated', 'booking.sumup_reader_save(text,text,uuid)', 'execute'), 'G4 authenticated ei reader_save');
  perform public.t295_ck(not has_function_privilege('authenticated', 'booking.sumup_refund_complete(bigint,jsonb)', 'execute'), 'G5 authenticated ei refund_complete');
  perform public.t295_ck(has_function_privilege('service_role', 'booking.sumup_pos_prepare(bigint,text,uuid)', 'execute'), 'G6 service_role prepare');
  perform public.t295_ck(has_function_privilege('authenticated', 'booking.admin_get_sumup_status()', 'execute'), 'G7 authenticated status');
  perform public.t295_ck(not has_function_privilege('anon', 'booking.admin_set_sumup_mode(text,text)', 'execute'), 'G8 anon ei set_mode');
  perform public.t295_ck(not has_table_privilege('authenticated', 'booking.sumup_readers', 'select'), 'G9 lukijataulu ei suoraan luettavissa');
  perform public.t295_ck((select bool_and(prosecdef and proconfig::text like '%search_path=%') from pg_proc where pronamespace = 'booking'::regnamespace and proname like '%sumup%' and proname not like '%_trg'), 'G10 definer + search_path');
  perform public.t295_ck(not has_function_privilege('anon', 'booking.sumup_pos_lookup_ref(text)', 'execute'), 'G11 anon ei lookup_ref');

  insert into kb.products(name, category, price, vat_rate, active) values ('t295 Vichy', 'other', 3.50, 13.5, true) returning id into p_prod;
  insert into booking.product_config(product_id, sale_kind, bookable, pos_enabled, pos_sort, fridge_sale)
  values (p_prod, 'other', false, true, 10, false);
  items := jsonb_build_array(jsonb_build_object('product_id', p_prod, 'quantity', 2));
  insert into auth.users(id, email) values (u_admin, 't295-admin@example.test'), (u_mgr, 't295-mgr@example.test'), (u_staff, 't295-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_admin, 't295-admin@example.test', 't295 admin', 'admin'),
    (u_mgr, 't295-mgr@example.test', 't295 mgr', 'manager'),
    (u_staff, 't295-staff@example.test', 't295 staff', 'staff');

  -- O: oletuksena off → maksutapa piilossa, Edge-RPC:t kieltäytyvät
  perform public.t295_ck(booking._sumup_mode() = 'off', 'O1 oletus off');
  select count(*) into n_other from booking.pos_tenders where handler not in ('sumup', 'checkoutx');
  perform public.t295_login(u_staff);
  res := booking.admin_pos_tenders();
  perform public.t295_ck(not exists (select 1 from jsonb_array_elements(res->'tenders') x where x->>'handler' = 'sumup'), 'O2 off: sumup ei tenders-listassa');
  perform public.t295_ck(res->>'sumup_mode' = 'off', 'O3 off: sumup_mode=off');
  perform public.t295_ck(jsonb_array_length(res->'tenders') = n_other, 'O4 muut maksutavat ennallaan');
  perform public.t295_ck(not exists (select 1 from jsonb_array_elements(res->'tenders') x where x->>'handler' = 'checkoutx'), 'O4b checkoutx piilossa aina');
  res := booking.admin_pos_checkout(items, 'fi', null);
  oid := (res->>'order_id')::bigint;
  perform public.t295_ck(public.t295_try('select booking.admin_set_sumup_mode(''test'', ''t295'')') = 'forbidden', 'O5 staff ei saa kytkeä');
  perform public.t295_logout();
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_prepare(%s, ''rdr_t295'', null)', oid)) = 'sumup_off', 'O6 off: prepare kielletty');
  perform public.t295_ck(public.t295_try('select booking.sumup_reader_save(''rdr_t295'', ''Testi'', null)') = 'sumup_off', 'O7 off: reader_save kielletty');
  perform public.t295_ck((booking.sumup_refund_claim(1)->'claimed') = '[]'::jsonb, 'O8 off: refund_claim tyhjä');

  -- M: kytkentä
  perform public.t295_login(u_admin);
  perform public.t295_ck(public.t295_try('select booking.admin_set_sumup_mode(''dry_run'', ''t295'')') = 'invalid_param', 'M1 dry_run hylätään');
  perform public.t295_ck(public.t295_try('select booking.admin_set_sumup_mode(''test'', null)') = 'approval_required', 'M2 test vaatii approved_by');
  perform public.t295_ck(public.t295_try('select booking.admin_set_sumup_mode(''live'', null)') = 'approval_required', 'M2b live vaatii approved_by');
  res := booking.admin_set_sumup_mode('test', 't295 Joonas');
  perform public.t295_ck(res->>'mode' = 'test' and res->>'approved_by' = 't295 Joonas', 'M3 test päälle');
  perform public.t295_logout();
  perform public.t295_ck(public.t295_try('update booking.integration_config set mode = ''live'', settings = settings - ''approved_by'' where key = ''sumup''') = 'approval_required', 'M4 live ilman approved_by estetty triggerillä');
  perform public.t295_ck(public.t295_try('update booking.integration_config set mode = ''test'', settings = settings - ''approved_by'' where key = ''sumup''') = 'approval_required', 'M5 test ilman approved_by estetty triggerillä');
  perform public.t295_ck(public.t295_try('update booking.integration_config set mode = ''dry_run'' where key = ''sumup''') like '23514:%', 'M6 dry_run estetty rajoitteella');
  perform public.t295_login(u_mgr);
  perform public.t295_ck(public.t295_try('select booking.admin_set_sumup_mode(''live'', ''t295'')') = 'forbidden', 'M7 live vain admin');
  perform public.t295_logout();
  perform public.t295_ck((select count(*) from pg_constraint where conrelid = 'booking.integration_config'::regclass and conname = 'integration_config_key_check' and pg_get_constraintdef(oid) like '%''sumup''%' and pg_get_constraintdef(oid) like '%''checkoutx''%' and pg_get_constraintdef(oid) like '%''montonio''%') = 1, 'M8 key_check sisältää sumup ja säilyttää vanhat');

  -- T: lukija
  perform public.t295_ck(public.t295_try('select booking.sumup_reader_save(''bad id!'', ''x'', null)') = 'invalid_param', 'T1 virheellinen tunnus');
  res := booking.sumup_reader_save('rdr_t295', '  Kassalukija  ', u_admin);
  perform public.t295_ck(res->>'name' = 'Kassalukija', 'T2 tallennus');
  perform public.t295_ck((select is_default and env = 'test' from booking.sumup_readers where reader_id = 'rdr_t295'), 'T2b ensimmäinen lukija on oletus, env=test');
  perform booking.sumup_reader_save('rdr_t295b', 'Toinen', u_admin);
  perform public.t295_ck(not (select is_default from booking.sumup_readers where reader_id = 'rdr_t295b'), 'T2c toinen ei ole oletus');
  perform public.t295_login(u_admin);
  perform booking.admin_sumup_reader_set_default('rdr_t295b');
  perform public.t295_ck((select count(*) from booking.sumup_readers where is_default and active and env = 'test') = 1 and (select is_default from booking.sumup_readers where reader_id = 'rdr_t295b'), 'T2d oletuksen vaihto');
  perform public.t295_logout();
  perform public.t295_login(u_staff);
  res := booking.admin_get_sumup_status();
  perform public.t295_ck(jsonb_array_length(res->'readers') = 2 and res->'readers'->0->>'reader_id' = 'rdr_t295b', 'T3 status listaa lukijat (oletus ensin)');
  perform public.t295_ck(public.t295_try('select booking.admin_sumup_reader_remove(''rdr_t295b'')') = 'forbidden', 'T3b staff ei poista lukijaa');
  res := booking.admin_pos_tenders();
  perform public.t295_ck(exists (select 1 from jsonb_array_elements(res->'tenders') x where x->>'handler' = 'sumup' and (x->>'active')::boolean), 'T4 test: sumup tenders-listassa');
  perform public.t295_ck(not exists (select 1 from jsonb_array_elements(res->'tenders') x where x->>'handler' = 'checkoutx'), 'T4b checkoutx edelleen piilossa');
  perform public.t295_logout();

  -- P: valmistelu ja maksettu
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_prepare(%s, ''unknown01'', null)', oid)) = 'reader_not_paired', 'P1 tuntematon lukija');
  res := booking.sumup_pos_prepare(oid, 'rdr_t295', u_staff);
  pid := (res->>'payment_id')::bigint;
  perform public.t295_ck(res->>'amount' = '7.00' and res->>'currency' = 'EUR', 'P2 summa = tilauksen maksamaton osuus (2 x 3,50)');
  perform public.t295_ck((select status = 'pending' and method = 'sumup' and provider = 'sumup' and link_expires_at > now() and provider_ref is null from booking.payments where id = pid), 'P3 avoin maksurivi 15 min');
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_apply(%s, ''paid'', ''txn_t295'', ''api'', 7.00, null)', pid)) = 'payment_not_started', 'P4 apply ennen checkoutia kielletty');
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_started(%s, ''bad id!'')', pid)) = 'invalid_param', 'P5 virheellinen checkout-tunnus');
  perform booking.sumup_pos_started(pid, 'ctx_t295_1');
  res := booking.sumup_pos_lookup(pid);
  perform public.t295_ck(res->>'client_transaction_id' = 'ctx_t295_1' and res->>'reader_id' = 'rdr_t295' and res->>'status' = 'pending', 'P6 lookup');
  perform public.t295_ck(booking.sumup_pos_lookup_ref('ctx_t295_1')->>'payment_id' = pid::text and (booking.sumup_pos_lookup_ref('ei_ole_1')->>'found')::boolean = false, 'P6b lookup_ref');
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_started(%s, ''ctx_t295_2'')', pid)) = 'ref_conflict', 'P7 toinen tunnus hylätään');
  -- webhook yksin ei riitä: paid ilman api-vahvistusta hylätään
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_apply(%s, ''paid'', ''txn_t295'', null, 7.00, null)', pid)) = 'not_confirmed', 'P7b paid ilman api-vahvistusta hylätään');
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_apply(%s, ''paid'', ''txn_t295'', ''webhook'', 7.00, null)', pid)) = 'not_confirmed', 'P7c paid webhook-lähteellä hylätään');
  perform public.t295_ck((select status from booking.payments where id = pid) = 'pending', 'P7d maksu edelleen avoin');
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_apply(%s, ''paid'', ''txn_t295'', ''api'', 6.50, null)', pid)) like '%:%Summa ei täsmää%' or public.t295_try(format('select booking.sumup_pos_apply(%s, ''paid'', ''txn_t295'', ''api'', 6.50, null)', pid)) = 'amount_mismatch', 'P7e väärä summa hylätään');
  -- F: epäonnistunut → uusi yritys
  res := booking.sumup_pos_apply(pid, 'failed', null, null, null, '{"status":"FAILED"}'::jsonb);
  perform public.t295_ck(res->>'status' = 'failed' and (select status from booking.payments where id = pid) = 'failed', 'F1 epäonnistunut kirjataan');
  perform public.t295_ck((select status from booking.orders where id = oid) = 'pending', 'F2 tilaus jää avoimeksi');
  res := booking.sumup_pos_prepare(oid, 'rdr_t295', u_staff);
  pid2 := (res->>'payment_id')::bigint;
  perform public.t295_ck(pid2 <> pid and res->>'amount' = '7.00', 'F3 uusi yritys samalle tilaukselle');
  perform booking.sumup_pos_started(pid2, 'ctx_t295_3');
  res := booking.sumup_pos_apply(pid2, 'paid', 'txn_t295', 'api', 7.00, '{"status":"SUCCESSFUL"}'::jsonb);
  perform public.t295_ck(res->>'ok' = 'true' and res->>'status' = 'paid', 'P8 maksettu');
  perform public.t295_ck((select status = 'paid' and provider_status = 'SUCCESSFUL' and paid_at is not null and provider_ref = 'ctx_t295_3' and raw->>'transaction_id' = 'txn_t295' and raw->>'confirmed_by' = 'api' from booking.payments where id = pid2), 'P9 maksurivi paid + provider_ref + transaktio-id');
  perform public.t295_ck(not ((select raw from booking.payments where id = pid2)::text ~* '(card|pan|name|email)'), 'P9b raw ei sisällä kortti- eikä henkilötietoja');
  perform public.t295_ck((select payment_status from booking.orders where id = oid) = 'paid', 'P10 tilaus maksettu');
  perform public.t295_ck(exists (select 1 from booking.receipts where order_id = oid), 'P11 kuitti syntyi');
  res := booking.sumup_pos_apply(pid2, 'paid', 'txn_t295', 'api', 7.00, null);
  perform public.t295_ck(res->>'already' = 'true', 'P12 toisto idempotentti');
  perform public.t295_ck((booking.sumup_pos_apply(pid2, 'cancelled', null, null, null, null))->>'unchanged' = 'true', 'P13 maksettua ei peruta');
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_prepare(%s, ''rdr_t295'', null)', oid)) = 'order_not_payable', 'P14 maksettua tilausta ei voi maksaa uudelleen');
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_apply(%s, ''bogus'', null, null, null, null)', pid2)) = 'invalid_param', 'P15 tuntematon lopputulos');

  -- R: hyvitys (admin_refund → requested → claim → complete)
  perform public.t295_login(u_admin);
  res := booking.admin_refund(pid2, 7.00, 't295 testihyvitys', null, false);
  perform public.t295_logout();
  rid := (res->>'refund_id')::bigint;
  perform public.t295_ck(res->>'status' = 'requested' and (select provider from booking.refunds where id = rid) = 'sumup', 'R1 admin_refund luo sumup-pyynnön');
  res := booking.sumup_refund_claim(rid);
  perform public.t295_ck(jsonb_array_length(res->'claimed') = 1 and res->'claimed'->0->>'transaction_id' = 'txn_t295' and res->'claimed'->0->>'payment_amount' = '7.00' and (res->>'partial_refund')::boolean = false, 'R2 claim');
  perform public.t295_ck(jsonb_array_length(booking.sumup_refund_claim(rid)->'claimed') = 0, 'R3 toinen claim ei ota samaa');
  res := booking.sumup_refund_complete(rid, '{"transaction_id":"txn_t295"}'::jsonb);
  perform public.t295_ck((select status from booking.refunds where id = rid) = 'done' and (select status from booking.payments where id = pid2) = 'refunded', 'R4 hyvitys kirjattu');
  perform public.t295_ck((booking.sumup_refund_complete(rid, null))->>'already' = 'true', 'R5 toisto idempotentti');
  perform public.t295_ck((booking.sumup_refund_fail(rid, '{}'::jsonb))->>'unchanged' = 'true', 'R6 valmista ei merkitä epäonnistuneeksi');
  perform public.t295_ck(exists (select 1 from booking.audit_log where action = 'SUMUP_REFUND' and row_pk = rid::text), 'R7 audit');

  -- C: peruutus ja luonnin epäonnistuminen
  perform public.t295_login(u_staff);
  res := booking.admin_pos_checkout(items, 'fi', null);
  perform public.t295_logout();
  oid := (res->>'order_id')::bigint;
  pid := ((booking.sumup_pos_prepare(oid, 'rdr_t295', null))->>'payment_id')::bigint;
  res := booking.sumup_pos_create_failed(pid, '{"reason":"t295"}'::jsonb);
  perform public.t295_ck(res->>'status' = 'failed' and (select provider_status from booking.payments where id = pid) = 'create_failed', 'C1 luonti epäonnistui → rivi pois');
  pid := ((booking.sumup_pos_prepare(oid, 'rdr_t295', null))->>'payment_id')::bigint;
  perform booking.sumup_pos_started(pid, 'ctx_t295_4');
  -- uusi yritys korvaa avoimen ja palauttaa korvatun checkoutin terminate-tietoineen
  res := booking.sumup_pos_prepare(oid, 'rdr_t295', null);
  perform public.t295_ck((select status from booking.payments where id = pid) = 'cancelled' and jsonb_array_length(res->'superseded') = 1 and res->'superseded'->0->>'client_transaction_id' = 'ctx_t295_4', 'C1b korvattu yritys palauttaa terminate-tiedot');
  pid := (res->>'payment_id')::bigint;
  perform booking.sumup_pos_started(pid, 'ctx_t295_5');
  perform booking.sumup_pos_apply(pid, 'cancelled', null, null, null, '{"by":"pos_cancel"}'::jsonb);
  perform public.t295_ck((select status from booking.payments where id = pid) = 'cancelled', 'C2 peruttu');
  perform public.t295_login(u_staff);
  perform booking.admin_pos_void(oid);
  perform public.t295_logout();
  perform public.t295_ck((select status from booking.orders where id = oid) = 'cancelled', 'C3 kassan peruutus toimii');

  -- Z: pois päältä → piiloon, muut tilat ennallaan
  perform public.t295_login(u_admin);
  perform booking.admin_set_sumup_mode('off', null);
  res := booking.admin_pos_tenders();
  perform public.t295_logout();
  perform public.t295_ck(not exists (select 1 from jsonb_array_elements(res->'tenders') x where x->>'handler' = 'sumup'), 'Z1 off: piilossa taas');
  perform public.t295_ck((select mode from booking.integration_config where key = 'montonio') is not distinct from v_montonio, 'Z2 montonio-tila ennallaan');
  perform public.t295_ck((select mode from booking.integration_config where key = 'checkoutx') is not distinct from v_cx, 'Z3 checkoutx-tila ennallaan');
  perform public.t295_ck(public.t295_try(format('select booking.sumup_pos_prepare(%s, ''rdr_t295'', null)', oid)) = 'sumup_off', 'Z4 off: prepare kielletty taas');

  log := current_setting('t295.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
