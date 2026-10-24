-- t148: jonotuslistan henkilömäärä palvelutyypin mukaan (booking_148).
-- a) yleinen vuoro (Miesten sauna ma, mode shared): 1–6 ennallaan, 7 / 0 / null = invalid_persons
-- b) yksityisvuoro (Oma savusaunavuoro pe 16–21, mode exclusive): varattu vuoro on julkisesti 'full' ja jonotettava ilman
--    henkilömäärää (p_persons ohitetaan, tallennetaan 1); vapautus ≥ 48 h → pito ensimmäiselle (koko tila pois myynnistä),
--    haltija lunastaa ja varaa millä tahansa henkilömäärällä; alle 48 h → kaikki saavat ilmoituksen ilman pitoa;
--    vapaa tai suljettu (space_blocks) yksityisvuoro ei ole jonotettava; viestissä ei henkilömäärää
-- c) tapahtuma (kb.products.category = 'event'): 1..kapasiteetti (pienin vuoron max, product_config.max, poolin capacity),
--    yli kapasiteetin = invalid_persons; mahtuvuus kuten yleisessä
-- "≥ 48 h" / "< 48 h" simuloidaan asetuksella waitlist_hold_min_hours_before kuten t137/t139.
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN. Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken.
-- Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t148_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t148_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.st(p_email text) returns text language sql as $$ select status from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.pers(p_email text) returns int language sql as $$ select persons from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.held(p_email text) returns boolean language sql as $$
  select status = 'notified' and coalesce(hold_expires_at > now(), false) from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.rid(p_email text) returns bigint language sql as $$
  select r.id from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = p_email order by r.id limit 1 $$;
create function pg_temp.join(p_rule bigint, p_date date, p_persons int, p_email text) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(); j := booking.public_join_waitlist(p_rule, p_date, p_persons, 'Jono ' || p_email, p_email); perform test.logout(); return j; end $$;
create function pg_temp.claim(p_token text) returns jsonb language plpgsql as $$
declare c jsonb; begin perform test.anon(); c := booking.public_waitlist_claim(p_token::uuid); perform test.logout(); return c; end $$;
-- Julkinen tila anonina: tuotteen haku ja kuukauden kaikki tuotteet (booking_133) täsmäävät.
create function pg_temp.pub_status(p_rule bigint, p_date date) returns text language plpgsql as $$
declare v_p bigint; a text; b text; begin
  select product_id into v_p from booking.schedule_rules where id = p_rule;
  perform test.anon();
  select status into a from booking.public_availability(v_p, p_date, p_date) where rule_id = p_rule;
  select status into b from booking.public_availability_all(p_date, p_date, 'consumer') where rule_id = p_rule;
  perform test.logout();
  if a is distinct from b then return 'mismatch:' || coalesce(a, '-') || '/' || coalesce(b, '-'); end if;
  return a; end $$;
create function pg_temp.hrs(p_rule bigint, p_date date) returns int language sql as $$
  select floor(extract(epoch from s.starts_at - now()) / 3600)::int from booking._sessions(p_date, p_date, null, true) s where s.rule_id = p_rule limit 1 $$;
create function pg_temp.hold_hours(p_h int) returns void language sql as $$
  insert into booking.settings(key, value) values ('waitlist_hold_min_hours_before', to_jsonb(p_h)) on conflict (key) do update set value = excluded.value $$;
create function pg_temp.mail(p_email text) returns jsonb language sql as $$
  select payload from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = p_email order by id desc limit 1 $$;
do $t$
declare
  v_gen bigint := test.rule('Miesten sauna%');
  v_wkd bigint := test.rule('Yleinen vuoro la–su 14:00%');
  v_tunti bigint := test.rule('Tunnin saunavuoro la–su 14:00%');
  v_priv bigint := test.rule('Oma savusaunavuoro pe 16–21%');
  v_priv2 bigint := test.rule('Oma savusaunavuoro ma–pe 16–19%');
  v_ev bigint; v_pool bigint;
  dg date := test.next_dow(1) + 84;
  dp1 date := test.next_dow(5) + 84; dp2 date := test.next_dow(5) + 91; dp3 date := test.next_dow(5) + 98; dp4 date := test.next_dow(5) + 105;
  de date := test.next_dow(5) + 112;
  b jsonb; j jsonb; ja jsonb; jb jsonb; c jsonb; m jsonb; v jsonb; p record; v_staff uuid;
begin
  perform booking.public_join_waitlist(v_gen, dg, 1, 'x', 'x');   -- lämmittely: rate limit -avain ei kaada

  -- ===== palvelutyypin tunnistus (booking._waitlist_party) =====
  select * into p from booking._waitlist_party(v_gen);
  perform pg_temp.ck(p.kind = 'general' and p.min_persons = 1 and p.max_persons = 6, 'T1: Miesten sauna = general 1–6 (vuoron max 16 rajataan kuuteen)');
  select * into p from booking._waitlist_party(v_wkd);
  perform pg_temp.ck(p.kind = 'general' and p.max_persons = 6, 'T2: viikonlopun yleinen vuoro = general 1–6');
  select * into p from booking._waitlist_party(v_tunti);
  perform pg_temp.ck(p.kind = 'general' and p.max_persons = 6, 'T3: tunnin saunavuoro (max 10) = general 1–6');
  select * into p from booking._waitlist_party(v_priv);
  perform pg_temp.ck(p.kind = 'private' and p.min_persons is null and p.max_persons is null, 'T4: oma savusaunavuoro (exclusive) = private ilman henkilömäärää');
  select * into p from booking._waitlist_party(test.rule('Savusaunavuoro yrityksille pe 16–21%'));
  perform pg_temp.ck(p.kind = 'private', 'T5: yritysten savusaunavuoro (exclusive) = private');

  -- ===== a) yleinen vuoro 1–6 =====
  b := test.pub_book(v_gen, dg, 16, 'taysi@t148.example');
  perform pg_temp.ck(pg_temp.pub_status(v_gen, dg) = 'full', 'A1: Miesten sauna täynnä');
  j := pg_temp.join(v_gen, dg, 6, 'g6@t148.example');
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'persons')::int = 6 and j ->> 'kind' = 'general' and pg_temp.pers('g6@t148.example') = 6, 'A2: yleinen 6 hlö ok');
  j := pg_temp.join(v_gen, dg, 1, 'g1@t148.example');
  perform pg_temp.ck((j ->> 'ok')::boolean and pg_temp.pers('g1@t148.example') = 1, 'A3: yleinen 1 hlö ok');
  j := pg_temp.join(v_gen, dg, 7, 'g7@t148.example');
  perform pg_temp.ck(not (j ->> 'ok')::boolean and j ->> 'code' = 'invalid_persons' and (j ->> 'max')::int = 6 and j ->> 'kind' = 'general'
    and pg_temp.st('g7@t148.example') is null, 'A4: yleinen 7 hlö = invalid_persons (max 6)');
  j := pg_temp.join(v_gen, dg, 0, 'g0@t148.example');
  perform pg_temp.ck(j ->> 'code' = 'invalid_persons', 'A5: yleinen 0 hlö = invalid_persons');
  j := pg_temp.join(v_gen, dg, null, 'gn@t148.example');
  perform pg_temp.ck(j ->> 'code' = 'invalid_persons', 'A6: yleinen ilman henkilömäärää = invalid_persons');

  -- ===== b) yksityisvuoro =====
  perform test.anon(); j := booking.public_join_waitlist(v_priv, dp1, null, 'Jono vapaa', 'vapaa@t148.example'); perform test.logout();
  perform pg_temp.ck(pg_temp.pub_status(v_priv, dp1) = 'available' and j ->> 'code' = 'not_full', 'B1: vapaa yksityisvuoro ei ole jonotettava (not_full)');
  b := test.pub_book(v_priv, dp1, 4, 'omistaja1@t148.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'B2: yksityisvuoro pe 16–21 varattu');
  perform pg_temp.ck(pg_temp.pub_status(v_priv, dp1) = 'full' and pg_temp.pub_status(v_priv2, dp1) = 'full',
    'B3: varattu yksityisvuoro ja päällekkäinen yksityisvuoro (pe 16–19) julkisesti full (jonotettava)');
  perform pg_temp.ck((select s.status from booking._sessions(dp1, dp1, null, true) s where s.rule_id = v_priv) = 'unavailable',
    'B4: sisäinen _sessions ennallaan (admin-näkymä ei muutu)');
  ja := pg_temp.join(v_priv, dp1, null, 'pa@t148.example');
  perform pg_temp.ck((ja ->> 'ok')::boolean and ja ->> 'kind' = 'private' and ja -> 'persons' = 'null'::jsonb and pg_temp.pers('pa@t148.example') = 1,
    'B5: yksityisvuoroon jonotus ilman henkilömäärää: tallennetaan 1, vastaus persons null');
  jb := pg_temp.join(v_priv, dp1, 99, 'pb@t148.example');
  perform pg_temp.ck((jb ->> 'ok')::boolean and pg_temp.pers('pb@t148.example') = 1, 'B6: yksityisvuorossa annettu henkilömäärä ohitetaan (99 → 1)');
  j := pg_temp.join(v_priv2, dp1, null, 'pc@t148.example');
  perform pg_temp.ck((j ->> 'ok')::boolean, 'B7: päällekkäiseen yksityisvuoroon (pe 16–19) voi jonottaa');
  perform pg_temp.hold_hours(pg_temp.hrs(v_priv, dp1) - 1);   -- vuoroon yli pitorajan
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('omistaja1@t148.example');
  perform pg_temp.ck(pg_temp.held('pa@t148.example') and pg_temp.st('pb@t148.example') = 'waiting',
    'B8: vapautus ≥ 48 h: ensimmäinen jonottaja pitoon (mahtuu aina), toinen odottaa');
  perform pg_temp.ck(pg_temp.st('pc@t148.example') = 'waiting', 'B9: päällekkäisen yksityisvuoron jonottaja ei saa pidettyä tilaa');
  perform pg_temp.ck(pg_temp.pub_status(v_priv, dp1) = 'full' and pg_temp.pub_status(v_priv2, dp1) = 'full',
    'B10: pidon aikana yksityisvuoro ei ole julkisessa myynnissä (full)');
  b := test.pub_book(v_priv, dp1, 2, 'muu1@t148.example');
  perform pg_temp.ck(not (b ->> 'ok')::boolean and b ->> 'code' = 'private_booked', 'B11: muu asiakas ei voi varata pidettyä yksityisvuoroa');
  b := test.pub_book(v_priv2, dp1, 2, 'muu2@t148.example');
  perform pg_temp.ck(not (b ->> 'ok')::boolean, 'B12: päällekkäistä yksityisvuoroa ei voi varata pidon aikana');
  m := pg_temp.mail('pa@t148.example');
  perform pg_temp.ck(m is not null and m -> 'persons' = 'null'::jsonb and m ->> 'book_url' not like '%n=%' and m ->> 'book_url' like '%?wl=%',
    'B13: ilmoitusviestissä ja varauslinkissä ei henkilömäärää');
  c := pg_temp.claim(ja ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and (c ->> 'enough')::boolean and c ->> 'kind' = 'private', 'B14: haltijan lunastus: vuoro vapaa hänelle (kind private)');
  c := pg_temp.claim(jb ->> 'token');
  perform pg_temp.ck((c ->> 'ok')::boolean and not (c ->> 'enough')::boolean, 'B15: toisen jonottajan lunastus: ei vapaana (pidossa)');
  b := test.pub_book(v_priv, dp1, 10, 'pa@t148.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'B16: haltija varaa yksityisvuoron millä tahansa henkilömäärällä (10)');
  set constraints all immediate; set constraints all deferred;
  perform pg_temp.ck(pg_temp.st('pa@t148.example') = 'booked' and pg_temp.pub_status(v_priv, dp1) = 'full', 'B17: varaus → jonovaraus booked, vuoro taas full');

  -- alle 48 h: kaikki saavat ilmoituksen ilman pitoa, ensimmäinen varaaja voittaa
  b := test.pub_book(v_priv, dp2, 4, 'omistaja2@t148.example');
  j := pg_temp.join(v_priv, dp2, null, 'qa@t148.example'); j := pg_temp.join(v_priv, dp2, null, 'qb@t148.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_priv, dp2) + 1);   -- vuoroon alle pitorajan
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('omistaja2@t148.example');
  perform pg_temp.ck(pg_temp.st('qa@t148.example') = 'notified' and pg_temp.st('qb@t148.example') = 'notified'
    and not pg_temp.held('qa@t148.example') and not pg_temp.held('qb@t148.example'), 'B18: alle 48 h: molemmat ilmoitetaan ilman pitoa');
  perform pg_temp.ck(pg_temp.pub_status(v_priv, dp2) = 'available', 'B19: alle 48 h: vuoro heti julkisesti myynnissä');
  b := test.pub_book(v_priv, dp2, 3, 'qb@t148.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'B20: jonottaja varaa vapautuneen yksityisvuoron');

  -- pidon vanheneminen: sweep ilmoittaa muille ilman pitoa
  b := test.pub_book(v_priv, dp3, 4, 'omistaja3@t148.example');
  j := pg_temp.join(v_priv, dp3, null, 'ra@t148.example'); j := pg_temp.join(v_priv, dp3, null, 'rb@t148.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_priv, dp3) - 1);
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('omistaja3@t148.example');
  perform pg_temp.ck(pg_temp.held('ra@t148.example') and pg_temp.st('rb@t148.example') = 'waiting', 'B21: pito ensimmäiselle');
  update booking.waitlist_entries set notified_at = now() - interval '121 minutes', hold_expires_at = now() - interval '1 minute' where customer_email = 'ra@t148.example';
  perform pg_temp.ck(pg_temp.pub_status(v_priv, dp3) = 'available', 'B22: pito vanheni → yksityisvuoro heti myynnissä');
  perform booking.waitlist_sweep();
  perform pg_temp.ck(pg_temp.st('rb@t148.example') = 'notified' and not pg_temp.held('rb@t148.example'), 'B23: sweep ilmoittaa seuraavalle ilman pitoa');

  -- henkilökunta ohittaa pidon
  b := test.pub_book(v_priv, dp4, 4, 'omistaja4@t148.example');
  j := pg_temp.join(v_priv, dp4, null, 'sa@t148.example');
  perform pg_temp.hold_hours(pg_temp.hrs(v_priv, dp4) - 1);
  update booking.reservations set status = 'cancelled' where id = pg_temp.rid('omistaja4@t148.example');
  perform pg_temp.ck(pg_temp.held('sa@t148.example'), 'B24: pito');
  v_staff := test.mk_staff('staff@t148.example', 'admin');
  perform test.login(v_staff);
  v := booking.admin_day_view(dp4);
  b := booking.admin_create_booking(v_priv, dp4, 6, null, '{"kind":"private","name":"Puhelin Asiakas","email":"puhelin@t148.example","phone":"0401234567"}'::jsonb);
  perform test.logout();
  perform pg_temp.ck((select s ->> 'status' from jsonb_array_elements(v -> 'sessions') s where (s ->> 'rule_id')::bigint = v_priv) = 'available'
    and jsonb_array_length(v -> 'waitlist_holds') = 1, 'B25: henkilökunta näkee pidetyn yksityisvuoron vapaana ja pidon');
  perform pg_temp.ck(b ? 'order_id' or coalesce((b ->> 'ok')::boolean, false), 'B26: henkilökunta voi varata pidetyn yksityisvuoron');

  -- suljettu (space_blocks) yksityisvuoro ei ole jonotettava, vaikka tila olisi varattu
  insert into booking.space_blocks(space_id, starts_at, ends_at, active, reason)
    select 1, s.starts_at, s.ends_at, true, 't148' from booking._sessions(dp2, dp2, null, true) s where s.rule_id = v_priv;
  perform pg_temp.ck(pg_temp.pub_status(v_priv, dp2) = 'unavailable', 'B27: sulku → unavailable (ei full)');
  j := pg_temp.join(v_priv, dp2, null, 'ta@t148.example');
  perform pg_temp.ck(j ->> 'code' = 'not_full', 'B28: suljettuun yksityisvuoroon ei voi jonottaa');

  -- ===== c) tapahtuma: kapasiteetti 12 (vuoron max, product_config.max ja pooli) =====
  update booking.product_config set bookable = true, shop_visible = true, max_persons = 12, required_skill = null
   where product_id = 32;
  insert into booking.resources(code, name, kind, parent_id, capacity, active) values ('t148_event', 'T148 tapahtuma', 'capacity_pool', 1, 12, true)
    returning id into v_pool;
  insert into booking.schedule_rules(product_id, label, mode, space_id, weekdays, start_time, duration_minutes, min_persons, max_persons, price_mode, deadline_minutes, active)
    values (32, 'T148 tapahtuma pe 9–11', 'shared', 1, '{5}', '09:00', 120, 1, 12, 'per_person', 0, true) returning id into v_ev;
  insert into booking.schedule_rule_pools(rule_id, pool_id) values (v_ev, v_pool);
  select * into p from booking._waitlist_party(v_ev);
  perform pg_temp.ck(p.kind = 'event' and p.min_persons = 1 and p.max_persons = 12, 'C1: tapahtuma tunnistetaan (category event), raja 1–12');
  b := test.pub_book(v_ev, de, 12, 'eventtaysi@t148.example');
  perform pg_temp.ck((b ->> 'ok')::boolean and pg_temp.pub_status(v_ev, de) = 'full', 'C2: tapahtuma täynnä (12/12)');
  j := pg_temp.join(v_ev, de, 12, 'e12@t148.example');
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'kind' = 'event' and pg_temp.pers('e12@t148.example') = 12, 'C3: tapahtumaan 12 hlö (= kapasiteetti) ok');
  j := pg_temp.join(v_ev, de, 8, 'e8@t148.example');
  perform pg_temp.ck((j ->> 'ok')::boolean and pg_temp.pers('e8@t148.example') = 8, 'C4: tapahtumaan 8 hlö (> 6) ok');
  j := pg_temp.join(v_ev, de, 13, 'e13@t148.example');
  perform pg_temp.ck(not (j ->> 'ok')::boolean and j ->> 'code' = 'invalid_persons' and (j ->> 'max')::int = 12 and pg_temp.st('e13@t148.example') is null,
    'C5: tapahtumaan 13 hlö (yli kapasiteetin) = invalid_persons');
  j := pg_temp.join(v_ev, de, 0, 'e0@t148.example');
  perform pg_temp.ck(j ->> 'code' = 'invalid_persons', 'C6: tapahtumaan 0 hlö = invalid_persons');
  update booking.resources set capacity = 10 where id = v_pool;
  select * into p from booking._waitlist_party(v_ev);
  perform pg_temp.ck(p.max_persons = 10, 'C7: poolin pienempi kapasiteetti rajaa (10)');
  update booking.resources set capacity = 12 where id = v_pool;
  update booking.product_config set max_persons = 9 where product_id = 32;
  select * into p from booking._waitlist_party(v_ev);
  perform pg_temp.ck(p.max_persons = 9, 'C8: product_config.max_persons rajaa (9)');
  update booking.product_config set max_persons = 12 where product_id = 32;
  -- mahtuvuus kuten yleisessä: 8 vapautuu → 12 hengen jonottaja ei mahdu, 8 hengen mahtuu (alle 48 h)
  perform pg_temp.hold_hours(pg_temp.hrs(v_ev, de) + 1);
  update booking.reservations set persons = 4 where id = pg_temp.rid('eventtaysi@t148.example');
  perform booking.waitlist_sweep();
  perform pg_temp.ck(pg_temp.st('e12@t148.example') = 'waiting' and pg_temp.st('e8@t148.example') = 'notified', 'C9: tapahtuma: 8 vapaata → 8 hlö ilmoitetaan, 12 hlö odottaa');
  m := pg_temp.mail('e8@t148.example');
  perform pg_temp.ck((m ->> 'persons')::int = 8 and m ->> 'book_url' like '%?n=8&wl=%', 'C10: tapahtuman viestissä henkilömäärä');

  -- ===== tekniset =====
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._waitlist_party(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking._waitlist_private_taken(bigint,timestamptz,timestamptz)', 'execute'), 'X1: apufunktiot eivät asiakkaille');
  perform pg_temp.ck(coalesce(current_setting('booking.waitlist_hold_exempt', true), '') = '', 'X2: poikkeusasetus ei jää päälle');

  declare v_pass int; v_fail int; v_list text; begin
    select count(*) filter (where ok), count(*) filter (where not ok), string_agg(case when not ok then label end, ' | ') into v_pass, v_fail, v_list from t148_r;
    raise exception 'TESTRESULT pass=% fail=% :: %', v_pass, v_fail, coalesce(v_list, 'ALL OK');
  end;
end $t$;
