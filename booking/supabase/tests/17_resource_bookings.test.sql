-- booking_17 (resurssivaraukset): legit, tilapuskurit, saunottajat, paketti, ylitys (override), lifecycle/vanha varaus, oikeudet. Pohjana Bottiavustuksen booking_17_tests_DRAFT.sql (pg_temp.t_ok/t_err -> pgTAP-rivit; fikstuurit public_mock.sql:n rakenteelle).
-- Testit käyttävät kuvitteellisia saunottajia/asiakasta ja tulevia päiviä (2027); kaikki kirjoitukset kumotaan.
begin;
set local search_path = extensions, booking, public;
select no_plan();

-- tulokset kerätään tauluun ja raportoidaan lopussa pgTAP-riveinä (ok / not ok); odottamaton virhe keskeyttää tiedoston (run.sh huomaa ERROR:n)
create temp table _tr(n serial, pass boolean, msg text);
create function pg_temp.t_ok(p_cond boolean, p_msg text) returns void language plpgsql as $$ begin insert into _tr(pass, msg) values (p_cond is true, p_msg); end $$;
-- odottaa BK001-virhettä jonka detail = p_code (tai EXCLUDE-virhettä 23P01 kun p_code='exclude')
create function pg_temp.t_err(p_sql text, p_code text, p_msg text) returns void language plpgsql as $$
declare v_code text;
begin
  begin
    execute p_sql;
  exception
    when sqlstate 'BK001' then get stacked diagnostics v_code = pg_exception_detail;
    when exclusion_violation then v_code := 'exclude';
  end;
  insert into _tr(pass, msg) values (v_code is not distinct from p_code, p_msg || ' [odotettu ' || p_code || ', saatu ' || coalesce(v_code, 'ei virhettä') || ']');
end $$;
create function pg_temp.ts(p text) returns timestamptz language sql as $$ select (p::timestamp) at time zone 'Europe/Helsinki' $$;
create function pg_temp.rid(p_code text) returns bigint language sql as $$ select id from booking.resources where code = p_code $$;
-- vanhan tyylin suora varaus (kuten _create_booking_core): tilaus + rivi + varaus
create function pg_temp.mk(p_space text, p_mode text, p_start text, p_end text, p_persons int, p_pools text[] default '{}', p_status text default 'confirmed', p_product bigint default 1) returns bigint language plpgsql as $$
declare v_o bigint; v_r bigint;
begin
  insert into booking.orders(status, total_gross) values ('confirmed', 0) returning id into v_o;
  insert into booking.reservations(order_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status)
  values (v_o, p_product, pg_temp.rid(p_space), p_mode, pg_temp.ts(p_start), pg_temp.ts(p_end), p_persons,
          coalesce((select array_agg(id) from booking.resources where code = any (p_pools)), '{}'), p_status) returning id into v_r;
  return v_r;
end $$;
-- uuden mallin varaus (legit); palauttaa reservation_id
create function pg_temp.mk2(p_product bigint, p_start text, p_persons int, p_space bigint default null, p_override boolean default false, p_reason text default null, p_end text default null) returns bigint language plpgsql as $$
begin
  return (booking._create_legs_booking(null, p_product, pg_temp.ts(p_start), case when p_end is null then null else pg_temp.ts(p_end) end, p_persons,
          (select id from booking.customers limit 1), 'admin', null, null, null, p_space, p_override, p_reason, false, null) ->> 'reservation_id')::bigint;
end $$;

-- admin-kirjautuminen vain JWT-väittämänä (DB-rooli pysyy ennallaan, jotta testin omat fikstuurit voivat kirjoittaa public-skeemaan); admin_*-funktiot lukevat auth.uid():n
select test.mk_staff('admin17@example.com', 'admin') as adm17 \gset
select test.mk_staff('staff17@example.com', 'staff') as staff17 \gset
select set_config('request.jwt.claims', json_build_object('sub', :'adm17'::text, 'role', 'authenticated')::text, true);

-- ---------- fikstuurit: 3 saunottajaa + Laura, vuorot 16.1.2027 ----------
insert into booking.customers(name) values ('Testiasiakas');
create temp table fx(k text primary key, id uuid);
-- public_mock.sql:n migraation 16 vaatimat mock-saunottajat (tuotannon UUID:t, niillä on migraation 16 taito-ylitykset) poistetaan käytöstä, ettei niitä lasketa tämän testin saunottajiksi
update public.staff set active = false where name like 'Mock Saunottaja%';
insert into public.staff(id, name, email) select gen_random_uuid(), 'T17 ' || x, lower(x) || '.t17@example.com' from unnest(array['T1','T2','T3','LAURA']) x;
insert into fx select substr(name, 5), id from public.staff where name like 'T17 %';
insert into public.staff_roles(staff_id, role_type) select id, 'therapist' from fx;   -- (public_mock.sql:n 3 mock-saunottajaa eivät ole vuorossa)
insert into booking.staff_skill_overrides(staff_id, skill, allowed) select id, 'saunotus', true from fx where k = 'T1';       -- vain T1 saunotus
insert into booking.staff_skill_overrides(staff_id, skill, allowed) select id, 'laura', true from fx where k = 'LAURA';
insert into booking.staff_skill_overrides(staff_id, skill, allowed) select id, 'morsiussauna', false from fx where k = 'T3';
create function pg_temp.shift(p_k text, p_from text, p_to text) returns void language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.work_shifts(id, role_type, status, staffing_status, starts_at, ends_at) values (v, 'therapist', 'active', 'assigned', pg_temp.ts(p_from), pg_temp.ts(p_to));
  insert into public.shift_assignments(shift_id, staff_id) select v, id from fx where k = p_k;
end $$;
create function pg_temp.sh(p_date text) returns void language sql as $$
  select pg_temp.shift('T1', p_date || ' 14:00', p_date || ' 20:00'), pg_temp.shift('T2', p_date || ' 16:00', p_date || ' 20:00'), pg_temp.shift('T3', p_date || ' 16:00', p_date || ' 20:00') $$;
select pg_temp.sh(d) from unnest(array['2027-01-23','2027-01-30','2027-02-06','2027-02-13','2027-02-27','2027-03-06','2027-03-13','2027-03-20','2027-04-03']) d;   -- 27.3.: vain T3 (ks. M)


-- ================= A. puoliavoin väli (15:00 / 19:00) – regressio (vanha polku, ei legejä) =================
do $$ begin
  perform pg_temp.mk('savusauna', 'exclusive', '2027-01-16 13:00', '2027-01-16 15:00', 4);
  perform pg_temp.mk('savusauna', 'shared', '2027-01-16 15:00', '2027-01-16 17:00', 2, array['yleinen_vkp_1500']);
  perform pg_temp.t_ok(true, 'A1 yksityinen 13–15 + julkinen 15–17 sallittu');
  perform pg_temp.mk('savusauna', 'shared', '2027-01-16 17:00', '2027-01-16 19:00', 2, array['yleinen_vkp_1700']);
  perform pg_temp.mk('savusauna', 'exclusive', '2027-01-16 19:00', '2027-01-16 21:00', 4);
  perform pg_temp.t_ok(true, 'A2 julkinen 17–19 + yksityinen 19–21 sallittu');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'shared', '2027-01-16 14:59', '2027-01-16 16:00', 1, array['yleinen_vkp_1400'])$q$, 'private_booked', 'A3 julkinen 14:59 osuu yksityiseen 13–15');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'exclusive', '2027-01-16 13:30', '2027-01-16 15:00', 1)$q$, 'private_booked', 'A4 kaksi yksityistä päällekkäin');
  perform pg_temp.mk('savusauna', 'exclusive', '2027-01-16 21:00', '2027-01-16 22:00', 2);
  perform pg_temp.t_ok(true, 'A5 kaksi yksityistä peräkkäin samalla hetkellä (21:00) sallittu');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'shared', '2027-01-16 18:30', '2027-01-16 19:30', 1, array['yleinen_vkp_1630'])$q$, 'private_booked', 'A6 julkinen osuu 19:00 alkavaan yksityiseen');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'exclusive', '2027-01-16 16:00', '2027-01-16 18:00', 1)$q$, 'public_shift_booked', 'A7 yksityinen osuu julkiseen 15–17');
end $$;

-- ================= B. regressio: pooli, sulku, historia =================
do $$ begin
  perform pg_temp.mk('savusauna', 'shared', '2027-01-09 14:00', '2027-01-09 16:00', 5, array['yleinen_vkp_1400'], 'confirmed');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'shared', '2027-01-09 14:00', '2027-01-09 16:00', 2, array['yleinen_vkp_1400'])$q$, 'capacity_exceeded', 'B1 pooli täynnä (6)');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'shared', '2027-01-09 14:00', '2027-01-09 16:00', 1, array['rauni_rituaali'])$q$, 'bad_pool', 'B2 väärän tilan pooli');
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (pg_temp.rid('savusauna'), pg_temp.ts('2027-01-17 10:00'), pg_temp.ts('2027-01-17 12:00'), 'testisulku');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'shared', '2027-01-17 11:00', '2027-01-17 13:00', 1, array['yleinen_vkp_1400'])$q$, 'space_closed', 'B3 sulku estää (savusauna)');
  perform pg_temp.mk('savusauna', 'shared', '2027-01-17 12:00', '2027-01-17 13:00', 1, array['yleinen_vkp_1400']);
  perform pg_temp.t_ok(true, 'B4 sulun päättymishetkestä alkava sallittu (puoliavoin)');
  perform pg_temp.mk('savusauna', 'exclusive', '2027-01-09 15:00', '2027-01-09 17:00', 3, '{}', 'completed');
  perform pg_temp.t_ok(true, 'B5 historia (completed) ohittaa validoinnin (päällekkäin 13–15/15–17 julkisen kanssa)');
  perform pg_temp.mk('rauni', 'exclusive', '2027-01-09 15:00', '2027-01-09 17:00', 1, '{}', 'cancelled');
  perform pg_temp.mk('rauni', 'exclusive', '2027-01-09 15:30', '2027-01-09 17:00', 1, '{}', 'cancelled');
  perform pg_temp.t_ok(true, 'B6 peruttu ei estä');
end $$;

-- ================= C. Rauni-puskuri 15 min, Lovi vain kun Rauni suljettu (23.1.) =================
do $$ declare r1 bigint; begin
  r1 := pg_temp.mk2(10, '2027-01-23 14:00', 1);
  perform pg_temp.t_ok((select space_id from booking.reservations where id = r1) = pg_temp.rid('rauni')
         and (select count(*) from booking.reservation_legs where reservation_id = r1 and role = 'therapist') = 1, 'C1 hoito (60 min): Rauni + saunottajaleg');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-01-23 15:10', 1)$q$, 'space_busy', 'C2 hoito 15:10 (väli 10 < 15 min) hylätään; Lovia ei tarjota kun Rauni vain varattu');
  perform pg_temp.mk2(10, '2027-01-23 15:15', 1);
  perform pg_temp.t_ok(true, 'C3 hoito 15:15 (väli 15 min) sallittu');
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (pg_temp.rid('rauni'), pg_temp.ts('2027-01-23 17:00'), pg_temp.ts('2027-01-23 19:00'), 'Rauni kiinni (testi)');
  r1 := pg_temp.mk2(10, '2027-01-23 17:30', 1);
  perform pg_temp.t_ok((select space_id from booking.reservations where id = r1) = pg_temp.rid('lovi'), 'C4 Rauni suljettu -> 1 hlö hoito menee Loviin');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-01-23 17:30', 2)$q$, 'space_closed', 'C5 2 hlö + Rauni suljettu: ei tilaa (Lovi max 1)');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-01-23 18:00', 1)$q$, 'space_closed', 'C6 Lovi varattu 17:30–18:30 ja Rauni kiinni -> hylätään');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-01-23 17:30', 1, pg_temp.rid('savusauna'))$q$, 'no_space', 'C7 käsin valittu tila jolle tuotteella ei ole sääntöä (savusauna) -> no_space');
end $$;

-- ================= D. rituaalit: yksi istunto jakaa pooliin + saunottajan; rituaali–rituaali väli 10, hoito 15 (30.1.) =================
do $$ declare a bigint; begin
  a := pg_temp.mk2(8, '2027-01-30 14:00', 3);
  perform pg_temp.mk2(8, '2027-01-30 14:00', 2);
  perform pg_temp.t_ok((select count(*) from booking.reservation_legs where role = 'therapist' and reservation_id in (select id from booking.reservations where starts_at = pg_temp.ts('2027-01-30 14:00'))) = 2,
                       'D1 kaksi rituaalivarausta samaan istuntoon (5/6) – yksi saunottaja riittää (vain T1 vuorossa 14:00)');
  perform pg_temp.t_err($q$select pg_temp.mk2(8, '2027-01-30 14:00', 2)$q$, 'capacity_exceeded', 'D2 rituaalipooli täynnä (7 > 6)');
  perform pg_temp.mk2(8, '2027-01-30 14:30', 1);
  perform pg_temp.t_ok(true, 'D3 rituaali 14:30 heti edellisen (14:00–14:20) jälkeen: väli 10 min riittää');
  perform pg_temp.t_err($q$select pg_temp.mk2(8, '2027-01-30 14:55', 1)$q$, 'space_busy', 'D4 rituaali 14:55 (väli 5 < 10) hylätään');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-01-30 14:50', 1)$q$, 'space_busy', 'D5 hoito 14:50 rituaalin (14:30–14:50) jälkeen: väli 0 < 15');
  perform pg_temp.mk2(10, '2027-01-30 15:05', 1);
  perform pg_temp.t_ok(true, 'D6 hoito 15:05 (väli 15 min rituaalista) sallittu');
end $$;

-- ================= E. paketti kb 7 (6.2.): Rauni 20 min + savusauna 14:30–16:00 + saunottaja 20 min =================
do $$ declare p bigint; begin
  p := pg_temp.mk2(7, '2027-02-06 14:00', 2);
  perform pg_temp.t_ok((select r.claim_offset_min = 30 and r.space_id = pg_temp.rid('savusauna') and r.pool_ids = array[pg_temp.rid('yleinen_vkp_1430')] and c.claim_start = pg_temp.ts('2027-02-06 14:30') and c.claim_end = pg_temp.ts('2027-02-06 16:00') from booking.reservations r join booking.v_claims c on c.reservation_id = r.id and c.role = 'space' and c.resource_id = r.space_id where r.id = p),
                       'E1 paketti: savusaunan claim 14:30–16:00 (+30 min, 90 min; claim_minutes NULL = ikkunan loppuun), pooli 14:30-vuoro');
  perform pg_temp.t_ok((select count(*) from booking.reservation_legs where reservation_id = p and role = 'space' and resource_id = pg_temp.rid('rauni') and ends_at = starts_at + interval '20 minutes') = 1
                       and (select count(*) from booking.reservation_legs where reservation_id = p and role = 'therapist' and ends_at = starts_at + interval '20 minutes') = 1, 'E2 paketti: Rauni-leg 20 min + saunottajaleg 20 min');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'exclusive', '2027-02-06 12:30', '2027-02-06 14:31', 1)$q$, 'public_shift_booked', 'E4 yksityinen 14:31 asti osuu paketin savusaunaosuuteen');
  perform pg_temp.mk('savusauna', 'exclusive', '2027-02-06 13:00', '2027-02-06 14:30', 4);
  perform pg_temp.t_ok(true, 'E3 yksityinen 13:00–14:30 sallittu (paketin savusaunaosuus alkaa 14:30)');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'shared', '2027-02-06 14:30', '2027-02-06 16:30', 5, array['yleinen_vkp_1430'])$q$, 'capacity_exceeded', 'E5 paketti vie 2 paikkaa 14:30-poolista -> 5 hlö ei mahdu (7 > 6)');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-02-06 14:30', 1)$q$, 'space_busy', 'E6 hoito 14:30: paketin Rauni-rituaali 14:00–14:20 + 15 min puskuri = 14:35');
  perform pg_temp.mk2(10, '2027-02-06 14:35', 1);
  perform pg_temp.t_ok(true, 'E7 hoito 14:35 sallittu');
  perform pg_temp.t_err($q$select booking.admin_create_block(pg_temp.rid('rauni'), pg_temp.ts('2027-02-06 14:00'), pg_temp.ts('2027-02-06 14:10'), 'testi')$q$, 'has_reservations', 'E8 Rauni-sulku ei onnistu paketin Rauni-legin päälle');
end $$;

-- ================= F. saunottajan Hall-tarkistus: saunotus ⊂ yleinen (13.2.; T1 14–20 saunotus, T2+T3 16–20) =================
do $$ declare f bigint; begin
  f := pg_temp.mk2(11, '2027-02-13 16:00', 1);
  perform pg_temp.t_ok((select skill from booking.reservation_legs where reservation_id = f and role = 'therapist') = 'saunotus', 'F1 saunotus 16–18 (Rauni, taito saunotus) – T1');
  perform pg_temp.t_err($q$select pg_temp.mk2(23, '2027-02-13 16:30', 1, pg_temp.rid('savusauna'))$q$, 'no_therapist', 'F2 toinen saunotus-taitoa vaativa (savusauna, manual) 16:30: vain yksi saunotustaitoinen (T1) vaikka T2/T3 vuorossa');
  perform pg_temp.mk2(30, '2027-02-13 16:00', 4);
  perform pg_temp.t_ok(true, 'F3 synttärisauna (savusauna 120 min, saunottaja 1 h, yleinen) 16:00 -> T2/T3 hoitaa');
  perform pg_temp.t_ok((select ends_at - starts_at from booking.reservation_legs where role = 'therapist' and reservation_id = (select id from booking.reservations where product_id = 30 and starts_at = pg_temp.ts('2027-02-13 16:00'))) = interval '1 hour', 'F4 synttärin saunottajaleg vain 1 h');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-02-13 16:30', 1, null)$q$, 'space_busy', 'F5 Rauni varattu saunotuksella 16–18 -> hoito 16:30 hylätään');
end $$;

-- ================= G. Laura-tapahtumat: vuoroista riippumaton, yksi samanaikainen istunto (20.2.) =================
do $$ begin
  perform pg_temp.mk2(9, '2027-02-20 19:00', 3);
  perform pg_temp.mk2(9, '2027-02-20 19:00', 4);
  perform pg_temp.t_ok(true, 'G1 Perinnesaunotusilta: kaksi varausta samaan istuntoon (3+4 <= 8), Lauralla ei vuoroa mutta riittää');
  perform pg_temp.t_err($q$select pg_temp.mk2(9, '2027-02-20 19:00', 2)$q$, 'capacity_exceeded', 'G2 tapahtumapooli 8 täynnä');
  perform pg_temp.t_err($q$select pg_temp.mk2(32, '2027-02-20 19:30', 2)$q$, 'no_therapist', 'G3 jouluinen saunailta 19:30 (Laura) päällekkäin Perinnesaunotusillan (19:00–20:30) kanssa');
  perform pg_temp.mk2(32, '2027-02-20 21:00', 2);
  perform pg_temp.t_ok((select count(*) from booking.reservation_legs where role = 'space' and resource_id = pg_temp.rid('rauni') and reservation_id = (select id from booking.reservations where product_id = 32)) = 1, 'G4 jouluinen 21:00: savusauna + Rauni-leg + Laura');
end $$;

-- ================= H. lisäpalvelu kb 27/28 vaatii jälkilöyly-/yksityisvuorovarauksen (27.2.) =================
do $$ declare h2 bigint; h3 bigint; begin
  perform pg_temp.t_err($q$select pg_temp.mk2(27, '2027-02-27 19:00', 4)$q$, 'parent_required', 'H1 kb 27 ilman jälkilöylyvarausta hylätään');
  h2 := pg_temp.mk2(26, '2027-02-27 19:00', 8, null, false, null, '2027-02-27 22:00');
  h3 := pg_temp.mk2(27, '2027-02-27 19:00', 4);
  perform pg_temp.t_ok((select parent_reservation_id from booking.reservations where id = h3) = h2 and (select space_id from booking.reservations where id = h3) = pg_temp.rid('ei_resurssia'), 'H2 kb 27 jälkilöylyn aikana: parent linkitetty, ei varaa saunaa (ei_resurssia) + saunottajaleg');
  perform pg_temp.t_err($q$select pg_temp.mk2(28, '2027-02-27 19:00', 2)$q$, 'parent_required', 'H3 kb 28 vaatii kb 25 -vuoron (jälkilöyly ei kelpaa)');
  update booking.reservations set status = 'cancelled' where id = h2;
  perform pg_temp.t_ok(exists (select 1 from jsonb_array_elements(booking.admin_review_list() -> 'orphan_addons') e where (e ->> 'reservation_id')::bigint = h3), 'H4 vanhempi peruttu -> lisäpalvelu listautuu Tarkista-listalle');
end $$;

-- ================= I. sulku + ylitys + admin-rajapinnat (6.3.) =================
do $$ declare i3 bigint; v jsonb; begin
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (pg_temp.rid('saunottaja'), pg_temp.ts('2027-03-06 14:00'), pg_temp.ts('2027-03-06 18:00'), 'hoidot kiinni (testi)');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-03-06 14:30', 1)$q$, 'therapist_closed', 'I1 "hoidot kiinni" estää hoidon');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-03-06 14:30', 1, null, true, null)$q$, 'override_reason_required', 'I2 ylitys vaatii perustelun');
  i3 := pg_temp.mk2(10, '2027-03-06 14:30', 1, null, true, 'Joonaksen lupa testissä');
  perform pg_temp.t_ok((select override_reason from booking.reservations where id = i3) is not null, 'I3 ylitys perusteluineen onnistuu; varaus merkitty');
  perform pg_temp.t_ok(exists (select 1 from jsonb_array_elements(booking.admin_review_list() -> 'overrides') e where (e ->> 'reservation_id')::bigint = i3), 'I4 ylitys näkyy Tarkista-listalla');
  perform set_config('request.jwt.claims', json_build_object('sub', (select user_id from booking.staff where email = 'staff17@example.com'), 'role', 'authenticated')::text, true);   -- peruskäyttäjällä ei ole bookings.override
  perform pg_temp.t_err($q$select booking.admin_create_resource_booking(10, pg_temp.ts('2027-03-06 15:45'), 1, (select id from booking.customers limit 1), null, null, null, 'pay_later', false, null, null, true, 'perustelu')$q$, 'forbidden', 'I5 ylitys vaatii oikeuden bookings.override');
  perform set_config('request.jwt.claims', json_build_object('sub', (select user_id from booking.staff where email = 'admin17@example.com'), 'role', 'authenticated')::text, true);
  v := booking.admin_create_resource_booking(10, pg_temp.ts('2027-03-06 19:00'), 2, (select id from booking.customers limit 1), null, null, null, 'pay_later', false, 'testi');
  perform pg_temp.t_ok((v ->> 'total')::numeric = 134 and (select count(*) from booking.payments where order_id = (v ->> 'order_id')::bigint) = 1, 'I6 admin_create_resource_booking: hinta 99 + 35 (2 hlö) = 134, maksurivi luotu');
  perform pg_temp.t_err($q$select booking.admin_create_old_booking(10, pg_temp.ts('2027-03-06 19:00'), 1, (select id from booking.customers limit 1))$q$, 'wrong_lifecycle', 'I7 vanha varaus vaatii old-tuotteen');
  perform pg_temp.t_err($q$select booking.admin_create_old_booking(24, pg_temp.ts('2027-03-06 20:30'), 1, (select id from booking.customers limit 1))$q$, 'no_therapist', 'I8 vanha hoito 20:30: ei saunottajaa vuorossa');
  v := booking.admin_create_old_booking(24, pg_temp.ts('2027-03-06 18:00'), 1, (select id from booking.customers limit 1));
  perform pg_temp.t_ok((v ->> 'total')::numeric = 20 and (select ends_at - starts_at from booking.reservations where id = (v ->> 'reservation_id')::bigint) = interval '30 minutes', 'I9 vanha varaus kb 24: 20 €, kesto 30 min (config)');
end $$;

-- ================= J. uudelleenaktivointi ja siirto: legit seuraavat (13.3.) =================
do $$ declare a bigint; b bigint; c bigint; begin
  a := pg_temp.mk2(10, '2027-03-13 14:00', 1);
  update booking.reservations set status = 'cancelled' where id = a;
  b := pg_temp.mk2(10, '2027-03-13 14:00', 1);
  perform pg_temp.t_err(format('update booking.reservations set status = %L where id = %s', 'confirmed', a), 'space_busy', 'J1 peruttu varaus ei voi aktivoitua kun aika on myöhemmin varattu');
  update booking.reservations set starts_at = starts_at + interval '1 hour', ends_at = ends_at + interval '1 hour' where id = b;
  perform pg_temp.t_ok((select starts_at from booking.reservation_legs where reservation_id = b and role = 'therapist') = pg_temp.ts('2027-03-13 15:00'), 'J2 varauksen siirto siirtää saunottajalegin');
  c := pg_temp.mk2(10, '2027-03-13 17:30', 1);
  perform pg_temp.t_err(format('update booking.reservations set starts_at = %L, ends_at = %L where id = %s', pg_temp.ts('2027-03-13 17:40'), pg_temp.ts('2027-03-13 18:40'), b), 'space_busy', 'J3 siirto osuu toiseen Rauni-varaukseen (puskuri)');
  update booking.reservations set persons = 1 where id = c;
  perform pg_temp.t_ok(true, 'J4 muuttumaton päivitys ei kaadu');
end $$;

-- ================= K. siirto Rauni -> Lovi, tuonnin leg-backfill, kiintiövapautus, historia, näkymät (20.3.) =================
do $$ declare k1 bigint; k2 bigint; k3 bigint; k4 bigint; v jsonb; n1 int; n2 int; begin
  k1 := pg_temp.mk2(10, '2027-03-20 14:00', 1);
  perform booking.admin_move_reservation_space(k1, 'lovi', 'Rauni ei lämmin');
  perform pg_temp.t_ok((select space_id from booking.reservations where id = k1) = pg_temp.rid('lovi'), 'K1 käsin-siirto Rauni -> Lovi (1 hlö) onnistuu');
  k2 := pg_temp.mk2(10, '2027-03-20 16:00', 2);
  perform pg_temp.t_err(format('select booking.admin_move_reservation_space(%s, %L)', k2, 'lovi'), 'space_not_allowed', 'K2 2 hlö ei voi siirtää Loviin');
  -- tuonti/backfill: vanha-tyylin (legitön) paketti -> import_attach_legs lisää legit ja claim-ikkunan; idempotentti
  k3 := pg_temp.mk('savusauna', 'shared', '2027-04-03 14:00', '2027-04-03 16:00', 2, array['yleinen_vkp_1430'], 'confirmed', 7);
  v := booking.import_attach_legs(k3);
  select count(*) into n1 from booking.reservation_legs where reservation_id = k3;
  v := booking.import_attach_legs(k3);
  select count(*) into n2 from booking.reservation_legs where reservation_id = k3;
  perform pg_temp.t_ok((v ->> 'ok')::boolean and n1 = 2 and n2 = 2 and (select claim_offset_min from booking.reservations where id = k3) = 30, 'K3 import_attach_legs: 2 legiä, claim +30, toisella ajolla ei uusia (idempotentti)');
  -- konfliktissa: ei osittaisia legejä, palauttaa koodin
  perform pg_temp.mk('rauni', 'exclusive', '2027-04-03 16:00', '2027-04-03 17:00', 1, '{}', 'confirmed', 10);
  k4 := pg_temp.mk('savusauna', 'shared', '2027-04-03 16:30', '2027-04-03 18:30', 2, array['yleinen_vkp_1700'], 'confirmed', 7);
  v := booking.import_attach_legs(k4);
  perform pg_temp.t_ok(not (v ->> 'ok')::boolean and v ->> 'code' = 'space_busy' and (select count(*) from booking.reservation_legs where reservation_id = k4) = 0, 'K4 import_attach_legs konfliktissa: ok=false/space_busy, ei osittaisia legejä');
  -- kiintiövapautus: pooli täynnä, quota_exempt ohittaa kapasiteetin
  perform pg_temp.mk('savusauna', 'shared', '2027-03-20 19:00', '2027-03-20 21:00', 6, array['yleinen_vkp_1700']);
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'shared', '2027-03-20 19:00', '2027-03-20 21:00', 1, array['yleinen_vkp_1700'])$q$, 'capacity_exceeded', 'K5a pooli täynnä');
  insert into booking.reservations(order_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status, quota_exempt)
  select o.id, 1, pg_temp.rid('savusauna'), 'shared', pg_temp.ts('2027-03-20 19:00'), pg_temp.ts('2027-03-20 21:00'), 1, array[pg_temp.rid('yleinen_vkp_1700')], 'confirmed', true
    from (select id from booking.orders order by id desc limit 1) o;
  perform pg_temp.t_ok(true, 'K5b quota_exempt ohittaa poolikapasiteetin (kiintiövapaa varaus)');
  -- näkymät
  v := booking.admin_day_view('2027-03-20'::date);
  perform pg_temp.t_ok(jsonb_typeof(v) = 'object' and v::text like '%legs%' and v::text like '%lifecycle%', 'K6 admin_day_view palauttaa legit + lifecycle');
  perform pg_temp.t_ok((select count(*) from booking.admin_list_reservations(p_limit => 500) x) > 0, 'K7 admin_list_reservations toimii (uudet sarakkeet)');
end $$;

-- ================= N. morsiussauna: nimetty taito poissulkee (27.3.; vain T3 vuorossa, T3:lta morsiussauna kielletty) =================
do $$ begin
  perform pg_temp.shift('T3', '2027-03-27 14:00', '2027-03-27 20:00');
  perform pg_temp.t_err($q$select pg_temp.mk2(29, '2027-03-27 14:00', 2)$q$, 'no_therapist', 'N1 kb 29: vain T3 vuorossa, mutta T3:lta kielletty morsiussauna -> no_therapist');
  perform pg_temp.shift('T2', '2027-03-27 14:00', '2027-03-27 20:00');
  perform pg_temp.mk2(29, '2027-03-27 14:00', 2);
  perform pg_temp.t_ok(true, 'N2 T2 vuorossa (morsiussauna default) -> onnistuu');
end $$;

-- ================= M. oikeudet: uudet funktiot eivät ole anon/authenticated-suoria (vain admin_* authenticatedille) =================
do $$ declare f text; begin
  foreach f in array array['booking._plan_legs(bigint,timestamptz,timestamptz,integer,bigint,boolean,bigint)', 'booking._create_legs_booking(text,bigint,timestamptz,timestamptz,integer,bigint,text,uuid,text,numeric,bigint,boolean,text,boolean,bigint)',
                           'booking._therapist_slack(text,timestamptz,timestamptz,integer,text,bigint,bigint)', 'booking.import_attach_legs(bigint)'] loop
    perform pg_temp.t_ok(not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute'), 'M1 ei anon/authenticated-execute: ' || split_part(f, '(', 1));
  end loop;
  perform pg_temp.t_ok(not has_table_privilege('anon', 'booking.reservation_legs', 'select') and not has_table_privilege('anon', 'booking.v_claims', 'select'), 'M2 anon ei lue reservation_legs / v_claims');
end $$;

select ok(pass, msg) from _tr order by n;
select * from finish();
rollback;
