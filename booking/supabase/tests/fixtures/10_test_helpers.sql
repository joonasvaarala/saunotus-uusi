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
grant execute on all functions in schema test to public;
