#!/usr/bin/env python3
"""LOCAL ONLY – EI DEV/PROD. booking_279 unpaid_order_delete: rinnakkaisuus erillisillä yhteyksillä (psycopg, READ COMMITTED).
Ei oikeita maksusessioita: Montonio-HTTP:tä ei kutsuta; montonio_payment_prepare = tietokantavaihe ENNEN ulkoista createOrderia
(edge-funktio kutsuu Montoniota vasta, kun prepare on commitattu ja yritysrivi kirjattu), montonio_payment_apply = varmennettu callback.
Odotus tunnistetaan pg_stat_activity.wait_event_type = 'Lock'.
Käyttö: PGHOST=… python t279_race.py <pohjakanta (fixtures+migraatiot+10_test_helpers)> [tulos.json]   → exit 1 jos jokin tapaus epäonnistuu."""
import os, sys, time, json, threading, pathlib, uuid, subprocess
import psycopg

BASE = sys.argv[1]
HERE = pathlib.Path(__file__).resolve().parent
MIG = HERE.parent.parent / "migrations" / "20261111190214_booking_279_unpaid_order_delete.sql"
DB = f"t279_race_{os.getpid()}"
kw = dict(host=os.environ.get("PGHOST", "127.0.0.1"), port=os.environ.get("PGPORT", "54329"), user=os.environ.get("PGUSER", "postgres"))
adm = psycopg.connect(dbname="postgres", autocommit=True, **kw)
adm.execute(f"create database {DB} template {BASE}")
import atexit
atexit.register(lambda: adm.execute(f"drop database if exists {DB} with (force)"))

SETUP = psycopg.connect(dbname=DB, autocommit=True, **kw)
SETUP.execute("begin"); SETUP.execute(MIG.read_text()); SETUP.execute("commit")
SETUP.execute("""update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode'""")
SETUP.execute("""insert into booking.integration_config(key, mode, settings) values ('montonio','test','{"approved_by":"t279race"}')
  on conflict (key) do update set mode='test', settings = coalesce(booking.integration_config.settings,'{}'::jsonb) || '{"approved_by":"t279race"}'""")
ADMIN = SETUP.execute("select test.mk_staff('admin@t279race.example','admin')").fetchone()[0]
SETUP.execute("""select set_config('request.jwt.claims','{"role":"service_role"}',false)""")

def one(c, sql, args=()):
    r = c.execute(sql, args).fetchone(); return r[0] if r else None

def conn(who="service"):
    c = psycopg.connect(dbname=DB, autocommit=False, **kw)
    c.execute("set lock_timeout = '20s'"); c.execute("set deadlock_timeout = '1s'")
    if who == "service":
        c.execute("""select set_config('request.jwt.claims','{"role":"service_role"}',false)"""); c.execute("set role service_role")
    elif who == "admin":
        c.execute("select set_config('request.jwt.claims', %s, false)", (json.dumps({"sub": str(ADMIN), "role": "authenticated"}),)); c.execute("set role authenticated")
    c.commit(); return c

class Bg(threading.Thread):
    def __init__(self, c, sql, args=()):
        super().__init__(daemon=True); self.c, self.sql, self.args = c, sql, args; self.res = self.err = None
    def run(self):
        try: self.res = one(self.c, self.sql, self.args)
        except Exception as e: self.err = e

def wait_state(bg, timeout=6.0):
    end = time.time() + timeout
    while time.time() < end:
        if not bg.is_alive(): return "done"
        if one(SETUP, "select wait_event_type = 'Lock' from pg_stat_activity where pid = %s", (bg.c.info.backend_pid,)) is True: return "blocked"
        time.sleep(0.02)
    return "timeout"

def finish(bg):
    bg.join(25)
    if bg.err is None: bg.c.commit(); return bg.res
    bg.c.rollback(); return {"error": type(bg.err).__name__, "sqlstate": bg.err.sqlstate}

AVAIL = """select q.starts_at from booking.public_treatment_availability(11, current_date + 3 + %s * 7, current_date + 9 + %s * 7, 2) q
  where q.status = 'available' order by 1 limit 1"""
def slot():
    for w in range(12):
        s = one(SETUP, AVAIL, (w, w))
        if s: return s
    raise RuntimeError("ei vapaita aikoja")

def mk(email):
    SETUP.execute("select test.reset_rl()")
    b = one(SETUP, "select booking.public_create_treatment_booking(11, %s, 2, 'Race', %s, '+358401234567', false, 'fi', null, 'private', null, null)", (slot(), email))
    assert b.get("ok"), b
    oid, ono = SETUP.execute("select id, order_no from booking.orders where public_token = %s::uuid", (b["token"],)).fetchone()
    return dict(oid=oid, ono=ono, tok=b["token"])

def mk_link(email):
    f = mk(email); f["ltok"] = str(uuid.uuid4())
    f["pid"] = one(SETUP, """insert into booking.payments(order_id, method, provider, amount, status, link_token, link_expires_at, link_sent_at)
        values (%s, 'montonio', 'montonio', (select total_gross from booking.orders where id = %s), 'pending', %s::uuid, now() + interval '7 days', now()) returning id""",
        (f["oid"], f["oid"], f["ltok"]))
    return f

def mk_abandoned(email):
    """Montonio-yritys aloitettu, CREATED, sitten varmennettu ABANDONED → poistettavissa."""
    f = mk(email)
    m = one(SETUP, "select booking.montonio_payment_prepare(%s::uuid, null, 'paymentInitiation')", (f["tok"],))
    one(SETUP, "select booking.montonio_payment_event(%s, 'CREATED', 'https://pay.montonio.com/session/race', %s, '{}'::jsonb)", (m["order_number"], "uuid-" + m["order_number"]))
    one(SETUP, """select booking.montonio_payment_apply(%s, 'cancelled', null, '{"paymentStatus":"ABANDONED"}'::jsonb)""", (m["order_number"],))
    f.update(a=m["order_number"], amt=m["amount"], pid=m["payment_id"]); return f

def st(f):
    return one(SETUP, """select jsonb_build_object('order', o.status, 'archived', o.archived_at is not null, 'payment_status', o.payment_status,
      'res', (select jsonb_agg(r.status order by r.id) from booking.reservations r where r.order_id = o.id),
      'res_active', (select count(*) from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at)),
      'pays', (select jsonb_agg(p.status order by p.id) from booking.payments p where p.order_id = o.id),
      'attempts', (select count(*) from booking.montonio_attempts a join booking.payments p on p.id = a.payment_id where p.order_id = o.id),
      'receipts', (select count(*) from booking.receipts x where x.order_id = o.id),
      'b279_res', (select count(*) from booking.reservations r where r.order_id = o.id and r.cancel_reason = 'order_deleted_unpaid'),
      'b279_pays', (select count(*) from booking.payments p where p.order_id = o.id and jsonb_typeof(p.raw) = 'object' and p.raw ? 'booking_279'),
      'audit_del', (select count(*) from booking.audit_log where table_name = 'orders' and row_pk = o.id::text and action = 'ORDER_DELETED_UNPAID'),
      'late_audit', (select count(*) from booking.audit_log a join booking.payments p on a.row_pk = p.id::text where p.order_id = o.id and a.action = 'LATE_PAID_CANCELLED_ORDER'),
      'confirm_mail', (select count(*) from booking.email_outbox e where e.order_id = o.id and e.kind in ('order_confirmation', 'receipt') and e.status in ('pending','sending','sent')))
      from booking.orders o where o.id = %s""", (f["oid"],))

DEL = "select booking.admin_delete_unpaid_order(%s, 'race')"
PREP_ORDER = "select booking.montonio_payment_prepare(%s::uuid, null, 'paymentInitiation')"
PREP_LINK = "select booking.montonio_payment_prepare(null, %s::uuid, 'paymentInitiation')"
PAY = "select booking.montonio_payment_apply(%s::text, 'paid', %s::numeric, '{\"paymentStatus\":\"PAID\"}'::jsonb)"
def retry_delete(f):
    c = conn("admin")
    try:
        out = one(c, DEL, (f["oid"],)); c.commit(); return out
    finally: c.close()

out = []

def case(name, fn):
    try:
        log = fn(); log["case"] = name
    except Exception as e:
        log = {"case": name, "harness_error": repr(e), "ok": False}
    out.append(log)

def archived_ok(s):
    return s["order"] == "cancelled" and s["archived"] and s["res_active"] == 0 and "pending" not in (s["pays"] or []) and s["audit_del"] == 1

# R1 arkistointi ensin (auki), maksun aloitus tilaustokenilla rinnalla → odottaa, sitten order_not_payable; ei yritysriviä → ei HTTP-starttia
def r1():
    f = mk("r1@race.test"); A = conn("admin"); a = one(A, DEL, (f["oid"],))
    B = Bg(conn(), PREP_ORDER, (f["tok"],)); B.start(); w = wait_state(B)
    A.commit(); b = finish(B); s = st(f)
    return dict(del_res=a, prep_wait=w, prep_res=b, state=s,
                ok=a.get("ok") is True and w == "blocked" and b.get("ok") is False and s["attempts"] == 0 and archived_ok(s))
# R2 maksun aloitus ensin (auki), arkistointi rinnalla → odottaa, sitten esto provider_session_unresolved; ei muutoksia
def r2():
    f = mk("r2@race.test"); B = conn(); b = one(B, PREP_ORDER, (f["tok"],))
    A = Bg(conn("admin"), DEL, (f["oid"],)); A.start(); w = wait_state(A)
    B.commit(); a0 = finish(A); a = retry_delete(f); s = st(f)
    return dict(prep_res={k: b.get(k) for k in ("ok", "order_number")}, del_wait=w, del_res={k: a.get(k) for k in ("ok", "code")}, state=s,
                ok=b.get("ok") is True and w == "done" and a0.get("code") == "busy" and a.get("ok") is False and a.get("code") == "provider_session_unresolved"
                   and s["order"] != "cancelled" and not s["archived"] and s["attempts"] == 1 and s["audit_del"] == 0)
# R3 maksulinkki: arkistointi ensin → linkin avaus odottaa → payment_not_pending
def r3():
    f = mk_link("r3@race.test"); A = conn("admin"); a = one(A, DEL, (f["oid"],))
    B = Bg(conn(), PREP_LINK, (f["ltok"],)); B.start(); w = wait_state(B)
    A.commit(); b = finish(B); s = st(f)
    return dict(del_res=a, prep_wait=w, prep_res=b, state=s,
                ok=a.get("ok") is True and w == "blocked" and b.get("ok") is False and s["attempts"] == 0 and archived_ok(s))
# R4 maksulinkki: linkin avaus ensin → arkistointi odottaa → esto
def r4():
    f = mk_link("r4@race.test"); B = conn(); b = one(B, PREP_LINK, (f["ltok"],))
    A = Bg(conn("admin"), DEL, (f["oid"],)); A.start(); w = wait_state(A)
    B.commit(); a0 = finish(A); a = retry_delete(f); s = st(f)
    return dict(prep_res={k: b.get(k) for k in ("ok", "order_number")}, del_wait=w, del_res={k: a.get(k) for k in ("ok", "code")}, state=s,
                ok=b.get("ok") is True and w == "done" and a0.get("code") == "busy" and a.get("ok") is False and a.get("code") == "provider_session_unresolved" and not s["archived"])
# R5 arkistointi ensin, myöhäinen paid-callback rinnalla → odottaa → booking_263-polku: kirjataan, tilaus pysyy perutuksi+arkistoiduksi
def r5():
    f = mk_abandoned("r5@race.test"); A = conn("admin"); a = one(A, DEL, (f["oid"],))
    B = Bg(conn(), PAY, (f["a"], f["amt"])); B.start(); w = wait_state(B)
    A.commit(); b = finish(B); s = st(f)
    lst = one(SETUP, "select 1")  # lista tarkistetaan SQL-testissä A14
    return dict(del_res={k: a.get(k) for k in ("ok",)}, pay_wait=w, pay_res=b, state=s,
                ok=a.get("ok") is True and w == "blocked" and b.get("order_cancelled") is True and s["order"] == "cancelled" and s["archived"]
                   and s["receipts"] == 1 and s["late_audit"] == 1 and s["res_active"] == 0 and s["confirm_mail"] == 0)
# R6 paid-callback ensin (auki), arkistointi rinnalla → odottaa → esto settled_payment; ei muutoksia, tilaus vahvistuu normaalisti
def r6():
    f = mk_abandoned("r6@race.test"); B = conn(); b = one(B, PAY, (f["a"], f["amt"]))
    A = Bg(conn("admin"), DEL, (f["oid"],)); A.start(); w = wait_state(A)
    B.commit(); a0 = finish(A); a = retry_delete(f); s = st(f)
    return dict(pay_res=b, del_wait=w, del_res={k: a.get(k) for k in ("ok", "code", "blockers")}, state=s,
                ok=w == "done" and a0.get("code") == "busy" and a.get("ok") is False and "settled_payment" in [x["code"] for x in a.get("blockers", [])]
                   and not s["archived"] and s["audit_del"] == 0 and s["receipts"] == 1)
# R7 kaksi samanaikaista poistoa → toinen odottaa → already; yksi audit
def r7():
    f = mk("r7@race.test"); A = conn("admin"); a = one(A, DEL, (f["oid"],))
    B = Bg(conn("admin"), DEL, (f["oid"],)); B.start(); w = wait_state(B)
    A.commit(); b0 = finish(B); b = retry_delete(f); s = st(f)
    return dict(first=a.get("ok"), second_wait=w, second=b, state=s, ok=a.get("ok") is True and w == "done" and b0.get("code") == "busy" and b.get("already") is True and archived_ok(s))
# R8 lomittuva: L pitää tilauslukkoa; arkistointi on lukinnut maksurivit ja odottaa tilausta; maksun aloitus (tilaus→maksu) jonossa → L vapautuu → arkistointi valmis, aloitus hylätään
def r8():
    f = mk_abandoned("r8@race.test")
    L = conn("postgres"); L.execute("select 1 from booking.orders where id = %s for update", (f["oid"],))
    A = Bg(conn("admin"), DEL, (f["oid"],)); A.start(); wa = wait_state(A)
    a = finish(A)
    B = Bg(conn(), PREP_ORDER, (f["tok"],)); B.start(); wb = wait_state(B)
    L.commit(); b = finish(B); s = st(f)
    return dict(del_res=a, prep_res=b, state=s,
                ok=wa == "done" and a.get("code") == "busy" and wb == "blocked" and b.get("ok") is True and not s["archived"])

def conn_pg():
    c = psycopg.connect(dbname=DB, autocommit=False, **kw); c.execute("set lock_timeout = '20s'"); c.commit(); return c
_conn = conn
def conn(who="service"):
    return conn_pg() if who == "postgres" else _conn(who)


# ===== Sähköposti: claim/send-vs-archive (email_outbox_claim = sama RPC jota send-emails kutsuu; ei lähetystä, vain tietokantavaihe)
CLAIM = "select booking.email_outbox_claim(50)"
def mail(f, kind, key):
    return one(SETUP, "insert into booking.email_outbox(kind, order_id, dedupe_key) values (%s, %s, %s) returning id", (kind, f["oid"], key))
def mstat(i):
    return one(SETUP, "select status from booking.email_outbox where id = %s", (i,))
def ids(claimed):
    return [x["id"] for x in (claimed or [])]
# E1 claim ensin (auki: rivi sending, rivilukko) → arkistointi odottaa → commit → esto email_sending, ei muutoksia
def e1():
    f = mk("e1@race.test"); m = mail(f, "order_change", "race-e1")
    C = conn(); c = one(C, CLAIM)
    A = Bg(conn("admin"), DEL, (f["oid"],)); A.start(); w = wait_state(A)
    C.commit(); a0 = finish(A); a = retry_delete(f); s = st(f)
    return dict(claimed=m in ids(c), del_wait=w, del_res={k: a.get(k) for k in ("ok", "code")}, mail=mstat(m), state=s,
                ok=m in ids(c) and w == "done" and a0.get("code") == "busy" and a.get("ok") is False and a.get("code") == "email_sending" and not s["archived"]
                   and s["audit_del"] == 0 and mstat(m) == "sending")
# E2 arkistointi ensin (auki, rivit lukittu) → claim ohittaa (SKIP LOCKED, ei odota) → commit → uusi claim ei ota (skipped)
def e2():
    f = mk("e2@race.test"); m = mail(f, "payment_link", "race-e2")
    A = conn("admin"); a = one(A, DEL, (f["oid"],))
    C = Bg(conn(), CLAIM); C.start(); w = wait_state(C)
    c1 = finish(C); A.commit(); C2 = conn(); c2 = one(C2, CLAIM); C2.commit(); s = st(f)
    return dict(del_res=a.get("ok"), claim_wait=w, first_claim_has=m in ids(c1), second_claim_has=m in ids(c2), mail=mstat(m), state=s,
                ok=a.get("ok") is True and w == "done" and m not in ids(c1) and m not in ids(c2) and mstat(m) == "skipped" and archived_ok(s))
# E3 arkistointi ensin (auki) → toinen yhteys lisää muistutuksen → odottaa (FOR KEY SHARE) → commit → rivi skipped
def e3():
    f = mk_link("e3@race.test")
    A = conn("admin"); a = one(A, DEL, (f["oid"],))
    I = Bg(conn_pg(), "insert into booking.email_outbox(kind, order_id, payment_id, dedupe_key) values ('payment_link_reminder', %s, %s, 'race-e3') returning id", (f["oid"], f["pid"]))
    I.start(); w = wait_state(I)
    A.commit(); m = finish(I); C = conn(); c = one(C, CLAIM); C.commit(); s = st(f)
    return dict(del_res=a.get("ok"), insert_wait=w, mail=mstat(m), claimed=m in ids(c), state=s,
                ok=a.get("ok") is True and w == "blocked" and mstat(m) == "skipped" and m not in ids(c) and archived_ok(s))
# E4 lisäys ensin (auki, ei näy arkistoinnille) → arkistointi odottaa tilauslukkoa → commit → rivi lukitaan ja skipataan
def e4():
    f = mk_link("e4@race.test")
    I = conn_pg(); m = one(I, "insert into booking.email_outbox(kind, order_id, payment_id, dedupe_key) values ('order_change', %s, %s, 'race-e4') returning id", (f["oid"], f["pid"]))
    A = Bg(conn("admin"), DEL, (f["oid"],)); A.start(); w = wait_state(A)
    I.commit(); a0 = finish(A); a = retry_delete(f); s = st(f)
    return dict(del_wait=w, del_res={k: a.get(k) for k in ("ok", "skipped_emails")}, mail=mstat(m), state=s,
                ok=w == "done" and a0.get("code") == "busy" and a.get("ok") is True and a.get("skipped_emails") == 1 and mstat(m) == "skipped" and archived_ok(s))

# ===== Lukitusjärjestys vs tunnetut tilaus→maksu-polut (admin_payment_link_mark_handled: tilaus → maksu)
MARK = "select booking.admin_payment_link_mark_handled(%s, 'bank_transfer', 'race')"
def mk_two_links(email):
    f = mk_link(email)
    f["pid2"] = one(SETUP, """insert into booking.payments(order_id, method, provider, amount, status, link_token, link_expires_at, link_sent_at)
        values (%s, 'montonio', 'montonio', 1, 'pending', gen_random_uuid(), now() + interval '7 days', now()) returning id""", (f["oid"],))
    return f
def consistent(s):
    """Ei osittaista tilaa: joko kokonaan arkistoitu tai ei lainkaan (ei peruttuja varauksia/maksurivejä ilman arkistointia)."""
    if s["archived"]: return archived_ok(s)
    return s["audit_del"] == 0 and s["b279_res"] == 0 and s["b279_pays"] == 0
# D1 regression of the old blocking lock inversion (now fails busy and releases order):
# Historical reproduction: L pitää maksuriviä p2; arkistointi lukitsee p1 ja odottaa p2:ta; merkintä hoidetuksi lukitsee
#    tilauksen ja odottaa p1:tä; L vapautuu → arkistointi tarvitsee tilauksen → old implementation deadlocked. No deadlock is acceptable here.
def d1():
    f = mk_two_links("d1@race.test")
    L = conn_pg(); L.execute("select 1 from booking.payments where id = %s for update", (f["pid2"],))
    A = conn("admin"); a = one(A, DEL, (f["oid"],))  # keep transaction open to prove lock release
    M = Bg(conn("admin"), MARK, (f["pid"],)); M.start(); wm = wait_state(M)
    L.commit(); m = finish(M); A.commit(); s = st(f)
    return dict(del_res=a, mark_res=m, mark_wait=wm, state=s,
                ok=a.get("code") == "busy" and m.get("handled") is True and consistent(s) and not s["archived"])
# D2 sama ilman kolmatta osapuolta mutta merkintä ensin: merkintä lukitsee tilauksen+maksun, arkistointi odottaa → valmis → esto
def d2():
    f = mk_link("d2@race.test"); M = conn("admin"); m = one(M, MARK, (f["pid"],))
    A = Bg(conn("admin"), DEL, (f["oid"],)); A.start(); w = wait_state(A)
    M.commit(); a0 = finish(A); a = retry_delete(f); s = st(f)
    return dict(mark=m.get("handled"), del_wait=w, del_res={k: a.get(k) for k in ("ok", "code")}, state=s,
                ok=m.get("handled") is True and w == "done" and a0.get("code") == "busy" and a.get("ok") is False and consistent(s) and not s["archived"])
# Complete-set checks must not retain any acquired locks on busy/blocker.
def busy_release(table):
    def fn():
        f = mk_link("release-" + table + "@race.test")
        pred = "id = %s" if table == "orders" else "order_id = %s"
        L = conn_pg(); L.execute(f"select 1 from booking.{table} where {pred} for update", (f["oid"],))
        A = conn("admin"); before = st(f); a = one(A, DEL, (f["oid"],)); after = st(f)
        L.commit()
        B = conn_pg(); n = one(B, "select count(*) from (select id from booking.orders where id = %s for update skip locked) q", (f["oid"],)); B.commit()
        A.commit()
        return dict(del_res=a, lock_available=n, ok=a.get("code") == "busy" and before == after and n == 1)
    return fn


def calendar_retry():
    f = mk("calendar@race.test")
    SETUP.execute("update booking.reservations set status='confirmed',hold_expires_at=null where order_id=%s",(f["oid"],))
    SETUP.execute("""insert into booking.integration_config(key,mode,settings) values('booking_calendar','dry_run',
        '{"resource_calendars":{"savusauna":"t279fake@group.calendar.google.com","rauni":"t279fake2@group.calendar.google.com","lovi":"t279fake3@group.calendar.google.com"},"window_forward_days":180}'::jsonb)
        on conflict(key) do update set mode=excluded.mode,settings=excluded.settings""")
    SETUP.execute("update booking.orders set status='confirmed',payment_status='unpaid' where id=%s",(f['oid'],))
    rid = one(SETUP,"select id from booking.reservations where order_id=%s limit 1",(f["oid"],)); key=f"r:{rid}"
    before=one(SETUP,"select booking.booking_calendar_export_plan()")
    ev=next(e for e in before['events'] if e['event_key']==key)
    assert ev['google_calendar_id'],ev
    one(SETUP,"select booking.booking_calendar_export_finish(%s::jsonb)",(json.dumps({'upserts':[ev],'deletes':[]}),))
    a=retry_delete(f); assert a.get('ok'),a
    def run(fail):
        plan=one(SETUP,"select booking.booking_calendar_export_plan()")
        plan['events']=[e for e in plan['events'] if e['event_key']==key]
        plan['mapped']=[e for e in plan['mapped'] if e['event_key']==key]
        assert not plan['events'],plan
        out=json.loads(subprocess.run(['node','--experimental-transform-types',str(HERE/'t279_calendar_runner.mjs')],input=json.dumps({'plan':plan,'fail':fail}),text=True,capture_output=True,check=True).stdout)
        one(SETUP,"select booking.booking_calendar_export_finish(%s::jsonb)",(json.dumps(out['payload']),))
        return out
    first=run(True); retained=one(SETUP,"select count(*) from booking.booking_calendar_events where event_key=%s",(key,))
    second=run(False); removed=one(SETUP,"select count(*) from booking.booking_calendar_events where event_key=%s",(key,))
    third=run(False)
    return dict(key=key,failed=first['result'],retry=second['result'],retained=retained,removed=removed,
                ok=first['result']['failed']==1 and first['payload']['deletes']==[] and retained==1
                   and second['payload']['deletes']==[key] and removed==0 and third['calls']==[])

def extra_lock(kind):
    def fn():
        f=mk_link('closure-'+kind+'@race.test')
        if kind=='legs':
            sql="select id from booking.reservation_legs where reservation_id in (select id from booking.reservations where order_id=%s) for update"
        elif kind=='outbox':
            SETUP.execute("insert into booking.email_outbox(kind,order_id,payment_id,dedupe_key) values('order_change',%s,%s,%s)",(f['oid'],f['pid'],'closure-'+str(f['oid'])))
            sql="select id from booking.email_outbox where order_id=%s for update"
        elif kind=='gift':
            one(SETUP,"insert into booking.gift_cards(code,initial_amount,balance,status,purchase_order_id) values(%s,5,5,'pending_payment',%s) returning id",('HH'+str(f['oid']).zfill(10),f['oid']))
            sql="select id from booking.gift_cards where purchase_order_id=%s for update"
        elif kind=='discount':
            did=one(SETUP,"insert into booking.discount_codes(code,kind,value,used_count) values(%s,'fixed',1,1) returning id",('T279'+str(f['oid']),))
            SETUP.execute("update booking.orders set discount_code_id=%s where id=%s",(did,f['oid']))
            sql="select id from booking.discount_codes where id=(select discount_code_id from booking.orders where id=%s) for update"
        elif kind=='space':
            sql="select pg_advisory_xact_lock(hashtextextended('booking:space:'||space_id::text,0)) from booking.reservations where order_id=%s"
        L=conn_pg(); rows=L.execute(sql,(f['oid'],)).fetchall(); assert rows,kind
        A=conn('admin'); a=one(A,DEL,(f['oid'],)); L.commit()
        B=conn_pg(); n=one(B,"select count(*) from (select id from booking.orders where id=%s for update skip locked) q",(f['oid'],));B.commit();A.commit()
        return dict(del_res=a,lock_available=n,ok=a.get('code')=='busy' and n==1 and not st(f)['archived'])
    return fn

def reactivation_race():
    f=mk_link('reactivation@race.test')
    eid=one(SETUP,"insert into booking.email_outbox(kind,order_id,payment_id,dedupe_key,status) values('order_change',%s,%s,%s,'failed') returning id",(f['oid'],f['pid'],'reactivate-'+str(f['oid'])))
    A=conn('admin'); a=one(A,DEL,(f['oid'],))
    U=Bg(conn_pg(),"update booking.email_outbox set status='pending' where id=%s returning status",(eid,));U.start();w=wait_state(U)
    A.commit();status=finish(U)
    return dict(archived=a,status=status,wait=w,ok=a.get('ok') and w=='blocked' and status=='skipped')


def rollback_archive():
    f=mk('rb-gate@race.test');A=conn('admin');a=one(A,DEL,(f['oid'],));assert a.get('ok'),a
    RB=(HERE.parent.parent/'rollbacks'/'20261111190214_booking_279_ROLLBACK.sql').read_text()
    R=Bg(conn_pg(),RB,None);R.start();w=wait_state(R);A.commit();r=finish(R)
    return dict(wait=w,rollback=r,ok=w=='blocked' and r.get('error') and 'arkistoituja' in str(R.err) and st(f)['archived'] and one(SETUP,"select to_regprocedure('booking.admin_delete_unpaid_order(bigint,text,boolean)') is not null"))

def ack_concurrent():
    f=mk_abandoned('ack-concurrent@race.test');a=retry_delete(f);assert a.get('ok'),a
    one(SETUP,PAY,(f['a'],f['amt']))
    # now() in a callback may predate archive commit: audit identity, not time, is decisive.
    SETUP.execute("update booking.audit_log set at=now()-interval '1 day' where action='LATE_PAID_CANCELLED_ORDER' and row_pk=%s",(str(f['pid']),))
    ACK="select booking.admin_ack_archived_late_payment(%s,'Synthetic local handled explanation')"
    A=conn('admin');a=one(A,ACK,(f['pid'],));B=Bg(conn('admin'),ACK,(f['pid'],));B.start();w=wait_state(B);A.commit();b=finish(B)
    n=one(SETUP,"select count(*) from booking.archived_late_payment_acks where payment_id=%s",(f['pid'],))
    au=one(SETUP,"select count(*) from booking.audit_log where action='ARCHIVED_LATE_PAYMENT_ACKNOWLEDGED' and row_pk=%s",(str(f['pid']),))
    return dict(first=a,second=b,wait=w,ok=w=='blocked' and a.get('ok') and b.get('already') and n==1 and au==1)

def payment_only_sending():
    f=mk_link('payment-only@race.test')
    eid=one(SETUP,"insert into booking.email_outbox(kind,payment_id,dedupe_key,status,attempts) values('payment_link',%s,%s,'sending',1) returning id",(f['pid'],'pay-only-'+str(f['oid'])))
    a=retry_delete(f)
    SETUP.execute("update booking.email_outbox set status='sent' where id=%s",(eid,))
    b=retry_delete(f)
    return dict(blocked=a,after_sent=b,ok=a.get('code')=='email_sending' and b.get('ok'))


def claim_expiry_history():
    f=mk('lease-history@race.test')
    eid=one(SETUP,"insert into booking.email_outbox(kind,order_id,dedupe_key,status,attempts,locked_at) values('order_change',%s,%s,'sending',1,now()-interval '20 minutes') returning id",(f['oid'],'lease-'+str(f['oid'])))
    claimed=one(SETUP,'select booking.email_outbox_claim(1000)')
    row=SETUP.execute('select status,attempts,archive_claim_uncertain from booking.email_outbox where id=%s',(eid,)).fetchone()
    SETUP.execute("update booking.email_outbox set status='sent' where id=%s",(eid,))
    a=retry_delete(f)
    return dict(claim_row=row,blocked=a,ok=row[1]>=2 and row[2] is True and a.get('code')=='email_claim_uncertain')

def blocker_release():
    f=mk_link('block-release@race.test')
    SETUP.execute("update booking.payments set raw='{" + '"mobilepay":{"reference":"synthetic"}' + "}'::jsonb where id=%s",(f['pid'],))
    A=conn('admin');a=one(A,DEL,(f['oid'],))
    B=conn_pg(); o=one(B,'select count(*) from (select id from booking.orders where id=%s for update skip locked) q',(f['oid'],))
    p=one(B,'select count(*) from (select id from booking.payments where id=%s for update skip locked) q',(f['pid'],));B.commit();A.commit()
    return dict(blocked=a,locks_released=[o,p],ok=a.get('code')=='provider_session_unresolved' and o==p==1)


def update_order_busy():
    f=mk_link('update-gate@race.test')
    eid=one(SETUP,"insert into booking.email_outbox(kind,order_id,payment_id,dedupe_key,status) values('order_change',%s,%s,%s,'failed') returning id",(f['oid'],f['pid'],'update-gate-'+str(f['oid'])))
    L=conn_pg();L.execute('select id from booking.orders where id=%s for update',(f['oid'],))
    U=Bg(conn_pg(),"update booking.email_outbox set status='sending' where id=%s returning status",(eid,));U.start();w=wait_state(U)
    u=finish(U);L.commit()
    return dict(wait=w,error=u,status=mstat(eid),ok=w=='done' and u is None and mstat(eid)=='failed')


def actual_first_claim_result(result):
    """Actual claim + mark RPCs, separate open transactions vs archive. NO external POST.
    A network error after POST is not proof the provider stopped: both failed and dead must stay blocked.
    max_attempts=1 reaches dead on the FIRST claim, not by artificial status UPDATE.
    """
    def fn():
        # Mail protocol does not need a capacity-consuming reservation: synthetic LOCAL empty unpaid draft.
        cid=one(SETUP,"insert into booking.customers(name,email) values('Synthetic mail protocol',%s) returning id",('first-claim-'+result+'@race.test',))
        oid=one(SETUP,"insert into booking.orders(customer_id,status,payment_status) values(%s,'pending','unpaid') returning id",(cid,))
        f=dict(oid=oid)
        limit=1 if result=='dead' else 5
        eid=one(SETUP,"insert into booking.email_outbox(kind,order_id,dedupe_key,max_attempts) values('order_change',%s,%s,%s) returning id",(f['oid'],'first-claim-'+str(f['oid']),limit))
        C=conn(); claimed=one(C,CLAIM); C.commit(); assert eid in ids(claimed),claimed
        row=SETUP.execute('select status,attempts,archive_claim_uncertain from booking.email_outbox where id=%s',(eid,)).fetchone()
        assert row==('sending',1,False),row
        before=retry_delete(f); assert before.get('code')=='email_sending',before
        M=conn(); one(M,"select booking.email_outbox_mark(%s,%s,null,%s)",(eid,'sent' if result=='sent' else 'failed','synthetic network exception AFTER possible provider acceptance'))
        A=conn('admin'); busy=one(A,DEL,(f['oid'],))
        # KEY SHARE is compatible with the marking guard, but not a retained archive FOR UPDATE.
        B=conn_pg(); released=one(B,'select count(*) from (select id from booking.orders where id=%s for key share skip locked) q',(f['oid'],)); B.commit()
        M.commit(); A.commit()
        marked=SETUP.execute('select status,attempts,archive_claim_uncertain from booking.email_outbox where id=%s',(eid,)).fetchone()
        after=retry_delete(f)
        if result=='sent':
            ok=marked==('sent',1,False) and after.get('ok') is True and st(f)['archived']
            late=None
        else:
            ok=marked==(result,1,True) and after.get('code')=='email_claim_uncertain' and not st(f)['archived']
            # A later successful mark cannot erase the original uncertainty; no operator override exists.
            S=conn(); one(S,"select booking.email_outbox_mark(%s,'sent',null,null)",(eid,)); S.commit()
            late=retry_delete(f)
            sticky=one(SETUP,'select archive_claim_uncertain from booking.email_outbox where id=%s',(eid,))
            ok=ok and sticky is True and late.get('code')=='email_claim_uncertain' and not st(f)['archived']
        return dict(claimed=row,marked=marked,before=before,busy=busy,after=after,after_later_sent=late,locks_released=released,
                    ok=ok and busy.get('code')=='busy' and released==1)
    return fn


def mail_draft(label):
    cid=one(SETUP,"insert into booking.customers(name,email) values('LOCAL synthetic mail',%s) returning id",(label+'@race.test',))
    return dict(oid=one(SETUP,"insert into booking.orders(customer_id,status,payment_status) values(%s,'pending','unpaid') returning id",(cid,)))

def mixed_claim(stale=False):
    def fn():
        # Isolate the genuine default-size 20-row claim batch from earlier test mail.
        SETUP.execute("update booking.email_outbox set next_attempt_at=now()+interval '1 day' where status in ('pending','failed')")
        f=mail_draft('mixed-busy-'+str(stale)); g=mail_draft('mixed-receipt-'+str(stale))
        pid=one(SETUP,"insert into booking.payments(order_id,method,amount,status,paid_at) values(%s,'cash',5,'paid',now()) returning id",(g['oid'],))
        SETUP.execute("insert into booking.payment_lines(payment_id,description,amount_gross,vat_rate) values(%s,'LOCAL synthetic receipt',5,0)",(pid,))
        rid=one(SETUP,'select booking._issue_receipt(%s)',(pid,));assert rid
        if stale:
            busy=one(SETUP,"insert into booking.email_outbox(kind,order_id,dedupe_key,status,attempts,locked_at) values('order_change',%s,%s,'sending',1,now()-interval '20 minutes') returning id",(f['oid'],'mixed-stale-'+str(f['oid'])))
        else: busy=mail(f,'order_change','mixed-busy-'+str(f['oid']))
        receipt=one(SETUP,"insert into booking.email_outbox(kind,order_id,payment_id,receipt_id,dedupe_key) values('receipt',%s,%s,%s,%s) returning id",(g['oid'],pid,rid,'mixed-rc-'+str(g['oid'])))
        healthy=[receipt]+[mail(g,'order_change','mixed-other-'+str(g['oid'])+'-'+str(i)) for i in range(18)]
        L=conn_pg();L.execute('select id from booking.orders where id=%s for update',(f['oid'],))
        C=conn(); first=one(C,'select booking.email_outbox_claim(20)');C.commit()
        row=SETUP.execute('select status,attempts,archive_claim_uncertain from booking.email_outbox where id=%s',(busy,)).fetchone()
        receipt_payload=next((x for x in first if x['id']==receipt),None)
        delivered=all(one(SETUP,'select status from booking.email_outbox where id=%s',(x,))=='sending' for x in ids(first))
        C2=conn(); again=one(C2,'select booking.email_outbox_claim(20)');C2.commit()
        L.commit();C3=conn();retry=one(C3,'select booking.email_outbox_claim(20)');C3.commit()
        return dict(stale=stale,first_ids=ids(first),receipt_id=receipt,receipt_payload=receipt_payload is not None,busy_row=row,retry_ids=ids(retry),
                    ok=set(ids(first))==set(healthy) and len(first)==19 and busy not in ids(first) and delivered
                       and receipt_payload.get('receipt',{}).get('id')==rid and row==('pending',1 if stale else 0,stale)
                       and again==[] and ids(retry)==[busy])
    return fn

def archived_claim_filter():
    f=mail_draft('archived-filter');assert retry_delete(f).get('ok')
    # Simulate a legacy outbox row under an archived order; LOCAL only, for defense-in-depth.
    SETUP.execute('begin');SETUP.execute('set local session_replication_role=replica')
    eid=mail(f,'order_change','legacy-archived-'+str(f['oid']));SETUP.execute('commit')
    C=conn();rows=one(C,CLAIM);C.commit()
    return dict(payload_has=eid in ids(rows),status=mstat(eid),ok=eid not in ids(rows) and mstat(eid)=='skipped')

for n, fn in [("R1 arkistointi ensin vs maksun aloitus (tilaustoken)", r1), ("R2 maksun aloitus ensin vs arkistointi", r2),
              ("R3 arkistointi ensin vs maksulinkin avaus", r3), ("R4 maksulinkin avaus ensin vs arkistointi", r4),
              ("R5 arkistointi ensin vs paid-callback (myöhäinen maksu)", r5), ("R6 paid-callback ensin vs arkistointi", r6),
              ("R7 kaksoispoisto", r7), ("R8 lomittuva: arkistointi puolivälissä, maksun aloitus jonossa", r8),
              ("E1 claim ensin vs arkistointi (sending estää)", e1), ("E2 arkistointi ensin vs claim (SKIP LOCKED, sitten skipped)", e2),
              ("E3 arkistointi ensin vs uusi muistutusrivi (trigger skippaa)", e3), ("E4 uusi rivi ensin vs arkistointi (lukitaan ja skipataan)", e4),
              ("D1 mark_handled survives archive contention without deadlock", d1), ("D2 mark_handled ensin vs arkistointi", d2),
              ("T1 order busy releases", busy_release("orders")),
              ("T2 payments busy releases", busy_release("payments")),
              ("T3 reservations busy releases", busy_release("reservations")),
              ("T4 reservation legs release",extra_lock("legs")), ("T5 outbox releases",extra_lock("outbox")),
              ("T6 space advisory releases",extra_lock("space")), ("E5 failed reactivation after archive",reactivation_race),
              ("C1 actual calendar deletion diff and failed/gone retry",calendar_retry),
              ("T7 gift card cancellation target",extra_lock("gift")), ("T8 discount release target",extra_lock("discount")),
              ("E6 payment-only sending blocks archive",payment_only_sending), ("Q6 concurrent unique acknowledgment",ack_concurrent),
              ("RB5 rollback waits archive then fails before DDL",rollback_archive),
              ("E7 actual claim expiry history fails closed after sent",claim_expiry_history),
              ("T9 blocker path releases subtransaction locks",blocker_release),
              ("E8 UPDATE e-to-order contention skips row without waiting",update_order_busy),
              ("E9 actual first claim then failed is permanently uncertain",actual_first_claim_result("failed")),
              ("E10 actual first claim then dead is permanently uncertain",actual_first_claim_result("dead")),
              ("E11 actual first claim then normal sent remains archivable",actual_first_claim_result("sent")),
              ("E12 real mixed 20-row claim skips busy order and continues receipt",mixed_claim()),
              ("E13 real mixed claim with expired busy lease continues receipt",mixed_claim(True)),
              ("E14 archived row changed to skipped never returned to worker",archived_claim_filter)]:
    case(n, fn)
res = "\n".join(json.dumps(l, default=str, ensure_ascii=False) for l in out)
print(res)
print(f"RACE pass={sum(1 for l in out if l.get('ok'))} fail={sum(1 for l in out if not l.get('ok'))}")
if len(sys.argv) > 2: pathlib.Path(sys.argv[2]).write_text(res + "\n")
SETUP.close()
sys.exit(0 if all(l.get("ok") for l in out) else 1)
