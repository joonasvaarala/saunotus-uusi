-- DISPOSABLE LOCAL DATABASE ONLY. Commits synthetic fixtures / real newsletter queue rows.
-- Never hosted: fixture-wide consent/config changes, no email transport invocation.
begin;
create temp table newsletter_identity_history(uid uuid,customer_id bigint,campaign_id bigint,log_id bigint,outbox_id bigint,payload jsonb,dedupe_key text);
do $$declare u uuid:=gen_random_uuid();c bigint;d jsonb;x jsonb;n bigint;v integer;l bigint;e booking.email_outbox;begin
 update booking.customers set marketing_consent=false where marketing_consent;
 update booking.integration_config set mode='dry_run'where key='resend';
 insert into booking.settings(key,value) values('newsletter_enabled','true'::jsonb) on conflict (key) do update set value='true'::jsonb; -- booking_306: kytkin auki kertakäyttökannassa
 insert into auth.users(id,email)values(u,'n259-identity-'||u||'@example.test');
 insert into booking.staff(user_id,email,name,role)values(u,'n259-identity-'||u||'@example.test','Identity fixture','manager');
 insert into booking.customers(name,email,marketing_consent,marketing_consent_at)
 values('Identity recipient','n259-identity-'||gen_random_uuid()||'@example.test',true,now())returning id into c;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
 d:=booking.svc_newsletter_save(null,'{"subject_fi":"Vanha","subject_en":"Old","body_fi":"Testi","body_en":"Test","style":{"layout":"letter"},"segment":"all"}');
 n:=(d->>'id')::bigint;v:=(d->>'version')::integer;x:=booking.admin_newsletter_dispatch(n,v,false);
 if x->>'recipient_count'<>'1'then raise exception 'Identity fixture must have exactly one recipient';end if;
 x:=booking.admin_newsletter_dispatch(n,v,true,(x->>'preview_token')::uuid);
 if x->>'queued_count'<>'1'then raise exception 'Old real campaign not queued';end if;
 select id into l from booking.newsletter_logs where newsletter_id=n;
 select * into e from booking.email_outbox where kind='newsletter'and payload->>'newsletter_log_id'=l::text and payload->>'customer_id'=c::text;
 if e.id is null or e.payload->>'address_fingerprint' is null or e.dedupe_key<>'newsletter:'||l||':'||c then raise exception 'Old campaign lacks actual dispatch payload/key';end if;
 update booking.email_outbox set status='sent'where id=e.id;
 insert into newsletter_identity_history values(u,c,n,l,e.id,e.payload,e.dedupe_key);
end$$;
commit;
