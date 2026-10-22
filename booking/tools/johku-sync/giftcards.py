"""Lahjakorttien saldo. Listassa ei ole saldoa, joten aktiivinen kortti haetaan
yksitellen. Täysi ajo hakee myös passiiviset. Koodeja ei tulosteta.
"""
from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from rules import canon_hash, money

TZ = ZoneInfo("Europe/Helsinki")
LIST_KEYS = ("id", "status", "value", "count", "validfrom", "validto", "deleted", "singleuse", "voucher_id", "item_id")


def list_hash(row: dict) -> str:
    return canon_hash({k: row.get(k) for k in LIST_KEYS})


def _active(row: dict, now_ts: float) -> bool:
    if str(row.get("deleted") or "0") not in ("0", ""):
        return False
    if str(row.get("status")) != "1":
        return False
    valid = str(row.get("validto") or "")
    if valid.isdigit() and int(valid) != 0 and int(valid) <= now_ts:
        return False
    return True


def select_cards(prev: list, nxt: list, mode: str, now_ts: float) -> list:
    """mode changed: uusi, listalta muuttunut tai yhä aktiivinen.
    mode full: jokainen listan kortti (myös käytetty ja poistettu).
    """
    prev_by = {str(r.get("id")): list_hash(r) for r in prev or []}
    out = []
    for row in nxt or []:
        cid = str(row.get("id"))
        changed = prev_by.get(cid) != list_hash(row)
        if mode == "full" or changed or _active(row, now_ts):
            out.append(row)
    return out


def detail_row(list_row: dict, detail: dict) -> dict:
    initial = money(detail.get("value") if detail.get("value") not in (None, "") else list_row.get("value"))
    raw_bal = detail.get("remainingvalue")
    balance = money(raw_bal if raw_bal not in (None, "") else initial)
    valid = detail.get("validto") if detail.get("validto") not in (None, "") else list_row.get("validto")
    valid_date = None
    if str(valid or "") not in ("", "0", "None"):
        valid_date = datetime.fromtimestamp(int(valid), TZ).date().isoformat()
    created = int(list_row.get("created") or detail.get("created") or 0)
    order_ext = detail.get("order_id") or list_row.get("order_id")
    return {
        "external_id": str(detail.get("id") or list_row.get("id")),
        "code": detail.get("code") or list_row.get("code"),
        "kind": "value",
        "initial_amount": initial,
        "balance": balance,
        "valid_to": valid_date,
        "created_unix": created,
        "purchase_order_ext": None if order_ext in (None, "", "0") else str(order_ext),
        "balance_verified": True,
        "balance_source": "johku_api",
        "single_order": str(detail.get("singleorder") or detail.get("singleuse") or "") == "1",
        "meta": {"template": detail.get("name") or list_row.get("name")},
        "ledger": [{
            "at_unix": created or int(datetime.now(TZ).timestamp()),
            "seq": 1,
            "delta": balance,
            "reason": "johku_sync",
            "note": None,
            "meta": {},
        }],
    }
