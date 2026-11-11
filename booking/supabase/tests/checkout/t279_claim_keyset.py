#!/usr/bin/env python3
"""LOCAL isolated clone only. Actual claim RPC, no external workers/providers/messages.
Usage: PGHOST=127.0.0.1 PGPORT=54329 python t279_claim_keyset.py pm_base [metrics.json]
"""
import os,sys,time,json,threading,pathlib,atexit,hashlib
import psycopg
BASE=sys.argv[1];ROOT=pathlib.Path(__file__).resolve().parents[3]
MIG=ROOT/'supabase/migrations/20261111235901_booking_279_unpaid_order_delete.sql'
kw=dict(host=os.environ.get('PGHOST','127.0.0.1'),port=os.environ.get('PGPORT','54329'),user=os.environ.get('PGUSER','postgres'))
assert kw['host']=='127.0.0.1' and kw['port']=='54329','LOCAL fixture only'
DB='t279_keyset_'+str(os.getpid());adm=psycopg.connect(dbname='postgres',autocommit=True,**kw)
adm.execute('create database '+DB+' template '+BASE);atexit.register(lambda:adm.execute('drop database if exists '+DB+' with (force)'))
c=psycopg.connect(dbname=DB,autocommit=True,**kw);c.execute('begin');c.execute(MIG.read_text());c.execute('commit')
out=[];seq=0

def one(q,s,a=()):
 r=q.execute(s,a).fetchone();return r[0] if r else None

def isolate():
 global seq
 seq+=1
 c.execute('drop trigger if exists zz_t279_probe on booking.email_outbox')
 c.execute("update booking.email_outbox set next_attempt_at=now()+interval '1 day' where status in ('pending','failed')")
 c.execute("update booking.email_outbox set locked_at=now() where status='sending'")
 c.execute('drop trigger if exists zz_t279_probe on booking.email_outbox')

def draft(label):
 cid=one(c,"insert into booking.customers(name,email) values('LOCAL keyset synthetic',%s) returning id",(str(seq)+label+'@keyset.test',))
 return one(c,"insert into booking.orders(customer_id,status,payment_status) values(%s,'pending','unpaid') returning id",(cid,))

def mails(oid,n,label):
 return [x[0] for x in c.execute("insert into booking.email_outbox(kind,order_id,dedupe_key) select 'order_change',%s,%s||i from generate_series(1,%s)i returning id",(oid,str(seq)+label,n)).fetchall()]

def receipt(oid,label):
 pid=one(c,"insert into booking.payments(order_id,method,amount,status,paid_at) values(%s,'cash',5,'paid',now()) returning id",(oid,))
 c.execute("insert into booking.payment_lines(payment_id,description,amount_gross,vat_rate) values(%s,'LOCAL synthetic receipt',5,0)",(pid,))
 rid=one(c,'select booking._issue_receipt(%s)',(pid,))
 eid=one(c,"insert into booking.email_outbox(kind,order_id,payment_id,receipt_id,dedupe_key) values('receipt',%s,%s,%s,%s) returning id",(oid,pid,rid,str(seq)+label))
 return eid,rid

def conn(service=False,timeout='30s'):
 x=psycopg.connect(dbname=DB,**kw);x.execute("select set_config('statement_timeout',%s,false)",(timeout,))
 if service:x.execute("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false)");x.execute('set role service_role')
 x.commit();return x

def claim(limit=20,timeout='30s'):
 x=conn(True,timeout);t=time.monotonic()
 try:r=one(x,'select booking.email_outbox_claim(%s)',(limit,));x.commit();return r,round((time.monotonic()-t)*1000,3)
 finally:x.close()

def ids(rows):return [r['id'] for r in rows]
def hold(oid):
 x=conn();one(x,'select id from booking.orders where id=%s for update',(oid,));return x

def still_locked(oid):
 x=conn();r=one(x,'select id from booking.orders where id=%s for key share skip locked',(oid,));x.rollback();x.close();return r is None

def busy_unchanged(bs):return one(c,"select count(*) from booking.email_outbox where id=any(%s) and status='pending' and attempts=0",(bs,))==len(bs)
def sending(rows):return one(c,"select count(*) from booking.email_outbox where id=any(%s) and status='sending'",(ids(rows),))==len(rows)

def case(name,fn):
 try:r=fn();ok=bool(r.pop('ok'));out.append(dict(case=name,ok=ok,**r))
 except Exception as e:out.append(dict(case=name,ok=False,error=repr(e),sqlstate=getattr(e,'sqlstate',None)))
 print(json.dumps(out[-1],default=str),flush=True)

def saturated(n):
 isolate();oid=draft('busy');bs=mails(oid,n,'busy');good=draft('receipt');eid,rid=receipt(good,'receipt');L=hold(oid)
 try:
  rows,ms=claim();again,ms2=claim();locked=still_locked(oid);untouched=busy_unchanged(bs)
  payload=next((r for r in rows if r['id']==eid),{})
  ok=ids(rows)==[eid] and payload.get('receipt',{}).get('id')==rid and sending(rows) and again==[] and locked and untouched
 finally:L.rollback();L.close()
 retry,_=claim();ok=ok and ids(retry)==bs[:20] and len(ids(rows+retry))==len(set(ids(rows+retry)))
 return dict(ok=ok,busy=n,claim_ms=ms,all_busy_scan_ms=ms2,statement_timeout_ms=30000,receipt_id=eid,returned=ids(rows),busy_sending=0 if untouched else 'FAIL',order_still_locked=locked,retry_count=len(retry))

class Job(threading.Thread):
 def __init__(self,limit=20,timeout='10s'):super().__init__(daemon=True);self.x=conn(True,timeout);self.limit=limit;self.rows=None;self.error=None
 def run(self):
  try:self.rows=one(self.x,'select booking.email_outbox_claim(%s)',(self.limit,));self.x.commit()
  except Exception as e:self.error=e;self.x.rollback()

def pause(eid,key):
 c.execute(f"create or replace function booking.t279_probe() returns trigger language plpgsql as $$ begin if new.id={eid} then perform pg_advisory_xact_lock({key}); end if; return new; end $$")
 c.execute('create trigger zz_t279_probe before update on booking.email_outbox for each row execute function booking.t279_probe()')
 x=conn();x.execute('select pg_advisory_xact_lock(%s)',(key,));return x

def wait_advisory(job):
 end=time.monotonic()+5
 while time.monotonic()<end:
  r=c.execute('select wait_event_type,wait_event from pg_stat_activity where pid=%s',(job.x.info.backend_pid,)).fetchone()
  if r and r[0]=='Lock' and r[1]=='advisory':return True
  if not job.is_alive():return False
  time.sleep(.01)
 return False

def release_proof():
 isolate();oid=draft('release-busy');bs=mails(oid,20,'release-busy');good=draft('release-healthy');eid= mails(good,1,'release-good')[0]
 L=hold(oid);P=pause(eid,2793101);J=Job();J.start();paused=wait_advisory(J)
 x=conn();unlocked=one(x,'select count(*) from (select id from booking.email_outbox where id=any(%s) for update skip locked)q',(bs,));x.rollback();x.close()
 locked=still_locked(oid);P.rollback();P.close();J.join(12);L.rollback();L.close();J.x.close()
 return dict(ok=paused and unlocked==20 and locked and J.error is None and ids(J.rows)==[eid],worker_paused_before_return=paused,busy_rows_lockable_during_call=unlocked,order_still_locked=locked,error=str(J.error))

def two_workers():
 isolate();oid=draft('two-busy');bs=mails(oid,40,'two-busy');good=draft('two-good');healthy=mails(good,60,'two-good');L=hold(oid)
 a,b=Job(),Job();a.start();b.start();a.join(15);b.join(15)
 rows=(a.rows or [])+(b.rows or []);locked=still_locked(oid);untouched=busy_unchanged(bs)
 ok=a.error is None and b.error is None and len(rows)==40 and len(set(ids(rows)))==40 and set(ids(rows)).issubset(set(healthy)) and sending(rows) and locked and untouched
 a.x.close();b.x.close();L.rollback();L.close();return dict(ok=ok,returned=len(rows),unique=len(set(ids(rows))),order_still_locked=locked,errors=[str(a.error),str(b.error)])

def fifo(limit,expected):
 isolate();oid=draft('fifo');healthy=mails(oid,55,'fifo');rows,ms=claim(limit)
 return dict(ok=ids(rows)==healthy[:expected] and sending(rows),limit=limit,expected=expected,returned=len(rows),ms=ms)

def archived_slot():
 isolate();oid=draft('archived');c.execute("update booking.orders set status='cancelled',archived_at=now() where id=%s",(oid,))
 c.execute('begin');c.execute('set local session_replication_role=replica');bad=mails(oid,1,'archived')[0];c.execute('commit')
 good=draft('archived-good');healthy=mails(good,20,'archived-good');rows,ms=claim()
 return dict(ok=ids(rows)==healthy and one(c,'select status from booking.email_outbox where id=%s',(bad,))=='skipped' and sending(rows),returned=len(rows),skipped_id=bad,ms=ms)

def highwater():
 isolate();oid=draft('highwater');first=mails(oid,1,'highwater-first')[0];P=pause(first,2793102);J=Job();J.start();paused=wait_advisory(J)
 later=mails(oid,1,'highwater-later')[0];P.rollback();P.close();J.join(12);J.x.close();c.execute('drop trigger zz_t279_probe on booking.email_outbox')
 rows,_=claim();return dict(ok=paused and J.error is None and ids(J.rows)==[first] and ids(rows)==[later],paused=paused,first_payload=ids(J.rows or []),next_payload=ids(rows))

def fault(timeout=False):
 isolate();oid=draft('fault');hs=mails(oid,3,'fault');action="perform pg_sleep(1)" if timeout else "raise exception using errcode='P2BAD',message='LOCAL fault after prior sending'"
 c.execute(f"create or replace function booking.t279_probe() returns trigger language plpgsql as $$ begin if new.id={hs[1]} then {action}; end if; return new; end $$")
 c.execute('create trigger zz_t279_probe before update on booking.email_outbox for each row execute function booking.t279_probe()')
 x=conn(True,'100ms' if timeout else '5s');rows=None;err=None
 try:rows=one(x,'select booking.email_outbox_claim(20)');x.commit()
 except Exception as e:err=e;x.rollback()
 x.close();state=c.execute('select status,attempts,locked_at from booking.email_outbox where id=any(%s) order by id',(hs,)).fetchall()
 return dict(ok=getattr(err,'sqlstate',None)==('57014' if timeout else 'P2BAD') and rows is None and state==[('pending',0,None)]*3,error_code=getattr(err,'sqlstate',None),payload=rows,states=state)

for n in [20,40,1000,10000]:case('K saturated busy prefix '+str(n),lambda n=n:saturated(n))
case('K busy lock released DURING active call',release_proof)
case('K two concurrent workers no duplicate/no opposite order wait',two_workers)
for n,expected in [(1,1),(20,20),(50,50),(0,1),(500,50),(None,20)]:case('K best-effort FIFO/clamp '+str(n),lambda n=n,e=expected:fifo(n,e))
case('K archived skipped persists without consuming slot',archived_slot)
case('K fixed highwater excludes later insert until next claim',highwater)
case('K mid-call unexpected error rolls back ALL prior sending',fault)
case('K actual statement timeout propagates and rolls back ALL',lambda:fault(True))
base=psycopg.connect(dbname=BASE,**kw)
a=one(base,"select pg_get_functiondef('booking.email_outbox_claim_base_132(integer)'::regprocedure)");b=one(c,"select pg_get_functiondef('booking.email_outbox_claim_base_132(integer)'::regprocedure)")
tail=lambda s:s[s.index('  select coalesce(jsonb_agg'):]
case('K payload SELECT byte-identical to baseline',lambda:dict(ok=tail(a)==tail(b),payload_sha256=hashlib.sha256(tail(b).encode()).hexdigest()))
base.close()
result=dict(cases=out,pass_count=sum(x['ok'] for x in out),fail_count=sum(not x['ok'] for x in out),local_only=True)
if len(sys.argv)>2:pathlib.Path(sys.argv[2]).write_text(json.dumps(result,indent=2,default=str)+'\n')
print('KEYSET pass='+str(result['pass_count'])+' fail='+str(result['fail_count']))
raise SystemExit(0 if result['fail_count']==0 else 1)
