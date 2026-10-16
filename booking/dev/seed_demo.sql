-- Demo-data paikalliseen kehitykseen (EI tuotantoon): keksittyjä asiakkaita (@example.com), ei oikeita henkilötietoja.
-- Aja migraatioiden jälkeen. Luo kolme demo-käyttäjää (admin@demo.local = admin, manager@demo.local = manager/ylläpitäjä, staff@demo.local = staff/peruskäyttäjä; salasana: demo),
-- vuosikorttiasiakkaan (vuosikortti@example.com) vuosikorttivarauksineen ja esimerkkivarauksia.
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000000a1', 'admin@demo.local'),
  ('00000000-0000-4000-8000-0000000000b2', 'staff@demo.local'),
  ('00000000-0000-4000-8000-0000000000c3', 'manager@demo.local')
on conflict do nothing;
insert into booking.staff (user_id, name, role, email) values
  ('00000000-0000-4000-8000-0000000000a1', 'Demo Admin', 'admin', 'admin@demo.local'),
  ('00000000-0000-4000-8000-0000000000c3', 'Demo Ylläpitäjä (manager)', 'manager', 'manager@demo.local'),
  ('00000000-0000-4000-8000-0000000000b2', 'Demo Peruskäyttäjä (staff)', 'staff', 'staff@demo.local')
on conflict (user_id) do nothing;

do $$
declare
  d date := (now() at time zone 'Europe/Helsinki')::date;
  v_dow int; r record; n int := 0; res jsonb;
  names text[] := array['Aino Esimerkki','Eino Testinen','Helmi Demola','Onni Mallikas','Kerttu Koe','Vilho Näyte','Siiri Sampo','Toivo Tuntematon'];
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  for r in
    select * from (values
      -- (viikonpäivä 1=ma, sääntöetuliite, henkilöitä, kuinka monta varausta)
      (6, 'Yleinen vuoro la–su 14:00%', 3, 1), (6, 'Yleinen vuoro la–su 14:30%', 2, 1), (6, 'Yleinen vuoro la–su 16:00%', 4, 1),
      (7, 'Yleinen vuoro la–su 14:00%', 6, 1), (7, 'Tunnin saunavuoro la–su 18:00', 5, 1),
      (4, 'Turvetorstai%', 6, 1), (4, 'Yleinen vuoro to 17–19', 5, 1),
      (1, 'Miesten sauna%', 9, 1), (1, 'Miesten sauna%', 5, 1),
      (2, 'Oma savusaunavuoro ma–pe 16–19%', 10, 1),
      (3, 'Hiljainen sauna ke%', 4, 1)
    ) as t(dow, rule_like, persons, cnt)
  loop
    -- seuraava tällainen viikonpäivä (vähintään 2 pv päästä)
    v_dow := r.dow;
    for i in 1..r.cnt loop
      n := n + 1;
      perform set_config('request.headers', json_build_object('x-forwarded-for', '10.20.' || (n / 200) || '.' || (n % 200 + 1))::text, true);
      select booking.public_create_booking(
        (select id from booking.schedule_rules where label like r.rule_like order by id limit 1),
        d + 2 + ((v_dow - extract(isodow from d + 2)::int + 7) % 7),
        r.persons, names[1 + n % array_length(names, 1)], 'demo' || n || '@example.com', '04012345' || lpad(n::text, 2, '0'), n % 3 = 0, 'fi', null) into res;
      if not (res ->> 'ok')::boolean then raise notice 'seed: % -> %', r.rule_like, res ->> 'code'; end if;
    end loop;
  end loop;
  delete from booking.rate_limit_hits;
end $$;
-- lisäpalvelut ja yritysasiakas demossa (migraatio 11): lisäpalveluja muutamalle varaukselle + yksi yritysvaraus (laskutus) maanantaille
do $$
declare
  d date := (now() at time zone 'Europe/Helsinki')::date; v_mon date; v_tue date; v_sat date; r_mon bigint; res jsonb; v_res bigint;
begin
  v_mon := d + 2 + ((1 - extract(isodow from d + 2)::int + 7) % 7);
  v_tue := d + 2 + ((2 - extract(isodow from d + 2)::int + 7) % 7);
  v_sat := d + 2 + ((6 - extract(isodow from d + 2)::int + 7) % 7);
  perform set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-0000000000a1", "role": "authenticated"}', true);
  select id into r_mon from booking.schedule_rules where label like 'Miesten sauna%' order by id limit 1;
  -- maanantain 9 hengen varaus: 3 saunavihtaa ja 2 turvenaamiota
  select r.id into v_res from booking.reservations r where r.rule_id = r_mon and r.starts_at >= v_mon::timestamp at time zone 'Europe/Helsinki' and r.starts_at < (v_mon + 1)::timestamp at time zone 'Europe/Helsinki' and r.persons = 9 limit 1;
  perform booking.admin_set_reservation_addons(v_res, '[{"code":"saunavihta","quantity":3},{"code":"turvenaamio_jalkakylpy","quantity":2}]');
  -- yritysvaraus (lasku): 2 hlöä + 2 saunavihtaa
  res := booking.admin_create_booking(r_mon, v_mon, 2, null,
    '{"kind":"company","name":"Kaisa Yhteys","email":"kaisa.yhteys@demoyritys.example.com","phone":"0401234500","company_details":{"company_name":"Demo Yritys Oy","business_id":"0112038-9","street":"Esimerkkikatu 1","zip":"00100","city":"Helsinki","einvoice_address":"003701120389","einvoice_operator":"003723327487","reference":"PO-1234"}}'::jsonb,
    'invoice', false, 'Demo: yritysvaraus', null, null, null, 'email', '[{"code":"saunavihta","quantity":2}]'::jsonb);
  -- tiistain yksityisvuoro (10 hlöä): 6 saunavihtaa + 4 turvenaamiota
  select r.id into v_res from booking.reservations r where r.mode = 'exclusive' and r.starts_at >= v_tue::timestamp at time zone 'Europe/Helsinki' and r.starts_at < (v_tue + 1)::timestamp at time zone 'Europe/Helsinki' limit 1;
  if v_res is not null then perform booking.admin_set_reservation_addons(v_res, '[{"code":"saunavihta","quantity":6},{"code":"turvenaamio_jalkakylpy","quantity":4}]'); end if;
  -- asiakasrekisteriin yksi erillinen yritysasiakas (ei varauksia)
  perform booking.admin_create_customer('{"kind":"company","name":"Pekka Laskutus","email":"pekka.laskutus@toinenyritys.example.com","phone":"0409876500","company_details":{"company_name":"Toinen Yritys Oy","business_id":"2336509-6","street":"Tehdaskatu 2","zip":"33100","city":"Tampere"}}'::jsonb);
  perform set_config('request.jwt.claims', '', true);
end $$;
-- Johku-varaukset demossa (migraatio 12: source/external_id): merkitään kolme demovarausta Johku-tuoduiksi (external_source='johku'),
-- jotta "Johku"-tunniste ja lähdesuodatin näkyvät. Tunnus on keksitty (ei oikeaa Johku-dataa). Kenttäpari on pakollinen (orders_ext_pair / reservations_ext_pair).
do $$
declare x record; n int := 0;
begin
  for x in
    select distinct on (sr.label, r.persons) r.id as rid, r.order_id as oid
      from booking.reservations r join booking.schedule_rules sr on sr.id = r.rule_id
     where (sr.label like 'Miesten sauna%' and r.persons = 5) or (sr.label like 'Yleinen vuoro to 17–19%' and r.persons = 5) or (sr.label like 'Yleinen vuoro la–su 14:00%' and r.persons = 3)
     order by sr.label, r.persons, r.id
  loop
    n := n + 1;
    update booking.orders set external_source = 'johku', external_id = 'DEMO-O-' || (48200 + n) where id = x.oid;
    update booking.reservations set external_source = 'johku', external_id = 'DEMO-R-' || (91400 + n) where id = x.rid;
  end loop;
end $$;
-- yksi maksettu ja yksi osittain maksettu tilaus näytille
update booking.orders set payment_status = 'paid' where id = (select min(id) from booking.orders);

-- vuosikorttiasiakas: kortti voimassa vuoden, yksi tuleva ilmainen varaus yleiseen vuoroon (vuosikortti ei kelpaa yksityisvuoroon)
insert into booking.customers (name, email, phone, customer_type) values ('Vuosikortti Vilma', 'vuosikortti@example.com', '0401230000', 'customer');
do $$
declare v_c bigint := (select id from booking.customers where email = 'vuosikortti@example.com'); d date := (now() at time zone 'Europe/Helsinki')::date; res jsonb;
begin
  perform set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-0000000000a1", "role": "authenticated"}', true);
  perform booking.admin_grant_annual_card(v_c, d - 30, d + 335, 'Demo: vuosikortti');
  res := booking.admin_create_annual_card_booking(v_c, (select id from booking.schedule_rules where label like 'Hiljainen sauna ke%' order by id limit 1),
           d + 3 + ((3 - extract(isodow from d + 3)::int + 7) % 7), 'Demo: vuosikorttivaraus');
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------- työvuorot (public-skeeman MOCK, oletetut sarakkeet; ks. docs/roolit-ja-kb.md) ----------
-- Demossa public.staff / work_shifts / shift_assignments / calendar_sources ovat fixtures/public_mock.sql:n tauluja. Tuotannossa ne täyttää Työvuoro-Tapio.
insert into public.staff (id, name, email, phone, active) values
  ('00000000-0000-4000-8000-0000000000d0', 'Demo Admin',          'admin@demo.local',   '0400000000', true),
  ('00000000-0000-4000-8000-0000000000d1', 'Demo Peruskäyttäjä',  'staff@demo.local',   '0400000001', true),
  ('00000000-0000-4000-8000-0000000000d2', 'Demo Ylläpitäjä',     'manager@demo.local', '0400000002', true),
  ('00000000-0000-4000-8000-0000000000d3', 'Liisa Vuoro',         'liisa@example.com',  '0400000003', true),
  ('00000000-0000-4000-8000-0000000000d4', 'Matti Mallivuoro',    'matti@example.com',  '0400000004', true),
  ('00000000-0000-4000-8000-0000000000d5', 'Entinen Eero',        'eero@example.com',   '0400000005', false)
on conflict do nothing;
insert into public.calendar_sources (id, calendar_name) values
  ('00000000-0000-4000-8000-0000000000b1', 'Hoitaja'), ('00000000-0000-4000-8000-0000000000b2', 'Vastaanotto'), ('00000000-0000-4000-8000-0000000000b3', 'Lämmitykset')
on conflict do nothing;
do $$
declare
  d0 date := (now() at time zone 'Europe/Helsinki')::date; i int; d date; dow int; sid uuid;
  pids uuid[] := array['00000000-0000-4000-8000-0000000000d1','00000000-0000-4000-8000-0000000000d2','00000000-0000-4000-8000-0000000000d3','00000000-0000-4000-8000-0000000000d4']::uuid[];
begin
  for i in -10..45 loop
    d := d0 + i; dow := extract(isodow from d)::int;
    if dow in (1, 2) then continue; end if;                       -- ma–ti ei vuoroja
    -- saunottajan vuoro (to–su), kolmena iltana kaksi saunottajaa
    insert into public.work_shifts (calendar_source_id, starts_at, ends_at, role_type, status, staffing_status, notes)
      values ('00000000-0000-4000-8000-0000000000b1', ((d::timestamp + time '13:30') at time zone 'Europe/Helsinki'), ((d::timestamp + time '19:00') at time zone 'Europe/Helsinki'), 'therapist', 'active', case when i % 7 = 3 then 'unassigned' else 'assigned' end, 'demo-muistiinpano (ei saa näkyä)')
      returning id into sid;
    if i % 7 <> 3 then insert into public.shift_assignments (shift_id, staff_id) values (sid, pids[1 + (i + 14) % 4]); end if;
    if dow >= 5 then insert into public.shift_assignments (shift_id, staff_id) values (sid, pids[1 + (i + 15) % 4]); end if;
    -- lämmittäjä aamuvuorossa (to–su), kuten tuotannossa: role_type heater, kalenterin nimi Lämmitykset
    insert into public.work_shifts (calendar_source_id, starts_at, ends_at, role_type, status, staffing_status)
      values ('00000000-0000-4000-8000-0000000000b3', ((d::timestamp + time '08:00') at time zone 'Europe/Helsinki'), ((d::timestamp + time '13:30') at time zone 'Europe/Helsinki'), 'heater', 'active', 'assigned') returning id into sid;
    insert into public.shift_assignments (shift_id, staff_id) values (sid, pids[1 + (i + 16) % 4]);
    -- vastaanotto lauantaisin
    if dow = 6 then
      insert into public.work_shifts (calendar_source_id, starts_at, ends_at, role_type, status, staffing_status)
        values ('00000000-0000-4000-8000-0000000000b2', ((d::timestamp + time '13:00') at time zone 'Europe/Helsinki'), ((d::timestamp + time '18:30') at time zone 'Europe/Helsinki'), 'reception', 'active', 'assigned') returning id into sid;
      insert into public.shift_assignments (shift_id, staff_id) values (sid, '00000000-0000-4000-8000-0000000000d3');
      -- illan lisäsaunottaja ilman nimettyä tekijää (hallinnan kalenterissa näkyy ilmoitus "Ei nimettyä tekijää")
      insert into public.work_shifts (calendar_source_id, starts_at, ends_at, role_type, status, staffing_status)
        values ('00000000-0000-4000-8000-0000000000b1', ((d::timestamp + time '19:00') at time zone 'Europe/Helsinki'), ((d::timestamp + time '21:00') at time zone 'Europe/Helsinki'), 'therapist', 'active', 'unassigned');
    end if;
    -- yksi peruttu vuoro (ei saa näkyä)
    if i = 12 then insert into public.work_shifts (calendar_source_id, starts_at, ends_at, role_type, status, staffing_status) values ('00000000-0000-4000-8000-0000000000b1', ((d::timestamp + time '10:00') at time zone 'Europe/Helsinki'), ((d::timestamp + time '12:00') at time zone 'Europe/Helsinki'), 'therapist', 'cancelled', 'assigned'); end if;
  end loop;
end $$;
update booking.staff set public_staff_id = '00000000-0000-4000-8000-0000000000d0' where user_id = '00000000-0000-4000-8000-0000000000a1';
update booking.staff set public_staff_id = '00000000-0000-4000-8000-0000000000d1' where user_id = '00000000-0000-4000-8000-0000000000b2';
update booking.staff set public_staff_id = '00000000-0000-4000-8000-0000000000d2' where user_id = '00000000-0000-4000-8000-0000000000c3';

-- saunottajaroolit (migraatio 16 lukee public.staff_roles-taulusta role_type = 'therapist'; tuotannossa Työvuoro-Tapio)
insert into public.staff_roles (staff_id, role_type, active)
  select id, 'therapist', true from public.staff
   where id in ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-4000-8000-0000000000d2', '00000000-0000-4000-8000-0000000000d3', '00000000-0000-4000-8000-0000000000d4');

-- Kaupan e2e-testit tarvitsevat päivän, jolla mikään tuote ei ole varattavissa ("tyhjä päivä" + ehdotus seuraavasta vapaasta päivästä).
-- Ennen tämä riippui kellonajasta (illalla "tänään" oli tyhjä). Nyt kiinteä: savusauna suljettu koko päivän (siivous/huolto) keskiviikkona viikon päästä ensi maanantaista (mon+9, 10–16 pv päässä;
-- e2e-screenshots käyttää ensi maanantaita ja mon+8 (tiistai) manuaaliseen varaukseen, joten ne eivät osu sulkuun).
do $$
declare t date := (now() at time zone 'Europe/Helsinki')::date; d date; res jsonb;
begin
  d := t + (case when extract(isodow from t)::int = 1 then 7 else 8 - extract(isodow from t)::int end) + 9;   -- ensi maanantai (ei tänään) + 9 pv
  perform set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-0000000000a1", "role": "authenticated"}', true);
  res := booking.admin_create_block((select id from booking.resources where code = 'savusauna'),
           (d::timestamp at time zone 'Europe/Helsinki'), ((d + 1)::timestamp at time zone 'Europe/Helsinki'), 'Demo: savusauna suljettu koko päivän');
  if not coalesce((res ->> 'ok')::boolean, false) then raise exception 'demo-sulun luonti epäonnistui: %', res; end if;
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------- resurssivaraukset (migraatio 17): hoitoja/rituaali (Rauni + saunottajaleg), vanha varaus ja ylitys ----------
-- Tehdään admin-funktioilla (sama polku kuin hallinnassa). Päivät: tuleva lauantai/sunnuntai (saunottajavuorot yllä), ylitys tiistaina ilman vuoroja (mon+15).
insert into booking.customers (name, email, phone, customer_type) values ('Hoito Hanna', 'hanna@example.com', '0401230001', 'customer');
do $$
declare
  t date := (now() at time zone 'Europe/Helsinki')::date;
  c bigint := (select id from booking.customers where email = 'hanna@example.com');
  sat date := (t + 3) + ((6 - extract(isodow from t + 3)::int + 7) % 7);
  mon date := t + (case when extract(isodow from t)::int = 1 then 7 else 8 - extract(isodow from t)::int end);
  b record; res jsonb;
begin
  perform set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-0000000000a1", "role": "authenticated"}', true);
  for b in
    select * from (values
      (10, (sat + time '15:00'), 1, false, null::text), (10, (sat + time '16:15'), 1, false, null),
      (8,  (sat + time '17:30'), 2, false, null),
      (16, (sat + 1 + time '14:00'), 1, true, null),
      (10, (mon + 15 + time '12:00'), 1, false, 'Demo: ylitys – ei saunottajan vuoroa, sovittu erikseen')) x(pid, a, n, old, why)
  loop
    if b.old then
      res := booking.admin_create_old_booking(b.pid, b.a at time zone 'Europe/Helsinki', b.n, c, null, null, null, 'pay_later', false, 'Demo: vanha varaus');
    else
      res := booking.admin_create_resource_booking(b.pid, b.a at time zone 'Europe/Helsinki', b.n, c, null, null, null, 'pay_later', false, 'Demo: resurssivaraus',
               null, b.why is not null, b.why);
    end if;
    if res ->> 'reservation_id' is null then raise exception 'demo-resurssivarauksen luonti epäonnistui: %', res; end if;
  end loop;
  perform set_config('request.jwt.claims', '', true);
end $$;
-- Tuotekuvat (migraatio 14): demokuvat tiedostoista booking/dev/demo-images/products (dev-palvelin tarjoaa ne Storage-mockin kautta).
-- Hiljainen sauna, turvetorstai, tunnin vuoro ja yritystuotteet jätetään tahallaan ilman kuvaa (kuvaton tila näkyy kaupassa ja testeissä).
update booking.product_config set image_path = 'products/1-demo01xx.webp',  image_alt = 'Savusaunan lauteet ja kiuas' where product_id = 1;
update booking.product_config set image_path = 'products/2-demo02xx.webp'  where product_id = 2;
update booking.product_config set image_path = 'products/3-demo03xx.webp',  image_alt = 'Naisten saunavuoro' where product_id = 3;
update booking.product_config set image_path = 'products/25-demo25xx.webp' where product_id = 25;

-- ---------- sulkukalenterit (migraatio 18) ----------
-- Tuotannossa kalenterit ovat active=false eikä synkkaa ole käynnissä; demossa hoidot ja savusauna on merkitty käyttöön (keinotekoinen kalenteritunnus), jotta Kalenterisulut-näkymässä
-- on tapahtumia, ohitus, konflikti ja ajoloki. rauni ja perinnesaunotus jäävät käyttämättömiksi (näkymän "Ei käytössä" -tila). Tapahtumat kirjataan suoraan kirjanpitoon
-- ja sulut luodaan samalla täsmäytysfunktiolla kuin synkka (_reconcile_closure_blocks). Päivät ensi maanantaista (mon+3 = torstai; mon+15 = tiistai, jolla on ylitysvaraus).
do $$
declare
  t date := (now() at time zone 'Europe/Helsinki')::date;
  mon date := t + (case when extract(isodow from t)::int = 1 then 7 else 8 - extract(isodow from t)::int end);
  hk bigint; res jsonb;
  ts_ constant text := 'Europe/Helsinki';
begin
  update booking.closure_calendars set google_calendar_id = 'demo-' || code || '@group.calendar.google.com', active = true where code in ('hoidot', 'savusauna');
  insert into booking.closure_events(calendar_code, external_id, class, reason, all_day, starts_at, ends_at, content_hash, override, override_note)
  values
    ('savusauna', 'demo-s1', 'closure', 'Huolto', false, (mon + 3 + time '08:00') at time zone ts_, (mon + 3 + time '12:00') at time zone ts_, md5('s1'), null, null),
    ('savusauna', 'demo-s2', 'closure', 'Savusauna kiinni (talkoot)', true, (mon + 11)::timestamp at time zone ts_, (mon + 12)::timestamp at time zone ts_, md5('s2'), null, null),
    ('savusauna', 'demo-s3', 'rough', 'Pitkä huoltojakso', false, (mon + 20 + time '08:00') at time zone ts_, (mon + 30 + time '19:00') at time zone ts_, md5('s3'), null, null),
    ('hoidot', 'demo-h1', 'closure', 'Hoidot kiinni', false, (mon + 15 + time '11:00') at time zone ts_, (mon + 15 + time '14:00') at time zone ts_, md5('h1'), null, null),
    ('hoidot', 'demo-h2', 'closure', 'Hoidot kiinni (ilta)', false, (mon + 17 + time '16:00') at time zone ts_, (mon + 17 + time '20:00') at time zone ts_, md5('h2'), 'ignore', 'Hoitaja löytyi, hoidot avoinna');
  perform booking._reconcile_closure_blocks('savusauna');
  perform booking._reconcile_closure_blocks('hoidot');
  insert into booking.closure_sync_runs(calendar_code, started_at, outcome, stats, error, source) values
    ('savusauna', now() - interval '40 minutes', 'ok', '{"events_seen":9,"candidates":3,"inserted":0,"updated":0,"deleted":0,"rough":1,"ignored_mirror":4,"ignored_training":1,"conflicting_reservations":0}', null, 'demo'),
    ('hoidot', now() - interval '35 minutes', 'ok', '{"events_seen":4,"candidates":2,"inserted":0,"updated":0,"deleted":0,"rough":0,"ignored_mirror":0,"ignored_training":1,"conflicting_reservations":1}', null, 'demo'),
    ('hoidot', now() - interval '2 days', 'error', null, 'Google Calendar API: 503 (demo)', 'demo');
  update booking.closure_calendars set last_attempt_at = now() - interval '35 minutes', last_success_at = now() - interval '35 minutes', last_stats = '{"events_seen":4,"candidates":2,"conflicting_reservations":1}' where code = 'hoidot';
  update booking.closure_calendars set last_attempt_at = now() - interval '40 minutes', last_success_at = now() - interval '40 minutes', last_stats = '{"events_seen":9,"candidates":3,"rough":1}' where code = 'savusauna';
  -- käsin tehty Laura-sulku (koulutus): muokattava, ei kalenterisulku
  perform set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-0000000000a1", "role": "authenticated"}', true);
  res := booking.admin_create_block((select id from booking.resources where code = 'laura'), (mon + 22 + time '09:00') at time zone ts_, (mon + 22 + time '16:00') at time zone ts_, 'Koulutus (käsin tehty)');
  if not coalesce((res ->> 'ok')::boolean, false) then raise exception 'demo-Laura-sulun luonti epäonnistui: %', res; end if;
  perform set_config('request.jwt.claims', '', true);
end $$;
