-- t210: tapahtuman jono (booking_210). Ei autovarausta, ei pitoa, ilmoitus järjestyksessä, tietosuoja, loki.
-- Yleisen vuoron pitoa ei muuteta. Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN.
-- Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t210_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t210_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.st(p_email text) returns text language sql as $$ select status from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.held(p_email text) returns boolean language sql as $$
  select coalesce(status = 'notified' and hold_expires_at > now(), false) from booking.waitlist_entries where customer_email = p_email $$;
create function pg_temp.resn(p_email text) returns int language sql as $$
  select count(*)::int from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = p_email $$;
create function pg_temp.mails(p_email text, p_kind text) returns int language sql as $$
  select count(*)::int from booking.email_outbox where kind = p_kind and payload ->> 'to_email' = p_email $$;
create function pg_temp.join(p_rule bigint, p_date date, p_persons int, p_email text, p_locale text default 'fi', p_consent boolean default true) returns jsonb language plpgsql as $$
declare j jsonb; begin
  perform test.anon();
  j := booking.public_join_waitlist(p_rule, p_date, p_persons, 'Jono ' || p_email, p_email, null, p_locale, false, p_consent);
  perform test.logout();
  return j;
end $$;
do $t$
declare
  v_ev bigint; v_ev2 bigint; v_pool bigint; v_pool2 bigint; v_staff uuid; v jsonb; b jsonb; j jsonb; v_err text;
  de date := test.next_dow(5) + 91;  -- varaushorisontti 120 pv
  de2 date := test.next_dow(5) + 105;
begin
  -- Verkkomaksu testitilaan (kehityskannassa maksut pois päältä; transaktio perutaan lopussa), kuten t190.
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t210"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t210"}'::jsonb;
  update booking.product_config set bookable = true, shop_visible = true, max_persons = 12, required_skill = null where product_id = 32;
  insert into booking.resources(code, name, kind, parent_id, capacity, active)
    values ('t210_event', 'T210 tapahtuma', 'capacity_pool', 1, 4, true) returning id into v_pool;
  insert into booking.schedule_rules(product_id, label, mode, space_id, weekdays, start_time, duration_minutes, min_persons, max_persons, price_mode, deadline_minutes, active, valid_from, valid_to)
    values (32, 'T210 tapahtuma', 'shared', 1, '{5}', '09:00', 120, 1, 4, 'per_person', 0, true, de, de) returning id into v_ev;
  insert into booking.schedule_rule_pools(rule_id, pool_id) values (v_ev, v_pool);

  perform test.anon();
  j := booking.public_join_waitlist(v_ev, de, 2, 'A B', 'nocon@t210.example', null, 'fi', false, false);
  perform test.logout();
  perform pg_temp.ck(j ->> 'code' = 'privacy_required' and pg_temp.st('nocon@t210.example') is null, 'A1: ilman suostumusta ei riviä');
  perform pg_temp.ck(not (j ? 'customer_email'), 'A2: virhe ei palauta sähköpostia');

  b := test.pub_book(v_ev, de, 4, 'taytto@t210.example');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'B1: tapahtuma täynnä');
  j := pg_temp.join(v_ev, de, 2, 'eka@t210.example', 'fi', true);
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'kind' = 'event' and not (j ? 'customer_email'), 'B2: liittyminen ok');
  perform pg_temp.ck(pg_temp.mails('eka@t210.example', 'waitlist_joined') = 1, 'B3: yksi vahvistusviesti');
  perform pg_temp.ck((select status from booking.email_outbox where kind = 'waitlist_joined' and payload ->> 'to_email' = 'eka@t210.example') = 'skipped', 'B3b: varattu testitunnus (.example) ei lähde');
  perform pg_temp.ck((select locale from booking.email_outbox where kind = 'waitlist_joined' and payload ->> 'to_email' = 'eka@t210.example') = 'fi', 'B4: vahvistus FI');
  perform pg_temp.ck((select privacy_consent_at is not null from booking.waitlist_entries where customer_email = 'eka@t210.example'), 'B5: suostumus tallessa');
  j := pg_temp.join(v_ev, de, 3, 'toka@t210.example', 'en', true);
  perform pg_temp.ck((select locale from booking.email_outbox where kind = 'waitlist_joined' and payload ->> 'to_email' = 'toka@t210.example') = 'en', 'B6: vahvistus EN');

  update booking.reservations set persons = 2 where id = (
    select r.id from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id
     where c.email = 'taytto@t210.example' order by r.id limit 1);
  perform pg_temp.ck(pg_temp.st('eka@t210.example') = 'notified' and pg_temp.st('toka@t210.example') = 'waiting', 'C1: 2 paikkaa riittää kahdelle, ei kolmelle');
  perform pg_temp.ck(not pg_temp.held('eka@t210.example'), 'C2: ei pitoa');
  perform pg_temp.ck(pg_temp.resn('eka@t210.example') = 0 and pg_temp.resn('toka@t210.example') = 0, 'C3: ei autovarausta');
  perform pg_temp.ck((select payload ->> 'book_url' from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = 'eka@t210.example') like '%/varaa/#/varaa/%n=2&wl=%', 'C4: FI-varauslinkki');
  perform pg_temp.ck(pg_temp.mails('toka@t210.example', 'waitlist_spot_freed') = 0, 'C5: liian iso jono ei saa viestiä');
  perform pg_temp.ck((select count(*) from booking.waitlist_notify_log where rule_id = v_ev and kind = 'spot_freed') = 1, 'C6: yksi vapautumisloki');

  update booking.resources set capacity = 8 where id = v_pool;
  update booking.schedule_rules set max_persons = 8 where id = v_ev;
  perform pg_temp.ck(pg_temp.st('toka@t210.example') = 'notified' and not pg_temp.held('toka@t210.example'), 'D1: kapasiteetin kasvu ilmoittaa seuraavalle ilman pitoa');
  perform pg_temp.ck((select payload ->> 'book_url' from booking.email_outbox where kind = 'waitlist_spot_freed' and payload ->> 'to_email' = 'toka@t210.example') like '%/en/book/#/varaa/%', 'D2: EN-varauslinkki');
  perform pg_temp.ck(pg_temp.resn('toka@t210.example') = 0, 'D3: kapasiteetin kasvu ei varaa');

  insert into booking.resources(code, name, kind, parent_id, capacity, active)
    values ('t210_event_b', 'T210 b', 'capacity_pool', 1, 2, true) returning id into v_pool2;
  insert into booking.schedule_rules(product_id, label, mode, space_id, weekdays, start_time, duration_minutes, min_persons, max_persons, price_mode, deadline_minutes, active, valid_from, valid_to)
    values (32, 'T210 pois', 'shared', 1, '{5}', '12:00', 120, 1, 2, 'per_person', 0, true, de2, de2) returning id into v_ev2;
  insert into booking.schedule_rule_pools(rule_id, pool_id) values (v_ev2, v_pool2);
  b := test.pub_book(v_ev2, de2, 2, 'taytto2@t210.example');
  j := pg_temp.join(v_ev2, de2, 1, 'hiljaa@t210.example');
  perform pg_temp.ck(pg_temp.mails('hiljaa@t210.example', 'waitlist_joined') = 1, 'E1: vahvistus lähtee vaikka ilmoitusasetus olisi myöhemmin pois');
  insert into booking.settings(key, value) values ('waitlist_event_notify', 'false'::jsonb)
    on conflict (key) do update set value = excluded.value;
  update booking.reservations set status = 'cancelled' where id = (
    select r.id from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id
     where c.email = 'taytto2@t210.example' order by r.id limit 1);
  perform pg_temp.ck(pg_temp.st('hiljaa@t210.example') = 'waiting' and pg_temp.mails('hiljaa@t210.example', 'waitlist_spot_freed') = 0, 'E2: asetus pois → ei vapautumisviestiä eikä varausta');
  insert into booking.settings(key, value) values ('waitlist_event_notify', 'true'::jsonb)
    on conflict (key) do update set value = excluded.value;

  v_err := null;
  perform test.anon();
  begin
    perform booking.admin_event_waitlist(v_ev);
  exception when others then
    v_err := sqlerrm;
  end;
  perform test.logout();
  perform pg_temp.ck(v_err ilike '%oikeu%' or v_err ilike '%forbidden%' or v_err ilike '%Ei oikeuksia%' or v_err ilike '%permission denied%', 'F1: anon ei saa jonoa');
  perform pg_temp.ck(not has_table_privilege('anon', 'booking.waitlist_notify_log', 'SELECT')
    and not has_table_privilege('anon', 'booking.waitlist_entries', 'SELECT'), 'F2: anon ei lue jonoa eikä lokia');
  v_staff := test.mk_staff('staff210@t210.example', 'admin');
  perform test.login(v_staff);
  v := booking.admin_event_waitlist(v_ev);
  perform test.logout();
  perform pg_temp.ck(jsonb_typeof(v) = 'array' and exists (select 1 from jsonb_array_elements(v) x where x ->> 'customer_email' = 'eka@t210.example')
    and not exists (select 1 from jsonb_array_elements(v) x where x ? 'public_token'), 'F3: henkilökunta näkee jonon ilman tokenia');

  declare v_pass int; v_fail int; v_list text; begin
    select count(*) filter (where ok), count(*) filter (where not ok), string_agg(case when not ok then label end, ' | ') into v_pass, v_fail, v_list from t210_r;
    raise exception 'TESTRESULT pass=% fail=% :: %', v_pass, v_fail, coalesce(v_list, 'ALL OK');
  end;
end $t$;
