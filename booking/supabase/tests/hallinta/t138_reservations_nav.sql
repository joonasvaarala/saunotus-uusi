-- t138: varauslistan palvelinpuolinen lajittelu ja yksittäisen varauksen haku (booking_138).
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN (mock-data: Miesten sauna).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
-- Migraation/rollbackin uudelleenajettavuus testataan erikseen (migraatio 2x, rollback 2x, migraatio uudelleen).
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t138_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t138_r values (coalesce(p_ok, false), p_label) $$;
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
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 10);
  u_stf uuid := test.mk_staff('stf@t138.example', 'staff');
  b jsonb; v jsonb; w jsonb; ids bigint[] := '{}'; o bigint; i int; v_n int;
  q text := $q$select coalesce(jsonb_agg(x.reservation_id order by x.n), '[]'::jsonb) from (select reservation_id, row_number() over () n from booking.admin_list_reservations(%L::timestamptz, %L::timestamptz, null, null, null, %s, %s, null, null, %L, %s)) x$q$;
  v_from timestamptz; v_to timestamptz; v_asc jsonb; v_desc jsonb; v_new jsonb; v_old jsonb; p1 jsonb; p2 jsonb;
begin
  -- 4 varausta eri viikoille; tilausten luontiajat tahallaan eri järjestyksessä kuin alkamisajat (testidata)
  for i in 0..3 loop
    b := test.pub_book(v_rule, d + 7 * i, 2, format('t138_%s@t138.example', i));
    perform pg_temp.ck((b ->> 'ok')::boolean, 'A0: varaus ' || i);
    o := (test.ord((b ->> 'token')::uuid)).id;
    update booking.orders set created_at = now() - make_interval(hours => (array[2, 4, 1, 3])[i + 1]) where id = o;
    ids := ids || (select id from booking.reservations where order_id = o order by id limit 1);
  end loop;
  v_from := (d - 1)::timestamptz; v_to := (d + 28)::timestamptz;

  -- B: vanha kutsu (9 paikallista argumenttia, kuten admin_day_bundle) toimii ja järjestys on ennallaan (alkamisaika laskevasti)
  v := pg_temp.as_(u_stf, format($q$select coalesce(jsonb_agg(reservation_id), '[]'::jsonb) from booking.admin_list_reservations(%L::timestamptz, %L::timestamptz, null, null, null, 50, 0, null, null)$q$, v_from, v_to));
  perform pg_temp.ck(v ->> 'err' is null and jsonb_array_length(v) >= 4, 'B1: 9 argumentin kutsu toimii ' || v::text);
  w := pg_temp.as_(u_stf, format(q, v_from, v_to, 50, 0, null, 'null'));
  perform pg_temp.ck(w = v, 'B2: p_sort null = vanha järjestys');
  w := pg_temp.as_(u_stf, format($q$select to_jsonb(coalesce(bool_and(s >= nx), true)) from (select starts_at s, lead(starts_at) over () nx from booking.admin_list_reservations(%L::timestamptz, %L::timestamptz, null, null, null, 50, 0, null, null)) x where nx is not null$q$, v_from, v_to));
  perform pg_temp.ck(w = 'true'::jsonb, 'B3: oletus laskeva ' || w::text);

  -- C: start_asc = tulevat lähin ensin; sivutus palvelimella pysyy oikeana
  v_asc := pg_temp.as_(u_stf, format(q, v_from, v_to, 50, 0, 'start_asc', 'null'));
  perform pg_temp.ck(v_asc = (select jsonb_agg(e order by ord desc) from jsonb_array_elements(v) with ordinality t(e, ord)) or
                     (select bool_and(true) from jsonb_array_elements(v_asc)), 'C0: start_asc palauttaa rivit');
  perform pg_temp.ck((select array_agg(x::bigint order by n) from jsonb_array_elements_text(v_asc) with ordinality t(x, n) where x::bigint = any(ids)) = ids, 'C1: start_asc nousevasti ' || v_asc::text);
  p1 := pg_temp.as_(u_stf, format(q, v_from, v_to, 2, 0, 'start_asc', 'null'));
  p2 := pg_temp.as_(u_stf, format(q, v_from, v_to, 50, 2, 'start_asc', 'null'));
  perform pg_temp.ck(p1 || p2 = v_asc, 'C2: sivut 1+2 = koko lista ilman tuplia');

  -- D: created_desc / created_asc tilauksen luontiajan mukaan
  v_new := pg_temp.as_(u_stf, format(q, v_from, v_to, 50, 0, 'created_desc', 'null'));
  perform pg_temp.ck((select array_agg(x::bigint order by n) from jsonb_array_elements_text(v_new) with ordinality t(x, n) where x::bigint = any(ids)) = array[ids[3], ids[1], ids[4], ids[2]], 'D1: uusin ensin ' || v_new::text);
  v_old := pg_temp.as_(u_stf, format(q, v_from, v_to, 50, 0, 'created_asc', 'null'));
  perform pg_temp.ck((select array_agg(x::bigint order by n) from jsonb_array_elements_text(v_old) with ordinality t(x, n) where x::bigint = any(ids)) = array[ids[2], ids[4], ids[1], ids[3]], 'D2: vanhin ensin ' || v_old::text);
  p1 := pg_temp.as_(u_stf, format(q, v_from, v_to, 1, 0, 'created_desc', 'null'));
  p2 := pg_temp.as_(u_stf, format(q, v_from, v_to, 50, 1, 'created_desc', 'null'));
  perform pg_temp.ck(p1 || p2 = v_new, 'D3: sivutus created_desc');
  w := pg_temp.as_(u_stf, format(q, v_from, v_to, 50, 0, 'tuntematon', 'null'));
  perform pg_temp.ck(w = v, 'D4: tuntematon p_sort = oletusjärjestys');

  -- E: yksittäinen varaus (suora linkki), myös ilman aikarajaa
  w := pg_temp.as_(u_stf, format(q, null, null, 50, 0, null, ids[2]));
  perform pg_temp.ck(w = jsonb_build_array(ids[2]), 'E1: p_reservation_id rajaa yhteen ' || w::text);
  w := pg_temp.as_(u_stf, format(q, null, null, 50, 0, null, -1));
  perform pg_temp.ck(w = '[]'::jsonb, 'E2: olematon id → tyhjä');
  w := pg_temp.as_(u_stf, format($q$select (select total_count from booking.admin_list_reservations(null, null, null, null, null, 50, 0, null, null, null, %s) limit 1)::text::jsonb$q$, ids[2]));
  perform pg_temp.ck(w = '1'::jsonb, 'E3: total_count = 1');

  -- F: oikeudet ja allekirjoitus
  perform pg_temp.ck((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'booking' and p.proname = 'admin_list_reservations') = 1, 'F1: yksi ylikuorma (ei PGRST203)');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean, text, bigint)', 'execute'), 'F2: anon ei suoritusoikeutta');
  perform pg_temp.ck(has_function_privilege('authenticated', 'booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean, text, bigint)', 'execute'), 'F3: authenticated saa kutsua (staff-tarkistus funktiossa)');
  begin
    perform * from booking.admin_list_reservations();
    perform pg_temp.ck(false, 'F4: kirjautumaton hylätään');
  exception when others then perform pg_temp.ck(true, 'F4');
  end;
  perform pg_temp.ck((select prosecdef and provolatile = 's' from pg_proc where oid = 'booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean, text, bigint)'::regprocedure), 'F5: stable security definer');

  -- G: päivänippu (booking_133) kutsuu edelleen 9 argumentilla
  v := pg_temp.as_(u_stf, format('select booking.admin_day_bundle(%L)', d));
  perform pg_temp.ck(v ->> 'err' is null and jsonb_typeof(v) = 'object', 'G1: admin_day_bundle toimii ' || left(coalesce(v ->> 'msg', ''), 200));

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t138_r where ok), (select count(*) from t138_r where not ok),
    coalesce((select string_agg(label, ' | ') from t138_r where not ok), 'ALL OK');
end $t$;
