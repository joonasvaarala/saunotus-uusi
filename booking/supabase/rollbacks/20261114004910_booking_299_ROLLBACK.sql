-- booking_299 ROLLBACK: palauttaa kaksi erillistä taulua.
--  * booking.newsletter_suppressions = alkuperäinen taulu (newsletter_suppressions_premerge_299, rivit koskemattomina)
--      + migraation jälkeen kirjatut uutiskirjekiellot (newsletter_unsubscribed_at ei null), jottei yhtään kieltoa katoa.
--  * booking.marketing_suppressions = rivit, joiden reason <> 'newsletter_unsubscribed' (alkuperäiset 285-rivit + migraation jälkeen
--      kirjatut markkinointikiellot; yleisen peruutuksen triggerin rivit jäävät myös tänne = ylimääräinen, ei haitallinen kielto).
--      Sarake newsletter_unsubscribed_at poistetaan ja reason-CHECK palautetaan 285:n muotoon.
--  * Funktiot _newsletter_address_blocked, public_newsletter_unsubscribe ja _newsletter_capture_general_optout palautetaan 259/262-runkoihin
--      (prosrc md5:t 5d74cdae..., 8e9a8560..., 2bbbc342...). is_email_suppressed ei muuttunut.
-- Huom: alkuperäiset rivit on myös tiedostoissa backup_299_suppressions_{dev,prod}.json ja backup_299_*_{dev,prod}.csv tässä hakemistossa.
set local lock_timeout = '5s';

do $pre$ begin
  if to_regclass('booking.newsletter_suppressions_premerge_299') is null
     or (select relkind from pg_catalog.pg_class where oid = to_regclass('booking.newsletter_suppressions')) is distinct from 'v' then
    raise exception 'booking_299 rollback: 299 ei ole käytössä (premerge-taulu tai näkymä puuttuu). Ei muutoksia.';
  end if;
end $pre$;

lock table booking.marketing_suppressions, booking.newsletter_suppressions_premerge_299 in access exclusive mode;

-- 1) Näkymä pois, alkuperäinen taulu takaisin omalle nimelleen
drop view booking.newsletter_suppressions;
alter table booking.newsletter_suppressions_premerge_299 rename to newsletter_suppressions;
comment on table booking.newsletter_suppressions is null;
revoke all on booking.newsletter_suppressions from public, anon, authenticated, service_role;
do $g$ begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'backup_reader') then
    execute 'grant select on booking.newsletter_suppressions to backup_reader';
  end if;
end $g$;

-- 2) Migraation jälkeen kirjatut uutiskirjekiellot vanhaan tauluun
insert into booking.newsletter_suppressions(address_fingerprint, unsubscribed_at)
select m.email_hash, m.newsletter_unsubscribed_at from booking.marketing_suppressions m
where m.newsletter_unsubscribed_at is not null
on conflict (address_fingerprint) do nothing;

-- 3) Vain uutiskirjelistalta tulleet rivit pois markkinointitaulusta (ne ovat nyt newsletter_suppressions-taulussa)
do $chk$ begin
  if exists (select 1 from booking.marketing_suppressions m where m.reason = 'newsletter_unsubscribed'
             and not exists (select 1 from booking.newsletter_suppressions n where n.address_fingerprint = m.email_hash)) then
    raise exception 'booking_299 rollback: uutiskirjerivi puuttuisi palautuksesta. Ei muutoksia.';
  end if;
end $chk$;
delete from booking.marketing_suppressions where reason = 'newsletter_unsubscribed';
alter table booking.marketing_suppressions drop constraint marketing_suppressions_reason_check;
alter table booking.marketing_suppressions add constraint marketing_suppressions_reason_check
  check (reason = any (array['unsubscribed','anonymized','merged_unsubscribed']));
alter table booking.marketing_suppressions drop column newsletter_unsubscribed_at;
comment on table booking.marketing_suppressions is 'booking_285: osoitteet, joille ei lähetetä markkinointia, vaikka asiakasrivi on anonymisoitu tai yhdistetty. Vain tiiviste. Tarkistus: booking.is_email_suppressed(email).';

create or replace function booking._newsletter_address_blocked(p_fingerprint text,p_email text) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from booking.newsletter_suppressions s where s.address_fingerprint=p_fingerprint)
    or exists(select 1 from booking.customers c
      where c.marketing_unsubscribed_at is not null and lower(btrim(c.email))=lower(btrim(p_email))
        and booking._newsletter_fingerprint(c.email)=p_fingerprint);
$$;
revoke all on function booking._newsletter_address_blocked(text,text) from public, anon, authenticated, service_role;

create or replace function booking.public_newsletter_unsubscribe(p_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$ begin
  insert into booking.newsletter_suppressions(address_fingerprint)
    select t.address_fingerprint from booking.newsletter_optout_tokens t where t.token=p_token
    on conflict do nothing;
  return jsonb_build_object('ok',true);
end $$;

create or replace function booking._newsletter_capture_general_optout() returns trigger
language plpgsql security definer set search_path='' as $$ begin
  if tg_op='INSERT' then
    if new.marketing_unsubscribed_at is not null and booking._valid_email(new.email) then
      insert into booking.newsletter_suppressions(address_fingerprint)
      values(booking._newsletter_fingerprint(new.email)) on conflict do nothing;
    end if;
  elsif (old.marketing_consent is true and new.marketing_consent is not true)
      or (new.marketing_unsubscribed_at is not null and new.marketing_unsubscribed_at is distinct from old.marketing_unsubscribed_at) then
    if booking._valid_email(old.email) then
      insert into booking.newsletter_suppressions(address_fingerprint)
      values(booking._newsletter_fingerprint(old.email)) on conflict do nothing;
    end if;
    if booking._valid_email(new.email) then
      insert into booking.newsletter_suppressions(address_fingerprint)
      values(booking._newsletter_fingerprint(new.email)) on conflict do nothing;
    end if;
  end if;
  return new;
end $$;

do $post$ begin
  if (select md5(prosrc) from pg_catalog.pg_proc where oid='booking._newsletter_address_blocked(text,text)'::regprocedure) <> '5d74cdaef9366d7fbc8384e0fc85e6c3'
     or (select md5(prosrc) from pg_catalog.pg_proc where oid='booking.public_newsletter_unsubscribe(uuid)'::regprocedure) <> '8e9a85606577162d5bc750048fc658b8'
     or (select md5(prosrc) from pg_catalog.pg_proc where oid='booking._newsletter_capture_general_optout()'::regprocedure) <> '2bbbc342f214f003c3e755d627b134d6' then
    raise exception 'booking_299 rollback: palautettujen funktioiden md5 ei täsmää 259/262:een. Ei muutoksia.';
  end if;
end $post$;
