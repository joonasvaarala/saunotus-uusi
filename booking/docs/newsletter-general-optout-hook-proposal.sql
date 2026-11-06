-- PROPOSAL ONLY — NOT PART OF migration 259. Requires parent + Koodari agreement.
-- Never run automatically. Depends ONLY on retained infrastructure from reviewed 259.
-- Permanent infrastructure: independent of draft/dispatch tables; survives feature rollback.
begin;
set local lock_timeout='5s';
-- Conflicts with INSERT/UPDATE/DELETE. Hold through hook installation AND backfill.
lock table booking.customers in share row exclusive mode;
-- Does NOT replace public_marketing_unsubscribe or change its grants/signature.
-- A tiny AFTER trigger records only address fingerprints in NEWSLETTER suppression.
-- Needed to retain future general marketing opt-outs after profile edits/deletion.
-- No raw addresses, customer ids, send capability, auto-resubscribe or external calls.
create function booking._newsletter_capture_general_optout() returns trigger
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
revoke all on function booking._newsletter_capture_general_optout() from public,anon,authenticated,service_role;
create trigger newsletter_capture_general_optout after insert or update of marketing_consent,marketing_unsubscribed_at on booking.customers
for each row execute function booking._newsletter_capture_general_optout();
-- The ONLY backfill: atomic with trigger installation under the same customer-write lock.
insert into booking.newsletter_suppressions(address_fingerprint)
select distinct booking._newsletter_fingerprint(c.email) from booking.customers c
where c.marketing_unsubscribed_at is not null and booking._valid_email(c.email) on conflict do nothing;
commit;
