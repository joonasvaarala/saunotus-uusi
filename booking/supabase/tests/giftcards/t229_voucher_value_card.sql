-- t229: booking_229 arvolahjakortin erotusviesti.
--   A) svc_mark_voucher_claim_redeemed(bigint,numeric,text,text,boolean), p_value_card boolean default false.
--      Vanha neljän argumentin allekirjoitus on poissa. Oikeudet: service_role, ei anon/authenticated.
--      _vc_redeem(6) on sisäinen (ei service_role). value_card-sarake on pyynnöllä.
--   B) ilman p_value_card (sijainti ja nimetty) → payload value_card false, pyyntö false, yleinen polku.
--   C) p_value_card true (sijainti ja nimetty, keskimmäiset oletuksilla) → payload true, pyyntö true, audit.
--   D) täysi arvo + true → ei maksulinkkiä, sarake silti true. Uusintakutsu ei vaihda lippua eikä lähetä toista viestiä.
--   E) email_outbox_claim_base_215 / email_outbox_claim kopioi value_cardin voucher_difference-lohkoon.
-- TUOTANTOKELPOINEN: yksi transaktio, ROLLBACK, ei kiinteitä id-arvoja, ei psql-metakomentoja.
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t229_voucher_value_card.sql
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t229.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t229.log', coalesce(current_setting('t229.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.skip(p_label text) returns void language sql as $$
  select set_config('t229.log', coalesce(current_setting('t229.log', true), '') || 'S ' || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; s text;
begin execute 'select (' || p_sql || ')::jsonb' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate; return jsonb_build_object('state', s, 'err', case when s = 'BK001' then d else s end);
end $$;
create function pg_temp.svc() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"service_role"}', true); execute 'set local role service_role'; end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
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
create function pg_temp.mkclaim(p_order bigint, p_source text) returns booking.voucher_claims language plpgsql as $$
declare c booking.voucher_claims;
begin
  insert into booking.voucher_claims(order_id, code, source, customer_name, locale)
  values (p_order, pg_temp.rnd('TQ', 10), p_source, 'T229 Testi', 'fi') returning * into c;
  return c;
end $$;

do $t$
declare
  run text := lower(pg_temp.rnd('', 8));
  u_adm uuid := gen_random_uuid();
  cu bigint; o bigint; c booking.voucher_claims; r jsonb; x jsonb; lnk bigint;
  args text; def text;
  log text; np int; nf int; ns int;
begin
  insert into auth.users(id, email) values (u_adm, 't229-admin-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't229-admin-' || run || '@example.test', 't229 admin', 'admin');
  insert into booking.customers(name, email) values ('T229 Testi', 't229-' || run || '@example.test') returning id into cu;

  select pg_get_function_arguments(p.oid) into args
    from pg_proc p
   where p.oid = to_regprocedure('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text,boolean)');
  perform pg_temp.ck(to_regprocedure('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)') is null
      and args is not null and lower(args) like '%p_value_card boolean default false%', 'A1 viides parametri p_value_card boolean default false, vanha allekirjoitus poissa');
  perform pg_temp.ck(has_function_privilege('service_role', 'booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text,boolean)', 'execute')
      and not has_function_privilege('anon', 'booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text,boolean)', 'execute')
      and not has_function_privilege('authenticated', 'booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text,boolean)', 'execute'), 'A2 svc vain service_role');
  perform pg_temp.ck(to_regprocedure('booking._vc_redeem(bigint,numeric,text,text,text)') is not null
      and to_regprocedure('booking._vc_redeem(bigint,numeric,text,text,text,boolean)') is not null
      and not has_function_privilege('service_role', 'booking._vc_redeem(bigint,numeric,text,text,text,boolean)', 'execute')
      and not has_function_privilege('anon', 'booking._vc_redeem(bigint,numeric,text,text,text,boolean)', 'execute')
      and not has_function_privilege('authenticated', 'booking._vc_redeem(bigint,numeric,text,text,text,boolean)', 'execute'), 'A3 _vc_redeem(6) sisäinen, viisipaikkainen ennallaan');
  perform pg_temp.ck(exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'voucher_claims' and column_name = 'value_card' and data_type = 'boolean' and column_default like '%false%'), 'A4 value_card boolean default false');

  -- B sijaintikutsu ilman viidettä argumenttia
  o := pg_temp.mkorder(cu, 80, 'fi', 'T229 yleinen');
  c := pg_temp.mkclaim(o, 'kokemuskauppa');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(c.id, 50, 'T229-GEN', null);
  perform pg_temp.logout();
  select to_jsonb(e) into x from booking.email_outbox e where e.order_id = o and e.kind = 'payment_link';
  perform pg_temp.ck((r ->> 'ok') = 'true' and (r ->> 'difference')::numeric = 30 and (r ->> 'value_card') = 'false' and (r ->> 'email_queued') = 'true', 'B1 neljä argumenttia: erotus 30, value_card false');
  perform pg_temp.ck(x #>> '{payload,variant}' = 'voucher_difference' and (x #>> '{payload,value_card}') = 'false'
      and (x #>> '{payload,voucher_value}')::numeric = 50 and (x #>> '{payload,difference}')::numeric = 30 and (x #>> '{payload,total}')::numeric = 80, 'B2 payload value_card false');
  perform pg_temp.ck((select value_card = false from booking.voucher_claims where id = c.id), 'B3 pyyntö value_card false');

  -- B nimetty ilman p_value_card
  o := pg_temp.mkorder(cu, 80, 'en', 'T229 nimetty yleinen');
  c := pg_temp.mkclaim(o, 'offerilla');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(p_id := c.id, p_amount := 50, p_partner_ref := 'T229-NAMED', p_note := null);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'value_card') = 'false' and (select value_card = false and (select (payload ->> 'value_card') = 'false' from booking.email_outbox where order_id = o and kind = 'payment_link') from booking.voucher_claims where id = c.id), 'B4 nimetty kutsu ilman p_value_card = false');

  -- C arvolahjakortti, sijainti
  o := pg_temp.mkorder(cu, 80, 'fi', 'T229 arvo');
  c := pg_temp.mkclaim(o, 'elamyslahjat');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(c.id, 50, 'T229-CARD', 'yli vuosi', true);
  perform pg_temp.logout();
  select to_jsonb(e) into x from booking.email_outbox e where e.order_id = o and e.kind = 'payment_link';
  lnk := (x ->> 'id')::bigint;
  perform pg_temp.ck((r ->> 'value_card') = 'true' and (r ->> 'email_queued') = 'true' and (r ->> 'difference')::numeric = 30, 'C1 viides argumentti true');
  perform pg_temp.ck((x #>> '{payload,value_card}') = 'true' and (x #>> '{payload,variant}') = 'voucher_difference', 'C2 payload value_card true');
  perform pg_temp.ck((select value_card from booking.voucher_claims where id = c.id), 'C3 pyyntö value_card true');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where table_name = 'booking.voucher_claims' and row_pk = c.id::text and action = 'VOUCHER_DIFFERENCE_LINK' and (new_data ->> 'value_card') = 'true'), 'C4 audit value_card true');

  -- C nimetty, partner_ref ja note oletuksilla
  o := pg_temp.mkorder(cu, 90, 'en', 'T229 nimetty arvo');
  c := pg_temp.mkclaim(o, 'kokemuskauppa');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(p_id := c.id, p_amount := 40, p_value_card := true);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'value_card') = 'true' and (r ->> 'difference')::numeric = 50
      and (select value_card and (select (payload ->> 'value_card') = 'true' and (payload ->> 'difference')::numeric = 50 from booking.email_outbox where order_id = o and kind = 'payment_link') from booking.voucher_claims where id = c.id), 'C5 nimetty p_value_card true, keskimmäiset oletuksilla');

  -- D täysi arvo ei lähetä linkkiä, sarake silti true; uusinta ei vaihda
  o := pg_temp.mkorder(cu, 40, 'fi', 'T229 täysi');
  c := pg_temp.mkclaim(o, 'offerilla');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(c.id, 40, null, null, true);
  perform pg_temp.ck(r -> 'payment_link' = 'null'::jsonb and (r ->> 'email_queued') = 'false' and (r ->> 'value_card') = 'true', 'D1 täysi arvo: ei linkkiä, value_card true');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = o and kind = 'payment_link'), 'D2 ei maksulinkkiviestiä');
  r := booking.svc_mark_voucher_claim_redeemed(c.id, 40, null, null, false);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'already') = 'true' and (select value_card from booking.voucher_claims where id = c.id), 'D3 uusintakutsu ei nollaa value_cardia');

  o := pg_temp.mkorder(cu, 30, 'fi', 'T229 kielto');
  c := pg_temp.mkclaim(o, 'kokemuskauppa');
  perform pg_temp.login(u_adm);
  r := pg_temp.call(format('booking.svc_mark_voucher_claim_redeemed(%s, 10, null, null, true)', c.id));
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'err' = '42501', 'D4 authenticated ei saa kutsua (42501)');

  -- E jonon rikastus, jos jonossa ei ole muiden viestejä
  if lnk is null then
    perform pg_temp.skip('E1 email_outbox_claim ohitettu: C-viesti puuttuu');
  elsif exists (select 1 from booking.email_outbox e where e.status in ('pending', 'failed') and e.next_attempt_at <= now()
                  and not exists (select 1 from booking.orders t where t.id = e.order_id and t.customer_id = cu)) then
    perform pg_temp.skip('E1 email_outbox_claim ohitettu: jonossa muita lähetettäviä viestejä');
  else
    update booking.email_outbox set status = 'skipped' where status in ('pending', 'failed') and order_id in (select id from booking.orders where customer_id = cu) and id <> lnk;
    update booking.email_outbox set status = 'pending', next_attempt_at = now() - interval '1 second' where id = lnk;
    r := booking.email_outbox_claim(50);
    r := (select e from jsonb_array_elements(r) e where (e ->> 'id')::bigint = lnk);
    perform pg_temp.ck((r #>> '{voucher_difference,value_card}') = 'true'
        and (r #>> '{voucher_difference,total}')::numeric = 80
        and (r #>> '{voucher_difference,voucher_value}')::numeric = 50
        and (r #>> '{voucher_difference,difference}')::numeric = 30, 'E1 claim kopioi value_card true');
    select e.id into lnk from booking.email_outbox e where e.payload ->> 'value_card' = 'false' and e.kind = 'payment_link' and e.order_id in (select id from booking.orders where customer_id = cu) order by e.id limit 1;
    update booking.email_outbox set status = 'skipped' where status in ('pending', 'failed') and id <> lnk;
    update booking.email_outbox set status = 'pending', next_attempt_at = now() - interval '1 second' where id = lnk;
    r := booking.email_outbox_claim(50);
    r := (select e from jsonb_array_elements(r) e where (e ->> 'id')::bigint = lnk);
    perform pg_temp.ck((r #>> '{voucher_difference,value_card}') = 'false', 'E2 claim kopioi value_card false');
  end if;

  def := pg_get_functiondef('booking.email_outbox_claim_base_215(integer)'::regprocedure);
  perform pg_temp.ck(def like '%''value_card'', coalesce((e.payload ->> ''value_card'')::boolean, false)%', 'E3 base_215 rakentaa value_cardin');

  log := current_setting('t229.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
select 't229 leftover rows = ' || ((select count(*) from booking.customers where email like 't229-%@example.test') + (select count(*) from auth.users where email like 't229-%@example.test')) as t229_check;
