-- PALUU: poistaa tarjoussäännöt ja -tarjoukset (020000 + 020100). Ei koske DB-first-synkkaa eikä closure-mallia.
drop trigger if exists shift_offers_guard_trg on public.shift_offers;
drop function if exists public.shift_offers_guard();
drop function if exists public.shift_offer_allowed(text, date);
drop function if exists public.shift_exhausted_next_step(text, timestamptz, int, timestamptz, timestamptz);
drop function if exists public.shift_offer_respond(uuid, uuid, text, timestamptz, boolean, text);
drop function if exists public.shift_service_closure_needed(text, date, uuid);
drop function if exists public.shift_offer_wait(text, timestamptz, timestamptz, boolean);
drop function if exists public.shift_add_active_time(timestamptz, interval, text);
drop function if exists public.shift_offer_candidates(text, date, int, text, timestamptz, timestamptz);
drop function if exists public.shift_staff_restricted(text, uuid, date);
drop function if exists public.shift_default_owner(text, date);
drop function if exists public.shift_week_parity(date);
alter table if exists public.shift_offers drop constraint if exists shift_offers_accepted_recipient_fkey;
drop table if exists public.shift_offer_recipients, public.shift_offers,
  public.shift_service_date_overrides, public.shift_service_allowed_therapists,
  public.shift_offer_response_tiers, public.shift_staff_restrictions,
  public.shift_offer_round_members, public.shift_offer_rounds,
  public.shift_default_owners, public.shift_offer_settings;
