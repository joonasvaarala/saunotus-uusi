-- t233: muut muutokset täsmäävät loppusaldoon (booking_233).
-- Johku-saldon synkka (johku_sync) ja oman kortin hyvitys ovat muita, eivät myyntiä eikä käyttöä.
-- Alku + myyty − käytetty + muut − vanhentunut = loppu. Myynti-CSV ei saa Johkua.
-- Aja migraatioiden jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t233.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t233.log', coalesce(current_setting('t233.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;

do $t$
declare
  u uuid := gen_random_uuid();
  o bigint;
  g_j bigint; g_own bigint;
  gc jsonb; rowj jsonb; csv text; sales text;
  d0 date := '2035-08-01'; d1 date := '2035-08-31';
  log text; np int; nf int;
  ident numeric;
begin
  insert into auth.users(id, email) values (u, 't233-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values (u, 't233-mgr@example.test', 't233 manager', 'manager');
  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'paid', 40, 'admin', 'fi', '2035-08-02 09:00:00+00') returning id into o;

  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, buyer_name, complimentary, activated_at, valid_from, valid_to)
  values ('JK233SYN00K2', 'johku', 'johku', 'johku', 'at_sale', 25.5, 2000, 1575, 'active', 'T233 Johku', false, '2035-07-01 10:00:00+00', '2035-07-01', '2036-08-01') returning id into g_j;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at, note)
  values (g_j, 14911, 14911, 'johku_purchase', '2035-07-02 10:00:00+00', 'alku'),
         (g_j, 2413, 17324, 'johku_purchase', '2035-08-03 10:00:00+00', 'myynti'),
         (g_j, -1878, 15446, 'johku_usage', '2035-08-04 10:00:00+00', 'kaytto'),
         (g_j, 462, 15908, 'johku_sync', '2035-08-05 10:00:00+00', 'Johku-saldon synkka');
  -- vanhentunut kortti: saldo 730, valid_to jaksolla, ei muita liikkeitä jaksolla
  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, complimentary, activated_at, valid_from, valid_to)
  values ('JK233EXP00K3', 'johku', 'johku', 'johku', 'at_sale', 25.5, 730, 730, 'active', false, '2035-07-01 10:00:00+00', '2035-07-01', '2035-08-20') returning id into g_own;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at)
  values (g_own, 730, 730, 'johku_purchase', '2035-07-03 10:00:00+00');

  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, complimentary, activated_at, valid_from, valid_to)
  values ('HH233REF00Q1', 'own', 'native', 'native', 'at_sale', 25.5, 100, 105, 'active', false, '2035-07-01 10:00:00+00', '2035-07-01', '2036-08-01') returning id into g_j;
  insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, at)
  values (g_j, o, 100, 100, 'purchase', '2035-07-04 10:00:00+00'),
         (g_j, o, 5, 105, 'refund', '2035-08-06 10:00:00+00');

  perform pg_temp.login(u);
  gc := booking.admin_report_gift_cards('all', 'json', d0, d1);
  select e into rowj from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'johku';
  ident := (rowj ->> 'opening')::numeric + (rowj ->> 'sold_gross')::numeric - (rowj ->> 'redeemed_gross')::numeric + (rowj ->> 'other_gross')::numeric - (rowj ->> 'expired_gross')::numeric;
  perform pg_temp.ck((rowj ->> 'opening')::numeric = 14911 + 730 and (rowj ->> 'sold_gross')::numeric = 2413 and (rowj ->> 'redeemed_gross')::numeric = 1878
    and (rowj ->> 'expired_gross')::numeric = 730 and (rowj ->> 'other_gross')::numeric = 462 and abs(ident - (rowj ->> 'closing')::numeric) < 0.01, 'A1 Johku täsmää, synkka on muut');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(rowj -> 'events') e where e ->> 'kind' = 'other' and e ->> 'reason' = 'johku_sync' and (e ->> 'amount')::numeric = 462), 'A2 tapahtuma johku_sync 462');
  perform pg_temp.ck(position('JK233SYN00K2' in gc::text) = 0, 'A3 selkokoodi ei vastauksessa');

  select e into rowj from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'native_paid';
  ident := (rowj ->> 'opening')::numeric + (rowj ->> 'sold_gross')::numeric - (rowj ->> 'redeemed_gross')::numeric + (rowj ->> 'other_gross')::numeric - (rowj ->> 'expired_gross')::numeric;
  perform pg_temp.ck((rowj ->> 'other_gross')::numeric = 5 and abs(ident - (rowj ->> 'closing')::numeric) < 0.01
    and exists (select 1 from jsonb_array_elements(rowj -> 'events') e where e ->> 'reason' = 'refund'), 'B1 oman kortin hyvitys on muut ja täsmää');

  perform pg_temp.ck((select bool_and(abs((e ->> 'opening')::numeric + (e ->> 'sold_gross')::numeric - (e ->> 'redeemed_gross')::numeric + coalesce((e ->> 'other_gross')::numeric, 0) - (e ->> 'expired_gross')::numeric - (e ->> 'closing')::numeric) < 0.01)
    from jsonb_array_elements(gc -> 'activity' -> 'rows') e where coalesce((e ->> 'balance_applicable')::boolean, false)), 'C1 jokainen saldorivi täsmää');

  csv := booking.admin_report_gift_cards('all', 'csv', d0, d1) ->> 'content';
  perform pg_temp.ck(position('muut' in csv) > 0 and position('johku_sync' in csv) > 0 and position('462,00' in csv) > 0 and position('johku;' in csv) = 0, 'D1 CSV: muut ja syy, ei johku;-osiota');
  sales := booking.admin_report_csv(d0, d1, 'summary') ->> 'content';
  perform pg_temp.ck(position('johku' in lower(coalesce(sales, ''))) = 0, 'E1 myynti-CSV ilman Johkua');
  perform pg_temp.logout();

  log := current_setting('t233.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
