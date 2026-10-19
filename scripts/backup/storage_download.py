"""Lataa Storage-bucketien tiedostot Supabasen Storage HTTP API:lla.

Yksinkertaisin tapa noin kymmenelle objektille: service role -avain, ei erillisiä S3-avaimia.
S3-rajapinta (storage/v1/s3) vaatisi omat access keyt dashboardista. Niitä ei käytetä.

Api:
  GET  {url}/storage/v1/bucket
  POST {url}/storage/v1/object/list/{bucket}
  GET  {url}/storage/v1/object/{bucket}/{polku}
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from common import BackupError


def _headers(key: str, json_body: bool = False) -> dict[str, str]:
    headers = {
        "Authorization": f"Bearer {key}",
        "apikey": key,
    }
    if json_body:
        headers["Content-Type"] = "application/json"
    return headers


def request_bytes(url: str, key: str, method: str = "GET", body: dict | None = None) -> bytes:
    data = None if body is None else json.dumps(body).encode("utf-8")
    last_error = "tuntematon virhe"
    for attempt in range(5):
        req = urllib.request.Request(
            url,
            data=data,
            headers=_headers(key, json_body=body is not None),
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:300]
            last_error = f"HTTP {exc.code}"
            if exc.code not in {429, 500, 502, 503, 504} or attempt == 4:
                raise BackupError(f"storage-pyyntö epäonnistui ({last_error})") from exc
        except urllib.error.URLError as exc:
            last_error = "verkko"
            if attempt == 4:
                raise BackupError(f"storage-pyyntö epäonnistui ({last_error})") from exc
        time.sleep(min(2 ** attempt, 8))
    raise BackupError(f"storage-pyyntö epäonnistui ({last_error})")


def safe_segment(name: str) -> str:
    if not name or name in {".", ".."} or "/" in name or "\\" in name or name.startswith("."):
        raise BackupError("storage-nimi ei ole turvallinen yksittäinen polun osa")
    if ".." in name:
        raise BackupError("storage-nimi ei ole turvallinen")
    return name


def list_buckets(base: str, key: str) -> list[dict]:
    raw = request_bytes(f"{base}/storage/v1/bucket", key)
    payload = json.loads(raw.decode("utf-8"))
    if not isinstance(payload, list):
        raise BackupError("bucket-lista ei ole taulukko")
    return payload


def list_page(base: str, key: str, bucket: str, prefix: str, offset: int) -> list[dict]:
    body = {
        "prefix": prefix,
        "limit": 100,
        "offset": offset,
        "sortBy": {"column": "name", "order": "asc"},
    }
    raw = request_bytes(
        f"{base}/storage/v1/object/list/{urllib.parse.quote(bucket)}",
        key,
        method="POST",
        body=body,
    )
    payload = json.loads(raw.decode("utf-8"))
    if not isinstance(payload, list):
        raise BackupError(f"objektien lista bucketissa {bucket} ei ole taulukko")
    return payload


def iter_objects(base: str, key: str, bucket: str) -> list[str]:
    files: list[str] = []
    stack = [""]
    seen_prefixes: set[str] = set()
    while stack:
        prefix = stack.pop()
        if prefix in seen_prefixes:
            continue
        seen_prefixes.add(prefix)
        offset = 0
        while True:
            page = list_page(base, key, bucket, prefix, offset)
            if not page:
                break
            for item in page:
                name = item.get("name") or ""
                if name in {".emptyFolderPlaceholder"}:
                    continue
                safe_segment(name)
                path = f"{prefix}{name}" if not prefix else f"{prefix}{name}"
                # Kansio: id on null. Tiedosto: id on uuid.
                if item.get("id") is None:
                    stack.append(path + "/")
                else:
                    files.append(path)
            if len(page) < 100:
                break
            offset += 100
            if offset > 100000:
                raise BackupError("storage-listaus ei päättynyt")
    return files


def download(base: str, key: str, dest: Path, max_files: int, max_bytes: int) -> dict:
    dest.mkdir(parents=True, exist_ok=True)
    files_root = dest / "files"
    files_root.mkdir()
    buckets = list_buckets(base, key)
    manifest_files = []
    total = 0
    for bucket in buckets:
        bucket_id = bucket.get("id") or bucket.get("name")
        if not isinstance(bucket_id, str):
            raise BackupError("bucket ilman tunnusta")
        safe_segment(bucket_id)
        paths = iter_objects(base, key, bucket_id)
        for path in paths:
            if len(manifest_files) >= max_files:
                raise BackupError(f"storage-tiedostoja on yli rajan {max_files}")
            quoted = "/".join(urllib.parse.quote(part) for part in path.split("/"))
            blob = request_bytes(
                f"{base}/storage/v1/object/{urllib.parse.quote(bucket_id)}/{quoted}",
                key,
            )
            total += len(blob)
            if total > max_bytes:
                raise BackupError(f"storage-tavumäärä ylittää rajan {max_bytes}")
            target = files_root / bucket_id
            for part in path.split("/"):
                safe_segment(part)
                target = target / part
            resolved = target.resolve()
            if files_root.resolve() not in resolved.parents:
                raise BackupError("storage-polku karkasi kohdehakemistosta")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(blob)
            manifest_files.append(
                {
                    "bucket": bucket_id,
                    "path": path,
                    "bytes": len(blob),
                    "sha256": hashlib.sha256(blob).hexdigest(),
                }
            )
    summary = {
        "method": "storage-api",
        "endpoint": "GET/POST /storage/v1",
        "buckets": [
            {
                "id": bucket.get("id") or bucket.get("name"),
                "public": bool(bucket.get("public")),
                "files": sum(1 for item in manifest_files if item["bucket"] == (bucket.get("id") or bucket.get("name"))),
            }
            for bucket in buckets
        ],
        "file_count": len(manifest_files),
        "bytes": total,
        "files": manifest_files,
    }
    (dest / "manifest.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dest", required=True)
    args = parser.parse_args()
    base = (os.environ.get("SUPABASE_URL") or f"https://{os.environ.get('SUPABASE_PROJECT_REF', 'sxbofnuisemspgquoxyv')}.supabase.co").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not key:
        print("storage: SUPABASE_SERVICE_ROLE_KEY puuttuu", file=sys.stderr)
        sys.exit(1)
    try:
        summary = download(
            base,
            key,
            Path(args.dest),
            max_files=int(os.environ.get("BACKUP_STORAGE_MAX_FILES", "5000")),
            max_bytes=int(os.environ.get("BACKUP_STORAGE_MAX_BYTES", str(2 * 1024 * 1024 * 1024))),
        )
    except BackupError as exc:
        print(f"storage: {exc}", file=sys.stderr)
        sys.exit(1)
    print(f"storage: {summary['file_count']} tiedostoa, {summary['bytes']} tavua")


if __name__ == "__main__":
    main()
