-- booking_299_suppressions_unify: yksi kieltolista (Joonas t1731u, 13.11.2026 yötyö).
-- Ennen: booking.marketing_suppressions (booking_285: yhdistäminen/anonymisointi, is_email_suppressed) ja
--        booking.newsletter_suppressions (booking_259/262: uutiskirjeen peruutus + yleisen markkinointiperuutuksen trigger).
--        Molempien avain on sama tiiviste sha256(lower(btrim(email))) hex, joten rivit voi yhdistää suoraan.
-- Jälkeen: booking.marketing_suppressions on AINOA kieltolista (taulu). Uusi sarake newsletter_unsubscribed_at säilyttää
--        uutiskirjelistan aikaleiman, uusi reason 'newsletter_unsubscribed' merkitsee vain uutiskirjelistalla olleet rivit.
--        booking.newsletter_suppressions on nyt automaattisesti päivittyvä näkymä (security_invoker) yhdistettyyn tauluun:
--        vanhat luvut näkevät KAIKKI kiellot ja vanhat kirjoitukset (insert (address_fingerprint) ... on conflict do nothing)
--        osuvat yhdistettyyn tauluun (näkymän oletukset reason='newsletter_unsubscribed', source='newsletter', newsletter_unsubscribed_at=now()).
--        Alkuperäinen newsletter_suppressions-taulu jää koskemattomana varmuuskopioksi nimellä booking.newsletter_suppressions_premerge_299.
-- Funktiot: _newsletter_address_blocked lukee yhdistettyä taulua; public_newsletter_unsubscribe ja _newsletter_capture_general_optout
--        kirjoittavat suoraan yhdistettyyn tauluun; is_email_suppressed lukee jo marketing_suppressions-taulua (nyt kaikki kiellot).
-- Ei lähetä viestejä, ei muuta lippuja. Rollback: booking_299_ROLLBACK.sql (samassa hakemistossa).
set local lock_timeout = '5s';

do $pre$
begin
  if (select relkind from pg_catalog.pg_class where oid = to_regclass('booking.marketing_suppressions')) is distinct from 'r'
     or (select relkind from pg_catalog.pg_class where oid = to_regclass('booking.newsletter_suppressions')) is distinct from 'r' then
    raise exception 'booking_299: odotettiin kahta taulua (marketing_suppressions, newsletter_suppressions). Ei muutoksia.';
  end if;
  if to_regclass('booking.newsletter_suppressions_premerge_299') is not null then
    raise exception 'booking_299: newsletter_suppressions_premerge_299 on jo olemassa. Ei muutoksia.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='booking' and table_name='marketing_suppressions' and column_name='newsletter_unsubscribed_at') then
    raise exception 'booking_299: newsletter_unsubscribed_at on jo olemassa. Ei muutoksia.';
  end if;
  if (select md5(prosrc) from pg_catalog.pg_proc where oid = to_regprocedure('booking._newsletter_address_blocked(text,text)')) is distinct from '5d74cdaef9366d7fbc8384e0fc85e6c3'
     or (select md5(prosrc) from pg_catalog.pg_proc where oid = to_regprocedure('booking.public_newsletter_unsubscribe(uuid)')) is distinct from '8e9a85606577162d5bc750048fc658b8'
     or (select md5(prosrc) from pg_catalog.pg_proc where oid = to_regprocedure('booking._newsletter_capture_general_optout()')) is distinct from '2bbbc342f214f003c3e755d627b134d6'
     or (select md5(prosrc) from pg_catalog.pg_proc where oid = to_regprocedure('booking.is_email_suppressed(text)')) is distinct from 'd70a510338abe274b674bc710a91f7df' then
    raise exception 'booking_299: kieltolistafunktiot poikkeavat odotetusta (259/262/285). Ei muutoksia.';
  end if;
  if exists (select 1 from pg_catalog.pg_trigger where tgrelid in ('booking.marketing_suppressions'::regclass,'booking.newsletter_suppressions'::regclass) and not tgisinternal)
     or exists (select 1 from pg_catalog.pg_policies where schemaname='booking' and tablename in ('marketing_suppressions','newsletter_suppressions'))
     or exists (select 1 from pg_catalog.pg_constraint where confrelid in ('booking.marketing_suppressions'::regclass,'booking.newsletter_suppressions'::regclass)) then
    raise exception 'booking_299: tauluissa odottamattomia triggereitä/policyjä/viiteavaimia. Ei muutoksia.';
  end if;
end $pre$;

lock table booking.marketing_suppressions, booking.newsletter_suppressions in access exclusive mode;

-- 1) Yhdistetty taulu: uusi sarake ja syy
alter table booking.marketing_suppressions add column newsletter_unsubscribed_at timestamptz;
alter table booking.marketing_suppressions drop constraint marketing_suppressions_reason_check;
alter table booking.marketing_suppressions add constraint marketing_suppressions_reason_check
  check (reason = any (array['unsubscribed','anonymized','merged_unsubscribed','newsletter_unsubscribed']));
comment on column booking.marketing_suppressions.newsletter_unsubscribed_at is
  'booking_299: milloin osoite kirjattiin uutiskirjeen kieltolistaan (vanha newsletter_suppressions). Mikä tahansa rivi estää kaikki markkinointiviestit ja uutiskirjeet.';
comment on table booking.marketing_suppressions is
  'booking_299: AINOA kieltolista (tiiviste sha256(lower(btrim(email))) hex). Yhdistää booking_285:n marketing_suppressions- ja booking_259:n newsletter_suppressions-rivit. booking.newsletter_suppressions on yhteensopivuusnäkymä tähän tauluun.';

-- 2) Rivien yhdistäminen. Tiivisteet normalisoidaan (lower/btrim; CHECK takaa 64 hex-merkkiä). Duplikaatissa markkinointirivin syy/lähde/aikaleima
--    säilyy ja uutiskirjeen aikaleima tallentuu newsletter_unsubscribed_at-sarakkeeseen (varhaisin, jos useita).
insert into booking.marketing_suppressions as m (email_hash, reason, source, created_at, newsletter_unsubscribed_at)
select lower(btrim(n.address_fingerprint)), 'newsletter_unsubscribed', 'newsletter_suppressions_299', min(n.unsubscribed_at), min(n.unsubscribed_at)
from booking.newsletter_suppressions n
group by lower(btrim(n.address_fingerprint))
on conflict (email_hash) do update
  set newsletter_unsubscribed_at = least(coalesce(m.newsletter_unsubscribed_at, excluded.newsletter_unsubscribed_at), excluded.newsletter_unsubscribed_at);

-- tarkistus: jokainen vanha uutiskirjerivi löytyy yhdistetystä taulusta
do $chk$
begin
  if exists (select 1 from booking.newsletter_suppressions n
             where not exists (select 1 from booking.marketing_suppressions m where m.email_hash = lower(btrim(n.address_fingerprint)))) then
    raise exception 'booking_299: yhdistämisessä puuttuu rivejä. Ei muutoksia.';
  end if;
end $chk$;

-- 3) Vanha taulu talteen koskemattomana, tilalle yhteensopivuusnäkymä
alter table booking.newsletter_suppressions rename to newsletter_suppressions_premerge_299;
comment on table booking.newsletter_suppressions_premerge_299 is
  'booking_299: alkuperäinen newsletter_suppressions-taulu yhdistämishetkellä (varmuuskopio rollbackia varten). EI käytössä; kiellot ovat booking.marketing_suppressions-taulussa.';
revoke all on booking.newsletter_suppressions_premerge_299 from public, anon, authenticated, service_role;

create view booking.newsletter_suppressions with (security_invoker = true) as
  select m.email_hash as address_fingerprint,
         m.created_at as unsubscribed_at,
         m.reason,
         m.source,
         m.newsletter_unsubscribed_at
  from booking.marketing_suppressions m;
alter view booking.newsletter_suppressions alter column unsubscribed_at set default now();
alter view booking.newsletter_suppressions alter column reason set default 'newsletter_unsubscribed';
alter view booking.newsletter_suppressions alter column source set default 'newsletter';
alter view booking.newsletter_suppressions alter column newsletter_unsubscribed_at set default now();
comment on view booking.newsletter_suppressions is
  'booking_299: yhteensopivuusnäkymä. Luvut ja kirjoitukset (myös insert ... on conflict) osuvat booking.marketing_suppressions-tauluun. Uusi koodi: käytä marketing_suppressions-taulua tai is_email_suppressed().';
revoke all on booking.newsletter_suppressions from public, anon, authenticated, service_role;
do $g$ begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'backup_reader') then
    execute 'grant select on booking.newsletter_suppressions to backup_reader';
  end if;
end $g$;

-- 4) Funktiot lukemaan/kirjoittamaan yhdistettyä listaa
create or replace function booking._newsletter_address_blocked(p_fingerprint text, p_email text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from booking.marketing_suppressions m
                where m.email_hash = lower(btrim(p_fingerprint)) or m.email_hash = booking._email_hash(p_email))
    or exists(select 1 from booking.customers c
      where c.marketing_unsubscribed_at is not null and lower(btrim(c.email)) = lower(btrim(p_email))
        and booking._newsletter_fingerprint(c.email) = p_fingerprint);
$$;
revoke all on function booking._newsletter_address_blocked(text,text) from public, anon, authenticated, service_role;

create or replace function booking.public_newsletter_unsubscribe(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$ begin
  insert into booking.marketing_suppressions as m (email_hash, reason, source, newsletter_unsubscribed_at)
    select lower(btrim(t.address_fingerprint)), 'newsletter_unsubscribed', 'newsletter_unsubscribe', now()
    from booking.newsletter_optout_tokens t where t.token = p_token
    on conflict (email_hash) do update set newsletter_unsubscribed_at = coalesce(m.newsletter_unsubscribed_at, excluded.newsletter_unsubscribed_at);
  return jsonb_build_object('ok', true);
end $$;

create or replace function booking._newsletter_capture_general_optout() returns trigger
language plpgsql security definer set search_path = '' as $$ begin
  if tg_op = 'INSERT' then
    if new.marketing_unsubscribed_at is not null and booking._valid_email(new.email) then
      insert into booking.marketing_suppressions(email_hash, reason, source, customer_id, newsletter_unsubscribed_at)
      values (booking._newsletter_fingerprint(new.email), 'unsubscribed', 'customer_optout', null, now()) on conflict do nothing;
    end if;
  elsif (old.marketing_consent is true and new.marketing_consent is not true)
      or (new.marketing_unsubscribed_at is not null and new.marketing_unsubscribed_at is distinct from old.marketing_unsubscribed_at) then
    if booking._valid_email(old.email) then
      insert into booking.marketing_suppressions(email_hash, reason, source, customer_id, newsletter_unsubscribed_at)
      values (booking._newsletter_fingerprint(old.email), 'unsubscribed', 'customer_optout', null, now()) on conflict do nothing;
    end if;
    if booking._valid_email(new.email) then
      insert into booking.marketing_suppressions(email_hash, reason, source, customer_id, newsletter_unsubscribed_at)
      values (booking._newsletter_fingerprint(new.email), 'unsubscribed', 'customer_optout', null, now()) on conflict do nothing;
    end if;
  end if;
  return new;
end $$;
