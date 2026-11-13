-- booking_291: uutiskirjeen vastaanottajatarkistus huomioi myös booking.marketing_suppressions (booking_285).
-- Taustaa: docs/claude/uutiskirje-tila.md kohta 3.4. Peruutuksia on kahdessa taulussa: newsletter_suppressions (259) ja marketing_suppressions (285:n
-- yhdistäminen ja anonymisointi). Lähetys tarkisti vain ensimmäisen, joten yhdistämisen tai anonymisoinnin suppression olisi ohittunut.
-- Ratkaisu: _newsletter_address_blocked tarkistaa kummankin taulun (taulujen tiivisteet ovat samaa muotoa sha256(lower(btrim(email))) hex).
-- _newsletter_recipients, admin_newsletter_dispatch (vastaanottajajoukko ja esikatselun allekirjoitus) ja email_newsletter_payload (tuore tarkistus juuri ennen lähetystä)
-- käyttävät tätä funktiota, joten muita funktioita ei tarvitse muuttaa. Tauluja ei yhdistetä eikä rivejä siirretä tai poisteta.
-- Muuttaa vain yhden funktion. Ennakkotarkistus: prosrc md5 (sama kuin 259/262 PRODissa) ja että 285:n taulu on olemassa.
-- Rollback: ../rollbacks/20261113120100_booking_291_ROLLBACK.sql
set local lock_timeout = '5s';

do $pre$
begin
  if to_regclass('booking.marketing_suppressions') is null then raise exception 'booking_291: booking_285 (marketing_suppressions) puuttuu. Ei muutoksia.'; end if;
  if to_regprocedure('booking._newsletter_address_blocked(text,text)') is null
     or (select md5(prosrc) from pg_catalog.pg_proc where oid = 'booking._newsletter_address_blocked(text,text)'::regprocedure) <> '5d74cdaef9366d7fbc8384e0fc85e6c3' then
    raise exception 'booking_291: _newsletter_address_blocked poikkeaa odotetusta (booking_259). Ei muutoksia.'; end if;
end $pre$;

create or replace function booking._newsletter_address_blocked(p_fingerprint text,p_email text) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from booking.newsletter_suppressions s where s.address_fingerprint=p_fingerprint)
    or exists(select 1 from booking.marketing_suppressions m where m.email_hash=p_fingerprint or m.email_hash=booking._email_hash(p_email))
    or exists(select 1 from booking.customers c
      where c.marketing_unsubscribed_at is not null and lower(btrim(c.email))=lower(btrim(p_email))
        and booking._newsletter_fingerprint(c.email)=p_fingerprint);
$$;
revoke all on function booking._newsletter_address_blocked(text,text) from public, anon, authenticated, service_role;
