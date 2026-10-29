-- ROLLBACK booking_215: poistaa maksulinkkien muistutukset ja seurantanäkymän RPC:t.
-- Palauttaa email_outbox_claimin booking_202-tilaan (email_outbox_claim_base_215 → email_outbox_claim).
-- Muistutusviestit jonosta poistetaan, jotta lajirajoite voidaan palauttaa. Maksuja ja tilauksia ei poisteta.

do $$
begin
  if to_regnamespace('cron') is not null and to_regprocedure('cron.unschedule(text)') is not null
     and exists (select 1 from cron.job where jobname = 'booking_payment_link_reminders') then
    perform cron.unschedule('booking_payment_link_reminders');
  end if;
exception when others then
  raise notice 'booking_215 rollback: cron-peruutus ohitettu: %', sqlerrm;
end $$;

drop trigger if exists payments_reminder_stop on booking.payments;

drop function if exists booking.admin_payment_link_mark_handled(bigint, text, text);
drop function if exists booking.admin_payment_link_pause_reminders(bigint);
drop function if exists booking.admin_payment_link_remind_now(bigint);
drop function if exists booking.admin_list_payment_link_watch(text, text, integer, integer);
drop function if exists booking.payment_link_reminders_sweep(timestamptz);
drop function if exists booking.payments_reminder_stop_trg();
drop function if exists booking._plr_enqueue(bigint, bigint, integer, text, timestamptz, boolean, timestamptz);
drop function if exists booking._plr_plan(bigint, timestamptz, timestamptz, jsonb, timestamptz);
drop function if exists booking._plr_is_tracked(bigint, timestamptz);
drop function if exists booking._plr_link_kind(timestamptz, timestamptz, jsonb);
drop function if exists booking._plr_next_open(timestamptz);
drop function if exists booking._plr_in_window(timestamptz);
drop function if exists booking._plr_window();
drop function if exists booking._plr_enabled();
drop function if exists booking._plr_hours(text, integer, integer, integer);

do $$
begin
  if to_regprocedure('booking.email_outbox_claim_base_215(integer)') is not null then
    drop function if exists booking.email_outbox_claim(integer);
    alter function booking.email_outbox_claim_base_215(integer) rename to email_outbox_claim;
    grant execute on function booking.email_outbox_claim(integer) to service_role;
  end if;
end $$;

delete from booking.email_outbox where kind = 'payment_link_reminder';

do $$
declare def text;
begin
  select pg_get_constraintdef(c.oid) into def
    from pg_constraint c
   where c.conrelid = 'booking.email_outbox'::regclass and c.conname = 'email_outbox_kind_check';
  if def is null or position('payment_link_reminder' in def) = 0 then return; end if;
  def := replace(def, '''payment_link_reminder''::text, ', '');
  execute 'alter table booking.email_outbox drop constraint email_outbox_kind_check';
  execute 'alter table booking.email_outbox add constraint email_outbox_kind_check ' || def;
end $$;

drop table if exists booking.payment_link_reminders;

alter table booking.payments drop column if exists reminders_paused_at;
alter table booking.payments drop column if exists reminders_handled_at;
alter table booking.payments drop column if exists reminders_needs_action;

drop index if exists booking.payments_open_paylink_idx;

delete from booking.settings where key in (
  'payment_link.reminders_enabled',
  'payment_link.remind_prepaid_after_hours',
  'payment_link.remind_before_expiry_hours',
  'payment_link.remind_onsite_interval_hours',
  'payment_link.remind_onsite_max',
  'payment_link.remind_window'
);
