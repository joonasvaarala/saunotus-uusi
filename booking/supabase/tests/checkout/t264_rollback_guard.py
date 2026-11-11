#!/usr/bin/env python3
"""LOCAL ONLY – EI DEV/PROD. booking_264: migraation ja rollbackin md5-vartijat jokaiselle muutettavalle/pudotettavalle funktiolle + triggerille.
Käyttö: PGHOST=… python t264_rollback_guard.py <pohjakanta>  → exit 1 jos jokin tapaus epäonnistuu."""
import os, sys, pathlib, re, threading, time
import psycopg
BASE = sys.argv[1]
HERE = pathlib.Path(__file__).resolve().parent
SB = HERE.parent.parent
MIG = (SB / "migrations" / "20261111141559_booking_264_unpaid_order_delete.sql").read_text()
RB = (SB / "rollbacks" / "20261111141559_booking_264_ROLLBACK.sql").read_text()
kw = dict(host=os.environ.get("PGHOST", "127.0.0.1"), port=os.environ.get("PGPORT", "54329"), user=os.environ.get("PGUSER", "postgres"))
adm = psycopg.connect(dbname="postgres", autocommit=True, **kw)
DB = f"t264_rb_{os.getpid()}"
ALO = "booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])"
DEPS=["booking.email_outbox_claim_base_132(integer)","booking.email_outbox_claim_base_146(integer)","booking.email_outbox_claim_base_215(integer)","booking.email_outbox_mark(bigint,text,text,text)"]
NEW = ["booking._order_delete_blockers(bigint)", "booking.admin_order_delete_check(bigint)", "booking.admin_delete_unpaid_order(bigint,text)", "booking._email_outbox_archived_bi()", "booking._archived_late_payment_review_rows()", "booking.admin_ack_archived_late_payment(bigint,text)"]
out = []

def fresh():
    adm.execute(f"drop database if exists {DB} with (force)"); adm.execute(f"create database {DB} template {BASE}")
    return psycopg.connect(dbname=DB, autocommit=True, **kw)
def run(c, sql):
    try:
        c.execute("begin"); c.execute(sql); c.execute("commit"); return None
    except Exception as e:
        c.execute("rollback"); return " ".join(str(e).split())
def state(c):
    q = lambda s: c.execute(s).fetchone()[0]
    return dict(deps={x:q(f"select md5(pg_get_functiondef('{x}'::regprocedure))") for x in DEPS}, alo=q(f"select md5(pg_get_functiondef('{ALO}'::regprocedure))"),
                new={s: q(f"select case when to_regprocedure('{s}') is null then null else md5(pg_get_functiondef(to_regprocedure('{s}'))) end") for s in NEW},
                claim=q("select md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure))"),
                review=q("select md5(pg_get_functiondef('booking.admin_review_list()'::regprocedure))"),
                trgdef=q("select md5(pg_get_triggerdef(oid)||tgenabled::text) from pg_trigger where tgrelid='booking.email_outbox'::regclass and tgname='email_outbox_archived_bi'") if q("select count(*) from pg_trigger where tgrelid='booking.email_outbox'::regclass and tgname='email_outbox_archived_bi'") else None,
                trg=q("select count(*) from pg_trigger where tgrelid = 'booking.email_outbox'::regclass and tgname = 'email_outbox_archived_bi'"),
                col=q("select count(*) from information_schema.columns where table_schema='booking' and table_name='orders' and column_name='archived_at'"))
def foreign(c, sig):
    d = c.execute(f"select pg_get_functiondef('{sig}'::regprocedure)").fetchone()[0]
    d2 = re.sub(r"\$(function|\$)\$\s*\n?", lambda m: m.group(0) + "-- vieras versio\n", d, count=1)
    assert d2 != d; c.execute(d2)
def case(name, ok, **info):
    out.append(dict(case=name, ok=bool(ok), **info)); print(("PASS " if ok else "FAIL ") + name, info if not ok else "")

c = fresh(); s0 = state(c)
e = run(c, MIG); s1 = state(c)
case("M1 migraatio puhtaaseen", e is None and s1["alo"] == "c50fa63ab94d0046d6a3ccf85a005f0b" and all(s1["new"].values()) and s1["trg"] == 1, err=e)
e2 = run(c, MIG); case("M2 migraatio uudelleen (sama versio) sallittu", e2 is None and state(c) == s1, err=e2)
e = run(c, RB); s2 = state(c)
case("RB1 rollback palauttaa booking_277:n ja poistaa kaiken", e is None and s2["alo"] == "7a546ff24b41e6ffe7f22e3a43a282fc" and not any(s2["new"].values()) and s2["trg"] == 0 and s2["col"] == 0 and s2 == s0, err=e)
e = run(c, RB); case("RB2 rollback uudelleen (jo palautettu) sallittu", e is None and state(c) == s2, err=e)
e = run(c, MIG); case("RB3 migraatio rollbackin jälkeen uudelleen", e is None and state(c) == s1, err=e)

c = fresh(); run(c, MIG)
c.execute("select test.reset_rl()")
slot = c.execute("""select q.starts_at from booking.public_treatment_availability(11, current_date + 3, current_date + 12, 2) q where q.status = 'available' order by 1 limit 1""").fetchone()[0]
b = c.execute("select booking.public_create_treatment_booking(11, %s, 2, 'Rb', 'rb@t264.example', '+358401234567', false, 'fi', null, 'private', null, null)", (slot,)).fetchone()[0]
c.execute("update booking.reservations set status = 'cancelled' where order_id = (select id from booking.orders where public_token = %s::uuid)", (b["token"],))
c.execute("update booking.orders set status = 'cancelled', archived_at = now(), archive_reason = 'rb' where public_token = %s::uuid", (b["token"],))
before = state(c); e = run(c, RB); s3 = state(c)
kept = c.execute("select count(*) from booking.orders where archived_at is not null and archive_reason = 'rb'").fetchone()[0]
case("RB4 archive data forbids ALL rollback changes", e is not None and "arkistoituja" in e and s3 == before and kept == 1, err=e)

# Direct administrative writer does not participate in the archive advisory protocol.
# It commits while rollback waits for the table lock: the locked recheck MUST fail, not restore the old list.
c=fresh();run(c,MIG)
oid=c.execute("insert into booking.orders(status,payment_status) values('pending','unpaid') returning id").fetchone()[0]
L=psycopg.connect(dbname=DB,autocommit=False,**kw)
L.execute("update booking.orders set status='cancelled',archived_at=now() where id=%s",(oid,))
R=psycopg.connect(dbname=DB,autocommit=True,**kw); result=[]; before=state(c)
t=threading.Thread(target=lambda: result.append(run(R,RB)));t.start();blocked=False
for _ in range(100):
    if c.execute("select wait_event_type='Lock' from pg_stat_activity where pid=%s",(R.info.backend_pid,)).fetchone()[0]: blocked=True;break
    time.sleep(.02)
L.commit();t.join(10)
case("RB7 direct archive commits during DDL wait: locked recheck forbids rollback",blocked and not t.is_alive() and result and result[0] is not None and 'arkistoituja' in result[0] and state(c)==before,err=result)
R.close();L.close()

c=fresh();run(c,MIG)
oid=c.execute("insert into booking.orders(status,payment_status) values('pending','unpaid') returning id").fetchone()[0]
pid=c.execute("insert into booking.payments(order_id,method,amount,status) values(%s,'cash',5,'pending') returning id",(oid,)).fetchone()[0]
c.execute("insert into booking.archived_late_payment_acks(payment_id,acknowledged_by,note) values(%s,gen_random_uuid(),'Synthetic local orphan-ack guard')",(pid,))
before=state(c);e=run(c,RB)
case("RB6 acknowledgment data alone forbids rollback",e is not None and "kuittauksia" in e and state(c)==before,err=e)

# Genuine pre-install failed1 -> skipped; all ambiguous statuses/all kinds.
c=fresh()
oid=c.execute("insert into booking.orders(status,payment_status) values('pending','unpaid') returning id").fetchone()[0]
for label,status,attempts,has_sent,kind in [('failed','failed',1,False,'order_change'),('dead','dead',1,False,'order_change'),('pending','pending',1,False,'order_change'),('skipped','failed',1,False,'order_change'),('dry','dry_run',1,False,'order_change'),('bad-sent','sent',1,False,'order_change'),('other-kind','skipped',1,False,'gift_card_buyer'),('retry-sent','sent',2,True,'order_change'),('normal-sent','sent',1,True,'order_change'),('never-claimed','failed',0,False,'order_change')]:
    c.execute("insert into booking.email_outbox(kind,order_id,dedupe_key,status,attempts,sent_at) values(%s,%s,%s,%s,%s,case when %s then now() else null end)",(kind,oid,'rb-legacy-'+label,status,attempts,has_sent))
c.execute("update booking.email_outbox set status='skipped' where dedupe_key='rb-legacy-skipped'")
e=run(c,MIG)
flags=dict(c.execute("select dedupe_key,archive_claim_uncertain from booking.email_outbox where dedupe_key like 'rb-legacy-%%'").fetchall())
case('M3 all ambiguous legacy statuses/kinds backfilled; sent1 and attempts0 exempt',e is None and len(flags)==10 and sum(flags.values())==8 and flags['rb-legacy-skipped'] and flags['rb-legacy-other-kind'] and not flags['rb-legacy-normal-sent'] and not flags['rb-legacy-never-claimed'],err=e,flags=flags)
c.execute("update booking.email_outbox set status='sent' where archive_claim_uncertain")
before=state(c); e=run(c,RB)
case('RB8 uncertain history forbids rollback even after sent; no rollback-reapply erasure',e is not None and 'lähetyshistoriaa' in e and state(c)==before and c.execute("select count(*) from booking.email_outbox where archive_claim_uncertain").fetchone()[0]==8,err=e)
e=run(c,MIG)
case('M4 reapply retains sent-row uncertainty',e is None and c.execute("select count(*) from booking.email_outbox where archive_claim_uncertain").fetchone()[0]==8,err=e)
c.execute("update booking.email_outbox set archive_claim_uncertain=false where archive_claim_uncertain")
case('M5 ordinary UPDATE cannot clear known uncertainty',c.execute("select count(*) from booking.email_outbox where archive_claim_uncertain").fetchone()[0]==8)

for sig in [ALO, "booking.admin_review_list()", "booking.email_outbox_claim(integer)"] + DEPS + NEW:
    c = fresh(); run(c, MIG); foreign(c, sig); before = state(c)
    e = run(c, RB)
    case(f"RBX rollback hylkää vieraan {sig.split('(')[0]}", e is not None and "tuntematon versio" in e and sig.split("(")[0] in e and state(c) == before, err=e)
c = fresh(); run(c, MIG)
c.execute("create function booking.t264_other_trg() returns trigger language plpgsql as $$ begin return new; end $$")
c.execute("drop trigger email_outbox_archived_bi on booking.email_outbox")
c.execute("create trigger email_outbox_archived_bi before insert on booking.email_outbox for each row execute function booking.t264_other_trg()")
before = state(c); e = run(c, RB)
case("RBX rollback hylkää vieraan triggerin", e is not None and "trigger email_outbox_archived_bi" in e and state(c) == before, err=e)
for change in ["drop trigger email_outbox_archived_bi on booking.email_outbox",
               "alter table booking.email_outbox disable trigger email_outbox_archived_bi",
               "drop trigger email_outbox_archived_bi on booking.email_outbox; create trigger email_outbox_archived_bi before insert on booking.email_outbox for each row execute function booking._email_outbox_archived_bi()"]:
    for script,label in [(MIG,"migration"),(RB,"rollback")]:
        c = fresh(); run(c,MIG); c.execute(change); before = state(c)
        e = run(c,script)
        case("trigger full definition/enabled guard " + label, e is not None and state(c) == before, err=e)
c = fresh(); run(c, MIG); run(c, RB); c.execute("drop function booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])")
e = run(c, RB); case("RBX rollback hylkää puuttuvan admin_list_orders", e is not None and "puuttuu" in e, err=e)

for sig in NEW:
    c = fresh(); run(c, MIG); foreign(c, sig); before = state(c)
    e = run(c, MIG)
    case(f"MX migraatio hylkää vieraan aiemman {sig.split('(')[0]}", e is not None and "vieras aiempi versio" in e and state(c) == before, err=e)
for sig, needle in [(ALO, "admin_list_orders md5"), ("booking.email_outbox_claim_base_132(integer)", "email_outbox_claim_base_132 md5"),
                    ("booking.email_outbox_claim_base_146(integer)","base146 vieras"),("booking.email_outbox_claim_base_215(integer)","base215 vieras"),("booking.email_outbox_mark(bigint,text,text,text)","outbox mark vieras"), ("booking.payment_mark_paid(text,text,numeric,jsonb)", "payment_mark_paid md5"), ("booking.admin_review_list()", "admin_review_list vieras"), ("booking.email_outbox_claim(integer)","email_outbox_claim vieras")]:
    c = fresh(); foreign(c, sig); before = state(c)
    e = run(c, MIG)
    case(f"MX migraatio hylkää vieraan {sig.split('(')[0]}", e is not None and needle in e and state(c) == before, err=e)

adm.execute(f"drop database if exists {DB} with (force)")
print(f"RBGUARD pass={sum(o['ok'] for o in out)} fail={sum(not o['ok'] for o in out)}")
sys.exit(0 if all(o["ok"] for o in out) else 1)
