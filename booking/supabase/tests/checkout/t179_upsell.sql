-- t179: booking_179 ehdotetut tuotteet. BEGIN…ROLLBACK, pass/fail-laskuri.
-- Odotettu tulos: ERROR: TESTRESULT pass=N fail=0 :: ALL OK
-- (poikkeus kumoaa testidatan; perässä oleva ROLLBACK ajetaan, jos ON_ERROR_STOP=0).
-- Ajetaan migraation jälkeen: psql -X -v ON_ERROR_STOP=0 -f booking/supabase/tests/checkout/t179_upsell.sql
begin;
set local lock_timeout = '4s';
set local statement_timeout = '180s';

create temp table t179_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t179_r values (coalesce(p_ok, false), p_label) $$;

do $t$
declare
  v_source bigint; v_ids bigint[]; v_failed boolean; v_result jsonb; v_def text;
  v_slot timestamptz; v_day date; v_extra timestamptz; v_made jsonb; v_tok uuid; v_oid bigint; v_sid uuid;
  v_total numeric; v_pay numeric; v_n int; v_total2 numeric; v_pay2 numeric; v_n2 int; v_base int; v_hits int; v_hits2 int;
  v_mode text; v_dc bigint; v_ok boolean;
begin
  select id into v_source from kb.products where id = 1;
  select array_agg(id order by id) into v_ids from (select id from kb.products where id in (2, 3, 4) order by id) s;

  perform pg_temp.ck((select value = '120'::jsonb and is_public = false from booking.settings where key = 'upsell_cutoff_minutes'), 'S1 cutoff 120, ei julkinen');
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.product_suggestions'::regclass), 'S2 suggestions RLS');
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.upsell_events'::regclass), 'S3 events RLS');
  perform pg_temp.ck(exists (select 1 from pg_policy where polrelid = 'booking.product_suggestions'::regclass and polname = 'product_suggestions_no_direct' and polpermissive = false), 'S4 suggestions deny-politiikka');
  perform pg_temp.ck(exists (select 1 from pg_policy where polrelid = 'booking.upsell_events'::regclass and polname = 'upsell_events_no_direct' and polpermissive = false), 'S5 events deny-politiikka');
  perform pg_temp.ck(not has_table_privilege('anon', 'booking.product_suggestions', 'SELECT'), 'S6 anon ei lue ehdotuksia');
  perform pg_temp.ck(not has_table_privilege('authenticated', 'booking.product_suggestions', 'INSERT'), 'S7 authenticated ei kirjoita ehdotuksia');
  perform pg_temp.ck(not has_table_privilege('anon', 'booking.upsell_events', 'SELECT'), 'S8 anon ei lue tapahtumia');
  perform pg_temp.ck(not has_table_privilege('public', 'booking.upsell_events', 'SELECT'), 'S9 public ei lue tapahtumia');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_upsell_for_order(uuid)', 'EXECUTE'), 'S10 julkinen luku-RPC');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_upsell_checkout_attach(uuid,jsonb,uuid)', 'EXECUTE'), 'S11 julkinen liitos-RPC');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_upsell_report(date,date)', 'EXECUTE'), 'S12 anon ei raporttia');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_set_product_suggestions(bigint,jsonb)', 'EXECUTE'), 'S13 anon ei tallenna');
  perform pg_temp.ck(not has_function_privilege('public', 'booking._upsell_options(bigint[],bigint[],date,integer,integer)', 'EXECUTE'), 'S14 sisäinen funktio ei publicille');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._upsell_attach_reservation(bigint,bigint,timestamptz,integer,date)', 'EXECUTE'), 'S15 liitosydin ei anonille');
  perform pg_temp.ck((
    select bool_and(p.prosecdef and coalesce(p.proconfig, '{}')::text like '%search_path=%')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'booking' and p.proname in (
       '_upsell_cutoff', 'admin_set_product_suggestions', 'admin_get_product_suggestions', '_upsell_day_slots', '_upsell_options',
       'public_upsell_suggestions', 'public_upsell_for_order', 'public_upsell_event', '_upsell_attach_reservation',
       'public_upsell_checkout_attach', 'public_upsell_add', '_upsell_paid_trg', 'admin_upsell_report')), 'S16 security definer + search_path');

  v_result := booking.public_upsell_for_order(gen_random_uuid());
  perform pg_temp.ck(v_result->'products' = '[]'::jsonb and v_result->'addons' = '[]'::jsonb and not (v_result ? 'token') and not (v_result ? 'public_token'), 'S17 tuntematon token ei vuoda');
  v_result := booking.public_upsell_checkout_attach(gen_random_uuid(), '[]'::jsonb, gen_random_uuid());
  perform pg_temp.ck(v_result->>'ok' = 'false' and not (v_result ? 'token') and not (v_result ? 'public_token'), 'S18 liitos ei palauta tokenia');
  perform pg_temp.ck(booking.public_upsell_event(gen_random_uuid(), 'checkout', v_source, 'paid', null, null) = false, 'S19 paid ei asiakkaalta');
  perform pg_temp.ck(booking.public_upsell_event(gen_random_uuid(), 'checkout', v_source, 'added', null, null) = false, 'S20 added ei asiakkaalta');
  perform pg_temp.ck(to_regprocedure('booking.public_add_to_order(uuid,jsonb)') is not null, 'S21 public_add_to_order ennallaan');
  perform pg_temp.ck(to_regprocedure('booking._create_link_payment(bigint,integer,text)') is not null, 'S22 maksulinkki ennallaan');
  perform pg_temp.ck(to_regprocedure('booking.payments_paid_trg()') is not null, 'S23 payments_paid_trg ennallaan');
  perform pg_temp.ck(to_regprocedure('booking.public_get_booking(uuid)') is not null, 'S24 public_get_booking ennallaan');
  v_def := pg_get_functiondef('booking._upsell_options(bigint[],bigint[],date,integer,integer)'::regprocedure);
  perform pg_temp.ck(v_def like '%option_required%' and v_def like '%BK001%', 'S25 option_required pois ja saatavuusvirhe kiinni');
  perform pg_temp.ck(pg_get_functiondef('booking.public_upsell_checkout_attach(uuid,jsonb,uuid)'::regprocedure) like '%discount_code_id%' and pg_get_functiondef('booking.public_upsell_checkout_attach(uuid,jsonb,uuid)'::regprocedure) like '%annual_card%', 'S26 alennus ja vuosikortti estetty');
  perform pg_temp.ck(pg_get_functiondef('booking.public_upsell_add(uuid,jsonb,uuid,bigint)'::regprocedure) like '%p_origin%', 'S27 lisäpalvelun varaus päätellään lähtötuotteesta');
  v_def := pg_get_functiondef('booking._upsell_day_slots(bigint,date,integer)'::regprocedure);
  perform pg_temp.ck(v_def like '%_treatment_availability_core%' and v_def like '%public_booking_enabled%', 'S28 saatavuusydin ilman julkista rajoitusta');
  perform pg_temp.ck(exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'booking' and p.proname = '_upsell_day_slots' and p.proconfig::text ilike '%lock_timeout=400ms%'), 'S29 lukkoaikakatkaisu 400 ms');
  perform pg_temp.ck(
    pg_get_functiondef('booking._upsell_options(bigint[],bigint[],date,integer,integer)'::regprocedure) not like '%public_treatment_availability%'
    and pg_get_functiondef('booking._upsell_attach_reservation(bigint,bigint,timestamptz,integer,date)'::regprocedure) not like '%public_treatment_availability%'
    and pg_get_functiondef('booking.public_upsell_add(uuid,jsonb,uuid,bigint)'::regprocedure) not like '%public_treatment_availability%',
    'S30 ehdotukset eivät kuluta julkista saatavuusrajaa');
  v_def := pg_get_functiondef('booking.public_upsell_checkout_attach(uuid,jsonb,uuid)'::regprocedure);
  perform pg_temp.ck(v_def like '%payment_status%' and v_def like '%payment_lines%' and v_def like '%order_closed%', 'S31 liitos vaatii maksamattoman tilauksen');
  perform pg_temp.ck(position('_order_rl' in v_def) > 0 and position('exception when' in v_def) > position('_order_rl' in v_def), 'S32 rajoitus ennen poikkeuslohkoa');

  if cardinality(v_ids) = 3 then
    insert into booking.product_suggestions(product_id, suggested_product_id, position, enabled)
    values (v_source, v_ids[1], 1, true), (v_source, v_ids[2], 2, true), (v_source, v_ids[3], 3, true);
    perform pg_temp.ck((select count(*) from booking.product_suggestions where product_id = v_source and enabled) = 3, 'C1 tasan kolme ehdotusta');
    v_failed := false;
    begin
      insert into booking.product_suggestions(product_id, suggested_product_id, position, enabled) values (v_source, v_ids[1], 4, true);
    exception when check_violation then v_failed := true;
    end;
    perform pg_temp.ck(v_failed, 'C2 neljäs paikka hylätään');
    v_failed := false;
    begin
      insert into booking.product_suggestions(product_id, suggested_product_id, position, enabled) values (v_source, v_source, 1, true);
    exception when check_violation or unique_violation then v_failed := true;
    end;
    perform pg_temp.ck(v_failed, 'C3 itseään ei voi ehdottaa');
    delete from booking.product_suggestions where product_id = v_source;
    insert into booking.product_suggestions(product_id, suggested_product_id, position, enabled) values (v_source, 10, 1, true);
    perform pg_temp.ck(coalesce((select pc.option_required from booking.product_config pc where pc.product_id = 10), false), 'C4 tuote 10 vaatii valinnan');
  else
    perform pg_temp.ck(false, 'C0 kolmea tuotetta ei löytynyt');
  end if;

  select q.starts_at, q.session_date into v_slot, v_day
    from booking.public_treatment_availability(11, current_date, current_date + 14, 1) q
   where q.status = 'available' and q.starts_at > now() + interval '3 hours' and extract(isodow from q.session_date) in (6, 7)
   order by q.starts_at limit 1;
  perform pg_temp.ck(v_slot is not null, 'B0 viikonlopun hoitoaika');

  if v_slot is not null then
    v_made := booking.public_create_treatment_booking(11, v_slot, 1, 'Upsell Testi', 'upsell179a@example.com', '+358401110011', false, 'fi', null, 'private', null, null, null);
    v_tok := (v_made->>'token')::uuid;
    select id into v_oid from booking.orders where public_token = v_tok;
    perform pg_temp.ck((v_made->>'ok')::boolean and v_tok is not null and v_oid is not null, 'B1 perusvaraus (' || coalesce(v_made->>'code', '') || ')');
    if v_oid is not null then
      select o.total_gross, (select count(*) from booking.reservations r where r.order_id = o.id),
             (select p.amount from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.provider = 'manual' order by p.id limit 1)
        into v_total, v_n, v_pay from booking.orders o where o.id = v_oid;
      v_sid := gen_random_uuid();
      select count(*) into v_hits from booking.rate_limit_hits where bucket = 'oupschktk:' || v_tok::text;
      v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 12, 'persons', 1, 'start', '1999-01-01T12:00:00Z')), v_sid);
      select count(*) into v_hits2 from booking.rate_limit_hits where bucket = 'oupschktk:' || v_tok::text;
      perform pg_temp.ck(v_hits2 = v_hits + 1, 'R1 epäonnistunut liitos kuluttaa rajoituksen');
      select o.total_gross, (select count(*) from booking.reservations r where r.order_id = o.id),
             (select p.amount from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.provider = 'manual' order by p.id limit 1)
        into v_total2, v_n2, v_pay2 from booking.orders o where o.id = v_oid;
      perform pg_temp.ck(v_result->>'ok' = 'false' and not (v_result ? 'token'), 'B2 kelvoton aika hylätään (' || coalesce(v_result->>'code', '') || ')');
      perform pg_temp.ck(v_total2 = v_total and v_n2 = v_n and v_pay2 is not distinct from v_pay, 'B3 perusvaraus ja maksu ennallaan');
      perform pg_temp.ck((select status from booking.orders where id = v_oid) in ('pending', 'confirmed'), 'B4 tilauksen tila ehjä');

      select q.starts_at into v_extra
        from booking.public_treatment_availability(12, v_day, v_day, 1) q
       where q.status = 'available' and q.starts_at > now() + interval '3 hours'
       order by q.starts_at limit 1;
      if v_extra is null then
        perform pg_temp.ck(false, 'B5 samalle päivälle ei jäänyt toista aikaa');
      else
        v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 12, 'persons', 1, 'start', v_extra)), v_sid);
        select count(*) into v_base from booking.reservations where order_id = v_oid and product_id = 11 and booking._res_active(status, hold_expires_at);
        select total_gross into v_total2 from booking.orders where id = v_oid;
        perform pg_temp.ck(v_result->>'ok' = 'true' and (v_result->>'added_count')::int = 1 and not (v_result ? 'token'), 'B5 liitos onnistui (' || coalesce(v_result->>'code', v_result::text) || ')');
        perform pg_temp.ck(v_base = 1 and v_total2 > v_total, 'B6 perusvaraus tallella ja summa kasvoi');
        select value #>> '{}' into v_mode from booking.settings where key = 'public_payment_mode';
        if v_mode = 'pay_later' then
          select p.amount into v_pay2 from booking.payments p where p.order_id = v_oid and p.status = 'pending' and p.provider = 'manual' order by p.id limit 1;
          perform pg_temp.ck(v_pay2 is not null and v_pay2 > v_pay, 'B7 pay_later-paikkamaksu päivittyi');
        else
          perform pg_temp.ck(true, 'B7 ei pay_later-tilaa, paikkamaksua ei odoteta');
        end if;
      end if;
    end if;

    v_made := booking.public_create_treatment_booking(11, v_slot, 1, 'Upsell Koodi', 'upsell179b@example.com', '+358401110012', false, 'fi', null, 'private', null, null, null);
    -- sama aika voi olla varattu ensimmäisellä onnistuneella liitoksella vain tuotteelle 12; tuote 11 on jo varattu.
    -- haetaan uusi aika tuotteelle 11, jos ensimmäinen luonti epäonnistui kapasiteettiin.
    if coalesce((v_made->>'ok')::boolean, false) = false then
      select q.starts_at, q.session_date into v_slot, v_day
        from booking.public_treatment_availability(11, current_date, current_date + 14, 1) q
       where q.status = 'available' and q.starts_at > now() + interval '3 hours'
       order by q.starts_at limit 1;
      if v_slot is not null then
        v_made := booking.public_create_treatment_booking(11, v_slot, 1, 'Upsell Koodi', 'upsell179b@example.com', '+358401110012', false, 'fi', null, 'private', null, null, null);
      end if;
    end if;
    v_tok := (v_made->>'token')::uuid;
    select id, total_gross into v_oid, v_total from booking.orders where public_token = v_tok;
    perform pg_temp.ck(v_oid is not null, 'D1 alennustilaus (' || coalesce(v_made->>'code', '') || ')');
    if v_oid is not null then
      insert into booking.discount_codes(code, kind, value) values ('UPSELL179T', 'percent', 10) returning id into v_dc;
      update booking.orders set discount_code_id = v_dc where id = v_oid;
      v_sid := gen_random_uuid();
      v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 12, 'persons', 1, 'start', coalesce(v_extra, v_slot))), v_sid);
      select total_gross into v_total2 from booking.orders where id = v_oid;
      perform pg_temp.ck(v_result->>'code' = 'code_conflict' and v_total2 = v_total, 'D2 alennuskoodi estää lisähoidon');
      v_result := booking.public_upsell_checkout_attach(v_tok, '[]'::jsonb, v_sid);
      perform pg_temp.ck(v_result->>'ok' = 'true' and (v_result->>'added_count')::int = 0, 'D3 tyhjä liitos alennuksen kanssa onnistuu');
    end if;

    select q.starts_at into v_slot
      from booking.public_treatment_availability(11, current_date, current_date + 14, 1) q
     where q.status = 'available' and q.starts_at > now() + interval '3 hours'
     order by q.starts_at limit 1;
    if v_slot is not null then
      v_made := booking.public_create_treatment_booking(11, v_slot, 1, 'Upsell Vuosi', 'upsell179c@example.com', '+358401110013', false, 'fi', null, 'private', null, null, null);
      v_tok := (v_made->>'token')::uuid;
      select id, total_gross into v_oid, v_total from booking.orders where public_token = v_tok;
      if v_oid is not null and exists (select 1 from booking.payment_methods where code = 'annual_card') then
        insert into booking.payments(order_id, method, provider, status, amount) values (v_oid, 'annual_card', 'manual', 'pending', 0);
        v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 12, 'persons', 1, 'start', v_slot)), gen_random_uuid());
        select total_gross into v_total2 from booking.orders where id = v_oid;
        perform pg_temp.ck(v_result->>'code' = 'code_conflict' and v_total2 = v_total, 'D4 vuosikorttimaksu estää lisähoidon');
      else
        perform pg_temp.ck(v_oid is not null, 'D4 vuosikorttitilausta ei syntynyt (' || coalesce(v_made->>'code', '') || ')');
      end if;
    end if;

    select q.starts_at into v_slot
      from booking.public_treatment_availability(11, current_date, current_date + 14, 1) q
     where q.status = 'available' and q.starts_at > now() + interval '3 hours'
     order by q.starts_at limit 1;
    if v_slot is not null and exists (select 1 from booking.payment_methods where code = 'mobilepay') then
      v_made := booking.public_create_treatment_booking(11, v_slot, 1, 'Upsell Maksu', 'upsell179d@example.com', '+358401110014', false, 'fi', null, 'private', null, null, null);
      v_tok := (v_made->>'token')::uuid;
      select id, total_gross into v_oid, v_total from booking.orders where public_token = v_tok;
      if v_oid is not null then
        insert into booking.payments(order_id, method, provider, status, amount) values (v_oid, 'mobilepay', 'mobilepay', 'pending', v_total);
        select count(*) into v_n from booking.reservations where order_id = v_oid;
        v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 12, 'persons', 1, 'start', v_slot)), gen_random_uuid());
        select total_gross into v_total2 from booking.orders where id = v_oid;
        select count(*) into v_n2 from booking.reservations where order_id = v_oid;
        perform pg_temp.ck(v_result->>'code' = 'order_closed' and v_total2 = v_total and v_n2 = v_n, 'P1 kesken oleva MobilePay sulkee liitoksen');
      else
        perform pg_temp.ck(false, 'P1 varausta ei syntynyt (' || coalesce(v_made->>'code', '') || ')');
      end if;
    else
      perform pg_temp.ck(v_slot is not null, 'P1 aika tai mobilepay puuttuu');
    end if;

    select q.starts_at into v_slot
      from booking.public_treatment_availability(11, current_date, current_date + 14, 1) q
     where q.status = 'available' and q.starts_at > now() + interval '3 hours'
     order by q.starts_at limit 1;
    if v_slot is not null then
      v_made := booking.public_create_treatment_booking(11, v_slot, 1, 'Upsell Maksettu', 'upsell179e@example.com', '+358401110015', false, 'fi', null, 'private', null, null, null);
      v_tok := (v_made->>'token')::uuid;
      select id into v_oid from booking.orders where public_token = v_tok;
      if v_oid is not null then
        update booking.payments set status = 'paid', paid_at = now()
         where order_id = v_oid and status = 'pending' and provider = 'manual';
        if not found then
          insert into booking.payments(order_id, method, provider, status, amount, paid_at)
          values (v_oid, 'pay_later', 'manual', 'paid', (select total_gross from booking.orders where id = v_oid), now());
        end if;
        update booking.orders set payment_status = 'paid' where id = v_oid and payment_status is distinct from 'paid';
        select total_gross into v_total from booking.orders where id = v_oid;
        select count(*) into v_n from booking.reservations where order_id = v_oid;
        v_result := booking.public_upsell_checkout_attach(v_tok, jsonb_build_array(jsonb_build_object('product_id', 12, 'persons', 1, 'start', v_slot)), gen_random_uuid());
        select total_gross into v_total2 from booking.orders where id = v_oid;
        select count(*) into v_n2 from booking.reservations where order_id = v_oid;
        perform pg_temp.ck(v_result->>'code' = 'order_closed' and v_total2 = v_total and v_n2 = v_n, 'P2 maksettu paikkamerkki sulkee liitoksen');
      else
        perform pg_temp.ck(false, 'P2 varausta ei syntynyt (' || coalesce(v_made->>'code', '') || ')');
      end if;
    else
      perform pg_temp.ck(false, 'P2 aikaa ei löytynyt');
    end if;
  end if;

  raise exception 'TESTRESULT pass=% fail=% :: %',
    (select count(*) from t179_r where ok),
    (select count(*) from t179_r where not ok),
    coalesce((select string_agg(label, ' | ' order by label) from t179_r where not ok), 'ALL OK');
end $t$;
rollback;
