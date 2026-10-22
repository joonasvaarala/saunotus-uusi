"""Johku-tuote → kb / lisäpalvelu. Vain tuoteluettelo, ei asiakkaita."""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "ref")


def _load(name):
    with open(os.path.join(REF, name), encoding="utf-8") as f:
        return json.load(f)


class Catalog:
    def __init__(self):
        kb = _load("kb_product_map.json")
        roles = _load("roles.json")
        self.kb = {}
        self.kb.update({str(k): int(v) for k, v in kb["clean"].items()})
        self.kb.update({str(k): int(v) for k, v in kb["proposed"].items()})
        self.addon = {str(k): v for k, v in roles["addon_by_johku_product"].items()}
        self.package_products = {str(x) for x in roles["package_johku_products"]}
        self.package_kb = int(roles["package_kb"])
        self.side_shift_kb = int(roles["side_shift_kb"])
        self.side_shift_optiontype = str(roles["side_shift_optiontype"])
        self.separate_ritual_kb = int(roles["separate_ritual_kb"])
        self.normalize_kb = {int(x) for x in roles["normalize_30_to_120_kb"]}
        self.fee_names = set(roles["fee_names"])
        keep = _load("general_shift_keep.json")
        self.keep_shifts = {(str(x["johku_product_id"]), str(x["starts_local"])) for x in keep}

    def kb_of(self, johku_product_id):
        if johku_product_id in (None, ""):
            return None
        return self.kb.get(str(johku_product_id))

    def addon_code(self, johku_product_id):
        return self.addon.get(str(johku_product_id or ""))
