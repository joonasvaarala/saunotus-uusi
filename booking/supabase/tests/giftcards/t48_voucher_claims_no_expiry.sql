-- ================= booking_47/48: kumppanilahjakorttien lunastuspyynnöt (booking_48: ei vanhenemista) =================
create function pg_temp.mkw(p_email text, p_name text default 'Testi Asiakas') returns jsonb language plpgsql volatile as $$
declare v_start timestamptz; v_r jsonb;
begin
  delete from booking.rate_limit_hits;
  select a.starts_at into v_start from booking.public_treatment_availability(10, (now() at time zone 'Europe/Helsinki')::date + 3, (now() at time zone 'Europe/Helsinki')::date + 16, 1) a order by a.starts_at limit 1;
  if v_start is null then return jsonb_build_object('ok', false, 'code', 'no_slot'); end if;
  v_r := booking.public_create_treatment_booking(10, v_start, 1, p_name, p_email, '+358401234567');
  return v_r || jsonb_build_object('_start', v_start, '_oid', (select order_id from booking.reservations where product_id = 10 order by id desc limit 1));
end $$;
create function pg_temp.tok(p_oid bigint) returns uuid language sql as $$ select public_token from booking.orders where id = p_oid $$;
create function pg_temp.sub(p_oid bigint, p_code text, p_src text, p_item bigint default null) returns jsonb language plpgsql volatile as $$
begin perform pg_temp.as_(''); delete from booking.gift_card_check_log; delete from booking.rate_limit_hits; return booking.public_submit_voucher_claim(pg_temp.tok(p_oid), p_code, p_src, p_item); end $$;
create function pg_temp.svc() returns void language sql as $$ select pg_temp.as_('{"role":"service_role"}') $$;

do $$ declare
  r jsonb; o1 bigint; o2 bigint; o3 bigint; o4 bigint; o5 bigint; o6 bigint; c1 bigint; c2 bigint; c3 bigint; c4 bigint; v_tot numeric; v_pay bigint; v_ok boolean; cl jsonb; x jsonb; v_n int; v_hold timestamptz;
  v_rep0 jsonb; v_rep1 jsonb; v_cardcode text; v_pm text;
begin
  perform pg_temp.as_('');
  -- ---- A. skeema, oletukset, oikeudet ----
  perform pg_temp.t_ok((select count(*) from information_schema.columns where table_schema = 'booking' and table_name = 'voucher_claims' and column_name in ('id', 'order_id', 'reservation_id', 'order_item_id', 'code', 'source', 'status', 'problem_code', 'customer_name', 'customer_email', 'customer_phone', 'hold_until', 'created_at', 'updated_at', 'resolved_at', 'resolved_by', 'notes', 'attempts', 'last_checked_at')) = 19
     and (select relrowsecurity from pg_class where oid = 'booking.voucher_claims'::regclass) and not has_table_privilege('anon', 'booking.voucher_claims', 'select') and not has_table_privilege('authenticated', 'booking.voucher_claims', 'select')
     and not has_table_privilege('authenticated', 'booking.voucher_claims', 'insert') and (select count(*) from pg_policies where schemaname = 'booking' and tablename = 'voucher_claims') = 0, 'A1 taulu + kaikki pyydetyt sarakkeet; RLS päällä, ei policyja, anon/authenticated eivät pääse tauluun suoraan');
  perform pg_temp.t_ok((select value from booking.settings where key = 'voucher_claims.enabled') = 'false'::jsonb and (select value from booking.settings where key = 'voucher_claims.problem_emails_enabled') = 'false'::jsonb
     and (select value from booking.settings where key = 'voucher_claims.partner_voucher_accounted') = 'false'::jsonb and not exists (select 1 from booking.settings where key = 'voucher_claims.hold_hours') and (select value from booking.settings where key = 'voucher_claims.remind_after_hours') = '24'::jsonb, 'A2 asetusoletukset: enabled=false, problem_emails_enabled=false, partner_voucher_accounted=false, hold_hours poistettu, remind_after_hours=24');
  perform pg_temp.t_ok(has_function_privilege('anon', 'booking.public_resolve_gift_code(text)', 'execute') and has_function_privilege('anon', 'booking.public_submit_voucher_claim(uuid,text,text,bigint)', 'execute') and has_function_privilege('anon', 'booking.public_get_order_voucher_claims(uuid)', 'execute')
     and not has_function_privilege('anon', 'booking.admin_list_voucher_claims(text,text,integer,integer,text)', 'execute') and has_function_privilege('authenticated', 'booking.admin_resolve_voucher_claim(bigint,text,text,text,numeric,text)', 'execute')
     and not has_function_privilege('anon', 'booking.svc_list_open_voucher_claims(integer,boolean)', 'execute') and not has_function_privilege('authenticated', 'booking.svc_list_open_voucher_claims(integer,boolean)', 'execute') and has_function_privilege('service_role', 'booking.svc_list_open_voucher_claims(integer,boolean)', 'execute')
     and not has_function_privilege('authenticated', 'booking.svc_resolve_voucher_claim(bigint,text,text,text,numeric,text)', 'execute') and not has_function_privilege('anon', 'booking._vc_resolve(bigint,text,text,text,numeric,text,text)', 'execute')
     and not has_function_privilege('anon', 'booking.voucher_claims_housekeeping()', 'execute') and not has_function_privilege('authenticated', 'booking.svc_notify_voucher_claim_problems()', 'execute'), 'A3 oikeudet: public anon+auth; admin auth; svc vain service_role; sisäiset ei kenellekään');
  perform pg_temp.t_ok(exists (select 1 from cron.job where jobname = 'booking_voucher_claims_housekeeping') and (select pg_get_constraintdef(oid) from pg_constraint where conname = 'email_outbox_kind_check') like '%voucher_claim_received%' and (select pg_get_constraintdef(oid) from pg_constraint where conname = 'email_outbox_kind_check') like '%voucher_claim_problem%', 'A4 housekeeping-cron ajastettu; email_outbox.kind sisältää voucher_claim_received/problem');

  perform pg_temp.t_ok(has_function_privilege('anon', 'booking.public_update_voucher_claim_code(uuid,bigint,text,text)', 'execute') and has_function_privilege('authenticated', 'booking.public_update_voucher_claim_code(uuid,bigint,text,text)', 'execute')
     and not has_function_privilege('anon', 'booking.admin_voucher_claim_summary()', 'execute') and has_function_privilege('authenticated', 'booking.admin_voucher_claim_summary()', 'execute')
     and not has_function_privilege('anon', 'booking.svc_voucher_claim_reminders(integer,integer)', 'execute') and not has_function_privilege('authenticated', 'booking.svc_voucher_claim_reminders(integer,integer)', 'execute') and has_function_privilege('service_role', 'booking.svc_voucher_claim_reminders(integer,integer)', 'execute')
     and not has_function_privilege('anon', 'booking._vc_keep_reserved(bigint)', 'execute') and not has_function_privilege('authenticated', 'booking._vc_remind_hours()', 'execute'), 'A5 uudet RPC:t: public_update anon+auth; summary vain henkilökunta; reminders vain service_role; sisäiset ei kenellekään');
  perform pg_temp.t_ok((select is_nullable from information_schema.columns where table_schema = 'booking' and table_name = 'voucher_claims' and column_name = 'hold_until') = 'YES' and not exists (select 1 from pg_proc where pronamespace = 'booking'::regnamespace and proname in ('_vc_hold_hours', '_vc_extend_hold'))
     and (select count(*) from cron.job where jobname = 'booking_voucher_claims_housekeeping') = 1, 'A6 hold_until sallii nullin (ei käytössä), pitofunktiot poistettu, housekeeping-cron säilyy (valvonta)');

  -- ---- B. lähteen ehdotus koodin muodosta ----
  perform pg_temp.t_ok(booking._vc_guess('KK91239EKKHHA') ->> 'source' = 'kokemuskauppa' and booking._vc_guess('OK19634YIY') ->> 'source' = 'offerilla' and booking._vc_guess('OK19634YIY') ->> 'confidence' = 'high'
     and booking._vc_guess('AB12CD34EF56') ->> 'source' = 'elamyslahjat' and booking._vc_guess('AB12CD34EF56') ->> 'confidence' = 'medium'
     and booking._vc_guess('3479ACEFHJKL') ->> 'source' is null and booking._vc_guess('KK9123') ->> 'source' is null and booking._vc_guess('ABCDEF') ->> 'source' is null, 'B1 _vc_guess: KK-muoto→Kokemuskauppa, OK19-muoto→Offerilla, 12 merk. Johku-merkistön ulkopuolisilla→Elämyslahjat (medium), Johku-merkistön 12 merk.→ei ehdotusta, Kiitoskauppa ei tunnettu');
  perform pg_temp.as_(''); delete from booking.gift_card_check_log;
  r := booking.public_resolve_gift_code('kk91 239 ekk hha');
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r ->> 'kind' = 'unknown' and r ->> 'suggested_source' = 'kokemuskauppa' and r ->> 'suggestion_confidence' = 'high' and jsonb_array_length(r -> 'sources') = 4 and r ->> 'partner_claims_enabled' = 'false', 'B2 public_resolve_gift_code: tuntematon KK-koodi (välilyönnit/pienet kirjaimet) → kind=unknown, ehdotus kokemuskauppa, 4 lähdettä, partner_claims_enabled=false: ' || r::text);
  r := booking.public_resolve_gift_code('OK19-634YIY');
  perform pg_temp.t_ok(r ->> 'kind' = 'unknown' and r ->> 'suggested_source' = 'offerilla', 'B3 OK19-634YIY → offerilla');
  r := booking.public_resolve_gift_code('AB12CD34EF56');
  perform pg_temp.t_ok(r ->> 'suggested_source' = 'elamyslahjat' and r ->> 'suggestion_confidence' = 'medium', 'B4 12 merk. Johku-merkistön ulkopuolisia → elamyslahjat (medium)');
  r := booking.public_resolve_gift_code('3479-ACEF-HJKL');
  perform pg_temp.t_ok(r ->> 'kind' = 'unknown' and r -> 'suggested_source' = 'null'::jsonb, 'B5 Johku-muotoinen tuntematon koodi → unknown, ei ehdotusta');
  r := booking.public_resolve_gift_code('ab');
  perform pg_temp.t_ok(r ->> 'ok' = 'false' and r ->> 'code' = 'invalid_code', 'B6 liian lyhyt koodi → invalid_code');
  -- oma kortti tunnistetaan (kuten public_check_gift_card)
  perform pg_temp.as_(pg_temp.adm());
  r := booking.admin_create_gift_card('open', 50, 1, null, 'Mikko M', null, null, null, null, null, 'fi', 'testi vc', 'admin', 'buyer');
  v_cardcode := (select code from booking.gift_cards where id = (r -> 'cards' -> 0 ->> 'id')::bigint);
  perform pg_temp.as_(''); delete from booking.gift_card_check_log;
  r := booking.public_resolve_gift_code(booking.gift_code_fmt(v_cardcode));
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r ->> 'kind' = 'own' and r ->> 'type' = 'value' and (r ->> 'balance')::numeric = 50 and not (r ? 'public_token') and not (r ? 'id'), 'B7 oma kortti → kind=own + sama kortti-info kuin public_check_gift_card (ei tokenia/id:tä): ' || r::text);
  -- rate limit jaettu: 10 epäonnistunutta -> 11. estetty
  delete from booking.gift_card_check_log; delete from booking.rate_limit_hits;
  for v_n in 1..10 loop r := booking.public_resolve_gift_code('ZZ99' || v_n || 'XXXXXXX'); end loop;
  r := booking.public_resolve_gift_code('ZZ99' || 11 || 'XXXXXXX');
  perform pg_temp.t_ok(r ->> 'ok' = 'false' and r ->> 'code' = 'rate_limited', 'B8 rate limit: 11. tuntematon yritys 10 minuutissa → rate_limited (sama laskuri kuin public_check_gift_card)');
  delete from booking.gift_card_check_log; delete from booking.rate_limit_hits;

  -- ---- C. julkinen pyyntö ----
  r := pg_temp.mkw('vc1-testi@example.invalid');
  perform pg_temp.t_ok(r ->> '_oid' is not null and r ->> 'ok' = 'true', 'C0 testitilaus 1 luotu: ' || left(r::text, 200));
  o1 := (r ->> '_oid')::bigint;
  select total_gross into v_tot from booking.orders where id = o1;
  r := pg_temp.sub(o1, 'KK91239EKKHHA', 'kokemuskauppa');
  perform pg_temp.t_ok(r ->> 'code' = 'voucher_claims_disabled', 'C1 oletuksena pois päältä: voucher_claims_disabled');
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.enabled';
  r := booking.public_resolve_gift_code('KK91239EKKHHA');
  perform pg_temp.t_ok(r ->> 'partner_claims_enabled' = 'true', 'C2 resolve kertoo partner_claims_enabled=true kun päällä');
  perform pg_temp.t_ok(pg_temp.sub(o1, 'KK91239EKKHHA', 'partner_other') ->> 'code' = 'invalid_source' and pg_temp.sub(o1, 'KK91239EKKHHA', 'foo') ->> 'code' = 'invalid_source' and pg_temp.sub(o1, 'KK91239EKKHHA', null) ->> 'code' = 'invalid_source', 'C3 lähde pakollinen ja vain 4 julkista (partner_other ei julkisesti)');
  perform pg_temp.t_ok(pg_temp.sub(o1, 'AB', 'offerilla') ->> 'code' = 'invalid_code' and pg_temp.sub(o1, repeat('A', 25), 'offerilla') ->> 'code' = 'invalid_code', 'C4 liian lyhyt/pitkä koodi → invalid_code');
  perform pg_temp.as_(''); delete from booking.gift_card_check_log; delete from booking.rate_limit_hits;
  r := booking.public_submit_voucher_claim(gen_random_uuid(), 'KK91239EKKHHA', 'kokemuskauppa');
  perform pg_temp.t_ok(r ->> 'code' = 'not_found', 'C5 tuntematon tilaus → not_found');
  perform pg_temp.t_ok(pg_temp.sub(o1, v_cardcode, 'elamyslahjat') ->> 'code' = 'use_own_card', 'C6 oma lahjakortti ei kelpaa pyynnöksi (use_own_card): Johku-lipun ohitus mahdoton');
  r := pg_temp.sub(o1, 'KK91 239 ekk-hha', 'kokemuskauppa');
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r ->> 'status' = 'open' and r ->> 'code_masked' = '…KHHA' || '' and r -> 'hold_until' = 'null'::jsonb and r ->> 'source_mismatch' = 'false' and not (r::text like '%EKKHHA%'),
     'C7 pyyntö luotu: open, koodi maskattuna (ei täyttä koodia vastauksessa), hold_until null (ei käytössä), ei lähde-ristiriitaa: ' || r::text);
  c1 := (r ->> 'claim_no')::bigint;
  perform pg_temp.t_ok((select code from booking.voucher_claims where id = c1) = 'KK91239EKKHHA' and (select customer_email from booking.voucher_claims where id = c1) = 'vc1-testi@example.invalid' and (select customer_name from booking.voucher_claims where id = c1) = 'Testi Asiakas'
     and (select reservation_id from booking.voucher_claims where id = c1) = (select id from booking.reservations where order_id = o1 limit 1) and (select source_suggested from booking.voucher_claims where id = c1) = 'kokemuskauppa' and (select locale from booking.voucher_claims where id = c1) = 'fi', 'C8 koodi normalisoituna, asiakkaan yhteystiedot + varaus kopioitu, ehdotettu lähde tallessa');
  perform pg_temp.t_ok((select count(*) from booking.email_outbox where kind = 'voucher_claim_received' and order_id = o1 and dedupe_key = 'vcrecv:' || c1 and payload ->> 'claim_id' = c1::text and status in ('pending', 'skipped')) = 1, 'C9 vahvistusviesti jonossa (voucher_claim_received, dedupe vcrecv:<id>; tila pending/skipped resend-moodin mukaan)');
  r := pg_temp.sub(o1, 'kk91239ekkhha', 'kokemuskauppa');
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r ->> 'already' = 'true' and (r ->> 'claim_no')::bigint = c1 and (select count(*) from booking.voucher_claims where order_id = o1) = 1 and (select count(*) from booking.email_outbox where kind = 'voucher_claim_received' and order_id = o1) = 1, 'C10 sama koodi uudelleen → idempotentti (already=true), ei kaksoisriviä eikä toista viestiä');
  r := pg_temp.mkw('vc2-testi@example.invalid'); o2 := (r ->> '_oid')::bigint;
  perform pg_temp.t_ok(pg_temp.sub(o2, 'KK91239EKKHHA', 'kokemuskauppa') ->> 'code' = 'code_already_claimed', 'C11 sama koodi toisella tilauksella → code_already_claimed');
  r := pg_temp.sub(o2, 'OK19-029OIB', 'elamyslahjat');
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r ->> 'source_mismatch' = 'true', 'C12 asiakas valitsee eri lähteen kuin ehdotus → hyväksytään, source_mismatch=true (ehdotus tallessa)');
  c2 := (r ->> 'claim_no')::bigint;
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  x := booking.public_get_order_voucher_claims(pg_temp.tok(o1));
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and jsonb_array_length(x -> 'claims') = 1 and x -> 'claims' -> 0 ->> 'public_status' = 'received' and x -> 'claims' -> 0 ->> 'code_masked' = '…KHHA' and not (x::text like '%EKKHHA%') and not (x -> 'claims' -> 0 ? 'notes') and not (x -> 'claims' -> 0 ? 'customer_email'), 'C13 tilaussivun tila: received, koodi maskattuna, ei muistiinpanoja/yhteystietoja: ' || x::text);
  perform pg_temp.t_ok(booking.public_get_order_voucher_claims(gen_random_uuid()) ->> 'code' = 'not_found', 'C14 tuntematon token → not_found');
  -- tilausrajoitteet
  perform pg_temp.as_(pg_temp.adm());
  update booking.orders set status = 'cancelled' where id = o2;
  perform pg_temp.t_ok((select status from booking.voucher_claims where id = c2) = 'cancelled' and (select resolved_by from booking.voucher_claims where id = c2) = 'system', 'C15 tilauksen peruutus sulkee avoimen pyynnön (cancelled, system)');
  perform pg_temp.t_ok(pg_temp.sub(o2, 'KK55123ABCDEF', 'kokemuskauppa') ->> 'code' = 'order_not_editable', 'C16 peruttu tilaus → order_not_editable');
  perform pg_temp.as_(pg_temp.adm());
  update booking.settings set value = '2'::jsonb where key = 'voucher_claims.max_per_order';
  perform pg_temp.t_ok(pg_temp.sub(o1, 'OK19-111AAA', 'offerilla') ->> 'ok' = 'true' and pg_temp.sub(o1, 'OK19-222BBB', 'offerilla') ->> 'code' = 'too_many_claims', 'C17 max_per_order=2: kolmas koodi → too_many_claims');
  update booking.settings set value = '10'::jsonb where key = 'voucher_claims.max_per_order';
  update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = 'staff' where order_id = o1 and code = 'OK19111AAA';

  -- ---- D. botti ----
  perform pg_temp.svc();
  cl := booking.svc_list_open_voucher_claims(50, true);
  perform pg_temp.t_ok((cl ->> 'count')::int = 1 and cl -> 'claims' -> 0 ->> 'code' = 'KK91239EKKHHA' and cl -> 'claims' -> 0 ->> 'source' = 'kokemuskauppa' and (cl -> 'claims' -> 0 -> 'order' ->> 'unpaid')::numeric = v_tot and cl -> 'claims' -> 0 -> 'order' ->> 'first_start' is not null
     and cl -> 'claims' -> 0 ->> 'customer_email' = 'vc1-testi@example.invalid' and (select status from booking.voucher_claims where id = c1) = 'processing' and (select attempts from booking.voucher_claims where id = c1) = 1, 'D1 svc_list_open: palauttaa täyden koodin + tilauksen tiedot, merkitsee processing (attempts=1): ' || left(cl::text, 300));
  perform pg_temp.t_ok((booking.svc_list_open_voucher_claims(50, true) ->> 'count')::int = 0, 'D2 toinen ajo heti perään ei palauta samaa (ei kaksoiskäsittelyä)');
  update booking.voucher_claims set last_checked_at = now() - interval '31 minutes' where id = c1;
  perform pg_temp.t_ok((booking.svc_list_open_voucher_claims(50, false) ->> 'count')::int = 1 and (select status from booking.voucher_claims where id = c1) = 'processing' and (select attempts from booking.voucher_claims where id = c1) = 1, 'D3 jumiin jäänyt processing (>30 min) palautuu listaan; p_mark=false ei muuta mitään');
  -- ongelma: koodi vanhentunut, ilmoitukset pois päältä
  x := booking.svc_resolve_voucher_claim(c1, 'problem', 'expired_code', 'Kumppanin sivu: koodi vanhentunut', null, 'EL-123');
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and (select status from booking.voucher_claims where id = c1) = 'problem' and (select problem_code from booking.voucher_claims where id = c1) = 'expired_code' and (select resolved_by from booking.voucher_claims where id = c1) = 'bot'
     and (select hold_until from booking.voucher_claims where id = c1) is null and x ->> 'problem_email_queued' = 'false'
     and not exists (select 1 from booking.email_outbox where kind = 'voucher_claim_problem'), 'D4 problem/expired_code: ei pitoaikaa (hold_until null), EI ongelmaviestiä kun problem_emails_enabled=false');
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  x := booking.public_get_order_voucher_claims(pg_temp.tok(o1));
  perform pg_temp.t_ok(x -> 'claims' -> 0 ->> 'public_status' = 'problem' and x -> 'claims' -> 0 ->> 'problem_code' = 'expired_code' and x -> 'claims' -> 0 -> 'hold_until' = 'null'::jsonb and (x -> 'claims' -> 0 ->> 'can_update_code')::boolean and not (x::text like '%EL-123%'), 'D5 tilaussivu näyttää ongelman + can_update_code=true, ei aikarajaa, ei sisäisiä tietoja');
  perform pg_temp.svc();
  perform pg_temp.t_ok(booking.svc_notify_voucher_claim_problems() ->> 'enabled' = 'false' and not exists (select 1 from booking.email_outbox where kind = 'voucher_claim_problem'), 'D6 svc_notify ei tee mitään kun asetus pois');
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.problem_emails_enabled';
  x := booking.svc_notify_voucher_claim_problems();
  perform pg_temp.t_ok((x ->> 'queued')::int = 1 and (select count(*) from booking.email_outbox where kind = 'voucher_claim_problem' and order_id = o1 and payload ->> 'problem_code' = 'expired_code' and payload ->> 'claim_id' = c1::text) = 1 and (select problem_notified_at from booking.voucher_claims where id = c1) is not null
     and (booking.svc_notify_voucher_claim_problems() ->> 'queued')::int = 0, 'D7 asetus päälle → svc_notify jonottaa ongelmaviestin (kind voucher_claim_problem) kerran; toinen ajo 0');
  update booking.email_outbox set status = 'pending', next_attempt_at = now(), locked_at = null where kind in ('voucher_claim_received', 'voucher_claim_problem') and order_id = o1;
  x := booking.email_outbox_claim(50);
  perform pg_temp.t_ok((select count(*) from jsonb_array_elements(x) e where e ->> 'kind' in ('voucher_claim_received', 'voucher_claim_problem') and e -> 'voucher_claim' ->> 'code_masked' = '…KHHA' and e ->> 'to' = 'vc1-testi@example.invalid' and e -> 'order' ->> 'order_url' is not null) = 2
     and not (x::text like '%EKKHHA%') and (select e -> 'voucher_claim' ->> 'status' from jsonb_array_elements(x) e where e ->> 'kind' = 'voucher_claim_problem') = 'problem', 'D8 email_outbox_claim: voucher_claim-lohko (maskattu koodi, tila, order_url), vastaanottaja tilauksen asiakas; täyttä koodia ei viesteissä');
  -- virheelliset siirtymät
  perform pg_temp.t_err(format('select booking.svc_resolve_voucher_claim(%s, %L)', c1, 'redeemed'), 'invalid_state', 'D9 botti ei voi käsitellä problem-tilaista (invalid_state)');
  perform pg_temp.t_err(format('select booking.svc_resolve_voucher_claim(%s, %L)', c1, 'cancelled'), 'invalid_status', 'D10 botti ei peruuta (invalid_status)');
  perform pg_temp.t_err(format('select booking.svc_resolve_voucher_claim(%s, %L, %L)', c1, 'problem', 'foo'), 'invalid_problem_code', 'D11 virheellinen problem_code');
  perform pg_temp.t_err('select booking.svc_resolve_voucher_claim(999999999, ''open'')', 'not_found', 'D12 tuntematon pyyntö → not_found');

  -- ---- E. asiakas korjaa koodin ----
  r := pg_temp.sub(o1, 'KK77123ABCDEF', 'kokemuskauppa');
  c3 := (r ->> 'claim_no')::bigint;
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and (select status from booking.voucher_claims where id = c1) = 'cancelled' and (select resolved_by from booking.voucher_claims where id = c1) = 'customer' and (select status from booking.voucher_claims where id = c3) = 'open', 'E1 uusi koodi korvaa ongelmatilaisen pyynnön (vanha cancelled/customer, uusi open)');
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  x := booking.public_get_order_voucher_claims(pg_temp.tok(o1));
  perform pg_temp.t_ok((x -> 'claims') @> jsonb_build_array(jsonb_build_object('claim_no', c3)) and not ((x -> 'claims') @> jsonb_build_array(jsonb_build_object('claim_no', c1))), 'E2 tilaussivulla uusi pyyntö näkyy, asiakkaan korvaama piilotetaan');

  -- ---- F. lunastus (vahvistettu pay_later-tilaus) + kirjanpito ----
  perform pg_temp.svc();
  cl := booking.svc_list_open_voucher_claims(50, true);
  perform pg_temp.t_ok((cl ->> 'count')::int = 1 and cl -> 'claims' -> 0 ->> 'id' = c3::text, 'F0 botti saa uuden pyynnön');
  select count(*), coalesce(sum(total_gross), 0) into v_n, v_tot from booking.receipts;
  v_rep0 := booking._report_json((now() at time zone 'Europe/Helsinki')::date, (now() at time zone 'Europe/Helsinki')::date, false, false);
  x := booking.svc_resolve_voucher_claim(c3, 'redeemed', null, 'Lunastettu kumppanin sivulla', 9999, 'KK-REF-1');
  select total_gross into v_tot from booking.orders where id = o1;
  v_pay := (x ->> 'payment_id')::bigint;
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and v_pay is not null and (select method from booking.payments where id = v_pay) = 'partner_voucher' and (select status from booking.payments where id = v_pay) = 'paid' and (select amount from booking.payments where id = v_pay) = v_tot
     and (select payment_status from booking.orders where id = o1) = 'paid' and (select status from booking.voucher_claims where id = c3) = 'redeemed' and (select amount from booking.voucher_claims where id = c3) = v_tot and (select voucher_value from booking.voucher_claims where id = c3) = 9999
     and (select resolved_by from booking.voucher_claims where id = c3) = 'bot' and (select partner_ref from booking.voucher_claims where id = c3) = 'KK-REF-1' and (select payment_id from booking.voucher_claims where id = c3) = v_pay and not (select needs_review from booking.voucher_claims where id = c3),
     'F1 lunastus: payments.method=partner_voucher paid, summa = maksamaton (kuponkiarvo 9999 katkaistaan), tilaus paid, pyyntö redeemed/bot, payment_id+partner_ref tallessa: ' || x::text);
  perform pg_temp.t_ok(booking._acct_excluded(o1, v_pay) and not exists (select 1 from booking.receipts where payment_id = v_pay) and not exists (select 1 from booking.accounting_outbox where payment_id = v_pay) and (select count(*) from booking.receipts) = v_n,
     'F2 kirjanpito: partner_voucher-maksu on _acct_excluded: ei kuittia, ei accounting_outbox-riviä, kuittien määrä ennallaan');
  v_rep1 := booking._report_json((now() at time zone 'Europe/Helsinki')::date, (now() at time zone 'Europe/Helsinki')::date, false, false);
  perform pg_temp.t_ok(v_rep0 -> 'totals' = v_rep1 -> 'totals' and v_rep0 -> 'by_method' = v_rep1 -> 'by_method' and v_rep0 -> 'unreceipted' = v_rep1 -> 'unreceipted', 'F3 kassaraportin totaalit, maksutapajakauma ja kuittaamattomat ennallaan lunastuksen jälkeen');
  perform pg_temp.t_err(format('select booking.svc_resolve_voucher_claim(%s, %L)', c3, 'open'), 'invalid_state', 'F4 lunastettua ei voi käsitellä uudelleen (invalid_state)');
  perform pg_temp.as_(pg_temp.adm());
  perform pg_temp.t_err(format('select booking.admin_resolve_voucher_claim(%s, %L)', c3, 'cancelled'), 'invalid_state', 'F5 henkilökunta ei muuta lunastettua (invalid_state)');
  -- partial: kuponkiarvo < maksamaton
  r := pg_temp.mkw('vc3-testi@example.invalid'); o3 := (r ->> '_oid')::bigint;
  r := pg_temp.sub(o3, 'AB12CD34EF56', 'elamyslahjat'); c4 := (r ->> 'claim_no')::bigint;
  perform pg_temp.svc(); perform booking.svc_list_open_voucher_claims(50, true);
  x := booking.svc_resolve_voucher_claim(c4, 'redeemed', null, null, 20, null);
  perform pg_temp.t_ok((x ->> 'amount')::numeric = 20 and pg_temp.bal(o3, 'unpaid') = (select total_gross from booking.orders where id = o3) - 20 and (select payment_status from booking.orders where id = o3) = 'partially_paid', 'F6 osittainen kuponkiarvo (20 €): maksu 20 €, loput maksamatta, tilaus partially_paid');
  -- tilaus maksettu jo muuten -> redeemed ilman maksua + needs_review
  r := pg_temp.mkw('vc4-testi@example.invalid'); o4 := (r ->> '_oid')::bigint;
  r := pg_temp.sub(o4, 'OK19-333CCC', 'offerilla'); c1 := (r ->> 'claim_no')::bigint;
  perform pg_temp.as_(pg_temp.adm()); perform booking.admin_record_payment(o4, 'cash', (select total_gross from booking.orders where id = o4), null);
  perform pg_temp.t_ok(pg_temp.sub(o4, 'OK19-444DDD', 'offerilla') ->> 'code' = 'nothing_to_pay', 'F7 maksettu tilaus: uusi pyyntö → nothing_to_pay');
  perform pg_temp.svc(); perform booking.svc_list_open_voucher_claims(50, true);
  x := booking.svc_resolve_voucher_claim(c1, 'redeemed', null, null, 50, null);
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and (x ->> 'payment_id') is null and (select needs_review from booking.voucher_claims where id = c1) and (select status from booking.voucher_claims where id = c1) = 'redeemed' and (select count(*) from booking.payments where order_id = o4 and method = 'partner_voucher') = 0,
     'F8 jos tilauksella ei ole enää maksettavaa: pyyntö redeemed ilman maksukirjausta, needs_review=true (henkilökunta näkee)');
  -- kytkin: partner_voucher_accounted=true -> normaali kuitti
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.partner_voucher_accounted';
  r := pg_temp.mkw('vc5-testi@example.invalid'); o5 := (r ->> '_oid')::bigint;
  r := pg_temp.sub(o5, 'OK19-555EEE', 'offerilla'); c1 := (r ->> 'claim_no')::bigint;
  perform pg_temp.svc(); perform booking.svc_list_open_voucher_claims(50, true);
  x := booking.svc_resolve_voucher_claim(c1, 'redeemed', null, null, null, null);
  perform pg_temp.t_ok(not booking._acct_excluded(o5, (x ->> 'payment_id')::bigint) and exists (select 1 from booking.receipts where payment_id = (x ->> 'payment_id')::bigint and kind = 'receipt'), 'F9 kytkin partner_voucher_accounted=true: partner_voucher-maksu tuottaa kuitin (päätös palautettavissa ilman migraatiota)');
  update booking.settings set value = 'false'::jsonb where key = 'voucher_claims.partner_voucher_accounted';
  -- normaali käteismaksu ennallaan
  perform pg_temp.t_ok(exists (select 1 from booking.receipts r2 join booking.payments p on p.id = r2.payment_id where p.order_id = o4 and p.method = 'cash') and not booking._acct_excluded(o4, (select id from booking.payments where order_id = o4 and method = 'cash')), 'F10 käteismaksu tuottaa edelleen kuitin (muut maksutavat ennallaan)');

  -- ---- G. ei vanhenemista (booking_48): pending-tilaus + pyyntö ----
  r := pg_temp.mkw('vc6-testi@example.invalid'); o6 := (r ->> '_oid')::bigint;
  -- hoitovaraus on aina pay_later; muutetaan odottavaksi (verkkomaksutilan tilaus: pending + 15 min pito)
  update booking.reservations set status = 'pending', hold_expires_at = now() + interval '15 minutes' where order_id = o6;
  update booking.orders set status = 'pending' where id = o6;
  perform pg_temp.t_ok((select status from booking.orders where id = o6) = 'pending' and (select status from booking.reservations where order_id = o6 limit 1) = 'pending', 'G0 pending-tilaus (pending + pito) valmis');
  r := pg_temp.sub(o6, 'KK66123ABCDEF', 'kokemuskauppa'); c1 := (r ->> 'claim_no')::bigint;
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and (select status from booking.reservations where order_id = o6 limit 1) = 'confirmed' and (select hold_expires_at from booking.reservations where order_id = o6 limit 1) is null
     and (select status from booking.orders where id = o6) = 'confirmed' and (select hold_until from booking.voucher_claims where id = c1) is null and (select payment_status from booking.orders where id = o6) in ('unpaid', 'pending'),
     'G1 pyyntö jätetty pending-tilaukselle: varaus vahvistetaan (ei pitoaikaa, ei vanhene), tilaus confirmed, maksamaton saldo jää, hold_until null: ' || (select payment_status from booking.orders where id = o6));
  perform pg_temp.svc(); perform booking.svc_list_open_voucher_claims(50, true);
  x := booking.svc_resolve_voucher_claim(c1, 'problem', 'invalid_code', null, null, null);
  perform pg_temp.t_ok((select status from booking.reservations where order_id = o6 limit 1) = 'confirmed' and (select hold_until from booking.voucher_claims where id = c1) is null and (select problem_notified_at from booking.voucher_claims where id = c1) is not null
     and (select count(*) from booking.email_outbox where kind = 'voucher_claim_problem' and order_id = o6) = 1, 'G2 ongelma: varaus pysyy vahvistettuna, ei pitoaikaa, ilmoitus jonossa (asetus päällä)');
  perform pg_temp.as_(pg_temp.adm());
  x := booking.admin_resolve_voucher_claim(c1, 'open', null, 'Asiakas korjasi koodin puhelimessa');
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and (select status from booking.voucher_claims where id = c1) = 'open' and (select problem_code from booking.voucher_claims where id = c1) is null and (select resolved_at from booking.voucher_claims where id = c1) is null and (select hold_until from booking.voucher_claims where id = c1) is null, 'G3 henkilökunta avaa ongelman uudelleen jonoon (open, problem_code tyhjennetty, ei pitoaikaa)');
  -- vanha pyyntö: 5 vrk, mitään ei vanhene
  update booking.voucher_claims set created_at = now() - interval '5 days' where id = c1;
  x := booking.voucher_claims_housekeeping();
  perform pg_temp.t_ok((x ->> 'expired_claims')::int = 0 and (select status from booking.voucher_claims where id = c1) = 'open' and (x ->> 'stale_active')::int >= 1 and (x ->> 'oldest_stale_hours')::numeric >= 119, 'G4 housekeeping EI vanhenna mitään (5 vrk vanha open pysyy open), raportoi stale_active: ' || x::text);
  perform booking._expire_holds(null);
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  perform pg_temp.t_ok((select bool_and(status = 'confirmed') from booking.reservations where order_id = o6) and booking.public_get_order(pg_temp.tok(o6)) ->> 'status' = 'confirmed', 'G5 _expire_holds ei vapauta aikaa eikä tilaussivu näytä "expired": varaus confirmed, tilaus confirmed');
  perform pg_temp.svc();
  cl := booking.svc_list_open_voucher_claims(50, true);
  perform pg_temp.t_ok((select count(*) from jsonb_array_elements(cl -> 'claims') e where e ->> 'id' = c1::text) = 1 and (select (e ->> 'age_hours')::numeric from jsonb_array_elements(cl -> 'claims') e where e ->> 'id' = c1::text) >= 119, 'G6 svc_list_open palauttaa vanhan (5 vrk) pyynnön, ei suodata ajalla; age_hours mukana');
  x := booking.svc_resolve_voucher_claim(c1, 'redeemed', null, 'Lunastettu viiveellä', null, 'KK-LATE');
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and (select status from booking.voucher_claims where id = c1) = 'redeemed' and (select payment_status from booking.orders where id = o6) = 'paid', 'G7 vanha pyyntö voidaan lunastaa normaalisti (partner_voucher-maksu, tilaus paid)');

  -- ---- H. hallinta ----
  r := pg_temp.mkw('vc7-testi@example.invalid', 'Liisa Lahjakortti'); o1 := (r ->> '_oid')::bigint;
  r := pg_temp.sub(o1, 'AB99XY77ZZ11', 'elamyslahjat'); c1 := (r ->> 'claim_no')::bigint;
  perform pg_temp.as_('');
  perform pg_temp.t_err('select booking.admin_list_voucher_claims()', 'forbidden', 'H1 admin_list: anon → forbidden');
  perform pg_temp.t_err(format('select booking.admin_get_voucher_claim(%s)', c1), 'forbidden', 'H2 admin_get: anon → forbidden');
  perform pg_temp.t_err(format('select booking.admin_resolve_voucher_claim(%s, %L)', c1, 'cancelled'), 'forbidden', 'H3 admin_resolve: anon → forbidden');
  perform pg_temp.as_(pg_temp.adm());
  x := booking.admin_list_voucher_claims('active', 'Liisa');
  perform pg_temp.t_ok((x ->> 'total')::int = 1 and x -> 'claims' -> 0 ->> 'id' = c1::text and x -> 'claims' -> 0 -> 'code' = 'null'::jsonb and x -> 'claims' -> 0 ->> 'code_masked' = '…ZZ11' and not (x::text like '%AB99XY77ZZ11%'), 'H4 admin_list: hakusana nimellä, vain maskattu koodi: ' || left(x::text, 200));
  perform pg_temp.t_ok((booking.admin_list_voucher_claims(null, 'zz11') ->> 'total')::int = 1 and (booking.admin_list_voucher_claims(null, 'ZZ-11') ->> 'total')::int = 1 and (booking.admin_list_voucher_claims('redeemed') ->> 'total')::int >= 2 and (booking.admin_list_voucher_claims('needs_review') ->> 'total')::int >= 1, 'H5 admin_list: haku koodin loppuosalla, tilasuodattimet (redeemed, needs_review)');
  perform pg_temp.t_err('select booking.admin_list_voucher_claims(''foo'')', 'invalid_status', 'H6 admin_list: tuntematon tila');
  x := booking.admin_get_voucher_claim(c1);
  perform pg_temp.t_ok(x -> 'claim' ->> 'code' = 'AB99XY77ZZ11' and x -> 'claim' ->> 'status' = 'open' and x -> 'source_guess' ->> 'source' = 'elamyslahjat' and jsonb_array_length(x -> 'reservations') = 1 and x -> 'order' ->> 'status' = 'confirmed'
     and (select count(*) from booking.audit_log where table_name = 'voucher_claims' and action = 'REVEAL' and row_pk = c1::text) = 1, 'H7 admin_get: koko koodi vain täällä; katselu kirjataan audit_logiin (REVEAL, ei koodia)');
  perform pg_temp.t_ok(not exists (select 1 from booking.audit_log where table_name = 'voucher_claims' and (coalesce(old_data::text, '') || coalesce(new_data::text, '')) ~ '(KK91239EKKHHA|AB99XY77ZZ11|AB12CD34EF56|KK66123ABCDEF|KK77123ABCDEF|OK19555EEE)') and exists (select 1 from booking.audit_log where table_name = 'voucher_claims' and action = 'INSERT' and new_data ->> 'code_masked' = '…ZZ11'),
     'H8 audit_log ei sisällä selkokielisiä koodeja (vain maskattu), INSERT/UPDATE-rivit silti kirjautuvat');
  x := booking.admin_resolve_voucher_claim(c1, 'problem', 'already_used', 'Elämyslahjat: koodi jo käytetty');
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and (select resolved_by from booking.voucher_claims where id = c1) = 'staff' and (select notes from booking.voucher_claims where id = c1) like '%staff: ongelma already_used%' and x ->> 'problem_email_queued' = 'true', 'H9 henkilökunta merkitsee ongelman (already_used) → ilmoitus jonoon, muistiinpano + resolved_by=staff');
  x := booking.admin_resolve_voucher_claim(c1, 'redeemed', null, 'Asiakas toi koodin paikan päällä, lunastettu käsin', null, 'EL-777');
  perform pg_temp.t_ok(x ->> 'ok' = 'true' and (select status from booking.voucher_claims where id = c1) = 'redeemed' and (select method from booking.payments where id = (x ->> 'payment_id')::bigint) = 'partner_voucher', 'H10 henkilökunta voi lunastaa ongelmatilaisen käsin (partner_voucher-maksu)');
  perform pg_temp.t_err(format('select booking.admin_resolve_voucher_claim(%s, %L)', c1, 'foo'), 'invalid_status', 'H11 virheellinen tila');
  x := booking.admin_voucher_claim_stats(null, null);
  perform pg_temp.t_ok((x -> 'totals' ->> 'redeemed')::int >= 3 and (select (e ->> 'redeemed')::int from jsonb_array_elements(x -> 'by_source') e where e ->> 'source' = 'elamyslahjat') >= 2 and (x -> 'totals' ->> 'redeemed_amount')::numeric > 0, 'H12 admin_voucher_claim_stats: lunastukset lähteittäin ja summa (tilastot, ei kassaraportin totaaleissa)');
  -- botin yritysraja
  r := pg_temp.mkw('vc8-testi@example.invalid'); o1 := (r ->> '_oid')::bigint;
  r := pg_temp.sub(o1, 'OK19-666FFF', 'offerilla'); c1 := (r ->> 'claim_no')::bigint;
  update booking.voucher_claims set attempts = 6, status = 'processing' where id = c1;
  perform pg_temp.svc();
  x := booking.svc_resolve_voucher_claim(c1, 'open', null, 'kumppanin sivu ei vastaa');
  perform pg_temp.t_ok((select status from booking.voucher_claims where id = c1) = 'problem' and (select problem_code from booking.voucher_claims where id = c1) = 'other' and x ->> 'problem_email_queued' = 'false', 'H13 botin yritysraja (6): open → problem/other automaattisesti, asiakkaalle ei ilmoitusta (henkilökunta ratkaisee)');
  -- yleinen: ei testidataa ulos – rollback hoitaa; varmistus että vanhat viestityypit ennallaan
  perform pg_temp.t_ok((select count(*) from booking.email_outbox where kind = 'voucher_claim_received') >= 6 and has_function_privilege('anon', 'booking.public_check_gift_card(text)', 'execute') and has_function_privilege('anon', 'booking.public_apply_gift_card(uuid,text,numeric)', 'execute'), 'H14 olemassa olevat julkiset lahjakortti-RPC:t ennallaan');

  -- ---- I. booking_48: hallinnan järjestys/yhteenveto, muistutuslista, koodin korjaus ----
  perform pg_temp.as_(pg_temp.adm());
  update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = 'staff' where status in ('open', 'processing', 'problem');   -- siivotaan aiemmat aktiiviset, jotta järjestys on deterministinen
  r := pg_temp.mkw('vc9-testi@example.invalid', 'Vanha Pyyntö'); o1 := (r ->> '_oid')::bigint;
  r := pg_temp.sub(o1, 'OK19-901AAA', 'offerilla'); c1 := (r ->> 'claim_no')::bigint;
  r := pg_temp.mkw('vc10-testi@example.invalid', 'Uusi Pyyntö'); o2 := (r ->> '_oid')::bigint;
  r := pg_temp.sub(o2, 'OK19-902BBB', 'offerilla'); c2 := (r ->> 'claim_no')::bigint;
  r := pg_temp.mkw('vc11-testi@example.invalid', 'Keski Pyyntö'); o3 := (r ->> '_oid')::bigint;
  r := pg_temp.sub(o3, 'OK19-903CCC', 'offerilla'); c3 := (r ->> 'claim_no')::bigint;
  update booking.voucher_claims set created_at = now() - interval '3 days' where id = c1;
  update booking.voucher_claims set created_at = now() - interval '20 hours' where id = c3;
  perform pg_temp.as_(pg_temp.adm());
  x := booking.admin_list_voucher_claims('active');
  perform pg_temp.t_ok((x ->> 'total')::int = 3 and x ->> 'sort' = 'oldest_open' and x -> 'claims' -> 0 ->> 'id' = c1::text and x -> 'claims' -> 1 ->> 'id' = c3::text and x -> 'claims' -> 2 ->> 'id' = c2::text
     and (x -> 'claims' -> 0 ->> 'age_hours')::numeric >= 71 and (x -> 'claims' -> 0 ->> 'stale')::boolean and not (x -> 'claims' -> 2 ->> 'stale')::boolean and (x -> 'claims' -> 0 ->> 'active')::boolean and x -> 'claims' -> 0 -> 'hours_left' = 'null'::jsonb, 'I1 admin_list: oletus oldest_open = vanhin aktiivinen ensin, age_hours + stale, hold-kentät null: ' || left(x::text, 160));
  x := booking.admin_list_voucher_claims('active', null, 100, 0, 'newest');
  perform pg_temp.t_ok(x -> 'claims' -> 0 ->> 'id' = c2::text and x -> 'claims' -> 2 ->> 'id' = c1::text, 'I2 admin_list p_sort=newest: uusin ensin (vanha järjestys säilyy valittavissa)');
  perform pg_temp.t_err('select booking.admin_list_voucher_claims(null, null, 100, 0, ''foo'')', 'invalid_sort', 'I3 virheellinen järjestys');
  perform pg_temp.t_ok(booking.admin_list_voucher_claims() ->> 'ok' = 'true' and booking.admin_list_voucher_claims('open', 'Vanha') ->> 'ok' = 'true' and (booking.admin_list_voucher_claims('active', 'Vanha') ->> 'total')::int = 1, 'I4 vanhat kutsutavat (0/2 argumenttia) toimivat edelleen');
  x := booking.admin_voucher_claim_summary();
  perform pg_temp.t_ok((x ->> 'active')::int = 3 and (x ->> 'open')::int = 3 and (x ->> 'stale')::int = 1 and (x -> 'oldest' ->> 'id') = c1::text and (x -> 'oldest' ->> 'age_hours')::numeric >= 71 and x -> 'oldest' ->> 'code_masked' = '…1AAA' and (x ->> 'remind_after_hours')::int = 24 and not (x::text like '%901AAA%'), 'I5 admin_voucher_claim_summary: aktiiviset, vanhimman ikä, stale-lukumäärä, vain maskattu koodi: ' || x::text);
  perform pg_temp.as_(''); 
  perform pg_temp.t_err('select booking.admin_voucher_claim_summary()', 'forbidden', 'I6 summary: anon → forbidden');
  perform pg_temp.svc();
  x := booking.svc_voucher_claim_reminders();
  perform pg_temp.t_ok((x ->> 'count')::int = 1 and x -> 'claims' -> 0 ->> 'id' = c1::text and (x -> 'claims' -> 0 ->> 'age_hours')::numeric >= 71 and x -> 'claims' -> 0 ->> 'order_status' = 'confirmed' and not (x::text like '%901AAA%') and x -> 'claims' -> 0 ->> 'code_masked' = '…1AAA', 'I7 svc_voucher_claim_reminders: vain yli remind_after_hours (24 h) vanhat, maskattu koodi, ei kirjoita mitään');
  perform pg_temp.t_ok((booking.svc_voucher_claim_reminders(50, 12) ->> 'count')::int = 2 and (booking.svc_voucher_claim_reminders(50, 48) ->> 'count')::int = 1 and (booking.svc_voucher_claim_reminders(50, 0) ->> 'count')::int >= 2 and (select status from booking.voucher_claims where id = c1) = 'open', 'I8 reminders: p_min_age_hours säätää rajaa; tila ei muutu (vain luku)');
  -- koodin korjaus tilaussivulla
  perform pg_temp.svc(); perform booking.svc_list_open_voucher_claims(50, true);
  x := booking.svc_resolve_voucher_claim(c1, 'problem', 'invalid_code', 'Kumppanin sivu: ei löydy', null, null);
  update booking.voucher_claims set attempts = 5 where id = c1;
  perform pg_temp.as_(''); delete from booking.gift_card_check_log; delete from booking.rate_limit_hits;
  r := booking.public_update_voucher_claim_code(pg_temp.tok(o1), c1, 'ok19 901 aab', null);
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r ->> 'public_status' = 'received' and r ->> 'code_masked' = '…1AAB' and not (r::text like '%901AAB%') and (select status from booking.voucher_claims where id = c1) = 'open' and (select problem_code from booking.voucher_claims where id = c1) is null
     and (select code from booking.voucher_claims where id = c1) = 'OK19901AAB' and (select attempts from booking.voucher_claims where id = c1) = 0 and (select resolved_at from booking.voucher_claims where id = c1) is null and (select resolved_by from booking.voucher_claims where id = c1) is null
     and (select problem_notified_at from booking.voucher_claims where id = c1) is null and (select source from booking.voucher_claims where id = c1) = 'offerilla' and (select notes from booking.voucher_claims where id = c1) like '%customer: koodi korjattu (…1AAA → …1AAB%' and (select notes from booking.voucher_claims where id = c1) not like '%901AAB%', 'I9 public_update_voucher_claim_code: ongelmatilainen pyyntö → open, uusi koodi normalisoituna, attempts 0, ilmoitusmerkki nollattu, vastaus ja muistiinpano vain maskattuna: ' || r::text);
  x := booking.public_get_order_voucher_claims(pg_temp.tok(o1));
  perform pg_temp.t_ok(x -> 'claims' -> 0 ->> 'public_status' = 'received' and (x -> 'claims' -> 0 ->> 'can_update_code')::boolean and x -> 'claims' -> 0 ->> 'code_masked' = '…1AAB', 'I10 tilaussivu: korjattu pyyntö näkyy tilassa received, can_update_code=true');
  delete from booking.rate_limit_hits; delete from booking.gift_card_check_log;
  perform pg_temp.t_ok(booking.public_update_voucher_claim_code(pg_temp.tok(o1), c1, 'OK19-901AAB', 'offerilla') ->> 'code' = 'unchanged', 'I11 sama koodi + sama myyjä → unchanged');
  r := booking.public_update_voucher_claim_code(pg_temp.tok(o1), c1, 'OK19-901AAB', 'elamyslahjat');
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and (select source from booking.voucher_claims where id = c1) = 'elamyslahjat' and r ->> 'source_mismatch' = 'true', 'I12 sama koodi, eri myyjä → sallittu (lähde korjattu)');
  perform pg_temp.t_ok(booking.public_update_voucher_claim_code(pg_temp.tok(o1), c1, 'AB', null) ->> 'code' = 'invalid_code' and booking.public_update_voucher_claim_code(pg_temp.tok(o1), c1, 'OK19-904DDD', 'foo') ->> 'code' = 'invalid_source', 'I13 liian lyhyt koodi → invalid_code; tuntematon myyjä → invalid_source');
  perform pg_temp.t_ok(booking.public_update_voucher_claim_code(pg_temp.tok(o1), c1, 'OK19-902BBB', null) ->> 'code' = 'code_already_claimed', 'I14 koodi toisen tilauksen aktiivisessa pyynnössä → code_already_claimed');
  perform pg_temp.t_ok(booking.public_update_voucher_claim_code(pg_temp.tok(o1), c1, v_cardcode, null) ->> 'code' = 'use_own_card', 'I15 oma lahjakortti → use_own_card (Johku-lipun ohitus mahdoton)');
  perform pg_temp.t_ok(booking.public_update_voucher_claim_code(pg_temp.tok(o2), c1, 'OK19-905EEE', null) ->> 'code' = 'not_found' and booking.public_update_voucher_claim_code(gen_random_uuid(), c1, 'OK19-905EEE', null) ->> 'code' = 'not_found', 'I16 toisen tilauksen pyyntöä ei voi muokata; tuntematon token → not_found');
  update booking.voucher_claims set status = 'processing' where id = c1;
  perform pg_temp.t_ok(booking.public_update_voucher_claim_code(pg_temp.tok(o1), c1, 'OK19-906FFF', null) ->> 'code' = 'busy', 'I17 processing-tilaista ei voi muuttaa (busy)');
  update booking.voucher_claims set status = 'redeemed', resolved_at = now(), resolved_by = 'bot' where id = c1;
  perform pg_temp.t_ok(booking.public_update_voucher_claim_code(pg_temp.tok(o1), c1, 'OK19-906FFF', null) ->> 'code' = 'claim_not_editable', 'I18 lunastettua ei voi muuttaa (claim_not_editable)');
  perform pg_temp.as_(pg_temp.adm());
  update booking.settings set value = 'false'::jsonb where key = 'voucher_claims.enabled';
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  perform pg_temp.t_ok(booking.public_update_voucher_claim_code(pg_temp.tok(o2), c2, 'OK19-907GGG', null) ->> 'code' = 'voucher_claims_disabled', 'I19 kytkin pois → voucher_claims_disabled (myös korjaus)');
  perform pg_temp.as_(pg_temp.adm());
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.enabled';
  update booking.voucher_claims set status = 'open' where id = c2 and status = 'processing';   -- svc_list_open merkitsi sen aiemmin processing-tilaan (testin sivuvaikutus)
  perform pg_temp.as_(''); delete from booking.rate_limit_hits; delete from booking.gift_card_check_log;
  r := booking.public_update_voucher_claim_code(pg_temp.tok(o2), c2, 'OK19-907GGG', null);
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and (select status from booking.voucher_claims where id = c2) = 'open', 'I20 avoimen (ei vielä käsitellyn) pyynnön koodin saa korjata (open → open): ' || r::text);
  -- nopeusrajoitus: 10 / 10 min / tilaus (+20 / IP)
  update booking.voucher_claims set status = 'open' where id = c3 and status = 'processing';
  for v_n in 1..22 loop
    delete from booking.gift_card_check_log;
    r := booking.public_update_voucher_claim_code(pg_temp.tok(o3), c3, 'OK19-95' || v_n || 'XYZ', null);
    v_tot := v_n;
    exit when r ->> 'ok' = 'false' and r ->> 'code' = 'rate_limited';
  end loop;
  perform pg_temp.t_ok(r ->> 'code' = 'rate_limited' and v_tot between 10 and 12, 'I21 nopeusrajoitus: tilauskohtainen raja (10 / 10 min) ylittyy (rate_limited kierroksella ' || v_tot || ')');
  perform pg_temp.t_ok(not exists (select 1 from booking.audit_log where table_name = 'voucher_claims' and (coalesce(old_data::text, '') || coalesce(new_data::text, '')) ~ '(OK19901AAB|OK19901AAA|OK19907GGG)') and exists (select 1 from booking.audit_log where table_name = 'voucher_claims' and action = 'UPDATE' and new_data ->> 'code_masked' = '…1AAB'), 'I22 koodin korjaus kirjautuu audit_logiin vain maskattuna');
end $$;
