-- DISPOSABLE LOCAL DATABASE ONLY.259 now installs capture in its own atomic transaction.
-- Check installed guards without disabling/replacing any trigger or function.
do $$declare sig text;definition text;begin
 foreach sig in array array['booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid)','booking.email_newsletter_payload(bigint)']loop
  select pg_get_functiondef(to_regprocedure(sig))into definition;
  if definition is null or position('newsletter_capture_general_optout' in definition)=0
   or position('tgenabled' in definition)=0 or position('to_regprocedure' in definition)=0 then
   raise exception 'Capture hard gate missing from dispatch/payload';end if;
 end loop;
 if not exists(select 1 from pg_trigger where tgrelid='booking.customers'::regclass and tgname='newsletter_capture_general_optout'and tgenabled='O')then
  raise exception 'Atomic259 did not install enabled capture';end if;
end$$;
