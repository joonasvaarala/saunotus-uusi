"""Kokoaa manifest.json arkistoon. Ei lue salaisuuksia."""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone


def load(path: str):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inspect", required=True)
    parser.add_argument("--counts", required=True)
    parser.add_argument("--dump-info", required=True)
    parser.add_argument("--roles", required=True)
    parser.add_argument("--storage", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--filename", required=True)
    args = parser.parse_args()
    inspect = load(args.inspect)
    storage = load(args.storage)
    manifest = {
        "project": "tapio-havuhattu",
        "project_ref": "sxbofnuisemspgquoxyv",
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "filename": args.filename,
        "db_user": inspect["current_user"],
        "using_postgres_role": inspect["using_postgres_role"],
        "server_version": inspect["server_version"],
        "visible_schemas": inspect["visible_schemas"],
        "optional_schemas_absent": inspect["optional_missing"],
        "dump": load(args.dump_info),
        "roles": load(args.roles),
        "row_counts": load(args.counts),
        "storage": {
            "method": storage.get("method"),
            "file_count": storage.get("file_count"),
            "bytes": storage.get("bytes"),
            "buckets": storage.get("buckets", []),
            "private_missing": storage.get("private_missing", []),
            "other_buckets": storage.get("other_buckets", []),
            "notes": storage.get("notes", []),
        },
        "encryption": {"tool": "age", "recipient_in_github_secret": "BACKUP_AGE_PUBLIC_KEY"},
        "notes": [
            "Rivimäärät on laskettu juuri ennen pg_dumpia.",
            "Roolien salasanat eivät ole arkistossa.",
            "Dumppi sisältää vault-salaisuudet vain salatussa muodossa. Yhteydellä backup_reader voi lukea vault.decrypted_secrets selväkielisenä.",
            *list(storage.get("notes") or []),
        ],
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


if __name__ == "__main__":
    main()
