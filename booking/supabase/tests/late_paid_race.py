#!/usr/bin/env python3
"""LOCAL ONLY – EI DEV/PROD. booking_263 late_paid_cancelled_order: deterministiset rinnakkaistestit erillisillä yhteyksillä.
Peruutuspolut: svc_cancel_reservation, public_cancel_booking, _expire_holds, _cancel_unpaid_expired_orders, _release_unpaid_additions.
Kullekin: W1 peruutus voittaa (peruutus-tx auki, maksu-callback rinnalla), W2 maksu voittaa (maksu-tx auki, peruutus rinnalla),
ja lomittuva D-tapaus (kolmas yhteys pitää lukkoa niin, että peruutus on puolivälissä), joka ilman NOWAIT-sopimusta tuottaa deadlockin.
Odotus tunnistetaan pg_stat_activity.wait_event_type = 'Lock' -kyselyllä (ei unia). 55P03 maksupuolella = edge 503 → uusintayritys (simuloidaan).
Käyttö: PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres python late_paid_race.py <pohjakanta> fix|baseline   (vaatii psycopg 3)
Luo kertakäyttöisen kannan pohjakannasta, asentaa (fix) numeroimattoman luonnoksen, poistaa kannan lopuksi."""
import os, sys, time, json, threading, pathlib
import psycopg
from psycopg import errors

BASE, MODE = sys.argv[1], sys.argv[2]
HERE = pathlib.Path(__file__).resolve().parent
DB = f"lp_race_{MODE.split('=')[0]}_{os.getpid()}"
kw = dict(host=os.environ.get("PGHOST", "127.0.0.1"), port=os.environ.get("PGPORT", "54329"), user=os.environ.get("PGUSER", "postgres"))
adm = psycopg.connect(dbname="postgres", autocommit=True, **kw)
adm.execute(f"create database {DB} template {BASE}")
import atexit
atexit.register(lambda: adm.execute(f"drop database if exists {DB} with (force)"))
results = []

def conn(role=True):
    c = psycopg.connect(dbname=DB, autocommit=False, **kw)
    c.execute("set lock_timeout = '20s'"); c.execute("set deadlock_timeout = '1s'")
    if role:
        c.execute("""select set_config('request.jwt.claims','{"role":"service_role"}',false)"""); c.execute("set role service_role")
    c.commit(); return c

def one(c, sql, args=()):
    r = c.execute(sql, args).fetchone(); return r[0] if r else None

class Bg(threading.Thread):
    def __init__(self, c, sql, args=()):
        super().__init__(daemon=True); self.c, self.sql, self.args = c, sql, args; self.res = self.err = None; self.t0 = time.time(); self.dt = None
    def run(self):
        try: self.res = one(self.c, self.sql, self.args)
        except Exception as e: self.err = e
        self.dt = time.time() - self.t0

def blocked(c):
    return one(SETUP, "select wait_event_type = 'Lock' from pg_stat_activity where pid = %s", (c.info.backend_pid,)) is True

def wait_state(bg, timeout=6.0):
    end = time.time() + timeout
    while time.time() < end:
        if not bg.is_alive(): return "done"
        if blocked(bg.c): return "blocked"
        time.sleep(0.02)
    return "timeout"

SETUP = psycopg.connect(dbname=DB, autocommit=True, **kw)
if MODE == "fix":
    SETUP.execute((HERE.parent / "unnumbered" / "late_paid_cancelled_order.sql").read_text())
elif MODE.startswith("file="):   # vertailu: esim. edellinen luonnos (a0f00c2)
    SETUP.execute(pathlib.Path(MODE[5:]).read_text())
SETUP.execute("""update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode'""")
SETUP.execute("""insert into booking.integration_config(key, mode, settings) values ('montonio','test','{"approved_by":"race"}')
  on conflict (key) do update set mode='test', settings = coalesce(booking.integration_config.settings,'{}'::jsonb) || '{"approved_by":"race"}'""")
SETUP.execute("""select set_config('request.jwt.claims','{"role":"service_role"}',false)""")
AVAIL = """select q.starts_at from (
  select * from booking.public_treatment_availability(11, current_date + 3, current_date + 16, 2)
  union all select * from booking.public_treatment_availability(11, current_date + 17, current_date + 30, 2)
  union all select * from booking.public_treatment_availability(11, current_date + 31, current_date + 44, 2)) q
  where q.status = 'available' order by 1 limit 1"""
class _Slots:
    def __next__(self):
        r = one(SETUP, AVAIL)
        if r is None: raise StopIteration
        return r
SL = _Slots()

def mk_hold(email):
    b = one(SETUP, "select booking.public_create_treatment_booking(11, %s, 2, 'Race', %s, '+358401234567', false, 'fi', null, 'private', null, null)", (next(SL), email))
    tok = b["token"]
    m = one(SETUP, "select booking.montonio_payment_prepare(%s::uuid, null, 'paymentInitiation')", (tok,))
    oid, ono = SETUP.execute("select id, order_no from booking.orders where public_token = %s::uuid", (tok,)).fetchone()
    return dict(oid=oid, ono=ono, tok=tok, a=m["order_number"], amt=m["amount"], pid=m["payment_id"])

def mk_addition(email):
    f = mk_hold(email)
    one(SETUP, PAY, (f["a"], f["amt"]))
    r = one(SETUP, "select booking.public_add_to_order(%s::uuid, jsonb_build_array(jsonb_build_object('type','reservation','product_id',11,'persons',1,'start',%s::timestamptz)))", (f["tok"], next(SL)))
    assert r.get("ok"), r
    ares, aitem = SETUP.execute("""select rv.id, rv.order_item_id from booking.reservations rv join booking.order_items i on i.id = rv.order_item_id
        where rv.order_id = %s and i.hold_expires_at is not null order by rv.id desc limit 1""", (f["oid"],)).fetchone()
    m = one(SETUP, "select booking.montonio_payment_prepare(%s::uuid, null, 'paymentInitiation')", (f["tok"],))
    SETUP.execute("update booking.order_items set hold_expires_at = now() - interval '1 minute' where id = %s", (aitem,))
    SETUP.execute("update booking.reservations set hold_expires_at = now() - interval '1 minute' where id = %s", (ares,))
    f.update(a=m["order_number"], amt=m["amount"], pid=m["payment_id"], ares=ares, aitem=aitem); return f

def mk_expired(email):
    f = mk_hold(email)
    SETUP.execute("update booking.reservations set status = 'expired', hold_expires_at = now() - interval '2 minutes' where order_id = %s", (f["oid"],))
    SETUP.execute("update booking.orders set status = 'expired' where id = %s", (f["oid"],)); return f

def mk_holdexp(email):
    f = mk_hold(email)
    SETUP.execute("update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = %s", (f["oid"],)); return f

def state(f):
    q = """select jsonb_build_object('order', o.status, 'pay', (select status from booking.payments where id = %(pid)s),
      'paid_n', (select count(*) from booking.payments where order_id = o.id and status = 'paid'),
      'res', (select jsonb_object_agg(id, status) from booking.reservations where order_id = o.id),
      'res_n', (select count(*) from booking.reservations where order_id = o.id),
      'receipts', (select count(*) from booking.receipts where payment_id = %(pid)s),
      'late_audit', (select count(*) from booking.audit_log where row_pk = %(pid)s::text and action = 'LATE_PAID_CANCELLED_ORDER'),
      'confirm_mail', (select count(*) from booking.email_outbox where order_id = o.id and kind = 'order_confirmation'),
      'note', coalesce(o.internal_note, '')) from booking.orders o where o.id = %(oid)s"""
    return one(SETUP, q, f)

PAY = "select booking.montonio_payment_apply(%s::text, 'paid', %s::numeric, '{}'::jsonb)"
CRON = {"expire_holds", "cancel_expired", "release"}   # sisäiset funktiot: cron/trigger ajaa omistajana (ei service_role-granttia)
ACT = {
    "svc": lambda f: ("select booking.svc_cancel_reservation(%s, 'race')", (f["ono"],)),
    "public": lambda f: ("select booking.public_cancel_booking(%s::uuid)", (f["tok"],)),
    "expire_holds": lambda f: ("select booking._expire_holds(null, null)", ()),
    "cancel_expired": lambda f: ("select booking._cancel_unpaid_expired_orders()", ()),
    "release": lambda f: ("select booking._release_unpaid_additions(%s, null, 'hold_expired')", (f["oid"],)),
}
FIX = {"svc": mk_hold, "public": mk_hold, "expire_holds": mk_holdexp, "cancel_expired": mk_expired, "release": mk_addition}

def finish_pay(bg, f, log):
    """Maksu-callbackin lopputulos; 55P03/40P01 → rollback + uusintayritys (edge 503 → palveluntarjoaja yrittää uudelleen)."""
    if bg.err is None: bg.c.commit(); log["pay"] = "ok"; log["pay_res"] = bg.res; return
    bg.c.rollback(); log["pay"] = type(bg.err).__name__ + ":" + (bg.err.sqlstate or "")
    c = conn(); r = one(c, PAY, (f["a"], f["amt"])); c.commit(); c.close(); log["pay_retry"] = r

def finish_cancel(bg, log):
    if bg.err is None: bg.c.commit(); log["cancel"] = "ok"; log["cancel_res"] = bg.res
    else: bg.c.rollback(); log["cancel"] = type(bg.err).__name__ + ":" + (bg.err.sqlstate or "")

def w1(path):
    f = FIX[path](f"w1-{path}@race.test"); log = {"case": f"W1 {path} (peruutus ensin)"}
    A = conn(role=path not in CRON); sql, args = ACT[path](f); log["cancel_res"] = one(A, sql, args)
    B = Bg(conn(), PAY, (f["a"], f["amt"])); B.start(); log["pay_wait"] = wait_state(B)
    A.commit(); log["cancel"] = "ok"; B.join(25); finish_pay(B, f, log); log["state"] = state(f); return f, log

def w2(path):
    f = FIX[path](f"w2-{path}@race.test"); log = {"case": f"W2 {path} (maksu ensin)"}
    B = conn(); log["pay_res"] = one(B, PAY, (f["a"], f["amt"]))
    sql, args = ACT[path](f); A = Bg(conn(role=path not in CRON), sql, args); A.start(); log["cancel_wait"] = wait_state(A)
    B.commit(); log["pay"] = "ok"; A.join(25); finish_cancel(A, log); log["state"] = state(f); return f, log

def d(path):
    f = FIX[path](f"d-{path}@race.test"); log = {"case": f"D {path} (lomittuva: peruutus puolivälissä, maksu rinnalla)"}
    L = conn(role=False)
    if path in ("public", "expire_holds"):   # varaukset → [tilaus odottaa L:ää] → maksut
        L.execute("select 1 from booking.orders where id = %s for update", (f["oid"],))
    else:                                     # tilaus → [varaus odottaa L:ää] → maksut
        rid = f.get("ares") or one(SETUP, "select min(id) from booking.reservations where order_id = %s", (f["oid"],))
        L.execute("select 1 from booking.reservations where id = %s for update", (rid,))
    sql, args = ACT[path](f); A = Bg(conn(role=path not in CRON), sql, args); A.start(); log["cancel_wait_L"] = wait_state(A)
    B = Bg(conn(), PAY, (f["a"], f["amt"])); B.start(); log["pay_wait"] = wait_state(B, 3.0)
    log["pay_dt_before_L_release"] = round(B.dt, 3) if B.dt is not None else None
    L.commit(); A.join(25); B.join(25)
    finish_cancel(A, log); finish_pay(B, f, log); log["state"] = state(f); return f, log

def expect(name, ok):
    results.append((name, bool(ok)))

def chk_cancel_won(path, f, log, how):
    s = log["state"]; nores = all(v == "cancelled" for v in (s["res"] or {}).values())
    if path == "release":
        expect(f"{how} release: lisäys pysyy cancelled, maksu kerran, ei kapasiteettia", s["res"][str(f["ares"])] == "cancelled" and s["paid_n"] <= 2 and s["res_n"] == 2
               and s["order"] == "confirmed" and (s["pay"] != "paid" or "YLIMAKSU" in s["note"]))
    elif path == "public" and how == "W2":
        pass
    else:
        expect(f"{how} {path}: peruttu säilyy, maksu kerran, tarkistukseen, ei vahvistusviestiä, varaukset cancelled",
               s["order"] == "cancelled" and s["pay"] == "paid" and s["paid_n"] == 1 and s["receipts"] == 1 and s["late_audit"] == 1
               and s["confirm_mail"] == 0 and nores and s["res_n"] == 1)

def chk_pay_won(path, f, log):
    s = log["state"]
    if path in ("svc",):  # henkilökunnan peruutus maksun jälkeen: normaali maksetun tilauksen peruutus
        expect("W2 svc: maksu kerran, sitten peruutus (ei tarkistusmerkintää)", s["order"] == "cancelled" and s["pay"] == "paid" and s["paid_n"] == 1 and s["late_audit"] == 0 and log["cancel"] == "ok")
    elif path == "release":
        expect("W2 release: lisäys vahvistettu maksulla, ei vapautusta", s["res"][str(f["ares"])] == "confirmed" and s["pay"] == "paid" and s["order"] == "confirmed" and log["cancel"] == "ok")
    else:
        expect(f"W2 {path}: maksu voitti, vahvistettu, peruutus/siivous ei vapauta paikkaa", s["order"] == "confirmed" and s["pay"] == "paid" and s["paid_n"] == 1
               and all(v == "confirmed" for v in s["res"].values()) and s["late_audit"] == 0 and log["cancel"] == "ok")

out = []
for p in ["svc", "public", "expire_holds", "cancel_expired", "release"]:
    for fn in (w1, w2) + ((d,) if p != "svc" else ()):
        try:
            f, log = fn(p)
        except Exception as e:
            log = {"case": f"{fn.__name__} {p}", "harness_error": repr(e)}; out.append(log); expect(log["case"] + " harness", False); continue
        out.append(log)
        if fn is w2: chk_pay_won(p, f, log)
        else: chk_cancel_won(p, f, log, "W1" if fn is w1 else "D")
        if fn is d:
            expect(f"D {p}: ei deadlockia (40P01)", "40P01" not in json.dumps(log, default=str))
            expect(f"D {p}: peruutus onnistui", log.get("cancel") == "ok")
            if MODE == "fix":
                expect(f"D {p}: maksu ei jäänyt odottamaan (NOWAIT 55P03 heti)", log["pay_wait"] == "done" and log["pay"].endswith("55P03") and (log["pay_dt_before_L_release"] or 9) < 1.0)
        if fn is w1 and MODE == "fix":
            expect(f"W1 {p}: maksu ei deadlockannut", "40P01" not in json.dumps(log, default=str))
for l in out: print(json.dumps(l, default=str, ensure_ascii=False))
np = sum(ok for _, ok in results); nf = len(results) - np
for n, ok in results: print(("PASS " if ok else "FAIL ") + n)
print(f"RACERESULT mode={MODE} pass={np} fail={nf}")
SETUP.close()
adm.execute(f"drop database if exists {DB} with (force)")
sys.exit(1 if nf else 0)
