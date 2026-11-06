-- DISPOSABLE LOCAL DATABASE ONLY. Before unapproved capture proposal is installed.
begin;
do $$declare u uuid:=gen_random_uuid();d jsonb;x text;blocked boolean:=false;begin
 insert into auth.users(id,email)values(u,'n259-required@example.test');
 insert into booking.staff(user_id,email,name,role)values(u,'n259-required@example.test','Synthetic capture guard','manager');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
 d:=booking.svc_newsletter_save(null,'{"subject_fi":"Testi","subject_en":"Test","body_fi":"Testi","body_en":"Test","style":{"layout":"letter"},"segment":"all"}'::jsonb);
 begin perform booking.admin_newsletter_dispatch((d->>'id')::bigint,(d->>'version')::integer,false);
 exception when sqlstate 'BK001'then get stacked diagnostics x=pg_exception_detail;blocked:=x like '%newsletter_capture_required%';end;
 if not blocked then raise exception 'Dispatch did not fail closed before capture approval';end if;
 if booking.email_newsletter_payload(0)->>'allowed' is distinct from 'false'then raise exception 'Delivery not blocked without capture';end if;
end$$;
rollback;
