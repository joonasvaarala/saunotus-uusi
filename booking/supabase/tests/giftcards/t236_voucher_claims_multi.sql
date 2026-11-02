-- t236: booking_236 usea kumppanilahjakortti, yksi erotuksen maksulinkki.
--   A) svc_mark_voucher_claims_redeemed, kaksi ylikuormaa. service_role, ei anon/authenticated.
--      _vc_redeem_many on sisäinen. Yhden kortin svc_mark_voucher_claim_redeemed säilyy.
--   B) 25+25 € / 58 € → yksi linkki 8 €, yksi viesti, value_card true, molemmat lunastettu.
--   C) kortit kattavat summan → ei linkkiä eikä viestiä.
--   D) eri tilaukset, tyhjä, kaksoiskappale, tuntematon, jo lunastettu, lasku, arvo yli.
--   E) p_value_card false ei käytä arvolahjakortin lippua. Muu maksu vähennetään erotuksesta.
-- TUOTANTOKELPOINEN: yksi transaktio, ROLLBACK, ei kiinteitä id-arvoja, ei psql-metakomentoja.
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t236_voucher_claims_multi.sql
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t236.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t236.log', coalesce(current_setting('t236.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; s text;
begin execute 'select (' || p_sql || ')::jsonb' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate; return jsonb_build_object('state', s, 'err', case when s = 'BK001' then d else s end);
end $$;
create function pg_temp.svc() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"service_role"}', true); execute 'set local role service_role'; end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.rnd(p_prefix text, p_len int) returns text language sql volatile as $$
  select p_prefix || upper(substr(translate(md5(random()::text || clock_timestamp()::text), 'abcdef', 'ghjkmn'), 1, p_len)) $$;
create function pg_temp.mkorder(p_cu bigint, p_total numeric, p_locale text, p_name text) returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale) values (p_cu, 'confirmed', 'unpaid', p_total, 'admin', p_locale) returning id into v;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate) values (v, p_name, 'product', 1, p_total, p_total, 25.5);
  return v;
end $$;
create function pg_temp.mkclaim(p_order bigint, p_source text) returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into booking.voucher_claims(order_id, code, source, customer_name, locale)
  values (p_order, pg_temp.rnd('TM', 10), p_source, 'T236 Testi', 'fi') returning id into v;
  return v;
end $$;
create function pg_temp.mails(p_order bigint) returns int language sql stable as $$
  select count(*)::int from booking.email_outbox where order_id = p_order and kind = 'payment_link' $$;
create function pg_temp.links(p_order bigint) returns int language sql stable as $$
  select count(*)::int from booking.payments where order_id = p_order and status = 'pending' and provider in ('montonio', 'visma_pay') $$;

do $t$
declare
  run text := lower(pg_temp.rnd('', 8));
  u_adm uuid := gen_random_uuid();
  cu bigint;
  o bigint; o2 bigint;
  c1 bigint; c2 bigint; c3 bigint; c4 bigint;
  r jsonb; x jsonb; pay jsonb;
  args_arr text; args_one text;
  sig_arr text := 'booking.svc_mark_voucher_claims_redeemed(bigint[],numeric[],text,text,boolean)';
  sig_one text := 'booking.svc_mark_voucher_claims_redeemed(bigint[],numeric,text,text,boolean)';
  sig_in text := 'booking._vc_redeem_many(bigint[],numeric[],text,text,text,boolean)';
  ic bigint; seq int;
  log text; np int; nf int;
begin
  insert into auth.users(id, email) values (u_adm, 't236-admin-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't236-admin-' || run || '@example.test', 't236 admin', 'admin');
  insert into booking.customers(name, email) values ('T236 Testi', 't236-' || run || '@example.test') returning id into cu;

  select pg_get_function_arguments(sig_arr::regprocedure) into args_arr;
  select pg_get_function_arguments(sig_one::regprocedure) into args_one;
  perform pg_temp.ck(args_arr is not null and lower(args_arr) like '%p_claim_ids bigint[]%' and lower(args_arr) like '%p_amounts numeric[]%' and lower(args_arr) like '%p_value_card boolean default false%', 'A1 taulukko-ylikuorma: p_claim_ids, p_amounts, p_value_card default false');
  perform pg_temp.ck(args_one is not null and lower(args_one) like '%p_amount numeric, p_partner_ref text default%' and lower(args_one) like '%p_value_card boolean default false%', 'A2 sama summa: p_amount ilman oletusta, p_value_card default false');
  perform pg_temp.ck(has_function_privilege('service_role', sig_arr, 'execute') and has_function_privilege('service_role', sig_one, 'execute')
      and not has_function_privilege('anon', sig_arr, 'execute') and not has_function_privilege('authenticated', sig_arr, 'execute')
      and not has_function_privilege('anon', sig_one, 'execute') and not has_function_privilege('authenticated', sig_one, 'execute')
      and not has_function_privilege('public', sig_arr, 'execute') and not has_function_privilege('public', sig_one, 'execute'), 'A3 svc vain service_role');
  perform pg_temp.ck(to_regprocedure(sig_in) is not null
      and not has_function_privilege('service_role', sig_in, 'execute')
      and not has_function_privilege('anon', sig_in, 'execute')
      and not has_function_privilege('authenticated', sig_in, 'execute'), 'A4 _vc_redeem_many sisäinen');
  perform pg_temp.ck(to_regprocedure('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text,boolean)') is not null, 'A5 yhden kortin funktio tallella');
  perform pg_temp.ck(pg_get_functiondef(sig_arr::regprocedure) ilike '%security definer%' and pg_get_functiondef(sig_arr::regprocedure) ilike '%search_path TO ''''%'
      and pg_get_functiondef(sig_one::regprocedure) ilike '%security definer%'
      and pg_get_functiondef(sig_in::regprocedure) like '%order by id%'
      and pg_get_functiondef(sig_in::regprocedure) like '%_vc_mark_redeemed%'
      and pg_get_functiondef(sig_in::regprocedure) like '%_order_invoice_locked%'
      and pg_get_functiondef(sig_in::regprocedure) like '%_create_link_payment%', 'A6 definer, search_path tyhjä, lukitus, apufunktiot');

  -- B: 25+25 / 58, arvolahjakortti, id:t käänteisessä järjestyksessä
  o := pg_temp.mkorder(cu, 58, 'fi', 'T236 kaksi korttia');
  c1 := pg_temp.mkclaim(o, 'kokemuskauppa');
  c2 := pg_temp.mkclaim(o, 'offerilla');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claims_redeemed(array[c2, c1], 25, 'T236-B', null, true);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'ok') = 'true' and (r ->> 'already') = 'false' and (r ->> 'difference')::numeric = 8 and (r ->> 'voucher_value')::numeric = 50
      and (r ->> 'email_queued') = 'true' and (r ->> 'value_card') = 'true' and r -> 'payment_link' <> 'null'::jsonb, 'B1 25+25 / 58: erotus 8, yksi linkki, value_card true');
  perform pg_temp.ck((select count(*) = 2 and bool_and(status = 'redeemed') and bool_and(amount = 25) and bool_and(value_card) from booking.voucher_claims where id in (c1, c2)), 'B2 molemmat lunastettu, arvo 25, value_card true');
  perform pg_temp.ck(pg_temp.mails(o) = 1 and pg_temp.links(o) = 1
      and (select amount = 8 from booking.payments where order_id = o and status = 'pending' and provider in ('montonio', 'visma_pay')), 'B3 tasan yksi maksulinkki, 8 €');
  perform pg_temp.ck(exists (select 1 from booking.email_outbox e where e.order_id = o and e.kind = 'payment_link'
      and e.payload ->> 'variant' = 'voucher_difference' and (e.payload ->> 'value_card') = 'true'
      and (e.payload ->> 'voucher_value')::numeric = 50 and (e.payload ->> 'difference')::numeric = 8 and (e.payload ->> 'total')::numeric = 58
      and jsonb_array_length(e.payload -> 'claim_ids') = 2), 'B4 yksi viesti, arvolahjakortin lippu, summat 50 / 8 / 58');
  perform pg_temp.ck((select count(*) = 1 from booking.vc_difference_payments where order_id = o)
      and exists (select 1 from booking.audit_log where action = 'VOUCHER_DIFFERENCE_LINK' and (new_data ->> 'value_card') = 'true' and (new_data ->> 'difference')::numeric = 8), 'B5 erotuslinkki ja audit kerran');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claims_redeemed(p_claim_ids := array[c1, c2], p_amount := 25, p_value_card := false);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'already') = 'true' and (r ->> 'email_queued') = 'false' and r -> 'payment_link' = 'null'::jsonb
      and pg_temp.mails(o) = 1 and pg_temp.links(o) = 1
      and (select bool_and(value_card) from booking.voucher_claims where id in (c1, c2)), 'B6 uusinta: already, ei toista linkkiä eikä viestiä, lippu säilyy');

  -- C: kortit kattavat koko summan
  o := pg_temp.mkorder(cu, 58, 'en', 'T236 täysi');
  c1 := pg_temp.mkclaim(o, 'elamyslahjat');
  c2 := pg_temp.mkclaim(o, 'kokemuskauppa');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claims_redeemed(array[c1, c2], array[30, 28], null, null, true);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'ok') = 'true' and (r ->> 'difference')::numeric = 0 and (r ->> 'email_queued') = 'false' and r -> 'payment_link' = 'null'::jsonb
      and pg_temp.mails(o) = 0 and pg_temp.links(o) = 0
      and (select count(*) = 2 and bool_and(status = 'redeemed') and bool_and(value_card) and sum(amount) = 58 from booking.voucher_claims where id in (c1, c2)), 'C1 30+28 / 58: ei linkkiä eikä viestiä, molemmat lunastettu');

  -- D: virheet, ei kirjoituksia
  o := pg_temp.mkorder(cu, 58, 'fi', 'T236 eri');
  o2 := pg_temp.mkorder(cu, 58, 'fi', 'T236 eri 2');
  c1 := pg_temp.mkclaim(o, 'kokemuskauppa');
  c2 := pg_temp.mkclaim(o2, 'offerilla');
  perform pg_temp.svc();
  x := pg_temp.call(format('booking.svc_mark_voucher_claims_redeemed(array[%s,%s]::bigint[], 25, null, null, true)', c1, c2));
  perform pg_temp.logout();
  perform pg_temp.ck(x ->> 'err' = 'different_orders' and (select count(*) = 2 and bool_and(status = 'open') from booking.voucher_claims where id in (c1, c2))
      and pg_temp.mails(o) = 0 and pg_temp.mails(o2) = 0 and not exists (select 1 from booking.payments where order_id in (o, o2) and status = 'paid'), 'D1 eri tilaukset: virhe, ei kirjauksia');

  c3 := pg_temp.mkclaim(o, 'elamyslahjat');
  perform pg_temp.svc();
  x := pg_temp.call('booking.svc_mark_voucher_claims_redeemed(''{}''::bigint[], 25, null, null, true)');
  perform pg_temp.ck(x ->> 'err' = 'invalid_ids', 'D2 tyhjä taulukko');
  x := pg_temp.call('booking.svc_mark_voucher_claims_redeemed(null::bigint[], null::numeric[], null, null, true)');
  perform pg_temp.ck(x ->> 'err' = 'invalid_ids', 'D3 null-lista');
  x := pg_temp.call(format('booking.svc_mark_voucher_claims_redeemed(array[%s,%s]::bigint[], array[25,25]::numeric[], null, null, false)', c1, c1));
  perform pg_temp.ck(x ->> 'err' = 'duplicate_claim' and (select status = 'open' from booking.voucher_claims where id = c1), 'D4 kaksoiskappale, ei kirjausta');
  x := pg_temp.call(format('booking.svc_mark_voucher_claims_redeemed(array[%s,%s]::bigint[], array[25,25]::numeric[], null, null, false)', c1, -1));
  perform pg_temp.ck(x ->> 'err' = 'not_found' and (select status = 'open' from booking.voucher_claims where id = c1), 'D5 tuntematon pyyntö, toista ei kirjata');
  x := pg_temp.call(format('booking.svc_mark_voucher_claims_redeemed(array[%s]::bigint[], array[0]::numeric[], null, null, false)', c1));
  perform pg_temp.ck(x ->> 'err' = 'invalid_amount', 'D6 arvo 0');
  x := pg_temp.call(format('booking.svc_mark_voucher_claims_redeemed(array[%s,%s]::bigint[], array[40,25]::numeric[], null, null, false)', c1, c3));
  perform pg_temp.ck(x ->> 'err' = 'voucher_exceeds_total' and (select count(*) = 2 and bool_and(status = 'open') from booking.voucher_claims where id in (c1, c3)), 'D7 summa yli maksettavan, ei kirjauksia');
  perform pg_temp.logout();

  -- jo lunastettu + avoin → virhe, avoin jää auki, yhden kortin linkkiä ei tule lisää
  o := pg_temp.mkorder(cu, 58, 'fi', 'T236 osin');
  c1 := pg_temp.mkclaim(o, 'kokemuskauppa');
  c2 := pg_temp.mkclaim(o, 'offerilla');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(c1, 25, 'T236-ONE', null, false);
  x := pg_temp.call(format('booking.svc_mark_voucher_claims_redeemed(array[%s,%s]::bigint[], array[25,25]::numeric[], null, null, true)', c1, c2));
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'difference')::numeric = 33 and x ->> 'err' = 'invalid_state'
      and (select status = 'redeemed' from booking.voucher_claims where id = c1)
      and (select status = 'open' and value_card = false from booking.voucher_claims where id = c2)
      and pg_temp.mails(o) = 1 and pg_temp.links(o) = 1
      and (select amount = 33 from booking.payments where order_id = o and status = 'pending'), 'D8 jo lunastettu + avoin: virhe, avoin jää, ei toista linkkiä');

  -- laskutettu tilaus
  o := pg_temp.mkorder(cu, 58, 'fi', 'T236 lasku');
  c1 := pg_temp.mkclaim(o, 'kokemuskauppa');
  c2 := pg_temp.mkclaim(o, 'offerilla');
  insert into booking.invoice_customers(company_name, customer_id) values ('T236 Lasku', cu) returning id into ic;
  select coalesce(max(i.seq), 0) + 1 into seq from booking.invoices i where i.series = 'L';
  insert into booking.invoices(customer_id, order_id, status, kind, due_date, seller_snapshot, customer_snapshot, series, seq, invoice_no)
  values (ic, o, 'sent', 'debit', current_date + 14, '{"name":"T236"}'::jsonb, '{"company_name":"T236 Lasku"}'::jsonb, 'L', seq, 'T236-' || seq::text);
  perform pg_temp.ck(booking._order_invoice_locked(o), 'D9a laskulukko päällä');
  perform pg_temp.svc();
  x := pg_temp.call(format('booking.svc_mark_voucher_claims_redeemed(array[%s,%s]::bigint[], 25, null, null, true)', c1, c2));
  perform pg_temp.logout();
  perform pg_temp.ck(x ->> 'err' = 'order_invoiced'
      and (select count(*) = 2 and bool_and(status = 'open') from booking.voucher_claims where id in (c1, c2))
      and pg_temp.mails(o) = 0 and not exists (select 1 from booking.payments where order_id = o and status = 'paid'), 'D9 laskutettu tilaus: order_invoiced, ei kirjauksia');

  perform pg_temp.anon();
  x := pg_temp.call(format('booking.svc_mark_voucher_claims_redeemed(array[%s]::bigint[], 10, null, null, true)', c1));
  perform pg_temp.logout();
  perform pg_temp.ck(x ->> 'err' = '42501', 'D10 anon ei saa kutsua');
  perform pg_temp.login(u_adm);
  x := pg_temp.call(format('booking.svc_mark_voucher_claims_redeemed(array[%s]::bigint[], 10, null, null, true)', c1));
  perform pg_temp.logout();
  perform pg_temp.ck(x ->> 'err' = '42501', 'D11 authenticated ei saa kutsua');

  -- E: eri arvot, value_card false, sekä muu maksu
  o := pg_temp.mkorder(cu, 58, 'en', 'T236 eri arvot');
  c1 := pg_temp.mkclaim(o, 'kokemuskauppa');
  c2 := pg_temp.mkclaim(o, 'elamyslahjat');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claims_redeemed(p_claim_ids := array[c2, c1], p_amounts := array[30, 20], p_value_card := false);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'difference')::numeric = 8 and (r ->> 'value_card') = 'false' and (r ->> 'email_queued') = 'true'
      and (select amount = 20 and value_card = false from booking.voucher_claims where id = c1)
      and (select amount = 30 and value_card = false from booking.voucher_claims where id = c2)
      and exists (select 1 from booking.email_outbox e where e.order_id = o and (e.payload ->> 'value_card') = 'false' and (e.payload ->> 'voucher_value')::numeric = 50 and (e.payload ->> 'difference')::numeric = 8)
      and pg_temp.mails(o) = 1, 'E1 20+30 käänteisessä järjestyksessä: oikeat arvot, yleinen erotus, yksi 8 € linkki');

  o := pg_temp.mkorder(cu, 68, 'fi', 'T236 muu maksu');
  c1 := pg_temp.mkclaim(o, 'offerilla');
  c2 := pg_temp.mkclaim(o, 'kokemuskauppa');
  perform pg_temp.login(u_adm);
  pay := booking.admin_record_payment(o, 'card_terminal', 10, 't236 kortti', null);
  perform pg_temp.logout();
  perform pg_temp.ck((pay ->> 'ok') = 'true', 'E2a muu maksu 10 € kirjattu');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claims_redeemed(array[c1, c2], 25, 'T236-PAY', null, true);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'ok') = 'true' and (r ->> 'difference')::numeric = 8 and (r ->> 'email_queued') = 'true' and (r ->> 'value_card') = 'true'
      and pg_temp.mails(o) = 1 and pg_temp.links(o) = 1
      and (select amount = 8 from booking.payments where order_id = o and status = 'pending' and provider in ('montonio', 'visma_pay'))
      and exists (select 1 from booking.email_outbox e where e.order_id = o and e.kind = 'payment_link' and (e.payload ->> 'value_card') = 'true' and (e.payload ->> 'difference')::numeric = 8 and (e.payload ->> 'voucher_value')::numeric = 50), 'E2 68 € miinus 10 € muu maksu miinus 25+25: yksi 8 € linkki, arvolahjakortin teksti');

  -- yhden kortin polku ennallaan
  o := pg_temp.mkorder(cu, 80, 'fi', 'T236 yksi');
  c4 := pg_temp.mkclaim(o, 'kokemuskauppa');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(c4, 50, 'T236-SINGLE', null, true);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'difference')::numeric = 30 and pg_temp.mails(o) = 1 and (select value_card from booking.voucher_claims where id = c4), 'E3 yhden kortin funktio: erotus 30, yksi viesti');

  log := current_setting('t236.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
select 't236 leftover rows = ' || ((select count(*) from booking.customers where email like 't236-%@example.test') + (select count(*) from auth.users where email like 't236-%@example.test')) as t236_check;
