-- APPLIED 2026-10-16 (Europe/Helsinki ~23:25): version 20261016202553 (booking_13_audit_skip) via apply_migration; sama SQL kuin tässä tiedostossa.
-- booking_13_audit_skip
-- Joonas hyväksyi ajon chatissa 16.10.2026. Audit-ohitus massatuonnille (PLAN.md §7.2 vaihtoehto B).
-- Ongelma: Johku-tuonti tuottaisi ~44 000 audit_log-riviä (rivikohtaiset JSON-kopiot henkilötiedoista).
-- Ratkaisu: audit_trg ohittaa kirjauksen, kun transaktiossa on set_config('booking.skip_audit','on', true) JA kutsuja on
--   privilegioitu: JWT-rooli (booking._jwt_role()) puuttuu (suora tietokantayhteys: postgres/tuontiputki) tai on service_role.
-- Turvallisuus:
--  * authenticated/anon -pyyntö (PostgREST asettaa request.jwt.claims role='authenticated'|'anon') ei voi ohittaa auditointia, vaikka
--    GUC jotenkin olisi 'on': ehto vaatii jwt-roolin null/service_role. set_config ei ole kutsuttavissa API:n kautta (pg_catalog ei ole
--    julkisessa API:ssa; booking-funktiot eivät aseta GUC:ia).
--  * audit_trg on SECURITY DEFINER, joten current_user on aina omistaja -> siksi rooli luetaan JWT-claimista, ei current_userista.
--  * Tuonti käyttää set_config(..., true) (transaktiopaikallinen) -> ohitus ei vuoda muille transaktioille/yhteyksille.
--  * Normaali polku (GUC puuttuu/ei 'on') on täsmälleen ennallaan, myös UPDATE-ilman-muutosta -ohitus.
--  * Funktion oikeudet ennallaan (CREATE OR REPLACE): postgres + service_role. Ei uusia funktioita eikä taulumuutoksia.
--  * Vain audit_trg ohittuu; customers_consent yms. triggerit eivät. Kattaa kaikki taulut joilla audit_trg on (myös tulevat _add_audit-taulut).
--  * Rajoitus: ALTER DATABASE/ROLE ... SET booking.skip_audit='on' (vain superuser/omistaja) ohittaisi auditoinnin pysyvästi -> älä aseta.
-- Käyttö tuontiputkessa (service_role / suora yhteys), samassa transaktiossa kuin kirjoitukset:
--   select set_config('booking.skip_audit', 'on', true);

create or replace function booking.audit_trg()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  o jsonb; n jsonb; pk text;
begin
  -- massatuonnin audit-ohitus: vain privilegioidulle kutsujalle (ei authenticated/anon)
  if coalesce(current_setting('booking.skip_audit', true), '') = 'on'
     and coalesce(booking._jwt_role(), 'service_role') = 'service_role' then
    return null;
  end if;
  if tg_op in ('UPDATE','DELETE') then o := to_jsonb(old); end if;
  if tg_op in ('INSERT','UPDATE') then n := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and o = n then return null; end if;
  pk := coalesce(n ->> 'id', n ->> 'key', n ->> 'user_id', n ->> 'product_id', n ->> 'code',
                 o ->> 'id', o ->> 'key', o ->> 'user_id', o ->> 'product_id', o ->> 'code');
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), tg_table_name, pk, tg_op, o, n);
  return null;
end $function$;
