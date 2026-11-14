-- DISPOSABLE LOCAL DATABASE ONLY. Actual shared unsubscribe and marketing separation.
begin;
do $$declare c bigint;o bigint;m bigint;i bigint;f bigint;t uuid;begin
 insert into booking.customers(name,email,marketing_consent,marketing_consent_at)
 values('Synthetic shared-message test','n259-compat-'||gen_random_uuid()||'@example.test',true,now())returning id,unsubscribe_token into c,t;
 insert into booking.orders(customer_id,status,payment_status)values(c,'confirmed','paid')returning id into o;
 insert into booking.messages(name,category)values('n259 marketing fixture','after_marketing')returning id into m;
 insert into booking.messages(name,category)values('n259 instruction fixture','instruction')returning id into i;
 insert into booking.messages(name,category)values('n259 feedback fixture','feedback')returning id into f;
 insert into booking.email_outbox(kind,order_id,dedupe_key,payload,status)values
 ('product_message',o,'n259-compat-marketing',jsonb_build_object('message_id',m),'pending'),
 ('product_message',o,'n259-compat-instruction',jsonb_build_object('message_id',i),'pending'),
 ('product_message',o,'n259-compat-feedback',jsonb_build_object('message_id',f),'pending'),
 ('event_message',o,'n259-compat-event',jsonb_build_object('message_id',m),'pending');
 set local role anon;perform booking.public_marketing_unsubscribe(t);reset role;
 if not exists(select 1 from booking.email_outbox where dedupe_key='n259-compat-marketing'and status='skipped'and last_error='unsubscribed')then raise exception 'Existing after_marketing cancellation changed';end if;
 if exists(select 1 from booking.email_outbox where dedupe_key in('n259-compat-instruction','n259-compat-feedback','n259-compat-event')and status<>'pending')then raise exception 'Service/event messages affected by newsletter suppression';end if;
end$$;
rollback;
