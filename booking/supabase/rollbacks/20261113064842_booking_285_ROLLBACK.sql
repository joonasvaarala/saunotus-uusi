-- booking_285 ROLLBACK: poistaa asiakkaiden yhdistämisen ja anonymisoinnin (funktiot, kytkimet, oikeus, lokitaulut, sarakkeet).
-- Ei muuta olemassa olevia funktioita (285 ei muuttanut yhtään), joten funktioiden palautusta ei tarvita.
--
-- PYSÄHTYY (ei muutoksia), jos peruuttamatonta dataa on syntynyt:
--   * booking.customer_merge_log:ssa on rivejä (yhdistettyjä asiakkaita), tai customers.merged_into on asetettu, tai
--   * booking.marketing_suppressions:ssa on rivejä (suppression kuuluu säilyttää, ettei osoite palaa listalle), tai
--   * anonymisointi on ajettu 285:n funktiolla (audit_log-rivi action = 'ANONYMIZE').
-- Yhdistämistä ei voi kumota automaattisesti: tilaukset ym. on siirretty. Käsin palautukseen: customer_merge_log.merge_snapshot (yhdistetyn rivin
-- sisältö) ja customer_merge_log.moved (taulu → siirretyt id:t). Anonymisointia ei voi kumota.
-- Jos haluat silti purkaa rakenteen, hoida data ensin käsin päätöksellä (Joonas) ja aja tämä uudelleen.
-- HUOM (booking_299, 14.11.2026): 299 yhdisti uutiskirjeen kieltolistan marketing_suppressions-tauluun (newsletter_suppressions on nyt näkymä).
--   Aja ENSIN 299:n rollback (rollbacks/20261114004910_booking_299_ROLLBACK.sql), vasta sitten tämä. Muuten tämä pysähtyy
--   marketing_suppressions-rivien takia tai pudottaisi taulun, josta newsletter_suppressions-näkymä ja uutiskirjefunktiot riippuvat.
set local lock_timeout = '5s';

do $g$
begin
  if exists (select 1 from booking.customer_merge_log) then
    raise exception 'booking_285 rollback: customer_merge_log:ssa on % yhdistettyä asiakasta. Ei muutoksia.', (select count(*) from booking.customer_merge_log);
  end if;
  if exists (select 1 from booking.customers where merged_into is not null) then
    raise exception 'booking_285 rollback: customers.merged_into on asetettu. Ei muutoksia.';
  end if;
  if exists (select 1 from booking.marketing_suppressions) then
    raise exception 'booking_285 rollback: marketing_suppressions sisältää % riviä (suppression pitää säilyttää). Ei muutoksia.', (select count(*) from booking.marketing_suppressions);
  end if;
  if exists (select 1 from booking.audit_log where action in ('ANONYMIZE', 'MERGE', 'MERGED_INTO') and table_name = 'customers') then
    raise exception 'booking_285 rollback: audit_logissa on 285:n yhdistämis- tai anonymisointitapahtumia. Ei muutoksia.';
  end if;
end $g$;

drop function if exists booking.admin_anonymize_customer(bigint, text, boolean);
drop function if exists booking.admin_anonymize_customer_preview(bigint);
drop function if exists booking._customer_anonymize_plan(bigint);
drop function if exists booking.admin_merge_customers(bigint, bigint, boolean, text);
drop function if exists booking.admin_merge_customers_preview(bigint, bigint);
drop function if exists booking._customer_merge_plan(bigint, bigint);
drop function if exists booking.admin_customer_admin_status();
drop function if exists booking._customer_move_refs(bigint, bigint);
drop function if exists booking._customer_ref_tables();
drop function if exists booking._customer_flag(text);
drop function if exists booking.is_email_suppressed(text);
drop function if exists booking._email_hash(text);

drop table if exists booking.marketing_suppressions;
drop table if exists booking.customer_merge_log;

drop index if exists booking.customers_merged_into_idx;
alter table booking.customers drop constraint if exists customers_merged_not_self;
alter table booking.customers drop column if exists merged_at;
alter table booking.customers drop column if exists merged_into;

delete from booking.settings where key in ('customer_merge_enabled', 'customer_anonymize_enabled');
delete from booking.role_permissions where permission = 'customers.admin';
comment on table booking.role_permissions is
  'Rooli → oikeus. Oikeudet: bookings.manage, customers.manage, payments.manage, blocks.manage, catalog.edit (tuotteet/hinnat/kuvaukset), '
  'settings.edit, resources.edit (kapasiteettipoolit), rules.edit (vuorosäännöt), annual_cards.manage, staff.manage (käyttäjä- ja roolihallinta, vain admin), audit.read, '
  'shifts.view (omat työvuorot), shifts.view_all (kaikkien työvuorot; lukunäkymä public-skeeman vuorodataan).';
