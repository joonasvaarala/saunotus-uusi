-- t178: booking_178 maksulinkin uusi yritys peruutuksen jälkeen (omistaja Joonas 25.10.2026: peruttu/keskeytetty Visma Pay -maksu EI kuluta maksulinkkiä).
--   A) rakenne: vismapay_payment_apply / vismapay_payment_lookup / public_payment_link_info / _vismapay_attempt_trg = booking_178 (md5), SECURITY DEFINER,
--      search_path ''; oikeudet ennallaan (apply/lookup vain service_role, link_info anon); riippuvuudet ennallaan; booking.vismapay_attempts: RLS päällä,
--      anon ei lue (42501), trigger payments_vismapay_attempt olemassa.
--   B) peruutus → linkki yhä open (last_attempt = cancelled), maksu pending, vanha token/ohjausosoite poistettu, audit VISMAPAY_CANCELLED_RETRYABLE;
--      uusi painallus luo UUDEN yrityksen (-a2, ei vanhan tokenin uudelleenkäyttöä); toistuva peruutusilmoitus ja vanhan yrityksen ilmoitus eivät muuta mitään;
--      hylätty kortti (failed) → sama; toisto idempotentti.
--   C) myöhästynyt "maksettu" vanhalle yritykselle (uudempi yritys jo luotu) → maksu kirjataan kerran, provider_ref = maksanut yritys, uudempi korvattu;
--      toisto idempotentti; uudemman yrityksen maksu → EI toista maksua (needs_review/duplicate_paid, TUPLAVELOITUS-merkintä, audit kerran); prepare → already_paid;
--      lookup löytää vanhan ja nykyisen tilausnumeron.
--   D) linkki vanhentunut → peruutus kuluttaa linkin (cancelled) → expired/link_expired; prepare → link_expired/payment_not_pending.
--   E) korvattu linkki (käsin kirjattu osamaksu perui) → myöhästynyt peruutus ei muuta → replaced; uusi linkki open. Summa muuttui (stale) → cancelled → replaced/link_stale.
--   F) verkkokaupan tavallinen maksu (order_token, 60 min) ennallaan: peruutus → cancelled, audit VISMAPAY_CANCELLED, vastaus {ok, outcome}; uusi yritys = uusi maksurivi.
--   G) SQLSTATE: anon → apply/lookup 42501, vismapay_attempts 42501; virheellinen uuid → 22P02; virheellinen tilausnumero → invalid_param, tuntematon → not_found.
-- TUOTANTOKELPOINEN: yksi transaktio (BEGIN … lopussa tahallinen poikkeus "TESTRESULT pass=… fail=… skip=…" + ROLLBACK), ei kiinteitä id-arvoja, testikäyttäjät
-- luodaan transaktion sisällä (auth.users + booking.staff), ei psql-metakomentoja. Edge-funktioiden RPC:t kutsutaan roolilla service_role, julkinen RPC roolilla anon,
-- hallinta oikealla JWT-kirjautumisella. Ei Visma-kutsuja (tilausnumerot ja tokenit ovat paikallisia), ei sähköposteja (kaikki kumotaan).
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t178_paylink_retry.sql   (tai liitä koko tiedosto SQL-editoriin; tulos virheviestissä TESTRESULT …)
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t178.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t178.log', coalesce(current_setting('t178.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
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
  values (v, p_pid, 'T178 Saunavuoro', 'reservation', 1, p_total - 4, p_total - 4, 25.5) returning id into it;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, parent_item_id)
  values (v, 'T178 Pyyhe', 'product', 1, 4, 4, 25.5, it);
  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  values (v, it, p_pid, p_space, 'exclusive', p_start, p_start + interval '2 hours', 2, 'confirmed');
  return v;
end $$;
create function pg_temp.info(p_token uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.anon(); r := booking.public_payment_link_info(p_token); perform pg_temp.logout(); return r; end $$;
create function pg_temp.mklink(p_admin uuid, p_order bigint) returns uuid language plpgsql as $$
declare r jsonb;
begin perform pg_temp.login(p_admin); r := booking.admin_create_payment_link(p_order, false, 14, 'T178 linkki'); perform pg_temp.logout();
  return (select link_token from booking.payments where id = coalesce((r ->> 'payment_id')::bigint, (r -> 'link' ->> 'payment_id')::bigint, (r ->> 'id')::bigint)); end $$;

create function pg_temp.svc() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"service_role"}', true); execute 'set local role service_role'; end $$;
create function pg_temp.prep(p_link uuid, p_order uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc(); r := booking.vismapay_payment_prepare(p_order, p_link); perform pg_temp.logout(); return r; end $$;
-- vismapay-start kirjaa onnistuneen auth_paymentin (CREATED + token + ohjausosoite)
create function pg_temp.created(p_onum text) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc();
  r := booking.vismapay_payment_event(p_onum, 'CREATED', 'https://www.vismapay.com/pbwapi/token/t178' || md5(p_onum), 't178' || md5(p_onum),
         jsonb_build_object('token_valid_until', (floor(extract(epoch from now())) + 3600)::bigint::text));
  perform pg_temp.logout(); return r; end $$;
create function pg_temp.apply(p_onum text, p_outcome text, p_amount numeric default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc(); r := booking.vismapay_payment_apply(p_onum, p_outcome, p_amount, jsonb_build_object('t178', true, 'visma_status', 14)); perform pg_temp.logout(); return r; end $$;
create function pg_temp.lookup(p_onum text) returns jsonb language plpgsql as $$
declare r jsonb;
begin perform pg_temp.svc(); r := booking.vismapay_payment_lookup(p_onum); perform pg_temp.logout(); return r; end $$;
create function pg_temp.audits(p_pay bigint, p_action text) returns int language sql as $$
  select count(*)::int from booking.audit_log where table_name = 'payments' and row_pk = p_pay::text and action = p_action $$;
create function pg_temp.paidn(p_order bigint) returns int language sql as $$
  select count(*)::int from booking.payments where order_id = p_order and status in ('paid', 'partially_refunded', 'refunded') $$;

do $t$
declare
  run text := lower(pg_temp.rnd('', 8));
  u_adm uuid := gen_random_uuid();
  cu bigint; pid bigint; sp bigint; o bigint; o2 bigint; o3 bigint; o4 bigint; o5 bigint; o6 bigint;
  tk uuid; tk2 uuid; tk3 uuid; tk4 uuid; tk5 uuid; tk6 uuid; otok uuid;
  pay bigint; pay2 bigint; pay3 bigint; pay6 bigint;
  a1 text; a2 text; a3 text; r jsonb; r2 jsonb; x jsonb; log text; np int; nf int; ns int; n int; prow booking.payments;
  v_start timestamptz := (date_trunc('day', now() at time zone 'Europe/Helsinki') + interval '41 days 15 hours') at time zone 'Europe/Helsinki';
  s_vp booking.integration_config; s_rl jsonb; v_has_rl boolean;
begin
  select * into s_vp from booking.integration_config where key = 'vismapay';
  select value, true into s_rl, v_has_rl from booking.settings where key = 'rl_order_get_per_10min';

  -- ===== A rakenne
  if to_regclass('booking.vismapay_attempts') is null or to_regprocedure('booking._vismapay_attempt_trg()') is null then
    raise exception 'TESTRESULT pass=0 fail=1 skip=0 F A1 booking_178 puuttuu (vismapay_attempts / _vismapay_attempt_trg)';
  end if;
  perform pg_temp.ck(md5(pg_get_functiondef('booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure)) in ('03fbbd2486b2c22dfa02d7ec84da626f', '2f8a7e56ae9bb4e29f4025f91e7ea706')
      and md5(pg_get_functiondef('booking.vismapay_payment_lookup(text)'::regprocedure)) = 'ddec24e2970bde7ff4dc6c6ecc3a63ac'
      and md5(pg_get_functiondef('booking.public_payment_link_info(uuid)'::regprocedure)) in ('647c556562046c75b7e7e33703c050a0', '1b729ef4d72dc925001169c38bad3315', '2c9e06b3153aa5c0edd25341024ae6a8')
      and md5(pg_get_functiondef('booking._vismapay_attempt_trg()'::regprocedure)) = '8553fa9e304740124b64dd361439820a', 'A1 muutetut funktiot = booking_178');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig = array['search_path=""']) from pg_proc where oid in ('booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure,
      'booking.vismapay_payment_lookup(text)'::regprocedure, 'booking.public_payment_link_info(uuid)'::regprocedure, 'booking._vismapay_attempt_trg()'::regprocedure)), 'A2 SECURITY DEFINER, search_path tyhjä');
  perform pg_temp.ck(has_function_privilege('service_role', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute')
      and not has_function_privilege('anon', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute')
      and not has_function_privilege('authenticated', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute')
      and has_function_privilege('service_role', 'booking.vismapay_payment_lookup(text)', 'execute')
      and not has_function_privilege('anon', 'booking.vismapay_payment_lookup(text)', 'execute')
      and has_function_privilege('anon', 'booking.public_payment_link_info(uuid)', 'execute')
      and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid in ('booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure,
            'booking.vismapay_payment_lookup(text)'::regprocedure, 'booking.public_payment_link_info(uuid)'::regprocedure, 'booking._vismapay_attempt_trg()'::regprocedure) and a.grantee = 0),
      'A3 oikeudet: apply/lookup vain service_role, link_info anon, ei PUBLIC');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.vismapay_payment_prepare(uuid,uuid)'::regprocedure)) in ('703c03c301f5a3008192cdbe65e559e2', 'cca997c4e900e78b8bb9e2e0c7da25d4', 'd1f8df803a45c2b77aa9f8554fc41890')
      and md5(pg_get_functiondef('booking.vismapay_payment_event(text,text,text,text,jsonb)'::regprocedure)) = 'e6834eb7c9da8a0a8c531706eb6692fc'
      and md5(pg_get_functiondef('booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure)) = '8ceb0a7dea60d37e3ea6a17cec0e4c25'
      and md5(pg_get_functiondef('booking.payment_mark_failed(text,text,text,jsonb)'::regprocedure)) = '2dfe2d2c0757157be90484d60cef8046'
      and md5(pg_get_functiondef('booking._create_link_payment(bigint,integer,text)'::regprocedure)) in ('533ac9af831c0c11e1f504e377a17827', '5e432077c560a10822db8ac0d2bbe7c2', 'f40db96ca201e40467f20cc1db5866c9', 'adc14e6983e60d80498508c9b969f60d')
      and md5(pg_get_functiondef('booking._order_balance(bigint)'::regprocedure)) = 'a6b31f93559de53d75a52d8a285f1170'
      and md5(pg_get_functiondef('booking.vismapay_order_refs(uuid)'::regprocedure)) = '79c7bbe4e02a4411d3ccdc821b662013', 'A4 riippuvuudet ennallaan');
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.vismapay_attempts'::regclass)
      and exists (select 1 from pg_trigger where tgrelid = 'booking.payments'::regclass and tgname = 'payments_vismapay_attempt' and not tgisinternal)
      and not has_table_privilege('anon', 'booking.vismapay_attempts', 'select'), 'A5 vismapay_attempts: RLS, trigger, ei anon-oikeutta');

  -- ===== fixture (feikki, vain tässä transaktiossa)
  insert into booking.integration_config(key, mode, settings) values ('vismapay', 'test', '{"approved_by":"t178"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t178"}'::jsonb;
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t178"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t178"}'::jsonb;
  if v_has_rl then update booking.settings set value = '500'::jsonb where key = 'rl_order_get_per_10min';
  else insert into booking.settings(key, value) values ('rl_order_get_per_10min', '500'::jsonb); end if;
  insert into auth.users(id, email) values (u_adm, 't178-admin-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't178-admin-' || run || '@example.test', 't178 admin', 'admin');
  insert into booking.customers(name, email, phone) values ('T178 Asiakas ' || run, 't178-' || run || '@example.test', '+358401780178') returning id into cu;
  insert into booking.resources(code, name, kind) values ('t178-' || run, 'T178 tila', 'space') returning id into sp;
  perform pg_temp.login(u_adm);
  r := booking.admin_product_create(jsonb_build_object('name', 'T178 Saunavuoro ' || run, 'price', 1, 'vat_rate', 25.5, 'active', false));
  pid := (r ->> 'id')::bigint;
  perform pg_temp.logout();
  o := pg_temp.mkorder(cu, pid, sp, 30, v_start);
  tk := pg_temp.mklink(u_adm, o);
  select id into pay from booking.payments where link_token = tk;
  perform pg_temp.ck(pid is not null and tk is not null and pay is not null, 'X0 fixture: tuote, tilaus, maksulinkki');

  -- ===== B peruutus → linkki yhä maksettavissa uudella yrityksellä
  r := pg_temp.prep(tk, null); a1 := r ->> 'order_number';
  perform pg_temp.ck(r ->> 'ok' = 'true' and a1 ~ '-a1$' and (r ->> 'reuse')::boolean = false, 'B1 ensimmäinen yritys -a1');
  perform pg_temp.created(a1);
  r := pg_temp.prep(tk, null);
  perform pg_temp.ck(r ->> 'order_number' = a1 and (r ->> 'reuse')::boolean, 'B2 voimassa oleva token käytetään uudelleen (ei rinnakkaista yritystä)');
  perform pg_temp.ck((select count(*) from booking.vismapay_attempts where payment_id = pay) = 1
      and (select superseded_at is null and outcome is null and attempt = 1 and env = 'test' from booking.vismapay_attempts where order_number = a1), 'B3 yritys kirjattu (vismapay_attempts)');
  r := pg_temp.apply(a1, 'cancelled');
  select * into prow from booking.payments where id = pay;
  perform pg_temp.ck(r ->> 'ok' = 'true' and r ->> 'outcome' = 'cancelled' and (r ->> 'retryable')::boolean, 'B4 peruutus → retryable');
  perform pg_temp.ck(prow.status = 'pending' and prow.provider_status = 'cancelled' and prow.provider_ref = a1 and not (prow.raw ? 'token') and not (prow.raw ? 'redirect_url')
      and not (prow.raw ? 'token_valid_until') and prow.link_url is null and prow.raw ->> 'last_state' = 'cancelled', 'B5 maksu pending, vanha token ja ohjausosoite poistettu');
  perform pg_temp.ck(pg_temp.audits(pay, 'VISMAPAY_CANCELLED_RETRYABLE') = 1 and pg_temp.audits(pay, 'VISMAPAY_CANCELLED') = 0
      and (select outcome from booking.vismapay_attempts where order_number = a1) = 'cancelled', 'B6 audit VISMAPAY_CANCELLED_RETRYABLE, yritys = cancelled');
  r := pg_temp.info(tk);
  perform pg_temp.ck(r ->> 'status' = 'open' and r ->> 'reason' = 'open' and (r ->> 'can_pay')::boolean and r ->> 'last_attempt' = 'cancelled' and (r ->> 'amount')::numeric = 30,
      'B7 link_info: open, last_attempt = cancelled');
  perform pg_temp.ck((select payment_status from booking.orders where id = o) = 'pending', 'B8 tilauksen maksutila pending (linkki auki)');
  r := pg_temp.apply(a1, 'cancelled');
  perform pg_temp.ck(r ->> 'outcome' = 'cancelled' and (r ->> 'unchanged')::boolean and pg_temp.audits(pay, 'VISMAPAY_CANCELLED_RETRYABLE') = 1, 'B9 toistuva peruutusilmoitus idempotentti');
  r := pg_temp.prep(tk, null); a2 := r ->> 'order_number';
  perform pg_temp.ck(r ->> 'ok' = 'true' and a2 ~ '-a2$' and a2 <> a1 and (r ->> 'reuse')::boolean = false and r ->> 'redirect_url' is null and (r ->> 'payment_id')::bigint = pay,
      'B10 uusi painallus → uusi yritys -a2 samalle maksulle (ei vanhaa tokenia)');
  perform pg_temp.ck((select superseded_at is not null from booking.vismapay_attempts where order_number = a1)
      and (select superseded_at is null and attempt = 2 from booking.vismapay_attempts where order_number = a2), 'B11 -a1 korvattu, -a2 nykyinen');
  perform pg_temp.created(a2);
  r := pg_temp.info(tk);
  perform pg_temp.ck(r ->> 'status' = 'open' and r -> 'last_attempt' = 'null'::jsonb, 'B12 uusi yritys käynnissä → last_attempt null');
  r := pg_temp.apply(a1, 'failed');
  select * into prow from booking.payments where id = pay;
  perform pg_temp.ck(r ->> 'outcome' = 'failed' and (r ->> 'unchanged')::boolean and (r ->> 'stale')::boolean and prow.provider_ref = a2 and prow.raw ->> 'last_state' = 'CREATED'
      and prow.raw ->> 'token' is not null, 'B13 vanhan yrityksen ilmoitus ei muuta nykyistä yritystä');
  r := pg_temp.apply(a2, 'failed');
  r2 := pg_temp.apply(a2, 'failed');
  select * into prow from booking.payments where id = pay;
  perform pg_temp.ck(r ->> 'outcome' = 'failed' and (r ->> 'retryable')::boolean and (r2 ->> 'unchanged')::boolean and prow.status = 'pending'
      and pg_temp.audits(pay, 'VISMAPAY_FAILED_RETRYABLE') = 1 and pg_temp.info(tk) ->> 'last_attempt' = 'failed', 'B14 hylätty kortti (failed) → yhä open, toisto idempotentti');
  r := pg_temp.prep(tk, null); a3 := r ->> 'order_number';
  perform pg_temp.ck(a3 ~ '-a3$' and (select count(*) from booking.vismapay_attempts where payment_id = pay) = 3, 'B15 kolmas yritys -a3');
  perform pg_temp.created(a3);
  r := pg_temp.apply(a3, 'paid', 30);
  perform pg_temp.ck(r ->> 'outcome' = 'paid' and (select status from booking.payments where id = pay) = 'paid' and pg_temp.paidn(o) = 1
      and pg_temp.info(tk) ->> 'reason' = 'link_paid', 'B16 uusi yritys maksettu → link_paid, yksi maksu');

  -- ===== C myöhästynyt maksu vanhalle yritykselle
  o2 := pg_temp.mkorder(cu, pid, sp, 40, v_start + interval '1 day');
  tk2 := pg_temp.mklink(u_adm, o2);
  select id into pay2 from booking.payments where link_token = tk2;
  a1 := pg_temp.prep(tk2, null) ->> 'order_number';
  perform pg_temp.created(a1);
  update booking.payments set raw = raw || jsonb_build_object('token_valid_until', (floor(extract(epoch from now())) - 60)::bigint::text) where id = pay2;   -- token vanheni
  a2 := pg_temp.prep(tk2, null) ->> 'order_number';
  perform pg_temp.created(a2);
  perform pg_temp.ck(a1 ~ '-a1$' and a2 ~ '-a2$' and (select provider_ref from booking.payments where id = pay2) = a2, 'C1 token vanheni → uusi yritys -a2');
  r := pg_temp.lookup(a1); r2 := pg_temp.lookup(a2);
  perform pg_temp.ck((r ->> 'found')::boolean and (r ->> 'payment_id')::bigint = pay2 and not (r ->> 'current')::boolean and r ->> 'env' = 'test'
      and (r2 ->> 'current')::boolean and (r2 ->> 'payment_id')::bigint = pay2, 'C2 lookup löytää vanhan ja nykyisen tilausnumeron');
  r := pg_temp.apply(a1, 'paid', 40);
  select * into prow from booking.payments where id = pay2;
  perform pg_temp.ck(r ->> 'outcome' = 'paid' and prow.status = 'paid' and prow.provider_ref = a1 and pg_temp.paidn(o2) = 1
      and (select sum(amount) from booking.payments where order_id = o2 and status = 'paid') = 40, 'C3 myöhästynyt maksu -a1 kirjattu kerran, provider_ref = -a1');
  perform pg_temp.ck((select outcome from booking.vismapay_attempts where order_number = a1) = 'paid'
      and (select superseded_at is not null from booking.vismapay_attempts where order_number = a2)
      and pg_temp.audits(pay2, 'VISMAPAY_LATE_PAID') = 1 and pg_temp.audits(pay2, 'VISMAPAY_PAID') = 1, 'C4 -a2 korvattu, audit VISMAPAY_LATE_PAID + VISMAPAY_PAID');
  r := pg_temp.apply(a1, 'paid', 40);
  perform pg_temp.ck((r ->> 'already')::boolean and r ->> 'outcome' = 'paid' and pg_temp.paidn(o2) = 1 and pg_temp.audits(pay2, 'VISMAPAY_PAID') = 1, 'C5 toisto idempotentti');
  r := pg_temp.apply(a2, 'paid', 40);
  r2 := pg_temp.apply(a2, 'paid', 40);
  perform pg_temp.ck(r ->> 'outcome' = 'needs_review' and r ->> 'code' = 'duplicate_paid' and r2 ->> 'code' = 'duplicate_paid' and pg_temp.paidn(o2) = 1
      and (select count(*) from booking.payments where order_id = o2) = 1 and (select provider_ref from booking.payments where id = pay2) = a1,
      'C6 toinen yritys maksettu → EI toista maksua (duplicate_paid)');
  perform pg_temp.ck(pg_temp.audits(pay2, 'VISMAPAY_DUPLICATE_PAID') = 1 and (select outcome from booking.vismapay_attempts where order_number = a2) = 'duplicate_paid'
      and (select internal_note from booking.orders where id = o2) like '%TUPLAVELOITUS%' || a2 || '%', 'C7 TUPLAVELOITUS-merkintä ja audit kerran');
  r := pg_temp.prep(tk2, null);
  perform pg_temp.ck(r ->> 'code' = 'already_paid' and pg_temp.info(tk2) ->> 'reason' = 'link_paid', 'C8 prepare → already_paid, link_paid');
  r := pg_temp.apply(a2, 'cancelled');
  perform pg_temp.ck((r ->> 'already')::boolean and (select status from booking.payments where id = pay2) = 'paid', 'C9 peruutus maksetulle → ennallaan');

  -- ===== D vanhentunut linkki + peruutus
  o3 := pg_temp.mkorder(cu, pid, sp, 30, v_start + interval '2 days');
  tk3 := pg_temp.mklink(u_adm, o3);
  select id into pay3 from booking.payments where link_token = tk3;
  a1 := pg_temp.prep(tk3, null) ->> 'order_number';
  perform pg_temp.created(a1);
  update booking.payments set created_at = now() - interval '15 days', link_expires_at = now() - interval '1 minute' where id = pay3;
  r := pg_temp.apply(a1, 'cancelled');
  perform pg_temp.ck(r ->> 'outcome' = 'cancelled' and (r ->> 'retryable')::boolean = false and r ->> 'reason' = 'link_expired'
      and (select status from booking.payments where id = pay3) = 'cancelled' and pg_temp.audits(pay3, 'VISMAPAY_CANCELLED') = 1, 'D1 vanhentunut linkki → peruutus kuluttaa (cancelled)');
  r := pg_temp.info(tk3);
  perform pg_temp.ck(r ->> 'status' = 'expired' and r ->> 'reason' = 'link_expired' and not (r ->> 'can_pay')::boolean and r -> 'last_attempt' = 'null'::jsonb, 'D2 link_info → expired/link_expired');
  r := pg_temp.prep(tk3, null);
  perform pg_temp.ck(r ->> 'code' = 'payment_not_pending', 'D3 prepare → payment_not_pending');

  -- ===== E korvattu linkki ja muuttunut summa
  o4 := pg_temp.mkorder(cu, pid, sp, 30, v_start + interval '3 days');
  tk4 := pg_temp.mklink(u_adm, o4);
  a1 := pg_temp.prep(tk4, null) ->> 'order_number';
  perform pg_temp.created(a1);
  perform pg_temp.login(u_adm);
  perform booking.admin_record_payment(o4, 'bank_transfer', 10, 'T178 osamaksu');
  perform pg_temp.logout();
  r := pg_temp.apply(a1, 'cancelled');
  perform pg_temp.ck((r ->> 'unchanged')::boolean and (select status from booking.payments where link_token = tk4) = 'cancelled', 'E1 korvattu linkki: myöhästynyt peruutus ei muuta');
  r := pg_temp.info(tk4);
  perform pg_temp.ck(r ->> 'status' = 'replaced' and r ->> 'reason' = 'replaced', 'E2 link_info → replaced');
  tk5 := pg_temp.mklink(u_adm, o4);
  perform pg_temp.ck(pg_temp.info(tk5) ->> 'status' = 'open' and (pg_temp.info(tk5) ->> 'amount')::numeric = 20, 'E3 uusi linkki open 20 €');
  a2 := pg_temp.prep(tk5, null) ->> 'order_number';
  perform pg_temp.created(a2);
  update booking.orders set total_gross = 25 where id = o4;   -- summa pieneni: linkki 20 € > maksamatta 15 €
  r := pg_temp.apply(a2, 'cancelled');
  perform pg_temp.ck(r ->> 'reason' = 'link_stale' and (select status from booking.payments where link_token = tk5) = 'cancelled'
      and pg_temp.info(tk5) ->> 'status' = 'replaced' and pg_temp.info(tk5) ->> 'reason' = 'link_stale', 'E4 summa muuttui → cancelled → replaced/link_stale');

  -- ===== F verkkokaupan tavallinen maksu ennallaan
  o6 := pg_temp.mkorder(cu, pid, sp, 30, v_start + interval '4 days');
  select public_token into otok from booking.orders where id = o6;
  r := pg_temp.prep(null, otok); a1 := r ->> 'order_number'; pay6 := (r ->> 'payment_id')::bigint;
  perform pg_temp.created(a1);
  r := pg_temp.apply(a1, 'cancelled');
  select * into prow from booking.payments where id = pay6;
  perform pg_temp.ck(r = '{"ok":true,"outcome":"cancelled"}'::jsonb and prow.status = 'cancelled' and prow.provider_status = 'cancelled'
      and pg_temp.audits(pay6, 'VISMAPAY_CANCELLED') = 1 and pg_temp.audits(pay6, 'VISMAPAY_CANCELLED_RETRYABLE') = 0, 'F1 tavallinen maksu: peruutus → cancelled kuten ennen');
  r := pg_temp.prep(null, otok);
  perform pg_temp.ck(r ->> 'ok' = 'true' and (r ->> 'payment_id')::bigint <> pay6 and r ->> 'order_number' ~ '-a1$', 'F2 uusi yritys = uusi maksurivi kuten ennen');

  -- ===== G SQLSTATE ja parametrit
  perform pg_temp.anon();
  x := pg_temp.call('booking.vismapay_payment_apply(''sauna-x'', ''paid'', 1, null)');
  perform pg_temp.ck(x ->> 'state' = '42501', 'G1 anon ei kutsu applya (42501)');
  x := pg_temp.call('booking.vismapay_payment_lookup(''sauna-x'')');
  perform pg_temp.ck(x ->> 'state' = '42501', 'G2 anon ei kutsu lookupia (42501)');
  x := pg_temp.call('(select to_jsonb(count(*)) from booking.vismapay_attempts)');
  perform pg_temp.ck(x ->> 'state' = '42501', 'G3 anon ei lue vismapay_attemptsia (42501)');
  x := pg_temp.call('booking.public_payment_link_info(''ei-uuid'')');
  perform pg_temp.ck(x ->> 'state' = '22P02', 'G4 virheellinen uuid → 22P02');
  perform pg_temp.logout();
  perform pg_temp.ck(pg_temp.apply('EI KELPAA', 'paid', 1) ->> 'code' = 'invalid_param' and pg_temp.apply('sauna-t178-' || run, 'paid', 1) ->> 'code' = 'not_found'
      and pg_temp.apply(a3, 'outoa') ->> 'code' = 'invalid_param' and (pg_temp.lookup('sauna-t178-' || run) ->> 'found')::boolean = false, 'G5 invalid_param / not_found');

  -- palautus (transaktio kumotaan joka tapauksessa)
  if s_vp.key is null then delete from booking.integration_config where key = 'vismapay'; else update booking.integration_config set mode = s_vp.mode, settings = s_vp.settings where key = 'vismapay'; end if;
  if v_has_rl then update booking.settings set value = s_rl where key = 'rl_order_get_per_10min'; else delete from booking.settings where key = 'rl_order_get_per_10min'; end if;

  log := current_setting('t178.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
select 't178 leftover rows = ' || ((select count(*) from booking.customers where email like 't178-%@example.test') + (select count(*) from auth.users where email like 't178-%@example.test')) as t178_check;
