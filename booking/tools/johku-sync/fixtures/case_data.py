"""Synteettinen Johku-vienti SYNC_SAANNOT-sääntöjen kokeeseen. Ei oikeita asiakkaita."""
from datetime import datetime
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Europe/Helsinki")
NOW = datetime(2026, 10, 22, 12, 0, tzinfo=TZ)


def ts(text: str) -> int:
    return int(datetime.fromisoformat(text).timestamp())


def customer(cid, phone, email="testi@example.test"):
    return {
        "id": cid, "name": "Testi Asiakas", "email": email, "phone": phone,
        "company": "", "address": "Esimerkkitie 1", "zip": "04130", "city": "Sipoo",
        "country": "FI", "allowmarketing": "0",
    }


def item(iid, product, name, price, parent=None, optiontype="0", start=None, end=None):
    row = {
        "id": iid, "product_id": product, "product_name": name, "price": price, "count": "1",
        "vat": "25.5", "item_id": parent, "optiontype": optiontype,
    }
    if start:
        row["start_ts"] = str(ts(start))
        row["end_ts"] = str(ts(end))
    return row


def order(oid, customer_id, total, lines, **extra):
    base = {
        "id": oid, "customer_id": customer_id, "total": total, "refunded": "0", "paid": "1",
        "payment": "paytrail", "confirmed": "2", "status": "1", "version": "fi_FI",
        "orderdate": str(ts("2026-10-01T10:00:00+03:00")),
        "paymentdate": str(ts("2026-10-01T10:05:00+03:00")),
        "more": "", "ownItem": lines,
    }
    base.update(extra)
    return base


def reservation(rid, item_id, product, start, end, count="2", status="1"):
    return {
        "id": rid, "item_id": item_id, "product_id": product, "status": status, "count": count,
        "start_ts": str(ts(start)), "end_ts": str(ts(end)), "pricetiers": "6:%s" % count,
        "client_more": "", "creation_ts": str(ts("2026-10-01T10:00:00+03:00")),
    }


def build():
    sat_start = "2026-10-24T14:00:00+03:00"
    sat_end_30 = "2026-10-24T14:30:00+03:00"
    sun_pkg = "2026-10-25T16:00:00+02:00"
    sun_pkg_end = "2026-10-25T18:00:00+02:00"
    sun_side = "2026-10-25T16:30:00+02:00"
    sun_side_end = "2026-10-25T18:30:00+02:00"
    ritual = "2026-10-26T17:00:00+02:00"
    ritual_end = "2026-10-26T17:20:00+02:00"
    shift = "2026-10-26T18:00:00+02:00"
    shift_end = "2026-10-26T19:00:00+02:00"
    future = "2026-11-02T16:00:00+02:00"
    future_end = "2026-11-02T18:00:00+02:00"

    c500 = customer("500", "0401234567")
    c501_old = customer("501", "0400000001", "toinen@example.test")
    c501 = customer("501", "0400000002", "toinen@example.test")
    c502_old = customer("502", "0400000003", "kolmas@example.test")
    c502 = customer("502", "0400000004", "kolmas@example.test")

    o11551_old = order("11551", "500", "203", [item("13618", "132", "Yleinen vuoro", "203")])
    o11551 = order("11551", "500", "203", [item("13618", "132", "Yleinen vuoro", "203")], more="muisti")
    o11552_old = order("11552", "500", "0", [item("13620", "103", "Saunavihta", "0", parent="13618")])
    o11552 = order("11552", "500", "13", [item("13620", "103", "Saunavihta", "13", parent="13618")])

    o13980 = order("13980", "501", "44", [
        item("20001", "132", "Yleinen vuoro", "29", start=future, end=future_end),
        item("20002", "113", "Jalkakylpy", "15", parent="20001"),
    ])
    o14021 = order("14021", "501", "29", [
        item("20010", "132", "Yleinen vuoro", "29", start="2026-11-03T16:00:00+02:00", end="2026-11-03T18:00:00+02:00"),
    ])
    o10007 = order("10007", "501", "29", [
        item("20020", "32", "Miesten sauna", "29", start="2026-10-26T16:00:00+02:00", end="2026-10-26T19:00:00+02:00"),
    ])
    o13990 = order("13990", "500", "89", [
        item("20100", "179", "Saunarituaali ja savusauna", "89", start=sun_pkg, end=sun_pkg_end),
        item("20101", "132", "Yleinen vuoro", "0", parent="20100", optiontype="3", start=sun_side, end=sun_side_end),
    ])
    o13991 = order("13991", "500", "70", [
        item("20200", "170", "Saunarituaali", "40", start=ritual, end=ritual_end),
        item("20201", "152", "Tunnin saunavuoro", "30", start=shift, end=shift_end),
    ])
    o14000 = order("14000", "500", "29", [
        item("20300", "132", "Yleinen vuoro", "29", start=sat_start, end=sat_end_30),
    ])
    o14050 = order("14050", "501", "15", [
        item("20400", "113", "Jalkakylpy", "15", parent="20001"),
    ])
    # Johku 134 Perinnesaunotus kahdelle: same service as kb 23, 2.5 h window must stay intact.
    o14060 = order("14060", "500", "270", [
        item("20600", "134", "Perinnesaunotus kahdelle", "270", start="2026-11-04T14:00:00+02:00", end="2026-11-04T16:30:00+02:00"),
    ])
    o13941 = order("13941", "500", "29", [
        item("20500", "132", "Yleinen vuoro", "29", start=future, end=future_end),
    ])
    o11553 = order("11553", "500", "216", [item("13630", "132", "Yleinen vuoro", "216")])

    r_pkg = reservation("30001", "20100", "179", sun_pkg, sun_pkg_end)
    r_side = reservation("30002", "20101", "132", sun_side, sun_side_end)
    r_ritual = reservation("30003", "20200", "170", ritual, ritual_end, count="1")
    r_shift = reservation("30004", "20201", "152", shift, shift_end, count="1")
    r_weekend = reservation("30005", "20300", "132", sat_start, sat_end_30)
    r_new = reservation("30006", "20001", "132", future, future_end)
    r_adv = reservation("30007", "20010", "132", "2026-11-03T16:00:00+02:00", "2026-11-03T18:00:00+02:00")
    r_men = reservation("30008", "20020", "32", "2026-10-26T16:00:00+02:00", "2026-10-26T19:00:00+02:00")
    r_hidden = reservation("10223", "90001", "113", future, future_end)
    r_hidden_changed = dict(r_hidden, count="3")
    r_pkg_hidden = reservation("10275", "90002", "132", sun_side, sun_side_end)
    r_gone = reservation("18001", "90003", "132", future, future_end)
    r_removed_order = reservation("30100", "20500", "132", future, future_end)
    r_two = reservation("30009", "20600", "134", "2026-11-04T14:00:00+02:00", "2026-11-04T16:30:00+02:00", count="2")

    prev = {
        "customers": [c500, c501_old, c502_old],
        "orders": [o11551_old, o11552_old, o13941, o11553],
        "reservations": [r_hidden, r_pkg_hidden, r_gone, r_removed_order],
        "bills": [],
        "valuecards": [],
    }
    nxt = {
        "customers": [c500, c501, c502],
        "orders": [o11551, o11552, o13980, o14021, o10007, o13990, o13991, o14000, o14050, o14060],
        "reservations": [r_hidden_changed, r_pkg, r_side, r_ritual, r_shift, r_weekend, r_new, r_adv, r_men, r_removed_order, r_two],
        "bills": [],
        "valuecards": [],
    }
    db_state = {
        "reservations": {
            "10223": {"hidden": True},
            "10275": {"hidden": True, "merged_into_package": True},
        },
        "orders": {
            "11551": {"addon_merge": True, "status": "confirmed"},
            "11552": {"addon_merge": True, "status": "completed"},
            "11553": {"addon_merge": True, "status": "confirmed"},
        },
        "items": {
            "13620": {"kind": "addon", "merged_from_order_id": "11552", "order_id": "11551"},
        },
        "anonymized_customers": ["502"],
        "taken_order_nos": [10007, 11551, 11552],
        "sequence_last": 14020,
    }
    return {"prev": prev, "next": nxt, "db_state": db_state, "now": NOW}
