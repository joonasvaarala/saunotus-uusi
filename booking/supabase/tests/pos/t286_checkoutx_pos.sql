-- t286: Pikakassan kortti puhelimella (CheckoutX, booking_286). Rollback-transaktio: lopuksi tahallinen poikkeus TESTRESULT.
-- Kattaa: oletuksena off (maksutapa piilossa, Edge-RPC:t kieltäytyvät), oikeudet (service_role vs authenticated/anon),
-- tilan kytkentä vain off/test + approved_by, live estetty, terminaalin tallennus, valmistelu, maksettu → kuitti/maksutila,
-- epäonnistunut/peruttu → uusi yritys samalle tilaukselle, hyvityksen claim/complete/fail.
-- Ei CI:ssä (Pages-työnkulussa ei ole Postgresia). Ajetaan psql:llä migraation jälkeen: psql -v ON_ERROR_STOP=0 -f ...
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t286.log', '', true);
create function public.t286_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t286.log', coalesce(current_setting('t286.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t286_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t286_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t286_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_admin uuid := gen_random_uuid();
  u_staff uuid := gen_random_uuid();
  p_prod bigint;
  items jsonb;
  res jsonb;
  oid bigint;
  pid bigint;
  pid2 bigint;
  rid bigint;
  v_montonio text;
  log text;
  npass int;
  nfail int;
  n_other int;
begin
  select mode into v_montonio from booking.integration_config where key = 'montonio';

  -- G: oikeudet
  perform public.t286_ck(not has_function_privilege('authenticated', 'booking.checkoutx_pos_prepare(bigint,text,uuid)', 'execute'), 'G1 authenticated ei prepare');
  perform public.t286_ck(not has_function_privilege('anon', 'booking.checkoutx_pos_apply(bigint,text,text,jsonb)', 'execute'), 'G2 anon ei apply');
  perform public.t286_ck(not has_function_privilege('authenticated', 'booking.checkoutx_pos_apply(bigint,text,text,jsonb)', 'execute'), 'G3 authenticated ei apply');
  perform public.t286_ck(not has_function_privilege('authenticated', 'booking.checkoutx_terminal_save(text,text,uuid)', 'execute'), 'G4 authenticated ei terminal_save');
  perform public.t286_ck(not has_function_privilege('authenticated', 'booking.checkoutx_refund_complete(bigint,jsonb)', 'execute'), 'G5 authenticated ei refund_complete');
  perform public.t286_ck(has_function_privilege('service_role', 'booking.checkoutx_pos_prepare(bigint,text,uuid)', 'execute'), 'G6 service_role prepare');
  perform public.t286_ck(has_function_privilege('authenticated', 'booking.admin_get_checkoutx_status()', 'execute'), 'G7 authenticated status');
  perform public.t286_ck(not has_function_privilege('anon', 'booking.admin_set_checkoutx_mode(text,text)', 'execute'), 'G8 anon ei set_mode');
  perform public.t286_ck(not has_table_privilege('authenticated', 'booking.checkoutx_terminals', 'select'), 'G9 terminaalitaulu ei suoraan luettavissa');
  perform public.t286_ck((select bool_and(prosecdef and proconfig::text like '%search_path=%') from pg_proc where pronamespace = 'booking'::regnamespace and proname like '%checkoutx%' and proname not like '%_trg'), 'G10 definer + search_path');

  insert into kb.products(name, category, price, vat_rate, active) values ('t286 Vichy', 'other', 3.50, 13.5, true) returning id into p_prod;
  insert into booking.product_config(product_id, sale_kind, bookable, pos_enabled, pos_sort, fridge_sale)
  values (p_prod, 'other', false, true, 10, false);
  items := jsonb_build_array(jsonb_build_object('product_id', p_prod, 'quantity', 2));
  insert into auth.users(id, email) values (u_admin, 't286-admin@example.test'), (u_staff, 't286-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_admin, 't286-admin@example.test', 't286 admin', 'admin'),
    (u_staff, 't286-staff@example.test', 't286 staff', 'staff');

  -- O: oletuksena off → maksutapa piilossa, Edge-RPC:t kieltäytyvät
  perform public.t286_ck(booking._checkoutx_mode() = 'off', 'O1 oletus off');
  select count(*) into n_other from booking.pos_tenders where handler <> 'checkoutx';
  perform public.t286_login(u_staff);
  res := booking.admin_pos_tenders();
  perform public.t286_ck(not exists (select 1 from jsonb_array_elements(res->'tenders') x where x->>'handler' = 'checkoutx'), 'O2 off: checkoutx ei tenders-listassa');
  perform public.t286_ck(res->>'checkoutx_mode' = 'off', 'O3 off: checkoutx_mode=off');
  perform public.t286_ck(jsonb_array_length(res->'tenders') = n_other, 'O4 muut maksutavat ennallaan');
  res := booking.admin_pos_checkout(items, 'fi', null);
  oid := (res->>'order_id')::bigint;
  perform public.t286_ck(public.t286_try('select booking.admin_set_checkoutx_mode(''test'', ''t286'')') = 'forbidden', 'O5 staff ei saa kytkeä');
  perform public.t286_logout();
  perform public.t286_ck(public.t286_try(format('select booking.checkoutx_pos_prepare(%s, ''T286TERM01'', null)', oid)) = 'checkoutx_off', 'O6 off: prepare kielletty');
  perform public.t286_ck(public.t286_try('select booking.checkoutx_terminal_save(''T286TERM01'', ''Testi'', null)') = 'checkoutx_off', 'O7 off: terminal_save kielletty');
  perform public.t286_ck((booking.checkoutx_refund_claim(1)->'claimed') = '[]'::jsonb, 'O8 off: refund_claim tyhjä');

  -- M: kytkentä
  perform public.t286_login(u_admin);
  perform public.t286_ck(public.t286_try('select booking.admin_set_checkoutx_mode(''live'', ''t286'')') = 'invalid_param', 'M1 live hylätään');
  perform public.t286_ck(public.t286_try('select booking.admin_set_checkoutx_mode(''test'', null)') = 'approval_required', 'M2 test vaatii approved_by');
  res := booking.admin_set_checkoutx_mode('test', 't286 Joonas');
  perform public.t286_ck(res->>'mode' = 'test' and res->>'approved_by' = 't286 Joonas', 'M3 test päälle');
  perform public.t286_logout();
  perform public.t286_ck(public.t286_try('update booking.integration_config set mode = ''live'' where key = ''checkoutx''') like '23514:%', 'M4 live estetty myös suoraan');
  perform public.t286_ck(public.t286_try('update booking.integration_config set mode = ''test'', settings = settings - ''approved_by'' where key = ''checkoutx''') = 'approval_required', 'M5 test ilman approved_by estetty triggerillä');

  -- T: terminaali
  perform public.t286_ck(public.t286_try('select booking.checkoutx_terminal_save(''bad id!'', ''x'', null)') = 'invalid_param', 'T1 virheellinen tunnus');
  res := booking.checkoutx_terminal_save('T286TERM01', '  Kassapuhelin  ', u_admin);
  perform public.t286_ck(res->>'label' = 'Kassapuhelin', 'T2 tallennus');
  perform public.t286_login(u_staff);
  res := booking.admin_get_checkoutx_status();
  perform public.t286_ck(jsonb_array_length(res->'terminals') = 1 and res->'terminals'->0->>'terminal_id' = 'T286TERM01', 'T3 status listaa puhelimen');
  res := booking.admin_pos_tenders();
  perform public.t286_ck(exists (select 1 from jsonb_array_elements(res->'tenders') x where x->>'handler' = 'checkoutx' and (x->>'active')::boolean), 'T4 test: checkoutx tenders-listassa');
  perform public.t286_logout();

  -- P: valmistelu ja maksettu
  perform public.t286_ck(public.t286_try(format('select booking.checkoutx_pos_prepare(%s, ''UNKNOWN01'', null)', oid)) = 'terminal_not_registered', 'P1 tuntematon puhelin');
  res := booking.checkoutx_pos_prepare(oid, 'T286TERM01', u_staff);
  pid := (res->>'payment_id')::bigint;
  perform public.t286_ck(res->>'amount' = '7.00' and res->>'currency' = 'EUR', 'P2 summa = tilauksen maksamaton osuus (2 x 3,50)');
  perform public.t286_ck((select status = 'pending' and method = 'checkoutx' and provider = 'checkoutx' and link_expires_at > now() from booking.payments where id = pid), 'P3 avoin maksurivi 15 min');
  perform public.t286_ck(public.t286_try(format('select booking.checkoutx_pos_apply(%s, ''paid'', null, null)', pid)) = 'payment_not_started', 'P4 apply ennen Surfboard-tilausta kielletty');
  perform public.t286_ck(public.t286_try(format('select booking.checkoutx_pos_created(%s, ''bad id!'', null)', pid)) = 'invalid_param', 'P5 virheellinen tilaustunnus');
  perform booking.checkoutx_pos_created(pid, 'sbord0001', 'sbpay0001');
  res := booking.checkoutx_pos_lookup(pid);
  perform public.t286_ck(res->>'sb_order_id' = 'sbord0001' and res->>'sb_payment_id' = 'sbpay0001' and res->>'terminal_id' = 'T286TERM01', 'P6 lookup');
  perform public.t286_ck(public.t286_try(format('select booking.checkoutx_pos_created(%s, ''sbord0002'', null)', pid)) = 'ref_conflict', 'P7 toinen tunnus hylätään');
  -- F: epäonnistunut → uusi yritys
  res := booking.checkoutx_pos_apply(pid, 'failed', null, '{"orderStatus":"PENDING"}'::jsonb);
  perform public.t286_ck(res->>'status' = 'failed' and (select status from booking.payments where id = pid) = 'failed', 'F1 epäonnistunut kirjataan');
  perform public.t286_ck((select status from booking.orders where id = oid) = 'pending', 'F2 tilaus jää avoimeksi');
  res := booking.checkoutx_pos_prepare(oid, 'T286TERM01', u_staff);
  pid2 := (res->>'payment_id')::bigint;
  perform public.t286_ck(pid2 <> pid and res->>'amount' = '7.00', 'F3 uusi yritys samalle tilaukselle');
  perform booking.checkoutx_pos_created(pid2, 'sbord0003', null);
  res := booking.checkoutx_pos_apply(pid2, 'paid', 'sbpay0003', '{"orderStatus":"PAYMENT_COMPLETED"}'::jsonb);
  perform public.t286_ck(res->>'ok' = 'true' and res->>'status' = 'paid', 'P8 maksettu');
  perform public.t286_ck((select status = 'paid' and provider_status = 'PAYMENT_COMPLETED' and raw->>'sb_payment_id' = 'sbpay0003' from booking.payments where id = pid2), 'P9 maksurivi paid + Surfboardin maksutunnus');
  perform public.t286_ck((select payment_status from booking.orders where id = oid) = 'paid', 'P10 tilaus maksettu');
  perform public.t286_ck(exists (select 1 from booking.receipts where order_id = oid), 'P11 kuitti syntyi');
  res := booking.checkoutx_pos_apply(pid2, 'paid', 'sbpay0003', null);
  perform public.t286_ck(res->>'already' = 'true', 'P12 toisto idempotentti');
  perform public.t286_ck((booking.checkoutx_pos_apply(pid2, 'cancelled', null, null))->>'unchanged' = 'true', 'P13 maksettua ei peruta');
  perform public.t286_ck(public.t286_try(format('select booking.checkoutx_pos_prepare(%s, ''T286TERM01'', null)', oid)) = 'order_not_payable', 'P14 maksettua tilausta ei voi maksaa uudelleen');
  perform public.t286_ck(public.t286_try(format('select booking.checkoutx_pos_apply(%s, ''bogus'', null, null)', pid2)) = 'invalid_param', 'P15 tuntematon lopputulos');

  -- R: hyvitys (admin_refund → requested → claim → complete)
  perform public.t286_login(u_admin);
  res := booking.admin_refund(pid2, 7.00, 't286 testihyvitys', null, false);
  perform public.t286_logout();
  rid := (res->>'refund_id')::bigint;
  perform public.t286_ck(res->>'status' = 'requested' and (select provider from booking.refunds where id = rid) = 'checkoutx', 'R1 admin_refund luo checkoutx-pyynnön');
  res := booking.checkoutx_refund_claim(rid);
  perform public.t286_ck(jsonb_array_length(res->'claimed') = 1 and res->'claimed'->0->>'sb_payment_id' = 'sbpay0003' and res->'claimed'->0->>'payment_amount' = '7.00', 'R2 claim');
  perform public.t286_ck(jsonb_array_length(booking.checkoutx_refund_claim(rid)->'claimed') = 0, 'R3 toinen claim ei ota samaa');
  res := booking.checkoutx_refund_complete(rid, '{"paymentStatus":"PAYMENT_VOIDED"}'::jsonb);
  perform public.t286_ck((select status from booking.refunds where id = rid) = 'done' and (select status from booking.payments where id = pid2) = 'refunded', 'R4 void kirjattu');
  perform public.t286_ck((booking.checkoutx_refund_complete(rid, null))->>'already' = 'true', 'R5 toisto idempotentti');
  perform public.t286_ck((booking.checkoutx_refund_fail(rid, '{}'::jsonb))->>'unchanged' = 'true', 'R6 valmista ei merkitä epäonnistuneeksi');

  -- C: peruutus ja luonnin epäonnistuminen
  perform public.t286_login(u_staff);
  res := booking.admin_pos_checkout(items, 'fi', null);
  perform public.t286_logout();
  oid := (res->>'order_id')::bigint;
  pid := ((booking.checkoutx_pos_prepare(oid, 'T286TERM01', null))->>'payment_id')::bigint;
  res := booking.checkoutx_pos_create_failed(pid, '{"reason":"t286"}'::jsonb);
  perform public.t286_ck(res->>'status' = 'failed' and (select provider_status from booking.payments where id = pid) = 'create_failed', 'C1 luonti epäonnistui → rivi pois');
  pid := ((booking.checkoutx_pos_prepare(oid, 'T286TERM01', null))->>'payment_id')::bigint;
  perform booking.checkoutx_pos_created(pid, 'sbord0004', null);
  perform booking.checkoutx_pos_apply(pid, 'cancelled', null, null);
  perform public.t286_ck((select status from booking.payments where id = pid) = 'cancelled', 'C2 peruttu');
  perform public.t286_login(u_staff);
  perform booking.admin_pos_void(oid);
  perform public.t286_logout();
  perform public.t286_ck((select status from booking.orders where id = oid) = 'cancelled', 'C3 kassan peruutus toimii');

  -- Z: pois päältä → piiloon, muut tilat ennallaan
  perform public.t286_login(u_admin);
  perform booking.admin_set_checkoutx_mode('off', null);
  res := booking.admin_pos_tenders();
  perform public.t286_logout();
  perform public.t286_ck(not exists (select 1 from jsonb_array_elements(res->'tenders') x where x->>'handler' = 'checkoutx'), 'Z1 off: piilossa taas');
  perform public.t286_ck((select mode from booking.integration_config where key = 'montonio') is not distinct from v_montonio, 'Z2 montonio-tila ennallaan');

  log := current_setting('t286.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
