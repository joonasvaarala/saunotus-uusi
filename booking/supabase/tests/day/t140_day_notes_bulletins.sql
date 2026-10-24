-- t140: päivän työvuororajaus, seuraava oma vuoro, varausmuistiinpano, päivän muistiinpanot ja henkilöstötiedotteet (booking_140).
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN testikannassa (public-skeema = fixtures/public_mock.sql, feikkidata).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
-- Migraation/rollbackin uudelleenajettavuus ja tilahash testataan erikseen (migraatio 2x, rollback 2x = tila ennen 140:tä, migraatio uudelleen).
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t140_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t140_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.login(p_user);
  begin
    execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
do $t$
declare
  d date := test.next_dow(1, 10);
  u_own uuid := test.mk_staff('own@t140.example', 'staff');
  u_nolink uuid := test.mk_staff('nolink@t140.example', 'staff');
  u_cancel uuid := test.mk_staff('cancel@t140.example', 'staff');
  u_mgr uuid := test.mk_staff('mgr@t140.example', 'manager');
  u_cust uuid := test.mk_user('asiakas@t140.example');
  p_own uuid := gen_random_uuid(); p_other uuid := gen_random_uuid(); p_cancel uuid := gen_random_uuid();
  w1 uuid := gen_random_uuid(); w2 uuid := gen_random_uuid(); w3 uuid := gen_random_uuid(); w4 uuid := gen_random_uuid(); w5 uuid := gen_random_uuid();
  v jsonb; w jsonb; b jsonb; n_id bigint; b_id bigint; r_id bigint; v_rule bigint := test.rule('Miesten sauna%');
  hel text := 'Europe/Helsinki';
begin
  -- Feikkidata public-mockkiin: kolme henkilöä, vuorot päivälle d, d+1 ja d+5
  insert into public.staff(id, name, email, active) values
    (p_own, 'T140 Oma Saunottaja', 'oma@t140.example', true),
    (p_other, 'T140 Toinen Saunottaja', 'toinen@t140.example', true),
    (p_cancel, 'T140 Peruttu Saunottaja', 'peruttu@t140.example', true);
  update booking.staff set public_staff_id = p_own, name = 'T140 Oma' where user_id = u_own;
  update booking.staff set public_staff_id = p_cancel where user_id = u_cancel;
  insert into public.work_shifts(id, starts_at, ends_at, role_type, status, staffing_status) values
    (w1, (d + time '10:00') at time zone hel, (d + time '14:00') at time zone hel, 'therapist', 'active', 'ok'),
    (w2, (d + time '15:00') at time zone hel, (d + time '20:00') at time zone hel, 'therapist', 'active', 'ok'),
    (w3, (d + 1 + time '10:00') at time zone hel, (d + 1 + time '14:00') at time zone hel, 'therapist', 'active', 'ok'),
    (w4, (d + 5 + time '10:00') at time zone hel, (d + 5 + time '14:00') at time zone hel, 'therapist', 'active', 'ok'),
    (w5, (d + 3 + time '10:00') at time zone hel, (d + 3 + time '14:00') at time zone hel, 'therapist', 'cancelled', 'ok');
  insert into public.shift_assignments(shift_id, staff_id, status) values
    (w1, p_own, 'assigned'), (w2, p_other, 'confirmed'), (w2, p_cancel, 'cancelled'),
    (w3, p_other, 'assigned'), (w4, p_own, 'confirmed'), (w5, p_own, 'assigned');

  -- A: työvuorojen näkyvyys
  v := pg_temp.as_(u_own, format($q$select coalesce(jsonb_agg(staff_name order by starts_at), '[]'::jsonb) from booking.admin_day_shifts(%L)$q$, d));
  perform pg_temp.ck(v = '["T140 Oma Saunottaja", "T140 Toinen Saunottaja"]'::jsonb, 'A1: oma vuoro päivällä → näkee kaikki päivän vuorot ' || v::text);
  perform pg_temp.ck(not (v::text like '%Peruttu%'), 'A2: peruttu vuoromerkintä ei näy nimenä');
  v := pg_temp.as_(u_own, format($q$select coalesce(jsonb_agg(staff_name), '[]'::jsonb) from booking.admin_day_shifts(%L)$q$, d + 1));
  perform pg_temp.ck(v = '[]'::jsonb, 'A3: ei omaa vuoroa päivällä → tyhjä ' || v::text);
  v := pg_temp.as_(u_nolink, format($q$select coalesce(jsonb_agg(staff_name), '[]'::jsonb) from booking.admin_day_shifts(%L)$q$, d));
  perform pg_temp.ck(v = '[]'::jsonb, 'A4: ei linkkiä työntekijään → tyhjä');
  v := pg_temp.as_(u_cancel, format($q$select coalesce(jsonb_agg(staff_name), '[]'::jsonb) from booking.admin_day_shifts(%L)$q$, d));
  perform pg_temp.ck(v = '[]'::jsonb, 'A5: vain peruttu merkintä ei avaa päivää ' || v::text);
  v := pg_temp.as_(u_mgr, format($q$select coalesce(jsonb_agg(staff_name order by starts_at), '[]'::jsonb) from booking.admin_day_shifts(%L)$q$, d + 1));
  perform pg_temp.ck(v = '["T140 Toinen Saunottaja"]'::jsonb, 'A6: shifts.view_all näkee aina ' || v::text);
  v := pg_temp.as_(u_mgr, format($q$select count(*)::text::jsonb from booking.admin_day_shifts(%L)$q$, d));
  perform pg_temp.ck(v = '2'::jsonb, 'A7: managerille kaksi riviä (peruttu merkintä pois) ' || v::text);
  v := pg_temp.as_(u_cust, format($q$select count(*)::text::jsonb from booking.admin_day_shifts(%L)$q$, d));
  perform pg_temp.ck(v ? 'err', 'A8: ei-henkilöstö hylätään');

  -- B: seuraava oma vuoro
  v := pg_temp.as_(u_own, format($q$select to_jsonb(booking.admin_next_own_shift_date(%L))$q$, d - 1));
  perform pg_temp.ck(v = to_jsonb(d), 'B1: seuraava oma vuoro = d ' || v::text);
  v := pg_temp.as_(u_own, format($q$select to_jsonb(booking.admin_next_own_shift_date(%L))$q$, d + 1));
  perform pg_temp.ck(v = to_jsonb(d + 5), 'B2: peruttu vuoro (d+3) ohitetaan, seuraava d+5 ' || v::text);
  v := pg_temp.as_(u_own, format($q$select to_jsonb(booking.admin_next_own_shift_date(%L))$q$, d + 6));
  perform pg_temp.ck(coalesce(v, 'null'::jsonb) = 'null'::jsonb, 'B3: ei tulevia → null');
  v := pg_temp.as_(u_nolink, format($q$select to_jsonb(booking.admin_next_own_shift_date(%L))$q$, d));
  perform pg_temp.ck(coalesce(v, 'null'::jsonb) = 'null'::jsonb, 'B4: ei linkkiä → null');
  v := pg_temp.as_(u_own, $q$select to_jsonb(booking.admin_next_own_shift_date())$q$);
  perform pg_temp.ck(v ->> 'err' is null, 'B5: oletusparametri (tämä päivä) toimii');
  v := pg_temp.as_(u_cust, $q$select to_jsonb(booking.admin_next_own_shift_date())$q$);
  perform pg_temp.ck(v ? 'err', 'B6: ei-henkilöstö hylätään');

  -- C: varauksen muistiinpano
  b := test.pub_book(v_rule, d, 2, 'varaus@t140.example');
  perform pg_temp.ck(b ->> 'token' is not null, 'C0: testivaraus ' || left(b::text, 200));
  r_id := (test.res((b ->> 'token')::uuid)).id;
  v := pg_temp.as_(u_own, format($q$select booking.admin_set_reservation_note(%s, %L)$q$, r_id, '  Allergia: koivu  '));
  perform pg_temp.ck(v ->> 'notes' = 'Allergia: koivu' and (select notes from booking.reservations where id = r_id) = 'Allergia: koivu', 'C1: muistiinpano tallentuu trimmattuna ' || v::text);
  v := pg_temp.as_(u_own, format($q$select booking.admin_set_reservation_note(%s, %L)$q$, r_id, repeat('x', 1001)));
  perform pg_temp.ck(v ->> 'err' = 'invalid_note', 'C2: yli 1000 merkkiä hylätään ' || v::text);
  v := pg_temp.as_(u_own, $q$select booking.admin_set_reservation_note(-1, 'x')$q$);
  perform pg_temp.ck(v ->> 'err' = 'not_found', 'C3: olematon varaus ' || v::text);
  v := pg_temp.as_(u_cust, format($q$select booking.admin_set_reservation_note(%s, 'x')$q$, r_id));
  perform pg_temp.ck(v ? 'err' and (select notes from booking.reservations where id = r_id) = 'Allergia: koivu', 'C4: ei-henkilöstö ei voi muuttaa');
  v := pg_temp.as_(u_own, format($q$select booking.admin_set_reservation_note(%s, '   ')$q$, r_id));
  perform pg_temp.ck(v -> 'notes' = 'null'::jsonb and (select notes from booking.reservations where id = r_id) is null, 'C5: tyhjä → null');

  -- D: päivän muistiinpanot
  v := pg_temp.as_(u_own, format($q$select booking.admin_save_day_note(%L, %L)$q$, d, 'Lämmitys aloitettu klo 9.'));
  n_id := (v -> 'note' ->> 'id')::bigint;
  perform pg_temp.ck(n_id is not null and v -> 'note' ->> 'author_name' = 'T140 Oma', 'D1: lisäys, kirjoittaja = henkilön nimi ' || v::text);
  v := pg_temp.as_(u_nolink, format($q$select booking.admin_list_day_notes(%L)$q$, d));
  perform pg_temp.ck(jsonb_array_length(v -> 'day_notes') = 1 and v -> 'day_notes' -> 0 ->> 'body' = 'Lämmitys aloitettu klo 9.', 'D2: kaikki henkilöstö näkee päivän muistiinpanot');
  v := pg_temp.as_(u_nolink, format($q$select jsonb_array_length(booking.admin_list_day_notes(%L) -> 'day_notes')::text::jsonb$q$, d + 1));
  perform pg_temp.ck(v = '0'::jsonb, 'D3: toinen päivä tyhjä');
  v := pg_temp.as_(u_nolink, format($q$select booking.admin_save_day_note(%L, 'muutos', %s)$q$, d, n_id));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'D4: toinen perustyöntekijä ei muokkaa ' || v::text);
  v := pg_temp.as_(u_nolink, format($q$select booking.admin_delete_day_note(%s)$q$, n_id));
  perform pg_temp.ck(v ->> 'err' = 'forbidden' and exists (select 1 from booking.day_notes where id = n_id), 'D5: toinen perustyöntekijä ei poista');
  v := pg_temp.as_(u_own, format($q$select booking.admin_save_day_note(%L, 'Lämmitys valmis.', %s)$q$, d, n_id));
  perform pg_temp.ck(v -> 'note' ->> 'body' = 'Lämmitys valmis.', 'D6: kirjoittaja muokkaa');
  v := pg_temp.as_(u_own, format($q$select booking.admin_save_day_note(%L, 'väärä päivä', %s)$q$, d + 1, n_id));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'D7: muokkaus vain samalle päivälle');
  v := pg_temp.as_(u_own, format($q$select booking.admin_save_day_note(%L, '   ')$q$, d));
  perform pg_temp.ck(v ->> 'err' = 'invalid_note', 'D8: tyhjä hylätään');
  v := pg_temp.as_(u_own, format($q$select booking.admin_save_day_note(%L, %L)$q$, d, repeat('y', 2001)));
  perform pg_temp.ck(v ->> 'err' = 'invalid_note', 'D9: yli 2000 merkkiä hylätään');
  v := pg_temp.as_(u_cust, format($q$select booking.admin_list_day_notes(%L)$q$, d));
  perform pg_temp.ck(v ? 'err', 'D10: ei-henkilöstö ei lue');
  v := pg_temp.as_(u_mgr, format($q$select booking.admin_delete_day_note(%s)$q$, n_id));
  perform pg_temp.ck(v ->> 'ok' = 'true' and not exists (select 1 from booking.day_notes where id = n_id), 'D11: shifts.view_all poistaa');
  perform pg_temp.ck((select count(*) from booking.audit_log where table_name = 'day_notes' and row_pk = n_id::text) = 3, 'D12: audit (insert, update, delete)');

  -- E: tiedotteet
  v := pg_temp.as_(u_own, format($q$select booking.admin_save_bulletin(null, %L, %L, 'x')$q$, d, d + 2));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'E1: perustyöntekijä ei lisää tiedotetta ' || v::text);
  v := pg_temp.as_(u_mgr, format($q$select booking.admin_save_bulletin(null, %L, %L, %L)$q$, d, d + 2, E'Sauna 2 huollossa. Käytä varakiuasta.'));
  b_id := (v -> 'bulletin' ->> 'id')::bigint;
  perform pg_temp.ck(b_id is not null, 'E2: manager lisää ' || v::text);
  v := pg_temp.as_(u_own, format($q$select booking.admin_list_day_notes(%L) -> 'bulletins'$q$, d + 1));
  perform pg_temp.ck(jsonb_array_length(v) = 1 and (v -> 0 ->> 'id')::bigint = b_id, 'E3: näkyy välillä (d+1) kaikille');
  v := pg_temp.as_(u_own, format($q$select jsonb_array_length(booking.admin_list_day_notes(%L) -> 'bulletins')::text::jsonb$q$, d + 3));
  perform pg_temp.ck(v = '0'::jsonb, 'E4: ei näy välin jälkeen');
  v := pg_temp.as_(u_mgr, format($q$select booking.admin_save_bulletin(%s, %L, %L, 'x', false)$q$, b_id, d, d + 2));
  w := pg_temp.as_(u_own, format($q$select jsonb_array_length(booking.admin_list_day_notes(%L) -> 'bulletins')::text::jsonb$q$, d));
  perform pg_temp.ck(v -> 'bulletin' ->> 'active' = 'false' and w = '0'::jsonb, 'E5: ei-aktiivinen piilossa');
  v := pg_temp.as_(u_mgr, format($q$select booking.admin_save_bulletin(null, %L, %L, 'x')$q$, d + 2, d));
  perform pg_temp.ck(v ->> 'err' = 'invalid_bulletin', 'E6: loppu ennen alkua hylätään');
  v := pg_temp.as_(u_own, format($q$select booking.admin_delete_bulletin(%s)$q$, b_id));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'E7: perustyöntekijä ei poista');
  v := pg_temp.as_(u_mgr, format($q$select booking.admin_delete_bulletin(%s)$q$, b_id));
  perform pg_temp.ck(v ->> 'ok' = 'true' and not exists (select 1 from booking.staff_bulletins where id = b_id), 'E8: manager poistaa');
  v := pg_temp.as_(u_mgr, $q$select booking.admin_delete_bulletin(-1)$q$);
  perform pg_temp.ck(v ->> 'err' = 'not_found', 'E9: olematon');

  -- F: päivänippu = booking_133:n avaimet + notes_bundle
  perform pg_temp.as_(u_own, format($q$select booking.admin_save_day_note(%L, 'Nipun testi')$q$, d));
  v := pg_temp.as_(u_own, format($q$select booking.admin_day_bundle(%L)$q$, d));
  perform pg_temp.ck(v ->> 'err' is null, 'F1: admin_day_bundle toimii ' || left(coalesce(v ->> 'msg', ''), 200));
  perform pg_temp.ck((select array_agg(k order by k) from jsonb_object_keys(v) k) = array['addons','date','extras','notes_bundle','options','payment_methods','permissions','products','reservations','resources','role','shifts','site_texts','view'], 'F2: avaimet = booking_133 + notes_bundle');
  perform pg_temp.ck(v -> 'notes_bundle' -> 'day_notes' -> 0 ->> 'body' = 'Nipun testi' and jsonb_typeof(v -> 'notes_bundle' -> 'bulletins') = 'array', 'F3: notes_bundle sisältää päivän muistiinpanot');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(v -> 'reservations') x where (x ->> 'reservation_id')::bigint = r_id), 'F4: reservations (9 argumentin admin_list_reservations) ennallaan');
  perform pg_temp.ck(jsonb_array_length(v -> 'shifts') = 2, 'F5: shifts = admin_day_shifts');
  w := pg_temp.as_(u_nolink, format($q$select booking.admin_day_bundle(%L) -> 'shifts'$q$, d));
  perform pg_temp.ck(w = '[]'::jsonb, 'F6: nipun shifts noudattaa rajausta');
  perform pg_temp.ck(pg_temp.as_(u_cust, format($q$select booking.admin_day_bundle(%L)$q$, d)) ? 'err', 'F7: ei-henkilöstö hylätään');

  -- G: oikeudet ja RLS
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.day_notes'::regclass) and (select relrowsecurity from pg_class where oid = 'booking.staff_bulletins'::regclass), 'G1: RLS päällä');
  perform pg_temp.ck(not has_table_privilege('authenticated', 'booking.day_notes', 'select') and not has_table_privilege('anon', 'booking.staff_bulletins', 'select'), 'G2: ei suoria tauluoikeuksia');
  v := pg_temp.as_(u_mgr, $q$select count(*)::text::jsonb from booking.day_notes$q$);
  perform pg_temp.ck(v ? 'err', 'G3: suora select hylätään ' || v::text);
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_save_day_note(date, text, bigint)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_list_day_notes(date)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_set_reservation_note(bigint, text)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_next_own_shift_date(date)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_day_shifts(date)', 'execute'), 'G4: anon ei suoritusoikeutta');
  perform pg_temp.ck((select bool_and(prosecdef) from pg_proc where pronamespace = 'booking'::regnamespace and proname in
    ('admin_day_shifts','admin_next_own_shift_date','admin_set_reservation_note','admin_list_day_notes','admin_save_day_note','admin_delete_day_note','admin_save_bulletin','admin_delete_bulletin','admin_day_bundle')), 'G5: security definer');
  perform pg_temp.ck((select count(*) from pg_proc where pronamespace = 'booking'::regnamespace and proname = 'admin_day_bundle') = 1, 'G6: yksi admin_day_bundle-ylikuorma');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t140_r where ok), (select count(*) from t140_r where not ok),
    coalesce((select string_agg(label, ' | ') from t140_r where not ok), 'ALL OK');
end $t$;
