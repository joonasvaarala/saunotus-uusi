#!/usr/bin/env python3
"""Johku -> booking -synkka. Yksi komento, ei service_role-avainta.

  python3 sync.py --dry-run --fixture case
  python3 sync.py                      # inkrementaalinen, vaatii ~/.secrets
  python3 sync.py --full --cards full  # täysi ajo, myös lahjakortit
  python3 sync.py --save-baseline      # tallentaa viennin vertailupohjaksi, ei kirjoita kantaan
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from giftcards import detail_row, select_cards  # noqa: E402
from johku_api import Client, JohkuError, load_env  # noqa: E402
from redact import redact  # noqa: E402
from rules import TZ, ExportRejected, build_plan, summarize  # noqa: E402

KINDS = ("customers", "orders", "reservations", "bills", "valuecards")
LIMITS = {"customers": 400, "orders": 200, "items": 800, "reservations": 400, "cancel_orders": 400, "cancel_reservations": 400}


def db_state_from_remote(s: dict) -> dict:
    res = {}
    for eid in s.get("hidden_reservations") or []:
        res.setdefault(str(eid), {})["hidden"] = True
    for eid in s.get("merged_reservations") or []:
        res.setdefault(str(eid), {})["merged_into"] = True
    for eid in s.get("package_merged_reservations") or []:
        res.setdefault(str(eid), {})["merged_into_package"] = True
    orders = {}
    for eid, st in (s.get("order_status") or {}).items():
        orders[str(eid)] = {"status": st}
    for eid in s.get("frozen_orders") or []:
        orders.setdefault(str(eid), {})["addon_merge"] = True
    items = {}
    for eid in s.get("addon_items") or []:
        items[str(eid)] = {"kind": "addon", "order_id": "row"}
    for eid in s.get("moved_items") or []:
        items.setdefault(str(eid), {}).update({"merged_from_order_id": "moved", "order_id": "row"})
    seq = s.get("sequence_last")
    return {
        "reservations": res,
        "orders": orders,
        "items": items,
        "anonymized_customers": [str(x) for x in s.get("anonymized_customers") or []],
        "taken_order_nos": [int(x) for x in (s.get("taken_order_nos") or [])],
        "sequence_last": None if seq is None else int(seq),
        "hidden_count": s.get("hidden_count"),
    }


def chunks(plan: dict):
    """Yksi laji kerrallaan: asiakkaat, tilaukset, rivit, varaukset, peruutukset."""
    keys = ("customers", "orders", "items", "reservations", "cancel_orders", "cancel_reservations")
    for key in keys:
        rows = list(plan.get(key) or [])
        while rows:
            batch = {k: [] for k in keys}
            batch[key] = rows[: LIMITS[key]]
            rows = rows[LIMITS[key]:]
            yield batch


def advance_baseline(prev: dict, nxt: dict, plan: dict, result: dict) -> dict:
    """Tarkistettavat rivit jäävät vanhaan vientin, jotta seuraava ajo yrittää uudelleen."""
    review = {(r["kind"], str(r["external_id"])) for r in (result.get("review") or [])}
    review_items = {eid for kind, eid in review if kind == "item"}
    item_order = {}
    for it in plan.get("items") or []:
        item_order[str(it["external_id"])] = str(it["order_ext"])
    review_orders = {eid for kind, eid in review if kind == "order"}
    review_orders |= {item_order[i] for i in review_items if i in item_order}
    res_order = {str(r["external_id"]): str(r["order_ext"]) for r in plan.get("reservations") or []}
    review_orders |= {res_order[eid] for kind, eid in review if kind == "reservation" and eid in res_order}

    def merge(kind_name, key, id_of):
        prev_by = {id_of(r): r for r in prev.get(key) or []}
        next_by = {id_of(r): r for r in nxt.get(key) or []}
        out = {}
        for i, row in next_by.items():
            held = (kind_name, i) in review or (kind_name == "order" and i in review_orders)
            if held and i in prev_by:
                out[i] = prev_by[i]
            elif not held:
                out[i] = row
        for i, row in prev_by.items():
            if i not in next_by and (kind_name, i) in review:
                out[i] = row
        return list(out.values())

    ident = lambda r: str(r["id"])  # noqa: E731
    return {
        "customers": merge("customer", "customers", ident),
        "orders": merge("order", "orders", ident),
        "reservations": merge("reservation", "reservations", ident),
        "bills": list(nxt.get("bills") or []),
        "valuecards": list(nxt.get("valuecards") or []),
    }


class Remote:
    def __init__(self, url: str, secret: str, opener=None):
        self.url = url
        self.secret = secret
        self.opener = opener or urllib.request.urlopen

    def post(self, body: dict) -> dict:
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(self.url, data=data, method="POST", headers={
            "content-type": "application/json",
            "x-johku-sync-secret": self.secret,
        })
        try:
            with self.opener(req, timeout=120) as r:
                payload = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                payload = {"ok": False, "error": "http_%s" % e.code}
            payload.setdefault("ok", False)
        if not payload.get("ok", True) and payload.get("error"):
            raise JohkuError(str(payload.get("error") if isinstance(payload.get("error"), str) else payload["error"].get("code", "remote")))
        return payload


def load_baseline(path: str) -> dict:
    if not os.path.exists(path):
        return {k: [] for k in KINDS}
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for k in KINDS:
        data.setdefault(k, [])
    return data


def save_json(path: str, data) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load_fixture(name: str):
    if name != "case":
        raise JohkuError("unknown_fixture")
    from fixtures.case_data import build
    return build()


def fetch_export(client: Client) -> dict:
    return {
        "customers": client.list("customers"),
        "orders": client.list("orders"),
        "reservations": client.list("reservations"),
        "bills": client.list("bills"),
        "valuecards": client.list("valuecards"),
    }


def push_plan(remote: Remote, plan: dict) -> dict:
    applied = {k: [] for k in ("customers", "orders", "items", "reservations", "cancel_orders", "cancel_reservations")}
    skipped, review = [], []
    for batch in chunks(plan):
        res = remote.post({"action": "apply", "payload": batch})["result"]
        for k in applied:
            applied[k].extend(res.get("applied", {}).get(k) or [])
        skipped.extend(res.get("skipped") or [])
        review.extend(res.get("review") or [])
    return {"applied": applied, "skipped": skipped, "review": review}


def run(args) -> int:
    now = datetime.now(TZ)
    mode = "full" if args.full else "incremental"
    if args.cards:
        mode = "cards" if not args.full else "full"
    counts = {}
    remote = None
    run_id = None
    try:
        if args.fixture:
            bundle = load_fixture(args.fixture)
            prev, nxt, db_state, now = bundle["prev"], bundle["next"], bundle["db_state"], bundle["now"]
        else:
            env = load_env(args.johku_env)
            client = Client(env["JOHKU_SHOP"], env["JOHKU_API_KEY"])
            baseline_path = os.path.join(args.state_dir, "baseline.json")
            prev = load_baseline(baseline_path)
            nxt = fetch_export(client)
            if args.save_baseline:
                save_json(baseline_path, nxt)
                print("baseline saved %s" % baseline_path)
                return 0
            sync_env = load_env_sync(args.sync_env)
            remote = Remote(sync_env["JOHKU_SYNC_URL"], sync_env["JOHKU_SYNC_SECRET"])
            db_state = db_state_from_remote(remote.post({"action": "state"})["state"])

        plan = build_plan(
            prev, nxt, db_state, now,
            taken_order_nos=db_state.get("taken_order_nos"),
            sequence_last=db_state.get("sequence_last"),
            force=bool(args.full),
        )
        card_rows = []
        if args.cards:
            chosen = select_cards(prev.get("valuecards") or [], nxt.get("valuecards") or [], "full" if args.cards == "full" else "changed", now.timestamp())
            counts["cards_selected"] = len(chosen)
            if not args.fixture and not args.dry_run and args.cards:
                env = load_env(args.johku_env)
                client = Client(env["JOHKU_SHOP"], env["JOHKU_API_KEY"])
                for row in chosen:
                    code = row.get("code") or ""
                    detail = client.get("valuecards/%s.json" % urllib_quote(code), {"details": "true"})
                    card_rows.append(detail_row(row, detail))
        text = summarize(plan)
        if args.cards:
            text += "\ncards selected=%s" % counts.get("cards_selected", len(card_rows))
        print(text)
        if args.dry_run or args.fixture and args.dry_run:
            if remote and not args.fixture:
                remote.post({"action": "log", "row": {"status": "dry_run", "mode": "dry_run", "counts": plan["counts"]}})
            return 0
        if args.fixture:
            return 0
        run_id = remote.post({"action": "log", "row": {"status": "running", "mode": mode}})["result"]["id"]
        result = push_plan(remote, plan)
        if card_rows:
            for i in range(0, len(card_rows), 100):
                remote.post({"action": "gift_cards", "rows": card_rows[i:i + 100]})
            counts["cards_pushed"] = len(card_rows)
        counts.update(plan["counts"])
        counts["review"] = len(result["review"])
        counts["skipped"] = len(result["skipped"])
        remote.post({"action": "log", "row": {"id": run_id, "status": "ok", "mode": mode, "counts": counts}})
        save_json(os.path.join(args.state_dir, "baseline.json"), advance_baseline(prev, nxt, plan, result))
        if result["review"]:
            print("review %s" % len(result["review"]))
        return 0
    except (ExportRejected, JohkuError, OSError, urllib.error.URLError, json.JSONDecodeError) as e:
        code = getattr(e, "code", None) or type(e).__name__
        msg = redact(str(code), 200)
        print("failed %s" % msg, file=sys.stderr)
        if remote is not None and run_id is not None:
            try:
                remote.post({"action": "log", "row": {"id": run_id, "status": "failed", "mode": mode, "counts": counts, "error": msg}})
            except (JohkuError, OSError, urllib.error.URLError):
                pass
        return 1


def load_env_sync(path: str) -> dict:
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    if not env.get("JOHKU_SYNC_URL") or not env.get("JOHKU_SYNC_SECRET"):
        raise JohkuError("missing_sync_env")
    return env


def urllib_quote(code: str) -> str:
    import urllib.parse
    return urllib.parse.quote(code.replace("-", "").replace(" ", "").upper(), safe="")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Johku-synkka uuteen varausjärjestelmään")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--full", action="store_true")
    p.add_argument("--cards", nargs="?", const="changed", choices=("changed", "full"))
    p.add_argument("--save-baseline", action="store_true")
    p.add_argument("--fixture", help="fixtures/<name>.py ilman verkkoa, esim. case")
    p.add_argument("--state-dir", default=os.path.expanduser("~/.johku-sync/state"))
    p.add_argument("--johku-env", default=os.path.expanduser("~/.secrets/johku.env"))
    p.add_argument("--sync-env", default=os.path.expanduser("~/.secrets/johku_sync.env"))
    args = p.parse_args(argv)
    if args.fixture and not args.dry_run and not args.save_baseline:
        args.dry_run = True
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
