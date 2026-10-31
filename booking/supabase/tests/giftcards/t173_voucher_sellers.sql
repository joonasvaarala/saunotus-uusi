-- t173: kumppanilahjakorttien myyjät (booking_173, versio 20261024231514): Kokemuskauppa / Offerilla / Elämyslahjat omina maksutapoinaan ja Procountor-tileinään,
-- tunnistus (^KK → Kokemuskauppa), Kiitoskauppa pois valinnoista (vanhat rivit toimivat), myyjän vaihto (asiakas + henkilökunta, audit),
-- hallinnan lunastusnäkymät (tilaus + Tarkista), lunastussivujen asetus ja idempotentti "merkitse lunastetuksi" (staff + tuleva botti).
-- TUOTANTOKELPOINEN: yksi transaktio (BEGIN … lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" + ROLLBACK), ei kiinteitä id-arvoja (RETURNING),
-- testikäyttäjät luodaan transaktion sisällä (auth.users + booking.staff, gen_random_uuid), ei psql-metakomentoja → toimii myös pelkällä SQL-työkalulla.
-- Apufunktiot pg_temp-skeemassa (ei public-skeemaa). Virheet tarkistetaan SQLSTATE / BK001-detail -koodeilla, ei virhetekstein. Ei sähköposteja (jono kumoutuu).
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t173_voucher_sellers.sql   (tai liitä koko tiedosto SQL-editoriin; tulos virheviestissä TESTRESULT …)
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t173.log', '', true);
-- uniikki keksitty IP (TEST-NET-3), jotta lahjakorttihaun IP-rajoitin ei osu muihin
select set_config('request.headers', json_build_object('x-forwarded-for', '203.0.113.' || (1 + floor(random() * 250))::int)::text, true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t173.log', coalesce(current_setting('t173.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
-- ajaa lausekkeen; palauttaa jsonb-tuloksen tai {"err": BK001-detail | SQLSTATE}
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; s text;
begin execute 'select (' || p_sql || ')::jsonb' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s end);
end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function pg_temp.svc() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"service_role"}', true); execute 'set local role service_role'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.rnd(p_prefix text, p_len int) returns text language sql volatile as $$
  select p_prefix || upper(substr(translate(md5(random()::text || clock_timestamp()::text), 'abcdef', 'ghjkmn'), 1, p_len)) $$;

do $t$
declare
  u_adm uuid := gen_random_uuid(); u_stf uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid();
  cu bigint; o1 bigint; o2 bigint; o3 bigint; t1 uuid; t2 uuid; t3 uuid; c1 bigint; c2 bigint; c3 bigint; cl bigint; pay bigint;
  k1 text := pg_temp.rnd('KK', 8); k2 text := pg_temp.rnd('ZQ', 8); k3 text := pg_temp.rnd('XW', 10); kl text := pg_temp.rnd('LG', 9);
  r jsonb; x jsonb; n int; n2 int; pm_old boolean; cfg0 booking.integration_config; cfg1 booking.integration_config; s0 jsonb; log text; np int; nf int;
begin
  select * into cfg0 from booking.integration_config where key = 'procountor';
  select value into s0 from booking.settings where key = 'voucher_claims.redeem_urls';
  insert into auth.users(id, email) values (u_adm, 't173-admin@example.test'), (u_stf, 't173-staff@example.test'), (u_rec, 't173-rec@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't173-admin@example.test', 't173 admin', 'admin'),
    (u_stf, 't173-staff@example.test', 't173 staff', 'staff');
  -- u_rec: kirjautunut käyttäjä, joka ei ole henkilökuntaa; u_stf: staff-rooli (giftcards.manage, ei settings.edit)

  -- ===== A rakenne, md5, oikeudet, siemendata
  perform pg_temp.ck(md5(pg_get_functiondef('booking._vc_guess(text)'::regprocedure)) = '3f33a0425eb0fa346ba617659b7b729d', 'A1 _vc_guess = booking_173');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._vc_sources()'::regprocedure)) = 'a1e85bd09bb916228984a4e667207bc5', 'A2 _vc_sources = booking_173');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_submit_voucher_claim(uuid,text,text,bigint)'::regprocedure)) in ('de84e5ce9b1062111c4248e7c582fdb8', 'd28a31d27147f4cf7bceb12150c9e77c'), 'A3 public_submit_voucher_claim = booking_173 (tai booking_176)');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_update_voucher_claim_code(uuid,bigint,text,text)'::regprocedure)) = '778fb281381aa026ed3e8afd49431ef6', 'A4 public_update_voucher_claim_code = booking_173');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._vc_pay(booking.orders,booking.voucher_claims,numeric)'::regprocedure)) = '3c24fd721b0e8bc6f1bdfb8a800c5a0e', 'A5 _vc_pay = booking_173');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._acct_excluded(bigint,bigint)'::regprocedure)) in ('4cbe97dbc038d5839453cf90f30525a5', '900fd3038c9285a84d82c25f67216f87'), 'A6 _acct_excluded = booking_173 (tai booking_223)');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.admin_set_procountor_settings(jsonb)'::regprocedure)) in ('0b67b832a42a1f85fca071a3dc4ac471', '1195e099ba7447d6eca60d3c0a2aa4d9'), 'A7 admin_set_procountor_settings = booking_173 tai booking_188');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._procountor_daily_build(date,jsonb,jsonb)'::regprocedure)) in ('f3e26f0ea30ab0e7a15f18c61aaf661e', '80215c7629cac9af3dcf212800335599'), 'A8 _procountor_daily_build = booking_173 (tai booking_223)');
  perform pg_temp.ck((select string_agg(code || '=' || label, ',' order by code) from booking.payment_methods where code like 'partner_voucher_%')
      = 'partner_voucher_elamyslahjat=Lahjakortti – Elämyslahjat,partner_voucher_kokemuskauppa=Lahjakortti – Kokemuskauppa,partner_voucher_offerilla=Lahjakortti – Offerilla', 'A9 kolme maksutapaa + nimet');
  perform pg_temp.ck(exists (select 1 from booking.payment_methods where code = 'partner_voucher'), 'A10 vanha partner_voucher säilyy (vanhat maksut, muu kumppani)');
  perform pg_temp.ck((select value ?& array['kokemuskauppa', 'offerilla', 'elamyslahjat'] and (value ->> 'kokemuskauppa') like 'https://%' from booking.settings where key = 'voucher_claims.redeem_urls'), 'A11 asetus voucher_claims.redeem_urls (3 https-osoitetta)');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_unredeemed_voucher_claims(text,integer)', 'execute') and not has_function_privilege('anon', 'booking.admin_order_voucher_claims(bigint)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute') and not has_function_privilege('anon', 'booking.admin_set_voucher_claim_source(bigint,text)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_set_voucher_redeem_urls(jsonb)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute'), 'A12 hallinnan RPC:t: ei anon, authenticated kyllä');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute') and not has_function_privilege('anon', 'booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute')
      and has_function_privilege('service_role', 'booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute'), 'A13 svc_mark_voucher_claim_redeemed vain service_role');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._vc_mark_redeemed(bigint,numeric,text,text,text)', 'execute') and not has_function_privilege('authenticated', 'booking._vc_mark_redeemed(bigint,numeric,text,text,text)', 'execute')
      and not has_function_privilege('authenticated', 'booking._vc_method(text)', 'execute'), 'A14 sisäiset apufunktiot eivät ole suoraan kutsuttavissa');

  -- ===== B tunnistus
  perform pg_temp.ck(booking._vc_guess('KK534536G5') = '{"source":"kokemuskauppa","confidence":"high"}'::jsonb, 'B1 KK534536G5 → Kokemuskauppa, high');
  perform pg_temp.ck(booking._vc_guess(booking.gift_code_norm('  kk-534 536g5 ')) ->> 'source' = 'kokemuskauppa', 'B2 pienet kirjaimet, välit ja viivat → Kokemuskauppa');
  perform pg_temp.ck(booking._vc_guess('KK12345ABCDEF') ->> 'source' = 'kokemuskauppa', 'B3 vanha KK-muoto edelleen Kokemuskauppa');
  perform pg_temp.ck(booking._vc_guess('OK19123ABC') = '{"source":"offerilla","confidence":"high"}'::jsonb, 'B4 OK-muoto → Offerilla, high');
  perform pg_temp.ck(booking._vc_guess('ZXQW98765432') ->> 'source' = 'elamyslahjat', 'B5 Elämyslahjat-muoto → Elämyslahjat');
  perform pg_temp.ck(booking._vc_guess('ABC123XYZ') = '{"source":"offerilla","confidence":"low"}'::jsonb, 'B6 muu → Offerilla ehdotuksena (low)');
  perform pg_temp.ck(booking._vc_guess('') ->> 'source' is null, 'B7 tyhjä → ei arvausta');
  perform pg_temp.ck((select array_agg(e ->> 'code' order by o) from jsonb_array_elements(booking._vc_sources()) with ordinality z(e, o)) = array['kokemuskauppa', 'offerilla', 'elamyslahjat'], 'B8 valinnat: Kokemuskauppa, Offerilla, Elämyslahjat (ei Kiitoskauppaa)');
  perform pg_temp.ck(booking._vc_method('kokemuskauppa') = 'partner_voucher_kokemuskauppa' and booking._vc_method('kiitoskauppa') = 'partner_voucher' and booking._vc_method('partner_other') = 'partner_voucher', 'B9 maksutapa myyjän mukaan; vanhat → partner_voucher');

  -- ===== C maksutapojen aktiivisuus seuraa partner_voucher-riviä (Asetukset > Maksutavat)
  select active into pm_old from booking.payment_methods where code = 'partner_voucher';
  update booking.payment_methods set active = not pm_old where code = 'partner_voucher';
  perform pg_temp.ck((select bool_and(active = not pm_old) from booking.payment_methods where code like 'partner_voucher_%'), 'C1 trigger: kolme maksutapaa seuraavat partner_voucher.active');
  update booking.payment_methods set active = pm_old where code = 'partner_voucher';

  -- ===== fixture (feikki)
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.enabled';
  update booking.settings set value = 'false'::jsonb where key = 'voucher_claims.partner_voucher_accounted';
  insert into booking.customers(name, email) values ('T173 Testi', 't173@example.test') returning id into cu;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale) values (cu, 'confirmed', 'unpaid', 50, 'admin', 'fi') returning id, public_token into o1, t1;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate) values (o1, 'T173 sauna', 'product', 1, 50, 50, 25.5);
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale) values (cu, 'confirmed', 'unpaid', 30, 'admin', 'en') returning id, public_token into o2, t2;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate) values (o2, 'T173 sauna 2', 'product', 1, 30, 30, 25.5);
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale) values (cu, 'confirmed', 'unpaid', 20, 'admin', 'fi') returning id, public_token into o3, t3;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate) values (o3, 'T173 sauna 3', 'product', 1, 20, 20, 25.5);

  -- ===== D asiakas (anon): lähetys ja myyjän vaihto ennen hyväksyntää
  perform pg_temp.anon();
  r := booking.public_resolve_gift_code(k1);
  perform pg_temp.ck(r ->> 'kind' = 'unknown' and r ->> 'suggested_source' = 'kokemuskauppa' and r ->> 'suggestion_confidence' = 'high' and not (r -> 'sources') @> '[{"code":"kiitoskauppa"}]'::jsonb, 'D1 KK-koodi: ehdotus Kokemuskauppa, valinnoissa ei Kiitoskauppaa');
  r := booking.public_submit_voucher_claim(t1, k1, 'kiitoskauppa');
  perform pg_temp.ck(r ->> 'ok' = 'false' and r ->> 'code' = 'invalid_source', 'D2 Kiitoskauppa ei enää kelpaa valinnaksi');
  r := booking.public_submit_voucher_claim(t1, k1, 'offerilla');
  c1 := (r ->> 'claim_no')::bigint;
  perform pg_temp.ck(r ->> 'ok' = 'true' and r ->> 'payment_method' = 'partner_voucher_offerilla' and r ->> 'payment_method_label' = 'Lahjakortti – Offerilla' and (r ->> 'source_mismatch')::boolean,
      'D3 asiakas valitsi väärin (Offerilla KK-koodille): maksutapa Offerilla + varoitus');
  r := booking.public_update_voucher_claim_code(t1, c1, '', 'kokemuskauppa');
  perform pg_temp.ck(r ->> 'ok' = 'true' and r ->> 'source' = 'kokemuskauppa' and r ->> 'payment_method_label' = 'Lahjakortti – Kokemuskauppa' and not coalesce((r ->> 'source_mismatch')::boolean, false),
      'D4 asiakas vaihtaa vain myyjän (koodi ennallaan) ennen hyväksyntää');
  r := booking.public_update_voucher_claim_code(t1, c1, '', 'kiitoskauppa');
  perform pg_temp.ck(r ->> 'ok' = 'false' and r ->> 'code' = 'invalid_source', 'D5 vaihto Kiitoskauppaan estetty');
  r := booking.public_submit_voucher_claim(t2, k2, 'elamyslahjat');
  c2 := (r ->> 'claim_no')::bigint;
  perform pg_temp.ck(r ->> 'ok' = 'true' and not (r ->> 'source_mismatch')::boolean and r ->> 'payment_method' = 'partner_voucher_elamyslahjat', 'D6 heikko Offerilla-ehdotus ei aiheuta varoitusta');
  r := booking.public_submit_voucher_claim(t3, k3, 'offerilla');
  c3 := (r ->> 'claim_no')::bigint;
  perform pg_temp.ck(r ->> 'ok' = 'true', 'D7 kolmas pyyntö (botti-polku)');
  perform pg_temp.logout();
  -- vanha Kiitoskauppa-rivi (ennen muutosta tehty)
  insert into booking.voucher_claims(order_id, code, source, source_suggested, customer_name, locale) values (o3, kl, 'kiitoskauppa', null, 'T173 Testi', 'fi') returning id into cl;
  perform pg_temp.anon();
  r := booking.public_update_voucher_claim_code(t3, cl, pg_temp.rnd('LH', 9), 'kiitoskauppa');
  perform pg_temp.ck(r ->> 'ok' = 'true' and r ->> 'source' = 'kiitoskauppa', 'D8 vanha Kiitoskauppa-rivi: koodin korjaus toimii, lähde säilyy');
  perform pg_temp.ck(pg_temp.call('booking.admin_order_voucher_claims(' || o1 || ')') ->> 'err' = '42501', 'D9 anon ei näe hallinnan lunastustietoja (42501)');
  perform pg_temp.logout();
  update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = 'staff' where id = cl;

  -- ===== E hallinta: tilauksen näkymä, myyjän vaihto, Tarkista-lista
  perform pg_temp.login(u_stf);
  r := booking.admin_order_voucher_claims(o1);
  x := r -> 'claims' -> 0;
  perform pg_temp.ck(jsonb_array_length(r -> 'claims') = 1 and x ->> 'code' = k1 and x ->> 'source' = 'kokemuskauppa' and x ->> 'source_suggested' = 'kokemuskauppa' and x ->> 'suggestion_confidence' = 'high'
      and x ->> 'payment_method_label' = 'Lahjakortti – Kokemuskauppa' and x ->> 'redeem_url' like 'https://%' and (x ->> 'unpaid')::numeric = 50 and (x ->> 'can_redeem')::boolean, 'E1 tilauksen näkymä: koko koodi, arvaus + valinta, maksutapa, lunastussivu, maksamaton');
  r := booking.admin_set_voucher_claim_source(c1, 'offerilla');
  perform pg_temp.ck(r ->> 'ok' = 'true' and r ->> 'payment_method' = 'partner_voucher_offerilla', 'E2 henkilökunta vaihtaa myyjän');
  perform pg_temp.ck(pg_temp.call('booking.admin_set_voucher_claim_source(' || c1 || ', ''offerilla'')') ->> 'err' = 'unchanged', 'E3 sama myyjä → unchanged');
  perform pg_temp.ck(pg_temp.call('booking.admin_set_voucher_claim_source(' || c1 || ', ''kiitoskauppa'')') ->> 'err' = 'invalid_source', 'E4 Kiitoskauppa → invalid_source');
  r := booking.admin_set_voucher_claim_source(c1, 'kokemuskauppa');
  perform pg_temp.logout();
  perform pg_temp.ck((select count(*) from booking.audit_log where table_name = 'booking.voucher_claims' and row_pk = c1::text and action = 'VOUCHER_SOURCE_CHANGE' and actor = u_stf) = 2
      and exists (select 1 from booking.audit_log where row_pk = c1::text and action = 'VOUCHER_SOURCE_CHANGE' and new_data ->> 'payment_method' = 'partner_voucher_kokemuskauppa'), 'E5 myyjän vaihto auditoitu (VOUCHER_SOURCE_CHANGE, uusi maksutapa)');
  perform pg_temp.login(u_rec);
  perform pg_temp.ck(pg_temp.call('booking.admin_set_voucher_claim_source(' || c1 || ', ''offerilla'')') ->> 'err' = 'forbidden', 'E6 muu kuin henkilökunta: myyjän vaihto → forbidden');
  perform pg_temp.ck(pg_temp.call('booking.admin_mark_voucher_claim_redeemed(' || c1 || ')') ->> 'err' = 'forbidden', 'E7 muu kuin henkilökunta: lunastus → forbidden');
  perform pg_temp.ck(pg_temp.call('booking.admin_unredeemed_voucher_claims(null, 10)') ->> 'err' = 'forbidden', 'E8 muu kuin henkilökunta: Tarkista-lista → forbidden');
  perform pg_temp.logout();
  perform pg_temp.login(u_stf);
  perform pg_temp.ck(pg_temp.call('booking.admin_set_voucher_redeem_urls(''{"offerilla":"https://example.test/"}''::jsonb)') ->> 'err' = 'forbidden', 'E9a lunastussivut ilman settings.edit → forbidden');
  r := booking.admin_unredeemed_voucher_claims(null, 500);
  perform pg_temp.ck((r ->> 'can_manage')::boolean and r -> 'claims' @> jsonb_build_array(jsonb_build_object('id', c1)) and r -> 'claims' @> jsonb_build_array(jsonb_build_object('id', c2))
      and not r -> 'claims' @> jsonb_build_array(jsonb_build_object('id', cl)), 'E9 Tarkista: lunastamattomat näkyvät (ei peruttuja), can_manage');
  r := booking.admin_unredeemed_voucher_claims('elamyslahjat', 500);
  perform pg_temp.ck((r ->> 'can_manage')::boolean and r -> 'claims' @> jsonb_build_array(jsonb_build_object('id', c2, 'source', 'elamyslahjat')) and not r -> 'claims' @> jsonb_build_array(jsonb_build_object('id', c1))
      and (r #>> '{counts,elamyslahjat}')::int >= 1 and r -> 'redeem_urls' ? 'elamyslahjat', 'E10 suodatus myyjällä + laskurit + osoitteet');
  perform pg_temp.ck(pg_temp.call('booking.admin_unredeemed_voucher_claims(''jotain'', 10)') ->> 'err' = 'invalid_source', 'E11 tuntematon myyjäsuodatin → invalid_source');

  -- ===== F merkitse lunastetuksi (staff), idempotentti; maksutapa = valittu myyjä
  r := booking.admin_mark_voucher_claim_redeemed(c1, null, 'T173-REF', null);
  select id into pay from booking.payments where order_id = o1 and status = 'paid' order by id desc limit 1;
  perform pg_temp.ck(r ->> 'ok' = 'true' and not (r ->> 'already')::boolean and r ->> 'redeemed_via' = 'staff' and r ->> 'payment_method' = 'partner_voucher_kokemuskauppa', 'F1 lunastus: ok, via staff');
  perform pg_temp.ck((select method = 'partner_voucher_kokemuskauppa' and amount = 50 and note like 'Lahjakortti – Kokemuskauppa%' from booking.payments where id = pay), 'F2 maksu Kokemuskauppa-maksutavalle, koko maksamaton');
  r := booking.admin_mark_voucher_claim_redeemed(c1, null, null, null);
  perform pg_temp.ck(r ->> 'ok' = 'true' and (r ->> 'already')::boolean and (select count(*) from booking.payments where order_id = o1) = 1, 'F3 toinen kutsu: already=true, ei toista maksua');
  perform pg_temp.ck(pg_temp.call('booking.admin_set_voucher_claim_source(' || c1 || ', ''offerilla'')') ->> 'err' = 'invalid_state', 'F4 lunastetun myyjää ei voi vaihtaa');
  perform pg_temp.ck(pg_temp.call('booking.admin_mark_voucher_claim_redeemed(-1)') ->> 'err' = 'not_found', 'F5 tuntematon id → not_found');
  r := booking.admin_order_voucher_claims(o1);
  perform pg_temp.ck(r #>> '{claims,0,status}' = 'redeemed' and r #>> '{claims,0,redeemed_via}' = 'staff' and not (r #>> '{claims,0,can_redeem}')::boolean, 'F6 tilauksen näkymä: lunastettu, via staff');
  r := booking.admin_unredeemed_voucher_claims(null, 500);
  perform pg_temp.ck(not r -> 'claims' @> jsonb_build_array(jsonb_build_object('id', c1)), 'F7 lunastettu poistuu Tarkista-listalta');
  perform pg_temp.logout();
  perform pg_temp.ck((select count(*) from booking.audit_log where row_pk = c1::text and action = 'VOUCHER_REDEEMED' and new_data ->> 'by' = 'staff') = 1, 'F8 audit VOUCHER_REDEEMED kerran');
  perform pg_temp.ck((select method_label = 'Lahjakortti – Kokemuskauppa' from (select e ->> 'method_label' method_label from jsonb_array_elements(booking.public_get_order(t1) -> 'payments') e) z limit 1), 'F9 asiakkaan tilaus näyttää maksutavan "Lahjakortti – Kokemuskauppa"');
  perform pg_temp.ck(booking._acct_excluded(o1, pay), 'F10 partner_voucher_accounted=false → myyjän maksu ei kirjanpitoon (kuten ennen)');
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.partner_voucher_accounted';
  perform pg_temp.ck(not booking._acct_excluded(o1, pay), 'F11 partner_voucher_accounted=true → mukaan kirjanpitoon');
  update booking.settings set value = 'false'::jsonb where key = 'voucher_claims.partner_voucher_accounted';

  -- ===== G tuleva botti (service_role)
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(c3, null, 'BOT-1', 'botti');
  perform pg_temp.ck(r ->> 'ok' = 'true' and r ->> 'redeemed_via' = 'bot' and r ->> 'payment_method' = 'partner_voucher_offerilla', 'G1 botti merkitsee lunastetuksi (via bot, Offerilla)');
  r := booking.svc_mark_voucher_claim_redeemed(c3, null, null, null);
  perform pg_temp.ck((r ->> 'already')::boolean, 'G2 botti: idempotentti');
  perform pg_temp.logout();
  perform pg_temp.ck((select resolved_by = 'bot' and resolved_at is not null and status = 'redeemed' from booking.voucher_claims where id = c3), 'G3 lunastustapa = resolved_by bot, aika resolved_at');
  perform pg_temp.login(u_adm);
  perform pg_temp.ck(pg_temp.call('booking.svc_mark_voucher_claim_redeemed(' || c2 || ')') ->> 'err' = '42501', 'G4 henkilökunta ei voi kutsua botin RPC:tä (42501)');
  perform pg_temp.logout();

  -- ===== H lunastussivujen asetus
  perform pg_temp.login(u_adm);
  perform pg_temp.ck(pg_temp.call('booking.admin_set_voucher_redeem_urls(''{"offerilla":"http://example.test/"}''::jsonb)') ->> 'err' = 'invalid_url', 'H1 http:// hylätään');
  perform pg_temp.ck(pg_temp.call('booking.admin_set_voucher_redeem_urls(''{"offerilla":"https://example.test/<x>"}''::jsonb)') ->> 'err' = 'invalid_url', 'H2 < hylätään');
  perform pg_temp.ck(pg_temp.call('booking.admin_set_voucher_redeem_urls(''{"kiitoskauppa":"https://example.test/"}''::jsonb)') ->> 'err' = 'invalid_setting', 'H3 tuntematon myyjä hylätään');
  r := booking.admin_set_voucher_redeem_urls('{"offerilla":"https://example.test/t173/"}'::jsonb);
  perform pg_temp.ck(r #>> '{redeem_urls,offerilla}' = 'https://example.test/t173/' and r #>> '{redeem_urls,kokemuskauppa}' = s0 ->> 'kokemuskauppa', 'H4 tallennus: muutettu avain vaihtuu, muut säilyvät');
  perform pg_temp.ck(booking.admin_order_voucher_claims(o3) #>> '{claims,0,redeem_url}' = 'https://example.test/t173/', 'H5 Lunasta-linkki tulee asetuksesta');

  -- ===== I Procountor: kolme tiliä, vanha avain kelpaa, varatili partner_voucher
  r := booking.admin_set_procountor_settings(jsonb_build_object('mode', cfg0.mode, 'accounts', jsonb_build_object('clearing_by_method',
         jsonb_build_object('partner_voucher', '1771', 'partner_voucher_kokemuskauppa', '1772', 'partner_voucher_offerilla', '1773', 'partner_voucher_elamyslahjat', '1774'))));
  perform pg_temp.logout();
  select * into cfg1 from booking.integration_config where key = 'procountor';
  perform pg_temp.ck(cfg1.settings #>> '{accounts,clearing_by_method,partner_voucher_kokemuskauppa}' = '1772' and cfg1.settings #>> '{accounts,clearing_by_method,partner_voucher}' = '1771'
      and cfg1.settings #>> '{accounts,clearing_by_method,partner_voucher_elamyslahjat}' = '1774', 'I1 tilit tallentuvat myyjittäin, vanha avain säilyy');
  perform pg_temp.ck(cfg1.mode = cfg0.mode and coalesce(cfg1.settings ->> 'daily_enabled', 'false') = coalesce(cfg0.settings ->> 'daily_enabled', 'false'), 'I2 tila ja daily_enabled ennallaan');
  perform pg_temp.login(u_adm);
  perform pg_temp.ck(pg_temp.call('booking.admin_set_procountor_settings(''{"accounts":{"clearing_by_method":{"partner_voucher_kiitoskauppa":"1"}}}''::jsonb)') ->> 'err' = 'invalid_setting', 'I3 tuntematon maksutapa hylätään');
  perform pg_temp.logout();
  x := '{"totals":{"receipts":1},"by_method":[{"method":"partner_voucher_offerilla","gross":10}],"vat":[]}'::jsonb;
  r := booking._procountor_daily_build(current_date, x, '{"accounts":{"clearing_by_method":{"partner_voucher":"1771"}}}'::jsonb);
  perform pg_temp.ck(not (r -> 'missing') ? 'clearing:partner_voucher_offerilla', 'I4 myyjän tili puuttuu → käytetään partner_voucher-tiliä');
  r := booking._procountor_daily_build(current_date, x, '{"accounts":{"clearing_by_method":{}}}'::jsonb);
  perform pg_temp.ck((r -> 'missing') ? 'clearing:partner_voucher_offerilla', 'I5 kumpikaan ei asetettu → puuttuu');

  log := current_setting('t173.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
