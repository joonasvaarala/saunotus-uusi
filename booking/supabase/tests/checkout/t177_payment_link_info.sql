-- t177: booking_177 public_payment_link_info(uuid) – maksulinkkisivun (/maksa/?p=, /en/pay/?p=) yhteenveto ennen maksun aloitusta.
--   A) rakenne: funktio = booking_177 (md5), SECURITY DEFINER, search_path '', anon/authenticated/service_role saavat kutsua, PUBLIC ei;
--      riippuvuudet ennallaan (vismapay_payment_prepare, _create_link_payment, _order_rl, _rate_limit, _client_ip, _order_balance, _vismapay_mode, _setting).
--   B) open: summa (eur + sentit), valuutta, tilausnumero, rivit (nimi FI/EN, pvm, klo Europe/Helsinki), voimassaolo; can_pay; Visma pois → not_payable/vismapay_off.
--   C) ei henkilötietoja: vastauksessa ei avaimia (email, phone, address, customer, note, token, provider_ref, raw …) eikä asiakkaan nimeä/sähköpostia/puhelinta/osoitetta,
--      tilauksen tokenia, maksuvälittäjän tunnistetta tai sisäistä muistiinpanoa.
--   D) summa muuttui → replaced (link_stale); käsin kirjattu osamaksu perui linkin → replaced; uusi linkki open (20 €); vanhentunut → expired (link_expired),
--      myös ajastetun expire_payment_links-perumisen jälkeen; vanhentunut + uudempi linkki → replaced; Visma-maksu peruttu → expired (payment_cancelled);
--      maksettu → paid (link_paid); korvattu linkki + tilaus maksettu → paid (order_paid); linkki auki mutta tilaus maksettu muuta kautta → paid (order_paid);
--      yritystilaus → not_payable (order_not_payable).
--   E) not_found: tuntematon ja puuttuva token → sama vastaus ilman muita tietoja.
--   F) vain luku: maksut ja tilaukset eivät muutu kutsuista; nopeusrajoitus (_order_rl, tokenikohtainen) → rate_limited.
--   G) SQLSTATE: virheellinen uuid → 22P02; anon ei lue booking.payments suoraan → 42501.
-- TUOTANTOKELPOINEN: yksi transaktio (BEGIN … lopussa tahallinen poikkeus "TESTRESULT pass=… fail=… skip=…" + ROLLBACK), ei kiinteitä id-arvoja (RETURNING),
-- testikäyttäjät luodaan transaktion sisällä (auth.users + booking.staff, gen_random_uuid), ei psql-metakomentoja → toimii myös pelkällä SQL-työkalulla.
-- Asetukset (rl_order_get_per_10min, integration_config vismapay) muutetaan vain transaktion sisällä. Apufunktiot pg_temp-skeemassa. Ei sähköposteja, ei Visma-kutsuja.
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t177_payment_link_info.sql   (tai liitä koko tiedosto SQL-editoriin; tulos virheviestissä TESTRESULT …)
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t177.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t177.log', coalesce(current_setting('t177.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; s text;
begin execute 'select (' || p_sql || ')::jsonb' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate; return jsonb_build_object('state', s, 'err', case when s = 'BK001' then d else s end);
end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.rnd(p_prefix text, p_len int) returns text language sql volatile as $$
  select p_prefix || upper(substr(translate(md5(random()::text || clock_timestamp()::text), 'abcdef', 'ghjkmn'), 1, p_len)) $$;
-- kaikki avaimet sisäkkäisistä objekteista/taulukoista
create function pg_temp.keys(p jsonb) returns setof text language sql immutable as $$
  with recursive w(v) as (select p union all
    select e.value from w, lateral (select value from jsonb_each(case when jsonb_typeof(w.v) = 'object' then w.v else '{}'::jsonb end)
                                    union all select value from jsonb_array_elements(case when jsonb_typeof(w.v) = 'array' then w.v else '[]'::jsonb end)) e)
  select distinct k from w, lateral jsonb_object_keys(case when jsonb_typeof(w.v) = 'object' then w.v else '{}'::jsonb end) k $$;
-- vahvistettu tilaus (yksityisasiakas), yksi varausrivi (tuote) annettuna Helsingin aikana + lisäpalvelu; palauttaa tilauksen id:n
create function pg_temp.mkorder(p_cu bigint, p_pid bigint, p_space bigint, p_total numeric, p_start timestamptz, p_kind text default 'private') returns bigint language plpgsql as $$
declare v bigint; it bigint;
begin
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind)
  values (p_cu, 'confirmed', 'unpaid', p_total, 'admin', 'fi', p_kind) returning id into v;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v, p_pid, 'T177 Saunavuoro', 'reservation', 1, p_total - 4, p_total - 4, 25.5) returning id into it;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, parent_item_id)
  values (v, 'T177 Pyyhe', 'product', 1, 4, 4, 25.5, it);
  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  values (v, it, p_pid, p_space, 'exclusive', p_start, p_start + interval '2 hours', 2, 'confirmed');
  return v;
end $$;
create function pg_temp.info(p_token uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.anon(); r := booking.public_payment_link_info(p_token); perform pg_temp.logout(); return r; end $$;
create function pg_temp.mklink(p_admin uuid, p_order bigint) returns uuid language plpgsql as $$
declare r jsonb;
begin perform pg_temp.login(p_admin); r := booking.admin_create_payment_link(p_order, false, 14, 'T177 linkki'); perform pg_temp.logout();
  return (select link_token from booking.payments where id = coalesce((r ->> 'payment_id')::bigint, (r -> 'link' ->> 'payment_id')::bigint, (r ->> 'id')::bigint)); end $$;

do $t$
declare
  run text := lower(pg_temp.rnd('', 8));
  u_adm uuid := gen_random_uuid();
  cu bigint; pid bigint; sp bigint; o bigint; o2 bigint; o3 bigint; o4 bigint; ono bigint; tk1 uuid; tk2 uuid; tk3 uuid; tk4 uuid; tk5 uuid; otok uuid;
  r jsonb; r2 jsonb; x jsonb; txt text; snap1 text; snap2 text; log text; np int; nf int; ns int; n int;
  v_start timestamptz := (date_trunc('day', now() at time zone 'Europe/Helsinki') + interval '40 days 17 hours') at time zone 'Europe/Helsinki';
  s_vp booking.integration_config; s_rl jsonb; v_has_rl boolean;
  pii text[] := array['email','phone','address','address_street','zip','city','country','customer','customer_name','customer_id','first_name','firstname','last_name','lastname',
                      'note','notes','internal_note','public_token','order_token','token','link_token','provider_ref','provider_status','raw','ip','created_by','user_id','staff'];
begin
  select * into s_vp from booking.integration_config where key = 'vismapay';
  select value, true into s_rl, v_has_rl from booking.settings where key = 'rl_order_get_per_10min';

  -- ===== A rakenne
  if to_regprocedure('booking.public_payment_link_info(uuid)') is null then
    raise exception 'TESTRESULT pass=0 fail=1 skip=0 F A1 booking_177 puuttuu (public_payment_link_info)';
  end if;
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_payment_link_info(uuid)'::regprocedure)) = '1fb6153b39daa6f1055c93cac7cb4563', 'A1 public_payment_link_info = booking_177');
  perform pg_temp.ck((select prosecdef and proconfig = array['search_path=""'] and provolatile = 'v' from pg_proc where oid = 'booking.public_payment_link_info(uuid)'::regprocedure),
      'A2 SECURITY DEFINER, search_path tyhjä');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_payment_link_info(uuid)', 'execute')
      and has_function_privilege('authenticated', 'booking.public_payment_link_info(uuid)', 'execute')
      and has_function_privilege('service_role', 'booking.public_payment_link_info(uuid)', 'execute')
      and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'booking.public_payment_link_info(uuid)'::regprocedure and a.grantee = 0),
      'A3 oikeudet: anon/authenticated/service_role, ei PUBLIC');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.vismapay_payment_prepare(uuid,uuid)'::regprocedure)) = '703c03c301f5a3008192cdbe65e559e2'
      and md5(pg_get_functiondef('booking._create_link_payment(bigint,integer,text)'::regprocedure)) = '533ac9af831c0c11e1f504e377a17827'
      and md5(pg_get_functiondef('booking._order_rl(text,uuid,integer,integer)'::regprocedure)) = 'ec6bf13a3694e5bf9034a80123857246'
      and md5(pg_get_functiondef('booking._rate_limit(text,integer,interval)'::regprocedure)) = '7c8076d29d82d72db797066fd44d06c1'
      and md5(pg_get_functiondef('booking._client_ip()'::regprocedure)) = '8c8e7d145566db576d33037a941ce81f'
      and md5(pg_get_functiondef('booking._order_balance(bigint)'::regprocedure)) = 'a6b31f93559de53d75a52d8a285f1170'
      and md5(pg_get_functiondef('booking._vismapay_mode()'::regprocedure)) = '6d7d56a83470d01e954a78e8767e8366'
      and md5(pg_get_functiondef('booking._setting(text,jsonb)'::regprocedure)) = '70fcfa245e9e7d070dae7a6c1e90ce4d', 'A4 riippuvuudet ennallaan');

  -- ===== fixture (feikki, vain tässä transaktiossa)
  insert into booking.integration_config(key, mode, settings) values ('vismapay', 'test', '{"approved_by":"t177"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t177"}'::jsonb;
  if v_has_rl then update booking.settings set value = '200'::jsonb where key = 'rl_order_get_per_10min';
  else insert into booking.settings(key, value) values ('rl_order_get_per_10min', '200'::jsonb); end if;
  insert into auth.users(id, email) values (u_adm, 't177-admin-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't177-admin-' || run || '@example.test', 't177 admin', 'admin');
  insert into booking.customers(name, email, phone, address, zip, city, country, notes)
  values ('Tiina Testaaja' || run, 't177-' || run || '@example.test', '+358401770177', 'Salakatu 177 ' || run, '01770', 'Sipoo177', 'FI', 'T177 sisäinen muistiinpano ' || run) returning id into cu;
  insert into booking.resources(code, name, kind) values ('t177-' || run, 'T177 tila', 'space') returning id into sp;
  perform pg_temp.login(u_adm);
  r := booking.admin_product_create(jsonb_build_object('name', 'T177 Saunavuoro ' || run, 'name_en', 'T177 Sauna slot', 'price', 1, 'vat_rate', 25.5, 'active', false));
  pid := (r ->> 'id')::bigint;
  perform pg_temp.logout();
  o := pg_temp.mkorder(cu, pid, sp, 30, v_start);
  select order_no, public_token into ono, otok from booking.orders where id = o;
  tk1 := pg_temp.mklink(u_adm, o);
  perform pg_temp.ck(pid is not null and tk1 is not null, 'X0 fixture: tuote, tilaus, maksulinkki');

  -- ===== B open
  select string_agg(p::text, ',' order by p.id) into snap1 from booking.payments p where p.order_id = o;
  select o2x::text into txt from booking.orders o2x where o2x.id = o; snap1 := snap1 || txt;
  r := pg_temp.info(tk1);
  perform pg_temp.ck(r ->> 'ok' = 'true' and r ->> 'status' = 'open' and r ->> 'reason' = 'open' and (r ->> 'can_pay')::boolean, 'B1 open, can_pay');
  perform pg_temp.ck((r ->> 'amount')::numeric = 30 and (r ->> 'amount_cents')::bigint = 3000 and r ->> 'currency' = 'EUR' and (r ->> 'order_no')::bigint = ono
      and (r ->> 'order_total')::numeric = 30, 'B2 summa 30,00 € = 3000 senttiä, EUR, tilausnumero');
  perform pg_temp.ck(jsonb_array_length(r -> 'items') = 2
      and r -> 'items' -> 0 ->> 'name' = 'T177 Saunavuoro' and r -> 'items' -> 0 ->> 'name_en' = 'T177 Sauna slot' and r -> 'items' -> 0 ->> 'kind' = 'reservation'
      and r -> 'items' -> 0 ->> 'date' = to_char(v_start at time zone 'Europe/Helsinki', 'YYYY-MM-DD')
      and r -> 'items' -> 0 ->> 'start' = '17:00' and r -> 'items' -> 0 ->> 'end' = '19:00'
      and r -> 'items' -> 1 ->> 'name' = 'T177 Pyyhe' and r -> 'items' -> 1 ->> 'date' is null, 'B3 rivit: nimi FI/EN, pvm ja klo 17:00–19:00 (Europe/Helsinki), lisärivi ilman aikaa');
  perform pg_temp.ck(r ->> 'expires_date' = (select to_char(link_expires_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD') from booking.payments where link_token = tk1)
      and r ->> 'expires_time' ~ '^\d\d:\d\d$' and (r ->> 'expires_at')::timestamptz > now() + interval '13 days', 'B4 voimassaolo (expires_at + Helsingin pvm/klo)');
  update booking.integration_config set mode = 'off' where key = 'vismapay';
  r2 := pg_temp.info(tk1);
  perform pg_temp.ck(r2 ->> 'status' = 'not_payable' and r2 ->> 'reason' = 'vismapay_off' and not (r2 ->> 'can_pay')::boolean and (r2 ->> 'amount')::numeric = 30, 'B5 Visma pois → not_payable/vismapay_off');
  update booking.integration_config set mode = 'test' where key = 'vismapay';

  -- ===== C ei henkilötietoja
  select count(*) into n from pg_temp.keys(r) k where k = any (pii);
  perform pg_temp.ck(n = 0, 'C1 ei henkilötieto- tai tunnisteavaimia');
  perform pg_temp.ck((select array_agg(k order by k) from pg_temp.keys(r) k) = array['amount','amount_cents','can_pay','currency','date','end','end_date','expires_at','expires_date','expires_time',
      'items','kind','name','name_en','ok','order_no','order_total','paid_at','quantity','reason','start','status'], 'C2 avaimet täsmälleen sallitut');
  txt := r::text;
  perform pg_temp.ck(position(run in txt) = 0 and position('Tiina' in txt) = 0 and position('example.test' in txt) = 0 and position('0401770177' in txt) = 0
      and position('Salakatu' in txt) = 0 and position('Sipoo177' in txt) = 0 and position(otok::text in txt) = 0 and position(tk1::text in txt) = 0
      and position('T177 linkki' in txt) = 0 and position('sauna-o' in txt) = 0, 'C3 ei nimeä, sähköpostia, puhelinta, osoitetta, tokeneita, muistiinpanoa');

  -- ===== F vain luku
  select string_agg(p::text, ',' order by p.id) into snap2 from booking.payments p where p.order_id = o;
  select o2x::text into txt from booking.orders o2x where o2x.id = o; snap2 := snap2 || txt;
  perform pg_temp.ck(snap1 = snap2, 'F1 kutsut eivät muuta maksuja eivätkä tilausta');

  -- ===== D tilat
  update booking.orders set total_gross = 25 where id = o;   -- tilauksen summa pieneni linkin luonnin jälkeen (esim. rivi poistettu)
  r := pg_temp.info(tk1);
  perform pg_temp.ck(r ->> 'status' = 'replaced' and r ->> 'reason' = 'link_stale' and not (r ->> 'can_pay')::boolean, 'D1 linkin summa > maksamatta → replaced/link_stale');
  update booking.orders set total_gross = 30 where id = o;
  perform pg_temp.login(u_adm);
  perform booking.admin_record_payment(o, 'bank_transfer', 10, 'T177 osamaksu');
  perform pg_temp.logout();
  r := pg_temp.info(tk1);
  perform pg_temp.ck(r ->> 'status' = 'replaced' and r ->> 'reason' = 'replaced' and not (r ->> 'can_pay')::boolean, 'D2 käsin kirjattu osamaksu perui linkin → replaced');
  tk2 := pg_temp.mklink(u_adm, o);
  r2 := pg_temp.info(tk2);
  perform pg_temp.ck(tk2 <> tk1 and r2 ->> 'status' = 'open' and (r2 ->> 'amount')::numeric = 20 and (r2 ->> 'amount_cents')::bigint = 2000, 'D3 uusi linkki open, 20,00 €');
  update booking.payments set link_expires_at = now() - interval '1 minute' where link_token = tk2;
  r2 := pg_temp.info(tk2);
  perform pg_temp.ck(r2 ->> 'status' = 'expired' and r2 ->> 'reason' = 'link_expired' and not (r2 ->> 'can_pay')::boolean and r2 ->> 'expires_date' is not null, 'D4 vanhentunut → expired/link_expired');
  perform booking.expire_payment_links();
  r2 := pg_temp.info(tk2);
  perform pg_temp.ck((select status from booking.payments where link_token = tk2) = 'cancelled' and r2 ->> 'status' = 'expired' and r2 ->> 'reason' = 'link_expired', 'D5 ajastettu vanhennus (expire_payment_links) → expired/link_expired');
  tk3 := pg_temp.mklink(u_adm, o);
  r2 := pg_temp.info(tk2);
  perform pg_temp.ck(tk3 not in (tk1, tk2) and r2 ->> 'status' = 'replaced' and r2 ->> 'reason' = 'replaced', 'D6 vanhentunut + uudempi linkki → replaced');
  update booking.payments set provider_ref = 'sauna-t177-' || run, provider_status = 'initiating' where link_token = tk3;
  perform booking.payment_mark_failed('visma_pay', 'sauna-t177-' || run, 'cancelled', null);
  r := pg_temp.info(tk3);
  perform pg_temp.ck(r ->> 'status' = 'expired' and r ->> 'reason' = 'payment_cancelled' and position('sauna-t177' in r::text) = 0, 'D7 maksu peruttu Visma Payssa → expired/payment_cancelled (ei tunnistetta)');
  tk3 := pg_temp.mklink(u_adm, o);
  update booking.payments set status = 'paid', paid_at = now() where link_token = tk3;
  r := pg_temp.info(tk3);
  perform pg_temp.ck(r ->> 'status' = 'paid' and r ->> 'reason' = 'link_paid' and r ->> 'paid_at' is not null and not (r ->> 'can_pay')::boolean, 'D8 maksettu → paid/link_paid');
  r := pg_temp.info(tk1);
  perform pg_temp.ck(r ->> 'status' = 'paid' and r ->> 'reason' = 'order_paid' and r ->> 'paid_at' is null, 'D9 korvattu linkki, tilaus maksettu → paid/order_paid');
  o2 := pg_temp.mkorder(cu, pid, sp, 50, v_start + interval '1 day');
  tk4 := pg_temp.mklink(u_adm, o2);
  insert into booking.payments(order_id, method, provider, status, amount, currency, paid_at, note) values (o2, 'bank_transfer', 'manual', 'paid', 50, 'EUR', now(), 'T177 tilisiirto (ei peru linkkiä)');
  r := pg_temp.info(tk4);
  perform pg_temp.ck((select status from booking.payments where link_token = tk4) = 'pending' and r ->> 'status' = 'paid' and r ->> 'reason' = 'order_paid', 'D10 linkki yhä auki, tilaus maksettu muuta kautta → paid/order_paid');
  o3 := pg_temp.mkorder(cu, pid, sp, 40, v_start + interval '2 days');
  tk5 := pg_temp.mklink(u_adm, o3);
  update booking.orders set customer_kind = 'company' where id = o3;
  r := pg_temp.info(tk5);
  perform pg_temp.ck(r ->> 'status' = 'not_payable' and r ->> 'reason' = 'order_not_payable', 'D11 yritystilaus → not_payable/order_not_payable');

  -- ===== E not_found
  r := pg_temp.info(gen_random_uuid()); r2 := pg_temp.info(null);
  perform pg_temp.ck(r = '{"ok":true,"status":"not_found","reason":"not_found","can_pay":false}'::jsonb and r2 = r, 'E1 tuntematon ja puuttuva token → sama not_found ilman muita tietoja');

  -- ===== F nopeusrajoitus
  update booking.settings set value = '3'::jsonb where key = 'rl_order_get_per_10min';
  o4 := pg_temp.mkorder(cu, pid, sp, 30, v_start + interval '3 days');
  tk5 := pg_temp.mklink(u_adm, o4);
  for i in 1..3 loop r := pg_temp.info(tk5); end loop;
  r2 := pg_temp.info(tk5);
  perform pg_temp.ck(r ->> 'status' = 'open' and r2 = '{"ok":false,"code":"rate_limited"}'::jsonb, 'F2 tokenikohtainen raja (_order_rl) → rate_limited');

  -- ===== G SQLSTATE
  perform pg_temp.anon();
  x := pg_temp.call('booking.public_payment_link_info(''ei-uuid'')');
  perform pg_temp.ck(x ->> 'state' = '22P02', 'G1 virheellinen uuid → 22P02');
  x := pg_temp.call('(select to_jsonb(count(*)) from booking.payments)');
  perform pg_temp.ck(x ->> 'state' = '42501', 'G2 anon ei lue booking.payments suoraan (42501)');
  perform pg_temp.logout();

  -- palautus (transaktio kumotaan joka tapauksessa)
  if s_vp.key is null then delete from booking.integration_config where key = 'vismapay'; else update booking.integration_config set mode = s_vp.mode, settings = s_vp.settings where key = 'vismapay'; end if;
  if v_has_rl then update booking.settings set value = s_rl where key = 'rl_order_get_per_10min'; else delete from booking.settings where key = 'rl_order_get_per_10min'; end if;

  log := current_setting('t177.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
select 't177 leftover rows = ' || ((select count(*) from booking.customers where email like 't177-%@example.test') + (select count(*) from auth.users where email like 't177-%@example.test')) as t177_check;
