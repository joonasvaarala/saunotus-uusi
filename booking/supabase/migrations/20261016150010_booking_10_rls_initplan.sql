-- 10. RLS-politiikat: auth_rls_initplan (Supabase advisor WARN). Funktiokutsut politiikoissa kääritään muotoon (select …), jolloin Postgres
-- laskee ne kerran kyselyä kohti (InitPlan) eikä jokaiselle riville. Semantiikka ei muutu (kaikki kutsutut funktiot ovat STABLE).
-- Korvaa: staff_self_read (auth.uid() → (select auth.uid())) sekä muut booking-skeeman politiikat (is_staff(), has_permission(…)) samalla tavalla.
-- Ajettu 01–09 jo tuotantoon: tämä on UUSI migraatio, joka ei muokkaa aiempia. Idempotentti (drop policy if exists + create policy).
begin;

-- henkilöstö: jokainen näkee oman rivinsä; kaikki rivit vain oikeudella staff.manage (alkuperäinen: migraatio 07)
drop policy if exists staff_self_read on booking.staff;
create policy staff_self_read on booking.staff for select to authenticated
  using (user_id = (select auth.uid()) or (select booking.has_permission('staff.manage')));

-- audit-loki: vain oikeudella audit.read (alkuperäinen: migraatio 07)
drop policy if exists audit_admin_read on booking.audit_log;
create policy audit_admin_read on booking.audit_log for select to authenticated
  using ((select booking.has_permission('audit.read')));

-- staff_read: kaikki muut luettavat taulut (alkuperäinen: migraatio 07, silmukka); taulut haetaan nykyisistä politiikoista, joten lista ei voi erkaantua
do $$
declare r record;
begin
  for r in select tablename from pg_policies where schemaname = 'booking' and policyname = 'staff_read' order by tablename loop
    execute format('drop policy if exists staff_read on booking.%I', r.tablename);
    execute format('create policy staff_read on booking.%I for select to authenticated using ((select booking.is_staff()))', r.tablename);
  end loop;
end $$;

commit;
