-- ============================================================
-- booking_83_counter_expire: maksamattomat pikakassa- ja kylmälaitetilaukset vanhenevat ilman tilakyselyä.
-- Ei korvaa booking.expire_holds / _expire_holds (ne koskevat varauksia, joiden hold_kind ei ole null).
-- Kassatilauksella ei ole varausta eikä hold_kindia, joten niille on oma funktio ja oma cron-rivi.
-- 30 min: sama raja kuin booking._counter_expire. Elävä pending-maksu (ei manual) estää vanhenemisen.
-- Rollback: rollbacks/20261019001300_booking_83_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

create or replace function booking.expire_counter_orders()
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer := 0; r record; v_before text;
begin
  for r in
    select o.id from booking.orders o
     where o.status = 'pending'
       and o.source_channel in ('pikakassa', 'kylmalaite')
       and o.created_at < now() - interval '30 minutes'
     order by o.id
  loop
    select o.status into v_before from booking.orders o where o.id = r.id;
    perform booking._counter_expire(r.id);
    if v_before = 'pending' and (select status from booking.orders where id = r.id) = 'expired' then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

revoke all on function booking.expire_counter_orders() from public, anon, authenticated;
grant execute on function booking.expire_counter_orders() to service_role;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and not exists (select 1 from cron.job where jobname = 'booking_expire_counter_orders') then
    perform cron.schedule('booking_expire_counter_orders', '* * * * *', 'select booking.expire_counter_orders()');
  end if;
exception when others then
  raise notice 'pg_cron-ajastus ohitettu: %', sqlerrm;
end $$;
