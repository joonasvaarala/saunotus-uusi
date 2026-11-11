-- LOCAL DRAFT / HOLD. NOT deployment approval, never auto-run with migrations.
-- DATA-PRESERVING feature switch, NOT rollback and NOT worker/SQL cancellation.
-- FIRST block new app/RPC ingress AND drain every already accepted/queued call.
-- Advisory gate only serializes active archive critical sections; it does NOT fence
-- a previously authorized call paused before the gate. REVOKE is not cancellation.
-- Set session booking264.rpc_drained='yes' ONLY after the actual external drain.
-- Owner/superuser can still call without grants. No security boundary against them.
-- Catalog caller scan covers literal/direct references, not arbitrary dynamically
-- constructed identifiers or hostile owner code. Audit/drain those outside SQL too.
begin;
set local lock_timeout='5s';
select pg_advisory_xact_lock(hashtextextended('booking:archive:264',0));
do $guard$
declare v_acl jsonb; r record;
begin
 if current_setting('booking264.rpc_drained',true) is distinct from 'yes' then
   raise exception 'booking264 switch: external ingress+accepted/queued-call drain required';
 end if;
 if (select pg_get_userbyid(proowner) from pg_proc where oid='booking.admin_delete_unpaid_order(bigint,text)'::regprocedure) is distinct from 'postgres' then
   raise exception 'booking264 switch: unexpected function owner';
 end if;
 for r in select * from (values
  ('booking.admin_delete_unpaid_order(bigint,text)','ba36be22eaadfc8bdef59b089ad5d629'),
  ('booking.payment_mark_paid(text,text,numeric,jsonb)','b35618b8cd17fa9e7c5902719d0804a2'),
  ('booking.email_outbox_claim_base_132(integer)','c865d1b3d8d6620ff5935c077b7e16a2'),
  ('booking.email_outbox_claim_base_146(integer)','5bb547fa6a5f9e715ebbb39e6b479d3e'),
  ('booking.email_outbox_claim_base_215(integer)','2c76d9c30a28f78e8bb84cce0ff61d77'),
  ('booking.email_outbox_mark(bigint,text,text,text)','2ba0222fdfee71942fb09053bd7ea803'),
  ('booking.email_outbox_claim(integer)','e46ae5ebd9fb813a087b7f05c40949b8'),
  ('booking.admin_review_list()','fca45e305e1036d462ef28c7473de150'),
  ('booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])','c50fa63ab94d0046d6a3ccf85a005f0b'),
  ('booking._email_outbox_archived_bi()','63515bcb6f2b85f003fc3e3125c37f73')
 )x(sig,ok) loop
  if md5(pg_get_functiondef(to_regprocedure(r.sig))) is distinct from r.ok then
   raise exception 'booking264 switch: unexpected function hash %',r.sig;
  end if;
 end loop;
 if not exists(select 1 from pg_trigger where tgrelid='booking.email_outbox'::regclass and tgname='email_outbox_archived_bi' and md5(pg_get_triggerdef(oid)||tgenabled::text)='e8a1a32402444a91417fd625c6a79478') then
   raise exception 'booking264 switch: unexpected trigger definition/enabled';
 end if;
 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where p.prosecdef and p.prokind in ('f','p') and n.nspname not in ('pg_catalog','information_schema')
       and p.oid<>'booking.admin_delete_unpaid_order(bigint,text)'::regprocedure
       and (p.prosrc ilike '%admin_delete_unpaid_order%'
         or exists(select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.refclassid='pg_proc'::regclass and d.refobjid='booking.admin_delete_unpaid_order(bigint,text)'::regprocedure))) then
   raise exception 'booking264 switch: internal SECURITY DEFINER caller requires separate review';
 end if;
 select coalesce(jsonb_agg(jsonb_build_array(pg_get_userbyid(a.grantor),case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end,a.privilege_type,a.is_grantable)
     order by case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end,a.privilege_type),'[]'::jsonb)
 into v_acl from pg_proc p cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a
 where p.oid='booking.admin_delete_unpaid_order(bigint,text)'::regprocedure;
 if v_acl is distinct from '[["postgres","authenticated","EXECUTE",false],["postgres","postgres","EXECUTE",false],["postgres","service_role","EXECUTE",false]]'::jsonb then raise exception 'booking264 switch: unexpected exact ACL %',v_acl; end if;
end $guard$;
revoke all on function booking.admin_delete_unpaid_order(bigint,text) from public,anon,authenticated,service_role;
commit;
-- No schema/data/list/history/worker changes; full rollback guards stay intact.
