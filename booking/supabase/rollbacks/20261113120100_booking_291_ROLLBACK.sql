-- booking_291 ROLLBACK: palauttaa _newsletter_address_blocked-funktion booking_259:n runkoon (tarkistaa vain newsletter_suppressions + asiakasrivin peruutuksen).
-- EI koske suppressiodataan (newsletter_suppressions, marketing_suppressions). Huom: rollbackin jälkeen 285:n yhdistämisen/anonymisoinnin suppressio ei
-- estä uutiskirjettä; älä avaa kytkintä newsletter_enabled ennen kuin 291 on uudelleen käytössä.
set local lock_timeout = '5s';

create or replace function booking._newsletter_address_blocked(p_fingerprint text,p_email text) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from booking.newsletter_suppressions s where s.address_fingerprint=p_fingerprint)
    or exists(select 1 from booking.customers c
      where c.marketing_unsubscribed_at is not null and lower(btrim(c.email))=lower(btrim(p_email))
        and booking._newsletter_fingerprint(c.email)=p_fingerprint);
$$;
revoke all on function booking._newsletter_address_blocked(text,text) from public, anon, authenticated, service_role;
