-- t194: yksityisvarauksen päällekkäisyys on kova esto. Ylibuukkaus vain admin-roolille (booking_194).
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN, paikallisessa PG17:ssä.
-- Fixtuurit luodaan ennen roolin vaihtoa. Viikonpäivävertailu: smallint[] (unnest → smallint).
-- Tulos: TESTRESULT pass=N fail=M. Ei koske tuotantoa.
set local lock_timeout = '3s';
set local statement_timeout = '90s';
create temp table t194_r(ok boolean, label text) on commit drop;
grant all on t194_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t194_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql; return 'NO ERROR'; exception when others then get stacked diagnostics v = pg_exception_detail; return coalesce(nullif(v, ''), sqlerrm); end $$;
create function pg_temp.pub(p_rule bigint, p_date date, p_persons int, p_email text) returns jsonb language sql as $$
  select booking.public_create_booking(p_rule, p_date, p_persons, 'T194 Asiakas', p_email, '0401940000', false, 'fi', null, 'private', null, null)
$$;
do $t$
declare
  v_adm uuid := test.mk_staff('adm194@example.test', 'admin');
  v_mgr uuid := test.mk_staff('mgr194@example.test', 'manager');
  v_staff uuid := test.mk_staff('staff194@example.test', 'staff');
  v_ex bigint; v_sh bigint; v_wd smallint; v_cap_rule bigint; v_cap_date date; v_cap_rem int; v_cap_max int;
  v_overlap date; v_ex_day date; v_move_from date; v_person_day date; v_off date; v_off_rule bigint; v_off_wd int;
  j jsonb; v_move bigint; v_res bigint; v_prod bigint; v_pmax int; v_opt text; v_ts timestamptz; v_code text; i int;
  v_wl_day date; v_early bigint; v_late bigint; v_bwd smallint; v_buf_day date; v_buf0 int;
  v_late_start timestamptz; v_late_end timestamptz; v_space bigint; v_late_mode text;
begin
  perform test.logout();

  select ex.id, sh.id, w.wd into v_ex, v_sh, v_wd
    from booking.schedule_rules ex
    join booking.schedule_rules sh
      on sh.active and sh.mode = 'shared' and sh.space_id = ex.space_id
     and sh.weekdays && ex.weekdays
     and ex.start_time < sh.start_time + make_interval(mins => sh.duration_minutes)
     and sh.start_time < ex.start_time + make_interval(mins => ex.duration_minutes)
    cross join lateral (select u.wd from unnest(ex.weekdays) as u(wd) where u.wd = any (sh.weekdays) limit 1) w
   where ex.active and ex.mode = 'exclusive'
     and (ex.valid_from is null or ex.valid_from <= (now() at time zone 'Europe/Helsinki')::date + 21)
     and (ex.valid_to is null or ex.valid_to >= (now() at time zone 'Europe/Helsinki')::date + 60)
     and (sh.valid_from is null or sh.valid_from <= (now() at time zone 'Europe/Helsinki')::date + 21)
     and (sh.valid_to is null or sh.valid_to >= (now() at time zone 'Europe/Helsinki')::date + 60)
     and not exists (select 1 from kb.product_price_variants v where v.id = ex.price_variant_id and v.valid_to is not null and v.valid_to < (now() at time zone 'Europe/Helsinki')::date + 60)
   order by ex.id, sh.id
   limit 1;
  if v_ex is null then raise exception 'TESTRESULT_ABORT ei päällekkäistä exclusive+shared-paria'; end if;

  v_overlap := test.next_dow(v_wd::int, 21);
  v_ex_day := test.next_dow(v_wd::int, 28);
  v_move_from := test.next_dow(v_wd::int, 35);
  v_person_day := test.next_dow(v_wd::int, 42);
  if v_overlap = v_ex_day or v_ex_day = v_move_from or v_overlap = v_move_from then
    raise exception 'TESTRESULT_ABORT päivät eivät erotu % % %', v_overlap, v_ex_day, v_move_from;
  end if;

  j := pg_temp.pub(v_sh, v_overlap, 1, 'fix194-shared@example.test');
  perform pg_temp.ck((j ->> 'ok')::boolean, 'F1: jaettu fixtuuri päällekkäiselle päivälle: ' || coalesce(j ->> 'code', j ->> 'message', 'ok'));
  j := pg_temp.pub(v_ex, v_ex_day, 1, 'fix194-priv@example.test');
  perform pg_temp.ck((j ->> 'ok')::boolean, 'F2: yksityinen fixtuuri omalle päivälle: ' || coalesce(j ->> 'code', j ->> 'message', 'ok'));
  j := pg_temp.pub(v_sh, v_move_from, 1, 'fix194-move@example.test');
  perform pg_temp.ck((j ->> 'ok')::boolean, 'F3: siirrettävä jaettu varaus: ' || coalesce(j ->> 'code', j ->> 'message', 'ok'));
  select r.id into v_move
    from booking.reservations r
    join booking.orders o on o.id = r.order_id
    join booking.customers c on c.id = o.customer_id
   where c.email = 'fix194-move@example.test' and r.rule_id = v_sh
   order by r.id desc limit 1;

  select q.rule_id, q.session_date, q.remaining, r.max_persons into v_cap_rule, v_cap_date, v_cap_rem, v_cap_max
    from booking.schedule_rules r
    join lateral booking.public_availability(r.product_id, (now() at time zone 'Europe/Helsinki')::date + 2,
                                             (now() at time zone 'Europe/Helsinki')::date + 70) q on q.rule_id = r.id
   where r.mode = 'shared' and r.active and q.status = 'available' and q.remaining between 1 and 30
     and q.session_date not in (v_overlap, v_ex_day, v_move_from, v_person_day)
   order by q.session_date, q.rule_id limit 1;
  perform pg_temp.ck(v_cap_rule is not null, 'F4: vapaa yhteinen vuoro kapasiteettitestiin');

  perform test.login(v_staff);
  perform pg_temp.ck(pg_temp.err(format(
    'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 1, p_customer := %L::jsonb, p_allow_overbook := true)',
    v_cap_rule, v_cap_date, '{"name":"Staff Lippu","kind":"private"}')) = 'overbook_admin_only',
    'N1: staff-rooli, pelkkä ylibuukkauslippu');
  perform pg_temp.ck(pg_temp.err(format(
    'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := %s, p_customer := %L::jsonb, p_allow_overbook := true)',
    v_cap_rule, v_cap_date, least(v_cap_rem + 1, 50), '{"name":"Staff Yli","kind":"private"}')) = 'overbook_admin_only',
    'N2: staff ei saa ylittää vuoron kapasiteettia');
  perform pg_temp.ck(pg_temp.err(format(
    'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := %s, p_customer := %L::jsonb, p_allow_overbook := false)',
    v_cap_rule, v_cap_date, least(v_cap_rem + 1, 50), '{"name":"Staff Ei","kind":"private"}')) in ('capacity_exceeded', 'persons_max'),
    'N3: ilman lippua kapasiteetti estää staffilta');
  perform pg_temp.ck(pg_temp.err(format(
    'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 1, p_customer := %L::jsonb, p_allow_overbook := true)',
    v_ex, v_overlap, '{"name":"Staff Yks","kind":"private"}')) = 'overbook_admin_only',
    'N4: staffin lippu hylätään ennen yksityiskonfliktia');
  perform test.logout();

  perform test.login(v_mgr);
  perform pg_temp.ck(booking.current_staff_role() = 'manager' and not booking.is_admin() and booking.has_permission('bookings.manage'), 'N5: manager ei ole admin');
  perform pg_temp.ck(pg_temp.err(format(
    'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := %s, p_customer := %L::jsonb, p_allow_overbook := true)',
    v_cap_rule, v_cap_date, least(v_cap_rem + 1, 50), '{"name":"Manager Yli","kind":"private"}')) = 'overbook_admin_only',
    'N6: manager (bookings.manage + bookings.override) ei saa ylibuukata');
  perform test.logout();

  perform test.login(v_adm);
  perform pg_temp.ck(booking.is_admin(), 'A0: admin-rooli');
  v_code := pg_temp.err(format(
    'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 2, p_customer := %L::jsonb, p_allow_overbook := true)',
    v_ex, v_overlap, '{"name":"Admin Paalle","kind":"private"}'));
  perform pg_temp.ck(v_code = 'public_shift_booked', 'A1: yksityinen jaetun päälle, lippu ei auta: ' || v_code);
  v_code := pg_temp.err(format(
    'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 1, p_customer := %L::jsonb, p_allow_overbook := true)',
    v_sh, v_ex_day, '{"name":"Admin Jaettu","kind":"private"}'));
  perform pg_temp.ck(v_code = 'private_booked', 'A2: jaettu yksityisen päälle, lippu ei auta: ' || v_code);
  v_code := pg_temp.err(format(
    'select booking.admin_change_booking(p_reservation_id := %s, p_rule_id := %s, p_date := %L, p_allow_overbook := true)',
    v_move, v_sh, v_ex_day));
  perform pg_temp.ck(v_code = 'private_booked', 'A3: siirto yksityisen päälle estyy: ' || v_code);
  j := booking.admin_create_booking(p_rule_id := v_cap_rule, p_date := v_cap_date, p_persons := least(v_cap_rem + 1, 50),
        p_customer := '{"name":"Admin Yli","kind":"private"}'::jsonb, p_allow_overbook := true);
  perform pg_temp.ck((j ->> 'reservation_id') is not null, 'A4: admin saa ylittää jaetun vuoron kapasiteetin');
  perform pg_temp.ck((select overbooked and overbooked_by = v_adm from booking.reservations where id = (j ->> 'reservation_id')::bigint), 'A5: overbooked ja tekijä');

  if (select max_persons from booking.schedule_rules where id = v_ex) is not null
     and (select max_persons from booking.schedule_rules where id = v_ex) < 50 then
    j := booking.admin_create_booking(p_rule_id := v_ex, p_date := v_person_day,
          p_persons := (select max_persons from booking.schedule_rules where id = v_ex) + 1,
          p_customer := '{"name":"Admin Hlot","kind":"private"}'::jsonb, p_allow_overbook := true);
    perform pg_temp.ck((j ->> 'reservation_id') is not null
      and (select overbooked from booking.reservations where id = (j ->> 'reservation_id')::bigint),
      'A6: yksityisvuoron ylibuukkaus = henkilömäärä, kun aika on vapaa');
    perform test.logout();
    perform test.login(v_staff);
    perform pg_temp.ck(pg_temp.err(format(
      'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := %s, p_customer := %L::jsonb, p_allow_overbook := true)',
      v_ex, v_person_day, (select max_persons from booking.schedule_rules where id = v_ex) + 1,
      '{"name":"Staff Hlot","kind":"private"}')) = 'overbook_admin_only',
      'N7: staff ei saa ylittää yksityisvuoron henkilömäärää');
    perform test.login(v_adm);
  else
    perform pg_temp.ck(false, 'A6: exclusive-säännöltä puuttuu max_persons');
  end if;

  j := booking.admin_preview_booking_limits('shift', v_ex, v_overlap, 1, null, null, null, null, null);
  perform pg_temp.ck((j ->> 'blocked')::boolean and j -> 'conflict' @> jsonb_build_array(jsonb_build_object('code', 'public_shift_booked'))
    and not (j -> 'overbook' @> jsonb_build_array(jsonb_build_object('code', 'public_shift_booked'))),
    'P1: esikatselu: yksityinen päällekkäisyys on conflict, ei overbook');
  j := booking.admin_preview_booking_limits('shift', v_sh, v_ex_day, 1, null, null, null, null, null);
  perform pg_temp.ck(j -> 'conflict' @> jsonb_build_array(jsonb_build_object('code', 'private_booked')),
    'P2: esikatselu: jaettu yksityisen päällä');
  j := booking.admin_day_view(v_ex_day);
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(j -> 'sessions') s
     where (s ->> 'rule_id')::bigint = v_sh and (s ->> 'private_conflict')::boolean),
    'U1: vuorokortti private_conflict jaetulla vuorolla');
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(j -> 'sessions') s
     where (s ->> 'rule_id')::bigint = v_ex and (s ->> 'private_conflict')::boolean),
    'U2: vuorokortti private_conflict yksityisvuorolla');

  select id into v_off_rule from booking.schedule_rules where active and mode = 'shared' and cardinality(weekdays) < 7 order by id limit 1;
  if v_off_rule is not null then
    v_off := (now() at time zone 'Europe/Helsinki')::date + 10;
    for i in 1..14 loop
      v_off_wd := extract(isodow from v_off)::int;
      exit when not (v_off_wd::smallint = any ((select weekdays from booking.schedule_rules where id = v_off_rule)::smallint[]));
      v_off := v_off + 1;
    end loop;
    perform test.logout();
    perform test.login(v_staff);
    j := booking.admin_create_booking(p_rule_id := v_off_rule, p_date := v_off, p_persons := 1,
          p_customer := '{"name":"Staff Sivu","kind":"private"}'::jsonb, p_allow_off_schedule := true);
    perform pg_temp.ck((select off_schedule from booking.reservations where id = (j ->> 'reservation_id')::bigint),
      'S1: aikataulun ulkopuolinen varaus onnistuu staffille ilman adminia');
    perform test.login(v_adm);
  end if;

  select pc.product_id, pc.max_persons into v_prod, v_pmax
    from booking.product_config pc
    join booking.product_space_rules psr on psr.product_id = pc.product_id and psr.active and psr.leg_no = 1 and psr.role = 'space' and psr.mode = 'exclusive'
   where pc.resource_class = 'resourced' and pc.lifecycle = 'current' and coalesce(pc.time_window_class, 'therapy') = 'therapy'
     and coalesce(cardinality(pc.requires_parent_product_ids), 0) = 0
   order by pc.product_id limit 1;
  if v_prod is not null then
    select po.code into v_opt from booking.product_options po where po.product_id = v_prod and po.active order by po.sort_order, po.id limit 1;
    v_ts := (test.next_dow(1, 50) + time '16:00') at time zone 'Europe/Helsinki';
    j := booking.admin_create_resource_booking(p_product_id := v_prod, p_start := v_ts, p_persons := 1,
          p_customer := '{"name":"Hoito A","kind":"private"}'::jsonb, p_option_code := v_opt);
    perform pg_temp.ck((j ->> 'reservation_id') is not null, 'R1: exclusive-resurssivaraus: ' || coalesce(j ->> 'code', j ->> 'message', 'ok'));
    v_res := (j ->> 'reservation_id')::bigint;
    if v_res is not null then
      v_code := pg_temp.err(format(
        'select booking.admin_create_resource_booking(p_product_id := %s, p_start := %L, p_persons := 1, p_customer := %L::jsonb, p_option_code := %L, p_allow_overbook := true)',
        v_prod, v_ts, '{"name":"Hoito B","kind":"private"}', v_opt));
      perform pg_temp.ck(v_code in ('private_booked', 'space_busy', 'public_shift_booked'), 'R2: toinen hoito samaan aikaan, lippu ei auta: ' || v_code);
    end if;
    if v_pmax is not null and v_pmax < 40 then
      j := booking.admin_create_resource_booking(p_product_id := v_prod, p_start := v_ts + interval '1 day', p_persons := v_pmax + 1,
            p_customer := '{"name":"Hoito Hlot","kind":"private"}'::jsonb, p_option_code := v_opt, p_allow_overbook := true);
      perform pg_temp.ck((j ->> 'reservation_id') is not null, 'R3: hoidon henkilömäärän ylitys adminille: ' || coalesce(j ->> 'message', j ->> 'code', 'ok'));
    end if;
  else
    perform pg_temp.ck(false, 'R1: ei exclusive-resurssituotetta');
  end if;

  perform test.logout();
  perform test.anon();
  perform set_config('booking.allow_overbook', 'on', true);
  j := booking.public_create_booking(v_sh, v_ex_day, 1, 'Julkinen Paalle', 'pub194@example.test', '0401940099', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck(coalesce(j ->> 'ok', 'false') <> 'true' and j ->> 'code' = 'private_booked', 'P3: julkinen ei tee jaettua varausta yksityisen päälle: ' || coalesce(j ->> 'code', 'ok'));
  perform test.logout();

  -- 1) exclusive-jonopito ei väisty ylibuukkauksella (admin on staff, _waitlist_hold_counts päästäisi läpi).
  v_wl_day := test.next_dow(v_wd::int, 56);
  insert into booking.waitlist_entries(product_id, rule_id, session_date, starts_at, ends_at, space_id, persons,
    customer_name, customer_email, status, notified_at, hold_expires_at)
  select r.product_id, r.id, v_wl_day,
         (v_wl_day + r.start_time) at time zone 'Europe/Helsinki',
         (v_wl_day + r.start_time + make_interval(mins => r.duration_minutes)) at time zone 'Europe/Helsinki',
         r.space_id, 1, 'Jono Testi', 'jono194@example.test', 'notified', now(), now() + interval '3 hours'
    from booking.schedule_rules r where r.id = v_ex;
  perform test.login(v_adm);
  v_code := pg_temp.err(format(
    'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 1, p_customer := %L::jsonb, p_allow_overbook := true)',
    v_ex, v_wl_day, '{"name":"Admin Jono","kind":"private"}'));
  perform pg_temp.ck(v_code = 'private_booked', 'W1: exclusive-jonopito ei väisty ylibuukkauksella: ' || coalesce(v_code, 'null'));
  j := booking.admin_day_view(v_wl_day);
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(j -> 'sessions') s
     where (s ->> 'rule_id')::bigint = v_ex and (s ->> 'private_conflict')::boolean),
    'W2: vuorokortti varattu exclusive-jonopidon takia');
  perform test.logout();

  -- 2) puskuri: vierekkäiset vuorot eivät osu ilman puskuria, osuvat kun resurssin buffer_after_min kasvaa.
  select e.id, l.id, w.wd into v_early, v_late, v_bwd
    from booking.schedule_rules e
    join booking.schedule_rules l
      on l.active and l.space_id = e.space_id
     and l.start_time = e.start_time + make_interval(mins => e.duration_minutes)
     and l.weekdays && e.weekdays
    cross join lateral (select u.wd from unnest(e.weekdays) u(wd) where u.wd = any (l.weekdays) limit 1) w
   where e.active and (e.mode = 'exclusive' or l.mode = 'exclusive')
     and (select res.buffer_after_min from booking.resources res where res.id = e.space_id) = 0
     and (e.valid_to is null or e.valid_to >= (now() at time zone 'Europe/Helsinki')::date + 80)
     and (l.valid_to is null or l.valid_to >= (now() at time zone 'Europe/Helsinki')::date + 80)
   order by (e.mode = 'exclusive' and l.mode = 'exclusive') desc, e.id
   limit 1;
  if v_early is null then
    perform pg_temp.ck(false, 'B0: ei vierekkäistä exclusive-vuoroparia puskuritestiin');
  else
    v_buf_day := test.next_dow(v_bwd::int, 70);
    select r.space_id, r.mode,
           (v_buf_day + r.start_time) at time zone 'Europe/Helsinki',
           (v_buf_day + r.start_time + make_interval(mins => r.duration_minutes)) at time zone 'Europe/Helsinki'
      into v_space, v_late_mode, v_late_start, v_late_end
      from booking.schedule_rules r where r.id = v_late;
    j := pg_temp.pub(v_early, v_buf_day, 1, 'buf194-early@example.test');
    perform pg_temp.ck((j ->> 'ok')::boolean, 'B0: viereinen vuoro luotu: ' || coalesce(j ->> 'code', j ->> 'message', 'ok'));
    select buffer_after_min into v_buf0 from booking.resources where id = v_space;
    perform pg_temp.ck(booking._private_overlap_code(v_space, v_late_mode, v_late_start, v_late_end, null,
        (select array_agg(pool_id) from booking.schedule_rule_pools where rule_id = v_late)) is null,
      'B1: ilman puskuria vierekkäiset vuorot eivät ole private_conflict');
    update booking.resources set buffer_after_min = greatest(v_buf0, 0) + 30 where id = v_space;
    perform pg_temp.ck(booking._private_overlap_code(v_space, v_late_mode, v_late_start, v_late_end, null,
        (select array_agg(pool_id) from booking.schedule_rule_pools where rule_id = v_late)) is not null,
      'B2: puskuri tekee private_conflictin');
    perform test.login(v_adm);
    j := booking.admin_day_view(v_buf_day);
    perform pg_temp.ck(exists (
      select 1 from jsonb_array_elements(j -> 'sessions') s
       where (s ->> 'rule_id')::bigint = v_late and (s ->> 'private_conflict')::boolean),
      'B3: vuorokortti varattu puskurin takia');
    v_code := pg_temp.err(format(
      'select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 1, p_customer := %L::jsonb, p_allow_overbook := true)',
      v_late, v_buf_day, '{"name":"Admin Puskuri","kind":"private"}'));
    perform pg_temp.ck(v_code in ('private_booked', 'public_shift_booked', 'space_busy'),
      'B4: tallennus epäonnistuu samassa puskurissa: ' || coalesce(v_code, 'null'));
    update booking.resources set buffer_after_min = v_buf0 where id = v_space;
    perform test.logout();
  end if;

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t194_r where ok), (select count(*) from t194_r where not ok),
    coalesce((select string_agg(label, ' | ') from t194_r where not ok), 'ALL OK');
end $t$;
