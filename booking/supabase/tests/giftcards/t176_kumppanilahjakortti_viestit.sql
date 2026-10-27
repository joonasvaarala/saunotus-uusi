-- t176: booking_176 kumppanilahjakorttivarauksen asiakasviestit yhteen (hyväksytty malli, omistaja Joonas 25.10.2026).
--   A) rakenne: korvattujen funktioiden md5 = booking_176, uudet sisäiset funktiot ja taulu eivät näy anon/authenticated-rooleille.
--   B) kohta 1: varaus + lahjakoodi (public_submit_voucher_claim) → yksi varausvahvistus (voucher_claim_received); ei tilausvahvistusta (order_confirmation),
--      ei ajastettua ohjeviestiä (product_message / instruction → skipped 'partner_voucher'); toinen koodi samalle tilaukselle ei lähetä uutta vahvistusta;
--      jo jonossa oleva lähettämätön tilausvahvistus ohitetaan; email_outbox_claim antaa vahvistukselle lyhyet ohjeet (order.instructions).
--      Ensimmäinen pyyntö peruttu ennen lähetystä, toinen voimassa → sama vahvistus lähtee voimassa olevan pyynnön tiedoilla (tasan yksi); kaikki peruttu → send-emails ohittaa;
--      ohitetun jälkeen uusi koodi → tasan yksi uusi vahvistus.
--   C) kohta 6: tavallinen varaus saa edelleen tilausvahvistuksen + ohjeviestin, korttimaksu kuitin + kuittisähköpostin, maksulinkki sähköpostin.
--   D) kohta 2: lahjakortti kattaa koko summan → lunastuksesta ei yhtään viestiä.
--   E) kohta 3: lahjakortti kattaa osan → yksi viesti (payment_link / voucher_difference), henkilökunta ja botti (svc_mark_voucher_claim_redeemed)
--      sekä vanha polku (admin_resolve_voucher_claim / svc_resolve_voucher_claim tila 'redeemed') samalla tavalla.
--   F) kohta 4: erotus maksettu → kuitti syntyy ja näkyy tilaussivulla (public_get_order.receipts), ei kuittisähköpostia; myös korvaava linkki (uusi payments.id).
--   G) kohta 5: lunastus epäonnistuu → ei viestiä, vaikka voucher_claims.problem_emails_enabled = true.
--   H) virheet SQLSTATE-koodeilla.
-- TUOTANTOKELPOINEN: yksi transaktio (BEGIN … lopussa tahallinen poikkeus "TESTRESULT pass=… fail=… skip=…" + ROLLBACK), ei kiinteitä id-arvoja (RETURNING),
-- testikäyttäjät luodaan transaktion sisällä (auth.users + booking.staff, gen_random_uuid), ei psql-metakomentoja → toimii myös pelkällä SQL-työkalulla.
-- Asetukset muutetaan vain transaktion sisällä. Apufunktiot pg_temp-skeemassa (ei public-skeemaa). Ei sähköposteja (jono kumoutuu).
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t176_kumppanilahjakortti_viestit.sql   (tai liitä koko tiedosto SQL-editoriin; tulos virheviestissä TESTRESULT …)
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t176.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t176.log', coalesce(current_setting('t176.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.skip(p_label text) returns void language sql as $$
  select set_config('t176.log', coalesce(current_setting('t176.log', true), '') || 'S ' || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; s text;
begin execute 'select (' || p_sql || ')::jsonb' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate; return jsonb_build_object('state', s, 'err', case when s = 'BK001' then d else s end);
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
-- odottava varaus (pitoaika voimassa) tuotteelle; palauttaa tilauksen id:n. Luotu 10 min sitten → ajastettu ohjeviesti (1 min varauksesta) on erääntynyt.
create function pg_temp.mkpending(p_cu bigint, p_pid bigint, p_space bigint, p_total numeric, p_locale text, p_days int) returns bigint language plpgsql as $$
declare v bigint; it bigint;
begin
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_at)
  values (p_cu, 'pending', 'unpaid', p_total, 'web', p_locale, now() - interval '10 minutes') returning id into v;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v, p_pid, 'T176 sauna', 'reservation', 1, p_total, p_total, 25.5) returning id into it;
  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, status, hold_expires_at)
  values (v, it, p_pid, p_space, 'exclusive', date_trunc('hour', now()) + make_interval(days => p_days), date_trunc('hour', now()) + make_interval(days => p_days, hours => 2), 2, 'pending', now() + interval '20 minutes');
  return v;
end $$;
-- yksittäisen jonorivin email_outbox_claim (send-emailsin näkymä). null = jonossa muiden asiakkaiden lähetettäviä viestejä (ei kosketa) → testi ohitetaan.
create function pg_temp.claim1(p_id bigint, p_cu bigint) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  if exists (select 1 from booking.email_outbox e where e.status in ('pending', 'failed') and e.next_attempt_at <= now()
               and not exists (select 1 from booking.orders t where t.id = e.order_id and t.customer_id = p_cu)) then return null; end if;
  update booking.email_outbox set status = 'skipped' where status in ('pending', 'failed') and order_id in (select id from booking.orders where customer_id = p_cu) and id <> p_id;
  update booking.email_outbox set status = 'pending', next_attempt_at = now() - interval '1 second' where id = p_id;
  r := booking.email_outbox_claim(50);
  return (select e from jsonb_array_elements(r) e where (e ->> 'id')::bigint = p_id);
end $$;
create function pg_temp.mails(p_order bigint) returns int language sql as $$ select count(*)::int from booking.email_outbox where order_id = p_order $$;
create function pg_temp.mails(p_order bigint, p_kind text) returns int language sql as $$ select count(*)::int from booking.email_outbox where order_id = p_order and kind = p_kind $$;

do $t$
declare
  run text := lower(pg_temp.rnd('', 8));
  u_adm uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid();
  cu bigint; pid bigint; sp bigint; mid bigint; o bigint; o2 bigint; o3 bigint; tok uuid; c bigint; c2 bigint; c3 bigint; cb1 bigint; cb2 bigint; pay bigint; lnk bigint; lnk2 bigint; rc bigint; em bigint; n0 int; n int;
  r jsonb; x jsonb; ob booking.orders; vc booking.voucher_claims;
  s_en jsonb; s_pe jsonb; s_acc jsonb; s_mt jsonb; log text; np int; nf int; ns int;
begin
  select value into s_en from booking.settings where key = 'voucher_claims.enabled';
  select value into s_pe from booking.settings where key = 'voucher_claims.problem_emails_enabled';
  select value into s_acc from booking.settings where key = 'voucher_claims.partner_voucher_accounted';
  select value into s_mt from booking.settings where key = 'messages.timed_enabled';

  -- ===== A rakenne
  perform pg_temp.ck(md5(pg_get_functiondef('booking._on_payment_paid(bigint)'::regprocedure)) = 'af7f99e87ba7e00e0d5e3d5b6cbf2400', 'A1 _on_payment_paid = booking_176');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure)) = '70602f6500703e8750e1539ae8809d38', 'A2 email_outbox_claim = booking_176');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.orders_confirmed_mail_trg()'::regprocedure)) = 'de9df39ff7972a951e61684f8f2db87b', 'A3 orders_confirmed_mail_trg = booking_176');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_submit_voucher_claim(uuid,text,text,bigint)'::regprocedure)) in ('d28a31d27147f4cf7bceb12150c9e77c', 'ae9e0fc42301619305a513c557199845'), 'A4 public_submit_voucher_claim = booking_176 (tai booking_185)');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.messages_dispatch(integer)'::regprocedure)) = '4b1f94601e23d9dc3eec34bcd5b4dc08', 'A5 messages_dispatch = booking_176');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._vc_notify_problem(bigint)'::regprocedure)) = '3414022269f6db113f1085208eb6f040', 'A6 _vc_notify_problem = booking_176');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure)) = 'a4e69cb26eb44b72eacce7c167342884', 'A7 admin_mark_voucher_claim_redeemed = booking_176');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure)) = '673f26a88054b2b31dcbab872557e383', 'A8 svc_mark_voucher_claim_redeemed = booking_176');
  if to_regprocedure('booking._vc_redeem(bigint,numeric,text,text,text)') is null or to_regprocedure('booking._vc_partner_order(bigint)') is null or to_regclass('booking.vc_difference_payments') is null then
    raise exception 'TESTRESULT pass=0 fail=1 skip=0 F A9 booking_176 puuttuu (_vc_redeem / _vc_partner_order / vc_difference_payments)';
  end if;
  perform pg_temp.ck(md5(pg_get_functiondef('booking._vc_redeem(bigint,numeric,text,text,text)'::regprocedure)) in ('6f52789346960d95370169446a61451b', '2aa8e44cb2c6f150d3488f53f8d94c25', '6576dc3dda048de2a438f1cdf333b0d9')
      and md5(pg_get_functiondef('booking._vc_partner_order(bigint)'::regprocedure)) = '9221478413d1e3869021d9e20c20e567', 'A9 _vc_redeem + _vc_partner_order = booking_176');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._vc_redeem(bigint,numeric,text,text,text)', 'execute')
      and not has_function_privilege('authenticated', 'booking._vc_redeem(bigint,numeric,text,text,text)', 'execute')
      and not has_function_privilege('anon', 'booking._vc_partner_order(bigint)', 'execute')
      and not has_function_privilege('authenticated', 'booking._vc_partner_order(bigint)', 'execute'), 'A10 uudet funktiot sisäisiä (ei anon/authenticated)');
  perform pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute')
      and has_function_privilege('service_role', 'booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute')
      and not has_function_privilege('authenticated', 'booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)', 'execute'), 'A11 lunastusfunktioiden oikeudet ennallaan');
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.vc_difference_payments'::regclass)
      and not has_table_privilege('anon', 'booking.vc_difference_payments', 'select') and not has_table_privilege('authenticated', 'booking.vc_difference_payments', 'select'), 'A12 vc_difference_payments: RLS, ei anon/authenticated');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.admin_resolve_voucher_claim(bigint,text,text,text,numeric,text)'::regprocedure)) = '41a4f3cc89e802f18e5131f849394188'
      and md5(pg_get_functiondef('booking.svc_resolve_voucher_claim(bigint,text,text,text,numeric,text)'::regprocedure)) = 'cc67ebd8ce012211eb603b7f2b1c3ef4', 'A13 admin_/svc_resolve_voucher_claim = booking_176');
  perform pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_resolve_voucher_claim(bigint,text,text,text,numeric,text)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_resolve_voucher_claim(bigint,text,text,text,numeric,text)', 'execute')
      and has_function_privilege('service_role', 'booking.svc_resolve_voucher_claim(bigint,text,text,text,numeric,text)', 'execute')
      and not has_function_privilege('authenticated', 'booking.svc_resolve_voucher_claim(bigint,text,text,text,numeric,text)', 'execute'), 'A14 resolve-funktioiden oikeudet ennallaan');

  -- ===== fixture (feikki, vain tässä transaktiossa)
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.enabled';
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.partner_voucher_accounted';
  update booking.settings set value = 'true'::jsonb where key = 'messages.timed_enabled';
  insert into auth.users(id, email) values (u_adm, 't176-admin-' || run || '@example.test'), (u_rec, 't176-rec-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't176-admin-' || run || '@example.test', 't176 admin', 'admin');
  insert into booking.customers(name, email) values ('T176 Testi', 't176-' || run || '@example.test') returning id into cu;
  insert into booking.resources(code, name, kind) values ('t176-' || run, 'T176 tila', 'space') returning id into sp;
  perform pg_temp.login(u_adm);
  r := booking.admin_product_create(jsonb_build_object('name', 'T176 sauna ' || run, 'price', 1, 'vat_rate', 25.5, 'active', false));
  pid := (r ->> 'id')::bigint;
  r := booking.admin_save_message(null, jsonb_build_object('name', 'T176 ohje ' || run, 'category', 'instruction', 'active', true, 'delivery_mode', 'scheduled',
      'subject_fi', 'T176 ohje', 'body_fi', 'T176 koko ohje', 'short_fi', 'T176 lyhyt ohje', 'subject_en', 'T176 guide', 'body_en', 'T176 full guide', 'short_en', 'T176 short guide',
      'send_amount', 1, 'send_unit', 'minutes', 'send_direction', 'after', 'send_anchor', 'booking', 'product_ids', jsonb_build_array(pid)));
  mid := (r ->> 'id')::bigint;
  perform pg_temp.logout();
  perform pg_temp.ck(pid is not null and mid is not null and sp is not null, 'X0 fixture: tuote, ajastettu ohjeviesti, tila');

  -- ===== B kohta 1: varaus + lahjakoodi → yksi varausvahvistus
  o := pg_temp.mkpending(cu, pid, sp, 60, 'fi', 41);
  select public_token into tok from booking.orders where id = o;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('KK', 8), 'kokemuskauppa');
  perform pg_temp.logout();
  c := (r ->> 'claim_no')::bigint;
  perform pg_temp.ck(r ->> 'ok' = 'true' and (select status from booking.orders where id = o) = 'confirmed', 'B1 lahjakoodi: ok, varaus vahvistettu');
  perform pg_temp.ck(pg_temp.mails(o, 'voucher_claim_received') = 1 and pg_temp.mails(o) = 1, 'B2 tasan yksi viesti: voucher_claim_received');
  perform pg_temp.ck(pg_temp.mails(o, 'order_confirmation') = 0, 'B3 ei erillistä tilausvahvistusta');
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('KK', 8), 'kokemuskauppa');
  perform pg_temp.logout();
  c2 := (r ->> 'claim_no')::bigint;
  perform pg_temp.ck(r ->> 'ok' = 'true' and c2 <> c and pg_temp.mails(o) = 1, 'B4 toinen koodi samalle tilaukselle: ei uutta vahvistusta');
  update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = 'staff' where id = c2;
  perform booking.messages_dispatch(200);
  perform pg_temp.ck(exists (select 1 from booking.email_outbox where dedupe_key = 'product_message:' || mid || ':' || o and status = 'skipped' and last_error = 'partner_voucher')
      and pg_temp.mails(o) = 2 and not exists (select 1 from booking.email_outbox where order_id = o and kind = 'product_message' and status <> 'skipped'), 'B5 ajastettu ohjeviesti ohitettu (partner_voucher)');
  -- vahvistuksen lyhyet ohjeet email_outbox_claimista (vain jos jonossa ei ole muita lähetettäviä viestejä)
  select to_jsonb(e) into x from booking.email_outbox e where e.order_id = o and e.kind = 'voucher_claim_received';
  if not exists (select 1 from booking.email_outbox e where e.status in ('pending', 'failed') and e.next_attempt_at <= now()
                   and not exists (select 1 from booking.orders t where t.id = e.order_id and t.customer_id = cu)) then
    update booking.email_outbox set status = 'skipped' where status in ('pending', 'failed') and order_id in (select id from booking.orders where customer_id = cu) and id <> (x ->> 'id')::bigint;
    update booking.email_outbox set status = 'pending', next_attempt_at = now() - interval '1 second' where id = (x ->> 'id')::bigint;
    r := booking.email_outbox_claim(50);
    r := (select e from jsonb_array_elements(r) e where (e ->> 'id')::bigint = (x ->> 'id')::bigint);
    perform pg_temp.ck(r #>> '{order,instructions,0,text}' = 'T176 lyhyt ohje' and r #>> '{order,order_url}' like '%?t=' || tok and r #>> '{voucher_claim,claim_id}' = c::text,
        'B6 email_outbox_claim: vahvistuksessa lyhyt ohje + tilauslinkki + pyyntö');
  else
    perform pg_temp.skip('B6 email_outbox_claim ohitettu: jonossa muita lähetettäviä viestejä');
  end if;
  -- tilaus vahvistui juuri ennen koodia (tilausvahvistus vielä lähettämättä) → tilausvahvistus ohitetaan, varausvahvistus jonoon
  o2 := pg_temp.mkpending(cu, pid, sp, 30, 'en', 43);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o2;
  update booking.orders set status = 'confirmed', confirmed_at = now() where id = o2;
  perform pg_temp.ck(pg_temp.mails(o2, 'order_confirmation') = 1, 'B7 vahvistus ilman koodia: tilausvahvistus jonossa');
  select public_token into tok from booking.orders where id = o2;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('ZQ', 8), 'elamyslahjat');
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and (select status = 'skipped' and last_error like 'booking_176:%' from booking.email_outbox where dedupe_key = 'order_confirmation:' || o2)
      and pg_temp.mails(o2, 'voucher_claim_received') = 1, 'B8 lähettämätön tilausvahvistus ohitettu, varausvahvistus jonossa');
  -- ensimmäinen pyyntö perutaan ennen lähetystä, toinen voimassa → sama vahvistus lähtee toisen pyynnön tiedoilla (tasan yksi)
  o3 := pg_temp.mkpending(cu, pid, sp, 55, 'fi', 44);
  select public_token into tok from booking.orders where id = o3;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('KK', 8), 'kokemuskauppa');
  cb1 := (r ->> 'claim_no')::bigint;
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('KK', 8), 'kokemuskauppa');
  cb2 := (r ->> 'claim_no')::bigint;
  perform pg_temp.logout();
  perform pg_temp.login(u_adm);
  r := booking.admin_resolve_voucher_claim(cb1, 'cancelled', null, 't176 peruttu', null, null);
  perform pg_temp.logout();
  select id into em from booking.email_outbox where order_id = o3 and kind = 'voucher_claim_received';
  perform pg_temp.ck(cb2 <> cb1 and (select status from booking.voucher_claims where id = cb1) = 'cancelled' and pg_temp.mails(o3, 'voucher_claim_received') = 1
      and (select payload ->> 'claim_id' from booking.email_outbox where id = em) = cb1::text, 'B9 kaksi koodia, ensimmäinen peruttu: yksi vahvistus jonossa (ensimmäisen pyynnön)');
  x := pg_temp.claim1(em, cu);
  if x is null then
    perform pg_temp.skip('B10 email_outbox_claim ohitettu: jonossa muita lähetettäviä viestejä');
    perform pg_temp.skip('B11 email_outbox_claim ohitettu');
  else
    perform pg_temp.ck(x #>> '{voucher_claim,claim_id}' = cb2::text and x #>> '{voucher_claim,status}' = 'open' and x #>> '{order,instructions,0,text}' = 'T176 lyhyt ohje',
        'B10 vahvistus lähtee voimassa olevan pyynnön tiedoilla (send-emails ei ohita)');
    perform pg_temp.login(u_adm);
    r := booking.admin_resolve_voucher_claim(cb2, 'cancelled', null, 't176 peruttu', null, null);
    perform pg_temp.logout();
    x := pg_temp.claim1(em, cu);
    perform pg_temp.ck(x is not null and x #>> '{voucher_claim,claim_id}' = cb1::text and x #>> '{voucher_claim,status}' = 'cancelled', 'B11 kaikki pyynnöt peruttu: pyyntö peruttu (send-emails ohittaa)');
  end if;
  -- send-emails ohitti (kaikki peruttu) → uusi koodi: tasan yksi uusi vahvistus
  update booking.email_outbox set status = 'skipped', last_error = 'pyyntö peruttu/vanhentunut' where id = em;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('KK', 8), 'kokemuskauppa');
  c3 := (r ->> 'claim_no')::bigint;
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('KK', 8), 'kokemuskauppa');
  perform pg_temp.logout();
  perform pg_temp.ck(c3 is not null and pg_temp.mails(o3, 'voucher_claim_received') = 2
      and (select count(*) from booking.email_outbox where order_id = o3 and kind = 'voucher_claim_received' and status <> 'skipped') = 1
      and exists (select 1 from booking.email_outbox where order_id = o3 and kind = 'voucher_claim_received' and status = 'pending' and dedupe_key = 'vcrecv:' || c3),
      'B12 ohitetun jälkeen uusi koodi (+ vielä yksi): tasan yksi uusi vahvistus');

  -- ===== C kohta 6: tavallinen varaus ennallaan
  o2 := pg_temp.mkpending(cu, pid, sp, 50, 'fi', 45);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o2;
  update booking.orders set status = 'confirmed', confirmed_at = now() where id = o2;
  perform pg_temp.ck(pg_temp.mails(o2, 'order_confirmation') = 1 and (select status <> 'skipped' or last_error is null from booking.email_outbox where dedupe_key = 'order_confirmation:' || o2)
      and pg_temp.mails(o2) = 1, 'C1 tavallinen varaus: tilausvahvistus jonossa (ainoa viesti)');
  perform booking.messages_dispatch(200);
  perform pg_temp.ck(exists (select 1 from booking.email_outbox where dedupe_key = 'product_message:' || mid || ':' || o2 and last_error is distinct from 'partner_voucher'), 'C2 tavallinen varaus: ohjeviesti jonossa kuten ennen');
  perform pg_temp.login(u_adm);
  r := booking.admin_record_payment(o2, 'card_terminal', 20, 't176 kortti', null);
  r := booking.admin_create_payment_link(o2, true, 14, 't176 linkki');
  perform pg_temp.logout();
  select id into rc from booking.receipts where order_id = o2 and kind = 'receipt';
  perform pg_temp.ck(rc is not null and exists (select 1 from booking.email_outbox where kind = 'receipt' and receipt_id = rc and dedupe_key = 'receipt:' || rc), 'C3 korttimaksu: kuitti + kuittisähköposti kuten ennen');
  perform pg_temp.ck(pg_temp.mails(o2, 'payment_link') = 1 and pg_temp.mails(o2) = 4, 'C4 maksulinkki sähköpostina kuten ennen (4 viestiä yhteensä)');

  -- ===== D kohta 2: koko summa lahjakortilla → ei viestiä lunastuksesta
  select order_id into o from booking.voucher_claims where id = c;
  n0 := pg_temp.mails(o);
  perform pg_temp.login(u_adm);
  r := booking.admin_mark_voucher_claim_redeemed(c, 60, 'T176-FULL', null);
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and (r ->> 'amount')::numeric = 60 and r -> 'payment_link' = 'null'::jsonb and ((booking._order_balance(o)) ->> 'unpaid')::numeric = 0, 'D1 koko summa: lunastettu, ei linkkiä, maksettu');
  perform pg_temp.ck(pg_temp.mails(o) = n0, 'D2 koko summa: ei yhtään uutta viestiä');

  -- ===== E kohta 3: osa summasta → yksi yhdistetty viesti (henkilökunta)
  o := pg_temp.mkpending(cu, pid, sp, 80, 'en', 47);
  select public_token into tok from booking.orders where id = o;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('XW', 10), 'offerilla');
  perform pg_temp.logout();
  c := (r ->> 'claim_no')::bigint;
  n0 := pg_temp.mails(o);
  perform pg_temp.login(u_adm);
  r := booking.admin_mark_voucher_claim_redeemed(c, 50, 'T176-PART', null);
  perform pg_temp.logout();
  lnk := (r #>> '{payment_link,payment_id}')::bigint;
  perform pg_temp.ck(r ->> 'ok' = 'true' and (r ->> 'difference')::numeric = 30 and (r ->> 'email_queued')::boolean and lnk is not null, 'E1 osa summasta: erotus 30, linkki, viesti jonossa');
  perform pg_temp.ck(pg_temp.mails(o) = n0 + 1 and pg_temp.mails(o, 'payment_link') = 1
      and exists (select 1 from booking.email_outbox where order_id = o and kind = 'payment_link' and payment_id = lnk and payload ->> 'variant' = 'voucher_difference'
                    and (payload ->> 'total')::numeric = 80 and (payload ->> 'voucher_value')::numeric = 50 and (payload ->> 'difference')::numeric = 30), 'E2 tasan yksi uusi viesti: payment_link / voucher_difference (80 / 50 / 30)');
  perform pg_temp.ck(exists (select 1 from booking.vc_difference_payments where payment_id = lnk and claim_id = c and order_id = o), 'E3 erotuslinkki kirjattu (vc_difference_payments)');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = o and kind in ('receipt', 'order_confirmation', 'voucher_claim_problem')), 'E4 ei kuitti-, tilausvahvistus- eikä ongelmaviestiä');
  -- botti: sama
  o2 := pg_temp.mkpending(cu, pid, sp, 70, 'fi', 49);
  select public_token into tok from booking.orders where id = o2;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('ZQ', 9), 'elamyslahjat');
  perform pg_temp.logout();
  c2 := (r ->> 'claim_no')::bigint;
  n0 := pg_temp.mails(o2);
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(c2, 45, 'T176-BOT', null);
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and r ->> 'redeemed_via' = 'bot' and (r ->> 'difference')::numeric = 25 and (r ->> 'email_queued')::boolean
      and pg_temp.mails(o2) = n0 + 1 and pg_temp.mails(o2, 'payment_link') = 1
      and exists (select 1 from booking.vc_difference_payments d join booking.payments p on p.id = d.payment_id where d.claim_id = c2 and p.amount = 25 and p.status = 'pending'),
      'E5 botti osa summasta: yksi viesti, erotus 25 € linkkinä');
  perform pg_temp.svc();
  r := booking.svc_mark_voucher_claim_redeemed(c2, 45, 'T176-BOT', null);
  perform pg_temp.logout();
  perform pg_temp.ck((r ->> 'already')::boolean and pg_temp.mails(o2) = n0 + 1, 'E6 uusi kutsu: already, ei uutta viestiä');
  -- vanha polku, henkilökunta: admin_resolve_voucher_claim(…, 'redeemed', arvo) = sama kuin admin_mark_voucher_claim_redeemed
  o3 := pg_temp.mkpending(cu, pid, sp, 90, 'fi', 55);
  select public_token into tok from booking.orders where id = o3;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('XW', 10), 'offerilla');
  perform pg_temp.logout();
  c3 := (r ->> 'claim_no')::bigint;
  n0 := pg_temp.mails(o3);
  perform pg_temp.login(u_adm);
  r := booking.admin_resolve_voucher_claim(c3, 'redeemed', null, 't176 vanha polku', 60, 'T176-LEG');
  perform pg_temp.logout();
  lnk2 := (r #>> '{payment_link,payment_id}')::bigint;
  perform pg_temp.ck(r ->> 'ok' = 'true' and r #>> '{claim,status}' = 'redeemed' and (r ->> 'difference')::numeric = 30 and (r ->> 'email_queued')::boolean and lnk2 is not null
      and pg_temp.mails(o3) = n0 + 1 and exists (select 1 from booking.email_outbox where order_id = o3 and kind = 'payment_link' and payment_id = lnk2 and payload ->> 'variant' = 'voucher_difference'
                    and (payload ->> 'total')::numeric = 90 and (payload ->> 'voucher_value')::numeric = 60 and (payload ->> 'difference')::numeric = 30)
      and exists (select 1 from booking.vc_difference_payments where payment_id = lnk2 and claim_id = c3 and order_id = o3)
      and exists (select 1 from booking.audit_log where table_name = 'booking.voucher_claims' and row_pk = c3::text and action = 'VOUCHER_DIFFERENCE_LINK'),
      'E7 vanha polku (admin_resolve redeemed 60/90): erotus 30 linkkinä, yksi viesti, kirjattu');
  -- vanha polku, botti: svc_resolve_voucher_claim(…, 'redeemed', arvo)
  o2 := pg_temp.mkpending(cu, pid, sp, 35, 'en', 57);
  select public_token into tok from booking.orders where id = o2;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('ZQ', 9), 'elamyslahjat');
  perform pg_temp.logout();
  c2 := (r ->> 'claim_no')::bigint;
  n0 := pg_temp.mails(o2);
  perform pg_temp.svc();
  r := booking.svc_resolve_voucher_claim(c2, 'redeemed', null, null, 20, 'T176-LEGBOT');
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and r ->> 'redeemed_via' = 'bot' and (r ->> 'difference')::numeric = 15 and pg_temp.mails(o2) = n0 + 1 and pg_temp.mails(o2, 'payment_link') = 1
      and exists (select 1 from booking.vc_difference_payments d join booking.payments p on p.id = d.payment_id where d.claim_id = c2 and p.amount = 15 and p.status = 'pending'),
      'E8 vanha polku (svc_resolve redeemed 20/35): erotus 15 linkkinä, yksi viesti');
  perform pg_temp.svc();
  x := pg_temp.call(format('booking.svc_resolve_voucher_claim(%s, %L)', c2, 'redeemed'));
  perform pg_temp.logout();
  perform pg_temp.ck(x ->> 'state' = 'BK001' and x ->> 'err' = 'invalid_state' and pg_temp.mails(o2) = n0 + 1, 'E9 vanha polku: jo lunastettu → BK001 invalid_state kuten ennen, ei viestiä');

  -- ===== F kohta 4: erotus maksettu → kuitti tilaussivulla, ei kuittisähköpostia
  n0 := pg_temp.mails(o);
  update booking.payments set status = 'paid', paid_at = now() where id = lnk;
  select id into rc from booking.receipts where payment_id = lnk and kind = 'receipt';
  perform pg_temp.ck(rc is not null and ((booking._order_balance(o)) ->> 'unpaid')::numeric = 0, 'F1 erotus maksettu: kuitti syntyi, tilaus maksettu');
  perform pg_temp.ck(pg_temp.mails(o) = n0 and pg_temp.mails(o, 'receipt') = 0, 'F2 ei kuittisähköpostia');
  select public_token into tok from booking.orders where id = o;
  perform pg_temp.anon();
  r := booking.public_get_order(tok);
  perform pg_temp.logout();
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r -> 'receipts') e where e ->> 'receipt_no' = (select receipt_no from booking.receipts where id = rc) and (e ->> 'total')::numeric = 30),
      'F3 tilaussivu (public_get_order) näyttää erotuksen kuitin (30 €)');
  -- korvaava linkki (uusi payments.id): vanha erotuslinkki vanheni, henkilökunta luo uuden ilman sähköpostia → maksusta ei kuittisähköpostia
  n0 := pg_temp.mails(o3);
  update booking.payments set link_expires_at = now() - interval '1 minute' where id = lnk2;
  perform pg_temp.login(u_adm);
  r := booking.admin_create_payment_link(o3, false, 14, 't176 korvaava');
  perform pg_temp.logout();
  pay := (r ->> 'payment_id')::bigint;
  perform pg_temp.ck(pay is not null and pay <> lnk2 and (select status from booking.payments where id = lnk2) = 'cancelled' and not exists (select 1 from booking.vc_difference_payments where payment_id = pay),
      'F4 korvaava linkki: uusi payments.id, vanha peruttu');
  update booking.payments set status = 'paid', paid_at = now() where id = pay;
  select id into rc from booking.receipts where payment_id = pay and kind = 'receipt';
  select public_token into tok from booking.orders where id = o3;
  perform pg_temp.anon();
  r := booking.public_get_order(tok);
  perform pg_temp.logout();
  perform pg_temp.ck(rc is not null and pg_temp.mails(o3) = n0 and pg_temp.mails(o3, 'receipt') = 0 and ((booking._order_balance(o3)) ->> 'unpaid')::numeric = 0
      and exists (select 1 from jsonb_array_elements(r -> 'receipts') e where e ->> 'receipt_no' = (select receipt_no from booking.receipts where id = rc)),
      'F5 korvaavan linkin maksu: kuitti tilaussivulla, ei kuittisähköpostia');

  -- ===== G kohta 5: lunastus epäonnistuu → ei viestiä (myös problem_emails_enabled = true)
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.problem_emails_enabled';
  o := pg_temp.mkpending(cu, pid, sp, 40, 'fi', 51);
  select public_token into tok from booking.orders where id = o;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('KK', 8), 'kokemuskauppa');
  perform pg_temp.logout();
  c := (r ->> 'claim_no')::bigint;
  n0 := pg_temp.mails(o);
  perform pg_temp.svc();
  r := booking.svc_resolve_voucher_claim(c, 'problem', 'invalid_code', 't176', null, null);
  x := booking.svc_notify_voucher_claim_problems();
  perform pg_temp.logout();
  perform pg_temp.ck((select status = 'problem' and problem_notified_at is null from booking.voucher_claims where id = c), 'G1 pyyntö ongelmatilassa, ei ilmoitettu');
  perform pg_temp.ck(pg_temp.mails(o) = n0 and pg_temp.mails(o, 'voucher_claim_problem') = 0, 'G2 ei voucher_claim_problem-viestiä');
  -- korjattu koodi (asiakas) → ei uutta vahvistusta
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('KK', 8), 'kokemuskauppa');
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'ok' = 'true' and pg_temp.mails(o) = n0, 'G3 korjattu koodi: ei uutta viestiä');

  -- ===== H virheet (SQLSTATE)
  o := pg_temp.mkpending(cu, pid, sp, 30, 'fi', 53);
  select public_token into tok from booking.orders where id = o;
  perform pg_temp.anon();
  r := booking.public_submit_voucher_claim(tok, pg_temp.rnd('KK', 8), 'kokemuskauppa');
  c := (r ->> 'claim_no')::bigint;
  x := pg_temp.call(format('booking._vc_redeem(%s, 10, null, null, %L)', c, 'staff'));
  perform pg_temp.ck(x ->> 'state' = '42501', 'H1 anon ei kutsu _vc_redeem (42501)');
  x := pg_temp.call(format('booking.svc_mark_voucher_claim_redeemed(%s, 10)', c));
  perform pg_temp.ck(x ->> 'state' = '42501', 'H2 anon ei kutsu svc_mark_voucher_claim_redeemed (42501)');
  perform pg_temp.logout();
  perform pg_temp.svc();
  x := pg_temp.call(format('booking.svc_mark_voucher_claim_redeemed(%s, 30.01)', c));
  perform pg_temp.ck(x ->> 'state' = 'BK001' and x ->> 'err' = 'voucher_exceeds_total', 'H3 botti: arvo > maksettava → BK001 voucher_exceeds_total');
  x := pg_temp.call(format('booking.svc_mark_voucher_claim_redeemed(%s, 0)', c));
  perform pg_temp.ck(x ->> 'state' = 'BK001' and x ->> 'err' = 'invalid_amount', 'H4 botti: arvo 0 → BK001 invalid_amount');
  x := pg_temp.call(format('booking.svc_resolve_voucher_claim(%s, %L, null, null, 30.01)', c, 'redeemed'));
  perform pg_temp.ck(x ->> 'state' = 'BK001' and x ->> 'err' = 'voucher_exceeds_total', 'H7 vanha polku: arvo > maksettava → BK001 voucher_exceeds_total');
  perform pg_temp.logout();
  perform pg_temp.login(u_rec);
  x := pg_temp.call(format('booking.admin_mark_voucher_claim_redeemed(%s, 10)', c));
  perform pg_temp.logout();
  perform pg_temp.ck(x ->> 'state' = 'BK001' and x ->> 'err' = 'forbidden', 'H5 muu kuin henkilökunta → BK001 forbidden');
  perform pg_temp.login(u_rec);
  x := pg_temp.call(format('booking.admin_resolve_voucher_claim(%s, %L, null, null, 10)', c, 'redeemed'));
  perform pg_temp.logout();
  perform pg_temp.ck(x ->> 'state' = 'BK001' and x ->> 'err' = 'forbidden', 'H8 vanha polku, muu kuin henkilökunta → BK001 forbidden');
  perform pg_temp.ck((select status = 'open' from booking.voucher_claims where id = c) and not exists (select 1 from booking.payments where order_id = o)
      and pg_temp.mails(o) = 1, 'H6 hylätyt: pyyntö auki, ei maksuja, vain varausvahvistus');

  -- palautus (transaktio kumotaan joka tapauksessa)
  update booking.settings set value = s_en where key = 'voucher_claims.enabled';
  update booking.settings set value = s_pe where key = 'voucher_claims.problem_emails_enabled';
  update booking.settings set value = s_acc where key = 'voucher_claims.partner_voucher_accounted';
  update booking.settings set value = s_mt where key = 'messages.timed_enabled';

  log := current_setting('t176.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
select 't176 leftover rows = ' || ((select count(*) from booking.customers where email like 't176-%@example.test') + (select count(*) from auth.users where email like 't176-%@example.test')) as t176_check;
