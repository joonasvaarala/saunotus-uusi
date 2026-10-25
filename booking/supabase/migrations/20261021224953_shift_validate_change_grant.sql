-- HISTORY-SYNC (repo-only alignment): tuotannossa public._shift_validate_change-funktion oikeus on jo
-- {postgres=X/postgres,service_role=X/postgres}. Se syntyi Supabasen oletusoikeuksista (default privileges: EXECUTE anon/authenticated/
-- service_role) ja migraation 20261021224952_shift_db_first_api revoke-lauseesta (public, anon, authenticated). Tuotannon historiassa
-- ei ole erillistä grant-lausetta, eikä tätä versiota ole schema_migrationsissa.
-- Tämä tiedosto tuottaa saman ACL:n puhtaassa ketjussa (ilman Supabasen oletusoikeuksia). Funktio luodaan ja sen oikeudet perutaan vain
-- migraatiossa 20261021224952, joten tämä tulee heti sen perään. Vartioitu: tuotannossa ja uudelleenajossa no-op.
do $hs$
begin
  if not has_function_privilege('service_role', 'public._shift_validate_change(text, uuid, uuid, text, timestamptz, timestamptz)', 'EXECUTE') then
    grant execute on function public._shift_validate_change(text, uuid, uuid, text, timestamptz, timestamptz) to service_role;
  end if;
end $hs$;
