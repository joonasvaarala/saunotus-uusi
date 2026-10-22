"""Johku REST, vain GET. Avainta ei tulosteta. Ei rinnakkaisia kutsuja.

Johkun palomuuri palauttaa satunnaisesti tyhjän HTTP 403:n. Silloin odotetaan
10–40 s ja yritetään uudelleen. Pyyntöjen väli on vähintään sekunti.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

MIN_INTERVAL = float(os.environ.get("JOHKU_MIN_INTERVAL", "1"))
UA = "johku-sync/1 (GET only)"


class JohkuError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def load_env(path: str) -> dict:
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    for key in ("JOHKU_API_KEY", "JOHKU_SHOP"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    if not env.get("JOHKU_API_KEY") or not env.get("JOHKU_SHOP"):
        raise JohkuError("missing_johku_env")
    return env


class Client:
    def __init__(self, shop: str, api_key: str, transport=None, sleep=time.sleep, now=time.time):
        self.shop = shop
        self.api_key = api_key
        self.transport = transport or _urllib_get
        self.sleep = sleep
        self.now = now
        self._last = 0.0

    def get(self, path: str, params=None, retries: int = 4):
        path = path.lstrip("/")
        if not path.endswith(".json") and "/" not in path:
            raise JohkuError("bad_path")
        url = "https://johku.com/%s/%s" % (self.shop, path)
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        delay = 10
        last_status = None
        for attempt in range(retries + 1):
            self._wait()
            status, body = self.transport("GET", url, {
                "Authorization": "Bearer " + self.api_key,
                "Accept": "application/json",
                "User-Agent": UA,
            })
            self._last = self.now()
            last_status = status
            empty = body in (b"", None, "")
            waf = (status == 403 and empty) or status in (429, 502, 503, 504)
            if waf and attempt < retries:
                self.sleep(min(delay, 40))
                delay = min(delay * 2, 40)
                continue
            if status != 200:
                raise JohkuError("http_%s" % status)
            if not body:
                return None
            return json.loads(body)
        raise JohkuError("http_%s" % last_status)

    def _wait(self):
        gap = MIN_INTERVAL - (self.now() - self._last)
        if gap > 0:
            self.sleep(gap)

    def list(self, name: str, params=None):
        query = {"limit": "100000"}
        if params:
            query.update(params)
        data = self.get(name + ".json", query)
        if not isinstance(data, list):
            raise JohkuError("not_a_list")
        return data


def _urllib_get(method: str, url: str, headers: dict):
    if method != "GET":
        raise JohkuError("method")
    req = urllib.request.Request(url, method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
