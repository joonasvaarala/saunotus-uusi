"""Johku-synkan päätökset (SYNC_SAANNOT).

Puhdas moduuli: ei verkkoa, ei tietokantaa. Palvelin toistaa samat kiellot
(piilotus, merged_into, addon-rivi, siirretty rivi, addon_merge-summa,
ei maksu/kuitti/sähköposti/Procountor-rivejä, ei kovaa poistoa).
"""
from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from catalog import Catalog

TZ = ZoneInfo("Europe/Helsinki")
SRC = "johku"
# Alle tämän rivimäärän katoaminen voi olla oikea muutos (testifixture).
# Tuotannon listat ovat tuhansia: yli 5 % pudotus keskeyttää ajon, jotta
# katkennut vastaus ei peruuta varauksia.
SHRINK_MIN_COUNT = 50
SHRINK_RATIO = 0.95
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# Viikonlopun yleisen vuoron pooli (kb 1 ja paketin kb 7 savusaunaosa).
POOL_2H = {
    "14:00": "yleinen_vkp_1400",
    "14:30": "yleinen_vkp_1430",
    "15:00": "yleinen_vkp_1500",
    "16:00": "yleinen_vkp_1600",
    "16:30": "yleinen_vkp_1630",
    "17:00": "yleinen_vkp_1700",
}
POOL_1H = {"14:00": "tunti_vkp_1400", "18:00": "tunti_vkp_1800"}


class ExportRejected(Exception):
    def __init__(self, code: str, detail: str = ""):
        self.code = code
        super().__init__(code if not detail else f"{code}:{detail}")


def num(value, default=0.0) -> float:
    if value is None or value == "":
        return default
    m = re.search(r"-?\d+(?:\.\d+)?", str(value).replace(",", "."))
    return float(m.group()) if m else default


def money(value) -> float:
    return round(num(value) + 0.0, 2)


def clean(value):
    if value is None:
        return None
    s = str(value).strip()
    return s or None


def canon_hash(obj) -> str:
    raw = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def record_hash(row: dict) -> str:
    return canon_hash(row)


def shrunk(prev_count: int | None, next_count: int) -> bool:
    if prev_count is None or prev_count < SHRINK_MIN_COUNT:
        return False
    return next_count < prev_count * SHRINK_RATIO


def parse_ts(value):
    if value in (None, "", "0", 0):
        return None
    if isinstance(value, (int, float)) or (isinstance(value, str) and re.fullmatch(r"-?\d+", str(value))):
        return datetime.fromtimestamp(int(value), TZ)
    return datetime.fromisoformat(str(value))


def iso(value):
    dt = value if isinstance(value, datetime) else parse_ts(value)
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=TZ)
    return dt.isoformat()


def local_minute(dt: datetime) -> str:
    return dt.astimezone(TZ).strftime("%Y-%m-%dT%H:%M")


def pool_codes(kb: int | None, start: datetime) -> list[str]:
    """Kapasiteettipoolien koodit. Tyhjä lista = ei johdettavissa (ei arvata)."""
    if kb is None or start is None:
        return []
    local = start.astimezone(TZ)
    if kb == 7:
        local = local + timedelta(minutes=30)
    wd = local.isoweekday()
    hm = local.strftime("%H:%M")
    if kb in (2, 3, 4):
        return ["yleinen_arki"]
    if kb == 5:
        return ["yleinen_arki", "turve"]
    if kb in (1, 7) and wd <= 4:
        return ["yleinen_arki"]
    if kb in (1, 7) and wd >= 6:
        return [POOL_2H[hm]] if hm in POOL_2H else []
    if kb == 6 and wd >= 6:
        return [POOL_1H[hm]] if hm in POOL_1H else []
    return []


def normalize_end(cat: Catalog, johku_product_id, kb, start: datetime, end: datetime) -> datetime:
    """Viikonlopun 30 min yleinen vuoro (kb 1) → 120 min. Poikkeukset ref/general_shift_keep.json."""
    if kb not in cat.normalize_kb or start is None or end is None:
        return end
    if int((end - start).total_seconds()) != 1800:
        return end
    if start.astimezone(TZ).isoweekday() not in (6, 7):
        return end
    key = (str(johku_product_id), local_minute(start))
    if key in cat.keep_shifts:
        return end
    return start + timedelta(minutes=120)


def reservation_guard(existing: dict | None) -> str | None:
    """Älä päivitä, älä aktivoi, älä pura piilotusta."""
    if not existing:
        return None
    if existing.get("hidden") or existing.get("hidden_at"):
        return "hidden"
    meta = existing.get("external_meta") or {}
    if existing.get("merged_into") or (isinstance(meta, dict) and "merged_into" in meta):
        return "merged_into"
    model = meta.get("model") if isinstance(meta, dict) else None
    if existing.get("merged_into_package") or (isinstance(model, dict) and "merged_into_package" in model):
        return "merged_into_package"
    return None


def item_guard(existing: dict | None) -> str | None:
    if not existing:
        return None
    if existing.get("kind") == "addon":
        return "addon_row"
    moved = existing.get("merged_from_order_id")
    if moved is None:
        mf = ((existing.get("price_breakdown") or {}).get("merged_from") or {})
        moved = mf.get("order_id")
    if moved is not None and str(moved) != str(existing.get("order_id")):
        return "moved_item"
    return None


def order_total_frozen(existing: dict | None) -> bool:
    if not existing:
        return False
    if existing.get("addon_merge"):
        return True
    meta = existing.get("external_meta") or {}
    return isinstance(meta, dict) and "addon_merge" in meta


def order_no_action(johku_no: int, taken: set[int], sequence_last: int | None) -> str:
    """explicit = käytä Johku-numeroa order_nona; identity = numero on jo natiivilla tilauksella."""
    if johku_no in taken:
        return "identity"
    if sequence_last is not None and johku_no > sequence_last:
        return "explicit_advance"
    return "explicit"


def _index_items(orders):
    items = {}
    order_of = {}
    for o in orders:
        for it in o.get("ownItem") or []:
            items[str(it.get("id"))] = it
            order_of[str(it.get("id"))] = o
    return items, order_of


def _biz(raw):
    s = re.sub(r"\s", "", raw or "")
    s = re.sub(r"^(FI|fi)(\d{8})$", r"\2", s)
    if re.fullmatch(r"\d{8}", s):
        s = s[:7] + "-" + s[7]
    if re.fullmatch(r"\d{6}-\d", s):
        s = "0" + s
    if not re.fullmatch(r"\d{7}-\d", s):
        return None
    w = [7, 9, 10, 5, 8, 4, 2]
    total = sum(int(s[i]) * w[i] for i in range(7))
    r = total % 11
    if r == 1:
        return None
    check = 0 if r == 0 else 11 - r
    return s if check == int(s[8]) else None


def _customer_row(c, orders_for_customer, now: datetime):
    em = clean(c.get("email"))
    em = em.lower() if em else None
    if em and not EMAIL_RE.match(em):
        em = None
    name = clean(c.get("name")) or clean(c.get("company")) or ("Tuntematon asiakas (Johku %s)" % c.get("id"))
    name = name[:200]
    company = clean(c.get("company"))
    kind = "company" if company else "private"
    bid = None
    if kind == "company":
        for o in orders_for_customer:
            for cand in (clean(o.get("billing_ident")), clean(o.get("ident"))):
                bid = _biz(cand) if cand else None
                if bid:
                    break
            if bid:
                break
    consent = str(c.get("allowmarketing")) == "1"
    first = None
    for o in orders_for_customer:
        if o.get("orderdate"):
            first = o["orderdate"]
            break
    langs = [o.get("version") for o in orders_for_customer if o.get("version")]
    lang = "en" if langs and str(langs[-1]).startswith("en") else "fi"
    country = clean(c.get("country")) or "FI"
    if len(country) == 2:
        country = country.upper()
    row = {
        "external_id": str(c["id"]),
        "name": name,
        "email": em,
        "phone": (clean(c.get("phone")) or "")[:50] or None,
        "company": company,
        "address": clean(c.get("address")),
        "zip": clean(c.get("zip")),
        "city": clean(c.get("city")),
        "country": country,
        "language": lang,
        "customer_kind": kind,
        "business_id": bid,
        "einvoice_address": clean(c.get("evoice")),
        "einvoice_operator": clean(c.get("evoiceint")),
        "marketing_consent": consent,
        "marketing_consent_at": (iso(first) if first else iso(now)) if consent else None,
        "marketing_consent_source": "johku_import" if consent else None,
        "created_at": iso(first),
    }
    row["sync_hash"] = canon_hash(row)
    return row


def _is_side_shift(cat: Catalog, item: dict, parent: dict | None) -> bool:
    if parent is None:
        return False
    if str(item.get("optiontype") or "") != cat.side_shift_optiontype:
        return False
    if money(item.get("price")) != 0:
        return False
    if cat.kb_of(item.get("product_id")) != cat.side_shift_kb:
        return False
    parent_kb = cat.kb_of(parent.get("product_id"))
    parent_is_package = str(parent.get("product_id")) in cat.package_products or parent_kb == cat.package_kb
    return parent_is_package


def _line_kind(cat: Catalog, item: dict) -> str:
    name = clean(item.get("product_name")) or "(nimetön rivi)"
    price = num(item.get("price"))
    if item.get("product_id") is None and (price < 0 or name not in cat.fee_names):
        return "discount" if price < 0 else "product"
    if name in cat.fee_names:
        return "fee"
    if str(item.get("product_subtype")) == "6":
        return "gift_card"
    if item.get("start_ts") not in (None, "", "0"):
        return "reservation"
    if price < 0:
        return "discount"
    return "product"


def _parent_in_order(item, items_by_id, order_of_item, order_id) -> tuple[str, dict | None]:
    parent_ext = clean(item.get("item_id"))
    if not parent_ext:
        return "missing_parent", None
    parent = items_by_id.get(str(parent_ext))
    if parent is None:
        return "missing_parent", None
    parent_order = order_of_item.get(str(parent_ext))
    if parent_order is None or str(parent_order.get("id")) != str(order_id):
        return "ambiguous_parent", None
    return "ok", parent


def classify_lines(cat: Catalog, order: dict, items_by_id, order_of_item):
    """Palauttaa (items, reservation_item_ids, reviews). Side shift ja lisäpalvelu eivät saa varausta."""
    out_items = []
    keep_res = []
    reviews = []
    oid = str(order["id"])
    for it in order.get("ownItem") or []:
        iid = str(it.get("id"))
        addon = cat.addon_code(it.get("product_id"))
        status, parent = _parent_in_order(it, items_by_id, order_of_item, oid)
        if addon:
            if status != "ok":
                reviews.append({"kind": "item", "external_id": iid, "code": status if status != "missing_parent" else "ambiguous_parent"})
                continue
            out_items.append(_item_row(cat, order, it, kind="addon", addon_code=addon, parent_ext=str(parent.get("id")), role="addon"))
            continue
        if _is_side_shift(cat, it, parent if status == "ok" else None):
            out_items.append(_item_row(cat, order, it, kind="product", addon_code=None, parent_ext=str(parent.get("id")), role="side_shift"))
            continue
        kind = _line_kind(cat, it)
        row = _item_row(cat, order, it, kind=kind, addon_code=None, parent_ext=clean(it.get("item_id")) if status == "ok" else None, role="line")
        out_items.append(row)
        if kind == "reservation":
            keep_res.append(iid)
    return out_items, keep_res, reviews


def _item_row(cat, order, it, kind, addon_code, parent_ext, role):
    price = num(it.get("price"))
    cnt = num(it.get("count"), 1)
    rc = num(it.get("reservation_count"), 0) if it.get("reservation_count") not in (None, "") else 0
    mult = 1.0
    if str(it.get("product_unittype")) == "3" and rc > 1:
        mult = rc
    qty_f = cnt * mult
    line_total = money(price * qty_f)
    if qty_f >= 0 and abs(qty_f - round(qty_f)) < 1e-9:
        quantity = int(round(qty_f))
        unit = money(price)
    else:
        quantity = 1
        unit = line_total
    name = (clean(it.get("product_name")) or "(nimetön rivi)")[:200]
    vat = num(it.get("vat"), 25.5)
    pb = {"johku_role": role}
    if it.get("optiontype") not in (None, ""):
        pb["optiontype"] = str(it.get("optiontype"))
    if it.get("pricetiers"):
        pb["pricetiers"] = it.get("pricetiers")
    row = {
        "external_id": str(it.get("id")),
        "order_ext": str(order["id"]),
        "parent_ext": str(parent_ext) if parent_ext else None,
        "johku_product_id": None if it.get("product_id") in (None, "") else str(it.get("product_id")),
        "kb_product_id": cat.kb_of(it.get("product_id")),
        "product_name": name,
        "kind": kind,
        "addon_code": addon_code,
        "quantity": quantity,
        "unit_price_gross": unit,
        "line_total_gross": line_total,
        "vat_rate": vat,
        "price_breakdown": pb,
        "created_at": iso(order.get("orderdate")),
    }
    row["sync_hash"] = canon_hash({k: v for k, v in row.items() if k != "sync_hash"})
    return row


def _order_status(order, res_statuses, existing):
    if str(order.get("refunded")) == "1":
        desired = "cancelled"
    elif any(s == "confirmed" for s in res_statuses):
        desired = "confirmed"
    elif res_statuses or str(order.get("paid")) == "1":
        desired = "completed"
    else:
        desired = "pending"
    if existing:
        prev = existing.get("status")
        if prev == "expired" and desired == "pending":
            return "expired"
        if prev == "completed" and desired == "pending":
            return "completed"
    return desired


def _payment_status(order, bill):
    total = money(order.get("total"))
    if str(order.get("refunded")) == "1":
        if bill is not None and abs(abs(money(bill.get("total"))) - total) >= 0.01:
            return "partially_refunded"
        return "refunded"
    if str(order.get("paid")) == "1":
        return "paid"
    return "unpaid"


def _billing(order):
    company = clean(order.get("company")) or clean(order.get("billing_company"))
    bid_raw = clean(order.get("billing_ident")) or clean(order.get("ident"))
    if not (company or bid_raw or order.get("billing_name")):
        return None
    bid = _biz(bid_raw) if bid_raw else None
    bill = {
        "name": clean(order.get("billing_name")) or clean(order.get("name")),
        "company": company,
        "business_id": bid,
        "address": clean(order.get("billing_address")) or clean(order.get("address")),
        "zip": clean(order.get("billing_zip")) or clean(order.get("zip")),
        "city": clean(order.get("billing_city")) or clean(order.get("city")),
        "country": clean(order.get("billing_country")) or clean(order.get("country")),
        "email": clean(order.get("billing_billingemail")) or clean(order.get("billing_email")),
        "einvoice_address": clean(order.get("billing_evoice")) or clean(order.get("evoice")),
        "einvoice_operator": clean(order.get("billing_evoiceint")) or clean(order.get("evoiceint")),
    }
    return {k: v for k, v in bill.items() if v}


def _johku_meta(order, bill):
    paid = str(order.get("paid")) == "1"
    meta = {
        "payment_method": (bill or {}).get("payment") if bill and bill.get("payment") else order.get("payment"),
        "paid": paid,
        "amount": money(order.get("total")),
        "paid_at": iso(order.get("paymentdate")),
        "confirmed_code": order.get("confirmed"),
        "johku_status_code": order.get("status"),
        "source": "johku",
    }
    if bill and bill.get("id"):
        meta["bill_id"] = str(bill.get("id"))
    return {k: v for k, v in meta.items() if v not in (None, "")}


def build_plan(prev: dict, nxt: dict, db_state: dict | None, now: datetime, taken_order_nos=None, sequence_last=None, cat: Catalog | None = None, force: bool = False) -> dict:
    cat = cat or Catalog()
    if now.tzinfo is None:
        now = now.replace(tzinfo=TZ)
    taken = {int(x) for x in (taken_order_nos or [])}
    db_state = db_state or {}
    db_res = {str(k): v for k, v in (db_state.get("reservations") or {}).items()}
    db_ord = {str(k): v for k, v in (db_state.get("orders") or {}).items()}
    db_item = {str(k): v for k, v in (db_state.get("items") or {}).items()}
    anon = {str(x) for x in (db_state.get("anonymized_customers") or [])}

    for kind in ("customers", "orders", "reservations"):
        if shrunk(len(prev.get(kind) or []), len(nxt.get(kind) or [])):
            raise ExportRejected("export_shrunk", kind)

    prev_c = {str(c["id"]): record_hash(c) for c in prev.get("customers") or []}
    next_c = {str(c["id"]): c for c in nxt.get("customers") or []}
    prev_bills = {str(b.get("identifier")): b for b in (prev.get("bills") or []) if b.get("identifier")}
    next_bills = {str(b.get("identifier")): b for b in (nxt.get("bills") or []) if b.get("identifier")}

    def order_fp(o, bills):
        b = bills.get(str(o.get("identifier") or ""))
        sig = None if not b else {k: b.get(k) for k in ("id", "payment", "total", "identifier")}
        return record_hash({"o": o, "b": sig})

    prev_o = {str(o["id"]): order_fp(o, prev_bills) for o in prev.get("orders") or []}
    next_o = {str(o["id"]): o for o in nxt.get("orders") or []}
    prev_r = {str(r["id"]): record_hash(r) for r in prev.get("reservations") or []}
    next_r = {str(r["id"]): r for r in nxt.get("reservations") or []}

    items_by_id, order_of_item = _index_items(nxt.get("orders") or [])
    # Edellisen viennin varaus → tilaus (poistot).
    prev_items, prev_order_of = _index_items(prev.get("orders") or [])
    orders_by_cust = {}
    for o in nxt.get("orders") or []:
        if o.get("customer_id"):
            orders_by_cust.setdefault(str(o["customer_id"]), []).append(o)

    customers = []
    unchanged_c = 0
    anon_changed = []
    for cid, c in next_c.items():
        h = record_hash(c)
        if prev_c.get(cid) == h and not force:
            unchanged_c += 1
            continue
        if cid in anon:
            anon_changed.append(cid)
            continue
        customers.append(_customer_row(c, orders_by_cust.get(cid, []), now))

    changed_orders = [oid for oid, o in next_o.items() if force or prev_o.get(oid) != order_fp(o, next_bills)]
    removed_orders = [oid for oid in prev_o if oid not in next_o]
    changed_res = [rid for rid, r in next_r.items() if force or prev_r.get(rid) != record_hash(r)]
    removed_res = [rid for rid in prev_r if rid not in next_r]

    # Tilauksen katoaminen peruuttaa myös sen varaukset, vaikka varauslista vielä sisältäisi ne.
    prev_res_order = {}
    for r in prev.get("reservations") or []:
        it = prev_items.get(str(r.get("item_id")))
        if it is not None:
            prev_res_order[str(r["id"])] = str(prev_order_of[str(it["id"])]["id"])
    for rid, oid in prev_res_order.items():
        if oid in removed_orders and rid not in removed_res:
            removed_res.append(rid)

    orders, items, reservations = [], [], []
    reviews, skips = [], []
    frozen = 0
    clash = 0

    def add_review(kind, external_id, code):
        reviews.append({"kind": kind, "external_id": str(external_id), "code": code})

    def add_skip(kind, external_id, code):
        skips.append({"kind": kind, "external_id": str(external_id), "code": code})

    for cid in anon_changed:
        add_skip("customer", cid, "anonymized")

    res_by_order = {}
    for r in nxt.get("reservations") or []:
        it = items_by_id.get(str(r.get("item_id")))
        if it is None:
            continue
        oid = str(order_of_item[str(it["id"])]["id"])
        res_by_order.setdefault(oid, []).append(r)

    for oid in changed_orders:
        o = next_o[oid]
        total = money(o.get("total"))
        if total < 0:
            add_review("order", oid, "negative_total")
            continue
        line_items, keep_res, line_reviews = classify_lines(cat, o, items_by_id, order_of_item)
        for rev in line_reviews:
            guard = item_guard(db_item.get(rev["external_id"]))
            if guard:
                add_skip("item", rev["external_id"], guard)
            else:
                add_review(rev["kind"], rev["external_id"], rev["code"])
        existing_o = db_ord.get(oid)
        freeze = order_total_frozen(existing_o)
        if freeze:
            frozen += 1
        res_statuses = []
        for r in res_by_order.get(oid, []):
            iid = str(r.get("item_id"))
            if iid not in keep_res:
                continue
            end = normalize_end(cat, r.get("product_id"), cat.kb_of(r.get("product_id")), parse_ts(r.get("start_ts")), parse_ts(r.get("end_ts")))
            if str(r.get("status")) == "0" or str(o.get("refunded")) == "1":
                res_statuses.append("cancelled")
            elif end is not None and end <= now:
                res_statuses.append("completed")
            else:
                res_statuses.append("confirmed")
        bill = next_bills.get(str(o.get("identifier") or ""))
        if existing_o:
            mode = "keep"
        elif db_state is None and taken_order_nos is None:
            mode = "server"
        else:
            mode = order_no_action(int(oid), taken, sequence_last)
            if mode == "identity":
                clash += 1
        row = {
            "external_id": oid,
            "johku_order_no": int(oid),
            "customer_ext": str(o["customer_id"]) if o.get("customer_id") else None,
            "status": _order_status(o, res_statuses, existing_o),
            "payment_status": _payment_status(o, bill),
            "total_gross": total,
            "preserve_total": freeze,
            "order_no_mode": mode,
            "locale": "en" if str(o.get("version") or "").startswith("en") else "fi",
            "customer_note": (clean(o.get("more")) or "")[:2000] or None,
            "internal_note": ("johku:payment=%s;confirmed=%s" % (o.get("payment"), o.get("confirmed")))[:500],
            "confirmed_at": iso(o.get("paymentdate") or o.get("orderdate")) if str(o.get("paid")) == "1" or str(o.get("confirmed")) == "2" else None,
            "cancelled_at": iso(o.get("orderdate")) if str(o.get("refunded")) == "1" else None,
            "customer_kind": "company" if (clean(o.get("company")) or clean(o.get("billing_company"))) else "private",
            "billing": _billing(o),
            "invoice_reference": (clean(o.get("yourreference")) or "")[:100] or None,
            "created_at": iso(o.get("orderdate")),
            "johku_meta": _johku_meta(o, bill),
        }
        row["sync_hash"] = canon_hash({k: v for k, v in row.items() if k != "sync_hash"})
        orders.append(row)
        for itrow in line_items:
            guard = item_guard(db_item.get(itrow["external_id"]))
            if guard:
                add_skip("item", itrow["external_id"], guard)
                continue
            items.append(itrow)

    for rid in changed_res:
        r = next_r[rid]
        guard = reservation_guard(db_res.get(rid))
        if guard:
            add_skip("reservation", rid, guard)
            continue
        it = items_by_id.get(str(r.get("item_id")))
        if it is None:
            add_review("reservation", rid, "missing_item")
            continue
        o = order_of_item[str(it["id"])]
        line_items, keep_res, _revs = classify_lines(cat, o, items_by_id, order_of_item)
        iid = str(r.get("item_id"))
        if iid not in keep_res:
            reason = "side_shift" if any(x["external_id"] == iid and x["price_breakdown"].get("johku_role") == "side_shift" for x in line_items) else "addon_or_not_reservation"
            if cat.addon_code(it.get("product_id")):
                reason = "addon_product"
            elif any(x["external_id"] == iid and x["price_breakdown"].get("johku_role") == "side_shift" for x in line_items):
                reason = "side_shift"
            add_skip("reservation", rid, reason)
            continue
        start = parse_ts(r.get("start_ts"))
        end = parse_ts(r.get("end_ts"))
        if start is None or end is None or end <= start:
            add_review("reservation", rid, "bad_time")
            continue
        kb = cat.kb_of(r.get("product_id"))
        end = normalize_end(cat, r.get("product_id"), kb, start, end)
        if str(r.get("status")) == "0" or str(o.get("refunded")) == "1":
            status, reason = "cancelled", "johku_import"
        elif end <= now:
            status, reason = "completed", None
        else:
            status, reason = "confirmed", None
        persons = int(num(r.get("count"), 1)) or 1
        if persons < 1:
            persons = 1
        parent_ext = clean(it.get("item_id"))
        parent = items_by_id.get(str(parent_ext)) if parent_ext else None
        parent_order = order_of_item.get(str(parent_ext)) if parent_ext else None
        parent_same = bool(parent_order and str(parent_order.get("id")) == str(o["id"]))
        row = {
            "external_id": rid,
            "order_ext": str(o["id"]),
            "item_ext": iid,
            "johku_product_id": None if r.get("product_id") in (None, "") else str(r.get("product_id")),
            "kb_product_id": kb,
            "optiontype": str(it.get("optiontype")) if it.get("optiontype") not in (None, "") else None,
            "line_price": money(it.get("price")),
            "parent_johku_product_id": None if not parent else (str(parent.get("product_id")) if parent.get("product_id") not in (None, "") else None),
            "parent_same_order": parent_same,
            "starts_at": iso(start),
            "ends_at": iso(end),
            "persons": persons,
            "participant_breakdown": _tiers(r.get("pricetiers")),
            "status": status,
            "cancel_reason": reason,
            "pool_codes": pool_codes(kb, start if kb != 7 else start),
            "notes": (clean(r.get("client_more")) or "")[:2000] or None,
            "created_at": iso(r.get("creation_ts")),
            "checkin_at": iso(r.get("checkin_ts")),
            "checkout_at": iso(r.get("checkout_ts")),
        }
        # Paketin savusauna alkaa +30 min; pooli lasketaan siitä.
        if kb == 7:
            row["pool_codes"] = pool_codes(7, start)
            row["claim_offset_min"] = 30
        row["sync_hash"] = canon_hash({k: v for k, v in row.items() if k != "sync_hash"})
        reservations.append(row)

    cancel_orders = []
    for oid in removed_orders:
        cancel_orders.append(oid)

    cancel_res = []
    for rid in removed_res:
        guard = reservation_guard(db_res.get(rid))
        if guard:
            add_skip("reservation", rid, guard)
            continue
        cancel_res.append(rid)

    # Varmistus: suunnitelma ei koskaan kuvaa maksuja, kuitteja tai sähköposteja.
    plan = {
        "customers": customers,
        "orders": orders,
        "items": items,
        "reservations": reservations,
        "cancel_orders": cancel_orders,
        "cancel_reservations": cancel_res,
        "review": reviews,
        "skips": skips,
        "counts": {
            "customers_upsert": len(customers),
            "customers_unchanged": unchanged_c,
            "orders_upsert": len(orders),
            "orders_cancel": len(cancel_orders),
            "orders_total_frozen": frozen,
            "orders_number_clash": clash,
            "items_upsert": len(items),
            "reservations_upsert": len(reservations),
            "reservations_cancel": len(cancel_res),
            "skipped": len(skips),
            "review": len(reviews),
        },
    }
    _assert_no_money_side_effects(plan)
    return plan


def _tiers(s):
    if not s:
        return None
    d = {}
    for part in str(s).split(";"):
        if ":" in part:
            a, b = part.split(":", 1)
            try:
                d["tier_" + a] = int(b)
            except ValueError:
                pass
    return d or None


def _assert_no_money_side_effects(plan):
    banned = {"payments", "receipts", "email_outbox", "accounting_outbox", "payment_lines", "refunds"}
    def walk(node):
        if isinstance(node, dict):
            bad = banned.intersection(node)
            if bad:
                raise ExportRejected("forbidden_key", ",".join(sorted(bad)))
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(plan)


def summarize(plan: dict, heading: str = "johku-sync") -> str:
    from redact import redact

    c = plan["counts"]
    lines = [
        heading,
        "customers upsert=%s unchanged=%s" % (c["customers_upsert"], c["customers_unchanged"]),
        "orders upsert=%s cancel=%s total_frozen=%s order_no_clash=%s" % (
            c["orders_upsert"], c["orders_cancel"], c["orders_total_frozen"], c["orders_number_clash"]),
        "items upsert=%s" % c["items_upsert"],
        "reservations upsert=%s cancel=%s" % (c["reservations_upsert"], c["reservations_cancel"]),
        "skipped=%s review=%s" % (c["skipped"], c["review"]),
    ]
    for row in plan["review"]:
        lines.append("review %s %s %s" % (row["kind"], row["external_id"], row["code"]))
    for row in plan["skips"]:
        lines.append("skip %s %s %s" % (row["kind"], row["external_id"], row["code"]))
    for oid in plan["cancel_orders"]:
        lines.append("cancel order %s johku_removed" % oid)
    for rid in plan["cancel_reservations"]:
        lines.append("cancel reservation %s johku_removed" % rid)
    lines.append("writes: customers orders order_items reservations cancellations")
    lines.append("does not write payments receipts email_outbox accounting_outbox")
    return redact("\n".join(lines), limit=4000)
