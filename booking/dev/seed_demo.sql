-- Demo-data paikalliseen kehitykseen (EI tuotantoon): keksittyjä asiakkaita (@example.com), ei oikeita henkilötietoja.
-- Aja migraatioiden jälkeen. Luo kolme demo-käyttäjää (admin@demo.local = admin, manager@demo.local = manager/ylläpitäjä, staff@demo.local = staff/peruskäyttäjä; salasana: demo),
-- vuosikorttiasiakkaan (vuosikortti@example.com) vuosikorttivarauksineen ja esimerkkivarauksia.
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000000a1', 'admin@demo.local'),
  ('00000000-0000-4000-8000-0000000000b2', 'staff@demo.local'),
  ('00000000-0000-4000-8000-0000000000c3', 'manager@demo.local')
on conflict do nothing;
insert into booking.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000a1', 'Demo Admin', 'admin'),
  ('00000000-0000-4000-8000-0000000000c3', 'Demo Ylläpitäjä (manager)', 'manager'),
  ('00000000-0000-4000-8000-0000000000b2', 'Demo Peruskäyttäjä (staff)', 'staff')
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
      (1, 'Miesten sauna%', 9, 1), (1, 'Miesten sauna%', 7, 1),
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
