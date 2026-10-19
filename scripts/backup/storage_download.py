"""Lataa Storage-tiedostot ilman service role -avainta.

Julkiset bucketit article-images ja product-images: lista storage.objects-taulusta
(backup_reader) ja lataus ilman avainta
GET /storage/v1/object/public/<bucket>/<polku>.

Yksityiset receipts ja invoices: erillinen auth-käyttäjä (app_metadata.backup_role),
POST /auth/v1/token?grant_type=password anon-avaimella ja
GET /storage/v1/object/authenticated/<bucket>/<polku>.
Jos yksityisiä ei saada, lataus jatkuu ja manifestiin jää merkintä.
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

from common import PRIVATE_STORAGE_BUCKETS, PUBLIC_STORAGE_BUCKETS, BackupError


PUBLIC = set(PUBLIC_STORAGE_BUCKETS)
PRIVATE = set(PRIVATE_STORAGE_BUCKETS)


def request_bytes(url: str, headers: dict[str, str] | None = None, method: str = "GET", body: bytes | None = None) -> bytes:
    last_error = "tuntematon virhe"
    for attempt in range(5):
        req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            exc.read()
            last_error = f"HTTP {exc.code}"
            if exc.code not in {429, 500, 502, 503, 504} or attempt == 4:
                raise BackupError(f"storage-pyyntö epäonnistui ({last_error})") from exc
        except urllib.error.URLError:
            last_error = "verkko"
            if attempt == 4:
                raise BackupError(f"storage-pyyntö epäonnistui ({last_error})")
        time.sleep(min(2 ** attempt, 8))
    raise BackupError(f"storage-pyyntö epäonnistui ({last_error})")


def safe_segment(name: str) -> str:
    if not name or name in {".", ".."} or "/" in name or "\\" in name or name.startswith("."):
        raise BackupError("storage-nimi ei ole turvallinen yksittäinen polun osa")
    if ".." in name:
        raise BackupError("storage-nimi ei ole turvallinen")
    return name


def object_url(base: str, kind: str, bucket: str, path: str) -> str:
    safe_segment(bucket)
    parts = []
    for part in path.split("/"):
        parts.append(urllib.parse.quote(safe_segment(part)))
    quoted = "/".join(parts)
    return f"{base}/storage/v1/object/{kind}/{urllib.parse.quote(bucket)}/{quoted}"


def sign_in(base: str, anon_key: str, email: str, password: str) -> str:
    body = json.dumps({"email": email, "password": password}).encode("utf-8")
    raw = request_bytes(
        f"{base}/auth/v1/token?grant_type=password",
        headers={
            "apikey": anon_key,
            "Authorization": f"Bearer {anon_key}",
            "Content-Type": "application/json",
        },
        method="POST",
        body=body,
    )
    try:
        payload = json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise BackupError("storage-kirjautuminen ei palauttanut jsonia") from exc
    token = payload.get("access_token") if isinstance(payload, dict) else None
    if not isinstance(token, str) or not token:
        raise BackupError("storage-kirjautuminen ei palauttanut tunnusta")
    return token


def _write_file(files_root: Path, bucket: str, path: str, blob: bytes) -> None:
    target = files_root / safe_segment(bucket)
    for part in path.split("/"):
        target = target / safe_segment(part)
    resolved = target.resolve()
    if files_root.resolve() not in resolved.parents:
        raise BackupError("storage-polku karkasi kohdehakemistosta")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(blob)


def download(
    base: str,
    objects: list[dict],
    dest: Path,
    *,
    anon_key: str = "",
    email: str = "",
    password: str = "",
    other_buckets: list[str] | None = None,
    list_note: str = "",
    max_files: int = 5000,
    max_bytes: int = 2 * 1024 * 1024 * 1024,
) -> dict:
    dest.mkdir(parents=True, exist_ok=True)
    files_root = dest / "files"
    files_root.mkdir()
    notes: list[str] = []
    if list_note:
        notes.append(list_note)
    if other_buckets:
        notes.append(
            "näitä bucketeja ei ladattu (vain article-images, product-images, receipts, invoices): "
            + ", ".join(other_buckets)
        )
    private_rows = [row for row in objects if row.get("private") or row.get("bucket") in PRIVATE]
    public_rows = [row for row in objects if row not in private_rows]
    token = ""
    if private_rows:
        missing = [
            name
            for name, value in (
                ("BACKUP_STORAGE_EMAIL", email),
                ("BACKUP_STORAGE_PASSWORD", password),
                ("SUPABASE_ANON_KEY", anon_key),
            )
            if not value
        ]
        if missing:
            notes.append("yksityisiä tiedostoja ei haettu, puuttuu: " + ", ".join(missing))
        else:
            try:
                token = sign_in(base, anon_key, email, password)
            except BackupError:
                notes.append("yksityisiä tiedostoja ei haettu: kirjautuminen epäonnistui")
                token = ""

    manifest_files = []
    private_missing = []
    total = 0
    seen = 0
    for row in public_rows + private_rows:
        bucket = row.get("bucket")
        path = row.get("path")
        if not isinstance(bucket, str) or not isinstance(path, str):
            raise BackupError("storage-objektilta puuttuu bucket tai polku")
        private = bool(row.get("private") or bucket in PRIVATE)
        seen += 1
        if seen > max_files:
            raise BackupError(f"storage-tiedostoja on yli rajan {max_files}")
        if private and not token:
            private_missing.append({"bucket": bucket, "path": path})
            continue
        kind = "authenticated" if private else "public"
        headers = {"Authorization": f"Bearer {token}", "apikey": anon_key} if private else None
        try:
            blob = request_bytes(object_url(base, kind, bucket, path), headers=headers)
        except BackupError:
            if private:
                private_missing.append({"bucket": bucket, "path": path})
                continue
            raise
        total += len(blob)
        if total > max_bytes:
            raise BackupError(f"storage-tavumäärä ylittää rajan {max_bytes}")
        _write_file(files_root, bucket, path, blob)
        manifest_files.append(
            {
                "bucket": bucket,
                "path": path,
                "private": private,
                "bytes": len(blob),
                "sha256": hashlib.sha256(blob).hexdigest(),
            }
        )
    if private_missing:
        notes.append(f"yksityisiä tiedostoja jäi hakematta: {len(private_missing)}")
    buckets = []
    for bucket in (*PUBLIC_STORAGE_BUCKETS, *PRIVATE_STORAGE_BUCKETS):
        files = [item for item in manifest_files if item["bucket"] == bucket]
        missed = [item for item in private_missing if item["bucket"] == bucket]
        if not files and not missed and bucket not in {row.get("bucket") for row in objects}:
            continue
        buckets.append(
            {
                "id": bucket,
                "public": bucket in PUBLIC,
                "files": len(files),
                "missing": len(missed),
            }
        )
    summary = {
        "method": "public-url+auth-user",
        "file_count": len(manifest_files),
        "bytes": total,
        "buckets": buckets,
        "files": manifest_files,
        "private_missing": private_missing,
        "other_buckets": list(other_buckets or []),
        "notes": notes,
    }
    (dest / "manifest.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dest", required=True)
    parser.add_argument("--objects", required=True)
    args = parser.parse_args()
    base = (os.environ.get("SUPABASE_URL") or f"https://{os.environ.get('SUPABASE_PROJECT_REF', 'sxbofnuisemspgquoxyv')}.supabase.co").rstrip("/")
    listing = json.loads(Path(args.objects).read_text(encoding="utf-8"))
    try:
        summary = download(
            base,
            listing.get("objects") or [],
            Path(args.dest),
            anon_key=os.environ.get("SUPABASE_ANON_KEY", ""),
            email=os.environ.get("BACKUP_STORAGE_EMAIL", ""),
            password=os.environ.get("BACKUP_STORAGE_PASSWORD", ""),
            other_buckets=listing.get("other_buckets") or [],
            list_note=listing.get("note") or "",
            max_files=int(os.environ.get("BACKUP_STORAGE_MAX_FILES", "5000")),
            max_bytes=int(os.environ.get("BACKUP_STORAGE_MAX_BYTES", str(2 * 1024 * 1024 * 1024))),
        )
    except BackupError as exc:
        print(f"storage: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    print(f"storage: {summary['file_count']} tiedostoa, {summary['bytes']} tavua, yksityisiä hakematta {len(summary['private_missing'])}")


if __name__ == "__main__":
    main()
