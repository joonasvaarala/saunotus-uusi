-- Testiapufunktiot (vain testitietokantaan). Roolin vaihto + JWT-väitteet, testikäyttäjät, päivämäärähaut.
create schema if not exists test;
create sequence if not exists test.seq;
grant usage on sequence test.seq to public;
grant usage on schema test to public;

create or replace function test.login(p_user uuid, p_role text default 'authenticated') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', p_role)::text, true);
  execute format('set local role %I', p_role);
end $$;
create or replace function test.anon(p_ip text default null) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.headers', case when p_ip is null then '' else json_build_object('x-forwarded-for', p_ip)::text end, true);
  set local role anon;
end $$;
create or replace function test.service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
end $$;
create or replace function test.logout() returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);
end $$;
create or replace function test.mk_user(p_email text) returns uuid language sql as $$
  insert into auth.users(email) values (p_email) on conflict (email) do update set email = excluded.email returning id
$$;
create or replace function test.mk_staff(p_email text, p_role text) returns uuid language plpgsql as $$
declare u uuid := test.mk_user(p_email);
begin
  insert into booking.staff(user_id, email, name, role) values (u, p_email, p_email, p_role)
  on conflict (user_id) do update set role = excluded.role, active = true;
  return u;
end $$;
-- seuraava annettu viikonpäivä (ISO 1=ma) vähintään p_min_days päivän päässä (Helsingin aikaa)
create or replace function test.next_dow(p_isodow int, p_min_days int default 3) returns date language sql stable as $$
  select d::date from generate_series(((now() at time zone 'Europe/Helsinki')::date + p_min_days)::timestamp,
                                      ((now() at time zone 'Europe/Helsinki')::date + p_min_days + 6)::timestamp, interval '1 day') d
   where extract(isodow from d) = p_isodow limit 1
$$;
create or replace function test.rule(p_label_like text) returns bigint language sql stable as $$
  select id from booking.schedule_rules where label like p_label_like and active order by id limit 1
$$;
-- public_create_booking-oikotie (palauttaa jsonb)
create or replace function test.pub_book(p_rule bigint, p_date date, p_persons int, p_email text default null, p_name text default 'Testi Asiakas')
returns jsonb language sql as $$
  select booking.public_create_booking(p_rule, p_date, p_persons, p_name,
         coalesce(p_email, 'asiakas' || nextval('test.seq') || '@example.com'), '0401234567', false, 'fi', null)
$$;
-- Lukufunktiot testeille, jotka ajetaan anon-/authenticated-roolina (suora taulu-lukuoikeus puuttuu): token → rivi
create or replace function test.res(p_token uuid) returns booking.reservations language sql stable security definer set search_path = '' as $$
  select r.* from booking.reservations r join booking.orders o on o.id = r.order_id where o.public_token = p_token order by r.id limit 1 $$;
create or replace function test.ord(p_token uuid) returns booking.orders language sql stable security definer set search_path = '' as $$
  select o.* from booking.orders o where o.public_token = p_token $$;
create or replace function test.item(p_token uuid) returns booking.order_items language sql stable security definer set search_path = '' as $$
  select i.* from booking.order_items i join booking.orders o on o.id = i.order_id where o.public_token = p_token order by i.id limit 1 $$;
create or replace function test.pay(p_token uuid) returns booking.payments language sql stable security definer set search_path = '' as $$
  select p.* from booking.payments p join booking.orders o on o.id = p.order_id where o.public_token = p_token order by p.id limit 1 $$;
create or replace function test.cnt_res(p_token uuid) returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::int from booking.reservations r join booking.orders o on o.id = r.order_id where o.public_token = p_token $$;
create or replace function test.audit_n(p_action text) returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::int from booking.audit_log where action = p_action $$;
create or replace function test.hel_date(p_ts timestamptz) returns date language sql immutable as $$ select (p_ts at time zone 'Europe/Helsinki')::date $$;
create or replace function test.hel_hm(p_ts timestamptz) returns text language sql immutable as $$ select to_char(p_ts at time zone 'Europe/Helsinki', 'HH24:MI') $$;
-- Suorittaa lauseen ja palauttaa BK001-virheen DETAIL-koodin (tai SQLSTATEn / 'ok'); ei kaada transaktiota
create or replace function test.code(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  return coalesce(d, sqlstate);
end $$;
create or replace function test.reset_rl() returns void language sql security definer set search_path = '' as $$ delete from booking.rate_limit_hits $$;
grant execute on all functions in schema test to public;
