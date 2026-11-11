#!/usr/bin/env python3
"""LOCAL ONLY: data-preserving feature-disable/re-enable draft guards, no remote apply."""
import psycopg,os,sys,pathlib,atexit,json
SB=pathlib.Path(__file__).resolve().parents[2];BASE=sys.argv[1]
MIG=(SB/'migrations/20261111190214_booking_279_unpaid_order_delete.sql').read_text()
RB=(SB/'rollbacks/20261111190214_booking_279_ROLLBACK.sql').read_text()
DIS=(SB/'rollbacks/booking_279_FORWARD_DISABLE_DRAFT.sql').read_text()
ENA=(SB/'rollbacks/booking_279_FORWARD_REENABLE_DRAFT.sql').read_text()
kw=dict(host='127.0.0.1',port='54329',user='postgres');DB='t279_switch_'+str(os.getpid())
a=psycopg.connect(dbname='postgres',autocommit=True,**kw);atexit.register(lambda:a.execute('drop database if exists '+DB+' with (force)'))
sig='booking.admin_delete_unpaid_order(bigint,text,boolean)';out=[]
def one(c,s,p=()):
 r=c.execute(s,p).fetchone();return r[0] if r else None

def run(c,s):
 try:c.execute(s);return None
 except Exception as e:c.execute('rollback');return dict(message=str(e),code=e.sqlstate)

def fresh():
 a.execute('drop database if exists '+DB+' with (force)');a.execute('create database '+DB+' template '+BASE)
 c=psycopg.connect(dbname=DB,autocommit=True,**kw);assert run(c,'begin;'+MIG+'commit;') is None;return c

def acl(c):return one(c,"select proacl::text from pg_proc where oid=%s::regprocedure",(sig,))
def snapshot(c):return one(c,"select md5(jsonb_build_object('orders',(select jsonb_agg(to_jsonb(o) order by o.id) from booking.orders o),'acks',(select jsonb_agg(to_jsonb(x) order by x.payment_id) from booking.archived_late_payment_acks x),'mail',(select jsonb_agg(to_jsonb(e) order by e.id) from booking.email_outbox e))::text)")
def case(name,ok,**kw):out.append(dict(case=name,ok=bool(ok),**kw));print(json.dumps(out[-1]),flush=True)
def attest(c):c.execute("set booking279.rpc_drained='yes'")
c=fresh();orig=acl(c);e=run(c,DIS);case('F1 requires external ingress/accepted/queued drain attestation',e and 'drain' in e['message'] and acl(c)==orig,error=e)
oid=one(c,"insert into booking.orders(status,payment_status) values('pending','unpaid') returning id")
c.execute("insert into booking.email_outbox(kind,order_id,dedupe_key,status,attempts) values('order_change',%s,'LOCAL-switch-history','failed',1)",(oid,));before=snapshot(c)
attest(c);e=run(c,DIS);disabled=acl(c)
case('F2 disable changes only exact archive ACL; data/history intact',e is None and before==snapshot(c) and one(c,"select has_function_privilege('authenticated',%s,'EXECUTE')",(sig,)) is False and one(c,"select has_function_privilege('service_role',%s,'EXECUTE')",(sig,)) is False,error=e)
x=psycopg.connect(dbname=DB,**kw);x.execute('set role authenticated');payload=None;err=None
try:payload=one(x,'select booking.admin_delete_unpaid_order(%s,null)',(oid,));x.commit()
except Exception as ex:err=ex;x.rollback()
x.close();case('F3 app receives 42501 not success; no data change',getattr(err,'sqlstate',None)=='42501' and payload is None and snapshot(c)==before,code=getattr(err,'sqlstate',None))
case('F4 owner/superuser retains grant-independent capability',one(c,"select has_function_privilege('postgres',%s,'EXECUTE')",(sig,)) and one(c,"select pg_get_userbyid(proowner)='postgres' from pg_proc where oid=%s::regprocedure",(sig,)))
e=run(c,'begin;'+MIG+'commit;');case('F4b migration reapply cannot silently reenable disabled feature',e and 'ACL' in e['message'] and acl(c)==disabled and snapshot(c)==before,error=e)
e=run(c,'begin;'+RB+'commit;');case('F5 disable does not weaken uncertainty/full-rollback stop',e and 'lähetyshistoriaa' in e['message'] and acl(c)==disabled and snapshot(c)==before,error=e)
e=run(c,ENA);case('F6 reenable requires separate reviewed-fix attestation',e and 'reviewed' in e['message'] and acl(c)==disabled,error=e)
c.execute("set booking279.fix_reviewed='yes'");e=run(c,ENA);case('F7 exact original grants restored, data/flags retained',e is None and acl(c)==orig and snapshot(c)==before,error=e)
for label,change,needle in [
 ('extra ACL',"grant execute on function "+sig+" to anon",'ACL'),
 ('grant option',"grant execute on function "+sig+" to authenticated with grant option",'ACL'),
 ('owner',"alter function "+sig+" owner to service_role",'owner'),
 ('literal definer',"create function booking.t279_internal() returns jsonb language sql security definer as $$select booking.admin_delete_unpaid_order(1,null)$$",'SECURITY DEFINER'),
 ('parsed SQL dependency',"create function booking.t279_internal() returns jsonb language sql security definer begin atomic select booking.admin_delete_unpaid_order(1,null); end",'SECURITY DEFINER'),
 ('foreign hash',"FOREIGN_SOURCE_COMMENT",'hash'),
 ('disabled trigger',"alter table booking.email_outbox disable trigger email_outbox_archived_bi",'trigger')]:
 c=fresh()
 if change=='FOREIGN_SOURCE_COMMENT':
  definition=one(c,"select pg_get_functiondef('booking.email_outbox_claim_base_132(integer)'::regprocedure)")
  c.execute(definition.replace('AS $function$','AS $function$\n-- LOCAL foreign source',1))
 else:c.execute(change)
 b=acl(c);attest(c);e=run(c,DIS);case('F guard '+label,e and needle in e['message'] and acl(c)==b,error=e)
c=fresh();attest(c);assert run(c,DIS) is None;c.execute('grant execute on function '+sig+' to anon');b=acl(c);c.execute("set booking279.fix_reviewed='yes'");e=run(c,ENA);case('F reenable rejects nonexact disabled ACL',e and 'ACL' in e['message'] and acl(c)==b,error=e)
print('SWITCH pass='+str(sum(x['ok'] for x in out))+' fail='+str(sum(not x['ok'] for x in out)))
raise SystemExit(0 if all(x['ok'] for x in out) else 1)
