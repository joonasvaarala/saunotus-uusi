-- t231: admin_list_voucher_claims palauttaa varauksen tuotteen ja ajan sekä value_cardin.
-- Koko koodi ei tule listaan (_vc_json false). Henkilökunnan resolve-polkua ei muuteta.
-- TUOTANTOKELPOINEN: yksi transaktio, ROLLBACK. Ajo: psql -X -v ON_ERROR_STOP=0 -f t231_voucher_claim_list_booking.sql
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t231.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t231.log', coalesce(current_setting('t231.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.skip(p_label text) returns void language sql as $$
  select set_config('t231.log', coalesce(current_setting('t231.log', true), '') || 'S ' || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.rnd(p_prefix text, p_len int) returns text language sql volatile as $$
  select p_prefix || upper(substr(translate(md5(random()::text || clock_timestamp()::text), 'abcdef', 'ghjkmn'), 1, p_len)) $$;

do $t$
declare
  run text := lower(pg_temp.rnd('', 8));
  u uuid := gen_random_uuid();
  src text; def text;
  cu bigint; o bigint; ono bigint; item bigint; space bigint; res bigint; code text;
  r jsonb; claim jsonb;
  log text; np int; nf int; ns int;
begin
  select pg_get_functiondef('booking.admin_list_voucher_claims(text,text,integer,integer,text)'::regprocedure) into src;
  perform pg_temp.ck(src ilike '%security definer%' and src ilike '%search_path = ''''%' and src like '%booking._vc_json(c, false)%' and src like '%booking_product%' and src like '%value_card%' and src not like '%_vc_json(c, true)%', 'A1 lista: definer, maskattu json, varaus ja value_card');
  perform pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_list_voucher_claims(text,text,integer,integer,text)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_list_voucher_claims(text,text,integer,integer,text)', 'execute'), 'A2 execute authenticated, ei anon');
  select pg_get_functiondef('booking.admin_resolve_voucher_claim(bigint,text,text,text,numeric,text)'::regprocedure) into def;
  perform pg_temp.ck(def like '%_vc_redeem%' and def not like '%p_value_card%', 'A3 resolve ei välitä value_cardia (5-arg polku)');

  select id into space from booking.resources order by id limit 1;
  if space is null then perform pg_temp.skip('B ei resurssia, datatarkistus ohitetaan');
  else
    insert into auth.users(id, email) values (u, 't231-' || run || '@example.test');
    insert into booking.staff(user_id, email, name, role) values (u, 't231-' || run || '@example.test', 't231', 'staff');
    insert into booking.customers(name, email) values ('T231 Testi', 't231-c-' || run || '@example.test') returning id into cu;
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale) values (cu, 'confirmed', 'unpaid', 80, 'admin', 'fi') returning id, order_no into o, ono;
    insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate) values (o, 'T231 vuoro', 'reservation', 1, 80, 80, 25.5) returning id into item;
    insert into booking.reservations(order_id, order_item_id, space_id, mode, starts_at, ends_at, persons, status)
      values (o, item, space, 'shared', now() + interval '4 days', now() + interval '4 days' + interval '2 hours', 2, 'confirmed') returning id into res;
    code := pg_temp.rnd('T231', 8);
    insert into booking.voucher_claims(order_id, reservation_id, order_item_id, code, source, customer_name, locale, status)
      values (o, res, item, code, 'elamyslahjat', 'T231 Testi', 'fi', 'open');
    perform pg_temp.login(u);
    r := booking.admin_list_voucher_claims('open', ono::text, 20, 0, 'oldest_open');
    perform pg_temp.logout();
    claim := r -> 'claims' -> 0;
    perform pg_temp.ck((r ->> 'ok')::boolean and (r ->> 'total')::int = 1, 'B1 haku tilausnumerolla löytää yhden');
    perform pg_temp.ck(claim ->> 'booking_product' = 'T231 vuoro' and (claim ->> 'booking_reservation_id')::bigint = res and claim ->> 'booking_starts_at' is not null, 'B2 varauksen nimi, id ja alku');
    perform pg_temp.ck(claim ->> 'code' is null and claim ->> 'code_masked' is not null and claim ->> 'code_masked' <> code and position(code in claim::text) = 0, 'B3 listassa vain maskattu koodi');
    perform pg_temp.ck(coalesce((claim ->> 'value_card')::boolean, true) = false, 'B4 value_card false kun botti ei ole merkinnyt');
  end if;

  log := current_setting('t231.log', true);
  select count(*) filter (where left(line, 1) = 'P'), count(*) filter (where left(line, 1) = 'F'), count(*) filter (where left(line, 1) = 'S')
    into np, nf, ns from unnest(string_to_array(log, E'\n')) line where line <> '';
  raise notice 'TESTRESULT pass=% fail=% skip=%', np, nf, ns;
  raise notice '%', log;
  if nf > 0 then raise exception 't231 failed'; end if;
end $t$;
rollback;
