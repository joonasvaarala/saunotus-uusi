-- t234: booking.svc_set_gift_card_expiry (booking_234).
-- Asiakaspalvelubotti pidentää oman tai Johku-kortin voimassaoloa. Kumppanikortti ei kelpaa.
-- Aja migraatioiden jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
-- psql -X -v ON_ERROR_STOP=0 -f booking/supabase/tests/giftcards/t234_svc_set_gift_card_expiry.sql
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t234.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t234.log', coalesce(current_setting('t234.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;

create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  return coalesce(d, sqlstate);
end $$;

create function pg_temp.ins(
  p_code text, p_issuer text, p_source text, p_origin text, p_balance numeric, p_status text, p_valid date
) returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, initial_amount, balance, status, valid_from, valid_to)
  values (p_code, p_issuer, p_source, p_origin, 'at_sale', greatest(p_balance, 1), p_balance, p_status, p_valid, p_valid)
  returning id into v;
  return v;
end $$;

do $t$
declare
  tag text := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  v_today date := booking._gc_today();
  v_min date := (booking._gc_today() - interval '12 months')::date;
  v_max date := (booking._gc_today() + interval '12 months')::date;
  src text;
  g_exp bigint; g_johku bigint; g_edge bigint; g_old bigint; g_future bigint; g_null bigint; g_used bigint; g_zero bigint;
  g_cancel bigint; g_pending bigint; g_el bigint; g_kk bigint; g_of bigint; g_other bigint; g_verify bigint;
  code_j text; code_edge text;
  r jsonb;
  n_led int; n_aud int;
  log text; np int; nf int;
  sig_id text := 'booking.svc_set_gift_card_expiry(bigint,date,text,text)';
  sig_code text := 'booking.svc_set_gift_card_expiry(text,date,text,text)';
begin
  select pg_get_functiondef(sig_id::regprocedure) into src;
  perform pg_temp.ck(src ilike '%security definer%' and src ilike '%search_path TO ''''%' and src not like '%giftcards.manage%' and src not like '%_require_permission%', 'A1 id-funktio: definer, search_path tyhjä, ei henkilökunnan oikeustarkistusta');
  select pg_get_functiondef(sig_code::regprocedure) into src;
  perform pg_temp.ck(src ilike '%security definer%' and src ilike '%search_path TO ''''%' and src like '%gift_code_norm%', 'A2 koodi-ylikuorma: definer, search_path tyhjä, normalisoi koodin');
  perform pg_temp.ck(
    not has_function_privilege('public', sig_id, 'execute')
    and not has_function_privilege('anon', sig_id, 'execute')
    and not has_function_privilege('authenticated', sig_id, 'execute')
    and has_function_privilege('service_role', sig_id, 'execute')
    and not has_function_privilege('public', sig_code, 'execute')
    and not has_function_privilege('anon', sig_code, 'execute')
    and not has_function_privilege('authenticated', sig_code, 'execute')
    and has_function_privilege('service_role', sig_code, 'execute'),
    'A3 execute vain service_role (public, anon, authenticated estetty), molemmat allekirjoitukset');

  code_j := 'JK' || tag || 'J001';
  code_edge := 'JK' || tag || 'E001';
  g_exp := pg_temp.ins('HH' || tag || 'X001', 'own', 'native', 'native', 40, 'expired', v_today - 40);
  g_johku := pg_temp.ins(code_j, 'johku', 'johku', 'johku', 15, 'active', v_today + 10);
  g_edge := pg_temp.ins(code_edge, 'johku', 'johku', 'johku', 8, 'expired', v_min);
  g_old := pg_temp.ins('HH' || tag || 'O001', 'own', 'native', 'native', 9, 'expired', v_min - 1);
  g_future := pg_temp.ins('HH' || tag || 'F001', 'own', 'native', 'native', 25, 'active', v_today + 20);
  g_null := pg_temp.ins('HH' || tag || 'N001', 'own', 'native', 'native', 11, 'active', null);
  g_used := pg_temp.ins('HH' || tag || 'U001', 'own', 'native', 'native', 0, 'used', v_today + 30);
  g_zero := pg_temp.ins('HH' || tag || 'Z001', 'own', 'native', 'native', 0, 'expired', v_today - 5);
  g_cancel := pg_temp.ins('HH' || tag || 'C001', 'own', 'native', 'native', 20, 'cancelled', v_today + 10);
  g_pending := pg_temp.ins('HH' || tag || 'P001', 'own', 'native', 'native', 20, 'pending_payment', v_today + 10);
  g_el := pg_temp.ins('HH' || tag || 'L001', 'elamyslahjat', 'native', 'native', 30, 'expired', v_today - 3);
  g_kk := pg_temp.ins('HH' || tag || 'K001', 'kokemuskauppa', 'native', 'native', 30, 'active', v_today + 3);
  g_of := pg_temp.ins('HH' || tag || 'R001', 'offerilla', 'native', 'native', 30, 'expired', v_today - 1);
  g_other := pg_temp.ins('HH' || tag || 'M001', 'other', 'native', 'native', 30, 'active', v_today + 1);
  g_verify := pg_temp.ins('HH' || tag || 'V001', 'own', 'native', 'native', 12, 'pending_verification', v_today - 2);

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';

  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', -1, v_today + 5, 'puuttuva kortti')) = 'not_found', 'B1 tuntematon id → not_found');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(null::bigint, %L::date, %L)', v_today + 5, 'puuttuva kortti')) = 'not_found', 'B2 null-id → not_found');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%L, %L::date, %L)', 'no-such-code', v_today + 5, 'puuttuva koodi')) = 'not_found', 'B3 tuntematon koodi → not_found');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%L, %L::date, %L)', '---', v_today + 5, 'tyhjä koodi')) = 'not_found', 'B4 tyhjä koodi → not_found');

  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_el, v_today + 30, 'kumppani')) = 'partner_card', 'C1 Elämyslahjat → partner_card');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_kk, v_today + 30, 'kumppani')) = 'partner_card', 'C2 Kokemuskauppa → partner_card');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_of, v_today + 30, 'kumppani')) = 'partner_card', 'C3 Offerilla → partner_card');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_other, v_today + 30, 'kumppani')) = 'partner_card', 'C4 issuer other → partner_card');

  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_cancel, v_today + 30, 'mitätöity')) = 'gift_card_inactive', 'D1 cancelled → gift_card_inactive');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_pending, v_today + 30, 'maksamaton')) = 'gift_card_inactive', 'D2 pending_payment → gift_card_inactive');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_used, v_today + 40, 'käytetty')) = 'gift_card_used', 'D3 status used ja saldo 0 → gift_card_used');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_zero, v_today + 40, 'nollasaldon vanha')) = 'gift_card_used', 'D4 vanhentunut saldo 0 → gift_card_used');

  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_old, v_today + 15, 'liian vanha')) = 'expired_too_old', 'E1 vanhentunut yli 12 kk sitten → expired_too_old');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_null, v_today + 15, 'ei päivää')) = 'missing_valid_to', 'E2 valid_to null → missing_valid_to');

  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, null)', g_future, v_today + 40)) = 'note_required', 'F1 p_note null → note_required');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_future, v_today + 40, '')) = 'note_required', 'F2 tyhjä p_note → note_required');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_future, v_today + 40, '   ')) = 'note_required', 'F3 pelkät välilyönnit → note_required');

  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, null::date, %L)', g_future, 'ei päivää')) = 'invalid_date', 'G1 p_valid_to null → invalid_date');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_future, v_today, 'tänään')) = 'invalid_date', 'G2 p_valid_to = tänään → invalid_date');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_future, v_today - 1, 'eilen')) = 'invalid_date', 'G3 p_valid_to menneisyydessä → invalid_date');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_future, v_today + 20, 'sama päivä')) = 'not_extended', 'G4 sama voimassaolo → not_extended');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_future, v_today + 19, 'aiempi')) = 'not_extended', 'G5 aiempi mutta tuleva päivä → not_extended');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_future, v_max + 1, 'liian pitkä')) = 'extends_too_far', 'G6 yli 12 kk tästä päivästä → extends_too_far');

  r := booking.svc_set_gift_card_expiry(g_exp, v_max, '  asiakas soitti, kortti oli käyttämättä  ', '  ');
  perform pg_temp.ck(
    (r ->> 'ok')::boolean and (r ->> 'id')::bigint = g_exp and r ->> 'old_valid_to' = (v_today - 40)::text
    and r ->> 'new_valid_to' = v_max::text and r ->> 'status' = 'active' and (r ->> 'balance')::numeric = 40,
    'H1 vanhentunut oma kortti → active, saldo mukana: ' || r::text);
  select count(*) into n_led from booking.gift_card_ledger
   where gift_card_id = g_exp and delta = 0 and balance_after = 40 and reason = 'expiry_change'
     and note = 'asiakas soitti, kortti oli käyttämättä' and old_valid_to = v_today - 40 and new_valid_to = v_max and created_by is null;
  perform pg_temp.ck(n_led = 1, 'H2 ledger expiry_change, delta 0, saldo ennallaan, syy trimmattu');
  select count(*) into n_aud from booking.audit_log
   where action = 'SVC_SET_GIFT_CARD_EXPIRY' and table_name = 'gift_cards' and row_pk = g_exp::text
     and actor is null and actor_role = 'service_role'
     and old_data ->> 'valid_to' = (v_today - 40)::text and old_data ->> 'status' = 'expired'
     and new_data ->> 'valid_to' = v_max::text and new_data ->> 'status' = 'active'
     and new_data ->> 'note' = 'asiakas soitti, kortti oli käyttämättä' and new_data ->> 'actor' = 'asiakaspalvelu-bot';
  perform pg_temp.ck(n_aud = 1, 'H3 audit SVC_SET_GIFT_CARD_EXPIRY, oletustoimija asiakaspalvelu-bot');
  perform pg_temp.ck((select status from booking.gift_cards where id = g_exp) = 'active' and (select valid_to from booking.gift_cards where id = g_exp) = v_max and (select balance from booking.gift_cards where id = g_exp) = 40, 'H4 kortin tila active ja valid_to päivitetty');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_set_gift_card_expiry(%s::bigint, %L::date, %L)', g_exp, v_max + 1, 'vielä')) = 'extends_too_far', 'H5 jo maksimissa: pidempi päivä → extends_too_far');

  r := booking.svc_set_gift_card_expiry('jk' || lower(tag) || '-j001', v_today + 50, 'Johku-koodi viivoilla', 'asiakaspalvelu-ilta');
  perform pg_temp.ck((r ->> 'id')::bigint = g_johku and r ->> 'status' = 'active' and r ->> 'old_valid_to' = (v_today + 10)::text and r ->> 'new_valid_to' = (v_today + 50)::text and (r ->> 'balance')::numeric = 15, 'I1 ei-vielä-vanhentunut Johku-kortti koodilla, toimija talteen');
  perform pg_temp.ck((select new_data ->> 'actor' from booking.audit_log where action = 'SVC_SET_GIFT_CARD_EXPIRY' and row_pk = g_johku::text) = 'asiakaspalvelu-ilta', 'I2 p_actor kirjataan auditiin');
  perform pg_temp.ck((select status from booking.gift_cards where id = g_johku) = 'active', 'I3 voimassa oleva kortti pysyy active');

  r := booking.svc_set_gift_card_expiry(code_edge, v_today + 1, 'tasan 12 kk rajalla');
  perform pg_temp.ck((r ->> 'id')::bigint = g_edge and r ->> 'status' = 'active' and r ->> 'old_valid_to' = v_min::text, 'J1 vanhentunut tasan 12 kk sitten kelpaa');

  r := booking.svc_set_gift_card_expiry(g_future, v_today + 21, 'voimassa oleva oma');
  perform pg_temp.ck(r ->> 'status' = 'active' and r ->> 'old_valid_to' = (v_today + 20)::text and r ->> 'new_valid_to' = (v_today + 21)::text, 'K1 ei-vielä-vanhentunut oma kortti kelpaa');

  r := booking.svc_set_gift_card_expiry(g_verify, v_today + 7, 'vahvistamaton saldo');
  perform pg_temp.ck(r ->> 'status' = 'pending_verification' and (select status from booking.gift_cards where id = g_verify) = 'pending_verification', 'L1 pending_verification ei vaihdu activeksi (sama sääntö kuin admin)');

  execute 'reset role';
  begin
    execute 'set local role authenticated';
    perform booking.svc_set_gift_card_expiry(g_future, v_today + 30, 'ei oikeutta');
    perform pg_temp.ck(false, 'M1 authenticated pääsi kutsumaan');
  exception when insufficient_privilege then
    perform pg_temp.ck(true, 'M1 authenticated ei saa execute');
  end;
  begin
    execute 'set local role anon';
    perform booking.svc_set_gift_card_expiry(code_j, v_today + 60, 'ei oikeutta');
    perform pg_temp.ck(false, 'M2 anon pääsi kutsumaan');
  exception when insufficient_privilege then
    perform pg_temp.ck(true, 'M2 anon ei saa execute');
  end;

  log := current_setting('t234.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
