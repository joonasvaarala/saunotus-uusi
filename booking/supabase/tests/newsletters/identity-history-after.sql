-- DISPOSABLE LOCAL DATABASE ONLY. After actual feature rollback -> re-enable.
-- Same real customer/address, actual preview/confirm RPC, retained outbox history.
begin;
do $$declare h newsletter_identity_history;d jsonb;x jsonb;y jsonb;n bigint;v integer;l bigint;e booking.email_outbox;before_count bigint;begin
 select * into h from newsletter_identity_history;
 if not found then raise exception 'Identity before-fixture missing';end if;
 if not exists(select 1 from booking.email_outbox where id=h.outbox_id and payload=h.payload and dedupe_key=h.dedupe_key and status='sent')then raise exception 'Rollback/re-enable altered old sent outbox history';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',h.uid,'role','authenticated')::text,true);
 select count(*)into before_count from booking.email_outbox where kind='newsletter';
 d:=booking.svc_newsletter_save(null,'{"subject_fi":"Uusi","subject_en":"New","body_fi":"Testi","body_en":"Test","style":{"layout":"letter"},"segment":"all"}');
 n:=(d->>'id')::bigint;v:=(d->>'version')::integer;
 if n<=h.campaign_id then raise exception 'Campaign identity restarted';end if;
 insert into booking.settings(key,value) values('newsletter_enabled','true'::jsonb) on conflict (key) do update set value='true'::jsonb; -- booking_290: kytkin auki kertakäyttökannassa
 x:=booking.admin_newsletter_dispatch(n,v,false);x:=booking.admin_newsletter_dispatch(n,v,true,(x->>'preview_token')::uuid);
 if x->>'queued_count'<>'1'then raise exception 'New campaign collided with retained dedupe/history';end if;
 select id into l from booking.newsletter_logs where newsletter_id=n;
 if l<=h.log_id then raise exception 'Log identity restarted';end if;
 select * into e from booking.email_outbox where kind='newsletter'and payload->>'newsletter_log_id'=l::text and payload->>'customer_id'=h.customer_id::text;
 if e.id is null or e.dedupe_key=h.dedupe_key or e.payload->>'address_fingerprint' is distinct from h.payload->>'address_fingerprint'then raise exception 'New campaign/address namespace incorrect';end if;
 y:=booking.admin_newsletter_dispatch(n,v,true,null);
 if y->>'already_sent'<>'true' or(select count(*)from booking.email_outbox where kind='newsletter')<>before_count+1 then raise exception 'Confirm retry duplicated or lost mail';end if;
 if exists(select 1 from jsonb_array_elements(booking.admin_newsletters_list())j where(j->>'id')::bigint=n and(j->'delivery'->>'sent')::integer<>0)then raise exception 'New campaign metrics aliased old sent history';end if;
 if not exists(select 1 from booking.email_outbox where id=h.outbox_id and payload=h.payload and dedupe_key=h.dedupe_key and status='sent')then raise exception 'New dispatch changed historical payload/key/status';end if;
 raise notice 'PASS: retained real outbox -> rollback -> re-enable -> new campaign same recipient, no collision/duplication/history alias';
end$$;
rollback;
