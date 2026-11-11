-- READ ONLY; Bottiavustus runs separately in DEV and PROD before any approved apply.
-- No identifiers, customer data, writes or claims. Stop on any unexpected hash/mismatch.
begin read only;
set local statement_timeout = '10s';
select sig, md5(pg_get_functiondef(to_regprocedure(sig))) as actual_md5,
       expected, coalesce(md5(pg_get_functiondef(to_regprocedure(sig)))=any(expected),false) as matches
from (values
 ('booking.payment_mark_paid(text,text,numeric,jsonb)',array['b35618b8cd17fa9e7c5902719d0804a2']),
 ('booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])',array['7a546ff24b41e6ffe7f22e3a43a282fc','c50fa63ab94d0046d6a3ccf85a005f0b']),
 ('booking.email_outbox_claim_base_132(integer)',array['0b10986533285645d8592449a90a1e0c','c865d1b3d8d6620ff5935c077b7e16a2']),
 ('booking.admin_review_list()',array['8c7ddb15580659e9daa3e72f43718f14','fca45e305e1036d462ef28c7473de150']),
 ('booking.email_outbox_claim_base_146(integer)',array['5bb547fa6a5f9e715ebbb39e6b479d3e']),
 ('booking.email_outbox_claim_base_215(integer)',array['2c76d9c30a28f78e8bb84cce0ff61d77']),
 ('booking.email_outbox_mark(bigint,text,text,text)',array['2ba0222fdfee71942fb09053bd7ea803']),
 ('booking.email_outbox_claim(integer)',array['5e8125c1da473685b7a7adbb40966250','e46ae5ebd9fb813a087b7f05c40949b8'])
) x(sig,expected);
-- booking_277: vain 13 argumentin admin_list_orders (p_payment_filters text[]); 12 argumentin versio puuttuu, anon ei saa kutsua.
select (to_regprocedure('booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text)') is null) as admin_list_orders_12arg_absent_must_be_true,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='booking' and p.proname='admin_list_orders') as admin_list_orders_overloads_must_be_1,
       (select pronargs from pg_proc where oid=to_regprocedure('booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])')) as admin_list_orders_nargs_must_be_13,
       coalesce(has_function_privilege('anon',to_regprocedure('booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])'),'execute'),false) as anon_execute_must_be_false;
-- Must be zero. Report/stop; NOT an instruction to edit existing outbox data.
select count(*) as active_order_payment_mismatch_must_be_zero
from booking.email_outbox e join booking.payments p on p.id=e.payment_id
where e.order_id is not null and e.order_id<>p.order_id
  and e.status in ('pending','failed','sending');
select count(*) filter(where status='sending') as sending,
       count(*) filter(where status in ('pending','failed','dead') and attempts>0) as legacy_claim_history,
       count(*) filter(where attempts>1) as multiple_attempts,
       count(*) filter(where coalesce((to_jsonb(e)->>'archive_claim_uncertain')::boolean,false)) as known_uncertain
from booking.email_outbox e;
-- Newly identified legacy ambiguity; report count before approved migration.
select count(*) as guarded_skipped_attempted_without_sent_at
from booking.email_outbox e
where e.kind in ('payment_link','payment_link_reminder','order_confirmation','order_change','unpaid_booking_cancelled')
  and e.status='skipped' and e.attempts>0 and e.sent_at is null;
-- Proposed conservative cohort: all attempted histories except positively normal first sent.
select e.kind,e.status,e.attempts,(e.sent_at is not null) as has_sent_at,count(*)
from booking.email_outbox e
where e.kind in ('payment_link','payment_link_reminder','order_confirmation','order_change','unpaid_booking_cancelled')
  and e.attempts>0
  and not (e.attempts=1 and e.status='sent' and e.sent_at is not null)
group by e.kind,e.status,e.attempts,(e.sent_at is not null)
order by e.kind,e.status,e.attempts,has_sent_at;
-- Record effective/operator and relevant role/database timeout budgets; never change them.
-- Actual PostgREST/worker call limits must also be checked by the operator, not inferred here.
select current_user,current_setting('statement_timeout') as operator_statement_timeout,current_setting('lock_timeout') as operator_lock_timeout;
select coalesce(r.rolname,'ALL ROLES') as role,coalesce(d.datname,'ALL DATABASES') as database,t.setting
from pg_db_role_setting s left join pg_roles r on r.oid=s.setrole left join pg_database d on d.oid=s.setdatabase
cross join lateral unnest(s.setconfig)t(setting)
where (s.setdatabase=0 or s.setdatabase=(select oid from pg_database where datname=current_database()))
  and (t.setting like 'statement_timeout=%' or t.setting like 'lock_timeout=%');
-- Optional forward-disable metadata: inspect exact owner/ACL and literal/dependency callers.
-- This is NOT proof that RPC ingress/accepted/queued calls have been drained.
select pg_get_userbyid(proowner) as archive_owner,proacl as archive_exact_acl
from pg_proc where oid=to_regprocedure('booking.admin_delete_unpaid_order(bigint,text)');
select n.nspname,p.proname,pg_get_userbyid(p.proowner) as owner
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where p.prosecdef and p.prokind in ('f','p') and n.nspname not in ('pg_catalog','information_schema')
 and p.oid<>coalesce(to_regprocedure('booking.admin_delete_unpaid_order(bigint,text)'),0)
 and (p.prosrc ilike '%admin_delete_unpaid_order%'
   or exists(select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.refclassid='pg_proc'::regclass and d.refobjid=to_regprocedure('booking.admin_delete_unpaid_order(bigint,text)')));
rollback;
