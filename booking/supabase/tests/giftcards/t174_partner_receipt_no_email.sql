-- t174: booking_174 (tuotantoversio 20261024235019).
--   1) Kumppanilahjakortin maksu (partner_voucher + kolme myyjäkohtaista) → K-kuitti kirjanpitoon (+ accounting_outbox, kun Procountor ei ole off),
--      EI kuittisähköpostia. Tavallinen maksu (korttipääte) → kuitti kirjanpitoon; kuittisähköposti status skipped, last_error receipt_auto_send disabled (booking_191).
--   2) Lahjakortin arvo käsin ennen hyväksyntää (admin_mark_voucher_claim_redeemed p_amount): arvo < maksettava → kumppanimaksu arvon suuruisena,
--      erotus Visma Pay -maksulinkkinä (payment_link-sähköposti, payload voucher_difference: total / voucher_value / difference); täysi arvo → ei linkkiä;
--      arvo > maksettava → BK001 voucher_exceeds_total; arvo <= 0 tai yli 2 desimaalia → BK001 invalid_amount. Erotuksen maksu → tavallinen kuittisähköposti.
-- TUOTANTOKELPOINEN: yksi transaktio (BEGIN … lopussa tahallinen poikkeus "TESTRESULT pass=… fail=… skip=…" + ROLLBACK), ei kiinteitä id-arvoja (RETURNING),
-- testikäyttäjät luodaan transaktion sisällä (auth.users + booking.staff, gen_random_uuid), ei psql-metakomentoja → toimii myös pelkällä SQL-työkalulla.
-- Asetukset (voucher_claims.partner_voucher_accounted, Procountorin tila dry_run) muutetaan vain transaktion sisällä ja palautetaan; mitään ei jää.
-- Apufunktiot pg_temp-skeemassa (ei public-skeemaa). Virheet tarkistetaan SQLSTATE + BK001-detail -koodeilla, ei virhetekstein. Ei sähköposteja (jono kumoutuu).
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t174_partner_receipt_no_email.sql   (tai liitä koko tiedosto SQL-editoriin; tulos virheviestissä TESTRESULT …)
-- Jälkitarkistus ROLLBACKin jälkeen (erillinen SELECT, ks. tiedoston loppu): t174 leftover rows = 0.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t174.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t174.log', coalesce(current_setting('t174.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.skip(p_label text) returns void language sql as $$
  select set_config('t174.log', coalesce(current_setting('t174.log', true), '') || 'S ' || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
-- ajaa lausekkeen; palauttaa jsonb-tuloksen tai {"state": SQLSTATE, "err": BK001-detail | SQLSTATE}
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; s text;
begin execute 'select (' || p_sql || ')::jsonb' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate; return jsonb_build_object('state', s, 'err', case when s = 'BK001' then d else s end);
end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.rnd(p_prefix text, p_len int) returns text language sql volatile as $$
  select p_prefix || upper(substr(translate(md5(random()::text || clock_timestamp()::text), 'abcdef', 'ghjkmn'), 1, p_len)) $$;
-- tilaus + yksi rivi (feikki), palauttaa tilauksen id:n
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
  insert into booking.voucher_claims(order_id, code, source, source_suggested, customer_name, locale)
  values (p_order, pg_temp.rnd('TQ', 10), p_source, null, 'T174 Testi', 'fi') returning * into c;
  return c;
end $$;

do $t$
declare
  run text := lower(pg_temp.rnd('', 8));
  u_adm uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid();
  cu bigint; o bigint; ob booking.orders; c booking.voucher_claims; pay bigint; rc bigint; lnk bigint; m text; src text; n int; cnt int := 0;
  r jsonb; x jsonb; cfg0 booking.integration_config; acc0 jsonb; log text; np int; nf int; ns int;
begin
  select * into cfg0 from booking.integration_config where key = 'procountor';
  select value into acc0 from booking.settings where key = 'voucher_claims.partner_voucher_accounted';
  insert into auth.users(id, email) values (u_adm, 't174-admin-' || run || '@example.test'), (u_rec, 't174-rec-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't174-admin-' || run || '@example.test', 't174 admin', 'admin');

  -- ===== A rakenne
  perform pg_temp.ck(md5(pg_get_functiondef('booking._on_payment_paid(bigint)'::regprocedure)) in ('de9084871640d213d10527a045157bf2', 'af7f99e87ba7e00e0d5e3d5b6cbf2400', '4b2517c30dfabeae29b1df62f21a7dd9'), 'A1 _on_payment_paid = booking_174 (tai booking_176 / booking_223)');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure)) in ('525d1fa96fd7c37df4d7e502edf1bf71', 'a4e69cb26eb44b72eacce7c167342884'), 'A2 admin_mark_voucher_claim_redeemed = booking_174 (tai booking_176)');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure)) in ('2db9a1233a06e6293d0877f17de1ab72', '70602f6500703e8750e1539ae8809d38'), 'A3 email_outbox_claim = booking_174 (tai booking_176)');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking._vc_due(booking.orders,booking.voucher_claims)', 'execute')
      and not has_function_privilege('anon', 'booking._vc_due(booking.orders,booking.voucher_claims)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute'), 'A4 oikeudet: _vc_due sisäinen, lunastus authenticated (ei anon)');
  perform pg_temp.ck((select count(*) from booking.payment_methods where booking._is_partner_method(code)) = 4, 'A5 neljä kumppanimaksutapaa');

  -- ===== fixture (feikki, vain tässä transaktiossa)
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.partner_voucher_accounted';
  update booking.integration_config set mode = 'dry_run' where key = 'procountor' and mode = 'off';   -- kirjanpitojonon tarkistus; ei live, ei daily_enabled
  insert into booking.customers(name, email) values ('T174 Testi', 't174-' || run || '@example.test') returning id into cu;

  -- ===== B kumppanilahjakortti _vc_pay-polulla: kuitti + kirjanpitojono, ei kuittisähköpostia (kaikki neljä maksutapaa)
  foreach src in array array['kokemuskauppa', 'offerilla', 'elamyslahjat', 'partner_other'] loop
    o := pg_temp.mkorder(cu, 40, 'fi', 'T174 sauna ' || src);
    c := pg_temp.mkclaim(o, src);
    select * into ob from booking.orders where id = o;
    r := booking._vc_pay(ob, c, null);
    pay := (r ->> 'payment_id')::bigint;
    select method into m from booking.payments where id = pay;
    select id into rc from booking.receipts where payment_id = pay and kind = 'receipt';
    perform pg_temp.ck(booking._is_partner_method(m) and m = booking._vc_method(src), 'B1 ' || src || ': maksutapa ' || coalesce(m, 'NULL'));
    perform pg_temp.ck(rc is not null and (select series = 'K' and total_gross = 40 from booking.receipts where id = rc), 'B2 ' || src || ': K-kuitti syntyi (40 €)');
    perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = o and kind = 'receipt'), 'B3 ' || src || ': ei kuittisähköpostia');
    perform pg_temp.ck(exists (select 1 from booking.accounting_outbox where receipt_id = rc and kind = 'receipt'), 'B4 ' || src || ': kirjanpitojonossa (accounting_outbox)');
    cnt := cnt + 1;
  end loop;
  perform pg_temp.ck(cnt = 4, 'B5 kaikki neljä myyjää käyty');

  -- ===== C tavallinen maksu (henkilökunta, korttipääte): kuitti kirjanpitoon, kuittisähköposti skipped (booking_191)
  o := pg_temp.mkorder(cu, 35, 'fi', 'T174 kortti');
  perform pg_temp.login(u_adm);
  r := booking.admin_record_payment(o, 'card_terminal', 35, 't174 kortti', null);
  perform pg_temp.logout();
  select id into pay from booking.payments where order_id = o and status = 'paid' and method = 'card_terminal';
  select id into rc from booking.receipts where payment_id = pay and kind = 'receipt';
  perform pg_temp.ck(rc is not null, 'C1 korttimaksu: kuitti');
  perform pg_temp.ck(exists (select 1 from booking.email_outbox where kind = 'receipt' and receipt_id = rc and payment_id = pay and dedupe_key = 'receipt:' || rc and status = 'skipped' and last_error = 'receipt_auto_send disabled'), 'C2 korttimaksu: kuittisähköposti skipped (receipt_auto_send disabled)');
  perform pg_temp.ck(exists (select 1 from booking.accounting_outbox where receipt_id = rc), 'C3 korttimaksu: kirjanpitojonossa');

  -- ===== D partner_voucher_accounted = false: ei kuittia, ei sähköpostia (ennallaan)
  update booking.settings set value = 'false'::jsonb where key = 'voucher_claims.partner_voucher_accounted';
  o := pg_temp.mkorder(cu, 25, 'fi', 'T174 ei kirjanpitoon');
  c := pg_temp.mkclaim(o, 'offerilla');
  select * into ob from booking.orders where id = o;
  r := booking._vc_pay(ob, c, null);
  pay := (r ->> 'payment_id')::bigint;
  perform pg_temp.ck(pay is not null and not exists (select 1 from booking.receipts where payment_id = pay) and not exists (select 1 from booking.email_outbox where order_id = o and kind = 'receipt'),
      'D1 accounted=false: maksu kirjattu, ei kuittia eikä kuittisähköpostia');
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.partner_voucher_accounted';

  -- ===== E arvo käsin, pienempi kuin maksettava → erotus maksulinkkinä (EN-tilaus)
  o := pg_temp.mkorder(cu, 80, 'en', 'T174 osittainen');
  c := pg_temp.mkclaim(o, 'kokemuskauppa');
  perform pg_temp.login(u_adm);
  r := booking.admin_mark_voucher_claim_redeemed(c.id, 50, 'T174-REF', null);
  perform pg_temp.logout();
  pay := (r ->> 'payment_id')::bigint;
  lnk := (r #>> '{payment_link,payment_id}')::bigint;
  perform pg_temp.ck(r ->> 'ok' = 'true' and (r ->> 'amount')::numeric = 50 and (r ->> 'voucher_value')::numeric = 50 and (r ->> 'due')::numeric = 80 and (r ->> 'difference')::numeric = 30
      and (r ->> 'email_queued')::boolean, 'E1 vastaus: arvo 50, maksettava 80, erotus 30, sähköposti jonossa');
  perform pg_temp.ck((select method = 'partner_voucher_kokemuskauppa' and amount = 50 and status = 'paid' from booking.payments where id = pay), 'E2 kumppanimaksu vain arvon suuruinen (50 €)');
  perform pg_temp.ck(exists (select 1 from booking.receipts where payment_id = pay and kind = 'receipt' and total_gross = 50)
      and not exists (select 1 from booking.email_outbox where order_id = o and kind = 'receipt'), 'E3 lahjakorttiosuus: kuitti 50 €, ei kuittisähköpostia');
  perform pg_temp.ck((select provider = 'montonio' and method = 'montonio' and status = 'pending' and amount = 30 and link_token is not null and link_expires_at is null
      and raw ->> 'paylink' = 'no_deadline' from booking.payments where id = lnk), 'E4 erotus 30 € verkkomaksun linkkinä (pending, ei takarajaa)');
  select to_jsonb(e) into x from booking.email_outbox e where e.order_id = o and e.kind = 'payment_link' and e.payment_id = lnk;
  perform pg_temp.ck(x is not null and x ->> 'locale' = 'en' and x #>> '{payload,variant}' = 'voucher_difference' and (x #>> '{payload,total}')::numeric = 80
      and (x #>> '{payload,voucher_value}')::numeric = 50 and (x #>> '{payload,difference}')::numeric = 30, 'E5 payment_link-sähköposti: EN, total 80 / voucher 50 / difference 30');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = o and kind = 'payment_link') = 1, 'E6 yksi maksulinkkiviesti');
  perform pg_temp.ck((select status = 'redeemed' and voucher_value = 50 and amount = 50 and payment_id = pay from booking.voucher_claims where id = c.id), 'E7 pyyntö lunastettu, arvo 50');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where table_name = 'booking.voucher_claims' and row_pk = c.id::text and action = 'VOUCHER_DIFFERENCE_LINK' and actor = u_adm
      and (new_data ->> 'difference')::numeric = 30), 'E8 audit VOUCHER_DIFFERENCE_LINK');
  perform pg_temp.ck(((booking._order_balance(o)) ->> 'unpaid')::numeric = 30, 'E9 tilauksella maksamatta 30 €');
  -- sähköpostijonon lohko voucher_difference (vain jos jonossa ei ole muita kuin tämän testin lähetettäviä viestejä; muuten ohitetaan, ettei testi lukitse oikeita viestejä)
  if not exists (select 1 from booking.email_outbox e where e.status in ('pending', 'failed') and e.next_attempt_at <= now()
                   and not exists (select 1 from booking.orders t where t.id = e.order_id and t.customer_id = cu)) then
    update booking.email_outbox set status = 'pending', next_attempt_at = now() - interval '1 second' where id = (x ->> 'id')::bigint;
    r := booking.email_outbox_claim(50);
    r := (select e from jsonb_array_elements(r) e where (e ->> 'id')::bigint = (x ->> 'id')::bigint);
    perform pg_temp.ck((r #>> '{voucher_difference,total}')::numeric = 80 and (r #>> '{voucher_difference,voucher_value}')::numeric = 50 and (r #>> '{voucher_difference,difference}')::numeric = 30
        and (r #>> '{payment,amount}')::numeric = 30 and r #>> '{payment,link_url}' like '%?p=%', 'E10 email_outbox_claim: voucher_difference-lohko + maksulinkki');
  else
    perform pg_temp.skip('E10 email_outbox_claim ohitettu: jonossa muita lähetettäviä viestejä');
  end if;
  -- asiakas maksaa erotuksen → kuitti (ilman booking_176:ta kuittisähköposti skipped, receipt_auto_send disabled; booking_176: ei kuittisähköpostia, kuitti tilaussivulla)
  update booking.payments set status = 'paid', paid_at = now() where id = lnk;
  select id into rc from booking.receipts where payment_id = lnk and kind = 'receipt';
  if to_regclass('booking.vc_difference_payments') is null then
    perform pg_temp.ck(rc is not null and exists (select 1 from booking.email_outbox where kind = 'receipt' and receipt_id = rc and status = 'skipped' and last_error = 'receipt_auto_send disabled'), 'E11 erotuksen maksu: kuitti, kuittisähköposti skipped (receipt_auto_send disabled)');
    perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = o and kind = 'receipt' and status = 'skipped' and last_error = 'receipt_auto_send disabled') = 1, 'E12 tilauksella vain erotuksen kuittisähköposti (skipped)');
  else
    perform pg_temp.ck(rc is not null and not exists (select 1 from booking.email_outbox where kind = 'receipt' and receipt_id = rc), 'E11 erotuksen maksu: kuitti, ei kuittisähköpostia (booking_176)');
    perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = o and kind = 'receipt') = 0, 'E12 tilauksella ei kuittisähköpostia (booking_176)');
  end if;

  -- ===== F täysi arvo → ei maksulinkkiä; arvo tyhjä (vanha tapa) → ei maksulinkkiä
  o := pg_temp.mkorder(cu, 40, 'fi', 'T174 täysi');
  c := pg_temp.mkclaim(o, 'offerilla');
  perform pg_temp.login(u_adm);
  r := booking.admin_mark_voucher_claim_redeemed(c.id, 40, null, null);
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and (r ->> 'amount')::numeric = 40 and r -> 'payment_link' = 'null'::jsonb and not (r ->> 'email_queued')::boolean, 'F1 täysi arvo: ok, ei linkkiä');
  perform pg_temp.ck(not exists (select 1 from booking.payments where order_id = o and provider = 'visma_pay') and not exists (select 1 from booking.email_outbox where order_id = o and kind in ('payment_link', 'receipt')),
      'F2 täysi arvo: ei Visma Pay -maksua, ei maksulinkki- eikä kuittisähköpostia');
  perform pg_temp.ck(((booking._order_balance(o)) ->> 'unpaid')::numeric = 0, 'F3 täysi arvo: tilaus maksettu');
  o := pg_temp.mkorder(cu, 45, 'fi', 'T174 ilman arvoa');
  c := pg_temp.mkclaim(o, 'elamyslahjat');
  perform pg_temp.login(u_adm);
  r := booking.admin_mark_voucher_claim_redeemed(c.id, null, null, null);
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and (r ->> 'amount')::numeric = 45 and r -> 'payment_link' = 'null'::jsonb
      and not exists (select 1 from booking.email_outbox where order_id = o and kind in ('payment_link', 'receipt')), 'F4 arvo tyhjä: koko summa, ei linkkiä, ei kuittisähköpostia');
  perform pg_temp.login(u_adm);
  r := pg_temp.call(format('booking.admin_mark_voucher_claim_redeemed(%s, 10)', c.id));
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'already')::boolean and r -> 'payment_link' = 'null'::jsonb and (select count(*) from booking.payments where order_id = o) = 1,
      'F5 uusi kutsu lunastetulle: already, ei uutta maksua eikä linkkiä');

  -- ===== G virheet (SQLSTATE BK001 + koodi), mitään ei kirjata
  o := pg_temp.mkorder(cu, 30, 'fi', 'T174 virheet');
  c := pg_temp.mkclaim(o, 'offerilla');
  perform pg_temp.login(u_adm);
  r := pg_temp.call(format('booking.admin_mark_voucher_claim_redeemed(%s, 30.01)', c.id));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'voucher_exceeds_total', 'G1 arvo > maksettava → BK001 voucher_exceeds_total');
  r := pg_temp.call(format('booking.admin_mark_voucher_claim_redeemed(%s, 0)', c.id));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'invalid_amount', 'G2 arvo 0 → BK001 invalid_amount');
  r := pg_temp.call(format('booking.admin_mark_voucher_claim_redeemed(%s, -5)', c.id));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'invalid_amount', 'G3 negatiivinen → BK001 invalid_amount');
  r := pg_temp.call(format('booking.admin_mark_voucher_claim_redeemed(%s, 10.005)', c.id));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'invalid_amount', 'G4 kolme desimaalia → BK001 invalid_amount');
  perform pg_temp.logout();
  perform pg_temp.ck((select status = 'open' from booking.voucher_claims where id = c.id) and not exists (select 1 from booking.payments where order_id = o)
      and not exists (select 1 from booking.email_outbox where order_id = o and kind in ('payment_link', 'receipt')), 'G5 hylätty: pyyntö auki, ei maksuja, ei sähköposteja');
  perform pg_temp.login(u_rec);
  r := pg_temp.call(format('booking.admin_mark_voucher_claim_redeemed(%s, 10)', c.id));
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'forbidden', 'G6 muu kuin henkilökunta → BK001 forbidden');

  -- palautus (transaktio kumotaan joka tapauksessa)
  update booking.settings set value = acc0 where key = 'voucher_claims.partner_voucher_accounted';
  update booking.integration_config set mode = cfg0.mode where key = 'procountor';
  perform pg_temp.ck((select mode = cfg0.mode and settings is not distinct from cfg0.settings from booking.integration_config where key = 'procountor'), 'X1 Procountor-asetus ennallaan');

  log := current_setting('t174.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
select 't174 leftover rows = ' || ((select count(*) from booking.customers where email like 't174-%@example.test') + (select count(*) from auth.users where email like 't174-%@example.test')) as t174_check;
