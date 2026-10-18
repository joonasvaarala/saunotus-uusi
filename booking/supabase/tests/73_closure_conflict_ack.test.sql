-- booking_73: sulkukonfliktin kuittaus ei muuta saatavuutta.
-- pgTAP. Ajo: booking/supabase/tests/run.sh (tai tämä tiedosto migraatioiden ja fixtuurien jälkeen).
-- Ei ON CONFLICT (email) auth.users-tauluun: käyttäjät tulevat test.mk_user / test.mk_staff -funktioista.
begin;
set local search_path = extensions, public;
select no_plan();

select test.mk_staff('t73-staff@example.test', 'staff') as staff,
       test.mk_staff('t73-mgr@example.test', 'manager') as mgr,
       test.mk_user('t73-asiakas@example.test') as plain \gset

insert into booking.roles(code, label, description, is_staff, sort_order)
values ('t73ovr', 'T73 vain ylitys', 'testi: vain bookings.override', true, 730);
insert into booking.role_permissions(role_code, permission) values ('t73ovr', 'bookings.override');
select test.mk_staff('t73-ovr@example.test', 't73ovr') as ovr \gset

select id as space from booking.resources where code = 'savusauna' \gset

-- Käsin tehty sulku ja varaus, joka on jo olemassa (sulku tulee varauksen jälkeen).
insert into booking.customers(name, email) values ('T73 Asiakas', 't73-cust@example.test') returning id as cust \gset
insert into booking.orders(customer_id, status, payment_status, source_channel, total_gross)
values (:cust, 'confirmed', 'paid', 'admin', 0) returning id as ord \gset

insert into booking.reservations(order_id, space_id, mode, starts_at, ends_at, persons, status)
values (:ord, :space, 'exclusive',
        timestamp '2027-06-05 14:00' at time zone 'Europe/Helsinki',
        timestamp '2027-06-05 15:00' at time zone 'Europe/Helsinki',
        2, 'confirmed')
returning id as res1 \gset

insert into booking.space_blocks(space_id, starts_at, ends_at, reason)
values (:space,
        timestamp '2027-06-05 14:30' at time zone 'Europe/Helsinki',
        timestamp '2027-06-05 16:30' at time zone 'Europe/Helsinki',
        'Sulku tehty käsin Johkussa')
returning id as block \gset

-- Toinen tilaus, jolla kokeillaan että sulku estää uuden varauksen (ei osu res1:een).
insert into booking.orders(customer_id, status, payment_status, source_channel, total_gross)
values (:cust, 'confirmed', 'paid', 'admin', 0) returning id as ord2 \gset

-- Kolmas pari bulk-kuittausta varten (eri päivä).
insert into booking.orders(customer_id, status, payment_status, source_channel, total_gross)
values (:cust, 'confirmed', 'paid', 'admin', 0) returning id as ord3 \gset
insert into booking.reservations(order_id, space_id, mode, starts_at, ends_at, persons, status)
values (:ord3, :space, 'exclusive',
        timestamp '2027-06-06 14:00' at time zone 'Europe/Helsinki',
        timestamp '2027-06-06 15:00' at time zone 'Europe/Helsinki',
        1, 'confirmed')
returning id as res3 \gset
insert into booking.space_blocks(space_id, starts_at, ends_at, reason)
values (:space,
        timestamp '2027-06-06 14:00' at time zone 'Europe/Helsinki',
        timestamp '2027-06-06 15:00' at time zone 'Europe/Helsinki',
        'Toinen käsisulku')
returning id as block3 \gset

select test.login(:'staff');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :res1 and (e ->> 'block_id')::bigint = :block
      and e ->> 'block_reason' = 'Sulku tehty käsin Johkussa'),
  1, 'A1 avoin sulkukonflikti näkyy ja sulun syy on mukana');
select test.logout();

-- Saatavuus ennen kuittausta: uusi varaus sulun ajalle (ei päällekkäin res1:n kanssa) estyy.
select is(test.code(format($q$
  insert into booking.reservations(order_id, space_id, mode, starts_at, ends_at, persons, status)
  values (%s, %s, 'exclusive', timestamp '2027-06-05 15:30' at time zone 'Europe/Helsinki',
          timestamp '2027-06-05 16:30' at time zone 'Europe/Helsinki', 1, 'confirmed')
$q$, :ord2, :space)), 'space_closed', 'A2 sulku estää uuden varauksen');

select test.anon();
select throws_ok(format('select booking.admin_ack_block_conflict(%s, %s, %L, null)', :res1, :block, 'Sulku tehty käsin Johkussa'),
  '42501', null, 'B1 anon ei saa kuitata');
select test.logout();

select test.login(:'plain');
select is(test.code(format('select booking.admin_ack_block_conflict(%s, %s, %L, null)', :res1, :block, 'Sulku tehty käsin Johkussa')),
  'forbidden', 'B2 tavallinen käyttäjä ei saa kuitata');
select throws_ok($$insert into booking.closure_conflict_acks(reservation_id, block_id, block_signature, ack_reason) values (1, 1, 't:1|2', 'ei saa')$$,
  '42501', null, 'B3 tavallinen käyttäjä ei kirjoita tauluun');
select throws_ok('select count(*) from booking.closure_conflict_acks', '42501', null, 'B4 tavallinen käyttäjä ei lue taulua');
select test.logout();

select ok(not has_table_privilege('anon', 'booking.closure_conflict_acks', 'select'), 'B5 anonilla ei ole lukuoikeutta');
select ok(not has_table_privilege('authenticated', 'booking.closure_conflict_acks', 'insert'), 'B6 authenticated ei kirjoita tauluun');
select ok(not has_function_privilege('anon', 'booking.admin_ack_block_conflict(bigint,bigint,text,text)', 'execute'), 'B7 anonilla ei ole execute-oikeutta');
select ok(has_function_privilege('authenticated', 'booking.admin_ack_block_conflict(bigint,bigint,text,text)', 'execute'), 'B8 henkilökunnan rooli voi kutsua RPC:tä');

select test.login(:'staff');
select is(test.code(format('select booking.admin_ack_block_conflict(%s, %s, %L, null)', :res1, :block, 'ab')),
  'note_required', 'C1 perustelu vähintään 3 merkkiä');
select is(test.code(format('select booking.admin_ack_block_conflict(%s, %s, %L, null)', :res1, :block3, 'Sulku tehty käsin Johkussa')),
  'no_conflict', 'C2 väärä pari ei ole konflikti');

select is((booking.admin_ack_block_conflict(:res1, :block, 'Sulku tehty käsin Johkussa', 'Joonas (päätös 18.10.2026)') ->> 'already')::boolean,
  false, 'C3 staff (blocks.manage) kuittaa');
select is((booking.admin_ack_block_conflict(:res1, :block, 'Sulku tehty käsin Johkussa', 'Joonas (päätös 18.10.2026)') ->> 'already')::boolean,
  true, 'C4 toinen kuittaus on idempotentti');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :res1 and (e ->> 'block_id')::bigint = :block),
  0, 'C5 kuitattu pari katoaa Sulkukonflikteista');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'acked_block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :res1 and (e ->> 'block_id')::bigint = :block
      and e ->> 'ack_reason' = 'Sulku tehty käsin Johkussa'
      and e ->> 'acked_by_label' = 'Joonas (päätös 18.10.2026)'),
  1, 'C6 pari näkyy Kuitatut-osiossa');
select test.logout();
select is(test.audit_n('BLOCK_CONFLICT_ACK'), 1, 'C7 audit_logiin yksi BLOCK_CONFLICT_ACK');

-- Saatavuus kuittauksen jälkeen: sulku, varaus ja uusi yritys ennallaan.
select is((select active from booking.space_blocks where id = :block), true, 'D1 sulku on yhä voimassa');
select is((select reason from booking.space_blocks where id = :block), 'Sulku tehty käsin Johkussa', 'D2 sulun syy ei muuttunut');
select is((select override_reason from booking.reservations where id = :res1), null, 'D3 varausta ei siirretä ylitykseksi');
select is((select status from booking.reservations where id = :res1), 'confirmed', 'D4 varaus pysyy vahvistettuna');
select is(test.code(format($q$
  insert into booking.reservations(order_id, space_id, mode, starts_at, ends_at, persons, status)
  values (%s, %s, 'exclusive', timestamp '2027-06-05 15:30' at time zone 'Europe/Helsinki',
          timestamp '2027-06-05 16:30' at time zone 'Europe/Helsinki', 1, 'confirmed')
$q$, :ord2, :space)), 'space_closed', 'D5 kuittaus ei avaa saatavuutta');

-- Sulun ajan muutos vanhentaa kuittauksen (käsisululla ei ole content_hashia).
update booking.space_blocks
   set starts_at = timestamp '2027-06-05 14:45' at time zone 'Europe/Helsinki',
       ends_at = timestamp '2027-06-05 16:45' at time zone 'Europe/Helsinki'
 where id = :block;
select test.login(:'staff');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :res1 and (e ->> 'block_id')::bigint = :block),
  1, 'E1 sulun muutos palauttaa konfliktin avoimeksi');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'acked_block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :res1 and (e ->> 'block_id')::bigint = :block),
  0, 'E2 vanhentunut kuittaus ei näy Kuitatuissa');
select is((booking.admin_ack_block_conflict(:res1, :block, 'Sulku tehty käsin Johkussa', null) ->> 'already')::boolean,
  false, 'E3 muuttuneen sulun voi kuitata uudelleen');
select test.logout();

-- Palauta alkuperäinen aika, jotta allekirjoitus taas vaihtuu ja avoin konflikti palaa purkamista varten.
update booking.space_blocks
   set starts_at = timestamp '2027-06-05 14:30' at time zone 'Europe/Helsinki',
       ends_at = timestamp '2027-06-05 16:30' at time zone 'Europe/Helsinki'
 where id = :block;
select test.login(:'ovr');
select is((booking.admin_ack_block_conflict(:res1, :block, 'Sulku tehty käsin Johkussa', 'vain ylitys') ->> 'already')::boolean,
  false, 'F1 bookings.override ilman blocks.manage riittää');
select is((booking.admin_unack_block_conflict(:res1, :block) ->> 'revoked')::boolean, true, 'F2 kuittauksen purku');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :res1 and (e ->> 'block_id')::bigint = :block),
  1, 'F3 purun jälkeen konflikti on taas avoin');
select is((booking.admin_unack_block_conflict(:res1, :block) ->> 'already')::boolean, true, 'F4 toinen purku on idempotentti');
select test.logout();
select is(test.audit_n('BLOCK_CONFLICT_UNACK'), 1, 'F5 audit_logiin BLOCK_CONFLICT_UNACK');

-- Kalenterisulku: varaus ensin, sulku sen jälkeen. Täsmäytys uudelleen ei nollaa kuittausta.
insert into booking.orders(customer_id, status, payment_status, source_channel, total_gross)
values (:cust, 'confirmed', 'paid', 'admin', 0) returning id as ordc \gset
insert into booking.reservations(order_id, space_id, mode, starts_at, ends_at, persons, status)
values (:ordc, :space, 'exclusive',
        timestamp '2027-06-12 15:00' at time zone 'Europe/Helsinki',
        timestamp '2027-06-12 17:00' at time zone 'Europe/Helsinki',
        2, 'confirmed')
returning id as resc \gset
insert into booking.closure_events(calendar_code, external_id, class, reason, all_day, starts_at, ends_at, content_hash)
values ('savusauna', 't73-ilta', 'closure', 'Perinnesaunotusilta', false,
        timestamp '2027-06-12 14:00' at time zone 'Europe/Helsinki',
        timestamp '2027-06-12 18:00' at time zone 'Europe/Helsinki',
        't73hashv1')
returning id as evid \gset
select (booking._reconcile_closure_blocks('savusauna') ->> 'blocks_inserted')::int as ins1 \gset
select id as cblock from booking.space_blocks where closure_event_id = :evid \gset
select is((:ins1::int > 0 and :cblock::bigint is not null), true, 'G1 täsmäytys loi kalenterisulun');

select test.login(:'mgr');
select is((booking.admin_ack_block_conflict(:resc, :cblock, 'Sulku tehty käsin Johkussa', 'Joonas (päätös 18.10.2026)') ->> 'ok')::boolean,
  true, 'G2 kalenterisulun konflikti kuitataan');
select test.logout();
select is((booking._reconcile_closure_blocks('savusauna') ->> 'blocks_deleted')::int, 0, 'G3 täsmäytys ei poista sulkua');
select is((select id from booking.space_blocks where closure_event_id = :evid), :cblock::bigint, 'G4 sulun id säilyy');
select test.login(:'mgr');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'acked_block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :resc),
  1, 'G5 täsmäytys ei nollaa kuittausta');
select is((select override from booking.closure_events where id = :evid), null, 'G6 tapahtuman ohitus ei vaihtunut');
select test.logout();

update booking.closure_events
   set starts_at = timestamp '2027-06-12 15:30' at time zone 'Europe/Helsinki',
       ends_at = timestamp '2027-06-12 18:30' at time zone 'Europe/Helsinki',
       content_hash = 't73hashv2',
       updated_at = now()
 where id = :evid;
select booking._reconcile_closure_blocks('savusauna');
select is((select id from booking.space_blocks where closure_event_id = :evid and active), :cblock::bigint, 'G7 muuttunut sulku päivitetään paikallaan');
select test.login(:'mgr');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :resc and (e ->> 'block_id')::bigint = :cblock
      and e ->> 'closure_reason' = 'Perinnesaunotusilta'),
  1, 'G8 sulun muutos vanhentaa kuittauksen ja syy näkyy');
select test.logout();
select is(test.code(format($q$
  insert into booking.reservations(order_id, space_id, mode, starts_at, ends_at, persons, status)
  values (%s, %s, 'exclusive', timestamp '2027-06-12 17:30' at time zone 'Europe/Helsinki',
          timestamp '2027-06-12 18:20' at time zone 'Europe/Helsinki', 1, 'confirmed')
$q$, :ord2, :space)), 'space_closed', 'G9 kalenterisulku estää yhä uuden varauksen');

-- Bulk: jo kuitattu pari + uusi pari. Oikeus vain bookings.override.
select test.login(:'ovr');
select booking.admin_ack_block_conflict(:res1, :block, 'Sulku tehty käsin Johkussa', 'Joonas (päätös 18.10.2026)') as pre \gset
select booking.admin_ack_block_conflicts_bulk(
  jsonb_build_array(
    jsonb_build_object('reservation_id', :res1, 'block_id', :block),
    jsonb_build_object('reservation_id', :res3, 'block_id', :block3)
  ),
  'Sulku tehty käsin Johkussa',
  'Joonas (päätös 18.10.2026)') as bulk \gset
select is((:'bulk'::jsonb ->> 'ok')::boolean and (:'bulk'::jsonb ->> 'count')::int = 2, true, 'H1 bulk kuittaa kaksi paria');
select is(((:'bulk'::jsonb -> 'items' -> 0) ->> 'already')::boolean, true, 'H2 bulk on idempotentti jo kuitatulle');
select is(((:'bulk'::jsonb -> 'items' -> 1) ->> 'already')::boolean, false, 'H3 bulk kuittaa uuden parin');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :res3),
  0, 'H4 bulk-kuittaus poistaa avoimen konfliktin');
select is(test.code($$select booking.admin_ack_block_conflicts_bulk('[]'::jsonb, 'Sulku tehty käsin Johkussa', null)$$),
  'bad_pairs', 'H5 tyhjä lista hylätään');
select test.logout();

select test.login(:'plain');
select is(test.code(format('select booking.admin_unack_block_conflict(%s, %s)', :res3, :block3)),
  'forbidden', 'H6 tavallinen käyttäjä ei pura kuittausta');
select test.logout();

-- SQL-editori: ei JWT:tä, current_user on postgres (session_user ei riitä, koska SET ROLE vaihtaa current_userin).
select is((booking.admin_unack_block_conflict(:res3, :block3) ->> 'revoked')::boolean, true, 'I1 postgres ilman JWT:tä saa purkaa');
select is((booking.admin_ack_block_conflicts_bulk(
  jsonb_build_array(jsonb_build_object('reservation_id', :res3, 'block_id', :block3)),
  'Sulku tehty käsin Johkussa', 'Joonas (päätös 18.10.2026)') ->> 'ok')::boolean, true, 'I2 postgres ilman JWT:tä saa bulk-kuitata');
select is(test.code('select booking.admin_review_list()'), 'forbidden', 'I3 Tarkista-lista vaatii henkilökunnan istunnon');
select test.login(:'staff');
select is(
  (select count(*)::int from jsonb_array_elements(booking.admin_review_list() -> 'acked_block_conflicts') e
    where (e ->> 'reservation_id')::bigint = :res3 and (e ->> 'block_id')::bigint = :block3),
  1, 'I4 SQL-editorin bulk-kuittaus näkyy Kuitatuissa');
select test.logout();

select * from finish();
rollback;
