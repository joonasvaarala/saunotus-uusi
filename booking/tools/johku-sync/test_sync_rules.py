"""SYNC_SAANNOT: kuiva ajo fixturellä, ei verkkoa eikä kantaa."""
import json
import os
import sys
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from catalog import Catalog  # noqa: E402
from fixtures.case_data import build  # noqa: E402
from giftcards import detail_row, select_cards  # noqa: E402
from johku_api import Client, JohkuError  # noqa: E402
from rules import ExportRejected, build_plan, order_no_action, orders_lack_items, shrunk, summarize  # noqa: E402
from sync import advance_baseline, chunks, db_state_from_remote, fetch_export, main  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MIGRATION = os.path.join(ROOT, "supabase", "migrations", "20261022091609_booking_126_johku_sync.sql")
MIGRATION_227 = os.path.join(ROOT, "supabase", "migrations", "20261101130000_booking_227_johku_unmapped_review.sql")
MIGRATION_227B = os.path.join(ROOT, "supabase", "migrations", "20261101133000_booking_227b_therapist_slack_null_leg.sql")


def plan():
    b = build()
    return build_plan(b["prev"], b["next"], b["db_state"], b["now"], b["db_state"]["taken_order_nos"], b["db_state"]["sequence_last"])


class RulesTest(unittest.TestCase):
    def test_fixture_dry_run(self):
        p = plan()
        text = summarize(p)
        self.assertNotIn("testi@example.test", text)
        self.assertNotIn("0401234567", text)
        self.assertNotIn("payments", " ".join(p.keys()))
        for banned in ("payments", "receipts", "email_outbox", "accounting_outbox"):
            self.assertNotIn(banned, p)

        by_order = {o["external_id"]: o for o in p["orders"]}
        self.assertTrue(by_order["11551"]["preserve_total"])
        self.assertTrue(by_order["11552"]["preserve_total"])
        self.assertEqual(by_order["11551"]["total_gross"], 203.0)
        self.assertEqual(by_order["10007"]["order_no_mode"], "identity")
        self.assertEqual(by_order["14021"]["order_no_mode"], "explicit_advance")

        item_ids = {i["external_id"] for i in p["items"]}
        self.assertNotIn("13620", item_ids)
        addon = next(i for i in p["items"] if i["external_id"] == "20002")
        self.assertEqual(addon["kind"], "addon")
        self.assertEqual(addon["addon_code"], "turvenaamio_jalkakylpy")
        self.assertTrue(any(i["external_id"] == "20101" and i["price_breakdown"]["johku_role"] == "side_shift" for i in p["items"]))
        self.assertTrue(any(s["external_id"] == "13620" and s["code"] == "addon_row" for s in p["skips"]))
        self.assertTrue(any(s["external_id"] == "502" and s["code"] == "anonymized" for s in p["skips"]))
        self.assertTrue(any(r["external_id"] == "20400" and r["code"] == "ambiguous_parent" for r in p["review"]))

        res = {r["external_id"]: r for r in p["reservations"]}
        self.assertNotIn("10223", res)
        self.assertNotIn("30002", res)
        self.assertNotIn("10275", res)
        self.assertIn("30001", res)
        self.assertIn("30003", res)
        self.assertIn("30004", res)
        self.assertEqual(res["30001"]["pool_codes"], ["yleinen_vkp_1630"])
        self.assertEqual(res["30001"]["claim_offset_min"], 30)
        self.assertTrue(res["30005"]["ends_at"].startswith("2026-10-24T16:00:00"))
        self.assertEqual(res["30005"]["pool_codes"], ["yleinen_vkp_1400"])
        self.assertTrue(any(s["external_id"] == "10223" and s["code"] == "hidden" for s in p["skips"]))
        self.assertTrue(any(s["external_id"] == "30002" and s["code"] == "side_shift" for s in p["skips"]))
        self.assertIn("13941", p["cancel_orders"])
        self.assertIn("11553", p["cancel_orders"])
        cust = next(c for c in p["customers"] if c["external_id"] == "501")
        self.assertEqual(cust["phone"], "0400000002")
        self.assertEqual(cust["email"], "toinen@example.test")
        self.assertEqual(cust["prev"]["phone"], "0400000001")
        self.assertEqual(cust["prev"]["email"], "toinen@example.test")
        self.assertNotIn("toinen@example.test", text)
        self.assertIn("18001", p["cancel_reservations"])
        self.assertIn("30100", p["cancel_reservations"])
        self.assertNotIn("10275", p["cancel_reservations"])
        self.assertNotIn("10223", p["cancel_reservations"])
        self.assertEqual(p["counts"]["customers_unchanged"], 1)
        self.assertTrue(any(c["external_id"] == "501" for c in p["customers"]))
        self.assertFalse(any(c["external_id"] == "502" for c in p["customers"]))
        self.assertEqual(res["30009"]["kb_product_id"], 23)
        self.assertEqual(res["30009"]["johku_product_id"], "134")
        self.assertEqual(res["30009"]["pool_codes"], [])
        self.assertTrue(res["30009"]["ends_at"].startswith("2026-11-04T16:30:00"))

    def test_future_fixture_products_are_mapped(self):
        """Every Johku product that has a future fixture booking must resolve to a kb product."""
        cat = Catalog()
        b = build()
        now = b["now"]
        missing = set()
        seen = set()
        for blob in (b["prev"], b["next"]):
            for row in blob["reservations"]:
                end = datetime.fromtimestamp(int(row["end_ts"]), tz=ZoneInfo("Europe/Helsinki"))
                if end <= now:
                    continue
                pid = str(row["product_id"])
                seen.add(pid)
                if cat.addon_code(pid):
                    continue
                if cat.kb_of(pid) is None:
                    missing.add(pid)
        self.assertIn("134", seen)
        self.assertEqual(cat.kb_of("134"), 23)
        self.assertEqual(cat.kb_of("62"), 23)
        self.assertEqual(missing, set())

    def test_shrink_and_order_numbers(self):
        self.assertFalse(shrunk(10, 1))
        self.assertTrue(shrunk(100, 90))
        self.assertFalse(shrunk(100, 96))
        prev = {"customers": [{"id": str(i)} for i in range(60)], "orders": [], "reservations": []}
        nxt = {"customers": [{"id": "1"}], "orders": [], "reservations": []}
        with self.assertRaises(ExportRejected) as ctx:
            build_plan(prev, nxt, {}, datetime(2026, 10, 22, tzinfo=ZoneInfo("Europe/Helsinki")))
        self.assertEqual(ctx.exception.code, "export_shrunk")
        self.assertEqual(order_no_action(10007, {10007}, 14020), "identity")
        self.assertEqual(order_no_action(14021, set(), 14020), "explicit_advance")
        self.assertEqual(order_no_action(12000, set(), 14020), "explicit")
        self.assertFalse(orders_lack_items([{"id": "1", "ownItem": [{"id": "2"}]}], [{"id": "1", "ownItem": [{"id": "2"}]}]))
        lined = [{"id": "1", "ownItem": [{"id": "9"}]}]
        bare = [{"id": str(i)} for i in range(60)]
        self.assertTrue(orders_lack_items(lined * 60, bare))
        self.assertTrue(orders_lack_items([], bare))
        with self.assertRaises(ExportRejected) as missing:
            build_plan(
                {"customers": [], "orders": lined * 60, "reservations": []},
                {"customers": [], "orders": bare, "reservations": []},
                {},
                datetime(2026, 10, 22, tzinfo=ZoneInfo("Europe/Helsinki")),
            )
        self.assertEqual(missing.exception.code, "export_missing_items")

    def test_summary_has_no_money_side_effects(self):
        text = summarize(plan())
        self.assertIn("does not write payments receipts email_outbox accounting_outbox", text)
        self.assertIn("cancel order 13941 johku_removed", text)

    def test_baseline_keeps_review_rows(self):
        b = build()
        p = plan()
        result = {"review": [{"kind": "order", "external_id": "14021"}], "applied": {}}
        out = advance_baseline(b["prev"], b["next"], p, result)
        ids = {o["id"] for o in out["orders"]}
        self.assertNotIn("14021", ids)
        self.assertIn("13980", ids)
        self.assertNotIn("13941", ids)

    def test_chunks_respect_limits(self):
        plan_big = {"customers": [{"external_id": str(i)} for i in range(401)], "orders": [], "items": [], "reservations": [], "cancel_orders": [], "cancel_reservations": []}
        batches = list(chunks(plan_big))
        self.assertEqual(len(batches), 2)
        self.assertEqual(len(batches[0]["customers"]), 400)

    def test_remote_state_has_no_contact_fields(self):
        state = db_state_from_remote({
            "hidden_reservations": ["10223"],
            "merged_reservations": [],
            "package_merged_reservations": ["10275"],
            "frozen_orders": ["11551"],
            "order_status": {"11551": "confirmed"},
            "addon_items": ["13620"],
            "moved_items": [],
            "anonymized_customers": ["502"],
            "taken_order_nos": [10007],
            "sequence_last": 14020,
            "hidden_count": 33,
        })
        self.assertTrue(state["reservations"]["10223"]["hidden"])
        self.assertTrue(state["reservations"]["10275"]["merged_into_package"])
        self.assertTrue(state["orders"]["11551"]["addon_merge"])
        self.assertEqual(state["items"]["13620"]["kind"], "addon")
        blob = json.dumps(state)
        self.assertNotIn("email", blob)
        self.assertNotIn("@", blob)


class GiftTest(unittest.TestCase):
    def test_select_active_and_changed_only(self):
        now = 1_800_000_000
        prev = [{"id": "1", "status": "1", "value": "50", "deleted": "0", "validto": "0"}]
        nxt = [
            {"id": "1", "status": "1", "value": "50", "deleted": "0", "validto": "0"},
            {"id": "2", "status": "0", "value": "50", "deleted": "0", "validto": "0"},
            {"id": "3", "status": "0", "value": "50", "deleted": "0", "validto": "0"},
        ]
        # 2 is new and inactive: list change, include. 1 is active, include. 3 is new too.
        chosen = {r["id"] for r in select_cards(prev, nxt, "changed", now)}
        self.assertEqual(chosen, {"1", "2", "3"})
        stable = select_cards(nxt, nxt, "changed", now)
        self.assertEqual({r["id"] for r in stable}, {"1"})
        full = select_cards(nxt, nxt, "full", now)
        self.assertEqual(len(full), 3)
        row = detail_row({"id": "1", "created": "1700000000", "value": "50"}, {"id": "1", "code": "AAAA-BBBB-CCCC", "value": "50", "remainingvalue": "20", "validto": "1800000000"})
        self.assertEqual(row["balance"], 20.0)
        self.assertEqual(row["ledger"][0]["delta"], 20.0)
        self.assertNotIn(row["code"], "printed")


class ApiTest(unittest.TestCase):
    def test_get_only_and_waf_retry(self):
        calls = []

        def transport(method, url, headers):
            calls.append(method)
            if method != "GET":
                raise AssertionError(method)
            if len(calls) == 1:
                return 403, b""
            return 200, b'[{"id":"1"}]'

        clock = {"t": 0}

        def now():
            clock["t"] += 10
            return clock["t"]

        slept = []
        client = Client("shop", "secret", transport=transport, sleep=slept.append, now=now)
        data = client.get("orders.json", {"limit": "1"}, retries=2)
        self.assertEqual(data, [{"id": "1"}])
        self.assertEqual(calls, ["GET", "GET"])
        self.assertIn(10, slept)
        self.assertTrue(url_is_get(calls))

    def test_orders_list_includes_items(self):
        urls = []

        def transport(method, url, headers):
            urls.append(url)
            if "orders.json" in url:
                return 200, b'[{"id":"1","ownItem":[{"id":"9"}]}]'
            return 200, b"[]"

        clock = {"t": 0}

        def now():
            clock["t"] += 10
            return clock["t"]

        client = Client("shop", "secret", transport=transport, sleep=lambda _s: None, now=now)
        data = fetch_export(client)
        order_urls = [u for u in urls if "orders.json" in u]
        self.assertEqual(len(order_urls), 1)
        self.assertIn("items=true", order_urls[0])
        self.assertIn("limit=100000", order_urls[0])
        self.assertEqual(data["orders"][0]["ownItem"][0]["id"], "9")
        for url in urls:
            if "orders.json" not in url:
                self.assertNotIn("items=", url)
        self.assertEqual(len(urls), 5)

    def test_seed_baseline_from_export_dir(self):
        import tempfile
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as state:
            files = {
                "customers": [{"id": "1"}],
                "orders": [{"id": "10", "ownItem": [{"id": "11"}]}],
                "reservations": [],
                "bills": [],
                "valuecards": [],
            }
            for name, rows in files.items():
                with open(os.path.join(src, name + ".json"), "w", encoding="utf-8") as f:
                    json.dump(rows, f)
            self.assertEqual(main(["--seed-baseline", src, "--state-dir", state]), 0)
            with open(os.path.join(state, "baseline.json"), encoding="utf-8") as f:
                saved = json.load(f)
            self.assertEqual(saved["orders"][0]["ownItem"][0]["id"], "11")
            with open(os.path.join(src, "orders.json"), "w", encoding="utf-8") as f:
                json.dump([{"id": str(i)} for i in range(60)], f)
            self.assertEqual(main(["--seed-baseline", src, "--state-dir", state]), 1)
            os.remove(os.path.join(src, "bills.json"))
            self.assertEqual(main(["--seed-baseline", src, "--state-dir", state]), 1)

    def test_refuses_non_json_path_without_calling(self):
        def transport(method, url, headers):
            raise AssertionError("called")
        client = Client("shop", "secret", transport=transport, sleep=lambda s: None, now=lambda: 0)
        with self.assertRaises(JohkuError):
            client.get("orders", retries=0)


def url_is_get(calls):
    return set(calls) == {"GET"}


class MigrationTextTest(unittest.TestCase):
    def test_sql_enforces_rules(self):
        with open(MIGRATION, encoding="utf-8") as f:
            sql = f.read().lower()
        for needle in (
            "hidden_at is not null",
            "addon_merge",
            "johku_removed",
            "merged_into",
            "johku_sync_side_effect",
            "johku_sync_unhide",
            "skip_audit",
            "_johku_sync_text",
            "addon_merge_total",
            "'johku_sync'",
            "103",
            "179",
        ):
            self.assertIn(needle, sql)
        self.assertNotIn("email = v_email", sql)
        self.assertNotIn("delete from", sql)
        self.assertNotIn("insert into booking.payments", sql)
        self.assertNotIn("insert into booking.receipts", sql)
        self.assertNotIn("insert into booking.email_outbox", sql)
        self.assertNotIn("insert into booking.accounting_outbox", sql)
        self.assertNotIn("hidden_at =", sql)

    def test_unmapped_product_is_reviewed(self):
        with open(MIGRATION_227, encoding="utf-8") as f:
            sql = f.read().lower()
        self.assertIn("'unmapped_product'", sql)
        self.assertIn("resource_class in ('none', 'text_only')", sql)
        self.assertIn("_johku_unmapped_needs_room", sql)
        marker = "booking_227: ei_resurssia only when"
        self.assertIn(marker, sql)
        block = sql.split(marker, 1)[1].split("if v_space is null then", 1)[0]
        self.assertIn("text_only", block)
        self.assertIn("ei_resurssia", block)
        self.assertIn("v_kb is not null", block)
        self.assertIn("johku_product_id' = '134'", sql)

    def test_227b_null_leg_and_existing_update(self):
        with open(MIGRATION_227B, encoding="utf-8") as f:
            sql = f.read().lower()
        self.assertEqual(sql.count("p_exclude_leg is null or c.leg_id is distinct from p_exclude_leg"), 2)
        self.assertIn("interval '15 minutes'", sql)
        self.assertIn("recent_ei as materialized", sql)
        self.assertIn("v_space is null and v_res_id is null", sql)
        self.assertIn("v_res.space_id", sql)
        self.assertIn("lr.code = 'rauni'", sql)


if __name__ == "__main__":
    unittest.main()
