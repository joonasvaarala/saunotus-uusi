-- t289: booking_289 (public_availability nopeutus) palauttaa täsmälleen saman tuloksen kuin booking_269:n määritys.
-- Vertailu: asennetaan vanha määritys (rollbacks/..._289_ROLLBACK.sql = booking_269), otetaan tulokset talteen usealla tuotteella,
-- aikavälillä ja tilanteella (perustila / yksityisvaraus + sulku + hoitajapula + koulutusvaihtoehto), asennetaan uusi (migraatio 289)
-- ja verrataan rivi riviltä (myös järjestys). Tulostaa TAP-rivit (ok / not ok); ei vaadi pgTAPia.
-- Ajo (migraatiot ajettu, superuser):  psql -X -v ON_ERROR_STOP=1 -d <testikanta> -f t289_availability_equivalence.sql
-- Lopun rollback kumoaa kaiken (myös funktiomääritysten vaihdon).
begin;
set local session_replication_role = replica;   -- testidatan suorat insertit ilman laukaisimia
create temp table r289(n serial, ok boolean, label text);
create temp table scen(id serial primary key, state text, product_id bigint, d_from date, d_to date);
create temp table snap(version text, state text, scen_id int, ord bigint, rule_id bigint, label text, mode text, session_date date,
  starts_at timestamptz, ends_at timestamptz, status text, remaining int, min_persons int, max_persons int, price_mode text,
  unit_price numeric, base_price numeric, included_persons int, extra_person_price numeric, label_en text);

create function pg_temp.take(p_version text, p_state text) returns void language plpgsql as $$
begin
  insert into snap
  select p_version, p_state, s.id, a.ord, a.rule_id, a.label, a.mode, a.session_date, a.starts_at, a.ends_at, a.status, a.remaining,
         a.min_persons, a.max_persons, a.price_mode, a.unit_price, a.base_price, a.included_persons, a.extra_person_price, a.label_en
    from scen s
    cross join lateral booking.public_availability(s.product_id, s.d_from, s.d_to) with ordinality as a(rule_id, label, mode, session_date,
      starts_at, ends_at, status, remaining, min_persons, max_persons, price_mode, unit_price, base_price, included_persons,
      extra_person_price, label_en, ord)
   where s.state = p_state;
end $$;

-- tilanteet x tuotteet x aikavälit (kaikki aktiiviset tuotteet, joten myös ei-varattavat ja ilman sääntöjä olevat)
insert into scen(state, product_id, d_from, d_to)
select st.s, p.id, r.f, r.t
  from (values ('base'), ('busy')) st(s)
  cross join (select id from kb.products where active) p
  cross join (values (current_date, current_date + 30), (current_date + 1, current_date + 1), (current_date - 5, current_date + 10),
                     (current_date + 100, current_date + 190), (current_date, current_date + 92)) r(f, t);

-- 1) vanha määritys (booking_269), perustila
\ir ../rollbacks/20261113064837_booking_289_ROLLBACK.sql
select pg_temp.take('old', 'base');

-- 2) uusi määritys, perustila
\ir ../migrations/20261113064837_booking_289_availability_speedup.sql
select pg_temp.take('new', 'base');

-- tilanne "busy": yksityisvaraus, tilasulku, hoitajapula ja koulutusvaihtoehto
do $$
declare v_order bigint; v_rule record; v_d date; v_sp bigint; v_first bigint; v_second bigint;
begin
  insert into booking.orders default values returning id into v_order;
  -- 1) exclusive-varaus: ensimmäinen exclusive-sääntö, seuraava sen viikonpäivä
  select r.* into v_rule from booking.schedule_rules r where r.active and r.mode = 'exclusive' order by r.id limit 1;
  if v_rule.id is not null then
    select g::date into v_d from generate_series(current_date + 2, current_date + 20, interval '1 day') g
     where extract(isodow from g)::int = any (v_rule.weekdays) limit 1;
    insert into booking.reservations(order_id, product_id, rule_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status)
    values (v_order, v_rule.product_id, v_rule.id, v_rule.space_id, 'exclusive',
            (v_d + v_rule.start_time) at time zone 'Europe/Helsinki',
            (v_d + v_rule.start_time + make_interval(mins => v_rule.duration_minutes)) at time zone 'Europe/Helsinki', 2, '{}', 'confirmed')
    on conflict do nothing;
    -- 2) tilasulku seuraavalle päivälle
    insert into booking.space_blocks(space_id, starts_at, ends_at, reason, active)
    values (v_rule.space_id, ((v_d + 1)::timestamp at time zone 'Europe/Helsinki'), ((v_d + 2)::timestamp at time zone 'Europe/Helsinki'), 'testi 289', true);
  end if;
  -- 3) jaettuja varauksia: täytetään ensimmäisen shared-säännön poolit kahdelle päivälle
  for v_rule in select r.*, (select array_agg(pool_id) from booking.schedule_rule_pools where rule_id = r.id) pools
                  from booking.schedule_rules r where r.active and r.mode = 'shared' order by r.id limit 3 loop
    for v_d in select g::date from generate_series(current_date + 1, current_date + 21, interval '1 day') g
                where extract(isodow from g)::int = any (v_rule.weekdays) limit 3 loop
      insert into booking.reservations(order_id, product_id, rule_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status)
      values (v_order, v_rule.product_id, v_rule.id, v_rule.space_id, 'shared',
              (v_d + v_rule.start_time) at time zone 'Europe/Helsinki',
              (v_d + v_rule.start_time + make_interval(mins => v_rule.duration_minutes)) at time zone 'Europe/Helsinki',
              greatest(coalesce(v_rule.max_persons, 4) - 1, 1), coalesce(v_rule.pools, '{}'), 'confirmed');
    end loop;
  end loop;
  -- 4) hoitajatarkistus (269): ensimmäiselle säännöllisen vuoron tuotteelle vaaditaan taito; vuoroja ei ole -> unavailable
  select r.product_id into v_first from booking.schedule_rules r where r.active order by r.id limit 1;
  update booking.product_config set required_skill = 'yleinen', therapist_minutes = 60, therapist_offset_min = 0 where product_id = v_first;
  -- 5) koulutusvaihtoehto: ensimmäinen sääntö saa segmentin (seats_left-polku)
  select min(id), max(id) into v_first, v_second from booking.schedule_rules where active;
  insert into booking.training_segments(option_rule_id, position, segment_rule_id) values (v_first, 1, v_second);
end $$;

-- 3) uusi määritys, busy
select pg_temp.take('new', 'busy');
-- 4) vanha määritys, busy
\ir ../rollbacks/20261113064837_booking_289_ROLLBACK.sql
select pg_temp.take('old', 'busy');
-- asennetaan uusi takaisin (ei vaikutusta rollbackin jälkeen, mutta pidetään tila selkeänä)
\ir ../migrations/20261113064837_booking_289_availability_speedup.sql

insert into r289(ok, label)
select (select count(*) from snap where version = 'old' and state = st) > 0, 'vanhasta on rivejä tilanteessa ' || st from (values ('base'), ('busy')) x(st);
insert into r289(ok, label)
select not exists (select state, scen_id, ord, rule_id, label, mode, session_date, starts_at, ends_at, status, remaining, min_persons, max_persons, price_mode, unit_price, base_price, included_persons, extra_person_price, label_en from snap where version = 'old' and state = st except select state, scen_id, ord, rule_id, label, mode, session_date, starts_at, ends_at, status, remaining, min_persons, max_persons, price_mode, unit_price, base_price, included_persons, extra_person_price, label_en from snap where version = 'new' and state = st)
   and not exists (select state, scen_id, ord, rule_id, label, mode, session_date, starts_at, ends_at, status, remaining, min_persons, max_persons, price_mode, unit_price, base_price, included_persons, extra_person_price, label_en from snap where version = 'new' and state = st except select state, scen_id, ord, rule_id, label, mode, session_date, starts_at, ends_at, status, remaining, min_persons, max_persons, price_mode, unit_price, base_price, included_persons, extra_person_price, label_en from snap where version = 'old' and state = st),
       'vanha = uusi rivi riviltä (sis. järjestys), tilanne ' || st from (values ('base'), ('busy')) x(st);
insert into r289(ok, label)
select (select count(*) from snap where version = 'old' and state = 'busy' and status = 'full') > 0, 'busy-tilanteessa on full-rivejä (kattavuus)';
insert into r289(ok, label)
select (select count(*) from snap where version = 'old' and state = 'busy' and status = 'unavailable') > 0, 'busy-tilanteessa on unavailable-rivejä (kattavuus)';
insert into r289(ok, label)
select (select count(*) from snap where version = 'old' and state = 'busy' and status = 'available') > 0, 'busy-tilanteessa on available-rivejä (kattavuus)';
insert into r289(ok, label)
select exists (select scen_id, ord, rule_id, label, mode, session_date, starts_at, ends_at, status, remaining, min_persons, max_persons, price_mode, unit_price, base_price, included_persons, extra_person_price, label_en from snap where version = 'old' and state = 'busy' except select scen_id, ord, rule_id, label, mode, session_date, starts_at, ends_at, status, remaining, min_persons, max_persons, price_mode, unit_price, base_price, included_persons, extra_person_price, label_en from snap where version = 'old' and state = 'base'),
       'busy eroaa base-tilanteesta (testidata vaikuttaa)';
insert into r289(ok, label)
select md5(pg_get_functiondef('booking.public_availability(bigint,date,date)'::regprocedure)) <> 'aa5fc3442cb7141eb4a2a05f92b580dd',
       'uusi määritys eroaa 269:stä (CASE-laiska arviointi)';
insert into r289(ok, label)
select pg_get_functiondef('booking.public_availability(bigint,date,date)'::regprocedure) ~ 'case when exists \(select 1 from booking\.training_segments',
       'seats_left kutsutaan vain kun training_segments-rivi on';

select case when ok then 'ok ' else 'not ok ' end || n || ' - ' || label from r289 order by n;
select '1..' || count(*) from r289;
rollback;
